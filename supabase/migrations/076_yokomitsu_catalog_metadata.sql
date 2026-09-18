begin;

set local lock_timeout = '10s';
set local statement_timeout = '110s';

create table if not exists public.catalog_metadata_sync_batches (
  id uuid primary key default gen_random_uuid(),
  source text not null default 'YOKOMITSU_CATALOG',
  source_version text not null,
  status text not null default 'processing',
  total_received integer not null default 0,
  matched_products integer not null default 0,
  inserted_rows integer not null default 0,
  updated_rows integer not null default 0,
  unchanged_rows integer not null default 0,
  ignored_rows integer not null default 0,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  summary jsonb not null default '{}'::jsonb,
  constraint catalog_metadata_sync_batches_source_version_uidx unique(source,source_version),
  constraint catalog_metadata_sync_batches_status_check
    check(status in ('processing','completed','completed_with_errors','failed'))
);

create table if not exists public.product_catalog_metadata (
  product_code text primary key references public.products(codigo) on update cascade on delete cascade,
  product_name text,
  line_name text,
  line_slug text,
  applications text,
  official_image_url text,
  source text not null default 'YOKOMITSU_CATALOG',
  source_product_updated_at timestamptz,
  source_synced_at timestamptz not null default now(),
  source_batch_id uuid references public.catalog_metadata_sync_batches(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint product_catalog_metadata_source_check check(source='YOKOMITSU_CATALOG'),
  constraint product_catalog_metadata_image_check check(
    official_image_url is null
    or official_image_url ~ '^https://www[.]yokomitsu[.]com[.]br/uploads/products/'
  )
);

create index if not exists product_catalog_metadata_line_idx
  on public.product_catalog_metadata(line_name,product_code);

create table if not exists public.product_catalog_metadata_audit (
  id bigint generated always as identity primary key,
  batch_id uuid not null references public.catalog_metadata_sync_batches(id) on delete restrict,
  product_code text not null references public.products(codigo) on update cascade on delete restrict,
  action text not null,
  before_data jsonb,
  after_data jsonb not null,
  created_at timestamptz not null default now(),
  constraint product_catalog_metadata_audit_action_check check(action in ('insert','update'))
);

create index if not exists product_catalog_metadata_audit_batch_idx
  on public.product_catalog_metadata_audit(batch_id,product_code);

alter table public.catalog_metadata_sync_batches enable row level security;
alter table public.product_catalog_metadata enable row level security;
alter table public.product_catalog_metadata_audit enable row level security;
revoke all on public.catalog_metadata_sync_batches,public.product_catalog_metadata,
  public.product_catalog_metadata_audit from public,anon,authenticated;

create or replace function public.sync_yokomitsu_catalog_metadata(
  records jsonb,
  p_source_version text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch public.catalog_metadata_sync_batches;
  v_item jsonb;
  v_code text;
  v_before public.product_catalog_metadata;
  v_after jsonb;
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
  if jsonb_typeof(records)<>'array' or jsonb_array_length(records)=0 then
    raise exception 'REGISTROS_CATALOGO_INVALIDOS';
  end if;
  if nullif(btrim(p_source_version),'') is null or length(p_source_version)>128 then
    raise exception 'VERSAO_CATALOGO_INVALIDA';
  end if;

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
    if v_code is null or not v_product_exists then
      v_ignored:=v_ignored+1;
      continue;
    end if;
    v_matched:=v_matched+1;
    select * into v_before from public.product_catalog_metadata m where m.product_code=v_code;
    v_after:=jsonb_build_object(
      'product_name',nullif(left(btrim(v_item->>'product_name'),300),''),
      'line_name',nullif(left(btrim(v_item->>'line_name'),120),''),
      'line_slug',nullif(left(btrim(v_item->>'line_slug'),160),''),
      'applications',nullif(left(btrim(v_item->>'applications'),1200),''),
      'official_image_url',case
        when btrim(coalesce(v_item->>'official_image_url','')) ~ '^https://www[.]yokomitsu[.]com[.]br/uploads/products/'
          then left(btrim(v_item->>'official_image_url'),1000)
        else null end,
      'source_product_updated_at',(nullif(v_item->>'source_product_updated_at','')::timestamptz)
    );

    if v_before.product_code is not null and
      jsonb_build_object(
        'product_name',v_before.product_name,'line_name',v_before.line_name,'line_slug',v_before.line_slug,
        'applications',v_before.applications,'official_image_url',v_before.official_image_url,
        'source_product_updated_at',v_before.source_product_updated_at
      ) is not distinct from v_after then
      v_unchanged:=v_unchanged+1;
      continue;
    end if;

    insert into public.product_catalog_metadata_audit(batch_id,product_code,action,before_data,after_data)
    values(v_batch.id,v_code,case when v_before.product_code is null then 'insert' else 'update' end,
      case when v_before.product_code is null then null else to_jsonb(v_before)-'source_batch_id'-'source_synced_at'-'created_at'-'updated_at' end,
      v_after);

    insert into public.product_catalog_metadata(
      product_code,product_name,line_name,line_slug,applications,official_image_url,
      source_product_updated_at,source_synced_at,source_batch_id,updated_at
    ) values(
      v_code,v_after->>'product_name',v_after->>'line_name',v_after->>'line_slug',
      v_after->>'applications',v_after->>'official_image_url',
      (v_after->>'source_product_updated_at')::timestamptz,now(),v_batch.id,now()
    ) on conflict(product_code) do update set
      product_name=excluded.product_name,line_name=excluded.line_name,line_slug=excluded.line_slug,
      applications=excluded.applications,official_image_url=excluded.official_image_url,
      source_product_updated_at=excluded.source_product_updated_at,source_synced_at=now(),
      source_batch_id=v_batch.id,updated_at=now();
    if v_before.product_code is null then v_inserted:=v_inserted+1; else v_updated:=v_updated+1; end if;
  end loop;

  update public.catalog_metadata_sync_batches set
    status='completed',
    matched_products=v_matched,inserted_rows=v_inserted,updated_rows=v_updated,
    unchanged_rows=v_unchanged,ignored_rows=v_ignored,finished_at=now(),
    summary=jsonb_build_object('received',jsonb_array_length(records),'matched',v_matched,
      'inserted',v_inserted,'updated',v_updated,'unchanged',v_unchanged,'ignored',v_ignored)
  where id=v_batch.id;
  return jsonb_build_object('batch_id',v_batch.id,'received',jsonb_array_length(records),
    'matched',v_matched,'inserted',v_inserted,'updated',v_updated,
    'unchanged',v_unchanged,'ignored',v_ignored,'idempotent',false);
end;
$$;

revoke all on function public.sync_yokomitsu_catalog_metadata(jsonb,text)
  from public,anon,authenticated;

create or replace function public.b2b_search_catalog(
  search_term text,
  line_filter text,
  only_available boolean,
  limit_count integer
)
returns table(
  product_code text,description text,brand text,application text,year text,image_url text,
  route text,final_price numeric,currency text,availability text,available_qty numeric,
  source_display_value text,pr_transfer_available_qty numeric,stock_updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_account public.customer_portal_accounts;
  v_client_state text;
  v_origin_code text;
  v_origin_id uuid;
  v_search_value text:=left(regexp_replace(lower(unaccent(btrim(coalesce(search_term,'')))),'[^a-z0-9]+',' ','g'),100);
  v_line_value text:=upper(btrim(unaccent(coalesce(line_filter,''))));
  v_tokens text[];
begin
  v_search_value:=btrim(regexp_replace(v_search_value,'[[:space:]]+',' ','g'));
  v_tokens:=case when v_search_value='' then array[]::text[] else regexp_split_to_array(v_search_value,'[[:space:]]+') end;
  select * into v_account from public.customer_portal_accounts where user_id=auth.uid() and active;
  if v_account.user_id is null then raise exception 'ACESSO_B2B_NAO_AUTORIZADO'; end if;
  if not v_account.can_view_prices then raise exception 'PRECO_B2B_NAO_AUTORIZADO'; end if;
  select upper(btrim(coalesce(c.estado,''))) into v_client_state from public.clients c where c.id=v_account.client_id and c.ativo;
  v_origin_code:=case v_client_state when 'SP' then 'SP' when 'PR' then 'PR' when 'SC' then 'PR' else null end;
  if v_origin_code is null then raise exception 'ROTA_B2B_NAO_CONFIGURADA'; end if;
  select b.id into v_origin_id from public.branches b where b.code=v_origin_code and b.active;
  if v_origin_id is null then raise exception 'FILIAL_B2B_NAO_CONFIGURADA'; end if;

  return query
  with eligible as (
    select p.codigo,p.descricao,p.marca,p.aplicacao,p.ano,
      coalesce(nullif(p.url_imagem,''),m.official_image_url) as url_imagem,
      rp.route,rp.final_price,rp.currency::text,
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
    from eligible e
    cross join lateral (
      select count(*) filter(where e.search_document like '%'||t.token||'%')::integer matched_terms,
        count(*) filter(where e.identifier_document like '%'||t.token||'%')::integer identifier_terms,
        count(*) filter(where e.application_document like '%'||t.token||'%')::integer application_terms,
        count(*) filter(where e.description_document like '%'||t.token||'%')::integer description_terms,
        count(*) filter(where e.brand_document like '%'||t.token||'%')::integer brand_terms
      from unnest(v_tokens) t(token)
    ) score
    where v_search_value='' or score.matched_terms=cardinality(v_tokens)
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
  from catalog c
  where not only_available or c.availability in ('DISPONIVEL','TRANSFERENCIA_PR')
  order by c.exact_code desc,c.phrase_match desc,c.matched_terms desc,c.field_score desc,c.codigo
  limit least(greatest(limit_count,1),50);
end;
$$;

create or replace function public.b2b_list_catalog_lines()
returns table(value text,label text)
language plpgsql stable security definer set search_path=public
as $$
declare
  v_account public.customer_portal_accounts;
  v_state text;
  v_origin text;
  v_branch uuid;
begin
  select * into v_account from public.customer_portal_accounts where user_id=auth.uid() and active;
  if v_account.user_id is null then raise exception 'ACESSO_B2B_NAO_AUTORIZADO'; end if;
  select upper(btrim(coalesce(c.estado,''))) into v_state from public.clients c where c.id=v_account.client_id and c.ativo;
  v_origin:=case v_state when 'SP' then 'SP' when 'PR' then 'PR' when 'SC' then 'PR' else null end;
  select b.id into v_branch from public.branches b where b.code=v_origin and b.active;
  if v_branch is null then raise exception 'ROTA_B2B_NAO_CONFIGURADA'; end if;
  return query
  select distinct btrim(coalesce(m.line_name,p.categoria)),btrim(coalesce(m.line_name,p.categoria))
  from public.products p
  left join public.product_catalog_metadata m on m.product_code=p.codigo
  join public.product_route_prices rp on rp.product_code=p.codigo and rp.origin_branch_id=v_branch
    and rp.route=v_origin||'-'||v_state and rp.final_price>0
    and upper(coalesce(rp.calculation_status,'OK')) like 'OK%'
  where nullif(btrim(coalesce(m.line_name,p.categoria)),'') is not null order by 2;
end;
$$;

revoke all on function public.b2b_search_catalog(text,text,boolean,integer),public.b2b_list_catalog_lines()
  from public,anon,authenticated;
grant execute on function public.b2b_search_catalog(text,text,boolean,integer),public.b2b_list_catalog_lines()
  to authenticated;

comment on table public.product_catalog_metadata is
  'Snapshot desacoplado de linha, aplicação e foto do catálogo público Yokomitsu por código IPS.';
comment on function public.sync_yokomitsu_catalog_metadata(jsonb,text) is
  'Sincroniza metadados públicos do catálogo com idempotência, batch e auditoria por produto.';

commit;
