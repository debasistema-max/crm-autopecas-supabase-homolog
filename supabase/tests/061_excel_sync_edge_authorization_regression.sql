begin;

do $$
declare v_admin uuid; v_non_admin uuid:=gen_random_uuid();
begin
  if has_function_privilege('anon','public.can_manage_data_sync()','execute') then
    raise exception 'ANON_PODE_CONSULTAR_PERMISSAO_DE_SYNC';
  end if;
  if not has_function_privilege('authenticated','public.can_manage_data_sync()','execute') then
    raise exception 'AUTHENTICATED_SEM_PREDICADO_DE_PERMISSAO';
  end if;

  select id into v_admin from public.profiles where upper(perfil::text)='ADMIN' limit 1;
  if v_admin is null then raise exception 'PERFIL_ADMIN_DE_TESTE_AUSENTE'; end if;

  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  if not public.can_manage_data_sync() then raise exception 'ADMIN_NEGADO'; end if;

  perform set_config('request.jwt.claim.sub',v_non_admin::text,true);
  if public.can_manage_data_sync() then raise exception 'VENDEDOR_AUTORIZADO'; end if;
  raise notice 'EXCEL_SYNC_EDGE_AUTHORIZATION_OK';
end;
$$;

rollback;
