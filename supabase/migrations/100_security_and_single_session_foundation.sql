-- Foundation is staged: enforcement is activated only after the new frontend.
create table public.app_session_policy (
  id boolean primary key default true check (id),
  enforced boolean not null default false
);
insert into public.app_session_policy(id,enforced) values(true,false);
alter table public.app_session_policy enable row level security;
revoke all on public.app_session_policy from public,anon,authenticated;

create table public.app_sessions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  active_session_id uuid,
  auth_created_at timestamptz not null,
  changed_at timestamptz not null default now()
);
alter table public.app_sessions enable row level security;
revoke all on public.app_sessions from public,anon,authenticated;

create or replace function public.is_app_session_active()
returns boolean language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_sid uuid; v_enforced boolean;
begin
  if auth.role()='service_role' then return true; end if;
  if v_uid is null then return false; end if;
  select enforced into v_enforced from public.app_session_policy where id;
  if not coalesce(v_enforced,true) then return true; end if;
  begin v_sid:=nullif(auth.jwt()->>'session_id','')::uuid;
  exception when invalid_text_representation then return false; end;
  if v_sid is null or not exists (
    select 1 from auth.sessions s where s.id=v_sid and s.user_id=v_uid
      and (s.not_after is null or s.not_after>now())
  ) then return false; end if;
  return exists(select 1 from public.app_sessions a where a.user_id=v_uid and a.active_session_id=v_sid);
end;
$$;

create or replace function public.claim_app_session()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_sid uuid; v_latest uuid; v_created timestamptz; v_previous public.app_sessions;
begin
  if auth.role() is distinct from 'authenticated' or v_uid is null then raise sqlstate 'PT401' using message='SESSAO_INVALIDA'; end if;
  begin v_sid:=nullif(auth.jwt()->>'session_id','')::uuid;
  exception when invalid_text_representation then raise sqlstate 'PT401' using message='SESSAO_INVALIDA'; end;
  if v_sid is null then raise sqlstate 'PT401' using message='SESSAO_INVALIDA'; end if;
  if not exists(select 1 from public.profiles p where p.id=v_uid and p.ativo)
    and not exists(select 1 from public.customer_portal_accounts a where a.user_id=v_uid and (a.active or a.activation_pending))
    then raise sqlstate 'PT403' using message='USUARIO_INATIVO'; end if;
  perform pg_advisory_xact_lock(hashtextextended('app-session:'||v_uid::text,0));
  select s.id,s.created_at into v_latest,v_created from auth.sessions s
    where s.user_id=v_uid and (s.not_after is null or s.not_after>now())
    order by s.created_at desc,s.id desc limit 1;
  if v_latest is distinct from v_sid then raise sqlstate 'PT401' using message='SESSAO_SUBSTITUIDA'; end if;
  select * into v_previous from public.app_sessions where user_id=v_uid;
  if v_previous.user_id is not null and v_previous.active_session_id is distinct from v_sid
    and v_previous.auth_created_at>=v_created then raise sqlstate 'PT401' using message='SESSAO_SUBSTITUIDA'; end if;
  insert into public.app_sessions(user_id,active_session_id,auth_created_at) values(v_uid,v_sid,v_created)
    on conflict(user_id) do update set active_session_id=excluded.active_session_id,
      auth_created_at=excluded.auth_created_at,changed_at=now();
  if v_previous.user_id is not null and v_previous.active_session_id is distinct from v_sid then
    insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_novos)
    values(v_uid,coalesce((select usuario from public.profiles where id=v_uid),'B2B'),
      'SUBSTITUIR_SESSAO','app_sessions',v_uid::text,jsonb_build_object('previous_session_id',v_previous.active_session_id,'session_id',v_sid));
  end if;
  return jsonb_build_object('active',true);
end;
$$;

create or replace function public.get_app_session_status()
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
  select jsonb_build_object('active',public.is_app_session_active());
$$;

create or replace function public.release_app_session()
returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
  update public.app_sessions set active_session_id=null,changed_at=now()
  where user_id=auth.uid() and active_session_id=nullif(auth.jwt()->>'session_id','')::uuid;
end;
$$;

create or replace function public.check_app_session_request()
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_path text:=coalesce(current_setting('request.path',true),'');
begin
  if auth.role() is distinct from 'authenticated' then return; end if;
  if v_path in ('/rpc/claim_app_session','/rpc/get_app_session_status','/rpc/get_public_company_identity') then return; end if;
  if not public.is_app_session_active() then raise sqlstate 'PT401' using message='SESSAO_SUBSTITUIDA'; end if;
end;
$$;

revoke all on function public.is_app_session_active(),public.claim_app_session(),public.get_app_session_status(),
  public.release_app_session(),public.check_app_session_request() from public,anon;
grant execute on function public.is_app_session_active(),public.claim_app_session(),public.get_app_session_status(),
  public.release_app_session(),public.check_app_session_request() to authenticated;
grant execute on function public.is_app_session_active(),public.get_app_session_status() to service_role;

-- Keep existing RLS rules; this additional restrictive rule cannot widen them.
do $$ declare t record; begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind in ('r','p') and c.relrowsecurity
      and c.relname not in ('app_sessions','app_session_policy')
  loop
    execute format('create policy app_active_session_gate on public.%I as restrictive for all to authenticated using ((select public.is_app_session_active())) with check ((select public.is_app_session_active()))',t.relname);
  end loop;
end; $$;
create policy app_active_session_gate on storage.objects as restrictive for all to authenticated
  using ((select public.is_app_session_active())) with check ((select public.is_app_session_active()));

-- Never replace an existing pre-request integration without an explicit review.
do $$ declare v_existing text; begin
  select split_part(setting,'=',2) into v_existing from pg_roles r cross join lateral unnest(r.rolconfig) setting
    where r.rolname='authenticator' and setting like 'pgrst.db_pre_request=%';
  if nullif(v_existing,'') is not null then raise exception 'PRE_REQUEST_EXISTENTE_REQUER_REVISAO'; end if;
end; $$;
alter role authenticator set pgrst.db_pre_request='public.check_app_session_request';
notify pgrst,'reload config';
notify pgrst,'reload schema';

-- Missing production policy: approval and SAP-code editing remain permissioned.
drop policy if exists cadastros_clientes_crm_update on public.cadastros_clientes;
create policy cadastros_clientes_crm_update on public.cadastros_clientes for update to authenticated
  using(public.has_module('cadastros') or public.is_admin())
  with check(public.has_module('cadastros') or public.is_admin());
grant select,update on public.cadastros_clientes to authenticated;

revoke execute on function public.commercial_create_document(text,jsonb),
  public.commercial_update_document_items(text,jsonb),public.convert_quotation_to_order(uuid),
  public.b2b_create_document(text,jsonb) from public,anon;
grant execute on function public.resolve_login_email(text) to service_role;
-- Fiscal implementation helpers are not customer-facing RPCs. Definer callers
-- retain access as their owner; clients use the scoped catalog RPCs instead.
revoke execute on function public.calculate_product_price(text,text,text,numeric,date,text),
  public.calculate_product_price_from_excel_base(text,text,text,numeric,date,text),
  public.calculate_product_price_crm_rules(text,text,text,numeric,date,text)
  from public,anon,authenticated;

-- Pin the remaining invoker helpers without changing their bodies or grants.
do $$ declare f record; begin
  for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prokind='f'
      and not exists(select 1 from pg_depend d where d.objid=p.oid and d.deptype='e')
      and not exists(select 1 from unnest(p.proconfig) s where s like 'search_path=%')
  loop execute format('alter function %s set search_path=public,pg_temp',f.signature); end loop;
end; $$;
