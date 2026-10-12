-- Execute inside BEGIN / ROLLBACK; only disposable session fixtures are added.
do $$
declare v_uid uuid; v_a uuid:=gen_random_uuid(); v_b uuid:=gen_random_uuid();
begin
  select a.user_id into v_uid from public.customer_portal_accounts a
    join public.clients c on c.id=a.client_id and c.ativo
    where (a.active or a.activation_pending)
      and not exists(select 1 from public.profiles p where p.id=a.user_id) limit 1;
  if v_uid is null then raise exception 'FIXTURE_B2B_SEM_PERFIL_NECESSARIA'; end if;
  insert into auth.sessions(id,user_id,created_at,updated_at,not_after)
    values(v_a,v_uid,now()+interval '1 second',now(),now()+interval '1 hour');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_uid,'role','authenticated','session_id',v_a)::text,true);
  perform public.claim_app_session();
  insert into auth.sessions(id,user_id,created_at,updated_at,not_after)
    values(v_b,v_uid,now()+interval '2 seconds',now(),now()+interval '1 hour');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_uid,'role','authenticated','session_id',v_b)::text,true);
  perform public.claim_app_session();
  if (select active_session_id from public.app_sessions where user_id=v_uid) is distinct from v_b then raise exception 'B2B_TAKEOVER_FALHOU'; end if;
  if not exists(select 1 from public.logs where acao='SUBSTITUIR_SESSAO'
    and id_entidade=v_uid::text and user_id is null and dados_novos->>'auth_user_id'=v_uid::text
    and dados_novos->>'previous_session_id'=v_a::text and dados_novos->>'session_id'=v_b::text)
    then raise exception 'B2B_AUDITORIA_FALHOU'; end if;
end; $$;
select 'PASS: B2B takeover without internal profile; nullable audit actor and Auth identity preserved' result;
