begin;

set local lock_timeout = '10s';
set local statement_timeout = '180s';

create extension if not exists pgcrypto with schema extensions;

alter table public.products_import_batches
  add column if not exists branch_id uuid references public.branches(id) on delete restrict,
  add column if not exists mode text,
  add column if not exists contract_version integer not null default 0,
  add column if not exists field_mask text[] not null default '{}'::text[],
  add column if not exists client_file_hash text,
  add column if not exists normalized_file_hash text,
  add column if not exists normalization_algorithm text,
  add column if not exists hash_algorithm text,
  add column if not exists idempotency_key text,
  add column if not exists state text,
  add column if not exists created_by_profile_id uuid references public.profiles(id) on delete set null,
  add column if not exists approved_by_profile_id uuid references public.profiles(id) on delete set null,
  add column if not exists committed_by_profile_id uuid references public.profiles(id) on delete set null,
  add column if not exists previewed_at timestamptz,
  add column if not exists committed_at timestamptz,
  add column if not exists last_attempt_started_at timestamptz,
  add column if not exists last_attempt_completed_at timestamptz,
  add column if not exists last_failure_code text,
  add column if not exists last_failure_details jsonb,
  add column if not exists last_failure_at timestamptz,
  add column if not exists attempt_count integer not null default 0,
  add column if not exists staging_revision bigint not null default 0,
  add column if not exists rollback_status text not null default 'NOT_REQUESTED',
  add column if not exists rollback_summary jsonb,
  add column if not exists rollback_started_at timestamptz,
  add column if not exists rollback_completed_at timestamptz,
  add column if not exists rollback_requested_by uuid references public.profiles(id) on delete set null;

update public.products_import_batches
set state = case lower(coalesce(status, 'draft'))
  when 'draft' then 'DRAFT'
  when 'validating' then 'DRAFT'
  when 'validated' then 'PREVIEWED'
  when 'approved' then 'APPROVED'
  when 'committed' then 'COMMITTED'
  when 'imported' then 'COMMITTED'
  when 'failed' then 'FAILED'
  else 'FAILED'
end
where state is null;

alter table public.products_import_batches
  alter column state set default 'DRAFT',
  alter column state set not null;

alter table public.products_import_stage
  add column if not exists normalized_code text,
  add column if not exists provided_fields text[] not null default '{}'::text[],
  add column if not exists field_mask text[] not null default '{}'::text[],
  add column if not exists row_hash text,
  add column if not exists planned_action text,
  add column if not exists product_before jsonb,
  add column if not exists product_after jsonb,
  add column if not exists stock_before jsonb,
  add column if not exists stock_after jsonb,
  add column if not exists price_before jsonb,
  add column if not exists price_after jsonb,
  add column if not exists product_version timestamptz,
  add column if not exists stock_version bigint,
  add column if not exists price_version bigint,
  add column if not exists physical_delta numeric(14,3),
  add column if not exists blocking_errors jsonb not null default '[]'::jsonb,
  add column if not exists ignored_fields jsonb not null default '[]'::jsonb;

alter table public.products_import_audit
  add column if not exists stage_id uuid references public.products_import_stage(id) on delete set null,
  add column if not exists branch_id uuid references public.branches(id) on delete restrict,
  add column if not exists entity_type text,
  add column if not exists version_before bigint,
  add column if not exists version_after bigint,
  add column if not exists stock_movement_id uuid references public.stock_movements(id) on delete restrict,
  add column if not exists rollback_action text,
  add column if not exists rollback_status text,
  add column if not exists rollback_details jsonb;

create table if not exists public.branch_import_legacy_function_snapshots (
  function_signature text primary key,
  function_name text not null unique,
  function_definition text not null,
  owner_name name not null,
  acl_state text not null,
  config_state text not null,
  definition_md5 text not null,
  captured_at timestamptz not null default now()
);

revoke all on public.branch_import_legacy_function_snapshots
from public, anon, authenticated;

create table if not exists public.branch_import_legacy_table_acl_snapshots (
  table_name text primary key,
  owner_name name not null,
  raw_acl_state aclitem[],
  effective_acl_state aclitem[] not null,
  raw_acl_md5 text not null,
  captured_at timestamptz not null default now()
);

revoke all on public.branch_import_legacy_table_acl_snapshots
from public, anon, authenticated;

do $capture_legacy_table_acls$
begin
  insert into public.branch_import_legacy_table_acl_snapshots (
    table_name,
    owner_name,
    raw_acl_state,
    effective_acl_state,
    raw_acl_md5
  )
  select
    format('%I.%I', n.nspname, c.relname),
    owner_role.rolname,
    c.relacl,
    coalesce(c.relacl, acldefault('r', c.relowner)),
    md5(coalesce(c.relacl::text, '<NULL>'))
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join pg_roles owner_role on owner_role.oid = c.relowner
  where c.oid in (
    'public.products_import_batches'::regclass,
    'public.products_import_stage'::regclass,
    'public.products_import_audit'::regclass
  )
  on conflict (table_name) do nothing;

  if (
    select count(*)
    from public.branch_import_legacy_table_acl_snapshots
    where table_name in (
      'public.products_import_batches',
      'public.products_import_stage',
      'public.products_import_audit'
    )
  ) <> 3 then
    raise exception using
      errcode = 'P2807',
      message = 'LEGACY_IMPORT_TABLE_ACL_SNAPSHOT_INCOMPLETE';
  end if;
end
$capture_legacy_table_acls$;

do $capture_legacy_functions$
declare
  v_signature text;
  v_proc regprocedure;
begin
  foreach v_signature in array array[
    'public.create_products_import_batch(jsonb)',
    'public.preview_products_import_batch(uuid)',
    'public.approve_products_import_batch(uuid)',
    'public.commit_products_import_batch(uuid)',
    'public.get_products_import_batches_report(jsonb)',
    'public.get_products_import_batch_details(uuid,integer,integer)'
  ]
  loop
    v_proc := to_regprocedure(v_signature);
    if v_proc is null then
      raise exception using
        errcode = 'P2807',
        message = 'LEGACY_IMPORT_FUNCTION_MISSING';
    end if;

    insert into public.branch_import_legacy_function_snapshots (
      function_signature,
      function_name,
      function_definition,
      owner_name,
      acl_state,
      config_state,
      definition_md5
    )
    select
      v_signature,
      p.proname,
      pg_get_functiondef(p.oid),
      owner_role.rolname,
      coalesce(p.proacl::text, '<NULL>'),
      coalesce(p.proconfig::text, '<NULL>'),
      md5(pg_get_functiondef(p.oid))
    from pg_proc p
    join pg_roles owner_role on owner_role.oid = p.proowner
    where p.oid = v_proc
    on conflict (function_signature) do nothing;
  end loop;

  if (
    select count(*)
    from public.branch_import_legacy_function_snapshots
    where function_signature = any(array[
      'public.create_products_import_batch(jsonb)',
      'public.preview_products_import_batch(uuid)',
      'public.approve_products_import_batch(uuid)',
      'public.commit_products_import_batch(uuid)',
      'public.get_products_import_batches_report(jsonb)',
      'public.get_products_import_batch_details(uuid,integer,integer)'
    ])
  ) <> 6 then
    raise exception using
      errcode = 'P2807',
      message = 'LEGACY_IMPORT_SNAPSHOT_INCOMPLETE';
  end if;
end
$capture_legacy_functions$;

do $create_legacy_implementations$
declare
  v_item record;
  v_definition text;
begin
  for v_item in
    select *
    from (values
      (
        'public.create_products_import_batch(jsonb)',
        'create_products_import_batch',
        'create_products_import_batch_v0_impl'
      ),
      (
        'public.preview_products_import_batch(uuid)',
        'preview_products_import_batch',
        'preview_products_import_batch_v0_impl'
      ),
      (
        'public.approve_products_import_batch(uuid)',
        'approve_products_import_batch',
        'approve_products_import_batch_v0_impl'
      ),
      (
        'public.commit_products_import_batch(uuid)',
        'commit_products_import_batch',
        'commit_products_import_batch_v0_impl'
      ),
      (
        'public.get_products_import_batch_details(uuid,integer,integer)',
        'get_products_import_batch_details',
        'get_products_import_batch_details_v0_impl'
      ),
      (
        'public.get_products_import_batches_report(jsonb)',
        'get_products_import_batches_report',
        'get_products_import_batches_report_v0_impl'
      )
    ) definitions(function_signature, original_name, implementation_name)
  loop
    select replace(
      function_definition,
      v_item.original_name,
      v_item.implementation_name
    )
    into strict v_definition
    from public.branch_import_legacy_function_snapshots
    where function_signature = v_item.function_signature;

    execute v_definition;
  end loop;
end
$create_legacy_implementations$;

revoke all on function
  public.create_products_import_batch_v0_impl(jsonb),
  public.preview_products_import_batch_v0_impl(uuid),
  public.approve_products_import_batch_v0_impl(uuid),
  public.commit_products_import_batch_v0_impl(uuid),
  public.get_products_import_batches_report_v0_impl(jsonb),
  public.get_products_import_batch_details_v0_impl(uuid, integer, integer)
from public, anon, authenticated;

do $constraints$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'products_import_batches_contract_check'
      and conrelid = 'public.products_import_batches'::regclass
  ) then
    alter table public.products_import_batches
      add constraint products_import_batches_contract_check
      check (contract_version in (0, 1));
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'products_import_batches_state_check'
      and conrelid = 'public.products_import_batches'::regclass
  ) then
    alter table public.products_import_batches
      add constraint products_import_batches_state_check check (state in (
        'DRAFT', 'PREVIEWED', 'APPROVED', 'COMMITTING', 'COMMITTED',
        'REVALIDATION_REQUIRED', 'FAILED'
      ));
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'products_import_batches_rollback_check'
      and conrelid = 'public.products_import_batches'::regclass
  ) then
    alter table public.products_import_batches
      add constraint products_import_batches_rollback_check check (rollback_status in (
        'NOT_REQUESTED', 'PENDING', 'PROCESSING', 'COMPLETED',
        'PARTIAL', 'BLOCKED', 'FAILED'
      ));
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'products_import_batches_v2_required_check'
      and conrelid = 'public.products_import_batches'::regclass
  ) then
    alter table public.products_import_batches
      add constraint products_import_batches_v2_required_check check (
        contract_version = 0 or (
          branch_id is not null
          and mode in ('UPDATE_STOCK', 'UPDATE_PRICES', 'CREATE_PRODUCTS', 'CUSTOM_UPDATE', 'FULL_IMPORT')
          and cardinality(field_mask) > 0
          and normalization_algorithm = 'branch-import-v1'
          and hash_algorithm = 'SHA-256'
          and (
            state in ('DRAFT', 'FAILED')
            or (
              normalized_file_hash is not null
              and idempotency_key is not null
            )
          )
        )
      );
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'products_import_batches_attempt_check'
      and conrelid = 'public.products_import_batches'::regclass
  ) then
    alter table public.products_import_batches
      add constraint products_import_batches_attempt_check check (attempt_count >= 0);
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'products_import_batches_staging_revision_check'
      and conrelid = 'public.products_import_batches'::regclass
  ) then
    alter table public.products_import_batches
      add constraint products_import_batches_staging_revision_check
      check (staging_revision >= 0);
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'products_import_stage_action_check'
      and conrelid = 'public.products_import_stage'::regclass
  ) then
    alter table public.products_import_stage
      add constraint products_import_stage_action_check check (
        planned_action is null or planned_action in ('INSERT', 'UPDATE', 'NO_CHANGE')
      );
  end if;
end
$constraints$;

do $index_ownership$
declare
  v_item record;
begin
  for v_item in
    select *
    from (values
      ('products_import_batches_v2_idempotency_idx', 'products_import_batches'),
      ('products_import_batches_branch_state_idx', 'products_import_batches'),
      ('products_import_stage_v2_code_idx', 'products_import_stage'),
      ('products_import_stage_v2_row_idx', 'products_import_stage'),
      ('products_import_audit_stage_idx', 'products_import_audit'),
      ('products_import_audit_movement_idx', 'products_import_audit')
    ) expected(index_name, table_name)
  loop
    if to_regclass('public.' || v_item.index_name) is not null
       and not exists (
         select 1
         from pg_index i
         where i.indexrelid = to_regclass('public.' || v_item.index_name)
           and i.indrelid = to_regclass('public.' || v_item.table_name)
       ) then
      raise exception using
        errcode = 'P2806',
        message = 'INDEX_NAME_COLLISION:' || v_item.index_name;
    end if;
  end loop;
end
$index_ownership$;

create unique index if not exists products_import_batches_v2_idempotency_idx
  on public.products_import_batches (idempotency_key)
  where contract_version >= 1
    and idempotency_key is not null
    and state = 'COMMITTED';

create index if not exists products_import_batches_branch_state_idx
  on public.products_import_batches (branch_id, state, created_at desc)
  where contract_version >= 1;

create unique index if not exists products_import_stage_v2_code_idx
  on public.products_import_stage (batch_id, normalized_code)
  where normalized_code is not null;

create unique index if not exists products_import_stage_v2_row_idx
  on public.products_import_stage (batch_id, row_number)
  where normalized_code is not null;

create index if not exists products_import_audit_stage_idx
  on public.products_import_audit (batch_id, stage_id);

create index if not exists products_import_audit_movement_idx
  on public.products_import_audit (stock_movement_id)
  where stock_movement_id is not null;

create table if not exists public.product_branch_prices (
  product_code text not null references public.products(codigo) on update cascade on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  sale_price numeric(14,4) not null,
  currency char(3) not null default 'BRL',
  version bigint not null default 1,
  source text not null,
  source_batch_id uuid references public.products_import_batches(id) on delete restrict,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (product_code, branch_id),
  constraint product_branch_prices_price_check check (sale_price >= 0),
  constraint product_branch_prices_currency_check
    check (currency = upper(currency) and currency ~ '^[A-Z]{3}$'),
  constraint product_branch_prices_version_check check (version >= 1),
  constraint product_branch_prices_source_check
    check (source in ('LEGACY_BACKFILL', 'LEGACY_SYNC', 'BRANCH_IMPORT_V2', 'MANUAL')),
  constraint product_branch_prices_batch_source_check check (
    (source = 'BRANCH_IMPORT_V2' and source_batch_id is not null)
    or (source <> 'BRANCH_IMPORT_V2' and source_batch_id is null)
  )
);

do $price_index_ownership$
begin
  if to_regclass('public.product_branch_prices_branch_price_idx') is not null
     and not exists (
       select 1
       from pg_index i
       where i.indexrelid =
         to_regclass('public.product_branch_prices_branch_price_idx')
         and i.indrelid = 'public.product_branch_prices'::regclass
     ) then
    raise exception using
      errcode = 'P2806',
      message = 'INDEX_NAME_COLLISION:product_branch_prices_branch_price_idx';
  end if;
end
$price_index_ownership$;

create index if not exists product_branch_prices_branch_price_idx
  on public.product_branch_prices (branch_id, sale_price, product_code);

create or replace function public.touch_product_branch_price()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if row(new.sale_price, new.currency, new.source, new.source_batch_id)
     is not distinct from
     row(old.sale_price, old.currency, old.source, old.source_batch_id) then
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

drop trigger if exists product_branch_prices_touch on public.product_branch_prices;
create trigger product_branch_prices_touch
before update on public.product_branch_prices
for each row execute function public.touch_product_branch_price();

alter table public.product_branch_prices enable row level security;

drop policy if exists product_branch_prices_scoped_read on public.product_branch_prices;
create policy product_branch_prices_scoped_read
on public.product_branch_prices
for select to authenticated
using (
  public.can_access_branch(branch_id)
  and (
    public.is_admin()
    or public.has_module('produtos')
    or public.has_module('novo_pedido')
    or public.has_module('nova_cotacao')
    or public.has_module('alimentacao')
    or public.has_module('dashboard')
  )
);

revoke all on public.product_branch_prices from public, anon, authenticated;
grant select on public.product_branch_prices to authenticated;

revoke all on function public.touch_product_branch_price() from public, anon, authenticated;

create or replace function public.resolve_branch_import_initial_branches()
returns table (pr_branch_id uuid, sp_branch_id uuid)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pr_count integer;
  v_sp_count integer;
  v_pr public.branches;
  v_sp public.branches;
begin
  select count(*) into v_pr_count from public.branches where code = 'PR';
  select count(*) into v_sp_count from public.branches where code = 'SP';

  if v_pr_count <> 1 then
    raise exception using
      errcode = 'P2801',
      message = case
        when v_pr_count = 0 then 'BRANCH_PR_MISSING'
        else 'BRANCH_PR_DUPLICATED'
      end;
  end if;
  if v_sp_count <> 1 then
    raise exception using
      errcode = 'P2802',
      message = case
        when v_sp_count = 0 then 'BRANCH_SP_MISSING'
        else 'BRANCH_SP_DUPLICATED'
      end;
  end if;

  select * into strict v_pr from public.branches where code = 'PR';
  select * into strict v_sp from public.branches where code = 'SP';

  if not v_pr.active
     or v_pr.state <> 'PR'
     or not v_pr.is_headquarters then
    raise exception using
      errcode = 'P2803',
      message = 'BRANCH_PR_IDENTITY_INVALID';
  end if;
  if not v_sp.active
     or v_sp.state <> 'SP'
     or v_sp.is_headquarters then
    raise exception using
      errcode = 'P2804',
      message = 'BRANCH_SP_IDENTITY_INVALID';
  end if;
  if v_pr.id = v_sp.id then
    raise exception using
      errcode = 'P2805',
      message = 'BRANCH_IDENTITIES_COLLIDE';
  end if;

  return query select v_pr.id, v_sp.id;
end;
$$;

revoke all on function public.resolve_branch_import_initial_branches()
from public, anon, authenticated;

do $scope_legacy_batches$
declare
  v_pr uuid;
  v_sp uuid;
begin
  select pr_branch_id, sp_branch_id into v_pr, v_sp
  from public.resolve_branch_import_initial_branches();

  update public.products_import_batches b
  set branch_id = case upper(btrim(b.region))
    when 'PR' then v_pr
    when 'SP' then v_sp
  end
  where b.contract_version = 0
    and b.branch_id is null
    and upper(btrim(coalesce(b.region, ''))) in ('PR', 'SP');

  update public.products_import_batches b
  set created_by_profile_id = matched.profile_id
  from (
    select candidate.created_by, min(candidate.profile_id::text)::uuid as profile_id
    from (
      select b2.created_by, p.id as profile_id
      from public.products_import_batches b2
      join public.profiles p on p.usuario = b2.created_by
      where b2.contract_version = 0
        and b2.created_by_profile_id is null
        and b2.created_by is not null
    ) candidate
    group by candidate.created_by
    having count(distinct candidate.profile_id) = 1
  ) matched
  where b.contract_version = 0
    and b.created_by_profile_id is null
    and b.created_by = matched.created_by;
end
$scope_legacy_batches$;

create or replace function public.can_access_product_import_batch_row(
  batch_contract_version integer,
  batch_branch_id uuid,
  batch_created_by_profile_id uuid,
  batch_created_by text,
  require_approval boolean default false,
  require_owner boolean default false,
  require_report_permission boolean default false
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.ativo
      and (
        public.is_admin()
        or (
          case
            when require_approval then public.can_approve_products_import()
            when require_report_permission then public.can_view_products_import_batches()
            else public.has_module('alimentacao')
              or public.can_approve_products_import()
          end
        )
      )
      and (
        public.is_admin()
        or (
          batch_contract_version >= 1
          and batch_branch_id is not null
          and public.can_access_branch(batch_branch_id)
        )
        or (
          batch_contract_version = 0
          and (
            (
              batch_branch_id is not null
              and public.can_access_branch(batch_branch_id)
            )
            or (
              batch_branch_id is null
              and (
                (
                  batch_created_by_profile_id is not null
                  and batch_created_by_profile_id is not distinct from auth.uid()
                )
                or (
                  batch_created_by_profile_id is null
                  and batch_created_by is not null
                  and batch_created_by is not distinct from p.usuario
                )
              )
            )
          )
        )
      )
      and (
        not require_owner
        or public.is_admin()
        or (
          batch_created_by_profile_id is not null
          and batch_created_by_profile_id is not distinct from auth.uid()
        )
        or (
          batch_created_by_profile_id is null
          and batch_created_by is not null
          and batch_created_by is not distinct from p.usuario
        )
      )
  );
$$;

revoke all on function public.can_access_product_import_batch_row(
  integer, uuid, uuid, text, boolean, boolean, boolean
) from public, anon;

grant execute on function public.can_access_product_import_batch_row(
  integer, uuid, uuid, text, boolean, boolean, boolean
) to authenticated;

do $backfill$
declare
  v_pr uuid;
  v_sp uuid;
begin
  select pr_branch_id, sp_branch_id into v_pr, v_sp
  from public.resolve_branch_import_initial_branches();

  if exists (
    select 1
    from public.product_branch_prices bp
    join public.products p on p.codigo = bp.product_code
    where (bp.branch_id = v_pr and p.preco_pr is not null and (
      bp.sale_price is distinct from p.preco_pr
      or bp.currency <> 'BRL'
      or bp.source <> 'LEGACY_BACKFILL'
      or bp.source_batch_id is not null
    ))
    or (bp.branch_id = v_sp and p.preco_sp is not null and (
      bp.sale_price is distinct from p.preco_sp
      or bp.currency <> 'BRL'
      or bp.source <> 'LEGACY_BACKFILL'
      or bp.source_batch_id is not null
    ))
  ) then
    raise exception 'BACKFILL_PRECOS_DIVERGENTE';
  end if;

  insert into public.product_branch_prices (
    product_code, branch_id, sale_price, currency, version, source
  )
  select p.codigo, v_pr, p.preco_pr, 'BRL', 1, 'LEGACY_BACKFILL'
  from public.products p
  where p.preco_pr is not null
  on conflict (product_code, branch_id) do nothing;

  insert into public.product_branch_prices (
    product_code, branch_id, sale_price, currency, version, source
  )
  select p.codigo, v_sp, p.preco_sp, 'BRL', 1, 'LEGACY_BACKFILL'
  from public.products p
  where p.preco_sp is not null
  on conflict (product_code, branch_id) do nothing;
end
$backfill$;

create or replace function public.sync_legacy_product_prices_to_branches()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pr uuid;
  v_sp uuid;
begin
  if current_setting('app.price_sync_source', true) = 'BRANCH_IMPORT_V2' then
    return new;
  end if;

  select pr_branch_id, sp_branch_id into v_pr, v_sp
  from public.resolve_branch_import_initial_branches();

  if tg_op = 'INSERT' or old.preco_pr is distinct from new.preco_pr then
    if new.preco_pr is null then
      delete from public.product_branch_prices
      where product_code = new.codigo and branch_id = v_pr;
    else
      insert into public.product_branch_prices (
        product_code, branch_id, sale_price, currency, source,
        source_batch_id, updated_by
      )
      values (
        new.codigo, v_pr, new.preco_pr, 'BRL', 'LEGACY_SYNC',
        null, auth.uid()
      )
      on conflict (product_code, branch_id) do update
      set sale_price = excluded.sale_price,
          currency = excluded.currency,
          source = excluded.source,
          source_batch_id = null,
          updated_by = excluded.updated_by
      where product_branch_prices.sale_price is distinct from excluded.sale_price
         or product_branch_prices.currency is distinct from excluded.currency;
    end if;
  end if;

  if tg_op = 'INSERT' or old.preco_sp is distinct from new.preco_sp then
    if new.preco_sp is null then
      delete from public.product_branch_prices
      where product_code = new.codigo and branch_id = v_sp;
    else
      insert into public.product_branch_prices (
        product_code, branch_id, sale_price, currency, source,
        source_batch_id, updated_by
      )
      values (
        new.codigo, v_sp, new.preco_sp, 'BRL', 'LEGACY_SYNC',
        null, auth.uid()
      )
      on conflict (product_code, branch_id) do update
      set sale_price = excluded.sale_price,
          currency = excluded.currency,
          source = excluded.source,
          source_batch_id = null,
          updated_by = excluded.updated_by
      where product_branch_prices.sale_price is distinct from excluded.sale_price
         or product_branch_prices.currency is distinct from excluded.currency;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists products_sync_legacy_prices_to_branches on public.products;
create trigger products_sync_legacy_prices_to_branches
after insert or update of preco_pr, preco_sp on public.products
for each row execute function public.sync_legacy_product_prices_to_branches();

revoke all on function public.sync_legacy_product_prices_to_branches()
from public, anon, authenticated;

create or replace function public.branch_import_allowed_fields(target_mode text)
returns text[]
language sql
immutable
set search_path = public
as $$
  select case upper(target_mode)
    when 'UPDATE_STOCK' then array[
      'physical_qty', 'product_code', 'stock_status'
    ]::text[]
    when 'UPDATE_PRICES' then array[
      'currency', 'product_code', 'sale_price'
    ]::text[]
    when 'CREATE_PRODUCTS' then array[
      'application', 'brand', 'category', 'currency', 'description', 'details',
      'group', 'image_url', 'ipi', 'manufacturer', 'oem', 'physical_qty',
      'product_code', 'registration_status', 'sale_price', 'similar',
      'stock_label', 'stock_status', 'tax_free_price', 'year'
    ]::text[]
    when 'CUSTOM_UPDATE' then array[
      'application', 'brand', 'category', 'currency', 'description', 'details',
      'group', 'image_url', 'ipi', 'manufacturer', 'oem', 'physical_qty',
      'product_code', 'registration_status', 'sale_price', 'similar',
      'stock_label', 'stock_status', 'tax_free_price', 'year'
    ]::text[]
    when 'FULL_IMPORT' then array[
      'application', 'brand', 'category', 'currency', 'description', 'details',
      'group', 'image_url', 'ipi', 'manufacturer', 'oem', 'physical_qty',
      'product_code', 'registration_status', 'sale_price', 'similar',
      'stock_label', 'stock_status', 'tax_free_price', 'year'
    ]::text[]
    else '{}'::text[]
  end
$$;

create or replace function public.normalize_branch_import_mask(
  target_mode text,
  target_mask text[]
)
returns text[]
language plpgsql
immutable
set search_path = public
as $$
declare
  v_mode text := upper(coalesce(target_mode, ''));
  v_mask text[];
  v_allowed text[];
begin
  if v_mode not in ('UPDATE_STOCK', 'UPDATE_PRICES', 'CREATE_PRODUCTS', 'CUSTOM_UPDATE', 'FULL_IMPORT') then
    raise exception 'MODO_IMPORTACAO_INVALIDO';
  end if;

  select coalesce(array_agg(distinct lower(btrim(value)) order by lower(btrim(value))), '{}'::text[])
  into v_mask
  from unnest(coalesce(target_mask, '{}'::text[])) value
  where nullif(btrim(value), '') is not null;

  v_allowed := public.branch_import_allowed_fields(v_mode);

  if cardinality(v_mask) = 0 or not ('product_code' = any(v_mask)) then
    raise exception 'MASCARA_SEM_PRODUCT_CODE';
  end if;

  if exists (select 1 from unnest(v_mask) value where not (value = any(v_allowed))) then
    raise exception 'MASCARA_CONTEM_CAMPO_INVALIDO';
  end if;

  if v_mode = 'UPDATE_STOCK' and not ('physical_qty' = any(v_mask)) then
    raise exception 'MASCARA_SEM_PHYSICAL_QTY';
  end if;
  if v_mode = 'UPDATE_PRICES' and not ('sale_price' = any(v_mask)) then
    raise exception 'MASCARA_SEM_SALE_PRICE';
  end if;
  if v_mode = 'CREATE_PRODUCTS' and not ('description' = any(v_mask)) then
    raise exception 'MASCARA_SEM_DESCRIPTION';
  end if;
  if v_mode = 'CUSTOM_UPDATE' and cardinality(v_mask) < 2 then
    raise exception 'MASCARA_CUSTOM_SEM_CAMPO_ATUALIZAVEL';
  end if;

  return v_mask;
end;
$$;

create or replace function public.canonicalize_branch_import_data(
  provided_fields text[],
  input_data jsonb
)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_field text;
  v_text text;
  v_numeric numeric;
  v_result jsonb := '{}'::jsonb;
  v_numeric_fields constant text[] := array[
    'ipi', 'physical_qty', 'sale_price', 'tax_free_price'
  ];
begin
  for v_field in
    select distinct lower(btrim(value))
    from unnest(coalesce(provided_fields, '{}'::text[])) value
    where nullif(btrim(value), '') is not null
    order by 1
  loop
    if not coalesce(input_data, '{}'::jsonb) ? v_field then
      v_result := v_result || jsonb_build_object(
        v_field, jsonb_build_object('state', 'absent')
      );
    elsif jsonb_typeof(input_data->v_field) = 'null' then
      v_result := v_result || jsonb_build_object(
        v_field, jsonb_build_object('state', 'null')
      );
    else
      v_text := input_data->>v_field;
      if v_field = any(v_numeric_fields) then
        if nullif(btrim(v_text), '') is null then
          v_result := v_result || jsonb_build_object(
            v_field, jsonb_build_object('state', 'empty')
          );
        else
          v_numeric := public.products_import_to_numeric(v_text);
          if v_numeric is null then
            v_result := v_result || jsonb_build_object(
              v_field,
              jsonb_build_object('state', 'invalid', 'value', btrim(v_text))
            );
          else
            v_result := v_result || jsonb_build_object(
              v_field,
              jsonb_build_object(
                'state', 'value',
                'value', to_jsonb(trim_scale(v_numeric))
              )
            );
          end if;
        end if;
      elsif v_field = 'currency' then
        v_result := v_result || jsonb_build_object(
          v_field,
          case
            when nullif(btrim(v_text), '') is null
              then jsonb_build_object('state', 'empty')
            else jsonb_build_object(
              'state', 'value', 'value', upper(btrim(v_text))
            )
          end
        );
      else
        v_result := v_result || jsonb_build_object(
          v_field,
          case
            when nullif(btrim(v_text), '') is null
              then jsonb_build_object('state', 'empty')
            else jsonb_build_object(
              'state', 'value', 'value', btrim(v_text)
            )
          end
        );
      end if;
    end if;
  end loop;

  return v_result;
end;
$$;

create or replace function public.compute_product_import_staging_hash(target_batch_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_batch public.products_import_batches;
  v_payload text;
begin
  select * into v_batch
  from public.products_import_batches
  where id = target_batch_id;

  if v_batch.id is null or v_batch.contract_version < 1 then
    raise exception 'LOTE_V2_NAO_ENCONTRADO';
  end if;
  if v_batch.contract_version <> 1
     or v_batch.normalization_algorithm <> 'branch-import-v1'
     or v_batch.hash_algorithm <> 'SHA-256' then
    raise exception using
      errcode = 'P2810',
      message = 'INVALID_IMPORT_CONTRACT';
  end if;

  select jsonb_build_array(
    v_batch.contract_version,
    v_batch.normalization_algorithm,
    v_batch.hash_algorithm,
    v_batch.branch_id,
    v_batch.mode,
    to_jsonb(public.normalize_branch_import_mask(v_batch.mode, v_batch.field_mask)),
    coalesce(jsonb_agg(
      jsonb_build_array(
        s.row_number,
        s.normalized_code,
        to_jsonb((select array_agg(value order by value) from unnest(s.provided_fields) value)),
        public.canonicalize_branch_import_data(
          s.provided_fields,
          s.normalized_data
        )
      )
      order by s.row_number, s.id
    ), '[]'::jsonb)
  )::text
  into v_payload
  from public.products_import_stage s
  where s.batch_id = v_batch.id;

  return encode(digest(convert_to(v_payload, 'UTF8'), 'sha256'), 'hex');
end;
$$;

create or replace function public.create_product_import_batch(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_branch_id uuid := nullif(payload->>'branch_id', '')::uuid;
  v_mode text := upper(coalesce(payload->>'mode', ''));
  v_contract constant integer := 1;
  v_normalization_algorithm constant text := 'branch-import-v1';
  v_hash_algorithm constant text := 'SHA-256';
  v_mask text[];
  v_batch_id uuid;
begin
  select p.id into v_user_id
  from public.profiles p
  where p.id = auth.uid() and p.ativo;

  if v_user_id is null or not (public.has_module('alimentacao') or public.is_admin()) then
    raise exception 'SEM_PERMISSAO';
  end if;
  if not exists (select 1 from public.branches where id = v_branch_id and active) then
    raise exception 'FILIAL_INATIVA_OU_INEXISTENTE';
  end if;
  if not public.can_access_branch(v_branch_id) then
    raise exception 'SEM_ACESSO_FILIAL';
  end if;
  if payload ? 'contract_version'
     and (
       jsonb_typeof(payload->'contract_version') <> 'number'
       or (payload->'contract_version')::text <> v_contract::text
     ) then
    raise exception using errcode = 'P2810', message = 'INVALID_IMPORT_CONTRACT';
  end if;
  if payload ? 'normalization_algorithm'
     and (
       jsonb_typeof(payload->'normalization_algorithm') <> 'string'
       or payload->>'normalization_algorithm' <> v_normalization_algorithm
     ) then
    raise exception using errcode = 'P2810', message = 'INVALID_IMPORT_CONTRACT';
  end if;
  if payload ? 'hash_algorithm'
     and (
       jsonb_typeof(payload->'hash_algorithm') <> 'string'
       or payload->>'hash_algorithm' <> v_hash_algorithm
     ) then
    raise exception using errcode = 'P2810', message = 'INVALID_IMPORT_CONTRACT';
  end if;

  select coalesce(array_agg(value), '{}'::text[])
  into v_mask
  from jsonb_array_elements_text(coalesce(payload->'field_mask', '[]'::jsonb)) value;
  v_mask := public.normalize_branch_import_mask(v_mode, v_mask);

  insert into public.products_import_batches (
    created_by, import_type, region, source_name, file_hash, status,
    branch_id, mode, contract_version, field_mask, client_file_hash,
    normalization_algorithm, hash_algorithm, state, created_by_profile_id
  )
  select
    p.usuario,
    v_mode,
    b.code,
    nullif(payload->>'source_name', ''),
    nullif(payload->>'client_file_hash', ''),
    'draft',
    b.id,
    v_mode,
    v_contract,
    v_mask,
    nullif(payload->>'client_file_hash', ''),
    v_normalization_algorithm,
    v_hash_algorithm,
    'DRAFT',
    p.id
  from public.profiles p
  join public.branches b on b.id = v_branch_id
  where p.id = v_user_id
  returning id into v_batch_id;

  return jsonb_build_object('batch_id', v_batch_id, 'state', 'DRAFT');
end;
$$;

create or replace function public.stage_product_import_rows(
  target_batch_id uuid,
  rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_batch public.products_import_batches;
  v_row jsonb;
  v_code text;
  v_row_number integer;
  v_fields text[];
  v_data jsonb;
  v_row_hash text;
  v_existing public.products_import_stage;
  v_count integer := 0;
begin
  select * into v_batch
  from public.products_import_batches b
  where b.id = target_batch_id
    and b.contract_version = 1
    and public.can_access_product_import_batch_row(
      b.contract_version,
      b.branch_id,
      b.created_by_profile_id,
      b.created_by,
      false,
      true,
      false
    )
  for update;

  if v_batch.id is null then
    raise exception using
      errcode = 'P2811',
      message = 'IMPORTACAO_NAO_AUTORIZADA';
  end if;
  if v_batch.state <> 'DRAFT' then
    raise exception 'LOTE_NAO_ACEITA_STAGING';
  end if;
  if jsonb_typeof(rows) <> 'array' or jsonb_array_length(rows) = 0 then
    raise exception 'STAGING_SEM_LINHAS';
  end if;

  for v_row in select value from jsonb_array_elements(rows)
  loop
    v_row_number := coalesce((v_row->>'row_number')::integer, v_count + 1);
    v_code := nullif(btrim(coalesce(v_row->>'product_code', '')), '');
    if v_code is null then
      raise exception 'PRODUCT_CODE_OBRIGATORIO';
    end if;

    select coalesce(
      array_agg(distinct lower(btrim(value)) order by lower(btrim(value))),
      '{}'::text[]
    )
    into v_fields
    from jsonb_array_elements_text(
      coalesce(v_row->'provided_fields', '[]'::jsonb)
    ) value
    where nullif(btrim(value), '') is not null;

    if not ('product_code' = any(v_fields)) then
      v_fields := array_append(v_fields, 'product_code');
      select array_agg(distinct value order by value) into v_fields from unnest(v_fields) value;
    end if;

    if exists (
      select 1 from unnest(v_fields) value
      where not (value = any(v_batch.field_mask))
    ) then
      raise exception 'STAGING_FORA_DA_MASCARA';
    end if;

    v_data := coalesce(v_row->'data', '{}'::jsonb);
    if jsonb_typeof(v_data) <> 'object' then
      raise exception 'STAGING_DATA_INVALIDO';
    end if;
    if exists (
      select 1
      from jsonb_object_keys(v_data) key
      where key <> lower(btrim(key))
         or not (key = any(v_fields))
    ) then
      raise exception 'STAGING_DATA_FORA_DOS_CAMPOS';
    end if;

    v_row_hash := encode(digest(convert_to(
      jsonb_build_array(
        v_row_number,
        v_code,
        to_jsonb(v_fields),
        public.canonicalize_branch_import_data(
          v_fields,
          v_data || jsonb_build_object('product_code', v_code)
        )
      )::text,
      'UTF8'
    ), 'sha256'), 'hex');

    select * into v_existing
    from public.products_import_stage
    where batch_id = v_batch.id and normalized_code = v_code;

    if v_existing.id is not null then
      if v_existing.row_hash = v_row_hash then
        v_count := v_count + 1;
        continue;
      end if;
      raise exception 'STAGING_CONFLITANTE';
    end if;

    insert into public.products_import_stage (
      batch_id, row_number, codigo, normalized_code, raw_data, normalized_data,
      status, provided_fields, field_mask, row_hash
    )
    values (
      v_batch.id, v_row_number, v_code, v_code, v_row,
      v_data || jsonb_build_object('product_code', v_code),
      'pending', v_fields, v_batch.field_mask, v_row_hash
    );
    v_count := v_count + 1;
  end loop;

  update public.products_import_batches
  set state = 'DRAFT',
      normalized_file_hash = null,
      idempotency_key = null,
      previewed_at = null,
      last_failure_code = null,
      last_failure_details = null,
      last_failure_at = null
  where id = v_batch.id;

  return jsonb_build_object('batch_id', v_batch.id, 'staged_rows', v_count, 'state', 'DRAFT');
end;
$$;

create or replace function public.reset_product_import_batch_to_draft(
  target_batch_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch public.products_import_batches;
  v_revision bigint;
begin
  select * into v_batch
  from public.products_import_batches b
  where b.id = target_batch_id
    and b.contract_version = 1
    and public.can_access_product_import_batch_row(
      b.contract_version,
      b.branch_id,
      b.created_by_profile_id,
      b.created_by,
      false,
      true,
      false
    )
  for update;

  if v_batch.id is null then
    raise exception using
      errcode = 'P2811',
      message = 'IMPORTACAO_NAO_AUTORIZADA';
  end if;
  if v_batch.state not in ('PREVIEWED', 'REVALIDATION_REQUIRED') then
    raise exception 'ESTADO_NAO_PERMITE_RETORNO_DRAFT';
  end if;

  update public.products_import_stage
  set planned_action = null,
      product_before = null,
      product_after = null,
      stock_before = null,
      stock_after = null,
      price_before = null,
      price_after = null,
      product_version = null,
      stock_version = null,
      price_version = null,
      physical_delta = null,
      blocking_errors = '[]'::jsonb,
      ignored_fields = '[]'::jsonb,
      errors = '[]'::jsonb,
      warnings = '[]'::jsonb,
      status = 'pending'
  where batch_id = v_batch.id;

  update public.products_import_batches
  set state = 'DRAFT',
      status = 'draft',
      normalized_file_hash = null,
      idempotency_key = null,
      previewed_at = null,
      approved_at = null,
      approved_by = null,
      approved_by_profile_id = null,
      last_failure_code = null,
      last_failure_details = null,
      last_failure_at = null,
      total_rows = 0,
      valid_rows = 0,
      invalid_rows = 0,
      warning_count = 0,
      error_count = 0,
      staging_revision = staging_revision + 1
  where id = v_batch.id
  returning staging_revision into v_revision;

  return jsonb_build_object(
    'batch_id', v_batch.id,
    'state', 'DRAFT',
    'staging_revision', v_revision
  );
end;
$$;

create or replace function public.preview_product_import_batch(target_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_batch public.products_import_batches;
  v_stage public.products_import_stage;
  v_mask text[];
  v_hash text;
  v_key text;
  v_errors jsonb;
  v_ignored jsonb;
  v_product public.products;
  v_stock public.product_branch_stock;
  v_price public.product_branch_prices;
  v_physical_qty numeric;
  v_sale_price numeric;
  v_ipi numeric;
  v_tax_free_price numeric;
  v_error_count integer := 0;
  v_row_count integer := 0;
begin
  select * into v_batch
  from public.products_import_batches b
  where b.id = target_batch_id
    and b.contract_version = 1
    and public.can_access_product_import_batch_row(
      b.contract_version,
      b.branch_id,
      b.created_by_profile_id,
      b.created_by,
      false,
      false,
      false
    )
  for update;

  if v_batch.id is null then
    raise exception using
      errcode = 'P2811',
      message = 'IMPORTACAO_NAO_AUTORIZADA';
  end if;
  if v_batch.contract_version <> 1
     or v_batch.normalization_algorithm <> 'branch-import-v1'
     or v_batch.hash_algorithm <> 'SHA-256' then
    raise exception using
      errcode = 'P2810',
      message = 'INVALID_IMPORT_CONTRACT';
  end if;
  if v_batch.state not in ('DRAFT', 'PREVIEWED', 'REVALIDATION_REQUIRED') then
    raise exception 'ESTADO_NAO_PERMITE_PREVIEW';
  end if;
  v_mask := public.normalize_branch_import_mask(v_batch.mode, v_batch.field_mask);

  if not exists (select 1 from public.products_import_stage where batch_id = v_batch.id) then
    raise exception 'STAGING_SEM_LINHAS';
  end if;

  for v_stage in
    select * from public.products_import_stage
    where batch_id = v_batch.id
    order by row_number, id
  loop
    v_errors := '[]'::jsonb;
    v_ignored := '[]'::jsonb;
    v_product := null;
    v_stock := null;
    v_price := null;
    v_physical_qty := public.products_import_to_numeric(
      v_stage.normalized_data->>'physical_qty'
    );
    v_sale_price := public.products_import_to_numeric(
      v_stage.normalized_data->>'sale_price'
    );
    v_ipi := public.products_import_to_numeric(v_stage.normalized_data->>'ipi');
    v_tax_free_price := public.products_import_to_numeric(
      v_stage.normalized_data->>'tax_free_price'
    );

    select * into v_product from public.products where codigo = v_stage.normalized_code;
    select * into v_stock from public.product_branch_stock
      where product_code = v_stage.normalized_code and branch_id = v_batch.branch_id;
    select * into v_price from public.product_branch_prices
      where product_code = v_stage.normalized_code and branch_id = v_batch.branch_id;

    if v_batch.mode in ('UPDATE_STOCK', 'UPDATE_PRICES', 'CUSTOM_UPDATE')
       and v_product.codigo is null then
      v_errors := v_errors || jsonb_build_array('PRODUTO_INEXISTENTE');
    end if;
    if v_batch.mode = 'CREATE_PRODUCTS' and v_product.codigo is not null then
      v_errors := v_errors || jsonb_build_array('PRODUTO_JA_EXISTE');
    end if;
    if v_product.codigo is null and v_batch.mode in ('CREATE_PRODUCTS', 'FULL_IMPORT')
       and nullif(btrim(v_stage.normalized_data->>'description'), '') is null then
      v_errors := v_errors || jsonb_build_array('DESCRIPTION_OBRIGATORIA_PRODUTO_NOVO');
    end if;
    if 'physical_qty' = any(v_stage.provided_fields) then
      if v_stage.normalized_data->'physical_qty' is null
         or jsonb_typeof(v_stage.normalized_data->'physical_qty') = 'null'
         or nullif(v_stage.normalized_data->>'physical_qty', '') is null then
        if v_batch.mode = 'UPDATE_STOCK' then
          v_errors := v_errors || jsonb_build_array('PHYSICAL_QTY_OBRIGATORIA');
        else
          v_ignored := v_ignored || jsonb_build_array('physical_qty');
        end if;
      elsif v_physical_qty is null then
        v_errors := v_errors || jsonb_build_array('PHYSICAL_QTY_INVALIDA');
      elsif v_physical_qty < 0 then
        v_errors := v_errors || jsonb_build_array('PHYSICAL_QTY_NEGATIVA');
      end if;
    end if;
    if 'sale_price' = any(v_stage.provided_fields) then
      if v_stage.normalized_data->'sale_price' is null
         or jsonb_typeof(v_stage.normalized_data->'sale_price') = 'null'
         or nullif(v_stage.normalized_data->>'sale_price', '') is null then
        if v_batch.mode = 'UPDATE_PRICES' then
          v_errors := v_errors || jsonb_build_array('SALE_PRICE_OBRIGATORIO');
        else
          v_ignored := v_ignored || jsonb_build_array('sale_price');
        end if;
      elsif v_sale_price is null then
        v_errors := v_errors || jsonb_build_array('SALE_PRICE_INVALIDO');
      elsif v_sale_price < 0 then
        v_errors := v_errors || jsonb_build_array('SALE_PRICE_NEGATIVO');
      end if;
    end if;
    if 'ipi' = any(v_stage.provided_fields)
       and nullif(v_stage.normalized_data->>'ipi', '') is not null then
      if v_ipi is null then
        v_errors := v_errors || jsonb_build_array('IPI_INVALIDO');
      elsif v_ipi < 0 then
        v_errors := v_errors || jsonb_build_array('IPI_NEGATIVO');
      end if;
    end if;
    if 'tax_free_price' = any(v_stage.provided_fields)
       and nullif(v_stage.normalized_data->>'tax_free_price', '') is not null then
      if v_tax_free_price is null then
        v_errors := v_errors || jsonb_build_array('TAX_FREE_PRICE_INVALIDO');
      elsif v_tax_free_price < 0 then
        v_errors := v_errors || jsonb_build_array('TAX_FREE_PRICE_NEGATIVO');
      end if;
    end if;
    if 'currency' = any(v_stage.provided_fields)
       and nullif(v_stage.normalized_data->>'currency', '') is not null
       and upper(v_stage.normalized_data->>'currency') !~ '^[A-Z]{3}$' then
      v_errors := v_errors || jsonb_build_array('CURRENCY_INVALIDA');
    end if;

    update public.products_import_stage
    set
      field_mask = v_mask,
      planned_action = case
        when v_product.codigo is null then 'INSERT'
        else 'UPDATE'
      end,
      product_before = case when v_product.codigo is null then null else to_jsonb(v_product) end,
      product_after = null,
      stock_before = case when v_stock.product_code is null then null else to_jsonb(v_stock) end,
      stock_after = null,
      price_before = case when v_price.product_code is null then null else to_jsonb(v_price) end,
      price_after = null,
      product_version = v_product.updated_at,
      stock_version = v_stock.version,
      price_version = v_price.version,
      physical_delta = case
        when 'physical_qty' = any(v_stage.provided_fields)
          and nullif(v_stage.normalized_data->>'physical_qty', '') is not null
          and v_physical_qty is not null
        then v_physical_qty - coalesce(v_stock.physical_qty, 0)
        else null
      end,
      blocking_errors = v_errors,
      ignored_fields = v_ignored,
      status = case when jsonb_array_length(v_errors) > 0 then 'error' else 'pending' end
    where id = v_stage.id;

    v_row_count := v_row_count + 1;
    if jsonb_array_length(v_errors) > 0 then
      v_error_count := v_error_count + 1;
    end if;
  end loop;

  if v_error_count > 0 then
    update public.products_import_batches
    set state = 'FAILED',
        status = 'failed',
        error_count = v_error_count,
        invalid_rows = v_error_count,
        valid_rows = v_row_count - v_error_count,
        total_rows = v_row_count,
        last_failure_code = 'PREVIEW_INVALIDO',
        last_failure_details = jsonb_build_object('error_rows', v_error_count),
        last_failure_at = now()
    where id = v_batch.id;

    return jsonb_build_object(
      'batch_id', v_batch.id, 'state', 'FAILED',
      'total_rows', v_row_count, 'error_rows', v_error_count
    );
  end if;

  v_hash := public.compute_product_import_staging_hash(v_batch.id);
  v_key := encode(digest(convert_to(
    concat_ws('|', v_batch.branch_id, v_batch.mode, v_batch.contract_version,
      array_to_string(v_mask, ','), v_hash, v_batch.hash_algorithm),
    'UTF8'
  ), 'sha256'), 'hex');

  if exists (
    select 1 from public.products_import_batches b
    where b.id <> v_batch.id
      and b.idempotency_key = v_key
      and b.state = 'COMMITTED'
  ) then
    raise exception 'CONTEUDO_JA_CONFIRMADO_NESTA_FILIAL';
  end if;

  update public.products_import_batches
  set state = 'PREVIEWED',
      status = 'validated',
      field_mask = v_mask,
      normalized_file_hash = v_hash,
      idempotency_key = v_key,
      previewed_at = now(),
      total_rows = v_row_count,
      valid_rows = v_row_count,
      invalid_rows = 0,
      error_count = 0,
      last_failure_code = null,
      last_failure_details = null,
      last_failure_at = null
  where id = v_batch.id;

  return jsonb_build_object(
    'batch_id', v_batch.id, 'state', 'PREVIEWED',
    'normalized_file_hash', v_hash, 'idempotency_key', v_key,
    'total_rows', v_row_count
  );
end;
$$;

create or replace function public.approve_product_import_batch(target_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch public.products_import_batches;
begin
  select * into v_batch
  from public.products_import_batches b
  where b.id = target_batch_id
    and b.contract_version = 1
    and public.can_access_product_import_batch_row(
      b.contract_version,
      b.branch_id,
      b.created_by_profile_id,
      b.created_by,
      true,
      false,
      false
    )
  for update;

  if v_batch.id is null then
    raise exception using
      errcode = 'P2811',
      message = 'IMPORTACAO_NAO_AUTORIZADA';
  end if;
  if v_batch.state = 'APPROVED' then
    return jsonb_build_object('batch_id', v_batch.id, 'state', 'APPROVED');
  end if;
  if v_batch.state <> 'PREVIEWED' then
    raise exception 'ESTADO_NAO_PERMITE_APROVACAO';
  end if;

  update public.products_import_batches
  set state = 'APPROVED',
      status = 'approved',
      approved_at = now(),
      approved_by_profile_id = auth.uid(),
      approved_by = (select usuario from public.profiles where id = auth.uid())
  where id = v_batch.id;

  return jsonb_build_object('batch_id', v_batch.id, 'state', 'APPROVED');
end;
$$;

create or replace function public.commit_product_import_batch(target_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_batch public.products_import_batches;
  v_stage public.products_import_stage;
  v_product public.products;
  v_stock public.product_branch_stock;
  v_price public.product_branch_prices;
  v_lock_code text;
  v_hash text;
  v_pr uuid;
  v_sp uuid;
  v_desired_stock numeric(14,3);
  v_desired_price numeric(14,4);
  v_currency char(3);
  v_before jsonb;
  v_after jsonb;
  v_product_before jsonb;
  v_product_after jsonb;
  v_movement_id uuid;
  v_changed integer := 0;
  v_stock_changed integer := 0;
  v_price_changed integer := 0;
  v_canonical_key text;
  v_winner public.products_import_batches;
  v_constraint_name text;
begin
  select * into v_batch
  from public.products_import_batches b
  where b.id = target_batch_id
    and b.contract_version = 1
    and public.can_access_product_import_batch_row(
      b.contract_version,
      b.branch_id,
      b.created_by_profile_id,
      b.created_by,
      true,
      false,
      false
    )
  for update;

  if v_batch.id is null then
    raise exception using
      errcode = 'P2811',
      message = 'IMPORTACAO_NAO_AUTORIZADA';
  end if;
  if v_batch.contract_version <> 1
     or v_batch.normalization_algorithm <> 'branch-import-v1'
     or v_batch.hash_algorithm <> 'SHA-256' then
    raise exception using
      errcode = 'P2810',
      message = 'INVALID_IMPORT_CONTRACT';
  end if;
  if v_batch.state = 'COMMITTED' then
    return coalesce(v_batch.summary, '{}'::jsonb) || jsonb_build_object(
      'batch_id', v_batch.id, 'state', 'COMMITTED', 'idempotent', true
    );
  end if;
  if v_batch.state <> 'APPROVED' then
    raise exception 'ESTADO_NAO_PERMITE_COMMIT';
  end if;

  update public.products_import_batches
  set last_attempt_started_at = now(),
      last_attempt_completed_at = null,
      attempt_count = attempt_count + 1,
      last_failure_code = null,
      last_failure_details = null,
      last_failure_at = null
  where id = v_batch.id;

  v_hash := public.compute_product_import_staging_hash(v_batch.id);
  if v_hash is distinct from v_batch.normalized_file_hash then
    update public.products_import_batches
    set state = 'REVALIDATION_REQUIRED',
        last_attempt_completed_at = now(),
        last_failure_code = 'STAGING_ALTERADO_APOS_PREVIEW',
        last_failure_details = jsonb_build_object(
          'expected_hash', v_batch.normalized_file_hash,
          'current_hash', v_hash
        ),
        last_failure_at = now()
    where id = v_batch.id;

    return jsonb_build_object(
      'batch_id', v_batch.id, 'state', 'REVALIDATION_REQUIRED',
      'error', 'STAGING_ALTERADO_APOS_PREVIEW'
    );
  end if;

  v_canonical_key := encode(digest(convert_to(
    concat_ws(
      '|',
      v_batch.branch_id,
      v_batch.mode,
      v_batch.contract_version,
      array_to_string(
        public.normalize_branch_import_mask(v_batch.mode, v_batch.field_mask),
        ','
      ),
      v_hash,
      v_batch.hash_algorithm
    ),
    'UTF8'
  ), 'sha256'), 'hex');

  if v_canonical_key is distinct from v_batch.idempotency_key then
    update public.products_import_batches
    set state = 'REVALIDATION_REQUIRED',
        last_attempt_completed_at = now(),
        last_failure_code = 'IDEMPOTENCY_KEY_DIVERGENTE',
        last_failure_details = jsonb_build_object(
          'reason', 'canonical_key_changed_after_preview'
        ),
        last_failure_at = now()
    where id = v_batch.id;

    return jsonb_build_object(
      'batch_id', v_batch.id,
      'state', 'REVALIDATION_REQUIRED',
      'error', 'IDEMPOTENCY_KEY_DIVERGENTE'
    );
  end if;

  begin
    perform pg_advisory_xact_lock(
      hashtextextended(
        'BRANCH_IMPORT_V2:IDEMPOTENCY:' || v_canonical_key,
        0
      )
    );

    for v_lock_code in
      select distinct s.normalized_code
      from public.products_import_stage s
      where s.batch_id = v_batch.id
      order by s.normalized_code
    loop
      perform pg_advisory_xact_lock(
        hashtextextended(
          'BRANCH_IMPORT_V2:PRODUCT:' || v_lock_code,
          0
        )
      );
    end loop;

    perform 1
    from public.products p
    join public.products_import_stage s
      on s.normalized_code = p.codigo and s.batch_id = v_batch.id
    order by p.codigo
    for update of p;

    perform 1
    from public.product_branch_prices bp
    join public.products_import_stage s
      on s.normalized_code = bp.product_code and s.batch_id = v_batch.id
    where bp.branch_id = v_batch.branch_id
    order by bp.product_code
    for update of bp;

    perform 1
    from public.product_branch_stock bs
    join public.products_import_stage s
      on s.normalized_code = bs.product_code and s.batch_id = v_batch.id
    where bs.branch_id = v_batch.branch_id
    order by bs.product_code
    for update of bs;

    v_hash := public.compute_product_import_staging_hash(v_batch.id);
    v_canonical_key := encode(digest(convert_to(
      concat_ws(
        '|',
        v_batch.branch_id,
        v_batch.mode,
        v_batch.contract_version,
        array_to_string(
          public.normalize_branch_import_mask(v_batch.mode, v_batch.field_mask),
          ','
        ),
        v_hash,
        v_batch.hash_algorithm
      ),
      'UTF8'
    ), 'sha256'), 'hex');

    if v_hash is distinct from v_batch.normalized_file_hash
       or v_canonical_key is distinct from v_batch.idempotency_key then
      update public.products_import_batches
      set state = 'REVALIDATION_REQUIRED',
          last_attempt_completed_at = now(),
          last_failure_code = 'STAGING_ALTERADO_APOS_LOCK',
          last_failure_details = jsonb_build_object(
            'reason', 'canonical_content_changed_after_lock'
          ),
          last_failure_at = now()
      where id = v_batch.id;

      return jsonb_build_object(
        'batch_id', v_batch.id,
        'state', 'REVALIDATION_REQUIRED',
        'error', 'STAGING_ALTERADO_APOS_LOCK'
      );
    end if;

    select b.* into v_winner
    from public.products_import_batches b
    where b.id is distinct from v_batch.id
      and b.contract_version = 1
      and b.idempotency_key = v_canonical_key
      and b.state = 'COMMITTED'
      and public.can_access_product_import_batch_row(
        b.contract_version,
        b.branch_id,
        b.created_by_profile_id,
        b.created_by,
        true,
        false,
        false
      )
    order by b.committed_at desc nulls last, b.id
    limit 1;

    if v_winner.id is not null then
      update public.products_import_batches
      set state = 'REVALIDATION_REQUIRED',
          last_attempt_completed_at = now(),
          last_failure_code = 'CONTEUDO_JA_CONFIRMADO',
          last_failure_details = jsonb_build_object(
            'reason', 'idempotent_winner_exists',
            'committed_batch_id', v_winner.id
          ),
          last_failure_at = now()
      where id = v_batch.id;

      return jsonb_build_object(
        'batch_id', v_batch.id,
        'committed_batch_id', v_winner.id,
        'state', 'REVALIDATION_REQUIRED',
        'idempotent', true,
        'error', 'CONTEUDO_JA_CONFIRMADO'
      );
    end if;
  exception
    when lock_not_available or serialization_failure or deadlock_detected then
      update public.products_import_batches
      set state = 'APPROVED',
          last_attempt_completed_at = now(),
          last_failure_code = 'TRANSIENT_FAILURE',
          last_failure_details = jsonb_build_object(
            'retryable', true,
            'category', 'CONCURRENCY'
          ),
          last_failure_at = now()
      where id = v_batch.id;

      return jsonb_build_object(
        'batch_id', v_batch.id,
        'state', 'APPROVED',
        'error', 'TRANSIENT_FAILURE',
        'retryable', true
      );
  end;

  if exists (
    select 1
    from public.products_import_stage s
    join public.products p on p.codigo = s.normalized_code
    where s.batch_id = v_batch.id
      and s.product_version is null
  ) then
    update public.products_import_batches
    set state = 'REVALIDATION_REQUIRED',
        last_attempt_completed_at = now(),
        last_failure_code = 'PRODUTO_CRIADO_CONCORRENTEMENTE',
        last_failure_details = jsonb_build_object(
          'reason', 'product_created_after_preview'
        ),
        last_failure_at = now()
    where id = v_batch.id;

    return jsonb_build_object(
      'batch_id', v_batch.id,
      'state', 'REVALIDATION_REQUIRED',
      'error', 'PRODUTO_CRIADO_CONCORRENTEMENTE'
    );
  end if;

  if exists (
    select 1
    from public.products_import_stage s
    left join public.products p on p.codigo = s.normalized_code
    left join public.product_branch_stock bs
      on bs.product_code = s.normalized_code and bs.branch_id = v_batch.branch_id
    left join public.product_branch_prices bp
      on bp.product_code = s.normalized_code and bp.branch_id = v_batch.branch_id
    where s.batch_id = v_batch.id
      and (
        p.updated_at is distinct from s.product_version
        or bs.version is distinct from s.stock_version
        or bp.version is distinct from s.price_version
      )
  ) then
    update public.products_import_batches
    set state = 'REVALIDATION_REQUIRED',
        last_attempt_completed_at = now(),
        last_failure_code = 'PREVIEW_DESATUALIZADO',
        last_failure_details = jsonb_build_object('reason', 'version_conflict'),
        last_failure_at = now()
    where id = v_batch.id;

    return jsonb_build_object(
      'batch_id', v_batch.id, 'state', 'REVALIDATION_REQUIRED',
      'error', 'PREVIEW_DESATUALIZADO'
    );
  end if;

  select pr_branch_id, sp_branch_id into v_pr, v_sp
  from public.resolve_branch_import_initial_branches();

  update public.products_import_batches
  set state = 'COMMITTING'
  where id = v_batch.id;

  begin
    perform set_config('app.stock_sync_source', 'BRANCH_IMPORT_V2', true);
    perform set_config('app.price_sync_source', 'BRANCH_IMPORT_V2', true);

    for v_stage in
      select * from public.products_import_stage
      where batch_id = v_batch.id
      order by normalized_code, id
    loop
      select * into v_product from public.products where codigo = v_stage.normalized_code;
      v_product_before := case
        when v_product.codigo is null then null
        else to_jsonb(v_product)
      end;

      if v_product.codigo is null then
        insert into public.products (
          codigo, descricao, marca, aplicacao, ano, ipi, preco_sem_imposto,
          estoque, estoque_quantidade, preco_sp, preco_pr, status_estoque,
          status_cadastro, url_imagem, grupo, categoria, montadora, detalhes,
          oem, "similar"
        )
        values (
          v_stage.normalized_code,
          nullif(btrim(v_stage.normalized_data->>'description'), ''),
          nullif(btrim(v_stage.normalized_data->>'brand'), ''),
          nullif(btrim(v_stage.normalized_data->>'application'), ''),
          nullif(btrim(v_stage.normalized_data->>'year'), ''),
          coalesce(nullif(v_stage.normalized_data->>'ipi', '')::numeric, 0),
          coalesce(nullif(v_stage.normalized_data->>'tax_free_price', '')::numeric, 0),
          nullif(btrim(v_stage.normalized_data->>'stock_label'), ''),
          0,
          0,
          0,
          nullif(btrim(v_stage.normalized_data->>'stock_status'), ''),
          nullif(btrim(v_stage.normalized_data->>'registration_status'), ''),
          nullif(btrim(v_stage.normalized_data->>'image_url'), ''),
          nullif(btrim(v_stage.normalized_data->>'group'), ''),
          nullif(btrim(v_stage.normalized_data->>'category'), ''),
          nullif(btrim(v_stage.normalized_data->>'manufacturer'), ''),
          nullif(btrim(v_stage.normalized_data->>'details'), ''),
          nullif(btrim(v_stage.normalized_data->>'oem'), ''),
          nullif(btrim(v_stage.normalized_data->>'similar'), '')
        );

        insert into public.product_branch_stock (product_code, branch_id, physical_qty, updated_by)
        select v_stage.normalized_code, b.id, 0, auth.uid()
        from public.branches b
        where b.active
        on conflict (product_code, branch_id) do nothing;
      else
        update public.products p
        set
          descricao = case when 'description' = any(v_stage.provided_fields)
            and nullif(btrim(v_stage.normalized_data->>'description'), '') is not null
            then btrim(v_stage.normalized_data->>'description') else p.descricao end,
          marca = case when 'brand' = any(v_stage.provided_fields)
            and nullif(btrim(v_stage.normalized_data->>'brand'), '') is not null
            then btrim(v_stage.normalized_data->>'brand') else p.marca end,
          aplicacao = case when 'application' = any(v_stage.provided_fields)
            and nullif(btrim(v_stage.normalized_data->>'application'), '') is not null
            then btrim(v_stage.normalized_data->>'application') else p.aplicacao end,
          ano = case when 'year' = any(v_stage.provided_fields)
            and nullif(btrim(v_stage.normalized_data->>'year'), '') is not null
            then btrim(v_stage.normalized_data->>'year') else p.ano end,
          ipi = case when 'ipi' = any(v_stage.provided_fields)
            and nullif(v_stage.normalized_data->>'ipi', '') is not null
            then (v_stage.normalized_data->>'ipi')::numeric else p.ipi end,
          preco_sem_imposto = case when 'tax_free_price' = any(v_stage.provided_fields)
            and nullif(v_stage.normalized_data->>'tax_free_price', '') is not null
            then (v_stage.normalized_data->>'tax_free_price')::numeric else p.preco_sem_imposto end,
          estoque = case when 'stock_label' = any(v_stage.provided_fields)
            and nullif(btrim(v_stage.normalized_data->>'stock_label'), '') is not null
            then btrim(v_stage.normalized_data->>'stock_label') else p.estoque end,
          status_estoque = case when 'stock_status' = any(v_stage.provided_fields)
            and nullif(btrim(v_stage.normalized_data->>'stock_status'), '') is not null
            then btrim(v_stage.normalized_data->>'stock_status') else p.status_estoque end,
          status_cadastro = case when 'registration_status' = any(v_stage.provided_fields)
            and nullif(btrim(v_stage.normalized_data->>'registration_status'), '') is not null
            then btrim(v_stage.normalized_data->>'registration_status') else p.status_cadastro end,
          url_imagem = case when 'image_url' = any(v_stage.provided_fields)
            and nullif(btrim(v_stage.normalized_data->>'image_url'), '') is not null
            then btrim(v_stage.normalized_data->>'image_url') else p.url_imagem end,
          grupo = case when 'group' = any(v_stage.provided_fields)
            and nullif(btrim(v_stage.normalized_data->>'group'), '') is not null
            then btrim(v_stage.normalized_data->>'group') else p.grupo end,
          categoria = case when 'category' = any(v_stage.provided_fields)
            and nullif(btrim(v_stage.normalized_data->>'category'), '') is not null
            then btrim(v_stage.normalized_data->>'category') else p.categoria end,
          montadora = case when 'manufacturer' = any(v_stage.provided_fields)
            and nullif(btrim(v_stage.normalized_data->>'manufacturer'), '') is not null
            then btrim(v_stage.normalized_data->>'manufacturer') else p.montadora end,
          detalhes = case when 'details' = any(v_stage.provided_fields)
            and nullif(btrim(v_stage.normalized_data->>'details'), '') is not null
            then btrim(v_stage.normalized_data->>'details') else p.detalhes end,
          oem = case when 'oem' = any(v_stage.provided_fields)
            and nullif(btrim(v_stage.normalized_data->>'oem'), '') is not null
            then btrim(v_stage.normalized_data->>'oem') else p.oem end,
          "similar" = case when 'similar' = any(v_stage.provided_fields)
            and nullif(btrim(v_stage.normalized_data->>'similar'), '') is not null
            then btrim(v_stage.normalized_data->>'similar') else p."similar" end
        where p.codigo = v_stage.normalized_code
          and (
            ('description' = any(v_stage.provided_fields)
              and nullif(btrim(v_stage.normalized_data->>'description'), '') is not null
              and p.descricao is distinct from btrim(v_stage.normalized_data->>'description'))
            or ('brand' = any(v_stage.provided_fields)
              and nullif(btrim(v_stage.normalized_data->>'brand'), '') is not null
              and p.marca is distinct from btrim(v_stage.normalized_data->>'brand'))
            or ('application' = any(v_stage.provided_fields)
              and nullif(btrim(v_stage.normalized_data->>'application'), '') is not null
              and p.aplicacao is distinct from btrim(v_stage.normalized_data->>'application'))
            or ('year' = any(v_stage.provided_fields)
              and nullif(btrim(v_stage.normalized_data->>'year'), '') is not null
              and p.ano is distinct from btrim(v_stage.normalized_data->>'year'))
            or ('ipi' = any(v_stage.provided_fields)
              and public.products_import_to_numeric(v_stage.normalized_data->>'ipi') is not null
              and p.ipi is distinct from public.products_import_to_numeric(
                v_stage.normalized_data->>'ipi'
              ))
            or ('tax_free_price' = any(v_stage.provided_fields)
              and public.products_import_to_numeric(
                v_stage.normalized_data->>'tax_free_price'
              ) is not null
              and p.preco_sem_imposto is distinct from public.products_import_to_numeric(
                v_stage.normalized_data->>'tax_free_price'
              ))
            or ('stock_label' = any(v_stage.provided_fields)
              and nullif(btrim(v_stage.normalized_data->>'stock_label'), '') is not null
              and p.estoque is distinct from btrim(v_stage.normalized_data->>'stock_label'))
            or ('stock_status' = any(v_stage.provided_fields)
              and nullif(btrim(v_stage.normalized_data->>'stock_status'), '') is not null
              and p.status_estoque is distinct from btrim(
                v_stage.normalized_data->>'stock_status'
              ))
            or ('registration_status' = any(v_stage.provided_fields)
              and nullif(btrim(v_stage.normalized_data->>'registration_status'), '') is not null
              and p.status_cadastro is distinct from btrim(
                v_stage.normalized_data->>'registration_status'
              ))
            or ('image_url' = any(v_stage.provided_fields)
              and nullif(btrim(v_stage.normalized_data->>'image_url'), '') is not null
              and p.url_imagem is distinct from btrim(v_stage.normalized_data->>'image_url'))
            or ('group' = any(v_stage.provided_fields)
              and nullif(btrim(v_stage.normalized_data->>'group'), '') is not null
              and p.grupo is distinct from btrim(v_stage.normalized_data->>'group'))
            or ('category' = any(v_stage.provided_fields)
              and nullif(btrim(v_stage.normalized_data->>'category'), '') is not null
              and p.categoria is distinct from btrim(v_stage.normalized_data->>'category'))
            or ('manufacturer' = any(v_stage.provided_fields)
              and nullif(btrim(v_stage.normalized_data->>'manufacturer'), '') is not null
              and p.montadora is distinct from btrim(
                v_stage.normalized_data->>'manufacturer'
              ))
            or ('details' = any(v_stage.provided_fields)
              and nullif(btrim(v_stage.normalized_data->>'details'), '') is not null
              and p.detalhes is distinct from btrim(v_stage.normalized_data->>'details'))
            or ('oem' = any(v_stage.provided_fields)
              and nullif(btrim(v_stage.normalized_data->>'oem'), '') is not null
              and p.oem is distinct from btrim(v_stage.normalized_data->>'oem'))
            or ('similar' = any(v_stage.provided_fields)
              and nullif(btrim(v_stage.normalized_data->>'similar'), '') is not null
              and p."similar" is distinct from btrim(v_stage.normalized_data->>'similar'))
          );
      end if;

      select to_jsonb(p) into v_product_after
      from public.products p
      where p.codigo = v_stage.normalized_code;

      if v_product_before is distinct from v_product_after then
        insert into public.products_import_audit (
          batch_id, codigo, action, before_data, after_data, created_by,
          stage_id, branch_id, entity_type
        )
        values (
          v_batch.id,
          v_stage.normalized_code,
          case when v_product_before is null then 'insert' else 'update' end,
          v_product_before,
          v_product_after,
          (select usuario from public.profiles where id = auth.uid()),
          v_stage.id,
          v_batch.branch_id,
          'PRODUCT'
        );
      end if;

      if 'physical_qty' = any(v_stage.provided_fields)
         and nullif(v_stage.normalized_data->>'physical_qty', '') is not null then
        v_desired_stock := (v_stage.normalized_data->>'physical_qty')::numeric;

        insert into public.product_branch_stock (product_code, branch_id, physical_qty, updated_by)
        values (v_stage.normalized_code, v_batch.branch_id, 0, auth.uid())
        on conflict (product_code, branch_id) do nothing;

        select * into v_stock
        from public.product_branch_stock
        where product_code = v_stage.normalized_code and branch_id = v_batch.branch_id
        for update;

        if v_stock.reserved_order_qty + v_stock.reserved_transfer_qty > v_desired_stock then
          raise exception using
            errcode = 'P2820',
            message = 'BUSINESS_RULE_VIOLATION';
        end if;

        if v_stock.physical_qty is distinct from v_desired_stock then
          v_before := to_jsonb(v_stock);
          update public.product_branch_stock
          set physical_qty = v_desired_stock, updated_by = auth.uid()
          where product_code = v_stage.normalized_code and branch_id = v_batch.branch_id
          returning to_jsonb(product_branch_stock.*) into v_after;

          insert into public.stock_movements (
            branch_id, product_code, movement_type, physical_delta,
            balance_before, balance_after, source, reference_type, reference_id,
            idempotency_key, created_by, metadata
          )
          values (
            v_batch.branch_id, v_stage.normalized_code, 'IMPORTACAO_ESTOQUE',
            v_desired_stock - v_stock.physical_qty,
            v_before, v_after, 'BRANCH_IMPORT_V2',
            'products_import_stage', v_stage.id,
            'branch-import-v2:' || v_batch.id || ':' || v_stage.id || ':stock',
            auth.uid(), jsonb_build_object('batch_id', v_batch.id, 'mode', v_batch.mode)
          )
          returning id into v_movement_id;

          insert into public.products_import_audit (
            batch_id, codigo, action, before_data, after_data, created_by,
            stage_id, branch_id, entity_type, version_before, version_after,
            stock_movement_id
          )
          values (
            v_batch.id, v_stage.normalized_code, 'update', v_before, v_after,
            (select usuario from public.profiles where id = auth.uid()),
            v_stage.id, v_batch.branch_id, 'STOCK', v_stock.version,
            (v_after->>'version')::bigint, v_movement_id
          );
          v_stock_changed := v_stock_changed + 1;
        end if;

        if v_batch.branch_id = v_pr then
          update public.products
          set estoque_quantidade = v_desired_stock
          where codigo = v_stage.normalized_code
            and estoque_quantidade is distinct from v_desired_stock;
        end if;
      end if;

      if 'sale_price' = any(v_stage.provided_fields)
         and nullif(v_stage.normalized_data->>'sale_price', '') is not null then
        v_desired_price := (v_stage.normalized_data->>'sale_price')::numeric;
        v_currency := upper(coalesce(nullif(v_stage.normalized_data->>'currency', ''), 'BRL'))::char(3);

        select * into v_price
        from public.product_branch_prices
        where product_code = v_stage.normalized_code and branch_id = v_batch.branch_id
        for update;
        v_before := case when v_price.product_code is null then null else to_jsonb(v_price) end;

        insert into public.product_branch_prices (
          product_code, branch_id, sale_price, currency, source,
          source_batch_id, updated_by
        )
        values (
          v_stage.normalized_code, v_batch.branch_id, v_desired_price,
          v_currency, 'BRANCH_IMPORT_V2', v_batch.id, auth.uid()
        )
        on conflict (product_code, branch_id) do update
        set sale_price = excluded.sale_price,
            currency = excluded.currency,
            source = excluded.source,
            source_batch_id = excluded.source_batch_id,
            updated_by = excluded.updated_by
        where product_branch_prices.sale_price is distinct from excluded.sale_price
           or product_branch_prices.currency is distinct from excluded.currency;

        select to_jsonb(bp) into v_after
        from public.product_branch_prices bp
        where product_code = v_stage.normalized_code and branch_id = v_batch.branch_id;

        if v_before is distinct from v_after then
          insert into public.products_import_audit (
            batch_id, codigo, action, before_data, after_data, created_by,
            stage_id, branch_id, entity_type, version_before, version_after
          )
          values (
            v_batch.id, v_stage.normalized_code,
            case when v_before is null then 'insert' else 'update' end,
            v_before, v_after,
            (select usuario from public.profiles where id = auth.uid()),
            v_stage.id, v_batch.branch_id, 'PRICE',
            case when v_before is null then null else (v_before->>'version')::bigint end,
            (v_after->>'version')::bigint
          );
          v_price_changed := v_price_changed + 1;
        end if;

        if v_batch.branch_id = v_pr then
          update public.products set preco_pr = v_desired_price
          where codigo = v_stage.normalized_code and preco_pr is distinct from v_desired_price;
        elsif v_batch.branch_id = v_sp then
          update public.products set preco_sp = v_desired_price
          where codigo = v_stage.normalized_code and preco_sp is distinct from v_desired_price;
        end if;
      end if;

      update public.products_import_stage s
      set product_after = (select to_jsonb(p) from public.products p where p.codigo = s.normalized_code),
          stock_after = (select to_jsonb(bs) from public.product_branch_stock bs
            where bs.product_code = s.normalized_code and bs.branch_id = v_batch.branch_id),
          price_after = (select to_jsonb(bp) from public.product_branch_prices bp
            where bp.product_code = s.normalized_code and bp.branch_id = v_batch.branch_id),
          status = 'imported'
      where s.id = v_stage.id;
      v_changed := v_changed + 1;
    end loop;

    update public.products_import_batches
    set state = 'COMMITTED',
        status = 'imported',
        committed_at = now(),
        imported_at = now(),
        committed_by_profile_id = auth.uid(),
        last_attempt_completed_at = now(),
        summary = coalesce(summary, '{}'::jsonb) || jsonb_build_object(
          'state', 'COMMITTED',
          'processedRows', v_changed,
          'stockChanged', v_stock_changed,
          'priceChanged', v_price_changed,
          'branchId', v_batch.branch_id
        )
    where id = v_batch.id;
  exception
    when lock_not_available or serialization_failure or deadlock_detected then
      update public.products_import_batches
      set state = 'APPROVED',
          last_attempt_completed_at = now(),
          last_failure_code = 'TRANSIENT_FAILURE',
          last_failure_details = jsonb_build_object(
            'retryable', true,
            'category', 'CONCURRENCY'
          ),
          last_failure_at = now()
      where id = v_batch.id;

      return jsonb_build_object(
        'batch_id', v_batch.id,
        'state', 'APPROVED',
        'error', 'TRANSIENT_FAILURE',
        'retryable', true
      );
    when sqlstate 'P2820' then
      update public.products_import_batches
      set state = 'FAILED',
          status = 'failed',
          last_attempt_completed_at = now(),
          last_failure_code = 'BUSINESS_RULE_VIOLATION',
          last_failure_details = jsonb_build_object('retryable', false),
          last_failure_at = now()
      where id = v_batch.id;

      return jsonb_build_object(
        'batch_id', v_batch.id,
        'state', 'FAILED',
        'error', 'BUSINESS_RULE_VIOLATION',
        'retryable', false
      );
    when unique_violation then
      get stacked diagnostics v_constraint_name = constraint_name;

      if v_constraint_name = 'products_import_batches_v2_idempotency_idx' then
        v_winner := null;
        select b.* into v_winner
        from public.products_import_batches b
        where b.id is distinct from v_batch.id
          and b.contract_version = 1
          and b.idempotency_key = v_canonical_key
          and b.state = 'COMMITTED'
          and public.can_access_product_import_batch_row(
            b.contract_version,
            b.branch_id,
            b.created_by_profile_id,
            b.created_by,
            true,
            false,
            false
          )
        order by b.committed_at desc nulls last, b.id
        limit 1;

        if v_winner.id is null then
          raise exception using
            errcode = 'P2811',
            message = 'IMPORTACAO_NAO_AUTORIZADA';
        end if;

        update public.products_import_batches
        set state = 'REVALIDATION_REQUIRED',
            last_attempt_completed_at = now(),
            last_failure_code = 'CONTEUDO_JA_CONFIRMADO',
            last_failure_details = jsonb_build_object(
              'reason', 'idempotency_unique_race',
              'committed_batch_id', v_winner.id
            ),
            last_failure_at = now()
        where id = v_batch.id;

        return jsonb_build_object(
          'batch_id', v_batch.id,
          'committed_batch_id', v_winner.id,
          'state', 'REVALIDATION_REQUIRED',
          'idempotent', true,
          'error', 'CONTEUDO_JA_CONFIRMADO'
        );
      end if;

      raise exception using
        errcode = 'P2899',
        message = 'IMPORTACAO_FALHOU';
    when others then
      raise exception using
        errcode = 'P2899',
        message = 'IMPORTACAO_FALHOU';
  end;

  return jsonb_build_object(
    'batch_id', v_batch.id, 'state', 'COMMITTED', 'idempotent', false,
    'processed_rows', v_changed,
    'stock_changed', v_stock_changed,
    'price_changed', v_price_changed
  );
end;
$$;

create or replace function public.get_allowed_import_branches()
returns table (
  branch_id uuid,
  code text,
  name text,
  is_default boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select b.id, b.code, b.name,
    coalesce(pb.is_default and pb.active, false)
  from public.branches b
  join public.profiles p
    on p.id = auth.uid()
   and p.ativo
  left join public.profile_branches pb
    on pb.branch_id = b.id and pb.profile_id = auth.uid() and pb.active
  where b.active
    and (
      public.is_admin()
      or public.has_module('alimentacao')
      or public.can_approve_products_import()
    )
    and (
      public.is_admin()
      or pb.profile_id is not null
    )
  order by coalesce(pb.is_default, false) desc, b.code
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
  if current_setting('app.stock_sync_source', true) = 'BRANCH_IMPORT_V2' then
    return new;
  end if;

  if v_new_qty < 0 then
    raise exception 'ESTOQUE_LEGADO_NEGATIVO';
  end if;

  select pr_branch_id, sp_branch_id
  into v_pr_branch_id, v_sp_branch_id
  from public.resolve_branch_import_initial_branches();

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

create or replace function public.create_products_import_batch(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_batch_id uuid;
  v_profile_id uuid;
  v_profile_user text;
  v_pr uuid;
  v_sp uuid;
  v_inferred_branch_id uuid;
begin
  v_result := public.create_products_import_batch_v0_impl(payload);
  v_batch_id := nullif(v_result->>'batch_id', '')::uuid;

  select p.id, p.usuario
  into v_profile_id, v_profile_user
  from public.profiles p
  where p.id = auth.uid()
    and p.ativo;

  if v_batch_id is not null and v_profile_id is not null then
    select pr_branch_id, sp_branch_id
    into v_pr, v_sp
    from public.resolve_branch_import_initial_branches();

    select case upper(btrim(coalesce(b.region, '')))
      when 'PR' then v_pr
      when 'SP' then v_sp
      else null
    end
    into v_inferred_branch_id
    from public.products_import_batches b
    where b.id = v_batch_id
      and b.contract_version = 0
      and b.created_by is not distinct from v_profile_user;

    update public.products_import_batches b
    set
      created_by_profile_id = coalesce(b.created_by_profile_id, v_profile_id),
      branch_id = case
        when b.branch_id is not null then b.branch_id
        when v_inferred_branch_id is not null
          and public.can_access_branch(v_inferred_branch_id)
        then v_inferred_branch_id
        else null
      end
    where b.id = v_batch_id
      and b.contract_version = 0
      and b.created_by is not distinct from v_profile_user;
  end if;

  return v_result;
end;
$$;

create or replace function public.preview_products_import_batch(batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
    from public.products_import_batches b
    where b.id = preview_products_import_batch.batch_id
      and b.contract_version = 0
      and public.can_access_product_import_batch_row(
        b.contract_version,
        b.branch_id,
        b.created_by_profile_id,
        b.created_by,
        false,
        false,
        false
      )
  ) then
    raise exception using
      errcode = 'P2812',
      message = 'IMPORTACAO_NAO_DISPONIVEL_NESTE_FLUXO';
  end if;

  return public.preview_products_import_batch_v0_impl(
    preview_products_import_batch.batch_id
  );
end;
$$;

create or replace function public.approve_products_import_batch(batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
    from public.products_import_batches b
    where b.id = approve_products_import_batch.batch_id
      and b.contract_version = 0
      and public.can_access_product_import_batch_row(
        b.contract_version,
        b.branch_id,
        b.created_by_profile_id,
        b.created_by,
        true,
        false,
        false
      )
  ) then
    raise exception using
      errcode = 'P2812',
      message = 'IMPORTACAO_NAO_DISPONIVEL_NESTE_FLUXO';
  end if;

  return public.approve_products_import_batch_v0_impl(
    approve_products_import_batch.batch_id
  );
end;
$$;

create or replace function public.commit_products_import_batch(batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
    from public.products_import_batches b
    where b.id = commit_products_import_batch.batch_id
      and b.contract_version = 0
      and public.can_access_product_import_batch_row(
        b.contract_version,
        b.branch_id,
        b.created_by_profile_id,
        b.created_by,
        true,
        false,
        false
      )
  ) then
    raise exception using
      errcode = 'P2812',
      message = 'IMPORTACAO_NAO_DISPONIVEL_NESTE_FLUXO';
  end if;

  return public.commit_products_import_batch_v0_impl(
    commit_products_import_batch.batch_id
  );
end;
$$;

create or replace function public.get_products_import_batches_report(
  filters jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_page integer := greatest(coalesce((filters->>'page')::integer, 1), 1);
  v_page_size integer := least(
    greatest(coalesce((filters->>'page_size')::integer, 25), 1),
    100
  );
  v_offset integer := 0;
  v_date_from timestamptz := nullif(filters->>'date_from', '')::timestamptz;
  v_date_to timestamptz := nullif(filters->>'date_to', '')::timestamptz;
  v_status text := nullif(filters->>'status', '');
  v_region text := nullif(upper(trim(coalesce(filters->>'region', ''))), '');
  v_user text := nullif(trim(coalesce(filters->>'user', '')), '');
  v_search text := nullif(trim(coalesce(filters->>'search', '')), '');
  v_source text := nullif(trim(coalesce(filters->>'source_name', '')), '');
  v_error_only boolean := coalesce((filters->>'error_only')::boolean, false);
  v_imported_only boolean := coalesce((filters->>'imported_only')::boolean, false);
  v_pending_only boolean := coalesce((filters->>'pending_only')::boolean, false);
begin
  if not exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.ativo
      and public.can_view_products_import_batches()
  ) then
    raise exception 'SEM_PERMISSAO_VISUALIZAR_LOTES';
  end if;

  if public.is_admin() then
    return public.get_products_import_batches_report_v0_impl(filters);
  end if;

  v_offset := (v_page - 1) * v_page_size;

  return (
    with filtered as materialized (
      select
        b.id,
        b.created_at,
        b.created_by,
        b.import_type,
        b.region,
        b.source_name,
        b.file_hash,
        b.status,
        b.total_rows,
        b.valid_rows,
        b.invalid_rows,
        b.warning_count,
        b.error_count,
        b.summary,
        b.approved_at,
        b.approved_by,
        b.imported_at,
        extract(epoch from (
          coalesce(b.imported_at, b.approved_at, b.failed_at, b.created_at)
          - b.created_at
        ))::integer as duration_seconds,
        case
          when b.status in ('approved', 'imported', 'committed')
          then b.valid_rows
          else 0
        end as approved_rows,
        case
          when b.status in ('imported', 'committed')
          then b.valid_rows
          else 0
        end as imported_rows
      from public.products_import_batches b
      where public.can_access_product_import_batch_row(
          b.contract_version,
          b.branch_id,
          b.created_by_profile_id,
          b.created_by,
          false,
          false,
          true
        )
        and (v_date_from is null or b.created_at >= v_date_from)
        and (v_date_to is null or b.created_at < v_date_to + interval '1 day')
        and (v_status is null or b.status = v_status)
        and (v_region is null or b.region = v_region)
        and (
          v_user is null
          or b.created_by ilike '%' || v_user || '%'
          or b.approved_by ilike '%' || v_user || '%'
        )
        and (v_source is null or b.source_name ilike '%' || v_source || '%')
        and (not v_error_only or b.error_count > 0 or b.status = 'failed')
        and (not v_imported_only or b.status in ('imported', 'committed'))
        and (
          not v_pending_only
          or b.status in ('validating', 'validated', 'approved')
        )
        and (
          v_search is null
          or b.id::text ilike '%' || v_search || '%'
          or b.source_name ilike '%' || v_search || '%'
          or b.file_hash ilike '%' || v_search || '%'
          or b.created_by ilike '%' || v_search || '%'
          or b.approved_by ilike '%' || v_search || '%'
        )
    ),
    totals as (
      select
        count(*)::integer as total_batches,
        count(*) filter (
          where status in ('imported', 'committed')
        )::integer as imported_batches,
        count(*) filter (
          where error_count > 0 or status = 'failed'
        )::integer as error_batches,
        count(*) filter (
          where status in ('validating', 'validated', 'approved')
        )::integer as pending_batches,
        coalesce(sum(total_rows), 0)::integer as total_products,
        coalesce(sum(imported_rows), 0)::integer as imported_products,
        coalesce(round(avg(
          case
            when total_rows > 0
            then valid_rows::numeric / total_rows * 100
            else null
          end
        ), 2), 0) as success_percent
      from filtered
    ),
    paged as (
      select *
      from filtered
      order by created_at desc, id desc
      limit v_page_size offset v_offset
    )
    select jsonb_build_object(
      'summary', to_jsonb(totals),
      'pagination', jsonb_build_object(
        'page', v_page,
        'pageSize', v_page_size,
        'total', totals.total_batches,
        'hasNext', v_offset + v_page_size < totals.total_batches,
        'hasPrevious', v_page > 1
      ),
      'rows', coalesce((
        select jsonb_agg(
          to_jsonb(paged)
          order by paged.created_at desc, paged.id desc
        )
        from paged
      ), '[]'::jsonb)
    )
    from totals
  );
end;
$$;

create or replace function public.get_products_import_batch_details(
  batch_id uuid,
  page integer default 1,
  page_size integer default 25
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_page integer := greatest(coalesce(page, 1), 1);
  v_page_size integer := least(greatest(coalesce(page_size, 25), 1), 100);
begin
  if not exists (
    select 1
    from public.products_import_batches b
    where b.id = get_products_import_batch_details.batch_id
      and public.can_access_product_import_batch_row(
        b.contract_version,
        b.branch_id,
        b.created_by_profile_id,
        b.created_by,
        false,
        false,
        true
      )
  ) then
    return jsonb_build_object(
      'batch', '{}'::jsonb,
      'items', '[]'::jsonb,
      'itemsPagination', jsonb_build_object(
        'page', v_page,
        'pageSize', v_page_size,
        'total', 0,
        'hasNext', false,
        'hasPrevious', v_page > 1
      ),
      'audit', '[]'::jsonb
    );
  end if;

  return public.get_products_import_batch_details_v0_impl(
    get_products_import_batch_details.batch_id,
    page,
    page_size
  );
end;
$$;

drop policy if exists product_branch_stock_commercial_read
on public.product_branch_stock;
create policy product_branch_stock_commercial_read
on public.product_branch_stock
for select to authenticated
using (
  public.can_access_branch(branch_id)
  and (
    public.is_admin()
    or public.has_module('produtos')
    or public.has_module('novo_pedido')
    or public.has_module('nova_cotacao')
    or public.has_module('alimentacao')
    or public.has_module('dashboard')
  )
);

alter table public.products_import_batches enable row level security;
alter table public.products_import_stage enable row level security;
alter table public.products_import_audit enable row level security;

revoke all on table
  public.products_import_batches,
  public.products_import_stage,
  public.products_import_audit
from public, anon, authenticated;

grant select on table
  public.products_import_batches,
  public.products_import_stage,
  public.products_import_audit
to authenticated;

drop policy if exists products_import_batches_read on public.products_import_batches;
create policy products_import_batches_read
on public.products_import_batches
for select to authenticated
using (
  public.can_view_products_import_batches()
  and public.can_access_product_import_batch_row(
    contract_version,
    branch_id,
    created_by_profile_id,
    created_by,
    false,
    false,
    true
  )
);

drop policy if exists products_import_stage_read on public.products_import_stage;
create policy products_import_stage_read
on public.products_import_stage
for select to authenticated
using (
  public.can_view_products_import_batches()
  and exists (
    select 1 from public.products_import_batches b
    where b.id = products_import_stage.batch_id
      and public.can_access_product_import_batch_row(
        b.contract_version,
        b.branch_id,
        b.created_by_profile_id,
        b.created_by,
        false,
        false,
        true
      )
  )
);

drop policy if exists products_import_audit_read on public.products_import_audit;
create policy products_import_audit_read
on public.products_import_audit
for select to authenticated
using (
  public.can_view_products_import_batches()
  and exists (
    select 1 from public.products_import_batches b
    where b.id = products_import_audit.batch_id
      and public.can_access_product_import_batch_row(
        b.contract_version,
        b.branch_id,
        b.created_by_profile_id,
        b.created_by,
        false,
        false,
        true
      )
  )
);

revoke all on function
  public.branch_import_allowed_fields(text),
  public.normalize_branch_import_mask(text, text[]),
  public.canonicalize_branch_import_data(text[], jsonb),
  public.resolve_branch_import_initial_branches(),
  public.compute_product_import_staging_hash(uuid),
  public.create_products_import_batch_v0_impl(jsonb),
  public.preview_products_import_batch_v0_impl(uuid),
  public.approve_products_import_batch_v0_impl(uuid),
  public.commit_products_import_batch_v0_impl(uuid),
  public.get_products_import_batches_report_v0_impl(jsonb),
  public.get_products_import_batch_details_v0_impl(uuid, integer, integer)
from public, anon, authenticated;

revoke all on function public.can_access_product_import_batch_row(
  integer, uuid, uuid, text, boolean, boolean, boolean
) from public, anon;

grant execute on function public.can_access_product_import_batch_row(
  integer, uuid, uuid, text, boolean, boolean, boolean
) to authenticated;

revoke all on function
  public.create_product_import_batch(jsonb),
  public.stage_product_import_rows(uuid, jsonb),
  public.reset_product_import_batch_to_draft(uuid),
  public.preview_product_import_batch(uuid),
  public.approve_product_import_batch(uuid),
  public.commit_product_import_batch(uuid),
  public.get_allowed_import_branches()
from public, anon;

grant execute on function
  public.create_product_import_batch(jsonb),
  public.stage_product_import_rows(uuid, jsonb),
  public.reset_product_import_batch_to_draft(uuid),
  public.preview_product_import_batch(uuid),
  public.approve_product_import_batch(uuid),
  public.commit_product_import_batch(uuid),
  public.get_allowed_import_branches()
to authenticated;

commit;
