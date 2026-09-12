begin;

set local lock_timeout = '10s';
set local statement_timeout = '110s';

create or replace function public.b2b_search_catalog(
  search_term text default '',
  only_available boolean default false,
  limit_count integer default 40
)
returns table(
  product_code text,
  description text,
  brand text,
  application text,
  year text,
  image_url text,
  route text,
  final_price numeric,
  currency text,
  availability text,
  available_qty numeric,
  source_display_value text,
  pr_transfer_available_qty numeric,
  stock_updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  account_row public.customer_portal_accounts;
  client_state text;
  origin_code text;
  origin_id uuid;
  search_value text := left(btrim(coalesce(search_term,'')),100);
begin
  select * into account_row from public.customer_portal_accounts
  where user_id = auth.uid() and active;
  if account_row.user_id is null then raise exception 'ACESSO_B2B_NAO_AUTORIZADO'; end if;
  if not account_row.can_view_prices then raise exception 'PRECO_B2B_NAO_AUTORIZADO'; end if;

  select upper(btrim(coalesce(c.estado,''))) into client_state
  from public.clients c where c.id = account_row.client_id and c.ativo;
  origin_code := case client_state when 'SP' then 'SP' when 'PR' then 'PR' when 'SC' then 'PR' else null end;
  if origin_code is null then raise exception 'ROTA_B2B_NAO_CONFIGURADA'; end if;
  select id into origin_id from public.branches where code = origin_code and active;
  if origin_id is null then raise exception 'FILIAL_B2B_NAO_CONFIGURADA'; end if;

  return query
  with candidates as (
    select p.*
    from public.products p
    where search_value = ''
       or p.search_vector @@ plainto_tsquery('simple',lower(unaccent(search_value)))
       or p.search_text like '%'||lower(unaccent(search_value))||'%'
    order by similarity(p.search_text,lower(unaccent(search_value))) desc,p.codigo
    limit least(greatest(limit_count,1)*5,250)
  ), catalog as (
    select
      p.codigo,p.descricao,p.marca,p.aplicacao,p.ano,p.url_imagem,
      rp.route,rp.final_price,rp.currency::text,
      case
        when s.product_code is null or (s.source_batch_id is null and coalesce(s.version,0)=0) then 'NAO_IMPORTADO'
        when s.available_qty > 0 then 'DISPONIVEL'
        when origin_code='SP' and pr.available_qty > 0
          and not (pr.source_batch_id is null and coalesce(pr.version,0)=0) then 'TRANSFERENCIA_PR'
        else 'INDISPONIVEL'
      end as availability,
      case when account_row.can_view_stock
        and s.product_code is not null
        and not (s.source_batch_id is null and coalesce(s.version,0)=0)
        then s.available_qty else null end as available_qty,
      case when account_row.can_view_stock
        and s.product_code is not null
        and not (s.source_batch_id is null and coalesce(s.version,0)=0)
        then coalesce(nullif(s.source_display_value,''),trim(to_char(s.available_qty,'FM999999999999990.###'))) else null end as source_display_value,
      case when account_row.can_view_stock and origin_code='SP'
        and pr.product_code is not null
        and not (pr.source_batch_id is null and coalesce(pr.version,0)=0)
        then pr.available_qty else null end as pr_transfer_available_qty,
      case when s.product_code is not null
        and not (s.source_batch_id is null and coalesce(s.version,0)=0)
        then s.updated_at else null end as stock_updated_at,
      p.search_text
    from candidates p
    join public.product_route_prices rp
      on rp.product_code=p.codigo and rp.origin_branch_id=origin_id
      and rp.route=origin_code||'-'||client_state
      and rp.final_price>0 and upper(coalesce(rp.calculation_status,'OK')) like 'OK%'
    left join public.product_branch_stock s
      on s.product_code=p.codigo and s.branch_id=origin_id
    left join public.branches prb on prb.code='PR' and prb.active
    left join public.product_branch_stock pr
      on pr.product_code=p.codigo and pr.branch_id=prb.id
  )
  select c.codigo,c.descricao,c.marca,c.aplicacao,c.ano,c.url_imagem,c.route,
    c.final_price,c.currency,c.availability,c.available_qty,c.source_display_value,
    c.pr_transfer_available_qty,c.stock_updated_at
  from catalog c
  where not only_available or c.availability in ('DISPONIVEL','TRANSFERENCIA_PR')
  order by similarity(c.search_text,lower(unaccent(search_value))) desc,c.codigo
  limit least(greatest(limit_count,1),50);
end;
$$;

create or replace function public.b2b_create_order_transfer_requests(
  target_order_id uuid,
  target_account_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  account_row public.customer_portal_accounts;
  order_row public.orders;
  sp_id uuid;
  pr_id uuid;
  item_row record;
  sp_stock public.product_branch_stock;
  pr_stock public.product_branch_stock;
  shortage numeric(14,3);
  transfer_qty numeric(14,3);
  created_count integer := 0;
begin
  select * into account_row from public.customer_portal_accounts
  where user_id=target_account_user_id and active;
  if account_row.user_id is null or target_account_user_id<>auth.uid() then raise exception 'ACESSO_B2B_NAO_AUTORIZADO'; end if;

  select * into order_row from public.orders
  where id=target_order_id and client_id=account_row.client_id
    and portal_account_user_id=account_row.user_id and source_channel='B2B_PORTAL'
  for update;
  if order_row.id is null then raise exception 'PEDIDO_B2B_NAO_ENCONTRADO'; end if;
  if order_row.regiao::text<>'SP' or upper(coalesce(order_row.billing_uf,''))<>'SP' then
    return jsonb_build_object('created',0,'warnings','[]'::jsonb);
  end if;

  select id into sp_id from public.branches where code='SP' and active;
  select id into pr_id from public.branches where code='PR' and active;

  for item_row in select * from public.order_items where order_id=target_order_id order by item loop
    select * into sp_stock from public.product_branch_stock
    where product_code=item_row.codigo and branch_id=sp_id for update;
    select * into pr_stock from public.product_branch_stock
    where product_code=item_row.codigo and branch_id=pr_id for update;
    shortage:=greatest(item_row.quantidade-coalesce(sp_stock.available_qty,0),0);
    transfer_qty:=least(shortage,coalesce(pr_stock.available_qty,0));
    if transfer_qty>0 then
      insert into public.stock_transfer_requests(
        order_id,order_item_id,product_code,source_branch_id,target_branch_id,
        requested_qty,source_available_qty,target_available_qty,reason,
        requested_by,requested_by_portal_user
      ) values(
        target_order_id,item_row.id,item_row.codigo,pr_id,sp_id,
        transfer_qty,pr_stock.available_qty,sp_stock.available_qty,
        'B2B_ORDER_SP_SHORTAGE_PR_TRANSFER',account_row.owner_profile_id,account_row.user_id
      ) on conflict (order_id,product_code,source_branch_id,target_branch_id)
        where status in ('PENDING','APPROVED','IN_TRANSIT')
      do update set
        order_item_id=excluded.order_item_id,
        requested_qty=excluded.requested_qty,
        source_available_qty=excluded.source_available_qty,
        target_available_qty=excluded.target_available_qty,
        requested_by=excluded.requested_by,
        requested_by_portal_user=excluded.requested_by_portal_user,
        updated_at=now();
      created_count:=created_count+1;
    end if;
  end loop;

  if created_count>0 then
    update public.orders set logistics_status=case when stock_contract_version=0 then logistics_status else 'AWAITING_STOCK' end
    where id=target_order_id;
  end if;
  return jsonb_build_object('created',created_count,'warnings','[]'::jsonb);
end;
$$;

create or replace function public.b2b_create_document(document_type text,payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  account_row public.customer_portal_accounts;
  client_row public.clients;
  owner_row public.profiles;
  branch_row public.branches;
  pr_branch_id uuid;
  destination_state text;
  origin_code text;
  route_value text;
  item_data jsonb;
  product_row public.products;
  price_row public.product_route_prices;
  stock_row public.product_branch_stock;
  pr_stock public.product_branch_stock;
  new_id uuid;
  document_number text;
  request_key text;
  idx integer:=0;
  qty numeric;
  subtotal_value numeric:=0;
  total_value numeric:=0;
  transfer_summary jsonb:=jsonb_build_object('created',0,'warnings','[]'::jsonb);
  seen_codes text[]:='{}'::text[];
  existing_result jsonb;
begin
  if document_type not in ('pedido','cotacao') then raise exception 'TIPO_DOCUMENTO_INVALIDO'; end if;
  select * into account_row from public.customer_portal_accounts
  where user_id=auth.uid() and active;
  if account_row.user_id is null then raise exception 'ACESSO_B2B_NAO_AUTORIZADO'; end if;
  if document_type='pedido' and not account_row.can_create_orders then raise exception 'PEDIDO_B2B_NAO_AUTORIZADO'; end if;
  if document_type='cotacao' and not account_row.can_create_quotations then raise exception 'COTACAO_B2B_NAO_AUTORIZADA'; end if;
  if not account_row.can_view_prices then raise exception 'PRECO_B2B_NAO_AUTORIZADO'; end if;
  if jsonb_typeof(payload->'items')<>'array' or jsonb_array_length(payload->'items') not between 1 and 100 then raise exception 'ITENS_B2B_INVALIDOS'; end if;

  request_key:=lower(btrim(coalesce(payload->>'idempotency_key','')));
  if request_key !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    raise exception 'IDEMPOTENCIA_B2B_INVALIDA';
  end if;

  if document_type='pedido' then
    select jsonb_build_object('id',id,'numero_pedido',numero_pedido,'duplicate',true)
    into existing_result from public.orders
    where portal_account_user_id=account_row.user_id and portal_idempotency_key=request_key;
  else
    select jsonb_build_object('id',id,'numero_cotacao',numero_cotacao,'duplicate',true)
    into existing_result from public.quotations
    where portal_account_user_id=account_row.user_id and portal_idempotency_key=request_key;
  end if;
  if existing_result is not null then return existing_result; end if;

  if (select count(*) from public.orders where portal_account_user_id=account_row.user_id and created_at>now()-interval '1 hour')
     +(select count(*) from public.quotations where portal_account_user_id=account_row.user_id and created_at>now()-interval '1 hour')>=30 then
    raise exception 'LIMITE_B2B_TEMPORARIO';
  end if;

  select * into client_row from public.clients where id=account_row.client_id and ativo;
  if client_row.id is null then raise exception 'CLIENTE_B2B_INATIVO'; end if;
  select * into owner_row from public.profiles where id=account_row.owner_profile_id and ativo;
  if owner_row.id is null then
    select * into owner_row from public.profiles where perfil='ADMIN' and ativo order by created_at limit 1;
  end if;
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
    insert into public.orders(
      numero_pedido,regiao,billing_uf,user_id,vendedor,codigo_sap_cliente,cliente,cnpj,telefone,endereco,
      prazo,observacao,status,client_id,portal_account_user_id,source_channel,portal_idempotency_key
    ) values(
      document_number,origin_code::public.order_region,destination_state,owner_row.id,coalesce(owner_row.nome,'Portal B2B'),
      client_row.codigo_sap_cliente,client_row.nome,regexp_replace(coalesce(client_row.cnpj,''),'\D','','g'),
      client_row.telefone,client_row.endereco,nullif(btrim(payload->>'prazo'),''),
      left(nullif(btrim(payload->>'observacao'),''),1000),'NOVO',client_row.id,account_row.user_id,'B2B_PORTAL',request_key
    ) returning id into new_id;
  else
    document_number:=lpad(nextval('public.quotation_commercial_number_seq')::text,6,'0');
    insert into public.quotations(
      numero_cotacao,regiao,billing_uf,user_id,vendedor,codigo_sap_cliente,cliente,cnpj,telefone,endereco,
      prazo,observacao,status,client_id,portal_account_user_id,source_channel,portal_idempotency_key
    ) values(
      document_number,origin_code::public.order_region,destination_state,owner_row.id,coalesce(owner_row.nome,'Portal B2B'),
      client_row.codigo_sap_cliente,client_row.nome,regexp_replace(coalesce(client_row.cnpj,''),'\D','','g'),
      client_row.telefone,client_row.endereco,nullif(btrim(payload->>'prazo'),''),
      left(nullif(btrim(payload->>'observacao'),''),1000),'NOVA',client_row.id,account_row.user_id,'B2B_PORTAL',request_key
    ) returning id into new_id;
  end if;

  for item_data in select value from jsonb_array_elements(payload->'items') loop
    idx:=idx+1;
    qty:=nullif(item_data->>'quantidade','')::numeric;
    if qty is null or qty<=0 or qty>999999 then raise exception 'QUANTIDADE_B2B_INVALIDA: item %',idx; end if;
    if btrim(coalesce(item_data->>'codigo',''))=any(seen_codes) then raise exception 'PRODUTO_B2B_DUPLICADO: item %',idx; end if;
    seen_codes:=array_append(seen_codes,btrim(item_data->>'codigo'));

    select * into product_row from public.products where codigo=btrim(item_data->>'codigo');
    if product_row.codigo is null then raise exception 'PRODUTO_NAO_ENCONTRADO: item %',idx; end if;
    select * into price_row from public.product_route_prices
    where product_code=product_row.codigo and origin_branch_id=branch_row.id and route=route_value
      and final_price>0 and upper(coalesce(calculation_status,'OK')) like 'OK%';
    if price_row.product_code is null then raise exception 'PRECO_B2B_INDISPONIVEL: item %',idx; end if;
    select * into stock_row from public.product_branch_stock
    where product_code=product_row.codigo and branch_id=branch_row.id;

    if document_type='pedido' then
      if stock_row.product_code is null or (stock_row.source_batch_id is null and coalesce(stock_row.version,0)=0) then
        raise exception 'ESTOQUE_B2B_NAO_IMPORTADO: item %',idx;
      end if;
      if coalesce(stock_row.available_qty,0)<qty then
        if origin_code<>'SP' then raise exception 'ESTOQUE_B2B_INSUFICIENTE: item %',idx; end if;
        select * into pr_stock from public.product_branch_stock
        where product_code=product_row.codigo and branch_id=pr_branch_id;
        if pr_stock.product_code is null or (pr_stock.source_batch_id is null and coalesce(pr_stock.version,0)=0) then
          raise exception 'ESTOQUE_PR_NAO_IMPORTADO: item %',idx;
        end if;
        if coalesce(stock_row.available_qty,0)+coalesce(pr_stock.available_qty,0)<qty then
          raise exception 'ESTOQUE_B2B_INSUFICIENTE_SP_PR: item %',idx;
        end if;
      end if;
    end if;

    if document_type='pedido' then
      insert into public.order_items(
        order_id,item,codigo,descricao,marca,aplicacao,quantidade,preco_unitario,desconto_percentual,
        preco_final_unitario,total_item,preco_sem_imposto_unitario,imposto_unitario,fiscal_status,fiscal_details,
        fiscal_calculated_at,fiscal_origin_state,fiscal_destination_state
      ) values(
        new_id,idx,product_row.codigo,product_row.descricao,product_row.marca,product_row.aplicacao,qty,price_row.final_price,0,
        price_row.final_price,round(price_row.final_price*qty,2),price_row.base_price,price_row.total_taxes,'OK',
        jsonb_build_object('status','OK','customer_type','REVENDA','price_source','EXCEL_ROUTE_PRICE','route',route_value,
          'source',price_row.source,'source_version',price_row.source_version,'source_batch_id',price_row.source_batch_id,
          'stock_version',stock_row.version,'stock_available_qty',stock_row.available_qty),
        price_row.source_updated_at,origin_code,destination_state
      );
    else
      insert into public.quotation_items(
        quotation_id,item,codigo,descricao,marca,aplicacao,quantidade,preco_unitario,desconto_percentual,
        preco_final_unitario,total_item,preco_sem_imposto_unitario,imposto_unitario,fiscal_status,fiscal_details,
        fiscal_calculated_at,fiscal_origin_state,fiscal_destination_state
      ) values(
        new_id,idx,product_row.codigo,product_row.descricao,product_row.marca,product_row.aplicacao,qty,price_row.final_price,0,
        price_row.final_price,round(price_row.final_price*qty,2),price_row.base_price,price_row.total_taxes,'OK',
        jsonb_build_object('status','OK','customer_type','REVENDA','price_source','EXCEL_ROUTE_PRICE','route',route_value,
          'source',price_row.source,'source_version',price_row.source_version,'source_batch_id',price_row.source_batch_id,
          'stock_version',stock_row.version,'stock_available_qty',stock_row.available_qty),
        price_row.source_updated_at,origin_code,destination_state
      );
    end if;
    subtotal_value:=subtotal_value+price_row.final_price*qty;
    total_value:=total_value+price_row.final_price*qty;
  end loop;

  if document_type='pedido' then
    update public.orders set subtotal=round(subtotal_value,2),desconto_total=0,total=round(total_value,2) where id=new_id;
    transfer_summary:=public.b2b_create_order_transfer_requests(new_id,account_row.user_id);
  else
    update public.quotations set subtotal=round(subtotal_value,2),desconto_total=0,total=round(total_value,2) where id=new_id;
  end if;

  insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_novos)
  values(owner_row.id,'B2B:'||account_row.email,
    case when document_type='pedido' then 'CRIAR_PEDIDO_B2B' else 'CRIAR_COTACAO_B2B' end,
    case when document_type='pedido' then 'orders' else 'quotations' end,new_id::text,
    jsonb_build_object('source','B2B_PORTAL','client_id',client_row.id,'portal_user_id',account_row.user_id,
      'numero',document_number,'route',route_value,'items',idx,'total',round(total_value,2),'transfers',transfer_summary));

  return jsonb_build_object('id',new_id,
    case when document_type='pedido' then 'numero_pedido' else 'numero_cotacao' end,document_number,
    'total',round(total_value,2),'route',route_value,'transferencias',transfer_summary,'duplicate',false);
exception when invalid_text_representation or numeric_value_out_of_range then
  raise exception 'VALOR_B2B_INVALIDO';
end;
$$;

create or replace function public.b2b_list_documents(document_type text,limit_count integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare account_row public.customer_portal_accounts; result jsonb;
begin
  select * into account_row from public.customer_portal_accounts where user_id=auth.uid() and active;
  if account_row.user_id is null then raise exception 'ACESSO_B2B_NAO_AUTORIZADO'; end if;
  if document_type='pedido' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into result from (
      select id,numero_pedido as numero,data_hora,created_at,status::text,total,regiao::text,billing_uf,
        logistics_status,source_channel
      from public.orders where client_id=account_row.client_id
      order by created_at desc limit least(greatest(limit_count,1),100)
    ) x;
  elsif document_type='cotacao' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into result from (
      select id,numero_cotacao as numero,data_hora,created_at,status::text,total,regiao::text,billing_uf,source_channel
      from public.quotations where client_id=account_row.client_id
      order by created_at desc limit least(greatest(limit_count,1),100)
    ) x;
  else raise exception 'TIPO_DOCUMENTO_INVALIDO'; end if;
  return result;
end;
$$;

create or replace function public.b2b_get_document(document_type text,target_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare account_row public.customer_portal_accounts; result jsonb;
begin
  select * into account_row from public.customer_portal_accounts where user_id=auth.uid() and active;
  if account_row.user_id is null then raise exception 'ACESSO_B2B_NAO_AUTORIZADO'; end if;
  if document_type='pedido' then
    select jsonb_build_object(
      'id',o.id,'numero',o.numero_pedido,'created_at',o.created_at,'status',o.status,'total',o.total,
      'billing_uf',o.billing_uf,'observacao',o.observacao,
      'items',coalesce((select jsonb_agg(jsonb_build_object('item',i.item,'codigo',i.codigo,'descricao',i.descricao,
        'marca',i.marca,'aplicacao',i.aplicacao,'quantidade',i.quantidade,'preco_unitario',i.preco_unitario,
        'total_item',i.total_item) order by i.item) from public.order_items i where i.order_id=o.id),'[]'::jsonb)
    ) into result from public.orders o where o.id=target_id and o.client_id=account_row.client_id;
  elsif document_type='cotacao' then
    select jsonb_build_object(
      'id',q.id,'numero',q.numero_cotacao,'created_at',q.created_at,'status',q.status,'total',q.total,
      'billing_uf',q.billing_uf,'observacao',q.observacao,
      'items',coalesce((select jsonb_agg(jsonb_build_object('item',i.item,'codigo',i.codigo,'descricao',i.descricao,
        'marca',i.marca,'aplicacao',i.aplicacao,'quantidade',i.quantidade,'preco_unitario',i.preco_unitario,
        'total_item',i.total_item) order by i.item) from public.quotation_items i where i.quotation_id=q.id),'[]'::jsonb)
    ) into result from public.quotations q where q.id=target_id and q.client_id=account_row.client_id;
  else raise exception 'TIPO_DOCUMENTO_INVALIDO'; end if;
  if result is null then raise exception 'DOCUMENTO_B2B_NAO_ENCONTRADO'; end if;
  return result;
end;
$$;

revoke all on function public.b2b_search_catalog(text,boolean,integer),
  public.b2b_create_order_transfer_requests(uuid,uuid),public.b2b_create_document(text,jsonb),
  public.b2b_list_documents(text,integer),public.b2b_get_document(text,uuid)
  from public,anon,authenticated;
grant execute on function public.b2b_search_catalog(text,boolean,integer),
  public.b2b_create_document(text,jsonb),public.b2b_list_documents(text,integer),
  public.b2b_get_document(text,uuid) to authenticated;

comment on function public.b2b_search_catalog(text,boolean,integer) is
  'Catálogo B2B restrito à rota do cliente, com preço final aprovado e estoque importado.';
comment on function public.b2b_create_document(text,jsonb) is
  'Cria cotação ou pedido B2B idempotente usando exclusivamente cadastro e rota da conta autenticada.';

commit;
