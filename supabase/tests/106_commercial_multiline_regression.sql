begin;
set local statement_timeout='110s';
create temporary table reg106_context on commit drop as
select gen_random_uuid() uid,gen_random_uuid() sid,'8106'||lpad(floor(random()*10000000000)::bigint::text,10,'0') prefix,
  'REG106-'||gen_random_uuid()::text fixture_group;
grant select on reg106_context to authenticated;
do $$
declare c record;
begin
  select * into c from reg106_context;
  if has_function_privilege('anon','public.get_commercial_list_lines()','EXECUTE')
    or has_function_privilege('authenticated','public.commercial_product_line(text,text,text)','EXECUTE') then raise exception 'REG106_GRANTS'; end if;
  if public.commercial_product_line(' Linha SAP ','RETROVISOR','FAROL LD')<>'Linha SAP'
    or public.commercial_product_line(' ',' Linha oficial ','FAROL LD')<>'Linha oficial'
    or public.commercial_product_line(null,null,'FAROL LD')<>'FAROL'
    or public.commercial_product_line(null,null,'LANTERNA LE')<>'LANTERNA'
    or public.commercial_product_line(null,null,'RETROVISOR LD')<>'RETROVISOR'
    or public.commercial_product_line(null,null,'RAD.EXP. TESTE')<>'RADIADOR'
    or public.commercial_product_line(null,null,null)<>'SEM LINHA' then raise exception 'REG106_CLASSIFICATION'; end if;
  insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data)
  values(c.uid,'authenticated','authenticated',c.uid||'@example.invalid','{}','{}');
  insert into public.profiles(id,usuario,nome,email,perfil,ativo)
  values(c.uid,c.uid::text,'REG106 ficticio',c.uid||'@example.invalid','ADMIN',true);
  insert into auth.sessions(id,user_id,created_at,updated_at,not_after)
  values(c.sid,c.uid,now()-interval '2 minutes',now(),now()+interval '1 hour');
  insert into public.app_sessions(user_id,active_session_id,auth_created_at)
  values(c.uid,c.sid,now()-interval '2 minutes');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',c.uid,'role','authenticated','session_id',c.sid)::text,true);
  insert into public.products(codigo,descricao,categoria,grupo,ativo)
  values(c.prefix||'1','FAROL TESTE',null,c.fixture_group,true),
    (c.prefix||'2','LANTERNA TESTE',null,c.fixture_group,true),
    (c.prefix||'3','RETROVISOR TESTE',null,c.fixture_group,true),
    (c.prefix||'4','FAROL TESTE',null,c.fixture_group,false),
    (c.prefix||'5','FAROL TESTE','LINHA OFICIAL',c.fixture_group,true);
end;
$$;
set local role authenticated;
do $$
declare c record; result jsonb; denied boolean; bad jsonb;
begin
  select * into c from reg106_context;
  result:=public.get_commercial_list_lines();
  if not(result->'linhas' ?& array['FAROL','LANTERNA','RETROVISOR','LINHA OFICIAL']) then raise exception 'REG106_OPTIONS_MISSING'; end if;
  result:=public.generate_commercial_list('PR-PR',jsonb_build_object('group',c.fixture_group,'offset',0,'limit',10,'lines',jsonb_build_array('FAROL','RETROVISOR','FAROL',' ')));
  if result->>'count'<>'2' or jsonb_array_length(result->'rows')<>2
    or exists(select 1 from jsonb_array_elements(result->'rows') item where item->>'product_code' not in(c.prefix||'1',c.prefix||'3')) then raise exception 'REG106_MULTILINE_OR_INACTIVE'; end if;
  result:=public.generate_commercial_list('PR-PR',jsonb_build_object('group',c.fixture_group,'offset',0,'limit',10,'lines','[]'::jsonb));
  if result->>'count'<>'4' then raise exception 'REG106_GENERAL'; end if;
  result:=public.generate_commercial_list('PR-PR',jsonb_build_object('group',c.fixture_group,'offset',0,'limit',10,'line','LANTERNA'));
  if result->>'count'<>'1' then raise exception 'REG106_SINGLE_COMPATIBILITY'; end if;
  result:=public.generate_commercial_list('PR-PR',jsonb_build_object('group',c.fixture_group,'offset',0,'limit',1,'lines',jsonb_build_array('FAROL','RETROVISOR')));
  if not(result->>'has_more')::boolean then raise exception 'REG106_FIRST_PAGE'; end if;
  result:=public.generate_commercial_list('PR-PR',jsonb_build_object('group',c.fixture_group,'offset',1,'limit',1,'expected_revision',result->>'catalog_revision','lines',jsonb_build_array('FAROL','RETROVISOR')));
  if (result->>'has_more')::boolean or jsonb_array_length(result->'rows')<>1 then raise exception 'REG106_SECOND_PAGE'; end if;
  for bad in select value from (values('null'::jsonb),('{}'::jsonb),('[1]'::jsonb),('[null]'::jsonb),(jsonb_build_array(repeat('A',121)))) payloads(value) loop
    denied:=false;
    begin perform public.generate_commercial_list('PR-PR',jsonb_build_object('offset',0,'lines',bad));
    exception when others then if sqlerrm='LINHAS_INVALIDAS' then denied:=true; else raise; end if; end;
    if not denied then raise exception 'REG106_INVALID_LINES_ALLOWED'; end if;
  end loop;
  denied:=false;
  begin
    perform public.generate_commercial_list('PR-PR',jsonb_build_object('offset',0,'lines',(select jsonb_agg('FAROL'::text) from generate_series(1,101))));
  exception when others then if sqlerrm='EXCESSO_DE_LINHAS' then denied:=true; else raise; end if; end;
  if not denied then raise exception 'REG106_EXCESS_LINES_ALLOWED'; end if;
  perform set_config('request.jwt.claims','{}',true);
  denied:=false;
  begin perform public.get_commercial_list_lines();
  exception when others then if sqlerrm='SEM_PERMISSAO' then denied:=true; else raise; end if; end;
  if not denied then raise exception 'REG106_NO_SESSION_ALLOWED'; end if;
end;
$$;
reset role;
rollback;
