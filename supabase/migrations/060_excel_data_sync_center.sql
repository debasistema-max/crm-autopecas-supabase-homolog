begin;

set local lock_timeout = '10s';
set local statement_timeout = '180s';

-- Data Sync v1 extends the existing branch/import foundation. It deliberately
-- keeps stock and base prices in their canonical tables and stores only the
-- distinct, consolidated fiscal result by commercial route in a new table.
do $required_foundation$
begin
  if to_regclass('public.products') is null
     or to_regclass('public.branches') is null
     or to_regclass('public.product_branch_stock') is null
     or to_regclass('public.product_branch_prices') is null
     or to_regclass('public.products_import_batches') is null
     or to_regclass('public.products_import_stage') is null
     or to_regclass('public.products_import_audit') is null then
    raise exception using
      errcode = 'P6001',
      message = 'DATA_SYNC_FOUNDATION_MISSING';
  end if;
end
$required_foundation$;

alter table public.products_import_batches
  add column if not exists integration_source text not null default 'IMPORT_MANUAL',
  add column if not exists source_version text,
  add column if not exists source_updated_at timestamptz,
  add column if not exists started_at timestamptz,
  add column if not exists finished_at timestamptz,
  add column if not exists next_sync_at timestamptz,
  add column if not exists inserted_rows integer not null default 0,
  add column if not exists updated_rows integer not null default 0,
  add column if not exists unchanged_rows integer not null default 0,
  add column if not exists ignored_rows integer not null default 0,
  add column if not exists stale_rows integer not null default 0;

alter table public.products_import_batches
  drop constraint if exists products_import_batches_contract_check;
alter table public.products_import_batches
  add constraint products_import_batches_contract_check
  check (contract_version in (0, 1, 2, 3));

alter table public.products_import_batches
  drop constraint if exists products_import_batches_v2_required_check;
alter table public.products_import_batches
  add constraint products_import_batches_v2_required_check check (
    contract_version = 0
    or (contract_version = 1
      and branch_id is not null
      and mode in ('UPDATE_STOCK','UPDATE_PRICES','CREATE_PRODUCTS','CUSTOM_UPDATE','FULL_IMPORT')
      and cardinality(field_mask) > 0
      and normalization_algorithm = 'branch-import-v1'
      and hash_algorithm = 'SHA-256'
      and (state in ('DRAFT','FAILED') or (normalized_file_hash is not null and idempotency_key is not null)))
    or (contract_version = 2
      and import_kind in ('COMMERCIAL_PRODUCTS','SAP_ITEM_MASTER','STOCK_PR','STOCK_SP','BASE_PRICE_PR','BASE_PRICE_SP','FISCAL_RULES_PR','FISCAL_RULES_SP')
      and normalization_algorithm in ('sap-import-v2','sap-import-v3')
      and hash_algorithm = 'SHA-256')
    or (contract_version = 3
      and import_kind = 'EXCEL_MASTER'
      and integration_source in ('EXCEL_API','SAP','GOOGLE_SHEETS','IMPORT_MANUAL')
      and normalization_algorithm = 'data-sync-v1'
      and hash_algorithm = 'SHA-256'
      and source_version is not null
      and source_updated_at is not null
      and idempotency_key is not null)
  );

alter table public.products_import_batches
  drop constraint if exists products_import_batches_v3_counts_check;
alter table public.products_import_batches
  add constraint products_import_batches_v3_counts_check check (
    inserted_rows >= 0 and updated_rows >= 0 and unchanged_rows >= 0
    and ignored_rows >= 0 and stale_rows >= 0
  );

alter table public.products_import_batches
  drop constraint if exists products_import_batches_v3_status_check;
alter table public.products_import_batches
  add constraint products_import_batches_v3_status_check check (
    contract_version <> 3
    or status in ('pending','processing','completed','completed_with_errors','failed')
  );

create unique index if not exists products_import_batches_v3_idempotency_idx
  on public.products_import_batches (idempotency_key)
  where contract_version = 3;
create index if not exists products_import_batches_v3_source_status_idx
  on public.products_import_batches (integration_source, status, created_at desc)
  where contract_version = 3;

alter table public.products_import_stage
  add column if not exists sync_area text,
  add column if not exists branch_code text,
  add column if not exists route text,
  add column if not exists source_version text,
  add column if not exists source_updated_at timestamptz,
  add column if not exists clear_fields text[] not null default '{}'::text[],
  add column if not exists changed_fields text[] not null default '{}'::text[],
  add column if not exists skip_reason text;

alter table public.products_import_stage
  drop constraint if exists products_import_stage_sync_area_check;
alter table public.products_import_stage
  add constraint products_import_stage_sync_area_check check (
    sync_area is null or sync_area in ('PRODUCT','STOCK','BASE_PRICE','ROUTE_PRICE')
  );

create index if not exists products_import_stage_sync_filters_idx
  on public.products_import_stage (batch_id, sync_area, branch_code, status, normalized_code)
  where sync_area is not null;

alter table public.products_import_audit
  add column if not exists source text,
  add column if not exists source_version text,
  add column if not exists source_updated_at timestamptz,
  add column if not exists route text,
  add column if not exists status text not null default 'applied';

create index if not exists products_import_audit_sync_lookup_idx
  on public.products_import_audit (batch_id, entity_type, branch_id, route, codigo, field_name, created_at desc);

alter table public.products
  add column if not exists sync_source text,
  add column if not exists sync_source_version text,
  add column if not exists sync_source_updated_at timestamptz,
  add column if not exists sync_batch_id uuid references public.products_import_batches(id) on delete set null;

alter table public.product_sap_data
  add column if not exists source_version text,
  add column if not exists source_updated_at timestamptz;

alter table public.product_branch_stock
  add column if not exists source_system text,
  add column if not exists source_version text;

alter table public.product_branch_prices
  add column if not exists source_version text,
  add column if not exists source_updated_at timestamptz;

alter table public.product_branch_prices
  drop constraint if exists product_branch_prices_source_check;
alter table public.product_branch_prices
  add constraint product_branch_prices_source_check
  check (source in ('LEGACY_BACKFILL','LEGACY_SYNC','BRANCH_IMPORT_V2','MANUAL','EXCEL_API','SAP','GOOGLE_SHEETS','IMPORT_MANUAL'));

alter table public.product_branch_prices
  drop constraint if exists product_branch_prices_batch_source_check;
alter table public.product_branch_prices
  add constraint product_branch_prices_batch_source_check check (
    (source in ('BRANCH_IMPORT_V2','EXCEL_API','SAP','GOOGLE_SHEETS','IMPORT_MANUAL') and source_batch_id is not null)
    or (source in ('LEGACY_BACKFILL','LEGACY_SYNC','MANUAL') and source_batch_id is null)
  );

alter table public.stock_movements
  drop constraint if exists stock_movements_type_check;
alter table public.stock_movements
  add constraint stock_movements_type_check check (movement_type in (
    'MIGRACAO_ESTOQUE_LEGADO','IMPORTACAO_ESTOQUE','SYNC_ERP',
    'RESERVA_PEDIDO','LIBERACAO_RESERVA_PEDIDO','RESERVA_TRANSFERENCIA',
    'LIBERACAO_TRANSFERENCIA','SAIDA_TRANSFERENCIA','ENTRADA_TRANSITO',
    'BAIXA_TRANSITO','ENTRADA_TRANSFERENCIA','ENTRADA_QUARENTENA',
    'LIBERACAO_QUARENTENA','AJUSTE','ESTORNO'
  ));

create table if not exists public.data_sync_sources (
  source_code text primary key,
  display_name text not null,
  adapter_type text not null,
  enabled boolean not null default true,
  connection_status text not null default 'UNKNOWN',
  last_seen_at timestamptz,
  last_success_at timestamptz,
  last_error_at timestamptz,
  last_error text,
  next_sync_at timestamptz,
  public_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint data_sync_sources_code_check check (source_code ~ '^[A-Z][A-Z0-9_]{1,39}$'),
  constraint data_sync_sources_status_check check (connection_status in ('UNKNOWN','CONNECTED','DEGRADED','DISCONNECTED')),
  constraint data_sync_sources_adapter_check check (adapter_type in ('HTTP_ADAPTER','MANUAL','SAP_API','GOOGLE_SHEETS_API'))
);

insert into public.data_sync_sources (source_code, display_name, adapter_type, enabled)
values ('EXCEL_API','Excel Mestre / API','HTTP_ADAPTER',true)
on conflict (source_code) do nothing;

create table if not exists public.product_route_prices (
  product_code text not null references public.products(codigo) on update cascade on delete restrict,
  origin_branch_id uuid not null references public.branches(id) on delete restrict,
  destination_state text not null,
  route text not null,
  base_price numeric(14,4),
  final_price numeric(14,4) not null,
  total_taxes numeric(14,4),
  tax_breakdown jsonb not null default '{}'::jsonb,
  calculation_status text not null default 'OK',
  currency char(3) not null default 'BRL',
  version bigint not null default 1,
  source text not null,
  source_version text not null,
  source_updated_at timestamptz not null,
  source_batch_id uuid not null references public.products_import_batches(id) on delete restrict,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (product_code, route),
  constraint product_route_prices_route_check check (route ~ '^[A-Z]{2}-[A-Z]{2}$'),
  constraint product_route_prices_destination_check check (destination_state ~ '^[A-Z]{2}$' and right(route,2) = destination_state),
  constraint product_route_prices_values_check check (
    final_price >= 0 and (base_price is null or base_price >= 0) and (total_taxes is null or total_taxes >= 0)
  ),
  constraint product_route_prices_currency_check check (currency ~ '^[A-Z]{3}$'),
  constraint product_route_prices_version_check check (version >= 1),
  constraint product_route_prices_source_check check (source in ('EXCEL_API','SAP','GOOGLE_SHEETS','IMPORT_MANUAL'))
);

create index if not exists product_route_prices_route_price_idx
  on public.product_route_prices (route, final_price, product_code);
create index if not exists product_route_prices_source_batch_idx
  on public.product_route_prices (source_batch_id, product_code, route);

create or replace function public.touch_product_route_price()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if row(new.base_price,new.final_price,new.total_taxes,new.tax_breakdown,new.calculation_status,
         new.currency,new.source,new.source_version,new.source_updated_at,new.source_batch_id)
     is not distinct from
     row(old.base_price,old.final_price,old.total_taxes,old.tax_breakdown,old.calculation_status,
         old.currency,old.source,old.source_version,old.source_updated_at,old.source_batch_id) then
    new.version := old.version;
    new.updated_at := old.updated_at;
    new.updated_by := old.updated_by;
    return new;
  end if;
  new.version := old.version + 1;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists data_sync_sources_touch_updated_at on public.data_sync_sources;
create trigger data_sync_sources_touch_updated_at
before update on public.data_sync_sources
for each row execute function public.touch_updated_at();

drop trigger if exists product_route_prices_touch on public.product_route_prices;
create trigger product_route_prices_touch
before update on public.product_route_prices
for each row execute function public.touch_product_route_price();

create or replace function public.can_manage_data_sync()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(auth.role(),'') = 'service_role'
    or exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.ativo and p.perfil = 'ADMIN'
    )
$$;

create or replace function public.can_view_data_sync()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.can_manage_data_sync()
    or exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.ativo and p.perfil = 'SUPERVISOR'
        and (public.has_module('alimentacao') or public.has_module('visualizar_lotes_importacao'))
    )
$$;

create or replace function public.normalize_integration_product_code(value_text text)
returns text
language plpgsql
immutable
parallel safe
set search_path = public
as $$
declare
  v_text text;
  v_number numeric;
begin
  v_text := regexp_replace(translate(coalesce(value_text,''), chr(8203)||chr(65279), ''), '[[:space:]]+', '', 'g');
  if v_text = '' then return null; end if;
  if v_text ~ '^[0-9]+[.,]0+$' then
    return regexp_replace(v_text, '[.,]0+$', '');
  end if;
  if v_text ~* '^[0-9]+([.,][0-9]+)?e[+]?[0-9]+$' then
    begin
      v_number := replace(v_text, ',', '.')::numeric;
      if v_number <> trunc(v_number) then return null; end if;
      return trunc(v_number)::text;
    exception when invalid_text_representation or numeric_value_out_of_range then
      return null;
    end;
  end if;
  if length(v_text) > 80 or v_text !~ '^[[:alnum:]_.\/-]+$' then return null; end if;
  return v_text;
end;
$$;

create or replace function public.data_sync_allowed_fields(target_area text)
returns text[]
language sql
immutable
parallel safe
as $$
  select case upper(target_area)
    when 'PRODUCT' then array[
      'description','brand','application','year','ncm','cest','ipi_rate','origin_code',
      'origin_description','material_group','fiscal_group','group','model','oem_01',
      'manufacturer','item_group','sales_unit','barcode','weight','volume','item_notes'
    ]::text[]
    when 'STOCK' then array[
      'stock_qty','confirmed_qty','sales_available_qty','authorized_pending_qty',
      'general_available_qty','general_available_capped','source_display_value'
    ]::text[]
    when 'BASE_PRICE' then array['base_price','currency']::text[]
    when 'ROUTE_PRICE' then array[
      'base_price','final_price','total_taxes','tax_breakdown','calculation_status','currency'
    ]::text[]
    else '{}'::text[] end
$$;

create or replace function public.normalize_data_sync_fields(
  target_area text,
  input_data jsonb,
  requested_fields text[],
  requested_clears text[] default '{}'::text[]
)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_area text := upper(coalesce(target_area,''));
  v_field text;
  v_text text;
  v_number numeric;
  v_allowed text[] := public.data_sync_allowed_fields(target_area);
  v_clearable constant text[] := array[
    'brand','application','year','ncm','cest','origin_code','origin_description',
    'material_group','fiscal_group','group','model','oem_01','manufacturer','item_group',
    'sales_unit','barcode','item_notes','source_display_value'
  ];
  v_data jsonb := '{}'::jsonb;
  v_errors jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_effective text[] := '{}'::text[];
begin
  if jsonb_typeof(coalesce(input_data,'{}'::jsonb)) <> 'object' then
    return jsonb_build_object('data','{}'::jsonb,'effective_fields','[]'::jsonb,
      'errors',jsonb_build_array('FIELDS_INVALIDO'),'warnings','[]'::jsonb);
  end if;
  for v_field in select distinct lower(btrim(value)) from unnest(coalesce(requested_fields,'{}'::text[])) value order by 1 loop
    if not (v_field = any(v_allowed)) then
      v_errors := v_errors || jsonb_build_array('CAMPO_NAO_PERMITIDO:'||v_field);
      continue;
    end if;
    if not input_data ? v_field then
      v_warnings := v_warnings || jsonb_build_array('CAMPO_AUSENTE_IGNORADO:'||v_field);
      continue;
    end if;
    if jsonb_typeof(input_data->v_field) = 'string' and btrim(input_data->>v_field) like '=%' then
      v_errors := v_errors || jsonb_build_array('FORMULA_NAO_PERMITIDA:'||v_field);
      continue;
    end if;
    v_text := nullif(btrim(input_data->>v_field),'');
    if jsonb_typeof(input_data->v_field) = 'null' or v_text is null then
      if v_field = any(coalesce(requested_clears,'{}'::text[])) and v_field = any(v_clearable) then
        v_data := v_data || jsonb_build_object(v_field,null);
        v_effective := array_append(v_effective,v_field);
      elsif v_field = any(coalesce(requested_clears,'{}'::text[])) then
        v_errors := v_errors || jsonb_build_array('LIMPEZA_NAO_PERMITIDA:'||v_field);
      else
        v_warnings := v_warnings || jsonb_build_array('VAZIO_IGNORADO:'||v_field);
      end if;
      continue;
    end if;

    if v_field in ('stock_qty','confirmed_qty','sales_available_qty','authorized_pending_qty',
                   'general_available_qty','base_price','final_price','total_taxes','ipi_rate','weight','volume') then
      v_number := public.parse_sap_decimal(v_text);
      if v_number is null then
        v_errors := v_errors || jsonb_build_array('NUMERO_INVALIDO:'||v_field);
        continue;
      end if;
      if v_number < 0 then
        v_errors := v_errors || jsonb_build_array('NUMERO_NEGATIVO:'||v_field);
        continue;
      end if;
      if v_field = 'ipi_rate' and v_number > 10 then
        v_errors := v_errors || jsonb_build_array('PERCENTUAL_FORA_FAIXA:'||v_field);
        continue;
      end if;
      v_data := v_data || jsonb_build_object(v_field,v_number);
    elsif v_field = 'ncm' then
      v_text := public.normalize_ncm(v_text);
      if v_text is null then v_errors := v_errors || jsonb_build_array('NCM_INVALIDO'); continue; end if;
      v_data := v_data || jsonb_build_object(v_field,v_text);
    elsif v_field = 'cest' then
      v_text := public.normalize_cest(v_text);
      if v_text is null then v_errors := v_errors || jsonb_build_array('CEST_INVALIDO'); continue; end if;
      v_data := v_data || jsonb_build_object(v_field,v_text);
    elsif v_field = 'currency' then
      v_text := upper(v_text);
      if v_text !~ '^[A-Z]{3}$' then v_errors := v_errors || jsonb_build_array('MOEDA_INVALIDA'); continue; end if;
      v_data := v_data || jsonb_build_object(v_field,v_text);
    elsif v_field = 'general_available_capped' then
      if lower(v_text) not in ('true','false','1','0','sim','nao','não') then
        v_errors := v_errors || jsonb_build_array('BOOLEANO_INVALIDO:'||v_field); continue;
      end if;
      v_data := v_data || jsonb_build_object(v_field,lower(v_text) in ('true','1','sim'));
    elsif v_field = 'tax_breakdown' then
      if jsonb_typeof(input_data->v_field) <> 'object' then
        v_errors := v_errors || jsonb_build_array('MEMORIA_FISCAL_INVALIDA'); continue;
      end if;
      v_data := v_data || jsonb_build_object(v_field,input_data->v_field);
    elsif v_field = 'calculation_status' then
      v_data := v_data || jsonb_build_object(v_field,upper(v_text));
    else
      v_data := v_data || jsonb_build_object(v_field,v_text);
    end if;
    v_effective := array_append(v_effective,v_field);
  end loop;
  for v_field in select unnest(coalesce(requested_clears,'{}'::text[])) loop
    if not (v_field = any(coalesce(requested_fields,'{}'::text[]))) then
      v_errors := v_errors || jsonb_build_array('LIMPEZA_FORA_DA_MASCARA:'||v_field);
    end if;
  end loop;
  return jsonb_build_object(
    'data',v_data,
    'effective_fields',to_jsonb(v_effective),
    'errors',v_errors,
    'warnings',v_warnings
  );
end;
$$;

create or replace function public.get_data_sync_current_values(
  target_area text,
  target_code text,
  target_branch text default null,
  target_route text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  if upper(target_area) = 'PRODUCT' then
    select jsonb_build_object(
      '_exists',true,'_updated_at',greatest(p.updated_at,coalesce(s.updated_at,p.updated_at)),'_version',extract(epoch from p.updated_at),
      'description',p.descricao,'brand',p.marca,'application',p.aplicacao,'year',p.ano,
      'ncm',p.ncm,'cest',p.cest,'ipi_rate',p.ipi_rate,'origin_code',p.origin_code,
      'origin_description',p.origin_description,'material_group',p.material_group,'fiscal_group',p.fiscal_group,
      'group',p.grupo,'model',s.model,'oem_01',coalesce(s.oem_01,p.oem),'manufacturer',coalesce(s.manufacturer,p.montadora),
      'item_group',s.item_group,'sales_unit',s.sales_unit,'barcode',s.barcode,'weight',s.weight,'volume',s.volume,'item_notes',coalesce(s.item_notes,p.detalhes)
    ) into v_result
    from public.products p left join public.product_sap_data s on s.product_code=p.codigo
    where p.codigo=target_code;
  elsif upper(target_area) = 'STOCK' then
    select jsonb_build_object(
      '_exists',true,'_updated_at',s.updated_at,'_version',s.version,
      'stock_qty',s.sap_stock_qty,'confirmed_qty',s.sap_confirmed_qty,
      'sales_available_qty',s.sap_sales_available_qty,'authorized_pending_qty',s.sap_authorized_pending_qty,
      'general_available_qty',s.sap_general_available_qty,'general_available_capped',s.available_qty_capped,
      'source_display_value',s.source_display_value
    ) into v_result
    from public.product_branch_stock s join public.branches b on b.id=s.branch_id
    where s.product_code=target_code and b.code=upper(target_branch);
  elsif upper(target_area) = 'BASE_PRICE' then
    select jsonb_build_object(
      '_exists',true,'_updated_at',p.updated_at,'_version',p.version,
      'base_price',p.sale_price,'currency',p.currency
    ) into v_result
    from public.product_branch_prices p join public.branches b on b.id=p.branch_id
    where p.product_code=target_code and b.code=upper(target_branch);
  elsif upper(target_area) = 'ROUTE_PRICE' then
    select jsonb_build_object(
      '_exists',true,'_updated_at',p.updated_at,'_version',p.version,
      'base_price',p.base_price,'final_price',p.final_price,'total_taxes',p.total_taxes,
      'tax_breakdown',p.tax_breakdown,'calculation_status',p.calculation_status,'currency',p.currency
    ) into v_result
    from public.product_route_prices p
    where p.product_code=target_code and p.route=upper(target_route);
  end if;
  return coalesce(v_result,jsonb_build_object('_exists',false,'_updated_at',null,'_version',null));
end;
$$;

create or replace function public.create_data_sync_batch(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_actor public.profiles;
  v_source text := upper(btrim(coalesce(payload->>'source','EXCEL_API')));
  v_version text := nullif(btrim(payload->>'source_version'),'');
  v_hash text := lower(btrim(coalesce(payload->>'file_hash','')));
  v_source_at timestamptz;
  v_key text;
  v_existing public.products_import_batches;
  v_id uuid;
begin
  if not public.can_manage_data_sync() then raise exception 'SEM_PERMISSAO_SINCRONIZAR'; end if;
  select * into v_actor from public.profiles where id=auth.uid() and ativo;
  if not exists(select 1 from public.data_sync_sources where source_code=v_source and enabled) then
    raise exception 'FONTE_SINCRONIZACAO_INVALIDA';
  end if;
  if v_version is null then raise exception 'VERSAO_ORIGEM_AUSENTE'; end if;
  if v_hash !~ '^[0-9a-f]{64}$' then raise exception 'HASH_ARQUIVO_INVALIDO'; end if;
  begin v_source_at := (payload->>'source_updated_at')::timestamptz;
  exception when others then raise exception 'DATA_ORIGEM_INVALIDA'; end;
  if v_source_at is null or v_source_at > now() + interval '5 minutes' then raise exception 'DATA_ORIGEM_INVALIDA'; end if;
  v_key := encode(digest(convert_to(concat_ws('|','DATA_SYNC_V1',v_source,v_version,v_hash),'UTF8'),'sha256'),'hex');

  select * into v_existing from public.products_import_batches
  where contract_version=3 and idempotency_key=v_key limit 1;
  if v_existing.id is not null then
    return jsonb_build_object('batch_id',v_existing.id,'status',v_existing.status,'duplicate',true,'idempotency_key',v_key);
  end if;

  insert into public.products_import_batches(
    created_by,created_by_profile_id,import_type,import_kind,integration_source,source_name,
    original_filename,file_size,file_hash,client_file_hash,normalized_file_hash,idempotency_key,
    contract_version,normalization_algorithm,hash_algorithm,state,status,source_version,
    source_updated_at,started_at,next_sync_at,field_mask,summary
  ) values (
    coalesce(v_actor.usuario,'SYSTEM'),v_actor.id,'EXCEL_MASTER','EXCEL_MASTER',v_source,
    nullif(payload->>'source_name',''),nullif(payload->>'original_filename',''),nullif(payload->>'file_size','')::bigint,
    v_hash,v_hash,v_hash,v_key,3,'data-sync-v1','SHA-256','DRAFT','pending',v_version,
    v_source_at,clock_timestamp(),nullif(payload->>'next_sync_at','')::timestamptz,'{}'::text[],
    jsonb_build_object('phase','CREATED','source',v_source,'source_version',v_version,'created_at',now())
  ) returning id into v_id;

  update public.data_sync_sources set connection_status='CONNECTED',last_seen_at=now(),last_error=null,
    next_sync_at=coalesce(nullif(payload->>'next_sync_at','')::timestamptz,next_sync_at)
  where source_code=v_source;
  return jsonb_build_object('batch_id',v_id,'status','pending','duplicate',false,'idempotency_key',v_key);
exception when unique_violation then
  select * into v_existing from public.products_import_batches where contract_version=3 and idempotency_key=v_key limit 1;
  return jsonb_build_object('batch_id',v_existing.id,'status',v_existing.status,'duplicate',true,'idempotency_key',v_key);
end;
$$;

create or replace function public.stage_data_sync_rows(target_batch_id uuid, rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch public.products_import_batches;
  v_row jsonb;
  v_area text;
  v_code text;
  v_branch text;
  v_route text;
  v_fields jsonb;
  v_mask text[];
  v_clears text[];
  v_row_number integer;
  v_key text;
  v_count integer := 0;
begin
  if not public.can_manage_data_sync() then raise exception 'SEM_PERMISSAO_SINCRONIZAR'; end if;
  select * into v_batch from public.products_import_batches b
  where b.id=target_batch_id and b.contract_version=3 and b.state='DRAFT' for update;
  if v_batch.id is null then raise exception 'LOTE_SINCRONIZACAO_FORA_DE_ESTADO'; end if;
  if jsonb_typeof(rows)<>'array' or jsonb_array_length(rows)=0 or jsonb_array_length(rows)>1000 then
    raise exception 'BLOCO_SINCRONIZACAO_INVALIDO';
  end if;
  for v_row in select value from jsonb_array_elements(rows) loop
    v_row_number:=coalesce((v_row->>'row_number')::integer,
      (select coalesce(max(row_number),0)+1 from public.products_import_stage where batch_id=target_batch_id));
    v_area:=upper(btrim(coalesce(v_row->>'area','')));
    v_code:=public.normalize_integration_product_code(v_row->>'product_code');
    v_branch:=upper(nullif(btrim(v_row->>'branch_code'),''));
    v_route:=upper(nullif(btrim(v_row->>'route'),''));
    v_fields:=coalesce(v_row->'fields','{}'::jsonb);
    v_mask:=coalesce(array(select lower(btrim(value)) from jsonb_array_elements_text(coalesce(v_row->'field_mask','[]'::jsonb))),
      array(select jsonb_object_keys(v_fields)),'{}'::text[]);
    if cardinality(v_mask)=0 then v_mask:=array(select jsonb_object_keys(v_fields)); end if;
    v_clears:=coalesce(array(select lower(btrim(value)) from jsonb_array_elements_text(coalesce(v_row->'clear_fields','[]'::jsonb))),'{}'::text[]);
    v_key:=concat_ws('|',coalesce(v_area,'INVALID'),coalesce(v_code,'INVALID'),coalesce(v_branch,''),coalesce(v_route,''));
    insert into public.products_import_stage(
      batch_id,row_number,codigo,normalized_code,raw_data,normalized_data,status,
      provided_fields,field_mask,row_hash,sync_area,branch_code,route,source_version,
      source_updated_at,clear_fields
    ) values (
      target_batch_id,v_row_number,v_code,v_key,coalesce(v_row->'raw',v_row),v_fields,'pending',
      v_mask,v_mask,md5(v_fields::text),v_area,v_branch,v_route,
      coalesce(nullif(v_row->>'source_version',''),v_batch.source_version),
      coalesce(nullif(v_row->>'source_updated_at','')::timestamptz,v_batch.source_updated_at),v_clears
    ) on conflict do nothing;
    v_count:=v_count+1;
  end loop;
  update public.products_import_batches set status='processing',
    total_rows=(select count(*) from public.products_import_stage where batch_id=target_batch_id),
    summary=summary||jsonb_build_object('phase','STAGING','staged_at',now()) where id=target_batch_id;
  return jsonb_build_object('batch_id',target_batch_id,'received_rows',v_count,
    'staged_rows',(select count(*) from public.products_import_stage where batch_id=target_batch_id));
end;
$$;

create or replace function public.validate_data_sync_batch(target_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '180s'
as $$
declare
  v_batch public.products_import_batches;
  v_stage public.products_import_stage;
  v_normalized jsonb;
  v_data jsonb;
  v_before jsonb;
  v_after jsonb;
  v_errors jsonb;
  v_warnings jsonb;
  v_effective text[];
  v_changed text[];
  v_field text;
  v_branch public.branches;
  v_valid integer:=0;
  v_invalid integer:=0;
  v_unchanged integer:=0;
  v_stale integer:=0;
  v_warning_count integer:=0;
  v_total integer:=0;
  v_products_analyzed integer:=0;
begin
  if not public.can_manage_data_sync() then raise exception 'SEM_PERMISSAO_SINCRONIZAR'; end if;
  select * into v_batch from public.products_import_batches b
  where b.id=target_batch_id and b.contract_version=3 and b.state in ('DRAFT','FAILED') for update;
  if v_batch.id is null then raise exception 'LOTE_SINCRONIZACAO_FORA_DE_ESTADO'; end if;

  for v_stage in select * from public.products_import_stage where batch_id=target_batch_id order by row_number loop
    v_total:=v_total+1; v_errors:='[]'::jsonb; v_warnings:='[]'::jsonb; v_changed:='{}'::text[];
    if v_stage.sync_area not in ('PRODUCT','STOCK','BASE_PRICE','ROUTE_PRICE') then
      v_errors:=v_errors||jsonb_build_array('AREA_INVALIDA');
    end if;
    if v_stage.codigo is null then v_errors:=v_errors||jsonb_build_array('CODIGO_INVALIDO'); end if;
    if v_stage.source_updated_at is null or v_stage.source_updated_at>now()+interval '5 minutes' then
      v_errors:=v_errors||jsonb_build_array('DATA_ORIGEM_INVALIDA');
    end if;
    if v_stage.source_version is null then v_errors:=v_errors||jsonb_build_array('VERSAO_ORIGEM_AUSENTE'); end if;

    if v_stage.sync_area in ('STOCK','BASE_PRICE') then
      select * into v_branch from public.branches where code=v_stage.branch_code and active;
      if v_branch.id is null then v_errors:=v_errors||jsonb_build_array('FILIAL_INVALIDA'); end if;
    elsif v_stage.sync_area='ROUTE_PRICE' then
      if v_stage.route is null or v_stage.route !~ '^[A-Z]{2}-[A-Z]{2}$' then
        v_errors:=v_errors||jsonb_build_array('ROTA_INVALIDA');
      else
        select * into v_branch from public.branches where code=left(v_stage.route,2) and active;
        if v_branch.id is null then v_errors:=v_errors||jsonb_build_array('FILIAL_ORIGEM_INVALIDA'); end if;
      end if;
    end if;

    v_normalized:=public.normalize_data_sync_fields(v_stage.sync_area,v_stage.normalized_data,v_stage.field_mask,v_stage.clear_fields);
    v_errors:=v_errors||coalesce(v_normalized->'errors','[]'::jsonb);
    v_warnings:=v_warnings||coalesce(v_normalized->'warnings','[]'::jsonb);
    v_data:=coalesce(v_normalized->'data','{}'::jsonb);
    v_effective:=coalesce(array(select jsonb_array_elements_text(v_normalized->'effective_fields')),'{}'::text[]);
    if cardinality(v_effective)=0 and jsonb_array_length(v_errors)=0 then
      v_warnings:=v_warnings||jsonb_build_array('SEM_CAMPOS_EFETIVOS');
    end if;

    if v_stage.sync_area<>'PRODUCT'
       and not exists(select 1 from public.products where codigo=v_stage.codigo)
       and not exists(select 1 from public.products_import_stage p where p.batch_id=target_batch_id
         and p.sync_area='PRODUCT' and p.codigo=v_stage.codigo) then
      v_errors:=v_errors||jsonb_build_array('PRODUTO_INEXISTENTE');
    end if;
    v_before:=public.get_data_sync_current_values(v_stage.sync_area,v_stage.codigo,v_stage.branch_code,v_stage.route);
    if v_stage.sync_area='PRODUCT' and not coalesce((v_before->>'_exists')::boolean,false)
       and nullif(v_data->>'description','') is null then
      v_errors:=v_errors||jsonb_build_array('DESCRICAO_AUSENTE_PRODUTO_NOVO');
    end if;
    if v_stage.sync_area='STOCK' and not coalesce((v_before->>'_exists')::boolean,false)
       and not (v_data?'stock_qty') then
      v_errors:=v_errors||jsonb_build_array('ESTOQUE_FISICO_AUSENTE_REGISTRO_NOVO');
    end if;
    if v_stage.sync_area='BASE_PRICE' and not (v_data?'base_price') then
      v_errors:=v_errors||jsonb_build_array('PRECO_AUSENTE');
    end if;
    if v_stage.sync_area='ROUTE_PRICE' and not (v_data?'final_price') then
      v_errors:=v_errors||jsonb_build_array('PRECO_FINAL_AUSENTE');
    end if;

    if coalesce((v_before->>'_exists')::boolean,false)
       and (v_before->>'_updated_at')::timestamptz > v_stage.source_updated_at then
      v_warnings:=v_warnings||jsonb_build_array('EVENTO_ORIGEM_ANTIGO');
      v_stale:=v_stale+1;
    else
      for v_field in select unnest(v_effective) loop
        if (v_before->v_field) is distinct from (v_data->v_field) then v_changed:=array_append(v_changed,v_field); end if;
      end loop;
    end if;
    v_after:=(v_before-'_exists'-'_updated_at'-'_version')||v_data;

    update public.products_import_stage set
      normalized_data=v_data,provided_fields=v_effective,field_mask=v_effective,changed_fields=v_changed,
      blocking_errors=v_errors,errors=v_errors,warnings=v_warnings,
      status=case when jsonb_array_length(v_errors)>0 then 'error'
        when jsonb_array_length(v_warnings)>0 then 'warning' else 'valid' end,
      skip_reason=case when v_warnings ? 'EVENTO_ORIGEM_ANTIGO' then 'STALE_SOURCE_EVENT'
        when cardinality(v_changed)=0 then 'NO_CHANGE' else null end,
      planned_action=case when jsonb_array_length(v_errors)>0 then null
        when v_warnings ? 'EVENTO_ORIGEM_ANTIGO' or cardinality(v_changed)=0 then 'NO_CHANGE'
        when coalesce((v_before->>'_exists')::boolean,false) then 'UPDATE' else 'INSERT' end,
      product_before=case when v_stage.sync_area='PRODUCT' then v_before-'_exists'-'_updated_at'-'_version' else null end,
      product_after=case when v_stage.sync_area='PRODUCT' then v_after else null end,
      stock_before=case when v_stage.sync_area='STOCK' then v_before-'_exists'-'_updated_at'-'_version' else null end,
      stock_after=case when v_stage.sync_area='STOCK' then v_after else null end,
      price_before=case when v_stage.sync_area in ('BASE_PRICE','ROUTE_PRICE') then v_before-'_exists'-'_updated_at'-'_version' else null end,
      price_after=case when v_stage.sync_area in ('BASE_PRICE','ROUTE_PRICE') then v_after else null end,
      product_version=case when v_stage.sync_area='PRODUCT' and v_before->>'_updated_at' is not null then (v_before->>'_updated_at')::timestamptz else null end,
      stock_version=case when v_stage.sync_area='STOCK' and v_before->>'_version' is not null then (v_before->>'_version')::bigint else null end,
      price_version=case when v_stage.sync_area in ('BASE_PRICE','ROUTE_PRICE') and v_before->>'_version' is not null then (v_before->>'_version')::bigint else null end
    where id=v_stage.id;

    if jsonb_array_length(v_errors)>0 then v_invalid:=v_invalid+1;
    else
      v_valid:=v_valid+1;
      if cardinality(v_changed)=0 then v_unchanged:=v_unchanged+1; end if;
    end if;
    v_warning_count:=v_warning_count+jsonb_array_length(v_warnings);
  end loop;

  select count(distinct codigo) into v_products_analyzed
  from public.products_import_stage where batch_id=target_batch_id and codigo is not null;

  update public.products_import_batches set
    state=case when v_valid=0 then 'FAILED' else 'PREVIEWED' end,
    status=case when v_valid=0 then 'failed' else 'processing' end,
    total_rows=v_total,valid_rows=v_valid,invalid_rows=v_invalid,error_count=v_invalid,warning_count=v_warning_count,
    unchanged_rows=v_unchanged,stale_rows=v_stale,ignored_rows=v_stale,
    previewed_at=now(),
    summary=summary||jsonb_build_object('phase','VALIDATED','products_analyzed',v_products_analyzed,'valid',v_valid,'invalid',v_invalid,
      'unchanged',v_unchanged,'stale',v_stale,'validated_at',now()),
    last_failure_code=case when v_valid=0 then 'ALL_ROWS_INVALID' else null end
  where id=target_batch_id;
  return public.get_data_sync_batch(target_batch_id);
end;
$$;

-- Forward declaration used by validation and commit responses.
create or replace function public.get_data_sync_batch(target_batch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_result jsonb;
begin
  if not public.can_view_data_sync() then raise exception 'SEM_PERMISSAO_VISUALIZAR_SINCRONIZACAO'; end if;
  select to_jsonb(b) || jsonb_build_object(
    'duration_seconds',case when b.started_at is null then null else extract(epoch from coalesce(b.finished_at,now())-b.started_at) end
  ) into v_result from public.products_import_batches b where b.id=target_batch_id and b.contract_version=3;
  if v_result is null then raise exception 'LOTE_SINCRONIZACAO_NAO_ENCONTRADO'; end if;
  return v_result;
end;
$$;

create or replace function public.commit_data_sync_batch(target_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '180s'
as $$
declare
  v_batch public.products_import_batches;
  v_stage public.products_import_stage;
  v_actor public.profiles;
  v_branch public.branches;
  v_before jsonb;
  v_after jsonb;
  v_data jsonb;
  v_field text;
  v_inserted integer:=0;
  v_updated integer:=0;
  v_unchanged integer:=0;
  v_ignored integer:=0;
  v_conflicts integer:=0;
  v_products integer:=0;
  v_products_inserted integer:=0;
  v_stocks integer:=0;
  v_prices integer:=0;
  v_fiscal integer:=0;
  v_delta numeric;
  v_movement_id uuid;
  v_current_version bigint;
  v_current_updated_at timestamptz;
begin
  if not public.can_manage_data_sync() then raise exception 'SEM_PERMISSAO_SINCRONIZAR'; end if;
  select * into v_actor from public.profiles where id=auth.uid() and ativo;
  select * into v_batch from public.products_import_batches b
  where b.id=target_batch_id and b.contract_version=3 for update;
  if v_batch.id is null then raise exception 'LOTE_SINCRONIZACAO_NAO_ENCONTRADO'; end if;
  if v_batch.state='COMMITTED' then return public.get_data_sync_batch(target_batch_id)||jsonb_build_object('already_committed',true); end if;
  if v_batch.state<>'PREVIEWED' then raise exception 'LOTE_SINCRONIZACAO_NAO_VALIDADO'; end if;
  update public.products_import_batches set state='COMMITTING',status='processing',
    attempt_count=attempt_count+1,last_attempt_started_at=now() where id=target_batch_id;

  for v_stage in select * from public.products_import_stage
    where batch_id=target_batch_id order by row_number for update loop
    if v_stage.status='error' then v_ignored:=v_ignored+1; continue; end if;
    if v_stage.planned_action='NO_CHANGE' then v_unchanged:=v_unchanged+1; continue; end if;
    v_data:=v_stage.normalized_data; v_movement_id:=null;
    v_before:=public.get_data_sync_current_values(v_stage.sync_area,v_stage.codigo,v_stage.branch_code,v_stage.route);

    -- Optimistic concurrency plus event-time protection. A manual edit or a
    -- newer source event after preview converts only that row into an error.
    if coalesce((v_before->>'_exists')::boolean,false) then
      if (v_before->>'_updated_at')::timestamptz > v_stage.source_updated_at
         or (v_stage.sync_area='PRODUCT' and (v_before->>'_updated_at')::timestamptz is distinct from v_stage.product_version)
         or (v_stage.sync_area='STOCK' and (v_before->>'_version')::bigint is distinct from v_stage.stock_version)
         or (v_stage.sync_area in ('BASE_PRICE','ROUTE_PRICE') and (v_before->>'_version')::bigint is distinct from v_stage.price_version) then
        update public.products_import_stage set status='error',skip_reason='CONCURRENT_MODIFICATION',
          blocking_errors=blocking_errors||jsonb_build_array('ALTERACAO_CONCORRENTE'),
          errors=errors||jsonb_build_array('ALTERACAO_CONCORRENTE') where id=v_stage.id;
        v_conflicts:=v_conflicts+1; v_ignored:=v_ignored+1; continue;
      end if;
    elsif v_stage.planned_action='UPDATE' then
      update public.products_import_stage set status='error',skip_reason='CONCURRENT_MODIFICATION',
        blocking_errors=blocking_errors||jsonb_build_array('REGISTRO_REMOVIDO_APOS_PREVIEW'),
        errors=errors||jsonb_build_array('REGISTRO_REMOVIDO_APOS_PREVIEW') where id=v_stage.id;
      v_conflicts:=v_conflicts+1; v_ignored:=v_ignored+1; continue;
    end if;

    if v_stage.sync_area='PRODUCT' then
      insert into public.products(
        codigo,descricao,marca,aplicacao,ano,ncm,cest,ipi_rate,ipi_defined,origin_code,
        origin_description,material_group,fiscal_group,grupo,montadora,oem,detalhes,
        sync_source,sync_source_version,sync_source_updated_at,sync_batch_id
      ) values (
        v_stage.codigo,v_data->>'description',v_data->>'brand',v_data->>'application',v_data->>'year',
        v_data->>'ncm',v_data->>'cest',nullif(v_data->>'ipi_rate','')::numeric,v_data?'ipi_rate',v_data->>'origin_code',
        v_data->>'origin_description',v_data->>'material_group',v_data->>'fiscal_group',v_data->>'group',
        v_data->>'manufacturer',v_data->>'oem_01',v_data->>'item_notes',v_batch.integration_source,
        v_stage.source_version,v_stage.source_updated_at,target_batch_id
      ) on conflict(codigo) do update set
        descricao=case when v_data?'description' then v_data->>'description' else products.descricao end,
        marca=case when v_data?'brand' then v_data->>'brand' else products.marca end,
        aplicacao=case when v_data?'application' then v_data->>'application' else products.aplicacao end,
        ano=case when v_data?'year' then v_data->>'year' else products.ano end,
        ncm=case when v_data?'ncm' then v_data->>'ncm' else products.ncm end,
        cest=case when v_data?'cest' then v_data->>'cest' else products.cest end,
        ipi_rate=case when v_data?'ipi_rate' then (v_data->>'ipi_rate')::numeric else products.ipi_rate end,
        ipi_defined=case when v_data?'ipi_rate' then true else products.ipi_defined end,
        origin_code=case when v_data?'origin_code' then v_data->>'origin_code' else products.origin_code end,
        origin_description=case when v_data?'origin_description' then v_data->>'origin_description' else products.origin_description end,
        material_group=case when v_data?'material_group' then v_data->>'material_group' else products.material_group end,
        fiscal_group=case when v_data?'fiscal_group' then v_data->>'fiscal_group' else products.fiscal_group end,
        grupo=case when v_data?'group' then v_data->>'group' else products.grupo end,
        montadora=case when v_data?'manufacturer' then v_data->>'manufacturer' else products.montadora end,
        oem=case when v_data?'oem_01' then v_data->>'oem_01' else products.oem end,
        detalhes=case when v_data?'item_notes' then v_data->>'item_notes' else products.detalhes end,
        sync_source=v_batch.integration_source,sync_source_version=v_stage.source_version,
        sync_source_updated_at=v_stage.source_updated_at,sync_batch_id=target_batch_id,updated_at=now();

      if v_data ?| array['model','oem_01','manufacturer','item_group','sales_unit','barcode','weight','volume','item_notes'] then
        insert into public.product_sap_data(
          product_code,model,oem_01,manufacturer,item_group,sales_unit,barcode,weight,volume,item_notes,
          raw_data,source,source_version,source_updated_at,import_batch_id
        ) values (
          v_stage.codigo,v_data->>'model',v_data->>'oem_01',v_data->>'manufacturer',v_data->>'item_group',
          v_data->>'sales_unit',v_data->>'barcode',nullif(v_data->>'weight','')::numeric,
          nullif(v_data->>'volume','')::numeric,v_data->>'item_notes',v_stage.raw_data,v_batch.integration_source,
          v_stage.source_version,v_stage.source_updated_at,target_batch_id
        ) on conflict(product_code) do update set
          model=case when v_data?'model' then v_data->>'model' else product_sap_data.model end,
          oem_01=case when v_data?'oem_01' then v_data->>'oem_01' else product_sap_data.oem_01 end,
          manufacturer=case when v_data?'manufacturer' then v_data->>'manufacturer' else product_sap_data.manufacturer end,
          item_group=case when v_data?'item_group' then v_data->>'item_group' else product_sap_data.item_group end,
          sales_unit=case when v_data?'sales_unit' then v_data->>'sales_unit' else product_sap_data.sales_unit end,
          barcode=case when v_data?'barcode' then v_data->>'barcode' else product_sap_data.barcode end,
          weight=case when v_data?'weight' then (v_data->>'weight')::numeric else product_sap_data.weight end,
          volume=case when v_data?'volume' then (v_data->>'volume')::numeric else product_sap_data.volume end,
          item_notes=case when v_data?'item_notes' then v_data->>'item_notes' else product_sap_data.item_notes end,
          raw_data=product_sap_data.raw_data||excluded.raw_data,source=excluded.source,
          source_version=excluded.source_version,source_updated_at=excluded.source_updated_at,
          import_batch_id=excluded.import_batch_id,updated_at=now();
      end if;
      v_products:=v_products+1;
      if v_stage.planned_action='INSERT' then v_products_inserted:=v_products_inserted+1; end if;
    elsif v_stage.sync_area='STOCK' then
      select * into v_branch from public.branches where code=v_stage.branch_code and active;
      select to_jsonb(s) into v_before from public.product_branch_stock s
        where s.product_code=v_stage.codigo and s.branch_id=v_branch.id;
      insert into public.product_branch_stock(
        product_code,branch_id,physical_qty,sap_stock_qty,sap_confirmed_qty,sap_sales_available_qty,
        sap_authorized_pending_qty,sap_general_available_qty,available_qty_capped,source_display_value,
        source_batch_id,source_updated_at,source_system,source_version,updated_by
      ) values (
        v_stage.codigo,v_branch.id,(v_data->>'stock_qty')::numeric,(v_data->>'stock_qty')::numeric,
        nullif(v_data->>'confirmed_qty','')::numeric,nullif(v_data->>'sales_available_qty','')::numeric,
        nullif(v_data->>'authorized_pending_qty','')::numeric,nullif(v_data->>'general_available_qty','')::numeric,
        coalesce((v_data->>'general_available_capped')::boolean,false),v_data->>'source_display_value',
        target_batch_id,v_stage.source_updated_at,v_batch.integration_source,v_stage.source_version,v_actor.id
      ) on conflict(product_code,branch_id) do update set
        physical_qty=case when v_data?'stock_qty' then (v_data->>'stock_qty')::numeric else product_branch_stock.physical_qty end,
        sap_stock_qty=case when v_data?'stock_qty' then (v_data->>'stock_qty')::numeric else product_branch_stock.sap_stock_qty end,
        sap_confirmed_qty=case when v_data?'confirmed_qty' then (v_data->>'confirmed_qty')::numeric else product_branch_stock.sap_confirmed_qty end,
        sap_sales_available_qty=case when v_data?'sales_available_qty' then (v_data->>'sales_available_qty')::numeric else product_branch_stock.sap_sales_available_qty end,
        sap_authorized_pending_qty=case when v_data?'authorized_pending_qty' then (v_data->>'authorized_pending_qty')::numeric else product_branch_stock.sap_authorized_pending_qty end,
        sap_general_available_qty=case when v_data?'general_available_qty' then (v_data->>'general_available_qty')::numeric else product_branch_stock.sap_general_available_qty end,
        available_qty_capped=case when v_data?'general_available_capped' then (v_data->>'general_available_capped')::boolean else product_branch_stock.available_qty_capped end,
        source_display_value=case when v_data?'source_display_value' then v_data->>'source_display_value' else product_branch_stock.source_display_value end,
        source_batch_id=target_batch_id,source_updated_at=v_stage.source_updated_at,
        source_system=v_batch.integration_source,source_version=v_stage.source_version,updated_by=v_actor.id;
      select to_jsonb(s) into v_after from public.product_branch_stock s
        where s.product_code=v_stage.codigo and s.branch_id=v_branch.id;
      v_delta:=coalesce((v_after->>'physical_qty')::numeric,0)-coalesce((v_before->>'physical_qty')::numeric,0);
      if v_delta<>0 then
        insert into public.stock_movements(
          branch_id,product_code,movement_type,physical_delta,balance_before,balance_after,source,
          reference_type,reference_id,idempotency_key,metadata,created_by
        ) values (
          v_branch.id,v_stage.codigo,'SYNC_ERP',v_delta,coalesce(v_before,'{}'::jsonb),v_after,
          v_batch.integration_source,'products_import_batches',target_batch_id,
          'DATA_SYNC|'||target_batch_id||'|'||v_stage.id||'|PHYSICAL',
          jsonb_build_object('batch_id',target_batch_id,'source_version',v_stage.source_version,
            'stock_before',v_before->'physical_qty','stock_received',v_after->'physical_qty','difference',v_delta),v_actor.id
        ) returning id into v_movement_id;
      end if;
      v_stocks:=v_stocks+1;
    elsif v_stage.sync_area='BASE_PRICE' then
      select * into v_branch from public.branches where code=v_stage.branch_code and active;
      insert into public.product_branch_prices(
        product_code,branch_id,sale_price,currency,version,source,source_batch_id,source_version,source_updated_at,updated_by,valid_from
      ) values (
        v_stage.codigo,v_branch.id,(v_data->>'base_price')::numeric,coalesce(v_data->>'currency','BRL'),1,
        v_batch.integration_source,target_batch_id,v_stage.source_version,v_stage.source_updated_at,v_actor.id,current_date
      ) on conflict(product_code,branch_id) do update set
        sale_price=case when v_data?'base_price' then (v_data->>'base_price')::numeric else product_branch_prices.sale_price end,
        currency=case when v_data?'currency' then v_data->>'currency' else product_branch_prices.currency end,
        source=v_batch.integration_source,source_batch_id=target_batch_id,source_version=v_stage.source_version,
        source_updated_at=v_stage.source_updated_at,updated_by=v_actor.id,valid_until=null;
      v_prices:=v_prices+1;
    elsif v_stage.sync_area='ROUTE_PRICE' then
      select * into v_branch from public.branches where code=left(v_stage.route,2) and active;
      insert into public.product_route_prices(
        product_code,origin_branch_id,destination_state,route,base_price,final_price,total_taxes,tax_breakdown,
        calculation_status,currency,source,source_version,source_updated_at,source_batch_id,updated_by
      ) values (
        v_stage.codigo,v_branch.id,right(v_stage.route,2),v_stage.route,nullif(v_data->>'base_price','')::numeric,
        (v_data->>'final_price')::numeric,nullif(v_data->>'total_taxes','')::numeric,coalesce(v_data->'tax_breakdown','{}'::jsonb),
        coalesce(v_data->>'calculation_status','OK'),coalesce(v_data->>'currency','BRL'),v_batch.integration_source,
        v_stage.source_version,v_stage.source_updated_at,target_batch_id,v_actor.id
      ) on conflict(product_code,route) do update set
        base_price=case when v_data?'base_price' then (v_data->>'base_price')::numeric else product_route_prices.base_price end,
        final_price=case when v_data?'final_price' then (v_data->>'final_price')::numeric else product_route_prices.final_price end,
        total_taxes=case when v_data?'total_taxes' then (v_data->>'total_taxes')::numeric else product_route_prices.total_taxes end,
        tax_breakdown=case when v_data?'tax_breakdown' then v_data->'tax_breakdown' else product_route_prices.tax_breakdown end,
        calculation_status=case when v_data?'calculation_status' then v_data->>'calculation_status' else product_route_prices.calculation_status end,
        currency=case when v_data?'currency' then v_data->>'currency' else product_route_prices.currency end,
        origin_branch_id=v_branch.id,destination_state=right(v_stage.route,2),source=v_batch.integration_source,
        source_version=v_stage.source_version,source_updated_at=v_stage.source_updated_at,
        source_batch_id=target_batch_id,updated_by=v_actor.id;
      v_fiscal:=v_fiscal+1;
    end if;

    v_after:=public.get_data_sync_current_values(v_stage.sync_area,v_stage.codigo,v_stage.branch_code,v_stage.route)-'_exists'-'_updated_at'-'_version';
    for v_field in select unnest(v_stage.changed_fields) loop
      insert into public.products_import_audit(
        batch_id,stage_id,codigo,action,before_data,after_data,created_by,branch_id,entity_type,
        field_name,old_value,new_value,version_before,version_after,stock_movement_id,
        source,source_version,source_updated_at,route,status
      ) values (
        target_batch_id,v_stage.id,v_stage.codigo,lower(v_stage.planned_action),
        coalesce(v_stage.product_before,v_stage.stock_before,v_stage.price_before),v_after,coalesce(v_actor.usuario,'SYSTEM'),
        case when v_stage.sync_area='PRODUCT' then null else v_branch.id end,
        v_stage.sync_area,v_field,
        coalesce(v_stage.product_before,v_stage.stock_before,v_stage.price_before)->v_field,v_after->v_field,
        case when v_stage.sync_area='STOCK' then v_stage.stock_version else v_stage.price_version end,
        case when v_stage.sync_area in ('STOCK','BASE_PRICE','ROUTE_PRICE') then
          nullif((public.get_data_sync_current_values(v_stage.sync_area,v_stage.codigo,v_stage.branch_code,v_stage.route)->>'_version'), '')::bigint else null end,
        v_movement_id,v_batch.integration_source,v_stage.source_version,v_stage.source_updated_at,v_stage.route,'applied'
      );
    end loop;
    update public.products_import_stage set status='committed',
      product_after=case when sync_area='PRODUCT' then v_after else product_after end,
      stock_after=case when sync_area='STOCK' then v_after else stock_after end,
      price_after=case when sync_area in ('BASE_PRICE','ROUTE_PRICE') then v_after else price_after end
    where id=v_stage.id;
    if v_stage.planned_action='INSERT' then v_inserted:=v_inserted+1; else v_updated:=v_updated+1; end if;
  end loop;

  update public.products_import_batches set state='COMMITTED',
    status=case when invalid_rows+v_conflicts>0 then 'completed_with_errors' else 'completed' end,
    inserted_rows=v_inserted,updated_rows=v_updated,unchanged_rows=v_unchanged,
    ignored_rows=v_ignored+v_batch.stale_rows,invalid_rows=invalid_rows+v_conflicts,error_count=error_count+v_conflicts,
    finished_at=now(),committed_at=now(),imported_at=now(),last_attempt_completed_at=now(),
    committed_by_profile_id=v_actor.id,
    summary=summary||jsonb_build_object('phase','COMPLETED','inserted',v_inserted,'updated',v_updated,
      'unchanged',v_unchanged,'ignored',v_ignored,'concurrent_conflicts',v_conflicts,
      'products_changed',v_products,'products_inserted',v_products_inserted,'stocks_changed',v_stocks,'prices_changed',v_prices,
      'fiscal_results_changed',v_fiscal,'completed_at',now())
  where id=target_batch_id;
  update public.data_sync_sources set connection_status=case when (v_batch.error_count+v_conflicts)>0 then 'DEGRADED' else 'CONNECTED' end,
    last_seen_at=now(),last_success_at=now(),last_error_at=case when (v_batch.error_count+v_conflicts)>0 then now() else last_error_at end,
    last_error=case when (v_batch.error_count+v_conflicts)>0 then 'Lote concluído com linhas ignoradas ou inválidas.' else null end,
    next_sync_at=v_batch.next_sync_at where source_code=v_batch.integration_source;
  return public.get_data_sync_batch(target_batch_id)||jsonb_build_object('already_committed',false);
exception when others then
  update public.data_sync_sources set connection_status='DEGRADED',last_error_at=now(),last_error=sqlerrm
  where source_code=v_batch.integration_source;
  raise;
end;
$$;

create or replace function public.mark_data_sync_failure(target_batch_id uuid, error_message text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_batch public.products_import_batches;
begin
  if not public.can_manage_data_sync() then raise exception 'SEM_PERMISSAO_SINCRONIZAR'; end if;
  select * into v_batch from public.products_import_batches
  where id=target_batch_id and contract_version=3 for update;
  if v_batch.id is null then raise exception 'LOTE_SINCRONIZACAO_NAO_ENCONTRADO'; end if;
  if v_batch.state<>'COMMITTED' then
    update public.products_import_batches set state='FAILED',status='failed',finished_at=now(),
      last_attempt_completed_at=now(),last_failure_at=now(),last_failure_code='ADAPTER_OR_PROCESSING_ERROR',
      last_failure_details=jsonb_build_object('message',left(coalesce(error_message,'Falha não detalhada.'),1000)),
      summary=summary||jsonb_build_object('phase','FAILED','failed_at',now()) where id=target_batch_id;
    update public.data_sync_sources set connection_status='DEGRADED',last_seen_at=now(),last_error_at=now(),
      last_error=left(coalesce(error_message,'Falha não detalhada.'),1000)
    where source_code=v_batch.integration_source;
  end if;
  return public.get_data_sync_batch(target_batch_id);
end;
$$;

create or replace function public.mark_data_sync_source_failure(target_source text, error_message text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_source text:=upper(trim(coalesce(target_source,''))); v_result jsonb;
begin
  if not public.can_manage_data_sync() then raise exception 'SEM_PERMISSAO_SINCRONIZAR'; end if;
  update public.data_sync_sources
  set connection_status='DEGRADED',last_seen_at=now(),last_error_at=now(),
    last_error=left(coalesce(error_message,'Falha não detalhada.'),1000)
  where source_code=v_source and enabled;
  if not found then raise exception 'FONTE_SINCRONIZACAO_NAO_ENCONTRADA'; end if;
  select jsonb_build_object('source',to_jsonb(s),'connected',false) into v_result
  from public.data_sync_sources s where s.source_code=v_source;
  return v_result;
end;
$$;

create or replace function public.get_data_sync_status(filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_source text:=upper(coalesce(nullif(filters->>'source',''),'EXCEL_API')); v_result jsonb;
begin
  if not public.can_view_data_sync() then raise exception 'SEM_PERMISSAO_VISUALIZAR_SINCRONIZACAO'; end if;
  select jsonb_build_object(
    'source',to_jsonb(s),
    'last_batch',case when b.id is null then null else to_jsonb(b)||jsonb_build_object(
      'duration_seconds',extract(epoch from coalesce(b.finished_at,now())-coalesce(b.started_at,b.created_at))) end,
    'connected',s.enabled and s.connection_status='CONNECTED'
  ) into v_result
  from public.data_sync_sources s
  left join lateral (
    select * from public.products_import_batches b
    where b.contract_version=3 and b.integration_source=s.source_code
    order by coalesce(b.started_at,b.created_at) desc,b.created_at desc limit 1
  ) b on true
  where s.source_code=v_source;
  return coalesce(v_result,jsonb_build_object('source',null,'last_batch',null,'connected',false));
end;
$$;

create or replace function public.list_data_sync_batches(filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_rows jsonb;
begin
  if not public.can_view_data_sync() then raise exception 'SEM_PERMISSAO_VISUALIZAR_SINCRONIZACAO'; end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_rows from (
    select b.id,b.created_at,b.started_at,b.finished_at,b.integration_source,b.source_name,b.original_filename,
      b.source_version,b.source_updated_at,b.status,b.total_rows,b.valid_rows,b.invalid_rows,b.inserted_rows,
      b.updated_rows,b.unchanged_rows,b.ignored_rows,b.stale_rows,b.error_count,b.summary,
      p.nome created_by_name
    from public.products_import_batches b left join public.profiles p on p.id=b.created_by_profile_id
    where b.contract_version=3
      and (nullif(filters->>'source','') is null or b.integration_source=upper(filters->>'source'))
      and (nullif(filters->>'status','') is null or b.status=lower(filters->>'status'))
      and (nullif(filters->>'from','') is null or b.created_at>=(filters->>'from')::timestamptz)
      and (nullif(filters->>'to','') is null or b.created_at<(filters->>'to')::timestamptz+interval '1 day')
    order by b.created_at desc limit least(greatest(coalesce((filters->>'limit')::integer,100),1),500)
  ) x;
  return jsonb_build_object('rows',v_rows,'count',jsonb_array_length(v_rows));
end;
$$;

create or replace function public.list_data_sync_errors(filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_rows jsonb;
begin
  if not public.can_view_data_sync() then raise exception 'SEM_PERMISSAO_VISUALIZAR_SINCRONIZACAO'; end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc,x.row_number),'[]'::jsonb) into v_rows from (
    select b.id batch_id,b.created_at,s.row_number,s.codigo product_code,s.sync_area area,s.branch_code,s.route,
      s.status,s.skip_reason,s.blocking_errors errors,s.warnings,s.raw_data,s.normalized_data
    from public.products_import_stage s join public.products_import_batches b on b.id=s.batch_id
    where b.contract_version=3 and (s.status='error' or jsonb_array_length(s.blocking_errors)>0 or s.skip_reason is not null)
      and (nullif(filters->>'batch_id','') is null or b.id=(filters->>'batch_id')::uuid)
      and (nullif(filters->>'area','') is null or s.sync_area=upper(filters->>'area'))
      and (nullif(filters->>'branch','') is null or s.branch_code=upper(filters->>'branch'))
      and (nullif(filters->>'status','') is null or s.status=lower(filters->>'status'))
      and (nullif(filters->>'product_code','') is null or s.codigo=public.normalize_integration_product_code(filters->>'product_code'))
      and (nullif(filters->>'from','') is null or b.created_at>=(filters->>'from')::timestamptz)
      and (nullif(filters->>'to','') is null or b.created_at<(filters->>'to')::timestamptz+interval '1 day')
    order by b.created_at desc,s.row_number
    limit least(greatest(coalesce((filters->>'limit')::integer,200),1),1000)
  ) x;
  return jsonb_build_object('rows',v_rows,'count',jsonb_array_length(v_rows));
end;
$$;

create or replace function public.list_data_sync_audit(filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_rows jsonb;
begin
  if not public.can_view_data_sync() then raise exception 'SEM_PERMISSAO_VISUALIZAR_SINCRONIZACAO'; end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_rows from (
    select a.id,a.created_at,a.batch_id,a.codigo product_code,a.entity_type area,a.field_name,
      a.old_value,a.new_value,a.branch_id,b.code branch_code,a.route,a.source,a.source_version,
      a.source_updated_at,a.created_by,a.status
    from public.products_import_audit a left join public.branches b on b.id=a.branch_id
    join public.products_import_batches ib on ib.id=a.batch_id and ib.contract_version=3
    where (nullif(filters->>'batch_id','') is null or a.batch_id=(filters->>'batch_id')::uuid)
      and (nullif(filters->>'area','') is null or a.entity_type=upper(filters->>'area'))
      and (nullif(filters->>'product_code','') is null or a.codigo=public.normalize_integration_product_code(filters->>'product_code'))
    order by a.created_at desc
    limit least(greatest(coalesce((filters->>'limit')::integer,500),1),2000)
  ) x;
  return jsonb_build_object('rows',v_rows,'count',jsonb_array_length(v_rows));
end;
$$;

alter table public.data_sync_sources enable row level security;
alter table public.product_route_prices enable row level security;

drop policy if exists data_sync_sources_admin_read on public.data_sync_sources;
create policy data_sync_sources_admin_read on public.data_sync_sources
for select to authenticated using (public.can_view_data_sync());

drop policy if exists product_route_prices_commercial_read on public.product_route_prices;
create policy product_route_prices_commercial_read on public.product_route_prices
for select to authenticated using (
  public.can_access_branch(origin_branch_id)
  and (public.is_admin() or public.has_module('produtos') or public.has_module('novo_pedido')
    or public.has_module('nova_cotacao') or public.has_module('alimentacao'))
);

revoke all on public.data_sync_sources,public.product_route_prices from public,anon,authenticated;
grant select on public.data_sync_sources,public.product_route_prices to authenticated;

revoke all on function public.touch_product_route_price(),public.can_manage_data_sync(),public.can_view_data_sync(),
  public.normalize_integration_product_code(text),public.data_sync_allowed_fields(text),
  public.normalize_data_sync_fields(text,jsonb,text[],text[]),
  public.get_data_sync_current_values(text,text,text,text),public.create_data_sync_batch(jsonb),
  public.stage_data_sync_rows(uuid,jsonb),public.validate_data_sync_batch(uuid),
  public.commit_data_sync_batch(uuid),public.mark_data_sync_failure(uuid,text),public.mark_data_sync_source_failure(text,text),
  public.get_data_sync_batch(uuid),public.get_data_sync_status(jsonb),
  public.list_data_sync_batches(jsonb),public.list_data_sync_errors(jsonb),public.list_data_sync_audit(jsonb)
from public,anon;

grant execute on function public.can_view_data_sync(),public.get_data_sync_batch(uuid),
  public.get_data_sync_status(jsonb),public.list_data_sync_batches(jsonb),public.list_data_sync_errors(jsonb),
  public.list_data_sync_audit(jsonb) to authenticated;
grant execute on function public.create_data_sync_batch(jsonb),public.stage_data_sync_rows(uuid,jsonb),
  public.validate_data_sync_batch(uuid),public.commit_data_sync_batch(uuid),public.mark_data_sync_failure(uuid,text),
  public.mark_data_sync_source_failure(text,text)
  to authenticated,service_role;

comment on table public.data_sync_sources is 'Estado público dos adapters; credenciais e tokens nunca são armazenados nesta tabela.';
comment on table public.product_route_prices is 'Resultados fiscais consolidados por rota recebidos de fonte externa; não substitui preço-base por filial nem replica fórmulas do Excel.';
comment on function public.commit_data_sync_batch(uuid) is 'Commit parcial seguro: aplica somente linhas válidas e alteradas, revalida concorrência e registra auditoria por campo.';

commit;
