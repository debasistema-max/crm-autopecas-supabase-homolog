begin;

-- Fiscal and SAP foundation built on the import/branch contracts from migrations 027-040.
-- Rates introduced here use fractions (0.18 = 18%). Legacy *_percent columns remain
-- synchronized for backwards compatibility with the existing admin screen/RPCs.

alter table public.products
  add column if not exists cest text,
  add column if not exists ipi_rate numeric(12,8),
  add column if not exists ipi_defined boolean not null default false,
  add column if not exists origin_code text,
  add column if not exists origin_description text,
  add column if not exists material_group text,
  add column if not exists fiscal_group text,
  add column if not exists fiscal_source text,
  add column if not exists fiscal_updated_at timestamptz,
  add column if not exists fiscal_import_batch_id uuid;

alter table public.products
  drop constraint if exists products_cest_format_check;
alter table public.products
  add constraint products_cest_format_check
  check (cest is null or cest ~ '^[0-9]{7}$');

alter table public.products
  drop constraint if exists products_ipi_rate_check;
alter table public.products
  add constraint products_ipi_rate_check
  check (ipi_rate is null or (ipi_rate >= 0 and ipi_rate <= 10));

create index if not exists products_ncm_idx on public.products (ncm) where ncm is not null;
create index if not exists products_cest_idx on public.products (cest) where cest is not null;
create index if not exists products_fiscal_import_batch_idx
  on public.products (fiscal_import_batch_id) where fiscal_import_batch_id is not null;

create table if not exists public.product_sap_data (
  product_code text primary key references public.products(codigo) on update cascade on delete cascade,
  sap_description text,
  brand text,
  model text,
  year_text text,
  in_stock_text text,
  ordered_qty numeric(16,6),
  oem_01 text,
  delivery_text text,
  last_purchase_date date,
  compatible_text text,
  import_notes text,
  item_group text,
  sales_unit text,
  item_notes text,
  weight numeric(16,6),
  volume numeric(16,6),
  manufacturer_code_01 text,
  manufacturer_code_02 text,
  manufacturer text,
  barcode text,
  product_source text,
  material_type text,
  origin_and_fiscal_group text,
  materials_group text,
  origin_and_ncm text,
  raw_data jsonb not null default '{}'::jsonb,
  source text not null default 'SAP_ITEM_MASTER',
  import_batch_id uuid references public.products_import_batches(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint product_sap_data_ordered_qty_check check (ordered_qty is null or ordered_qty >= 0),
  constraint product_sap_data_weight_check check (weight is null or weight >= 0),
  constraint product_sap_data_volume_check check (volume is null or volume >= 0)
);

create index if not exists product_sap_data_item_group_idx on public.product_sap_data (item_group);
create index if not exists product_sap_data_manufacturer_idx on public.product_sap_data (manufacturer);
create index if not exists product_sap_data_import_batch_idx on public.product_sap_data (import_batch_id);

drop trigger if exists product_sap_data_touch_updated_at on public.product_sap_data;
create trigger product_sap_data_touch_updated_at
before update on public.product_sap_data
for each row execute function public.touch_updated_at();

alter table public.product_branch_stock
  add column if not exists sap_stock_qty numeric(16,6),
  add column if not exists sap_confirmed_qty numeric(16,6),
  add column if not exists sap_sales_available_qty numeric(16,6),
  add column if not exists sap_authorized_pending_qty numeric(16,6),
  add column if not exists sap_general_available_qty numeric(16,6),
  add column if not exists available_qty_capped boolean not null default false,
  add column if not exists source_display_value text,
  add column if not exists source_batch_id uuid references public.products_import_batches(id) on delete set null,
  add column if not exists source_updated_at timestamptz;

alter table public.product_branch_stock
  drop constraint if exists product_branch_stock_sap_quantities_check;
alter table public.product_branch_stock
  add constraint product_branch_stock_sap_quantities_check check (
    (sap_stock_qty is null or sap_stock_qty >= 0)
    and (sap_confirmed_qty is null or sap_confirmed_qty >= 0)
    and (sap_sales_available_qty is null or sap_sales_available_qty >= 0)
    and (sap_authorized_pending_qty is null or sap_authorized_pending_qty >= 0)
    and (sap_general_available_qty is null or sap_general_available_qty >= 0)
  );

create index if not exists product_branch_stock_source_batch_idx
  on public.product_branch_stock (source_batch_id) where source_batch_id is not null;
create index if not exists product_branch_stock_commercial_available_idx
  on public.product_branch_stock (branch_id, sap_general_available_qty, product_code);

alter table public.product_branch_prices
  add column if not exists valid_from date not null default current_date,
  add column if not exists valid_until date,
  add column if not exists source_code text;

alter table public.product_branch_prices
  drop constraint if exists product_branch_prices_period_check;
alter table public.product_branch_prices
  add constraint product_branch_prices_period_check
  check (valid_until is null or valid_until >= valid_from);

alter table public.fiscal_tax_rules
  add column if not exists cest text,
  add column if not exists cfop text,
  add column if not exists cst_code text,
  add column if not exists has_st boolean,
  add column if not exists interstate_icms_rate numeric(12,8),
  add column if not exists internal_icms_rate numeric(12,8),
  add column if not exists mva_rate numeric(12,8),
  add column if not exists ipi_rate numeric(12,8),
  add column if not exists pis_rate numeric(12,8),
  add column if not exists cofins_rate numeric(12,8),
  add column if not exists fcp_rate numeric(12,8),
  add column if not exists base_reduction_rate numeric(12,8),
  add column if not exists freight_rate numeric(12,8),
  add column if not exists insurance_rate numeric(12,8),
  add column if not exists other_expenses_rate numeric(12,8),
  add column if not exists source text not null default 'MANUAL',
  add column if not exists source_code text,
  add column if not exists import_batch_id uuid references public.products_import_batches(id) on delete set null,
  add column if not exists rule_version bigint not null default 1,
  add column if not exists created_by uuid references public.profiles(id) on delete set null,
  add column if not exists updated_by uuid references public.profiles(id) on delete set null;

update public.fiscal_tax_rules
set interstate_icms_rate = coalesce(interstate_icms_rate, icms_percent / 100),
    internal_icms_rate = coalesce(internal_icms_rate, icms_st_percent / 100),
    mva_rate = coalesce(mva_rate, mva_percent / 100),
    ipi_rate = coalesce(ipi_rate, ipi_percent / 100),
    pis_rate = coalesce(pis_rate, pis_percent / 100),
    cofins_rate = coalesce(cofins_rate, cofins_percent / 100),
    fcp_rate = coalesce(fcp_rate, fcp_percent / 100),
    base_reduction_rate = coalesce(base_reduction_rate, 0),
    freight_rate = coalesce(freight_rate, 0),
    insurance_rate = coalesce(insurance_rate, 0),
    other_expenses_rate = coalesce(other_expenses_rate, 0),
    has_st = coalesce(has_st, icms_st_percent > 0);

alter table public.fiscal_tax_rules
  drop constraint if exists fiscal_tax_rules_rates_check;
alter table public.fiscal_tax_rules
  add constraint fiscal_tax_rules_rates_check check (
    (interstate_icms_rate is null or interstate_icms_rate between 0 and 1)
    and (internal_icms_rate is null or internal_icms_rate between 0 and 1)
    and (mva_rate is null or mva_rate between 0 and 10)
    and (ipi_rate is null or ipi_rate between 0 and 10)
    and (pis_rate is null or pis_rate between 0 and 1)
    and (cofins_rate is null or cofins_rate between 0 and 1)
    and (fcp_rate is null or fcp_rate between 0 and 1)
    and (base_reduction_rate is null or base_reduction_rate between 0 and 1)
    and (freight_rate is null or freight_rate between 0 and 10)
    and (insurance_rate is null or insurance_rate between 0 and 10)
    and (other_expenses_rate is null or other_expenses_rate between 0 and 10)
  );

alter table public.fiscal_tax_rules
  drop constraint if exists fiscal_tax_rules_cest_format_check;
alter table public.fiscal_tax_rules
  add constraint fiscal_tax_rules_cest_format_check
  check (cest is null or cest ~ '^[0-9]{7}$');

create index if not exists fiscal_tax_rules_route_period_idx
  on public.fiscal_tax_rules (ncm, uf_origem, uf_destino, effective_from desc, effective_to)
  where active;
create index if not exists fiscal_tax_rules_import_batch_idx
  on public.fiscal_tax_rules (import_batch_id) where import_batch_id is not null;

create or replace function public.sync_fractional_fiscal_rates()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.interstate_icms_rate := coalesce(new.interstate_icms_rate, new.icms_percent / 100);
    new.internal_icms_rate := coalesce(new.internal_icms_rate, new.icms_st_percent / 100);
    new.mva_rate := coalesce(new.mva_rate, new.mva_percent / 100);
    new.ipi_rate := coalesce(new.ipi_rate, new.ipi_percent / 100);
    new.pis_rate := coalesce(new.pis_rate, new.pis_percent / 100);
    new.cofins_rate := coalesce(new.cofins_rate, new.cofins_percent / 100);
    new.fcp_rate := coalesce(new.fcp_rate, new.fcp_percent / 100);
  else
    if new.icms_percent is distinct from old.icms_percent then new.interstate_icms_rate := new.icms_percent / 100;
    elsif new.interstate_icms_rate is distinct from old.interstate_icms_rate then new.icms_percent := new.interstate_icms_rate * 100; end if;
    if new.icms_st_percent is distinct from old.icms_st_percent then new.internal_icms_rate := new.icms_st_percent / 100;
    elsif new.internal_icms_rate is distinct from old.internal_icms_rate then new.icms_st_percent := new.internal_icms_rate * 100; end if;
    if new.mva_percent is distinct from old.mva_percent then new.mva_rate := new.mva_percent / 100;
    elsif new.mva_rate is distinct from old.mva_rate then new.mva_percent := new.mva_rate * 100; end if;
    if new.ipi_percent is distinct from old.ipi_percent then new.ipi_rate := new.ipi_percent / 100;
    elsif new.ipi_rate is distinct from old.ipi_rate then new.ipi_percent := new.ipi_rate * 100; end if;
    if new.pis_percent is distinct from old.pis_percent then new.pis_rate := new.pis_percent / 100;
    elsif new.pis_rate is distinct from old.pis_rate then new.pis_percent := new.pis_rate * 100; end if;
    if new.cofins_percent is distinct from old.cofins_percent then new.cofins_rate := new.cofins_percent / 100;
    elsif new.cofins_rate is distinct from old.cofins_rate then new.cofins_percent := new.cofins_rate * 100; end if;
    if new.fcp_percent is distinct from old.fcp_percent then new.fcp_rate := new.fcp_percent / 100;
    elsif new.fcp_rate is distinct from old.fcp_rate then new.fcp_percent := new.fcp_rate * 100; end if;
  end if;
  new.has_st := coalesce(new.has_st, coalesce(new.internal_icms_rate, 0) > 0);
  new.rule_version := case when tg_op = 'UPDATE' then old.rule_version + 1 else coalesce(new.rule_version, 1) end;
  return new;
end;
$$;

drop trigger if exists fiscal_tax_rules_sync_fractional_rates on public.fiscal_tax_rules;
create trigger fiscal_tax_rules_sync_fractional_rates
before insert or update on public.fiscal_tax_rules
for each row execute function public.sync_fractional_fiscal_rates();

create or replace function public.sync_product_ipi_rate()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.ipi_rate := coalesce(new.ipi_rate, new.ipi / 100);
    new.ipi_defined := coalesce(new.ipi_defined, false) or new.ipi_rate is not null and new.ipi <> 0;
  elsif new.ipi is distinct from old.ipi then
    new.ipi_rate := new.ipi / 100;
    new.ipi_defined := true;
  elsif new.ipi_rate is distinct from old.ipi_rate then
    new.ipi := coalesce(new.ipi_rate, 0) * 100;
    new.ipi_defined := new.ipi_rate is not null;
  end if;
  return new;
end;
$$;

update public.products set ipi_rate = ipi / 100 where ipi_rate is null;
drop trigger if exists products_sync_ipi_rate on public.products;
create trigger products_sync_ipi_rate
before insert or update of ipi, ipi_rate on public.products
for each row execute function public.sync_product_ipi_rate();

alter table public.products_import_batches
  add column if not exists import_kind text,
  add column if not exists original_filename text,
  add column if not exists sheet_name text,
  add column if not exists file_size bigint,
  add column if not exists origin_state text,
  add column if not exists destination_state text,
  add column if not exists clear_empty_fields boolean not null default false,
  add column if not exists detected_fields text[] not null default '{}'::text[],
  add column if not exists missing_fields text[] not null default '{}'::text[];

alter table public.products_import_batches drop constraint if exists products_import_batches_contract_check;
alter table public.products_import_batches
  add constraint products_import_batches_contract_check check (contract_version in (0, 1, 2));

alter table public.products_import_batches drop constraint if exists products_import_batches_v2_required_check;
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
      and normalization_algorithm = 'sap-import-v2'
      and hash_algorithm = 'SHA-256')
  );

alter table public.products_import_batches
  drop constraint if exists products_import_batches_origin_state_check;
alter table public.products_import_batches
  add constraint products_import_batches_origin_state_check
  check (origin_state is null or origin_state ~ '^[A-Z]{2}$');

create index if not exists products_import_batches_kind_state_idx
  on public.products_import_batches (import_kind, branch_id, state, created_at desc)
  where contract_version = 2;

create or replace function public.normalize_cest(cest_text text)
returns text
language sql
immutable
parallel safe
as $$
  select case when regexp_replace(coalesce(cest_text, ''), '[^0-9]', '', 'g') ~ '^[0-9]{7}$'
    then regexp_replace(cest_text, '[^0-9]', '', 'g') else null end
$$;

create or replace function public.normalize_fiscal_uf(uf_text text)
returns text
language sql
immutable
parallel safe
as $$
  select case when upper(regexp_replace(coalesce(uf_text, ''), '[^A-Za-z]', '', 'g')) ~ '^[A-Z]{2}$'
    then upper(regexp_replace(uf_text, '[^A-Za-z]', '', 'g')) else null end
$$;

create or replace function public.parse_sap_decimal(value_text text)
returns numeric
language plpgsql
immutable
parallel safe
as $$
declare
  value_normalized text;
begin
  value_normalized := regexp_replace(coalesce(value_text, ''), '[^0-9,.-]', '', 'g');
  if value_normalized = '' or value_normalized in ('-', '.', ',') then return null; end if;
  if value_normalized like '%,%' and value_normalized like '%.%' then
    if strpos(reverse(value_normalized), ',') < strpos(reverse(value_normalized), '.') then
      value_normalized := replace(replace(value_normalized, '.', ''), ',', '.');
    else
      value_normalized := replace(value_normalized, ',', '');
    end if;
  elsif value_normalized like '%,%' then
    value_normalized := replace(value_normalized, ',', '.');
  end if;
  return value_normalized::numeric;
exception when invalid_text_representation or numeric_value_out_of_range then
  return null;
end;
$$;

create or replace function public.parse_sap_rate(value_text text, value_is_percent boolean default true)
returns numeric
language sql
immutable
parallel safe
as $$
  select case
    when public.parse_sap_decimal(value_text) is null then null
    when value_is_percent then public.parse_sap_decimal(value_text) / 100
    else public.parse_sap_decimal(value_text)
  end
$$;

alter table public.product_sap_data enable row level security;
drop policy if exists product_sap_data_read on public.product_sap_data;
create policy product_sap_data_read on public.product_sap_data
for select to authenticated
using (public.is_admin() or public.has_module('produtos') or public.has_module('novo_pedido') or public.has_module('nova_cotacao'));

drop policy if exists product_sap_data_admin_write on public.product_sap_data;
create policy product_sap_data_admin_write on public.product_sap_data
for all to authenticated
using (public.is_admin()) with check (public.is_admin());

insert into public.role_permissions (perfil, modulo, permitido)
values
  ('ADMIN', 'importar_estoque_preco', true),
  ('SUPERVISOR', 'importar_estoque_preco', false),
  ('VENDEDOR', 'importar_estoque_preco', false),
  ('SUPERVISOR', 'aprovar_importacao', false),
  ('VENDEDOR', 'aprovar_importacao', false)
on conflict (perfil, modulo) do nothing;

grant select on public.product_sap_data to authenticated;
grant execute on function public.normalize_cest(text), public.normalize_fiscal_uf(text),
  public.parse_sap_decimal(text), public.parse_sap_rate(text, boolean) to authenticated;

comment on table public.product_sap_data is 'Atributos adicionais do Cadastro Item SAP; os campos comerciais/fiscais canônicos permanecem em products.';
comment on column public.fiscal_tax_rules.interstate_icms_rate is 'Fração decimal: 0.12 representa 12%.';
comment on column public.fiscal_tax_rules.internal_icms_rate is 'Fração decimal da alíquota interna no destino.';
comment on column public.products_import_batches.import_kind is 'Tipo operacional da Central de Importações SAP (contrato 2).';

commit;
