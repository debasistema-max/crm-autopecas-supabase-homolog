begin;

set local lock_timeout = '10s';
set local statement_timeout = '110s';

-- Public endpoints never need direct anonymous table access. Registrations are
-- validated and written by the cadastro-cliente Edge Function.
revoke all privileges on all tables in schema public from public, anon;
revoke all privileges on all sequences in schema public from public, anon;
drop policy if exists cadastros_clientes_public_insert on public.cadastros_clientes;

-- Preserve the authenticated/service-role function surface while removing the
-- implicit PostgreSQL PUBLIC execute grant that also exposed it to anon.
create temporary table security_function_acl_snapshot on commit drop as
select p.oid,
       has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_execute,
       has_function_privilege('service_role',p.oid,'EXECUTE') as service_execute
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and not exists (
    select 1 from pg_depend d
    where d.classid='pg_proc'::regclass and d.objid=p.oid and d.deptype='e'
  );

do $$
declare r record;
begin
  for r in select * from security_function_acl_snapshot loop
    execute format('revoke execute on function %s from public, anon',r.oid::regprocedure);
    if r.authenticated_execute then
      execute format('grant execute on function %s to authenticated',r.oid::regprocedure);
    end if;
    if r.service_execute then
      execute format('grant execute on function %s to service_role',r.oid::regprocedure);
    end if;
  end loop;
end;
$$;

-- The only RPCs intentionally callable before login.
grant execute on function public.resolve_login_email(text) to anon;
grant execute on function public.get_public_company_identity() to anon;

-- Internal helpers must only run through an authorized SECURITY DEFINER entry
-- point or a server-side service-role operation.
revoke execute on function public.calculate_product_price(text,text,text,numeric,date,text)
  from public,anon,authenticated;
grant execute on function public.calculate_product_price(text,text,text,numeric,date,text)
  to service_role;
revoke execute on function public.resolve_fiscal_tax_rule(text,text,text,text,date)
  from public,anon,authenticated;
grant execute on function public.resolve_fiscal_tax_rule(text,text,text,text,date)
  to service_role;
revoke execute on function public.get_data_sync_current_values(text,text,text,text)
  from public,anon,authenticated;
grant execute on function public.get_data_sync_current_values(text,text,text,text)
  to service_role;

-- Product-code existence is an internal CRM operation, not a B2B/anonymous API.
create or replace function public.check_existing_product_codes(codes jsonb)
returns table(codigo text)
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.is_internal_user() then raise exception 'SEM_PERMISSAO'; end if;
  if jsonb_typeof(coalesce(codes,'[]'::jsonb))<>'array'
     or jsonb_array_length(coalesce(codes,'[]'::jsonb))>1000 then
    raise exception 'LISTA_CODIGOS_INVALIDA';
  end if;
  return query
  select p.codigo
  from public.products p
  join (
    select distinct btrim(value #>> '{}') as codigo
    from jsonb_array_elements(coalesce(codes,'[]'::jsonb))
  ) c on c.codigo=p.codigo
  where c.codigo<>'' and length(c.codigo)<=80;
end;
$$;
revoke all on function public.check_existing_product_codes(jsonb) from public,anon,authenticated;
grant execute on function public.check_existing_product_codes(jsonb) to authenticated;

-- Password activation is now completed atomically by a server-side function
-- only after that function has changed the Auth password.
revoke all on function public.complete_b2b_password_change() from public,anon,authenticated;
grant execute on function public.complete_b2b_password_change() to service_role;

create or replace function public.complete_b2b_password_change_for_user(p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare v_account public.customer_portal_accounts;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user not in ('postgres','supabase_admin') then
    raise exception 'SEM_PERMISSAO';
  end if;
  update public.customer_portal_accounts
  set must_change_password=false,activation_pending=false,active=true,updated_at=now()
  where user_id=p_user_id and must_change_password
  returning * into v_account;
  if v_account.user_id is null then raise exception 'ACESSO_B2B_NAO_ENCONTRADO'; end if;
  return true;
end;
$$;
revoke all on function public.complete_b2b_password_change_for_user(uuid)
  from public,anon,authenticated;
grant execute on function public.complete_b2b_password_change_for_user(uuid) to service_role;

create table if not exists public.public_endpoint_rate_limits(
  endpoint text not null check(endpoint ~ '^[a-z0-9_-]{2,64}$'),
  subject_hash text not null check(subject_hash ~ '^[0-9a-f]{64}$'),
  window_started_at timestamptz not null default now(),
  request_count integer not null default 1 check(request_count>0),
  updated_at timestamptz not null default now(),
  primary key(endpoint,subject_hash)
);
alter table public.public_endpoint_rate_limits enable row level security;
revoke all on public.public_endpoint_rate_limits from public,anon,authenticated;
grant select,insert,update,delete on public.public_endpoint_rate_limits to service_role;

create or replace function public.consume_public_endpoint_rate_limit(
  p_endpoint text,p_subject_hash text,p_window_seconds integer,p_max_requests integer
)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare v_row public.public_endpoint_rate_limits;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user not in ('postgres','supabase_admin') then
    raise exception 'SEM_PERMISSAO';
  end if;
  if p_endpoint !~ '^[a-z0-9_-]{2,64}$' or p_subject_hash !~ '^[0-9a-f]{64}$'
     or p_window_seconds not between 60 and 86400 or p_max_requests not between 1 and 1000 then
    raise exception 'RATE_LIMIT_INVALIDO';
  end if;
  select * into v_row from public.public_endpoint_rate_limits
  where endpoint=p_endpoint and subject_hash=p_subject_hash for update;
  if v_row.endpoint is null then
    insert into public.public_endpoint_rate_limits(endpoint,subject_hash)
    values(p_endpoint,p_subject_hash);
    return true;
  end if;
  if v_row.window_started_at<=now()-make_interval(secs=>p_window_seconds) then
    update public.public_endpoint_rate_limits
    set window_started_at=now(),request_count=1,updated_at=now()
    where endpoint=p_endpoint and subject_hash=p_subject_hash;
    return true;
  end if;
  if v_row.request_count>=p_max_requests then return false; end if;
  update public.public_endpoint_rate_limits
  set request_count=request_count+1,updated_at=now()
  where endpoint=p_endpoint and subject_hash=p_subject_hash;
  return true;
end;
$$;
revoke all on function public.consume_public_endpoint_rate_limit(text,text,integer,integer)
  from public,anon,authenticated;
grant execute on function public.consume_public_endpoint_rate_limit(text,text,integer,integer)
  to service_role;

comment on table public.public_endpoint_rate_limits is
  'Contadores sem IP em claro para limitar abuso dos endpoints públicos.';

commit;
