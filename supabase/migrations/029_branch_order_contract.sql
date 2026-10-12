begin;

set local lock_timeout = '10s';
set local statement_timeout = '120s';

do $$
declare
  v_missing text;
begin
  select string_agg(required_object, ', ' order by required_object)
  into v_missing
  from (
    values
      ('public.orders', to_regclass('public.orders')),
      ('public.order_items', to_regclass('public.order_items')),
      ('public.quotations', to_regclass('public.quotations')),
      ('public.quotation_items', to_regclass('public.quotation_items')),
      ('public.branches', to_regclass('public.branches')),
      ('public.profile_branches', to_regclass('public.profile_branches')),
      ('public.product_branch_stock', to_regclass('public.product_branch_stock')),
      ('public.product_branch_prices', to_regclass('public.product_branch_prices')),
      ('public.stock_movements', to_regclass('public.stock_movements')),
      (
        'public.branch_import_legacy_function_snapshots',
        to_regclass('public.branch_import_legacy_function_snapshots')
      ),
      (
        'public.branch_import_legacy_table_acl_snapshots',
        to_regclass('public.branch_import_legacy_table_acl_snapshots')
      )
  ) required(required_object, object_oid)
  where object_oid is null;

  if v_missing is not null then
    raise exception using
      errcode = '42P01',
      message = 'MIGRATION_029_MISSING_PREREQUISITES',
      detail = v_missing;
  end if;
end;
$$;

do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute
      'lock table supabase_migrations.schema_migrations in share mode';
  end if;
end;
$$;

lock table public.branches in share mode;
lock table public.orders, public.order_items,
  public.quotations, public.quotation_items
  in share row exclusive mode;
lock table public.branch_import_legacy_function_snapshots
  in share row exclusive mode;

do $validate_legacy_commercial_security$
begin
  if (
    select count(*)
    from pg_class c
    where c.oid = any(array[
      'public.orders'::regclass,
      'public.order_items'::regclass,
      'public.quotations'::regclass,
      'public.quotation_items'::regclass
    ])
      and c.relkind = 'r'
      and c.relrowsecurity
      and not c.relforcerowsecurity
      and c.relowner = 'postgres'::regrole
      and (
        select string_agg(
          grantor_role.rolname || ':' ||
          coalesce(grantee_role.rolname, 'PUBLIC') || ':' ||
          acl.privilege_type || ':' || acl.is_grantable,
          ','
          order by
            grantor_role.rolname,
            coalesce(grantee_role.rolname, 'PUBLIC'),
            acl.privilege_type,
            acl.is_grantable
        )
        from aclexplode(c.relacl) acl
        join pg_roles grantor_role on grantor_role.oid = acl.grantor
        left join pg_roles grantee_role
          on grantee_role.oid = nullif(acl.grantee, 0)
      ) =
        'postgres:authenticated:SELECT:false,' ||
        'postgres:postgres:DELETE:false,' ||
        'postgres:postgres:INSERT:false,' ||
        'postgres:postgres:MAINTAIN:false,' ||
        'postgres:postgres:REFERENCES:false,' ||
        'postgres:postgres:SELECT:false,' ||
        'postgres:postgres:TRIGGER:false,' ||
        'postgres:postgres:TRUNCATE:false,' ||
        'postgres:postgres:UPDATE:false'
      and not exists (
        select 1
        from pg_attribute attribute_row
        where attribute_row.attrelid = c.oid
          and attribute_row.attnum > 0
          and not attribute_row.attisdropped
          and attribute_row.attacl is not null
      )
      and has_table_privilege('authenticated', c.oid, 'SELECT')
      and not has_table_privilege(
        'authenticated',
        c.oid,
        'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
      )
      and not has_any_column_privilege(
        'authenticated',
        c.oid,
        'INSERT,UPDATE,REFERENCES'
      )
      and not has_table_privilege(
        'anon',
        c.oid,
        'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
      )
      and not has_any_column_privilege(
        'anon',
        c.oid,
        'SELECT,INSERT,UPDATE,REFERENCES'
      )
      and not has_table_privilege(
        'public',
        c.oid,
        'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
      )
      and not has_any_column_privilege(
        'public',
        c.oid,
        'SELECT,INSERT,UPDATE,REFERENCES'
      )
  ) <> 4
  or (
    select count(*)
    from pg_policy p
    where p.polrelid = any(array[
      'public.orders'::regclass,
      'public.order_items'::regclass,
      'public.quotations'::regclass,
      'public.quotation_items'::regclass
    ])
      and (p.polrelid::regclass::text, p.polname) in (
        ('orders', 'orders_create'),
        ('orders', 'orders_read'),
        ('orders', 'orders_scoped_update'),
        ('order_items', 'order_items_create'),
        ('order_items', 'order_items_read'),
        ('quotations', 'quotations_create'),
        ('quotations', 'quotations_read'),
        ('quotations', 'quotations_scoped_update'),
        ('quotation_items', 'quotation_items_create'),
        ('quotation_items', 'quotation_items_read')
      )
  ) <> 10
  or (
    select count(*)
    from pg_policy p
    where p.polrelid = any(array[
      'public.orders'::regclass,
      'public.order_items'::regclass,
      'public.quotations'::regclass,
      'public.quotation_items'::regclass
    ])
  ) <> 10 then
    raise exception using
      errcode = '55000',
      message = 'MIGRATION_029_LEGACY_COMMERCIAL_SECURITY_MISMATCH';
  end if;
end
$validate_legacy_commercial_security$;

do $$
begin
  if to_regclass('public.order_stock_contract_settings') is not null then
    execute
      'lock table public.order_stock_contract_settings
       in share row exclusive mode';
  end if;
end;
$$;

do $$
declare
  v_used boolean;
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null
     and exists (
       select 1
       from supabase_migrations.schema_migrations
       where version ~ '^[0-9]+$'
         and version::numeric > 29
     ) then
    raise exception using
      errcode = '55000',
      message = 'MIGRATION_029_REAPPLICATION_BLOCKED_DOWNSTREAM_MIGRATION';
  end if;

  if to_regclass('public.order_stock_contract_settings') is not null
     and (
       select count(*)
       from information_schema.columns
       where table_schema = 'public'
         and table_name = 'order_stock_contract_settings'
         and column_name in (
           'singleton',
           'order_stock_contract_v1_enabled'
         )
      ) = 2
      and (
        select count(*)
        from pg_catalog.pg_attribute a
        where a.attrelid = to_regclass('public.order_stock_contract_settings')
          and a.attnum > 0
          and not a.attisdropped
          and (
            (a.attname = 'singleton' and a.atttypid = 'boolean'::regtype)
            or (
              a.attname = 'order_stock_contract_v1_enabled'
              and a.atttypid = 'boolean'::regtype
            )
          )
      ) = 2 then
    execute
      'select exists (
         select 1
         from public.order_stock_contract_settings
         where singleton and order_stock_contract_v1_enabled
       )'
      into v_used;
    if v_used then
      raise exception using
        errcode = '55000',
        message = 'MIGRATION_029_REAPPLICATION_BLOCKED_V1_ENABLED';
    end if;
  end if;

  if (
    select count(*)
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'orders'
      and column_name in (
        'stock_contract_version',
        'logistics_status',
        'operational_version'
      )
  ) = 3
  and (
    select count(*)
    from pg_catalog.pg_attribute a
    where a.attrelid = 'public.orders'::regclass
      and a.attnum > 0
      and not a.attisdropped
      and (
        (a.attname = 'stock_contract_version' and a.atttypid = 'smallint'::regtype)
        or (a.attname = 'logistics_status' and a.atttypid = 'text'::regtype)
        or (a.attname = 'operational_version' and a.atttypid = 'bigint'::regtype)
      )
  ) = 3 then
    execute
      'select exists (
         select 1
         from public.orders
         where stock_contract_version = 1
            or logistics_status <> ''LEGACY_UNMANAGED''
            or operational_version <> 0
       )'
      into v_used;
    if v_used then
      raise exception using
        errcode = '55000',
        message = 'MIGRATION_029_REAPPLICATION_BLOCKED_ORDER_USE';
    end if;
  end if;

  if (
    select count(*)
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'quotations'
      and column_name in (
        'stock_contract_version',
        'operational_version'
      )
  ) = 2
  and (
    select count(*)
    from pg_catalog.pg_attribute a
    where a.attrelid = 'public.quotations'::regclass
      and a.attnum > 0
      and not a.attisdropped
      and (
        (a.attname = 'stock_contract_version' and a.atttypid = 'smallint'::regtype)
        or (a.attname = 'operational_version' and a.atttypid = 'bigint'::regtype)
      )
  ) = 2 then
    execute
      'select exists (
         select 1
         from public.quotations
         where stock_contract_version = 1
            or operational_version <> 0
       )'
      into v_used;
    if v_used then
      raise exception using
        errcode = '55000',
        message = 'MIGRATION_029_REAPPLICATION_BLOCKED_QUOTATION_USE';
    end if;
  end if;

  if (
    select count(*)
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'order_items'
      and column_name in (
        'branch_price',
        'branch_price_currency',
        'branch_price_version',
        'branch_price_captured_at'
      )
  ) = 4 then
    execute
      'select exists (
         select 1
         from public.order_items
         where branch_price is not null
            or branch_price_currency is not null
            or branch_price_version is not null
            or branch_price_captured_at is not null
       )'
      into v_used;
    if v_used then
      raise exception using
        errcode = '55000',
        message = 'MIGRATION_029_REAPPLICATION_BLOCKED_ORDER_SNAPSHOT_USE';
    end if;
  end if;

  if (
    select count(*)
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'quotation_items'
      and column_name in (
        'branch_price',
        'branch_price_currency',
        'branch_price_version',
        'branch_price_captured_at'
      )
  ) = 4 then
    execute
      'select exists (
         select 1
         from public.quotation_items
         where branch_price is not null
            or branch_price_currency is not null
            or branch_price_version is not null
            or branch_price_captured_at is not null
       )'
      into v_used;
    if v_used then
      raise exception using
        errcode = '55000',
        message = 'MIGRATION_029_REAPPLICATION_BLOCKED_QUOTATION_SNAPSHOT_USE';
    end if;
  end if;
end;
$$;

do $reject_existing_029$
begin
  if to_regclass('public.order_stock_contract_settings') is not null
     or to_regprocedure(
       'public.enforce_branch_order_contract()'
     ) is not null
     or to_regprocedure(
       'public.enforce_branch_price_snapshot_parent()'
     ) is not null
     or to_regprocedure(
       'public.serialize_branch_order_contract_statement()'
     ) is not null
     or to_regprocedure(
       'public.is_active_branch_order_profile()'
     ) is not null
     or to_regprocedure(
       'public.is_branch_order_supervisor()'
     ) is not null
     or exists (
       select 1
       from pg_trigger trigger_row
       where not trigger_row.tgisinternal
         and (
           (
             trigger_row.tgrelid = 'public.orders'::regclass
             and trigger_row.tgname in (
               'orders_serialize_branch_contract_029',
               'orders_enforce_branch_contract_029'
             )
           )
           or (
             trigger_row.tgrelid = 'public.quotations'::regclass
             and trigger_row.tgname in (
               'quotations_serialize_branch_contract_029',
               'quotations_enforce_branch_contract_029'
             )
           )
           or (
             trigger_row.tgrelid = 'public.order_items'::regclass
             and trigger_row.tgname in (
               'order_items_serialize_branch_snapshot_insert_029',
               'order_items_serialize_branch_snapshot_update_029',
               'order_items_serialize_branch_snapshot_write_029',
               'order_items_enforce_branch_snapshot_029'
             )
           )
           or (
             trigger_row.tgrelid = 'public.quotation_items'::regclass
             and trigger_row.tgname in (
               'quotation_items_serialize_branch_snapshot_insert_029',
               'quotation_items_serialize_branch_snapshot_update_029',
               'quotation_items_serialize_branch_snapshot_write_029',
               'quotation_items_enforce_branch_snapshot_029'
             )
           )
         )
     ) then
    raise exception using
      errcode = '55000',
      message = 'MIGRATION_029_ALREADY_APPLIED_OR_PARTIAL';
  end if;
end
$reject_existing_029$;

create temporary table migration_029_expected_settings (
  singleton boolean primary key default true,
  order_stock_contract_v1_enabled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint expected_settings_singleton_check check (singleton)
) on commit drop;

create temporary table migration_029_expected_branches (
  id uuid primary key
) on commit drop;

create temporary table migration_029_expected_orders (
  id uuid,
  user_id uuid,
  data_hora timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  branch_id uuid,
  stock_contract_version smallint not null default 0,
  logistics_status text not null default 'LEGACY_UNMANAGED',
  priority text,
  promised_at timestamptz,
  operational_version bigint not null default 0,
  branch_locked_at timestamptz,
  approval_requested_at timestamptz,
  price_revalidation_required_at timestamptz,
  constraint expected_orders_branch_id_fkey
    foreign key (branch_id)
    references migration_029_expected_branches(id)
    on delete restrict,
  constraint expected_orders_stock_contract_version_check
    check (stock_contract_version in (0, 1)),
  constraint expected_orders_logistics_status_check
    check (logistics_status in (
      'LEGACY_UNMANAGED',
      'DRAFT',
      'READY_FOR_APPROVAL',
      'AWAITING_STOCK',
      'RESERVED',
      'CONSUMED',
      'CANCELLED'
    )),
  constraint expected_orders_priority_check
    check (priority is null or priority in ('LOW', 'NORMAL', 'HIGH', 'URGENT')),
  constraint expected_orders_operational_version_check
    check (operational_version >= 0),
  constraint expected_orders_contract_coherence_check
    check (
      (
        stock_contract_version = 0
        and logistics_status = 'LEGACY_UNMANAGED'
        and operational_version = 0
        and priority is null
        and promised_at is null
        and branch_locked_at is null
        and approval_requested_at is null
        and price_revalidation_required_at is null
      )
      or
      (
        stock_contract_version = 1
        and branch_id is not null
        and logistics_status <> 'LEGACY_UNMANAGED'
        and priority is not null
      )
    ),
  constraint expected_orders_contract_dates_check
    check (
      (promised_at is null or promised_at >= data_hora)
      and (branch_locked_at is null or branch_locked_at >= created_at)
      and (approval_requested_at is null or approval_requested_at >= created_at)
      and (
        price_revalidation_required_at is null
        or (
          approval_requested_at is not null
          and price_revalidation_required_at >= approval_requested_at
        )
      )
    )
) on commit drop;

create temporary table migration_029_expected_quotations (
  id uuid,
  user_id uuid,
  data_hora timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  branch_id uuid,
  stock_contract_version smallint not null default 0,
  priority text,
  promised_at timestamptz,
  operational_version bigint not null default 0,
  constraint expected_quotations_branch_id_fkey
    foreign key (branch_id)
    references migration_029_expected_branches(id)
    on delete restrict,
  constraint expected_quotations_stock_contract_version_check
    check (stock_contract_version in (0, 1)),
  constraint expected_quotations_priority_check
    check (priority is null or priority in ('LOW', 'NORMAL', 'HIGH', 'URGENT')),
  constraint expected_quotations_operational_version_check
    check (operational_version >= 0),
  constraint expected_quotations_contract_coherence_check
    check (
      (
        stock_contract_version = 0
        and operational_version = 0
        and priority is null
        and promised_at is null
      )
      or
      (
        stock_contract_version = 1
        and branch_id is not null
        and priority is not null
      )
    ),
  constraint expected_quotations_contract_dates_check
    check (promised_at is null or promised_at >= data_hora)
) on commit drop;

create temporary table migration_029_expected_order_items (
  id uuid,
  order_id uuid,
  codigo text,
  branch_price numeric(14,4),
  branch_price_currency character(3),
  branch_price_version bigint,
  branch_price_captured_at timestamptz,
  constraint expected_order_items_branch_price_snapshot_check
    check (
      (
        branch_price is null
        and branch_price_currency is null
        and branch_price_version is null
        and branch_price_captured_at is null
      )
      or
      (
        branch_price is not null
        and branch_price >= 0
        and branch_price_currency is not null
        and branch_price_currency = upper(branch_price_currency)
        and branch_price_currency ~ '^[A-Z]{3}$'
        and branch_price_version is not null
        and branch_price_version >= 1
        and branch_price_captured_at is not null
      )
    )
) on commit drop;

create temporary table migration_029_expected_quotation_items (
  id uuid,
  quotation_id uuid,
  codigo text,
  branch_price numeric(14,4),
  branch_price_currency character(3),
  branch_price_version bigint,
  branch_price_captured_at timestamptz,
  constraint expected_quotation_items_branch_price_snapshot_check
    check (
      (
        branch_price is null
        and branch_price_currency is null
        and branch_price_version is null
        and branch_price_captured_at is null
      )
      or
      (
        branch_price is not null
        and branch_price >= 0
        and branch_price_currency is not null
        and branch_price_currency = upper(branch_price_currency)
        and branch_price_currency ~ '^[A-Z]{3}$'
        and branch_price_version is not null
        and branch_price_version >= 1
        and branch_price_captured_at is not null
      )
    )
) on commit drop;

create unique index expected_order_items_order_product_unique
  on migration_029_expected_order_items (order_id, codigo);
create unique index expected_quotation_items_quotation_product_unique
  on migration_029_expected_quotation_items (quotation_id, codigo);
create index expected_orders_branch_logistics_v1
  on migration_029_expected_orders (
    branch_id,
    logistics_status,
    updated_at desc,
    id
  )
  where stock_contract_version = 1;
create index expected_orders_branch_priority_v1
  on migration_029_expected_orders (branch_id, priority, promised_at, id)
  where stock_contract_version = 1;
create index expected_orders_owner_branch_v1
  on migration_029_expected_orders (
    user_id,
    branch_id,
    created_at desc,
    id
  )
  where stock_contract_version = 1;
create index expected_quotations_branch_v1
  on migration_029_expected_quotations (branch_id, updated_at desc, id)
  where stock_contract_version = 1;
create index expected_quotations_owner_branch_v1
  on migration_029_expected_quotations (
    user_id,
    branch_id,
    created_at desc,
    id
  )
  where stock_contract_version = 1;

create or replace function pg_temp.assert_migration_029_structure(
  require_all boolean
)
returns void
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $$
declare
  item record;
  actual_column record;
  expected_column record;
  actual_constraint record;
  expected_constraint record;
  actual_index record;
  expected_index record;
  actual_relation regclass;
  expected_relation regclass;
  object_required boolean;
  settings_exists boolean;
begin
  settings_exists :=
    to_regclass('public.order_stock_contract_settings') is not null;

  if settings_exists then
    if not exists (
      select 1
      from pg_class c
      where c.oid = 'public.order_stock_contract_settings'::regclass
        and c.relkind in ('r', 'p')
    ) or (
      select count(*)
      from pg_attribute a
      where a.attrelid = 'public.order_stock_contract_settings'::regclass
        and a.attnum > 0
        and not a.attisdropped
    ) <> 4 then
      raise exception using
        errcode = '55000',
        message = 'MIGRATION_029_SETTINGS_TABLE_FINGERPRINT_MISMATCH';
    end if;
  end if;

  for item in
    select *
    from (
      values
        ('order_stock_contract_settings', 'migration_029_expected_settings', 'singleton'),
        ('order_stock_contract_settings', 'migration_029_expected_settings', 'order_stock_contract_v1_enabled'),
        ('order_stock_contract_settings', 'migration_029_expected_settings', 'created_at'),
        ('order_stock_contract_settings', 'migration_029_expected_settings', 'updated_at'),
        ('orders', 'migration_029_expected_orders', 'branch_id'),
        ('orders', 'migration_029_expected_orders', 'stock_contract_version'),
        ('orders', 'migration_029_expected_orders', 'logistics_status'),
        ('orders', 'migration_029_expected_orders', 'priority'),
        ('orders', 'migration_029_expected_orders', 'promised_at'),
        ('orders', 'migration_029_expected_orders', 'operational_version'),
        ('orders', 'migration_029_expected_orders', 'branch_locked_at'),
        ('orders', 'migration_029_expected_orders', 'approval_requested_at'),
        ('orders', 'migration_029_expected_orders', 'price_revalidation_required_at'),
        ('quotations', 'migration_029_expected_quotations', 'branch_id'),
        ('quotations', 'migration_029_expected_quotations', 'stock_contract_version'),
        ('quotations', 'migration_029_expected_quotations', 'priority'),
        ('quotations', 'migration_029_expected_quotations', 'promised_at'),
        ('quotations', 'migration_029_expected_quotations', 'operational_version'),
        ('order_items', 'migration_029_expected_order_items', 'branch_price'),
        ('order_items', 'migration_029_expected_order_items', 'branch_price_currency'),
        ('order_items', 'migration_029_expected_order_items', 'branch_price_version'),
        ('order_items', 'migration_029_expected_order_items', 'branch_price_captured_at'),
        ('quotation_items', 'migration_029_expected_quotation_items', 'branch_price'),
        ('quotation_items', 'migration_029_expected_quotation_items', 'branch_price_currency'),
        ('quotation_items', 'migration_029_expected_quotation_items', 'branch_price_version'),
        ('quotation_items', 'migration_029_expected_quotation_items', 'branch_price_captured_at')
    ) columns(actual_table, expected_table, column_name)
  loop
    actual_relation := to_regclass(format('public.%I', item.actual_table));
    expected_relation :=
      to_regclass(format('pg_temp.%I', item.expected_table));
    object_required :=
      require_all
      or (
        item.actual_table = 'order_stock_contract_settings'
        and settings_exists
      );

    select
      a.atttypid as type_oid,
      a.atttypmod as type_modifier,
      a.attnotnull as not_null,
      a.attidentity as identity_kind,
      a.attgenerated as generated_kind,
      a.attcollation as collation_oid,
      coalesce(pg_get_expr(d.adbin, d.adrelid), '') as default_expression
    into expected_column
    from pg_attribute a
    left join pg_attrdef d
      on d.adrelid = a.attrelid
     and d.adnum = a.attnum
    where a.attrelid = expected_relation
      and a.attname = item.column_name
      and a.attnum > 0
      and not a.attisdropped;

    select
      a.atttypid as type_oid,
      a.atttypmod as type_modifier,
      a.attnotnull as not_null,
      a.attidentity as identity_kind,
      a.attgenerated as generated_kind,
      a.attcollation as collation_oid,
      coalesce(pg_get_expr(d.adbin, d.adrelid), '') as default_expression
    into actual_column
    from pg_attribute a
    left join pg_attrdef d
      on d.adrelid = a.attrelid
     and d.adnum = a.attnum
    where a.attrelid = actual_relation
      and a.attname = item.column_name
      and a.attnum > 0
      and not a.attisdropped;

    if not found then
      if object_required then
        raise exception using
          errcode = '55000',
          message = 'MIGRATION_029_COLUMN_FINGERPRINT_MISMATCH',
          detail = format(
            'missing column public.%I.%I',
            item.actual_table,
            item.column_name
          );
      end if;
    elsif actual_column.type_oid <> expected_column.type_oid
       or actual_column.type_modifier <> expected_column.type_modifier
       or actual_column.not_null <> expected_column.not_null
       or actual_column.identity_kind <> expected_column.identity_kind
       or actual_column.generated_kind <> expected_column.generated_kind
       or actual_column.collation_oid <> expected_column.collation_oid
       or actual_column.default_expression
          is distinct from expected_column.default_expression then
      raise exception using
        errcode = '55000',
        message = 'MIGRATION_029_COLUMN_FINGERPRINT_MISMATCH',
        detail = format(
          'column public.%I.%I differs from contract; expected=%s; actual=%s',
          item.actual_table,
          item.column_name,
          to_jsonb(expected_column),
          to_jsonb(actual_column)
        );
    end if;
  end loop;

  for item in
    select *
    from (
      values
        ('order_stock_contract_settings', 'order_stock_contract_settings_pkey', 'migration_029_expected_settings', 'migration_029_expected_settings_pkey'),
        ('order_stock_contract_settings', 'order_stock_contract_settings_singleton_check', 'migration_029_expected_settings', 'expected_settings_singleton_check'),
        ('orders', 'orders_branch_id_fkey_029', 'migration_029_expected_orders', 'expected_orders_branch_id_fkey'),
        ('orders', 'orders_stock_contract_version_check_029', 'migration_029_expected_orders', 'expected_orders_stock_contract_version_check'),
        ('orders', 'orders_logistics_status_check_029', 'migration_029_expected_orders', 'expected_orders_logistics_status_check'),
        ('orders', 'orders_priority_check_029', 'migration_029_expected_orders', 'expected_orders_priority_check'),
        ('orders', 'orders_operational_version_check_029', 'migration_029_expected_orders', 'expected_orders_operational_version_check'),
        ('orders', 'orders_contract_coherence_check_029', 'migration_029_expected_orders', 'expected_orders_contract_coherence_check'),
        ('orders', 'orders_contract_dates_check_029', 'migration_029_expected_orders', 'expected_orders_contract_dates_check'),
        ('quotations', 'quotations_branch_id_fkey_029', 'migration_029_expected_quotations', 'expected_quotations_branch_id_fkey'),
        ('quotations', 'quotations_stock_contract_version_check_029', 'migration_029_expected_quotations', 'expected_quotations_stock_contract_version_check'),
        ('quotations', 'quotations_priority_check_029', 'migration_029_expected_quotations', 'expected_quotations_priority_check'),
        ('quotations', 'quotations_operational_version_check_029', 'migration_029_expected_quotations', 'expected_quotations_operational_version_check'),
        ('quotations', 'quotations_contract_coherence_check_029', 'migration_029_expected_quotations', 'expected_quotations_contract_coherence_check'),
        ('quotations', 'quotations_contract_dates_check_029', 'migration_029_expected_quotations', 'expected_quotations_contract_dates_check'),
        ('order_items', 'order_items_branch_price_snapshot_check_029', 'migration_029_expected_order_items', 'expected_order_items_branch_price_snapshot_check'),
        ('quotation_items', 'quotation_items_branch_price_snapshot_check_029', 'migration_029_expected_quotation_items', 'expected_quotation_items_branch_price_snapshot_check')
    ) constraints(
      actual_table,
      actual_name,
      expected_table,
      expected_name
    )
  loop
    actual_relation := to_regclass(format('public.%I', item.actual_table));
    expected_relation :=
      to_regclass(format('pg_temp.%I', item.expected_table));
    object_required :=
      require_all
      or (
        item.actual_table = 'order_stock_contract_settings'
        and settings_exists
      );

    select
      c.contype as constraint_type,
      c.convalidated as validated,
      c.condeferrable as deferrable,
      c.condeferred as initially_deferred,
      regexp_replace(
        replace(
          pg_get_constraintdef(c.oid, true),
          'migration_029_expected_branches',
          'branches'
        ),
        '\s+',
        ' ',
        'g'
      ) as definition
    into expected_constraint
    from pg_constraint c
    where c.conrelid = expected_relation
      and c.conname = item.expected_name;

    select
      c.contype as constraint_type,
      c.convalidated as validated,
      c.condeferrable as deferrable,
      c.condeferred as initially_deferred,
      regexp_replace(
        pg_get_constraintdef(c.oid, true),
        '\s+',
        ' ',
        'g'
      ) as definition
    into actual_constraint
    from pg_constraint c
    where c.conrelid = actual_relation
      and c.conname = item.actual_name;

    if not found then
      if object_required then
        raise exception using
          errcode = '55000',
          message = 'MIGRATION_029_CONSTRAINT_FINGERPRINT_MISMATCH',
          detail = format(
            'missing constraint public.%I.%I',
            item.actual_table,
            item.actual_name
          );
      end if;
    elsif actual_constraint.constraint_type
          <> expected_constraint.constraint_type
       or actual_constraint.validated <> expected_constraint.validated
       or actual_constraint.deferrable <> expected_constraint.deferrable
       or actual_constraint.initially_deferred
          <> expected_constraint.initially_deferred
       or actual_constraint.definition
          is distinct from expected_constraint.definition then
      raise exception using
        errcode = '55000',
        message = 'MIGRATION_029_CONSTRAINT_FINGERPRINT_MISMATCH',
        detail = format(
          'constraint public.%I.%I differs from contract; expected=%s; actual=%s',
          item.actual_table,
          item.actual_name,
          to_jsonb(expected_constraint),
          to_jsonb(actual_constraint)
        );
    end if;
  end loop;

  for item in
    select *
    from (
      values
        ('order_items', 'order_items_order_product_unique_029', 'expected_order_items_order_product_unique'),
        ('quotation_items', 'quotation_items_quotation_product_unique_029', 'expected_quotation_items_quotation_product_unique'),
        ('orders', 'orders_branch_logistics_v1_idx_029', 'expected_orders_branch_logistics_v1'),
        ('orders', 'orders_branch_priority_v1_idx_029', 'expected_orders_branch_priority_v1'),
        ('orders', 'orders_owner_branch_v1_idx_029', 'expected_orders_owner_branch_v1'),
        ('quotations', 'quotations_branch_v1_idx_029', 'expected_quotations_branch_v1'),
        ('quotations', 'quotations_owner_branch_v1_idx_029', 'expected_quotations_owner_branch_v1')
    ) indexes(actual_table, actual_name, expected_name)
  loop
    actual_relation := to_regclass(format('public.%I', item.actual_name));
    expected_relation :=
      to_regclass(format('pg_temp.%I', item.expected_name));

    if actual_relation is null then
      if require_all then
        raise exception using
          errcode = '55000',
          message = 'MIGRATION_029_INDEX_FINGERPRINT_MISMATCH',
          detail = format('missing index public.%I', item.actual_name);
      end if;
      continue;
    end if;

    select
      i.indrelid as table_oid,
      i.indisunique as unique_index,
      i.indisprimary as primary_index,
      i.indisexclusion as exclusion_index,
      i.indisvalid as valid_index,
      i.indisready as ready_index,
      i.indislive as live_index,
      regexp_replace(
        substring(pg_get_indexdef(i.indexrelid) from ' USING .*$'),
        '\s+',
        ' ',
        'g'
      ) as definition
    into actual_index
    from pg_index i
    where i.indexrelid = actual_relation;

    if not found then
      raise exception using
        errcode = '55000',
        message = 'MIGRATION_029_INDEX_FINGERPRINT_MISMATCH',
        detail = format('public.%I is not an index', item.actual_name);
    end if;

    select
      i.indisunique as unique_index,
      i.indisprimary as primary_index,
      i.indisexclusion as exclusion_index,
      i.indisvalid as valid_index,
      i.indisready as ready_index,
      i.indislive as live_index,
      regexp_replace(
        substring(pg_get_indexdef(i.indexrelid) from ' USING .*$'),
        '\s+',
        ' ',
        'g'
      ) as definition
    into expected_index
    from pg_index i
    where i.indexrelid = expected_relation;

    if actual_index.table_oid
          <> to_regclass(format('public.%I', item.actual_table))
       or actual_index.unique_index <> expected_index.unique_index
       or actual_index.primary_index <> expected_index.primary_index
       or actual_index.exclusion_index <> expected_index.exclusion_index
       or actual_index.valid_index <> expected_index.valid_index
       or actual_index.ready_index <> expected_index.ready_index
       or actual_index.live_index <> expected_index.live_index
       or actual_index.definition is distinct from expected_index.definition then
      raise exception using
        errcode = '55000',
        message = 'MIGRATION_029_INDEX_FINGERPRINT_MISMATCH',
        detail = format(
          'index public.%I differs from contract; expected=%s; actual=%s',
          item.actual_name,
          to_jsonb(expected_index),
          to_jsonb(actual_index)
        );
    end if;
  end loop;
end;
$$;

select pg_temp.assert_migration_029_structure(false);

do $$
declare
  v_pr_count integer;
  v_sp_count integer;
  v_unmapped text;
  v_duplicates text;
begin
  select count(*) into v_pr_count
  from public.branches
  where code = 'PR'
    and active
    and is_headquarters;

  select count(*) into v_sp_count
  from public.branches
  where code = 'SP'
    and active;

  if v_pr_count <> 1 or v_sp_count <> 1 then
    raise exception using
      errcode = '23514',
      message = 'MIGRATION_029_CANONICAL_BRANCHES_INVALID',
      detail = format('PR=%s, SP=%s', v_pr_count, v_sp_count);
  end if;

  select string_agg(format('%s:%s', source_id, region_value), ', ' order by source_id)
  into v_unmapped
  from (
    select id::text as source_id, left(regiao::text, 20) as region_value
    from public.orders o
    where o.regiao is not null
      and not exists (
        select 1
        from public.branches b
        where b.code = o.regiao::text
          and b.active
      )
    union all
    select id::text, left(regiao::text, 20)
    from public.quotations q
    where q.regiao is not null
      and not exists (
        select 1
        from public.branches b
        where b.code = q.regiao::text
          and b.active
      )
  ) unmapped;

  if v_unmapped is not null then
    raise exception using
      errcode = '23514',
      message = 'MIGRATION_029_UNMAPPABLE_REGION',
      detail = v_unmapped;
  end if;

  select string_agg(format('%s:%s', document_id, left(product_code, 80)), ', ' order by document_id, product_code)
  into v_duplicates
  from (
    select order_id::text as document_id, codigo as product_code
    from public.order_items
    group by order_id, codigo
    having count(*) > 1
  ) duplicates;

  if v_duplicates is not null then
    raise exception using
      errcode = '23505',
      message = 'MIGRATION_029_DUPLICATE_ORDER_PRODUCTS',
      detail = v_duplicates;
  end if;

  select string_agg(format('%s:%s', document_id, left(product_code, 80)), ', ' order by document_id, product_code)
  into v_duplicates
  from (
    select quotation_id::text as document_id, codigo as product_code
    from public.quotation_items
    group by quotation_id, codigo
    having count(*) > 1
  ) duplicates;

  if v_duplicates is not null then
    raise exception using
      errcode = '23505',
      message = 'MIGRATION_029_DUPLICATE_QUOTATION_PRODUCTS',
      detail = v_duplicates;
  end if;
end;
$$;

do $$
begin
  if not exists (
    select 1
    from pg_trigger t
    where t.tgrelid = 'public.orders'::regclass
      and t.tgname = 'orders_touch_updated_at'
      and not t.tgisinternal
      and t.tgenabled = 'O'
      and t.tgtype = 19
      and t.tgfoid = 'public.touch_updated_at()'::regprocedure
      and t.tgnargs = 0
      and t.tgqual is null
      and octet_length(t.tgargs) = 0
  ) or not exists (
    select 1
    from pg_trigger t
    where t.tgrelid = 'public.quotations'::regclass
      and t.tgname = 'quotations_touch_updated_at'
      and not t.tgisinternal
      and t.tgenabled = 'O'
      and t.tgtype = 19
      and t.tgfoid = 'public.touch_updated_at()'::regprocedure
      and t.tgnargs = 0
      and t.tgqual is null
      and octet_length(t.tgargs) = 0
  ) or (
    select count(*)
    from pg_trigger t
    where not t.tgisinternal
      and (
        (t.tgrelid = 'public.orders'::regclass
         and t.tgname = 'orders_touch_updated_at')
        or
        (t.tgrelid = 'public.quotations'::regclass
         and t.tgname = 'quotations_touch_updated_at')
      )
  ) <> 2 then
    raise exception using
      errcode = '55000',
      message = 'MIGRATION_029_UPDATED_AT_TRIGGER_INVALID';
  end if;
end;
$$;

create table if not exists public.order_stock_contract_settings (
  singleton boolean primary key default true,
  order_stock_contract_v1_enabled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint order_stock_contract_settings_singleton_check
    check (singleton)
);

insert into public.order_stock_contract_settings (
  singleton,
  order_stock_contract_v1_enabled
)
values (true, false)
on conflict (singleton) do nothing;

do $$
begin
  if not exists (
    select 1
    from public.order_stock_contract_settings
    where singleton
      and not order_stock_contract_v1_enabled
  ) or (
    select count(*)
    from public.order_stock_contract_settings
  ) <> 1 then
    raise exception using
      errcode = '23514',
      message = 'MIGRATION_029_V1_FLAG_MUST_BE_DISABLED_SINGLETON';
  end if;
end;
$$;

drop trigger if exists order_stock_contract_settings_touch_updated_at
  on public.order_stock_contract_settings;
create trigger order_stock_contract_settings_touch_updated_at
before update on public.order_stock_contract_settings
for each row execute function public.touch_updated_at();

alter table public.orders
  add column if not exists branch_id uuid,
  add column if not exists stock_contract_version smallint not null default 0,
  add column if not exists logistics_status text not null default 'LEGACY_UNMANAGED',
  add column if not exists priority text,
  add column if not exists promised_at timestamptz,
  add column if not exists operational_version bigint not null default 0,
  add column if not exists branch_locked_at timestamptz,
  add column if not exists approval_requested_at timestamptz,
  add column if not exists price_revalidation_required_at timestamptz;

alter table public.quotations
  add column if not exists branch_id uuid,
  add column if not exists stock_contract_version smallint not null default 0,
  add column if not exists priority text,
  add column if not exists promised_at timestamptz,
  add column if not exists operational_version bigint not null default 0;

alter table public.order_items
  add column if not exists branch_price numeric(14,4),
  add column if not exists branch_price_currency character(3),
  add column if not exists branch_price_version bigint,
  add column if not exists branch_price_captured_at timestamptz;

alter table public.quotation_items
  add column if not exists branch_price numeric(14,4),
  add column if not exists branch_price_currency character(3),
  add column if not exists branch_price_version bigint,
  add column if not exists branch_price_captured_at timestamptz;

create temporary table migration_029_orders_updated_at_before
on commit drop
as
select o.id, o.updated_at
from public.orders o
join public.branches b
  on b.code = o.regiao::text
 and b.active
where o.regiao is not null
  and o.branch_id is distinct from b.id;

create temporary table migration_029_quotations_updated_at_before
on commit drop
as
select q.id, q.updated_at
from public.quotations q
join public.branches b
  on b.code = q.regiao::text
 and b.active
where q.regiao is not null
  and q.branch_id is distinct from b.id;

alter table public.orders disable trigger orders_touch_updated_at;
alter table public.quotations disable trigger quotations_touch_updated_at;

update public.orders o
set branch_id = b.id
from public.branches b
where o.regiao is not null
  and b.code = o.regiao::text
  and b.active
  and o.branch_id is distinct from b.id;

update public.quotations q
set branch_id = b.id
from public.branches b
where q.regiao is not null
  and b.code = q.regiao::text
  and b.active
  and q.branch_id is distinct from b.id;

alter table public.orders enable trigger orders_touch_updated_at;
alter table public.quotations enable trigger quotations_touch_updated_at;

do $$
begin
  if exists (
    select 1
    from migration_029_orders_updated_at_before old_row
    join public.orders o on o.id = old_row.id
    where o.updated_at is distinct from old_row.updated_at
  ) or exists (
    select 1
    from migration_029_quotations_updated_at_before old_row
    join public.quotations q on q.id = old_row.id
    where q.updated_at is distinct from old_row.updated_at
  ) then
    raise exception using
      errcode = '55000',
      message = 'MIGRATION_029_UPDATED_AT_BACKFILL_CHANGED';
  end if;
end;
$$;

alter table public.orders
  drop constraint if exists orders_branch_id_fkey_029,
  drop constraint if exists orders_stock_contract_version_check_029,
  drop constraint if exists orders_logistics_status_check_029,
  drop constraint if exists orders_priority_check_029,
  drop constraint if exists orders_operational_version_check_029,
  drop constraint if exists orders_contract_coherence_check_029,
  drop constraint if exists orders_contract_dates_check_029;

alter table public.orders
  add constraint orders_branch_id_fkey_029
    foreign key (branch_id) references public.branches(id) on delete restrict
    not valid,
  add constraint orders_stock_contract_version_check_029
    check (stock_contract_version in (0, 1)) not valid,
  add constraint orders_logistics_status_check_029
    check (logistics_status in (
      'LEGACY_UNMANAGED',
      'DRAFT',
      'READY_FOR_APPROVAL',
      'AWAITING_STOCK',
      'RESERVED',
      'CONSUMED',
      'CANCELLED'
    )) not valid,
  add constraint orders_priority_check_029
    check (priority is null or priority in ('LOW', 'NORMAL', 'HIGH', 'URGENT'))
    not valid,
  add constraint orders_operational_version_check_029
    check (operational_version >= 0) not valid,
  add constraint orders_contract_coherence_check_029
    check (
      (
        stock_contract_version = 0
        and logistics_status = 'LEGACY_UNMANAGED'
        and operational_version = 0
        and priority is null
        and promised_at is null
        and branch_locked_at is null
        and approval_requested_at is null
        and price_revalidation_required_at is null
      )
      or
      (
        stock_contract_version = 1
        and branch_id is not null
        and logistics_status <> 'LEGACY_UNMANAGED'
        and priority is not null
      )
    ) not valid,
  add constraint orders_contract_dates_check_029
    check (
      (promised_at is null or promised_at >= data_hora)
      and (branch_locked_at is null or branch_locked_at >= created_at)
      and (approval_requested_at is null or approval_requested_at >= created_at)
      and (
        price_revalidation_required_at is null
        or (
          approval_requested_at is not null
          and price_revalidation_required_at >= approval_requested_at
        )
      )
    ) not valid;

alter table public.quotations
  drop constraint if exists quotations_branch_id_fkey_029,
  drop constraint if exists quotations_stock_contract_version_check_029,
  drop constraint if exists quotations_priority_check_029,
  drop constraint if exists quotations_operational_version_check_029,
  drop constraint if exists quotations_contract_coherence_check_029,
  drop constraint if exists quotations_contract_dates_check_029;

alter table public.quotations
  add constraint quotations_branch_id_fkey_029
    foreign key (branch_id) references public.branches(id) on delete restrict
    not valid,
  add constraint quotations_stock_contract_version_check_029
    check (stock_contract_version in (0, 1)) not valid,
  add constraint quotations_priority_check_029
    check (priority is null or priority in ('LOW', 'NORMAL', 'HIGH', 'URGENT'))
    not valid,
  add constraint quotations_operational_version_check_029
    check (operational_version >= 0) not valid,
  add constraint quotations_contract_coherence_check_029
    check (
      (
        stock_contract_version = 0
        and operational_version = 0
        and priority is null
        and promised_at is null
      )
      or
      (
        stock_contract_version = 1
        and branch_id is not null
        and priority is not null
      )
    ) not valid,
  add constraint quotations_contract_dates_check_029
    check (promised_at is null or promised_at >= data_hora) not valid;

alter table public.order_items
  drop constraint if exists order_items_branch_price_snapshot_check_029;

alter table public.order_items
  add constraint order_items_branch_price_snapshot_check_029
    check (
      (
        branch_price is null
        and branch_price_currency is null
        and branch_price_version is null
        and branch_price_captured_at is null
      )
      or
      (
        branch_price is not null
        and branch_price >= 0
        and branch_price_currency is not null
        and branch_price_currency = upper(branch_price_currency)
        and branch_price_currency ~ '^[A-Z]{3}$'
        and branch_price_version is not null
        and branch_price_version >= 1
        and branch_price_captured_at is not null
      )
    ) not valid;

alter table public.quotation_items
  drop constraint if exists quotation_items_branch_price_snapshot_check_029;

alter table public.quotation_items
  add constraint quotation_items_branch_price_snapshot_check_029
    check (
      (
        branch_price is null
        and branch_price_currency is null
        and branch_price_version is null
        and branch_price_captured_at is null
      )
      or
      (
        branch_price is not null
        and branch_price >= 0
        and branch_price_currency is not null
        and branch_price_currency = upper(branch_price_currency)
        and branch_price_currency ~ '^[A-Z]{3}$'
        and branch_price_version is not null
        and branch_price_version >= 1
        and branch_price_captured_at is not null
      )
    ) not valid;

alter table public.orders validate constraint orders_branch_id_fkey_029;
alter table public.orders validate constraint orders_stock_contract_version_check_029;
alter table public.orders validate constraint orders_logistics_status_check_029;
alter table public.orders validate constraint orders_priority_check_029;
alter table public.orders validate constraint orders_operational_version_check_029;
alter table public.orders validate constraint orders_contract_coherence_check_029;
alter table public.orders validate constraint orders_contract_dates_check_029;

alter table public.quotations validate constraint quotations_branch_id_fkey_029;
alter table public.quotations validate constraint quotations_stock_contract_version_check_029;
alter table public.quotations validate constraint quotations_priority_check_029;
alter table public.quotations validate constraint quotations_operational_version_check_029;
alter table public.quotations validate constraint quotations_contract_coherence_check_029;
alter table public.quotations validate constraint quotations_contract_dates_check_029;

alter table public.order_items
  validate constraint order_items_branch_price_snapshot_check_029;
alter table public.quotation_items
  validate constraint quotation_items_branch_price_snapshot_check_029;

create unique index if not exists order_items_order_product_unique_029
  on public.order_items (order_id, codigo);

create unique index if not exists quotation_items_quotation_product_unique_029
  on public.quotation_items (quotation_id, codigo);

create index if not exists orders_branch_logistics_v1_idx_029
  on public.orders (branch_id, logistics_status, updated_at desc, id)
  where stock_contract_version = 1;

create index if not exists orders_branch_priority_v1_idx_029
  on public.orders (branch_id, priority, promised_at, id)
  where stock_contract_version = 1;

create index if not exists orders_owner_branch_v1_idx_029
  on public.orders (user_id, branch_id, created_at desc, id)
  where stock_contract_version = 1;

create index if not exists quotations_branch_v1_idx_029
  on public.quotations (branch_id, updated_at desc, id)
  where stock_contract_version = 1;

create index if not exists quotations_owner_branch_v1_idx_029
  on public.quotations (user_id, branch_id, created_at desc, id)
  where stock_contract_version = 1;

create or replace function public.is_active_branch_order_profile()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.ativo
  )
$$;

create or replace function public.is_branch_order_supervisor()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.ativo
      and p.perfil = 'SUPERVISOR'
  )
$$;

create or replace function public.serialize_branch_order_contract_statement()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog, public
as $$
begin
  perform pg_advisory_xact_lock(29, 0);

  return null;
end;
$$;

do $validate_legacy_snapshot_storage$
begin
  if to_regclass(
    'public.branch_import_legacy_function_snapshots'
  ) is null
  or exists (
    select 1
    from pg_class c
    where c.oid =
      'public.branch_import_legacy_function_snapshots'::regclass
      and (
        c.relkind <> 'r'
        or c.relrowsecurity
        or c.relforcerowsecurity
      )
  )
  or (
    select count(*)
    from pg_attribute a
    where a.attrelid =
      'public.branch_import_legacy_function_snapshots'::regclass
      and a.attnum > 0
      and not a.attisdropped
  ) <> 8
  or exists (
    with expected(
      attnum,
      attname,
      atttypid,
      attnotnull,
      attidentity,
      attgenerated,
      attcollation,
      default_expression
    ) as (
      values
        (1, 'function_signature', 'text'::regtype::oid, true, ''::"char", ''::"char", (select typcollation from pg_type where oid = 'text'::regtype), null::text),
        (2, 'function_name', 'text'::regtype::oid, true, ''::"char", ''::"char", (select typcollation from pg_type where oid = 'text'::regtype), null::text),
        (3, 'function_definition', 'text'::regtype::oid, true, ''::"char", ''::"char", (select typcollation from pg_type where oid = 'text'::regtype), null::text),
        (4, 'owner_name', 'name'::regtype::oid, true, ''::"char", ''::"char", (select typcollation from pg_type where oid = 'name'::regtype), null::text),
        (5, 'acl_state', 'text'::regtype::oid, true, ''::"char", ''::"char", (select typcollation from pg_type where oid = 'text'::regtype), null::text),
        (6, 'config_state', 'text'::regtype::oid, true, ''::"char", ''::"char", (select typcollation from pg_type where oid = 'text'::regtype), null::text),
        (7, 'definition_md5', 'text'::regtype::oid, true, ''::"char", ''::"char", (select typcollation from pg_type where oid = 'text'::regtype), null::text),
        (8, 'captured_at', 'timestamptz'::regtype::oid, true, ''::"char", ''::"char", 0::oid, 'now()'::text)
    ),
    actual as (
      select
        a.attnum::integer,
        a.attname::text,
        a.atttypid,
        a.attnotnull,
        a.attidentity,
        a.attgenerated,
        a.attcollation,
        pg_get_expr(d.adbin, d.adrelid)
      from pg_attribute a
      left join pg_attrdef d
        on d.adrelid = a.attrelid
       and d.adnum = a.attnum
      where a.attrelid =
        'public.branch_import_legacy_function_snapshots'::regclass
        and a.attnum > 0
        and not a.attisdropped
    )
    (select * from expected except select * from actual)
    union all
    (select * from actual except select * from expected)
  )
  or (
    select count(*)
    from pg_constraint con
    where con.conrelid =
      'public.branch_import_legacy_function_snapshots'::regclass
      and (
        (con.conname = 'branch_import_legacy_function_snapshots_pkey'
         and con.contype = 'p'
         and pg_get_constraintdef(con.oid, true) =
           'PRIMARY KEY (function_signature)')
        or
        (con.conname =
           'branch_import_legacy_function_snapshots_function_name_key'
         and con.contype = 'u'
         and pg_get_constraintdef(con.oid, true) =
           'UNIQUE (function_name)')
      )
  ) <> 2
  or (
    select count(*)
    from pg_constraint con
    where con.conrelid =
      'public.branch_import_legacy_function_snapshots'::regclass
  ) <> 2
  or (
    select count(*)
    from pg_index i
    join pg_class index_class on index_class.oid = i.indexrelid
    join pg_am access_method on access_method.oid = index_class.relam
    where i.indrelid =
      'public.branch_import_legacy_function_snapshots'::regclass
      and (
        (
          index_class.relname =
            'branch_import_legacy_function_snapshots_pkey'
          and i.indisprimary
          and i.indisunique
          and i.indnkeyatts = 1
          and i.indnatts = 1
          and i.indkey::text = '1'
          and i.indpred is null
          and i.indexprs is null
          and access_method.amname = 'btree'
        )
        or
        (
          index_class.relname =
            'branch_import_legacy_function_snapshots_function_name_key'
          and not i.indisprimary
          and i.indisunique
          and i.indnkeyatts = 1
          and i.indnatts = 1
          and i.indkey::text = '2'
          and i.indpred is null
          and i.indexprs is null
          and access_method.amname = 'btree'
        )
      )
  ) <> 2
  or (
    select count(*)
    from pg_index i
    where i.indrelid =
      'public.branch_import_legacy_function_snapshots'::regclass
  ) <> 2
  or exists (
    select 1
    from pg_trigger t
    where t.tgrelid =
      'public.branch_import_legacy_function_snapshots'::regclass
      and not t.tgisinternal
  )
  or exists (
    select 1
    from pg_policy p
    where p.polrelid =
      'public.branch_import_legacy_function_snapshots'::regclass
  )
  or (
    select snapshot_table.relowner <> acl_snapshot_table.relowner
    from pg_class snapshot_table
    cross join pg_class acl_snapshot_table
    where snapshot_table.oid =
      'public.branch_import_legacy_function_snapshots'::regclass
      and acl_snapshot_table.oid =
        'public.branch_import_legacy_table_acl_snapshots'::regclass
  )
  or has_table_privilege(
    'anon',
    'public.branch_import_legacy_function_snapshots',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
  )
  or has_any_column_privilege(
    'anon',
    'public.branch_import_legacy_function_snapshots',
    'SELECT,INSERT,UPDATE,REFERENCES'
  )
  or has_table_privilege(
    'authenticated',
    'public.branch_import_legacy_function_snapshots',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
  )
  or has_any_column_privilege(
    'authenticated',
    'public.branch_import_legacy_function_snapshots',
    'SELECT,INSERT,UPDATE,REFERENCES'
  )
  or has_table_privilege(
    'public',
    'public.branch_import_legacy_function_snapshots',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
  )
  or has_any_column_privilege(
    'public',
    'public.branch_import_legacy_function_snapshots',
    'SELECT,INSERT,UPDATE,REFERENCES'
  ) then
    raise exception using
      errcode = '55000',
      message = 'MIGRATION_029_LEGACY_SNAPSHOT_STORAGE_MISMATCH';
  end if;
end
$validate_legacy_snapshot_storage$;

do $capture_legacy_commercial_functions$
declare
  v_signature text;
  v_proc regprocedure;
  v_existing_count integer;
begin
  select count(*)
  into v_existing_count
  from public.branch_import_legacy_function_snapshots
  where function_signature = any(array[
    'public.commercial_update_document_items(text,jsonb)',
    'public.commercial_update_document_status(text,uuid,text)',
    'public.convert_quotation_to_order(uuid)'
  ]);

  if v_existing_count <> 0 then
    raise exception using
      errcode = '55000',
      message = 'MIGRATION_029_LEGACY_COMMERCIAL_SNAPSHOT_COLLISION';
  end if;

  foreach v_signature in array array[
    'public.commercial_update_document_items(text,jsonb)',
    'public.commercial_update_document_status(text,uuid,text)',
    'public.convert_quotation_to_order(uuid)'
  ]
  loop
    v_proc := to_regprocedure(v_signature);
    if v_proc is null then
      raise exception using
        errcode = '55000',
        message = 'MIGRATION_029_LEGACY_COMMERCIAL_FUNCTION_MISSING',
        detail = v_signature;
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
    where p.oid = v_proc;
  end loop;

  if (
    select count(*)
    from public.branch_import_legacy_function_snapshots
    where function_signature = any(array[
      'public.commercial_update_document_items(text,jsonb)',
      'public.commercial_update_document_status(text,uuid,text)',
      'public.convert_quotation_to_order(uuid)'
    ])
  ) <> 3 then
    raise exception using
      errcode = '55000',
      message = 'MIGRATION_029_LEGACY_COMMERCIAL_SNAPSHOT_INCOMPLETE';
  end if;

  if exists (
    select 1
    from public.branch_import_legacy_function_snapshots snapshot
    left join pg_proc p
      on p.oid = to_regprocedure(snapshot.function_signature)
    left join pg_roles owner_role on owner_role.oid = p.proowner
    where snapshot.function_signature = any(array[
      'public.commercial_update_document_items(text,jsonb)',
      'public.commercial_update_document_status(text,uuid,text)',
      'public.convert_quotation_to_order(uuid)'
    ])
      and (
        snapshot.function_name is distinct from p.proname
        or snapshot.definition_md5 is distinct from
          md5(snapshot.function_definition)
        or snapshot.owner_name is distinct from owner_role.rolname
        or snapshot.acl_state is distinct from
          coalesce(p.proacl::text, '<NULL>')
        or snapshot.config_state is distinct from
          coalesce(p.proconfig::text, '<NULL>')
        or snapshot.definition_md5 is distinct from
          md5(pg_get_functiondef(p.oid))
      )
  ) then
    raise exception using
      errcode = '55000',
      message = 'MIGRATION_029_LEGACY_COMMERCIAL_SNAPSHOT_DIVERGED';
  end if;

  if exists (
    with expected(
      function_signature,
      definition_md5,
      owner_name,
      acl_state,
      config_state
    ) as (
      values
        (
          'public.commercial_update_document_items(text,jsonb)',
          '19dd936a5fc11427034c0084ef392adb',
          'postgres'::name,
          '{postgres=X/postgres}',
          '{search_path=public}'
        ),
        (
          'public.commercial_update_document_status(text,uuid,text)',
          'e3cac88842bb5e81a6c33a6e23429c22',
          'postgres'::name,
          '{postgres=X/postgres}',
          '{search_path=public}'
        ),
        (
          'public.convert_quotation_to_order(uuid)',
          '0c40587afdb78135d3ec085384b7ed76',
          'postgres'::name,
          '{postgres=X/postgres,authenticated=X/postgres}',
          '{search_path=public}'
        )
    )
    select 1
    from expected
    left join public.branch_import_legacy_function_snapshots snapshot
      using (function_signature)
    where snapshot.function_signature is null
       or snapshot.definition_md5 is distinct from expected.definition_md5
       or snapshot.owner_name is distinct from expected.owner_name
       or snapshot.acl_state is distinct from expected.acl_state
       or snapshot.config_state is distinct from expected.config_state
  ) then
    raise exception using
      errcode = '55000',
      message = 'MIGRATION_029_LEGACY_COMMERCIAL_BASELINE_MISMATCH';
  end if;
end
$capture_legacy_commercial_functions$;

create or replace function public.commercial_update_document_items(
  document_type text,
  payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  owner_id uuid;
  current_status text;
  region_value public.order_region;
  item_data jsonb;
  product_row public.products;
  target_id uuid;
  idx integer := 0;
  qty numeric;
  discount numeric;
  unit_price numeric;
  final_unit numeric;
  subtotal_value numeric := 0;
  total_value numeric := 0;
  max_discount numeric := public.max_discount_percent();
begin
  actor := public.commercial_active_profile();
  if actor.id is null then raise exception 'SEM_PERMISSAO'; end if;
  if document_type = 'pedido' and not (actor.perfil = 'ADMIN' or public.has_module('pedidos')) then raise exception 'SEM_PERMISSAO'; end if;
  if document_type = 'cotacao' and not (actor.perfil = 'ADMIN' or public.has_module('cotacoes')) then raise exception 'SEM_PERMISSAO'; end if;
  target_id := (payload->>'id')::uuid;
  if jsonb_typeof(payload->'items') <> 'array' or jsonb_array_length(payload->'items') = 0 then raise exception 'ITENS_OBRIGATORIOS'; end if;

  perform pg_advisory_xact_lock(29, 0);

  if document_type = 'pedido' then
    select user_id, status::text, regiao into owner_id, current_status, region_value from public.orders where id = target_id for update;
    if current_status not in ('NOVO', 'EM_ANALISE') then raise exception 'PEDIDO_NAO_EDITAVEL'; end if;
  elsif document_type = 'cotacao' then
    select user_id, status::text, regiao into owner_id, current_status, region_value from public.quotations where id = target_id for update;
    if current_status not in ('NOVA', 'ENVIADA') then raise exception 'COTACAO_NAO_EDITAVEL'; end if;
  else raise exception 'TIPO_DOCUMENTO_INVALIDO';
  end if;
  if owner_id is null then raise exception 'DOCUMENTO_NAO_ENCONTRADO'; end if;
  if actor.perfil <> 'ADMIN' and owner_id <> actor.id then raise exception 'SEM_PERMISSAO'; end if;

  if document_type = 'pedido' then delete from public.order_items where order_id = target_id;
  else delete from public.quotation_items where quotation_id = target_id; end if;

  for item_data in select value from jsonb_array_elements(payload->'items') loop
    idx := idx + 1;
    select * into product_row from public.products where codigo = btrim(item_data->>'codigo');
    if product_row.codigo is null then raise exception 'PRODUTO_NAO_ENCONTRADO: item %', idx; end if;
    qty := coalesce(nullif(item_data->>'quantidade', '')::numeric, 0);
    discount := coalesce(nullif(item_data->>'desconto_percentual', '')::numeric, 0);
    if qty <= 0 then raise exception 'QUANTIDADE_INVALIDA: item %', idx; end if;
    if discount < 0 or discount > max_discount then raise exception 'DESCONTO_INVALIDO: item %', idx; end if;
    unit_price := case when region_value = 'PR' then product_row.preco_pr else product_row.preco_sp end;
    if unit_price is null or unit_price < 0 then raise exception 'PRECO_INVALIDO: item %', idx; end if;
    final_unit := round(unit_price * (1 - discount / 100), 4);
    subtotal_value := subtotal_value + unit_price * qty;
    total_value := total_value + final_unit * qty;
    if document_type = 'pedido' then
      insert into public.order_items (order_id, item, codigo, descricao, marca, aplicacao, quantidade, preco_unitario, desconto_percentual, preco_final_unitario, total_item)
      values (target_id, idx, product_row.codigo, product_row.descricao, product_row.marca, product_row.aplicacao, qty, unit_price, discount, final_unit, round(final_unit * qty, 2));
    else
      insert into public.quotation_items (quotation_id, item, codigo, descricao, marca, aplicacao, quantidade, preco_unitario, desconto_percentual, preco_final_unitario, total_item)
      values (target_id, idx, product_row.codigo, product_row.descricao, product_row.marca, product_row.aplicacao, qty, unit_price, discount, final_unit, round(final_unit * qty, 2));
    end if;
  end loop;

  if document_type = 'pedido' then
    update public.orders set subtotal = round(subtotal_value, 2), desconto_total = round(subtotal_value - total_value, 2), total = round(total_value, 2) where id = target_id;
  else
    update public.quotations set subtotal = round(subtotal_value, 2), desconto_total = round(subtotal_value - total_value, 2), total = round(total_value, 2) where id = target_id;
  end if;
  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (actor.id, actor.usuario, 'ATUALIZAR_ITENS', case when document_type = 'pedido' then 'orders' else 'quotations' end,
          target_id::text, jsonb_build_object('itens', idx, 'total', round(total_value, 2)));
  return jsonb_build_object('id', target_id, 'subtotal', round(subtotal_value, 2), 'desconto_total', round(subtotal_value - total_value, 2), 'total', round(total_value, 2));
end;
$$;

create or replace function public.commercial_update_document_status(
  document_type text,
  target_id uuid,
  target_status text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare actor public.profiles; owner_id uuid; old_status text;
begin
  actor := public.commercial_active_profile();
  if actor.id is null then raise exception 'SEM_PERMISSAO'; end if;
  if document_type = 'pedido' and not (actor.perfil = 'ADMIN' or public.has_module('pedidos')) then raise exception 'SEM_PERMISSAO'; end if;
  if document_type = 'cotacao' and not (actor.perfil = 'ADMIN' or public.has_module('cotacoes')) then raise exception 'SEM_PERMISSAO'; end if;
  if document_type = 'pedido' then
    select user_id, status::text into owner_id, old_status from public.orders where id = target_id for update;
    if owner_id is null then raise exception 'DOCUMENTO_NAO_ENCONTRADO'; end if;
    if actor.perfil <> 'ADMIN' and owner_id <> actor.id then raise exception 'SEM_PERMISSAO'; end if;
    if not ((old_status = 'NOVO' and target_status in ('EM_ANALISE','APROVADO','CANCELADO')) or
            (old_status = 'EM_ANALISE' and target_status in ('APROVADO','CANCELADO')) or
            (old_status = 'APROVADO' and target_status in ('FATURADO','CANCELADO')) or old_status = target_status)
    then raise exception 'TRANSICAO_STATUS_INVALIDA'; end if;
    update public.orders set status = target_status::public.order_status where id = target_id;
  elsif document_type = 'cotacao' then
    select user_id, status::text into owner_id, old_status from public.quotations where id = target_id for update;
    if owner_id is null then raise exception 'DOCUMENTO_NAO_ENCONTRADO'; end if;
    if actor.perfil <> 'ADMIN' and owner_id <> actor.id then raise exception 'SEM_PERMISSAO'; end if;
    if not ((old_status = 'NOVA' and target_status in ('ENVIADA','APROVADA','CANCELADA')) or
            (old_status = 'ENVIADA' and target_status in ('APROVADA','CANCELADA')) or old_status = target_status)
    then raise exception 'TRANSICAO_STATUS_INVALIDA'; end if;
    update public.quotations set status = target_status::public.quotation_status where id = target_id;
  else raise exception 'TIPO_DOCUMENTO_INVALIDO'; end if;
  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (actor.id, actor.usuario, 'ATUALIZAR_STATUS', case when document_type = 'pedido' then 'orders' else 'quotations' end,
          target_id::text, jsonb_build_object('anterior', old_status, 'novo', target_status));
  return jsonb_build_object('id', target_id, 'status', target_status);
end;
$$;

create or replace function public.convert_quotation_to_order(
  target_quotation_id uuid
)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare actor public.profiles; source public.quotations; new_order_id uuid; new_number text; existing public.quotation_order_conversions; item_count integer;
begin
  actor := public.commercial_active_profile();
  if actor.id is null or not public.has_module('novo_pedido') or not public.has_module('cotacoes') then raise exception 'SEM_PERMISSAO'; end if;
  perform pg_advisory_xact_lock(29, 0);
  select * into source from public.quotations where id=target_quotation_id for update;
  if source.id is null then raise exception 'COTACAO_NAO_ENCONTRADA'; end if;
  if actor.perfil <> 'ADMIN' and source.user_id <> actor.id then raise exception 'SEM_PERMISSAO'; end if;
  select * into existing from public.quotation_order_conversions where quotation_id=source.id;
  if existing.quotation_id is not null then
    return (select jsonb_build_object('id_pedido',o.id,'numero_pedido',o.numero_pedido,'numero_cotacao',source.numero_cotacao,'already_converted',true) from public.orders o where o.id=existing.order_id);
  end if;
  if source.status <> 'APROVADA' then raise exception 'COTACAO_NAO_APROVADA'; end if;
  select count(*) into item_count from public.quotation_items where quotation_id=source.id;
  if item_count=0 then raise exception 'COTACAO_SEM_ITENS'; end if;
  new_number := lpad(nextval('public.order_commercial_number_seq')::text,6,'0');
  insert into public.orders(numero_pedido,regiao,user_id,vendedor,codigo_sap_cliente,cliente,cnpj,telefone,endereco,prazo,transportadora,transportadora_cnpj,transportadora_endereco,observacao,subtotal,desconto_total,total,status)
  values(new_number,source.regiao,source.user_id,source.vendedor,source.codigo_sap_cliente,source.cliente,source.cnpj,source.telefone,source.endereco,source.prazo,source.transportadora,source.transportadora_cnpj,source.transportadora_endereco,nullif(concat_ws(E'\n',source.observacao,'Convertido da cotacao '||source.numero_cotacao),''),source.subtotal,source.desconto_total,source.total,'NOVO') returning id into new_order_id;
  insert into public.order_items(order_id,item,codigo,descricao,marca,aplicacao,quantidade,preco_unitario,desconto_percentual,preco_final_unitario,total_item)
  select new_order_id,item,codigo,descricao,marca,aplicacao,quantidade,preco_unitario,desconto_percentual,preco_final_unitario,total_item from public.quotation_items where quotation_id=source.id order by item;
  insert into public.quotation_order_conversions(quotation_id,order_id,converted_by) values(source.id,new_order_id,actor.id);
  update public.quotations set status='CONVERTIDA' where id=source.id;
  insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_novos) values(actor.id,actor.usuario,'CONVERTER_COTACAO_PEDIDO','orders',new_order_id::text,jsonb_build_object('quotation_id',source.id,'numero_cotacao',source.numero_cotacao));
  return jsonb_build_object('id_pedido',new_order_id,'numero_pedido',new_number,'numero_cotacao',source.numero_cotacao,'already_converted',false);
end;
$$;

create or replace function public.enforce_branch_order_contract()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_branch_id uuid;
  v_branch_count integer;
  v_v1_enabled boolean;
  v_invalid_items boolean;
begin
  if new.stock_contract_version = 1 then
    select s.order_stock_contract_v1_enabled
    into v_v1_enabled
    from public.order_stock_contract_settings s
    where s.singleton;

    if not coalesce(v_v1_enabled, false) then
      raise exception using
        errcode = '0A000',
        message = 'ORDER_STOCK_CONTRACT_V1_DISABLED',
        schema = tg_table_schema,
        table = tg_table_name;
    end if;
  end if;

  if new.branch_id is not null
     and not exists (
       select 1
       from public.branches b
       where b.id = new.branch_id
         and b.active
     ) then
    raise exception using
      errcode = '23514',
      message = 'ORDER_STOCK_CONTRACT_BRANCH_INACTIVE',
      schema = tg_table_schema,
      table = tg_table_name;
  end if;

  if new.stock_contract_version = 0 and new.regiao is not null then
    select count(*), min(b.id::text)::uuid
    into v_branch_count, v_branch_id
    from public.branches b
    where b.code = new.regiao::text
      and b.active;

    if v_branch_count <> 1 then
      raise exception using
        errcode = '23514',
        message = 'ORDER_STOCK_CONTRACT_REGION_NOT_MAPPABLE',
        schema = tg_table_schema,
        table = tg_table_name,
        detail = left(new.regiao::text, 20);
    end if;

    if new.branch_id is null then
      new.branch_id := v_branch_id;
    elsif new.branch_id <> v_branch_id then
      raise exception using
        errcode = '23514',
        message = 'ORDER_STOCK_CONTRACT_V0_BRANCH_REGION_MISMATCH',
        schema = tg_table_schema,
        table = tg_table_name;
    end if;
  end if;

  if tg_op = 'UPDATE'
     and old.stock_contract_version is distinct from new.stock_contract_version then
    if tg_table_name = 'orders' then
      select exists (
        select 1
        from public.order_items i
        where i.order_id = new.id
          and (
            (new.stock_contract_version = 0 and i.branch_price is not null)
            or
            (
              new.stock_contract_version = 1
              and (
                i.branch_price is null
                or i.branch_price_currency is null
                or i.branch_price_version is null
                or i.branch_price_captured_at is null
              )
            )
          )
      )
      into v_invalid_items;
    else
      select exists (
        select 1
        from public.quotation_items i
        where i.quotation_id = new.id
          and (
            (new.stock_contract_version = 0 and i.branch_price is not null)
            or
            (
              new.stock_contract_version = 1
              and (
                i.branch_price is null
                or i.branch_price_currency is null
                or i.branch_price_version is null
                or i.branch_price_captured_at is null
              )
            )
          )
      )
      into v_invalid_items;
    end if;

    if v_invalid_items then
      raise exception using
        errcode = '23514',
        message = 'ORDER_STOCK_CONTRACT_ITEM_SNAPSHOT_MISMATCH',
        schema = tg_table_schema,
        table = tg_table_name;
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.enforce_branch_price_snapshot_parent()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_contract_version smallint;
  v_snapshot_present boolean;
  v_old_snapshot_present boolean := false;
  v_snapshot_complete boolean;
  v_parent_ids uuid[];
  v_parent_id uuid;
begin
  v_snapshot_present :=
    new.branch_price is not null
    or new.branch_price_currency is not null
    or new.branch_price_version is not null
    or new.branch_price_captured_at is not null;

  if tg_op = 'UPDATE' then
    v_old_snapshot_present :=
      old.branch_price is not null
      or old.branch_price_currency is not null
      or old.branch_price_version is not null
      or old.branch_price_captured_at is not null;
  end if;

  if v_snapshot_present or v_old_snapshot_present then
    perform pg_advisory_xact_lock(29, 0);
  end if;

  if tg_table_name = 'order_items' then
    if tg_op = 'UPDATE' and old.order_id is distinct from new.order_id then
      select array_agg(parent_id order by parent_id)
      into v_parent_ids
      from (
        select distinct parent_id
        from unnest(array[old.order_id, new.order_id]) parent(parent_id)
        where parent_id is not null
      ) parents;
    else
      v_parent_ids := array[new.order_id];
    end if;
  else
    if tg_op = 'UPDATE'
       and old.quotation_id is distinct from new.quotation_id then
      select array_agg(parent_id order by parent_id)
      into v_parent_ids
      from (
        select distinct parent_id
        from unnest(
          array[old.quotation_id, new.quotation_id]
        ) parent(parent_id)
        where parent_id is not null
      ) parents;
    else
      v_parent_ids := array[new.quotation_id];
    end if;
  end if;

  foreach v_parent_id in array v_parent_ids
  loop
    if tg_table_name = 'order_items' then
      perform 1
      from public.orders o
      where o.id = v_parent_id
      for no key update;
    else
      perform 1
      from public.quotations q
      where q.id = v_parent_id
      for no key update;
    end if;

    if not found then
      raise exception using
        errcode = '23503',
        message = 'BRANCH_PRICE_SNAPSHOT_PARENT_NOT_FOUND',
        schema = tg_table_schema,
        table = tg_table_name;
    end if;
  end loop;

  v_snapshot_complete :=
    new.branch_price is not null
    and new.branch_price_currency is not null
    and new.branch_price_version is not null
    and new.branch_price_captured_at is not null;

  if tg_table_name = 'order_items' then
    select o.stock_contract_version
    into strict v_contract_version
    from public.orders o
    where o.id = new.order_id;
  else
    select q.stock_contract_version
    into strict v_contract_version
    from public.quotations q
    where q.id = new.quotation_id;
  end if;

  if v_contract_version = 0 and v_snapshot_present then
    raise exception using
      errcode = '23514',
      message = 'BRANCH_PRICE_SNAPSHOT_REQUIRES_V1',
      schema = tg_table_schema,
      table = tg_table_name;
  end if;

  if v_contract_version = 1 and not v_snapshot_complete then
    raise exception using
      errcode = '23514',
      message = 'BRANCH_PRICE_SNAPSHOT_REQUIRED_FOR_V1',
      schema = tg_table_schema,
      table = tg_table_name;
  end if;

  return new;
end;
$$;

drop trigger if exists orders_serialize_branch_contract_029 on public.orders;
create trigger orders_serialize_branch_contract_029
before update of stock_contract_version
on public.orders
for each statement
execute function public.serialize_branch_order_contract_statement();

drop trigger if exists quotations_serialize_branch_contract_029
  on public.quotations;
create trigger quotations_serialize_branch_contract_029
before update of stock_contract_version
on public.quotations
for each statement
execute function public.serialize_branch_order_contract_statement();

drop trigger if exists order_items_serialize_branch_snapshot_insert_029
  on public.order_items;
create trigger order_items_serialize_branch_snapshot_insert_029
before insert
on public.order_items
for each statement
execute function public.serialize_branch_order_contract_statement();

drop trigger if exists order_items_serialize_branch_snapshot_update_029
  on public.order_items;
create trigger order_items_serialize_branch_snapshot_update_029
before update of order_id, branch_price, branch_price_currency,
  branch_price_version, branch_price_captured_at
on public.order_items
for each statement
execute function public.serialize_branch_order_contract_statement();

drop trigger if exists order_items_serialize_branch_snapshot_write_029
  on public.order_items;

drop trigger if exists quotation_items_serialize_branch_snapshot_insert_029
  on public.quotation_items;
create trigger quotation_items_serialize_branch_snapshot_insert_029
before insert
on public.quotation_items
for each statement
execute function public.serialize_branch_order_contract_statement();

drop trigger if exists quotation_items_serialize_branch_snapshot_update_029
  on public.quotation_items;
create trigger quotation_items_serialize_branch_snapshot_update_029
before update of quotation_id, branch_price, branch_price_currency,
  branch_price_version, branch_price_captured_at
on public.quotation_items
for each statement
execute function public.serialize_branch_order_contract_statement();

drop trigger if exists quotation_items_serialize_branch_snapshot_write_029
  on public.quotation_items;

drop trigger if exists orders_enforce_branch_contract_029 on public.orders;
create trigger orders_enforce_branch_contract_029
before insert or update of branch_id, regiao, stock_contract_version
on public.orders
for each row execute function public.enforce_branch_order_contract();

drop trigger if exists quotations_enforce_branch_contract_029 on public.quotations;
create trigger quotations_enforce_branch_contract_029
before insert or update of branch_id, regiao, stock_contract_version
on public.quotations
for each row execute function public.enforce_branch_order_contract();

drop trigger if exists order_items_enforce_branch_snapshot_029 on public.order_items;
create trigger order_items_enforce_branch_snapshot_029
before insert or update of order_id, branch_price, branch_price_currency,
  branch_price_version, branch_price_captured_at
on public.order_items
for each row execute function public.enforce_branch_price_snapshot_parent();

drop trigger if exists quotation_items_enforce_branch_snapshot_029
  on public.quotation_items;
create trigger quotation_items_enforce_branch_snapshot_029
before insert or update of quotation_id, branch_price, branch_price_currency,
  branch_price_version, branch_price_captured_at
on public.quotation_items
for each row execute function public.enforce_branch_price_snapshot_parent();

alter table public.order_stock_contract_settings enable row level security;

drop policy if exists order_stock_contract_settings_admin_read_029
  on public.order_stock_contract_settings;
create policy order_stock_contract_settings_admin_read_029
on public.order_stock_contract_settings
for select to authenticated
using (public.is_admin());

do $verify_policy_snapshot_names$
begin
  if exists (
    select 1
    from pg_policy p
    where p.polname like 'migration_029_expected_%'
      and p.polrelid = any(array[
        'public.orders'::regclass,
        'public.order_items'::regclass,
        'public.quotations'::regclass,
        'public.quotation_items'::regclass
      ])
  ) then
    raise exception using
      errcode = '55000',
      message = 'MIGRATION_029_POLICY_FINGERPRINT_NAMESPACE_COLLISION';
  end if;
end
$verify_policy_snapshot_names$;

create policy migration_029_expected_orders_read on public.orders
for select to authenticated
using (public.is_admin() or user_id = auth.uid());

create policy migration_029_expected_order_items_read on public.order_items
for select to authenticated
using (
  exists (
    select 1
    from public.orders o
    where o.id = order_id
      and (public.is_admin() or o.user_id = auth.uid())
  )
);

create policy migration_029_expected_quotations_read on public.quotations
for select to authenticated
using (public.is_admin() or user_id = auth.uid());

create policy migration_029_expected_quotation_items_read
on public.quotation_items
for select to authenticated
using (
  exists (
    select 1
    from public.quotations q
    where q.id = quotation_id
      and (public.is_admin() or q.user_id = auth.uid())
  )
);

create policy migration_029_expected_orders_create on public.orders
for insert
with check (
  public.has_module('novo_pedido')
  and user_id = auth.uid()
);

create policy migration_029_expected_orders_scoped_update on public.orders
for update to authenticated
using (public.is_admin() or user_id = auth.uid())
with check (public.is_admin() or user_id = auth.uid());

create policy migration_029_expected_order_items_create on public.order_items
for insert
with check (
  exists (
    select 1
    from public.orders o
    where o.id = order_id
      and o.user_id = auth.uid()
  )
);

create policy migration_029_expected_quotations_create on public.quotations
for insert
with check (
  public.has_module('nova_cotacao')
  and user_id = auth.uid()
);

create policy migration_029_expected_quotations_scoped_update
on public.quotations
for update to authenticated
using (public.is_admin() or user_id = auth.uid())
with check (public.is_admin() or user_id = auth.uid());

create policy migration_029_expected_quotation_items_create
on public.quotation_items
for insert
with check (
  exists (
    select 1
    from public.quotations q
    where q.id = quotation_id
      and q.user_id = auth.uid()
  )
);

do $validate_legacy_commercial_policies$
begin
  if exists (
    with policy_pairs(table_oid, current_name, expected_name) as (
      values
        (
          'public.orders'::regclass,
          'orders_read',
          'migration_029_expected_orders_read'
        ),
        (
          'public.order_items'::regclass,
          'order_items_read',
          'migration_029_expected_order_items_read'
        ),
        (
          'public.quotations'::regclass,
          'quotations_read',
          'migration_029_expected_quotations_read'
        ),
        (
          'public.quotation_items'::regclass,
          'quotation_items_read',
          'migration_029_expected_quotation_items_read'
        ),
        (
          'public.orders'::regclass,
          'orders_create',
          'migration_029_expected_orders_create'
        ),
        (
          'public.orders'::regclass,
          'orders_scoped_update',
          'migration_029_expected_orders_scoped_update'
        ),
        (
          'public.order_items'::regclass,
          'order_items_create',
          'migration_029_expected_order_items_create'
        ),
        (
          'public.quotations'::regclass,
          'quotations_create',
          'migration_029_expected_quotations_create'
        ),
        (
          'public.quotations'::regclass,
          'quotations_scoped_update',
          'migration_029_expected_quotations_scoped_update'
        ),
        (
          'public.quotation_items'::regclass,
          'quotation_items_create',
          'migration_029_expected_quotation_items_create'
        )
    )
    select 1
    from policy_pairs pair
    left join pg_policy current_policy
      on current_policy.polrelid = pair.table_oid
     and current_policy.polname = pair.current_name
    left join pg_policy expected_policy
      on expected_policy.polrelid = pair.table_oid
     and expected_policy.polname = pair.expected_name
    where current_policy.oid is null
       or expected_policy.oid is null
       or current_policy.polpermissive is distinct from
          expected_policy.polpermissive
       or current_policy.polroles is distinct from expected_policy.polroles
       or current_policy.polcmd is distinct from expected_policy.polcmd
       or pg_get_expr(
            current_policy.polqual,
            current_policy.polrelid
          ) is distinct from pg_get_expr(
            expected_policy.polqual,
            expected_policy.polrelid
          )
       or pg_get_expr(
            current_policy.polwithcheck,
            current_policy.polrelid
          ) is distinct from pg_get_expr(
            expected_policy.polwithcheck,
            expected_policy.polrelid
          )
  ) then
    raise exception using
      errcode = '55000',
      message = 'MIGRATION_029_LEGACY_POLICY_FINGERPRINT_MISMATCH';
  end if;
end
$validate_legacy_commercial_policies$;

drop policy migration_029_expected_orders_read on public.orders;
drop policy migration_029_expected_order_items_read on public.order_items;
drop policy migration_029_expected_quotations_read on public.quotations;
drop policy migration_029_expected_quotation_items_read
  on public.quotation_items;
drop policy migration_029_expected_orders_create on public.orders;
drop policy migration_029_expected_orders_scoped_update on public.orders;
drop policy migration_029_expected_order_items_create on public.order_items;
drop policy migration_029_expected_quotations_create on public.quotations;
drop policy migration_029_expected_quotations_scoped_update
  on public.quotations;
drop policy migration_029_expected_quotation_items_create
  on public.quotation_items;

drop policy if exists orders_read on public.orders;
create policy orders_read on public.orders
for select to authenticated
using (
  (
    stock_contract_version = 0
    and (public.is_admin() or user_id = auth.uid())
  )
  or
  (
    stock_contract_version = 1
    and (
      public.is_admin()
      or (
        public.is_active_branch_order_profile()
        and
        public.can_access_branch(branch_id)
        and (
          user_id = auth.uid()
          or public.is_branch_order_supervisor()
        )
      )
    )
  )
);

drop policy if exists order_items_read on public.order_items;
create policy order_items_read on public.order_items
for select to authenticated
using (
  exists (
    select 1
    from public.orders o
    where o.id = order_id
      and (
        (
          o.stock_contract_version = 0
          and (public.is_admin() or o.user_id = auth.uid())
        )
        or
        (
          o.stock_contract_version = 1
          and (
            public.is_admin()
            or (
              public.is_active_branch_order_profile()
              and
              public.can_access_branch(o.branch_id)
              and (
                o.user_id = auth.uid()
                or public.is_branch_order_supervisor()
              )
            )
          )
        )
      )
  )
);

drop policy if exists quotations_read on public.quotations;
create policy quotations_read on public.quotations
for select to authenticated
using (
  (
    stock_contract_version = 0
    and (public.is_admin() or user_id = auth.uid())
  )
  or
  (
    stock_contract_version = 1
    and (
      public.is_admin()
      or (
        public.is_active_branch_order_profile()
        and
        public.can_access_branch(branch_id)
        and (
          user_id = auth.uid()
          or public.is_branch_order_supervisor()
        )
      )
    )
  )
);

drop policy if exists quotation_items_read on public.quotation_items;
create policy quotation_items_read on public.quotation_items
for select to authenticated
using (
  exists (
    select 1
    from public.quotations q
    where q.id = quotation_id
      and (
        (
          q.stock_contract_version = 0
          and (public.is_admin() or q.user_id = auth.uid())
        )
        or
        (
          q.stock_contract_version = 1
          and (
            public.is_admin()
            or (
              public.is_active_branch_order_profile()
              and
              public.can_access_branch(q.branch_id)
              and (
                q.user_id = auth.uid()
                or public.is_branch_order_supervisor()
              )
            )
          )
        )
      )
  )
);

revoke all on public.order_stock_contract_settings
  from public, anon, authenticated;
grant select on public.order_stock_contract_settings to authenticated;

revoke all on function public.enforce_branch_order_contract(),
  public.enforce_branch_price_snapshot_parent(),
  public.serialize_branch_order_contract_statement(),
  public.is_active_branch_order_profile(),
  public.is_branch_order_supervisor()
  from public, anon, authenticated;
grant execute on function public.is_active_branch_order_profile(),
  public.is_branch_order_supervisor()
  to authenticated;

select pg_temp.assert_migration_029_structure(true);

do $$
begin
  if exists (
    select 1
    from public.orders
    where stock_contract_version <> 0
       or logistics_status <> 'LEGACY_UNMANAGED'
  ) then
    raise exception 'MIGRATION_029_BACKFILL_ORDER_CONTRACT_INVALID';
  end if;

  if exists (
    select 1
    from public.quotations
    where stock_contract_version <> 0
  ) then
    raise exception 'MIGRATION_029_BACKFILL_QUOTATION_CONTRACT_INVALID';
  end if;

  if exists (
    select 1
    from public.orders o
    join public.branches b on b.code = o.regiao::text and b.active
    where o.regiao is not null
      and o.branch_id is distinct from b.id
  ) or exists (
    select 1
    from public.quotations q
    join public.branches b on b.code = q.regiao::text and b.active
    where q.regiao is not null
      and q.branch_id is distinct from b.id
  ) then
    raise exception 'MIGRATION_029_BACKFILL_BRANCH_INVALID';
  end if;

  if (
    select count(*)
    from public.order_stock_contract_settings
  ) <> 1 or not exists (
    select 1
    from public.order_stock_contract_settings
    where singleton
      and not order_stock_contract_v1_enabled
  ) then
    raise exception 'MIGRATION_029_V1_FLAG_VALIDATION_FAILED';
  end if;
end;
$$;

commit;
