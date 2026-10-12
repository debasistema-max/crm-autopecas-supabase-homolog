-- Apply only after crm-login, session-aware Edge Functions and frontend deploy.
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
