begin;
set local statement_timeout='110s';
create temporary table reg107_context on commit drop as
select gen_random_uuid() uid,gen_random_uuid() sid,'8107'||lpad(floor(random()*10000000000)::bigint::text,10,'0') prefix,
  'REG107-'||gen_random_uuid()::text fixture_group;
grant select on reg107_context to authenticated;
do $$
declare c record;
begin
  select * into c from reg107_context;
  if public.product_vehicle_types('COROLLA')<>array['LEVE']
    or public.product_vehicle_types('COROLLA CROSS COROLLA CROSS')<>array['UTILITARIO']
    or public.product_vehicle_types('S-10')<>array['UTILITARIO']
    or public.product_vehicle_types('RAV 4')<>array['UTILITARIO']
    or public.product_vehicle_types('ATEGO 2429')<>array['PESADO']
    or public.product_vehicle_types('COROLLA/HILUX')<>array['LEVE','UTILITARIO']
    or public.product_vehicle_types('COROLLA/COROLLA CROSS')<>array['LEVE','UTILITARIO']
    or public.product_vehicle_types('MERCEDES')<>array['NAO_CLASSIFICADO']
    or public.product_vehicle_types('ASTRAL')<>array['NAO_CLASSIFICADO']
    or public.product_vehicle_types(null)<>array['NAO_CLASSIFICADO'] then raise exception 'REG107_CLASSIFICATION'; end if;
  if has_function_privilege('authenticated','public.product_vehicle_types(text)','EXECUTE') then raise exception 'REG107_PRIVATE_HELPER'; end if;
  insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data)
  values(c.uid,'authenticated','authenticated',c.uid||'@example.invalid','{}','{}');
  insert into public.profiles(id,usuario,nome,email,perfil,ativo)
  values(c.uid,c.uid::text,'REG107 ficticio',c.uid||'@example.invalid','ADMIN',true);
  insert into auth.sessions(id,user_id,created_at,updated_at,not_after)
  values(c.sid,c.uid,now()-interval '2 minutes',now(),now()+interval '1 hour');
  insert into public.app_sessions(user_id,active_session_id,auth_created_at)
  values(c.uid,c.sid,now()-interval '2 minutes');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',c.uid,'role','authenticated','session_id',c.sid)::text,true);
  insert into public.products(codigo,descricao,aplicacao,grupo,ativo)
  values(c.prefix||'1','FAROL TESTE','COROLLA',c.fixture_group,true),
    (c.prefix||'2','FAROL TESTE','HILUX',c.fixture_group,true),
    (c.prefix||'3','FAROL TESTE','ATEGO',c.fixture_group,true),
    (c.prefix||'4','FAROL TESTE',null,c.fixture_group,true),
    (c.prefix||'5','FAROL TESTE','COROLLA/HILUX',c.fixture_group,true),
    (c.prefix||'6','FAROL TESTE','HILUX',c.fixture_group,false);
end;
$$;
set local role authenticated;
do $$
declare c record; result jsonb; segment text; expected integer; denied boolean;
begin
  select * into c from reg107_context;
  foreach segment in array array['LEVE','UTILITARIO','PESADO','NAO_CLASSIFICADO'] loop
    expected:=case when segment in('LEVE','UTILITARIO') then 2 else 1 end;
    result:=public.search_products_v2(jsonb_build_object('group',c.fixture_group,'vehicle_type',segment,'limit',500));
    if jsonb_array_length(result)<>expected or exists(select 1 from jsonb_array_elements(result) item
      where not(item->'vehicle_types' ? segment)) then raise exception 'REG107_PRODUCT_FILTER: %',segment; end if;
    result:=public.generate_commercial_list('PR-PR',jsonb_build_object('group',c.fixture_group,'lines',jsonb_build_array('FAROL'),'vehicle_type',segment,'offset',0,'limit',500));
    if (result->>'count')::int<>expected or jsonb_array_length(result->'rows')<>expected
      or exists(select 1 from jsonb_array_elements(result->'rows') item where not(item->'vehicle_types' ? segment)) then raise exception 'REG107_LIST_FILTER: %',segment; end if;
  end loop;
  result:=public.search_products_v2(jsonb_build_object('group',c.fixture_group,'vehicle_type','PESADO','limit',1));
  if result->0->>'codigo'<>c.prefix||'3' then raise exception 'REG107_FILTER_AFTER_LIMIT'; end if;
  denied:=false;
  begin perform public.search_products_v2(jsonb_build_object('vehicle_type','INVALIDO'));
  exception when others then if sqlerrm='TIPO_VEICULO_INVALIDO' then denied:=true; else raise; end if; end;
  if not denied then raise exception 'REG107_INVALID_PRODUCT_TYPE'; end if;
  denied:=false;
  begin perform public.generate_commercial_list('PR-PR',jsonb_build_object('offset',0,'vehicle_type','INVALIDO'));
  exception when others then if sqlerrm='TIPO_VEICULO_INVALIDO' then denied:=true; else raise; end if; end;
  if not denied then raise exception 'REG107_INVALID_LIST_TYPE'; end if;
end;
$$;
reset role;
rollback;
