begin;

set local lock_timeout = '10s';
set local statement_timeout = '110s';

create table if not exists public.customer_portal_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete restrict,
  email text not null,
  contact_name text,
  active boolean not null default true,
  can_create_quotations boolean not null default true,
  can_create_orders boolean not null default true,
  can_view_stock boolean not null default true,
  can_view_prices boolean not null default true,
  owner_profile_id uuid references public.profiles(id) on delete set null,
  invited_by uuid references public.profiles(id) on delete set null,
  invited_at timestamptz not null default now(),
  last_login_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint customer_portal_accounts_email_check
    check (email = lower(btrim(email)) and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')
);

create unique index if not exists customer_portal_accounts_email_uidx
  on public.customer_portal_accounts (lower(email));
create index if not exists customer_portal_accounts_client_active_idx
  on public.customer_portal_accounts (client_id, active, created_at desc);

create table if not exists public.customer_portal_change_requests (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete restrict,
  requested_by uuid not null references auth.users(id) on delete restrict,
  requested_data jsonb not null,
  status text not null default 'PENDING',
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  review_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint customer_portal_change_requests_status_check
    check (status in ('PENDING','APPROVED','REJECTED','CANCELLED')),
  constraint customer_portal_change_requests_payload_check
    check (jsonb_typeof(requested_data) = 'object' and requested_data <> '{}'::jsonb)
);

create index if not exists customer_portal_change_requests_client_status_idx
  on public.customer_portal_change_requests (client_id, status, created_at desc);

alter table public.orders
  add column if not exists client_id uuid references public.clients(id) on delete restrict,
  add column if not exists portal_account_user_id uuid references auth.users(id) on delete set null,
  add column if not exists source_channel text not null default 'INTERNAL',
  add column if not exists portal_idempotency_key text;

alter table public.quotations
  add column if not exists client_id uuid references public.clients(id) on delete restrict,
  add column if not exists portal_account_user_id uuid references auth.users(id) on delete set null,
  add column if not exists source_channel text not null default 'INTERNAL',
  add column if not exists portal_idempotency_key text;

alter table public.stock_transfer_requests
  add column if not exists requested_by_portal_user uuid references auth.users(id) on delete set null;

alter table public.orders drop constraint if exists orders_source_channel_check;
alter table public.orders add constraint orders_source_channel_check
  check (source_channel in ('INTERNAL','B2B_PORTAL','IMPORT'));
alter table public.quotations drop constraint if exists quotations_source_channel_check;
alter table public.quotations add constraint quotations_source_channel_check
  check (source_channel in ('INTERNAL','B2B_PORTAL','IMPORT'));

create unique index if not exists orders_portal_idempotency_uidx
  on public.orders (portal_account_user_id, portal_idempotency_key)
  where portal_idempotency_key is not null;
create unique index if not exists quotations_portal_idempotency_uidx
  on public.quotations (portal_account_user_id, portal_idempotency_key)
  where portal_idempotency_key is not null;
create index if not exists orders_b2b_client_created_idx
  on public.orders (client_id, created_at desc) where source_channel = 'B2B_PORTAL';
create index if not exists quotations_b2b_client_created_idx
  on public.quotations (client_id, created_at desc) where source_channel = 'B2B_PORTAL';

update public.orders o
set client_id = public.resolve_commercial_client(o.codigo_sap_cliente,o.cnpj)
where o.client_id is null
  and (nullif(btrim(o.codigo_sap_cliente),'') is not null
       or nullif(regexp_replace(coalesce(o.cnpj,''),'\D','','g'),'') is not null);

update public.quotations q
set client_id = public.resolve_commercial_client(q.codigo_sap_cliente,q.cnpj)
where q.client_id is null
  and (nullif(btrim(q.codigo_sap_cliente),'') is not null
       or nullif(regexp_replace(coalesce(q.cnpj,''),'\D','','g'),'') is not null);

create or replace function public.is_internal_user()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.ativo
  )
$$;

create or replace function public.is_active_b2b_client(target_client_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.customer_portal_accounts a
    join public.clients c on c.id = a.client_id and c.ativo
    where a.user_id = auth.uid()
      and a.active
      and a.client_id = target_client_id
  )
$$;

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
  select a.* into account_row
  from public.customer_portal_accounts a
  where a.user_id = auth.uid() and a.active;
  if account_row.user_id is null then raise exception 'ACESSO_B2B_NAO_AUTORIZADO'; end if;

  select c.* into client_row from public.clients c
  where c.id = account_row.client_id and c.ativo;
  if client_row.id is null then raise exception 'CLIENTE_B2B_INATIVO'; end if;

  destination_state := upper(btrim(coalesce(client_row.estado,'')));
  origin_branch := case destination_state when 'SP' then 'SP' when 'PR' then 'PR' when 'SC' then 'PR' else null end;

  update public.customer_portal_accounts
  set last_login_at = now(), updated_at = now()
  where user_id = account_row.user_id
    and (last_login_at is null or last_login_at < now() - interval '15 minutes');

  return jsonb_build_object(
    'account',jsonb_build_object(
      'user_id',account_row.user_id,
      'email',account_row.email,
      'contact_name',account_row.contact_name,
      'can_create_quotations',account_row.can_create_quotations,
      'can_create_orders',account_row.can_create_orders,
      'can_view_stock',account_row.can_view_stock,
      'can_view_prices',account_row.can_view_prices
    ),
    'client',jsonb_build_object(
      'id',client_row.id,
      'codigo_sap_cliente',client_row.codigo_sap_cliente,
      'nome',client_row.nome,
      'nome_fantasia',client_row.nome_fantasia,
      'cnpj',client_row.cnpj,
      'telefone',client_row.telefone,
      'email',client_row.email,
      'cidade',client_row.cidade,
      'estado',client_row.estado,
      'endereco',client_row.endereco
    ),
    'route',case when origin_branch is null then null else origin_branch||'-'||destination_state end,
    'origin_branch',origin_branch,
    'destination_state',nullif(destination_state,''),
    'route_supported',origin_branch is not null
  );
end;
$$;

create or replace function public.submit_b2b_profile_change(requested_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  account_row public.customer_portal_accounts;
  clean_data jsonb;
  request_id uuid;
begin
  select * into account_row from public.customer_portal_accounts
  where user_id = auth.uid() and active;
  if account_row.user_id is null then raise exception 'ACESSO_B2B_NAO_AUTORIZADO'; end if;
  if jsonb_typeof(requested_data) <> 'object' then raise exception 'ALTERACAO_INVALIDA'; end if;

  clean_data := jsonb_strip_nulls(jsonb_build_object(
    'telefone',nullif(btrim(requested_data->>'telefone'),''),
    'email',nullif(lower(btrim(requested_data->>'email')),''),
    'endereco',nullif(btrim(requested_data->>'endereco'),''),
    'cidade',nullif(btrim(requested_data->>'cidade'),''),
    'estado',nullif(upper(btrim(requested_data->>'estado')),'')
  ));
  if clean_data = '{}'::jsonb then raise exception 'ALTERACAO_VAZIA'; end if;
  if clean_data ? 'estado' and clean_data->>'estado' !~ '^[A-Z]{2}$' then raise exception 'UF_INVALIDA'; end if;
  if clean_data ? 'email' and clean_data->>'email' !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'EMAIL_INVALIDO'; end if;

  if exists (
    select 1 from public.customer_portal_change_requests
    where client_id = account_row.client_id and status = 'PENDING'
  ) then raise exception 'ALTERACAO_JA_PENDENTE'; end if;

  insert into public.customer_portal_change_requests(client_id,requested_by,requested_data)
  values(account_row.client_id,account_row.user_id,clean_data)
  returning id into request_id;

  return jsonb_build_object('id',request_id,'status','PENDING');
end;
$$;

alter table public.customer_portal_accounts enable row level security;
alter table public.customer_portal_change_requests enable row level security;

drop policy if exists customer_portal_accounts_own_read on public.customer_portal_accounts;
create policy customer_portal_accounts_own_read on public.customer_portal_accounts
for select to authenticated using (user_id = auth.uid() and active);

drop policy if exists customer_portal_change_requests_own_read on public.customer_portal_change_requests;
create policy customer_portal_change_requests_own_read on public.customer_portal_change_requests
for select to authenticated using (
  requested_by = auth.uid() and public.is_active_b2b_client(client_id)
);

-- B2B users share the authenticated database role with employees. Tighten old
-- broad policies so customers cannot enumerate internal reference tables.
drop policy if exists clients_read on public.clients;
create policy clients_read on public.clients for select to authenticated
using (public.is_internal_user());

drop policy if exists carriers_read on public.carriers;
create policy carriers_read on public.carriers for select to authenticated
using (public.is_internal_user());

drop policy if exists payment_terms_read on public.payment_terms;
create policy payment_terms_read on public.payment_terms for select to authenticated
using (public.is_internal_user());

drop policy if exists permissions_read on public.role_permissions;
create policy permissions_read on public.role_permissions for select to authenticated
using (public.is_internal_user());

drop policy if exists settings_read on public.settings;
create policy settings_read on public.settings for select to authenticated
using (public.is_internal_user());

drop policy if exists company_settings_read on public.company_settings;
create policy company_settings_read on public.company_settings for select to authenticated
using (public.is_internal_user());

drop policy if exists branches_authenticated_read on public.branches;
create policy branches_authenticated_read on public.branches for select to authenticated
using (public.is_internal_user());

drop policy if exists logs_insert on public.logs;
create policy logs_insert on public.logs for insert to authenticated
with check (public.is_internal_user() and user_id = auth.uid());

revoke all on public.customer_portal_accounts,public.customer_portal_change_requests
  from public,anon,authenticated;
grant select on public.customer_portal_accounts,public.customer_portal_change_requests
  to authenticated;

revoke all on function public.is_internal_user(),public.is_active_b2b_client(uuid),
  public.get_b2b_session(),public.submit_b2b_profile_change(jsonb)
  from public,anon,authenticated;
grant execute on function public.is_active_b2b_client(uuid),public.get_b2b_session(),
  public.submit_b2b_profile_change(jsonb),public.is_internal_user() to authenticated;

comment on table public.customer_portal_accounts is
  'Vínculo explícito entre auth.users e um único cadastro de cliente no Portal B2B.';
comment on function public.get_b2b_session() is
  'Retorna apenas campos cadastrais permitidos do próprio cliente e sua rota comercial.';

commit;
