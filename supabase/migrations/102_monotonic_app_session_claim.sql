-- Protect against a concurrent activation seed as well as normal claim/logout.
create or replace function public.claim_app_session()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_sid uuid; v_latest uuid; v_created timestamptz;
  v_previous public.app_sessions; v_written integer;
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
      auth_created_at=excluded.auth_created_at,changed_at=now()
    where public.app_sessions.active_session_id=excluded.active_session_id
      or public.app_sessions.auth_created_at<excluded.auth_created_at;
  get diagnostics v_written=row_count;
  if v_written<>1 then raise sqlstate 'PT401' using message='SESSAO_SUBSTITUIDA'; end if;
  if v_previous.user_id is not null and v_previous.active_session_id is distinct from v_sid then
    insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_novos)
    values(v_uid,coalesce((select usuario from public.profiles where id=v_uid),'B2B'),
      'SUBSTITUIR_SESSAO','app_sessions',v_uid::text,jsonb_build_object('previous_session_id',v_previous.active_session_id,'session_id',v_sid));
  end if;
  return jsonb_build_object('active',true);
end;
$$;
revoke execute on function public.claim_app_session() from public,anon;
grant execute on function public.claim_app_session() to authenticated;
notify pgrst,'reload schema';
