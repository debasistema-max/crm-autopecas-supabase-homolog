-- PostgREST runs its pre-request hook as the request role, including anon.
-- The hook itself returns no private data and preserves the RPC/table grants.
grant execute on function public.check_app_session_request() to anon,service_role;

create or replace function public.release_app_session()
returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if auth.uid() is null then return; end if;
  perform pg_advisory_xact_lock(hashtextextended('app-session:'||auth.uid()::text,0));
  update public.app_sessions set active_session_id=null,changed_at=now()
  where user_id=auth.uid() and active_session_id=nullif(auth.jwt()->>'session_id','')::uuid;
end;
$$;
revoke execute on function public.release_app_session() from public,anon;
grant execute on function public.release_app_session() to authenticated;
notify pgrst,'reload config';
notify pgrst,'reload schema';
