-- Apply only after crm-login, session-aware Edge Functions and frontend deploy.
-- Disabling an account must also invalidate an otherwise matching session.
create or replace function public.is_app_session_active()
returns boolean language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_sid uuid; v_enforced boolean;
begin
  if auth.role()='service_role' then return true; end if;
  if v_uid is null then return false; end if;
  select enforced into v_enforced from public.app_session_policy where id;
  if not coalesce(v_enforced,true) then return true; end if;
  if not exists(select 1 from public.profiles p where p.id=v_uid and p.ativo)
    and not exists(select 1 from public.customer_portal_accounts a
      join public.clients c on c.id=a.client_id and c.ativo
      where a.user_id=v_uid and (a.active or a.activation_pending)) then return false; end if;
  begin v_sid:=nullif(auth.jwt()->>'session_id','')::uuid;
  exception when invalid_text_representation then return false; end;
  if v_sid is null or not exists(select 1 from auth.sessions s where s.id=v_sid and s.user_id=v_uid
    and (s.not_after is null or s.not_after>now())) then return false; end if;
  return exists(select 1 from public.app_sessions a where a.user_id=v_uid and a.active_session_id=v_sid);
end;
$$;
insert into public.app_sessions(user_id,active_session_id,auth_created_at)
select distinct on (s.user_id) s.user_id,s.id,s.created_at from auth.sessions s
where (s.not_after is null or s.not_after>now())
  and (exists(select 1 from public.profiles p where p.id=s.user_id and p.ativo)
    or exists(select 1 from public.customer_portal_accounts a where a.user_id=s.user_id and (a.active or a.activation_pending)))
order by s.user_id,s.created_at desc,s.id desc
on conflict(user_id) do update set active_session_id=excluded.active_session_id,
  auth_created_at=excluded.auth_created_at,changed_at=now()
where public.app_sessions.auth_created_at<excluded.auth_created_at;
update public.app_session_policy set enforced=true where id;
revoke execute on function public.resolve_login_email(text) from public,anon,authenticated;
grant execute on function public.resolve_login_email(text) to service_role;
notify pgrst,'reload schema';
