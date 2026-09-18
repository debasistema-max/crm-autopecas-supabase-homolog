begin;

set local lock_timeout = '10s';
set local statement_timeout = '110s';

alter table public.clients
  add column if not exists commercial_discount_percent numeric(5,2) not null default 0;

alter table public.clients
  drop constraint if exists clients_commercial_discount_percent_check;
alter table public.clients
  add constraint clients_commercial_discount_percent_check
    check(commercial_discount_percent between 0 and 100);

create or replace function public.guard_client_commercial_discount()
returns trigger language plpgsql security definer set search_path=public as $$
declare
  v_limit numeric:=coalesce(public.max_discount_percent(),10);
  v_changed boolean;
begin
  new.commercial_discount_percent:=coalesce(new.commercial_discount_percent,0);
  if new.commercial_discount_percent>v_limit then
    raise exception 'DESCONTO_CLIENTE_ACIMA_LIMITE: máximo %%%',v_limit;
  end if;
  if tg_op='INSERT' then
    v_changed:=new.commercial_discount_percent<>0;
  else
    v_changed:=new.commercial_discount_percent is distinct from old.commercial_discount_percent;
  end if;
  if v_changed and not (
    public.is_admin()
    or coalesce(auth.role(),'')='service_role'
    or session_user in ('postgres','supabase_admin')
  ) then raise exception 'APENAS_ADMIN_ALTERA_DESCONTO_CLIENTE'; end if;
  return new;
end;
$$;

drop trigger if exists clients_guard_commercial_discount on public.clients;
create trigger clients_guard_commercial_discount
before insert or update of commercial_discount_percent on public.clients
for each row execute function public.guard_client_commercial_discount();

revoke all on function public.guard_client_commercial_discount() from public,anon,authenticated;

create or replace function public.get_b2b_session()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  account_row public.customer_portal_accounts;
  client_row public.clients;
  destination_state text;
  origin_branch text;
begin
  select a.* into account_row from public.customer_portal_accounts a
  where a.user_id=auth.uid() and (a.active or a.activation_pending);
  if account_row.user_id is null then raise exception 'ACESSO_B2B_NAO_AUTORIZADO'; end if;
  select c.* into client_row from public.clients c where c.id=account_row.client_id and c.ativo;
  if client_row.id is null then raise exception 'CLIENTE_B2B_INATIVO'; end if;
  destination_state:=upper(btrim(coalesce(client_row.estado,'')));
  origin_branch:=case destination_state when 'SP' then 'SP' when 'PR' then 'PR' when 'SC' then 'PR' else null end;
  update public.customer_portal_accounts set last_login_at=now(),updated_at=now()
  where user_id=account_row.user_id and (last_login_at is null or last_login_at<now()-interval '15 minutes');
  return jsonb_build_object(
    'account',jsonb_build_object(
      'user_id',account_row.user_id,'email',case when account_row.login_mode='EMAIL' then account_row.email else null end,
      'username',account_row.username,'login_mode',account_row.login_mode,
      'must_change_password',account_row.must_change_password,'activation_pending',account_row.activation_pending,
      'contact_name',account_row.contact_name,'can_create_quotations',account_row.can_create_quotations,
      'can_create_orders',account_row.can_create_orders,'can_view_stock',account_row.can_view_stock,
      'can_view_prices',account_row.can_view_prices
    ),
    'client',jsonb_build_object(
      'id',client_row.id,'codigo_sap_cliente',client_row.codigo_sap_cliente,'nome',client_row.nome,
      'nome_fantasia',client_row.nome_fantasia,'cnpj',client_row.cnpj,'telefone',client_row.telefone,
      'email',client_row.email,'cidade',client_row.cidade,'estado',client_row.estado,'endereco',client_row.endereco,
      'commercial_discount_percent',client_row.commercial_discount_percent
    ),
    'route',case when origin_branch is null then null else origin_branch||'-'||destination_state end,
    'origin_branch',origin_branch,'destination_state',nullif(destination_state,''),
    'route_supported',origin_branch is not null
  );
end;
$$;

create or replace function public.b2b_search_catalog(
  search_term text,line_filter text,only_available boolean,limit_count integer
)
returns table(
  product_code text,description text,brand text,application text,year text,image_url text,
  route text,final_price numeric,currency text,availability text,available_qty numeric,
  source_display_value text,pr_transfer_available_qty numeric,stock_updated_at timestamptz
)
language plpgsql stable security definer set search_path=public as $$
declare
  v_account public.customer_portal_accounts;
  v_client_state text;
  v_origin_code text;
  v_origin_id uuid;
  v_discount numeric:=0;
  v_search_value text:=left(regexp_replace(lower(unaccent(btrim(coalesce(search_term,'')))),'[^a-z0-9]+',' ','g'),100);
  v_line_value text:=upper(btrim(unaccent(coalesce(line_filter,''))));
  v_tokens text[];
begin
  v_search_value:=btrim(regexp_replace(v_search_value,'[[:space:]]+',' ','g'));
  v_tokens:=case when v_search_value='' then array[]::text[] else regexp_split_to_array(v_search_value,'[[:space:]]+') end;
  select * into v_account from public.customer_portal_accounts where user_id=auth.uid() and active;
  if v_account.user_id is null then raise exception 'ACESSO_B2B_NAO_AUTORIZADO'; end if;
  if not v_account.can_view_prices then raise exception 'PRECO_B2B_NAO_AUTORIZADO'; end if;
  select upper(btrim(coalesce(c.estado,''))),coalesce(c.commercial_discount_percent,0)
    into v_client_state,v_discount from public.clients c where c.id=v_account.client_id and c.ativo;
  if v_discount>coalesce(public.max_discount_percent(),10) then raise exception 'DESCONTO_CLIENTE_ACIMA_LIMITE'; end if;
  v_origin_code:=case v_client_state when 'SP' then 'SP' when 'PR' then 'PR' when 'SC' then 'PR' else null end;
  if v_origin_code is null then raise exception 'ROTA_B2B_NAO_CONFIGURADA'; end if;
  select b.id into v_origin_id from public.branches b where b.code=v_origin_code and b.active;
  if v_origin_id is null then raise exception 'FILIAL_B2B_NAO_CONFIGURADA'; end if;
  return query
  with eligible as (
    select p.codigo,p.descricao,p.marca,p.aplicacao,p.ano,
      coalesce(nullif(p.url_imagem,''),m.official_image_url) as url_imagem,rp.route,
      round(rp.final_price*(1-v_discount/100),4) as final_price,rp.currency::text,
      lower(unaccent(concat_ws(' ',p.codigo,p.descricao,p.marca,p.aplicacao,p.ano,p.oem,
        p."similar",p.montadora,p.detalhes,p.search_text,m.product_name,m.applications,m.line_name))) as search_document,
      lower(unaccent(concat_ws(' ',p.codigo,p.oem,p."similar"))) as identifier_document,
      lower(unaccent(concat_ws(' ',p.descricao,m.product_name))) as description_document,
      lower(unaccent(concat_ws(' ',p.aplicacao,m.applications))) as application_document,
      lower(unaccent(concat_ws(' ',p.marca,p.montadora))) as brand_document
    from public.products p
    left join public.product_catalog_metadata m on m.product_code=p.codigo
    join public.product_route_prices rp on rp.product_code=p.codigo and rp.origin_branch_id=v_origin_id
      and rp.route=v_origin_code||'-'||v_client_state and rp.final_price>0
      and upper(coalesce(rp.calculation_status,'OK')) like 'OK%'
    where v_line_value='' or upper(btrim(unaccent(coalesce(m.line_name,p.categoria,''))))=v_line_value
  ), scored as (
    select e.*,score.matched_terms,
      score.identifier_terms*45+score.application_terms*25+score.description_terms*20+score.brand_terms*10 as field_score,
      e.codigo=regexp_replace(v_search_value,'[[:space:]]+','','g') as exact_code,
      e.search_document like '%'||v_search_value||'%' as phrase_match
    from eligible e cross join lateral (
      select count(*) filter(where e.search_document like '%'||t.token||'%')::integer matched_terms,
        count(*) filter(where e.identifier_document like '%'||t.token||'%')::integer identifier_terms,
        count(*) filter(where e.application_document like '%'||t.token||'%')::integer application_terms,
        count(*) filter(where e.description_document like '%'||t.token||'%')::integer description_terms,
        count(*) filter(where e.brand_document like '%'||t.token||'%')::integer brand_terms
      from unnest(v_tokens) t(token)
    ) score where v_search_value='' or score.matched_terms=cardinality(v_tokens)
  ), catalog as (
    select p.*,
      case when s.product_code is null or (s.source_batch_id is null and coalesce(s.version,0)=0) then 'NAO_IMPORTADO'
        when s.available_qty>0 then 'DISPONIVEL'
        when v_origin_code='SP' and pr.available_qty>0 and not(pr.source_batch_id is null and coalesce(pr.version,0)=0) then 'TRANSFERENCIA_PR'
        else 'INDISPONIVEL' end availability,
      case when v_account.can_view_stock and s.product_code is not null and not(s.source_batch_id is null and coalesce(s.version,0)=0) then s.available_qty end available_qty,
      case when v_account.can_view_stock and s.product_code is not null and not(s.source_batch_id is null and coalesce(s.version,0)=0)
        then coalesce(nullif(s.source_display_value,''),trim(to_char(s.available_qty,'FM999999999999990.###'))) end source_display_value,
      case when v_account.can_view_stock and v_origin_code='SP' and pr.product_code is not null and not(pr.source_batch_id is null and coalesce(pr.version,0)=0) then pr.available_qty end pr_transfer_available_qty,
      case when s.product_code is not null and not(s.source_batch_id is null and coalesce(s.version,0)=0) then s.updated_at end stock_updated_at
    from scored p
    left join public.product_branch_stock s on s.product_code=p.codigo and s.branch_id=v_origin_id
    left join public.branches prb on prb.code='PR' and prb.active
    left join public.product_branch_stock pr on pr.product_code=p.codigo and pr.branch_id=prb.id
  )
  select c.codigo,c.descricao,c.marca,c.aplicacao,c.ano,c.url_imagem,c.route,c.final_price,c.currency,
    c.availability,c.available_qty,c.source_display_value,c.pr_transfer_available_qty,c.stock_updated_at
  from catalog c where not only_available or c.availability in ('DISPONIVEL','TRANSFERENCIA_PR')
  order by c.exact_code desc,c.phrase_match desc,c.matched_terms desc,c.field_score desc,c.codigo
  limit least(greatest(limit_count,1),50);
end;
$$;

create or replace function public.b2b_create_document(document_type text,payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  account_row public.customer_portal_accounts; client_row public.clients; owner_row public.profiles;
  branch_row public.branches; pr_branch_id uuid; destination_state text; origin_code text; route_value text;
  item_data jsonb; product_row public.products; price_row public.product_route_prices;
  stock_row public.product_branch_stock; pr_stock public.product_branch_stock;
  new_id uuid; document_number text; request_key text; idx integer:=0; qty numeric;
  discount_percent numeric:=0; discounted_unit numeric; subtotal_value numeric:=0; total_value numeric:=0;
  transfer_summary jsonb:=jsonb_build_object('created',0,'warnings','[]'::jsonb);
  seen_codes text[]:='{}'::text[]; existing_result jsonb;
begin
  if document_type not in ('pedido','cotacao') then raise exception 'TIPO_DOCUMENTO_INVALIDO'; end if;
  select * into account_row from public.customer_portal_accounts where user_id=auth.uid() and active;
  if account_row.user_id is null then raise exception 'ACESSO_B2B_NAO_AUTORIZADO'; end if;
  if document_type='pedido' and not account_row.can_create_orders then raise exception 'PEDIDO_B2B_NAO_AUTORIZADO'; end if;
  if document_type='cotacao' and not account_row.can_create_quotations then raise exception 'COTACAO_B2B_NAO_AUTORIZADA'; end if;
  if not account_row.can_view_prices then raise exception 'PRECO_B2B_NAO_AUTORIZADO'; end if;
  if jsonb_typeof(payload->'items')<>'array' or jsonb_array_length(payload->'items') not between 1 and 100 then raise exception 'ITENS_B2B_INVALIDOS'; end if;
  request_key:=lower(btrim(coalesce(payload->>'idempotency_key','')));
  if request_key !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then raise exception 'IDEMPOTENCIA_B2B_INVALIDA'; end if;
  if document_type='pedido' then
    select jsonb_build_object('id',id,'numero_pedido',numero_pedido,'total',total,'desconto_total',desconto_total,'duplicate',true)
      into existing_result from public.orders where portal_account_user_id=account_row.user_id and portal_idempotency_key=request_key;
  else
    select jsonb_build_object('id',id,'numero_cotacao',numero_cotacao,'total',total,'desconto_total',desconto_total,'duplicate',true)
      into existing_result from public.quotations where portal_account_user_id=account_row.user_id and portal_idempotency_key=request_key;
  end if;
  if existing_result is not null then return existing_result; end if;
  if (select count(*) from public.orders where portal_account_user_id=account_row.user_id and created_at>now()-interval '1 hour')
    +(select count(*) from public.quotations where portal_account_user_id=account_row.user_id and created_at>now()-interval '1 hour')>=30 then raise exception 'LIMITE_B2B_TEMPORARIO'; end if;
  select * into client_row from public.clients where id=account_row.client_id and ativo;
  if client_row.id is null then raise exception 'CLIENTE_B2B_INATIVO'; end if;
  discount_percent:=coalesce(client_row.commercial_discount_percent,0);
  if discount_percent>coalesce(public.max_discount_percent(),10) then raise exception 'DESCONTO_CLIENTE_ACIMA_LIMITE'; end if;
  select * into owner_row from public.profiles where id=account_row.owner_profile_id and ativo;
  if owner_row.id is null then select * into owner_row from public.profiles where perfil='ADMIN' and ativo order by created_at limit 1; end if;
  if owner_row.id is null then raise exception 'RESPONSAVEL_B2B_NAO_CONFIGURADO'; end if;
  destination_state:=upper(btrim(coalesce(client_row.estado,'')));
  origin_code:=case destination_state when 'SP' then 'SP' when 'PR' then 'PR' when 'SC' then 'PR' else null end;
  if origin_code is null then raise exception 'ROTA_B2B_NAO_CONFIGURADA'; end if;
  route_value:=origin_code||'-'||destination_state;
  select * into branch_row from public.branches where code=origin_code and active;
  select id into pr_branch_id from public.branches where code='PR' and active;
  if branch_row.id is null then raise exception 'FILIAL_B2B_NAO_CONFIGURADA'; end if;
  if document_type='pedido' then
    document_number:=lpad(nextval('public.order_commercial_number_seq')::text,6,'0');
    insert into public.orders(numero_pedido,regiao,billing_uf,user_id,vendedor,codigo_sap_cliente,cliente,cnpj,telefone,endereco,prazo,observacao,status,client_id,portal_account_user_id,source_channel,portal_idempotency_key)
    values(document_number,origin_code::public.order_region,destination_state,owner_row.id,coalesce(owner_row.nome,'Portal B2B'),client_row.codigo_sap_cliente,client_row.nome,
      regexp_replace(coalesce(client_row.cnpj,''),'\D','','g'),client_row.telefone,client_row.endereco,nullif(btrim(payload->>'prazo'),''),left(nullif(btrim(payload->>'observacao'),''),1000),
      'NOVO',client_row.id,account_row.user_id,'B2B_PORTAL',request_key) returning id into new_id;
  else
    document_number:=lpad(nextval('public.quotation_commercial_number_seq')::text,6,'0');
    insert into public.quotations(numero_cotacao,regiao,billing_uf,user_id,vendedor,codigo_sap_cliente,cliente,cnpj,telefone,endereco,prazo,observacao,status,client_id,portal_account_user_id,source_channel,portal_idempotency_key)
    values(document_number,origin_code::public.order_region,destination_state,owner_row.id,coalesce(owner_row.nome,'Portal B2B'),client_row.codigo_sap_cliente,client_row.nome,
      regexp_replace(coalesce(client_row.cnpj,''),'\D','','g'),client_row.telefone,client_row.endereco,nullif(btrim(payload->>'prazo'),''),left(nullif(btrim(payload->>'observacao'),''),1000),
      'NOVA',client_row.id,account_row.user_id,'B2B_PORTAL',request_key) returning id into new_id;
  end if;
  for item_data in select value from jsonb_array_elements(payload->'items') loop
    idx:=idx+1; qty:=nullif(item_data->>'quantidade','')::numeric;
    if qty is null or qty<=0 or qty>999999 then raise exception 'QUANTIDADE_B2B_INVALIDA: item %',idx; end if;
    if btrim(coalesce(item_data->>'codigo',''))=any(seen_codes) then raise exception 'PRODUTO_B2B_DUPLICADO: item %',idx; end if;
    seen_codes:=array_append(seen_codes,btrim(item_data->>'codigo'));
    select * into product_row from public.products where codigo=btrim(item_data->>'codigo');
    if product_row.codigo is null then raise exception 'PRODUTO_NAO_ENCONTRADO: item %',idx; end if;
    select * into price_row from public.product_route_prices where product_code=product_row.codigo and origin_branch_id=branch_row.id
      and route=route_value and final_price>0 and upper(coalesce(calculation_status,'OK')) like 'OK%';
    if price_row.product_code is null then raise exception 'PRECO_B2B_INDISPONIVEL: item %',idx; end if;
    discounted_unit:=round(price_row.final_price*(1-discount_percent/100),4);
    select * into stock_row from public.product_branch_stock where product_code=product_row.codigo and branch_id=branch_row.id;
    if document_type='pedido' then
      if stock_row.product_code is null or (stock_row.source_batch_id is null and coalesce(stock_row.version,0)=0) then raise exception 'ESTOQUE_B2B_NAO_IMPORTADO: item %',idx; end if;
      if coalesce(stock_row.available_qty,0)<qty then
        if origin_code<>'SP' then raise exception 'ESTOQUE_B2B_INSUFICIENTE: item %',idx; end if;
        select * into pr_stock from public.product_branch_stock where product_code=product_row.codigo and branch_id=pr_branch_id;
        if pr_stock.product_code is null or (pr_stock.source_batch_id is null and coalesce(pr_stock.version,0)=0) then raise exception 'ESTOQUE_PR_NAO_IMPORTADO: item %',idx; end if;
        if coalesce(stock_row.available_qty,0)+coalesce(pr_stock.available_qty,0)<qty then raise exception 'ESTOQUE_B2B_INSUFICIENTE_SP_PR: item %',idx; end if;
      end if;
    end if;
    if document_type='pedido' then
      insert into public.order_items(order_id,item,codigo,descricao,marca,aplicacao,quantidade,preco_unitario,desconto_percentual,preco_final_unitario,total_item,
        preco_sem_imposto_unitario,imposto_unitario,fiscal_status,fiscal_details,fiscal_calculated_at,fiscal_origin_state,fiscal_destination_state)
      values(new_id,idx,product_row.codigo,product_row.descricao,product_row.marca,product_row.aplicacao,qty,price_row.final_price,discount_percent,discounted_unit,
        round(discounted_unit*qty,2),price_row.base_price,price_row.total_taxes,'OK',
        jsonb_build_object('status','OK','customer_type','REVENDA','price_source','EXCEL_ROUTE_PRICE','route',route_value,'client_discount_percent',discount_percent,
          'source',price_row.source,'source_version',price_row.source_version,'source_batch_id',price_row.source_batch_id,'stock_version',stock_row.version,'stock_available_qty',stock_row.available_qty),
        price_row.source_updated_at,origin_code,destination_state);
    else
      insert into public.quotation_items(quotation_id,item,codigo,descricao,marca,aplicacao,quantidade,preco_unitario,desconto_percentual,preco_final_unitario,total_item,
        preco_sem_imposto_unitario,imposto_unitario,fiscal_status,fiscal_details,fiscal_calculated_at,fiscal_origin_state,fiscal_destination_state)
      values(new_id,idx,product_row.codigo,product_row.descricao,product_row.marca,product_row.aplicacao,qty,price_row.final_price,discount_percent,discounted_unit,
        round(discounted_unit*qty,2),price_row.base_price,price_row.total_taxes,'OK',
        jsonb_build_object('status','OK','customer_type','REVENDA','price_source','EXCEL_ROUTE_PRICE','route',route_value,'client_discount_percent',discount_percent,
          'source',price_row.source,'source_version',price_row.source_version,'source_batch_id',price_row.source_batch_id,'stock_version',stock_row.version,'stock_available_qty',stock_row.available_qty),
        price_row.source_updated_at,origin_code,destination_state);
    end if;
    subtotal_value:=subtotal_value+price_row.final_price*qty;
    total_value:=total_value+discounted_unit*qty;
  end loop;
  if document_type='pedido' then
    update public.orders set subtotal=round(subtotal_value,2),desconto_total=round(subtotal_value-total_value,2),total=round(total_value,2) where id=new_id;
    transfer_summary:=public.b2b_create_order_transfer_requests(new_id,account_row.user_id);
  else
    update public.quotations set subtotal=round(subtotal_value,2),desconto_total=round(subtotal_value-total_value,2),total=round(total_value,2) where id=new_id;
  end if;
  insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_novos)
  values(owner_row.id,'B2B:'||account_row.email,case when document_type='pedido' then 'CRIAR_PEDIDO_B2B' else 'CRIAR_COTACAO_B2B' end,
    case when document_type='pedido' then 'orders' else 'quotations' end,new_id::text,
    jsonb_build_object('source','B2B_PORTAL','client_id',client_row.id,'portal_user_id',account_row.user_id,'numero',document_number,'route',route_value,
      'client_discount_percent',discount_percent,'subtotal',round(subtotal_value,2),'discount_total',round(subtotal_value-total_value,2),'items',idx,'total',round(total_value,2),'transfers',transfer_summary));
  return jsonb_build_object('id',new_id,case when document_type='pedido' then 'numero_pedido' else 'numero_cotacao' end,document_number,
    'subtotal',round(subtotal_value,2),'desconto_total',round(subtotal_value-total_value,2),'total',round(total_value,2),
    'discount_percent',discount_percent,'route',route_value,'transferencias',transfer_summary,'duplicate',false);
exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'VALOR_B2B_INVALIDO';
end;
$$;

comment on column public.clients.commercial_discount_percent is
  'Desconto comercial padrão do cliente, aplicado depois do preço final aprovado da rota.';

commit;
