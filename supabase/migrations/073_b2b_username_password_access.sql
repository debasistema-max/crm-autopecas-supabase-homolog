begin;

set local lock_timeout = '10s';
set local statement_timeout = '110s';

alter table public.customer_portal_accounts
  add column if not exists username text,
  add column if not exists login_mode text not null default 'EMAIL',
  add column if not exists must_change_password boolean not null default false,
  add column if not exists activation_pending boolean not null default false;

alter table public.customer_portal_accounts
  drop constraint if exists customer_portal_accounts_login_mode_check;
alter table public.customer_portal_accounts
  add constraint customer_portal_accounts_login_mode_check
    check (login_mode in ('EMAIL','USERNAME'));

alter table public.customer_portal_accounts
  drop constraint if exists customer_portal_accounts_username_check;
alter table public.customer_portal_accounts
  add constraint customer_portal_accounts_username_check check (
    (login_mode='EMAIL' and username is null)
    or
    (login_mode='USERNAME' and username is not null
      and username=lower(username)
      and username ~ '^[a-z0-9][a-z0-9._-]{2,48}[a-z0-9]$')
  );

alter table public.customer_portal_accounts
  drop constraint if exists customer_portal_accounts_activation_check;
alter table public.customer_portal_accounts
  add constraint customer_portal_accounts_activation_check
    check (not activation_pending or (must_change_password and not active));

create unique index if not exists customer_portal_accounts_username_uidx
  on public.customer_portal_accounts(lower(username)) where username is not null;

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
  where a.user_id = auth.uid() and (a.active or a.activation_pending);
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
      'email',case when account_row.login_mode='EMAIL' then account_row.email else null end,
      'username',account_row.username,
      'login_mode',account_row.login_mode,
      'must_change_password',account_row.must_change_password,
      'activation_pending',account_row.activation_pending,
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

create or replace function public.complete_b2b_password_change()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  account_row public.customer_portal_accounts;
  auth_password_updated_at timestamptz;
begin
  select * into account_row from public.customer_portal_accounts
  where user_id=auth.uid() and activation_pending and must_change_password for update;
  if account_row.user_id is null then raise exception 'ACESSO_B2B_NAO_AUTORIZADO'; end if;
  select u.updated_at into auth_password_updated_at from auth.users u where u.id=auth.uid();
  if auth_password_updated_at is null or auth_password_updated_at<=account_row.invited_at then
    raise exception 'TROCA_SENHA_B2B_NAO_CONFIRMADA';
  end if;
  update public.customer_portal_accounts
  set must_change_password=false,activation_pending=false,active=true,updated_at=now()
  where user_id=account_row.user_id;
  insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_novos)
  values(null,'B2B:'||coalesce(account_row.username,account_row.email),'ALTERAR_SENHA_B2B',
    'customer_portal_accounts',account_row.user_id::text,jsonb_build_object('login_mode',account_row.login_mode));
  return true;
end;
$$;

revoke all on function public.get_b2b_session(),public.complete_b2b_password_change()
  from public,anon,authenticated;
grant execute on function public.get_b2b_session(),public.complete_b2b_password_change()
  to authenticated;

comment on function public.complete_b2b_password_change() is
  'Conclui a troca obrigatória da senha inicial de uma conta B2B autenticada.';

commit;
