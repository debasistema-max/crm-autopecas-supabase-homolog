begin;

set local lock_timeout = '10s';
set local statement_timeout = '110s';

alter table public.product_catalog_metadata
  add column if not exists catalog_details jsonb not null default '{}'::jsonb;

alter table public.product_catalog_metadata
  drop constraint if exists product_catalog_metadata_details_object_check;
alter table public.product_catalog_metadata
  add constraint product_catalog_metadata_details_object_check
    check(jsonb_typeof(catalog_details)='object' and octet_length(catalog_details::text)<=65536);

create or replace function public.sync_yokomitsu_catalog_metadata(records jsonb,p_source_version text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_batch public.catalog_metadata_sync_batches;
  v_item jsonb;
  v_code text;
  v_before public.product_catalog_metadata;
  v_after jsonb;
  v_details jsonb;
  v_applications text;
  v_product_exists boolean;
  v_inserted integer:=0;
  v_updated integer:=0;
  v_unchanged integer:=0;
  v_ignored integer:=0;
  v_matched integer:=0;
begin
  if not (
    coalesce(auth.role(),'')='service_role'
    or session_user in ('postgres','supabase_admin')
    or exists(select 1 from public.profiles p where p.id=auth.uid() and p.ativo and p.perfil='ADMIN')
  ) then raise exception 'SEM_PERMISSAO_SYNC_CATALOGO_YOKOMITSU'; end if;
  if jsonb_typeof(records)<>'array' or jsonb_array_length(records)=0 then raise exception 'REGISTROS_CATALOGO_INVALIDOS'; end if;
  if nullif(btrim(p_source_version),'') is null or length(p_source_version)>128 then raise exception 'VERSAO_CATALOGO_INVALIDA'; end if;

  select b.* into v_batch from public.catalog_metadata_sync_batches b
  where b.source='YOKOMITSU_CATALOG' and b.source_version=btrim(p_source_version);
  if v_batch.id is not null and v_batch.status='completed' then
    return v_batch.summary||jsonb_build_object('batch_id',v_batch.id,'idempotent',true);
  end if;

  insert into public.catalog_metadata_sync_batches(source,source_version,total_received)
  values('YOKOMITSU_CATALOG',btrim(p_source_version),jsonb_array_length(records))
  on conflict(source,source_version) do update set
    status='processing',started_at=now(),finished_at=null,total_received=excluded.total_received
  returning * into v_batch;

  for v_item in select value from jsonb_array_elements(records) loop
    v_code:=public.normalize_integration_product_code(v_item->>'product_code');
    select exists(select 1 from public.products p where p.codigo=v_code) into v_product_exists;
    if v_code is null or not v_product_exists then v_ignored:=v_ignored+1; continue; end if;
    v_matched:=v_matched+1;
    select * into v_before from public.product_catalog_metadata m where m.product_code=v_code;

    v_details:=case
      when v_item ? 'catalog_details' and jsonb_typeof(v_item->'catalog_details')='object'
        then v_item->'catalog_details'
      else coalesce(v_before.catalog_details,'{}'::jsonb)
    end;
    v_applications:=case
      when lower(coalesce(v_item->>'applications_complete','false'))='true'
        then nullif(left(btrim(v_item->>'applications'),12000),'')
      else coalesce(v_before.applications,nullif(left(btrim(v_item->>'applications'),12000),''))
    end;
    v_after:=jsonb_build_object(
      'product_name',nullif(left(btrim(v_item->>'product_name'),300),''),
      'line_name',nullif(left(btrim(v_item->>'line_name'),120),''),
      'line_slug',nullif(left(btrim(v_item->>'line_slug'),160),''),
      'applications',v_applications,
      'official_image_url',case
        when btrim(coalesce(v_item->>'official_image_url','')) ~ '^https://www[.]yokomitsu[.]com[.]br/uploads/products/'
          then left(btrim(v_item->>'official_image_url'),1000)
        else null end,
      'catalog_details',v_details,
      'source_product_updated_at',(nullif(v_item->>'source_product_updated_at','')::timestamptz)
    );

    if v_before.product_code is not null and jsonb_build_object(
      'product_name',v_before.product_name,'line_name',v_before.line_name,'line_slug',v_before.line_slug,
      'applications',v_before.applications,'official_image_url',v_before.official_image_url,
      'catalog_details',v_before.catalog_details,'source_product_updated_at',v_before.source_product_updated_at
    ) is not distinct from v_after then
      v_unchanged:=v_unchanged+1;
      continue;
    end if;

    insert into public.product_catalog_metadata_audit(batch_id,product_code,action,before_data,after_data)
    values(v_batch.id,v_code,case when v_before.product_code is null then 'insert' else 'update' end,
      case when v_before.product_code is null then null else to_jsonb(v_before)-'source_batch_id'-'source_synced_at'-'created_at'-'updated_at' end,
      v_after);

    insert into public.product_catalog_metadata(
      product_code,product_name,line_name,line_slug,applications,official_image_url,catalog_details,
      source_product_updated_at,source_synced_at,source_batch_id,updated_at
    ) values(
      v_code,v_after->>'product_name',v_after->>'line_name',v_after->>'line_slug',v_after->>'applications',
      v_after->>'official_image_url',v_after->'catalog_details',(v_after->>'source_product_updated_at')::timestamptz,
      now(),v_batch.id,now()
    ) on conflict(product_code) do update set
      product_name=excluded.product_name,line_name=excluded.line_name,line_slug=excluded.line_slug,
      applications=excluded.applications,official_image_url=excluded.official_image_url,
      catalog_details=excluded.catalog_details,source_product_updated_at=excluded.source_product_updated_at,
      source_synced_at=now(),source_batch_id=v_batch.id,updated_at=now();
    if v_before.product_code is null then v_inserted:=v_inserted+1; else v_updated:=v_updated+1; end if;
  end loop;

  update public.catalog_metadata_sync_batches set
    status='completed',matched_products=v_matched,inserted_rows=v_inserted,updated_rows=v_updated,
    unchanged_rows=v_unchanged,ignored_rows=v_ignored,finished_at=now(),
    summary=jsonb_build_object('received',jsonb_array_length(records),'matched',v_matched,
      'inserted',v_inserted,'updated',v_updated,'unchanged',v_unchanged,'ignored',v_ignored)
  where id=v_batch.id;
  return jsonb_build_object('batch_id',v_batch.id,'received',jsonb_array_length(records),
    'matched',v_matched,'inserted',v_inserted,'updated',v_updated,
    'unchanged',v_unchanged,'ignored',v_ignored,'idempotent',false);
end;
$$;

revoke all on function public.sync_yokomitsu_catalog_metadata(jsonb,text) from public,anon,authenticated;
grant execute on function public.sync_yokomitsu_catalog_metadata(jsonb,text) to service_role;

create or replace function public.b2b_search_catalog(search_term text,line_filter text,only_available boolean,limit_count integer)
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
    select p.codigo,coalesce(nullif(m.product_name,''),p.descricao) descricao,p.marca,
      coalesce(nullif(m.applications,''),nullif(btrim(concat_ws(' ',p.aplicacao,p.ano)),'')) aplicacao,p.ano,
      coalesce(nullif(p.url_imagem,''),m.official_image_url) url_imagem,rp.route,
      round(rp.final_price*(1-v_discount/100),4) final_price,rp.currency::text,
      lower(unaccent(concat_ws(' ',p.codigo,p.descricao,p.marca,p.aplicacao,p.ano,p.oem,p."similar",
        p.montadora,p.detalhes,p.search_text,m.product_name,m.applications,m.line_name,m.catalog_details::text))) search_document,
      lower(unaccent(concat_ws(' ',p.codigo,p.oem,p."similar"))) identifier_document,
      lower(unaccent(concat_ws(' ',p.descricao,m.product_name))) description_document,
      lower(unaccent(concat_ws(' ',p.aplicacao,p.ano,m.applications))) application_document,
      lower(unaccent(concat_ws(' ',p.marca,p.montadora))) brand_document
    from public.products p
    left join public.product_catalog_metadata m on m.product_code=p.codigo
    join public.product_route_prices rp on rp.product_code=p.codigo and rp.origin_branch_id=v_origin_id
      and rp.route=v_origin_code||'-'||v_client_state and rp.final_price>0
      and upper(coalesce(rp.calculation_status,'OK')) like 'OK%'
    where v_line_value='' or upper(btrim(unaccent(coalesce(m.line_name,p.categoria,''))))=v_line_value
  ), scored as (
    select e.*,score.matched_terms,
      score.identifier_terms*45+score.application_terms*25+score.description_terms*20+score.brand_terms*10 field_score,
      e.codigo=regexp_replace(v_search_value,'[[:space:]]+','','g') exact_code,
      e.search_document like '%'||v_search_value||'%' phrase_match
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

create or replace function public.b2b_get_catalog_product_detail(p_product_code text)
returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare
  v_account public.customer_portal_accounts;
  v_state text;
  v_origin text;
  v_branch uuid;
  v_pr_branch uuid;
  v_discount numeric:=0;
  v_code text:=public.normalize_integration_product_code(p_product_code);
  v_result jsonb;
begin
  select * into v_account from public.customer_portal_accounts where user_id=auth.uid() and active;
  if v_account.user_id is null then raise exception 'ACESSO_B2B_NAO_AUTORIZADO'; end if;
  if not v_account.can_view_prices then raise exception 'PRECO_B2B_NAO_AUTORIZADO'; end if;
  select upper(btrim(coalesce(c.estado,''))),coalesce(c.commercial_discount_percent,0)
    into v_state,v_discount from public.clients c where c.id=v_account.client_id and c.ativo;
  v_origin:=case v_state when 'SP' then 'SP' when 'PR' then 'PR' when 'SC' then 'PR' else null end;
  select id into v_branch from public.branches where code=v_origin and active;
  select id into v_pr_branch from public.branches where code='PR' and active;
  if v_branch is null then raise exception 'ROTA_B2B_NAO_CONFIGURADA'; end if;

  select jsonb_build_object(
    'product_code',p.codigo,
    'description',coalesce(nullif(m.product_name,''),p.descricao),
    'brand',p.marca,
    'application',coalesce(nullif(m.applications,''),nullif(btrim(concat_ws(' ',p.aplicacao,p.ano)),'')),
    'line',coalesce(nullif(m.line_name,''),p.categoria),
    'image_url',coalesce(nullif(p.url_imagem,''),m.official_image_url),
    'details',coalesce(m.catalog_details,'{}'::jsonb),
    'route',rp.route,
    'final_price',round(rp.final_price*(1-v_discount/100),4),
    'currency',rp.currency::text,
    'availability',case
      when s.product_code is null or (s.source_batch_id is null and coalesce(s.version,0)=0) then 'NAO_IMPORTADO'
      when s.available_qty>0 then 'DISPONIVEL'
      when v_origin='SP' and pr.available_qty>0 and not(pr.source_batch_id is null and coalesce(pr.version,0)=0) then 'TRANSFERENCIA_PR'
      else 'INDISPONIVEL' end,
    'available_qty',case when v_account.can_view_stock and s.product_code is not null
      and not(s.source_batch_id is null and coalesce(s.version,0)=0) then s.available_qty end,
    'source_display_value',case when v_account.can_view_stock and s.product_code is not null
      and not(s.source_batch_id is null and coalesce(s.version,0)=0)
      then coalesce(nullif(s.source_display_value,''),trim(to_char(s.available_qty,'FM999999999999990.###'))) end,
    'pr_transfer_available_qty',case when v_account.can_view_stock and v_origin='SP' and pr.product_code is not null
      and not(pr.source_batch_id is null and coalesce(pr.version,0)=0) then pr.available_qty end
  ) into v_result
  from public.products p
  left join public.product_catalog_metadata m on m.product_code=p.codigo
  join public.product_route_prices rp on rp.product_code=p.codigo and rp.origin_branch_id=v_branch
    and rp.route=v_origin||'-'||v_state and rp.final_price>0
    and upper(coalesce(rp.calculation_status,'OK')) like 'OK%'
  left join public.product_branch_stock s on s.product_code=p.codigo and s.branch_id=v_branch
  left join public.product_branch_stock pr on pr.product_code=p.codigo and pr.branch_id=v_pr_branch
  where p.codigo=v_code;
  if v_result is null then raise exception 'PRODUTO_B2B_NAO_DISPONIVEL'; end if;
  return v_result;
end;
$$;

create or replace function public.snapshot_b2b_item_application()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_source text; v_application text;
begin
  if tg_table_name='order_items' then
    select o.source_channel into v_source from public.orders o where o.id=new.order_id;
  else
    select q.source_channel into v_source from public.quotations q where q.id=new.quotation_id;
  end if;
  if v_source='B2B_PORTAL' then
    select nullif(m.applications,'') into v_application from public.product_catalog_metadata m where m.product_code=new.codigo;
    new.aplicacao:=coalesce(v_application,new.aplicacao);
  end if;
  return new;
end;
$$;

drop trigger if exists order_items_snapshot_b2b_application on public.order_items;
create trigger order_items_snapshot_b2b_application before insert on public.order_items
for each row execute function public.snapshot_b2b_item_application();
drop trigger if exists quotation_items_snapshot_b2b_application on public.quotation_items;
create trigger quotation_items_snapshot_b2b_application before insert on public.quotation_items
for each row execute function public.snapshot_b2b_item_application();

create or replace function public.b2b_get_document(document_type text,target_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare account_row public.customer_portal_accounts; result jsonb;
begin
  select * into account_row from public.customer_portal_accounts where user_id=auth.uid() and active;
  if account_row.user_id is null then raise exception 'ACESSO_B2B_NAO_AUTORIZADO'; end if;
  if document_type='pedido' then
    select jsonb_build_object(
      'id',o.id,'numero',o.numero_pedido,'created_at',o.created_at,'status',o.status,'total',o.total,
      'billing_uf',o.billing_uf,'observacao',o.observacao,
      'items',coalesce((select jsonb_agg(jsonb_build_object('item',i.item,'codigo',i.codigo,'descricao',i.descricao,
        'marca',i.marca,'aplicacao',coalesce(nullif(m.applications,''),i.aplicacao),'quantidade',i.quantidade,
        'preco_unitario',i.preco_unitario,'total_item',i.total_item) order by i.item)
        from public.order_items i left join public.product_catalog_metadata m on m.product_code=i.codigo
        where i.order_id=o.id),'[]'::jsonb)
    ) into result from public.orders o where o.id=target_id and o.client_id=account_row.client_id;
  elsif document_type='cotacao' then
    select jsonb_build_object(
      'id',q.id,'numero',q.numero_cotacao,'created_at',q.created_at,'status',q.status,'total',q.total,
      'billing_uf',q.billing_uf,'observacao',q.observacao,
      'items',coalesce((select jsonb_agg(jsonb_build_object('item',i.item,'codigo',i.codigo,'descricao',i.descricao,
        'marca',i.marca,'aplicacao',coalesce(nullif(m.applications,''),i.aplicacao),'quantidade',i.quantidade,
        'preco_unitario',i.preco_unitario,'total_item',i.total_item) order by i.item)
        from public.quotation_items i left join public.product_catalog_metadata m on m.product_code=i.codigo
        where i.quotation_id=q.id),'[]'::jsonb)
    ) into result from public.quotations q where q.id=target_id and q.client_id=account_row.client_id;
  else raise exception 'TIPO_DOCUMENTO_INVALIDO'; end if;
  if result is null then raise exception 'DOCUMENTO_B2B_NAO_ENCONTRADO'; end if;
  return result;
end;
$$;

revoke all on function public.b2b_search_catalog(text,text,boolean,integer),
  public.b2b_get_catalog_product_detail(text),public.snapshot_b2b_item_application(),
  public.b2b_get_document(text,uuid) from public,anon,authenticated;
grant execute on function public.b2b_search_catalog(text,text,boolean,integer),
  public.b2b_get_catalog_product_detail(text),public.b2b_get_document(text,uuid) to authenticated;

comment on column public.product_catalog_metadata.catalog_details is
  'Snapshot técnico público da ficha Yokomitsu; não substitui cadastro, preço ou regra fiscal.';
comment on function public.b2b_get_catalog_product_detail(text) is
  'Retorna ficha detalhada persistida, preço líquido e estoque somente para a rota do cliente B2B.';

commit;
