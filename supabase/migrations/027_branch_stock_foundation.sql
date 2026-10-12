begin;

set local lock_timeout = '10s';
set local statement_timeout = '120s';

create table if not exists public.branches (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  state text not null,
  city text not null,
  active boolean not null default true,
  is_headquarters boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branches_code_format_check
    check (code = upper(btrim(code)) and code ~ '^[A-Z0-9][A-Z0-9_-]{0,19}$'),
  constraint branches_name_check check (char_length(btrim(name)) between 2 and 120),
  constraint branches_state_check check (state = upper(btrim(state)) and state ~ '^[A-Z]{2}$'),
  constraint branches_city_check check (char_length(btrim(city)) between 2 and 120)
);

create unique index if not exists branches_single_headquarters_idx
  on public.branches (is_headquarters)
  where is_headquarters;

create table if not exists public.profile_branches (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete restrict,
  is_default boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (profile_id, branch_id)
);

create unique index if not exists profile_branches_single_default_idx
  on public.profile_branches (profile_id)
  where is_default and active;

create index if not exists profile_branches_branch_active_idx
  on public.profile_branches (branch_id, active, profile_id);

create table if not exists public.product_branch_stock (
  product_code text not null references public.products(codigo) on update cascade on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  physical_qty numeric(14,3) not null default 0,
  reserved_order_qty numeric(14,3) not null default 0,
  reserved_transfer_qty numeric(14,3) not null default 0,
  in_transit_qty numeric(14,3) not null default 0,
  quarantined_qty numeric(14,3) not null default 0,
  minimum_stock_qty numeric(14,3) not null default 0,
  reorder_point_qty numeric(14,3) not null default 0,
  target_stock_qty numeric(14,3) not null default 0,
  auto_replenishment_enabled boolean not null default false,
  replenishment_source_branch_id uuid references public.branches(id) on delete restrict,
  available_qty numeric(14,3) generated always as (
    greatest(physical_qty - reserved_order_qty - reserved_transfer_qty, 0::numeric)
  ) stored,
  version bigint not null default 0,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (product_code, branch_id),
  constraint product_branch_stock_physical_check check (physical_qty >= 0),
  constraint product_branch_stock_reserved_order_check check (reserved_order_qty >= 0),
  constraint product_branch_stock_reserved_transfer_check check (reserved_transfer_qty >= 0),
  constraint product_branch_stock_in_transit_check check (in_transit_qty >= 0),
  constraint product_branch_stock_quarantined_check check (quarantined_qty >= 0),
  constraint product_branch_stock_minimum_check check (minimum_stock_qty >= 0),
  constraint product_branch_stock_reorder_check check (reorder_point_qty >= minimum_stock_qty),
  constraint product_branch_stock_target_check check (target_stock_qty >= reorder_point_qty),
  constraint product_branch_stock_reservations_check
    check (reserved_order_qty + reserved_transfer_qty <= physical_qty),
  constraint product_branch_stock_replenishment_source_check
    check (replenishment_source_branch_id is null or replenishment_source_branch_id <> branch_id),
  constraint product_branch_stock_auto_replenishment_check
    check (not auto_replenishment_enabled or replenishment_source_branch_id is not null)
);

create index if not exists product_branch_stock_branch_available_idx
  on public.product_branch_stock (branch_id, available_qty, product_code);

create index if not exists product_branch_stock_replenishment_idx
  on public.product_branch_stock (branch_id, auto_replenishment_enabled, available_qty)
  where auto_replenishment_enabled;

create table if not exists public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id) on delete restrict,
  product_code text not null references public.products(codigo) on update cascade on delete restrict,
  movement_type text not null,
  physical_delta numeric(14,3) not null default 0,
  reserved_order_delta numeric(14,3) not null default 0,
  reserved_transfer_delta numeric(14,3) not null default 0,
  in_transit_delta numeric(14,3) not null default 0,
  quarantined_delta numeric(14,3) not null default 0,
  balance_before jsonb not null,
  balance_after jsonb not null,
  source text not null,
  reference_type text,
  reference_id uuid,
  order_id uuid references public.orders(id) on delete set null,
  order_item_id uuid references public.order_items(id) on delete set null,
  idempotency_key text not null unique,
  reversal_of uuid references public.stock_movements(id) on delete restrict,
  notes text,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint stock_movements_type_check check (movement_type in (
    'MIGRACAO_ESTOQUE_LEGADO',
    'IMPORTACAO_ESTOQUE',
    'RESERVA_PEDIDO',
    'LIBERACAO_RESERVA_PEDIDO',
    'RESERVA_TRANSFERENCIA',
    'LIBERACAO_TRANSFERENCIA',
    'SAIDA_TRANSFERENCIA',
    'ENTRADA_TRANSITO',
    'BAIXA_TRANSITO',
    'ENTRADA_TRANSFERENCIA',
    'ENTRADA_QUARENTENA',
    'LIBERACAO_QUARENTENA',
    'AJUSTE',
    'ESTORNO'
  )),
  constraint stock_movements_nonzero_check check (
    physical_delta <> 0
    or reserved_order_delta <> 0
    or reserved_transfer_delta <> 0
    or in_transit_delta <> 0
    or quarantined_delta <> 0
  ),
  constraint stock_movements_reversal_check check (
    movement_type <> 'ESTORNO' or reversal_of is not null
  )
);

create unique index if not exists stock_movements_single_reversal_idx
  on public.stock_movements (reversal_of)
  where reversal_of is not null;

create index if not exists stock_movements_product_branch_created_idx
  on public.stock_movements (product_code, branch_id, created_at desc);

create index if not exists stock_movements_order_idx
  on public.stock_movements (order_id, created_at desc)
  where order_id is not null;

create index if not exists stock_movements_reference_idx
  on public.stock_movements (reference_type, reference_id, created_at desc)
  where reference_id is not null;

drop trigger if exists branches_touch_updated_at on public.branches;
create trigger branches_touch_updated_at
before update on public.branches
for each row execute function public.touch_updated_at();

drop trigger if exists profile_branches_touch_updated_at on public.profile_branches;
create trigger profile_branches_touch_updated_at
before update on public.profile_branches
for each row execute function public.touch_updated_at();

create or replace function public.touch_product_branch_stock()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  new.version := old.version + 1;
  return new;
end;
$$;

drop trigger if exists product_branch_stock_touch_updated_at on public.product_branch_stock;
create trigger product_branch_stock_touch_updated_at
before update on public.product_branch_stock
for each row execute function public.touch_product_branch_stock();

create or replace function public.reject_stock_movement_mutation()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  raise exception using
    errcode = '55000',
    message = 'MOVIMENTACAO_ESTOQUE_IMUTAVEL';
end;
$$;

drop trigger if exists stock_movements_immutable on public.stock_movements;
create trigger stock_movements_immutable
before update or delete on public.stock_movements
for each row execute function public.reject_stock_movement_mutation();

revoke all on function public.touch_product_branch_stock(),
  public.reject_stock_movement_mutation()
  from public, anon, authenticated;

create or replace function public.can_access_branch(target_branch_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin() or exists (
    select 1
    from public.profile_branches pb
    join public.branches b on b.id = pb.branch_id
    where pb.profile_id = auth.uid()
      and pb.branch_id = target_branch_id
      and pb.active
      and b.active
  )
$$;

create or replace function public.get_default_branch_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select pb.branch_id
  from public.profile_branches pb
  join public.branches b on b.id = pb.branch_id
  where pb.profile_id = auth.uid()
    and pb.is_default
    and pb.active
    and b.active
  limit 1
$$;

alter table public.branches enable row level security;
alter table public.profile_branches enable row level security;
alter table public.product_branch_stock enable row level security;
alter table public.stock_movements enable row level security;

drop policy if exists branches_authenticated_read on public.branches;
create policy branches_authenticated_read on public.branches
for select to authenticated using (true);

drop policy if exists branches_admin_insert on public.branches;
create policy branches_admin_insert on public.branches
for insert to authenticated with check (public.is_admin());

drop policy if exists branches_admin_update on public.branches;
create policy branches_admin_update on public.branches
for update to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists profile_branches_scoped_read on public.profile_branches;
create policy profile_branches_scoped_read on public.profile_branches
for select to authenticated using (profile_id = auth.uid() or public.is_admin());

drop policy if exists profile_branches_admin_insert on public.profile_branches;
create policy profile_branches_admin_insert on public.profile_branches
for insert to authenticated with check (public.is_admin());

drop policy if exists profile_branches_admin_update on public.profile_branches;
create policy profile_branches_admin_update on public.profile_branches
for update to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists profile_branches_admin_delete on public.profile_branches;
create policy profile_branches_admin_delete on public.profile_branches
for delete to authenticated using (public.is_admin());

drop policy if exists product_branch_stock_commercial_read on public.product_branch_stock;
create policy product_branch_stock_commercial_read on public.product_branch_stock
for select to authenticated using (
  public.is_admin()
  or public.has_module('produtos')
  or public.has_module('novo_pedido')
  or public.has_module('nova_cotacao')
  or public.has_module('alimentacao')
  or public.has_module('dashboard')
);

drop policy if exists stock_movements_audit_read on public.stock_movements;
create policy stock_movements_audit_read on public.stock_movements
for select to authenticated using (public.is_admin() or public.has_module('logs'));

revoke all on public.branches, public.profile_branches, public.product_branch_stock, public.stock_movements
  from public, anon, authenticated;

grant select on public.branches, public.product_branch_stock to authenticated;
grant select, insert, update on public.branches to authenticated;
grant select, insert, update, delete on public.profile_branches to authenticated;
grant select on public.stock_movements to authenticated;

revoke all on function public.can_access_branch(uuid), public.get_default_branch_id()
  from public, anon;
grant execute on function public.can_access_branch(uuid), public.get_default_branch_id()
  to authenticated;

insert into public.branches (code, name, state, city, active, is_headquarters)
values
  ('PR', 'Matriz PR', 'PR', 'Curitiba', true, true),
  ('SP', 'Filial SP', 'SP', 'Sao Paulo', true, false)
on conflict (code) do nothing;

do $$
declare
  v_pr_branch_id uuid;
  v_sp_branch_id uuid;
begin
  select id into v_pr_branch_id from public.branches where code = 'PR';
  select id into v_sp_branch_id from public.branches where code = 'SP';

  if v_pr_branch_id is null or v_sp_branch_id is null then
    raise exception 'FILIAIS_INICIAIS_NAO_CRIADAS';
  end if;

  if exists (select 1 from public.products where estoque_quantidade < 0) then
    raise exception 'ESTOQUE_LEGADO_NEGATIVO';
  end if;

  insert into public.product_branch_stock (
    product_code, branch_id, physical_qty
  )
  select p.codigo, v_pr_branch_id, p.estoque_quantidade
  from public.products p
  on conflict (product_code, branch_id) do nothing;

  insert into public.product_branch_stock (
    product_code, branch_id, physical_qty
  )
  select p.codigo, v_sp_branch_id, 0
  from public.products p
  on conflict (product_code, branch_id) do nothing;

  insert into public.stock_movements (
    branch_id,
    product_code,
    movement_type,
    physical_delta,
    balance_before,
    balance_after,
    source,
    reference_type,
    idempotency_key,
    metadata
  )
  select
    v_pr_branch_id,
    p.codigo,
    'MIGRACAO_ESTOQUE_LEGADO',
    p.estoque_quantidade,
    jsonb_build_object(
      'physical_qty', 0,
      'reserved_order_qty', 0,
      'reserved_transfer_qty', 0,
      'in_transit_qty', 0,
      'quarantined_qty', 0
    ),
    jsonb_build_object(
      'physical_qty', p.estoque_quantidade,
      'reserved_order_qty', 0,
      'reserved_transfer_qty', 0,
      'in_transit_qty', 0,
      'quarantined_qty', 0
    ),
    'MIGRACAO_FUNDACAO_027',
    'products',
    'foundation-027:legacy:PR:' || p.codigo,
    jsonb_build_object('legacy_column', 'products.estoque_quantidade')
  from public.products p
  where p.estoque_quantidade > 0
  on conflict (idempotency_key) do nothing;
end;
$$;

create or replace function public.sync_legacy_product_stock_to_pr()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pr_branch_id uuid;
  v_sp_branch_id uuid;
  v_old_qty numeric(14,3) := case when tg_op = 'INSERT' then 0 else old.estoque_quantidade end;
  v_new_qty numeric(14,3) := coalesce(new.estoque_quantidade, 0);
  v_before jsonb;
  v_after jsonb;
begin
  if v_new_qty < 0 then
    raise exception 'ESTOQUE_LEGADO_NEGATIVO';
  end if;

  select id into v_pr_branch_id from public.branches where code = 'PR';
  select id into v_sp_branch_id from public.branches where code = 'SP';

  if v_pr_branch_id is null or v_sp_branch_id is null then
    raise exception 'FILIAIS_INICIAIS_NAO_CRIADAS';
  end if;

  insert into public.product_branch_stock (product_code, branch_id, physical_qty, updated_by)
  values (new.codigo, v_sp_branch_id, 0, auth.uid())
  on conflict (product_code, branch_id) do nothing;

  select jsonb_build_object(
    'physical_qty', s.physical_qty,
    'reserved_order_qty', s.reserved_order_qty,
    'reserved_transfer_qty', s.reserved_transfer_qty,
    'in_transit_qty', s.in_transit_qty,
    'quarantined_qty', s.quarantined_qty
  )
  into v_before
  from public.product_branch_stock s
  where s.product_code = new.codigo
    and s.branch_id = v_pr_branch_id
  for update;

  if v_before is null then
    v_before := jsonb_build_object(
      'physical_qty', 0,
      'reserved_order_qty', 0,
      'reserved_transfer_qty', 0,
      'in_transit_qty', 0,
      'quarantined_qty', 0
    );

    insert into public.product_branch_stock (
      product_code, branch_id, physical_qty, updated_by
    )
    values (
      new.codigo, v_pr_branch_id, v_new_qty, auth.uid()
    );
  elsif v_old_qty is distinct from v_new_qty then
    update public.product_branch_stock s
    set physical_qty = v_new_qty,
        updated_by = auth.uid()
    where s.product_code = new.codigo
      and s.branch_id = v_pr_branch_id;
  end if;

  if v_old_qty is not distinct from v_new_qty then
    return new;
  end if;

  select jsonb_build_object(
    'physical_qty', s.physical_qty,
    'reserved_order_qty', s.reserved_order_qty,
    'reserved_transfer_qty', s.reserved_transfer_qty,
    'in_transit_qty', s.in_transit_qty,
    'quarantined_qty', s.quarantined_qty
  )
  into v_after
  from public.product_branch_stock s
  where s.product_code = new.codigo
    and s.branch_id = v_pr_branch_id;

  insert into public.stock_movements (
    branch_id,
    product_code,
    movement_type,
    physical_delta,
    balance_before,
    balance_after,
    source,
    reference_type,
    idempotency_key,
    created_by,
    metadata
  )
  values (
    v_pr_branch_id,
    new.codigo,
    'IMPORTACAO_ESTOQUE',
    v_new_qty - v_old_qty,
    v_before,
    v_after,
    'LEGACY_PRODUCTS_SYNC',
    'products',
    'legacy-products-sync:' || gen_random_uuid()::text,
    auth.uid(),
    jsonb_build_object('legacy_column', 'products.estoque_quantidade', 'operation', tg_op)
  );

  return new;
end;
$$;

drop trigger if exists products_insert_sync_legacy_stock_to_pr on public.products;
create trigger products_insert_sync_legacy_stock_to_pr
after insert on public.products
for each row execute function public.sync_legacy_product_stock_to_pr();

drop trigger if exists products_update_sync_legacy_stock_to_pr on public.products;
create trigger products_update_sync_legacy_stock_to_pr
after update of estoque_quantidade on public.products
for each row execute function public.sync_legacy_product_stock_to_pr();

revoke all on function public.sync_legacy_product_stock_to_pr() from public, anon, authenticated;

commit;
