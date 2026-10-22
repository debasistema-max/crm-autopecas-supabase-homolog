begin;
set local statement_timeout='110s';
create function pg_temp.assert114(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'REG114:%',label;end if;end $$;
select pg_temp.assert114(public.canonical_vehicle_maker(' vw ')='VOLKSWAGEN','vw_alias');
select pg_temp.assert114(public.canonical_vehicle_maker('M.Benz')='MERCEDES-BENZ','mercedes_alias');
select pg_temp.assert114(public.canonical_vehicle_maker('Ssang Yong')='SSANGYONG','ssangyong_alias');
select pg_temp.assert114(public.canonical_vehicle_maker('01 FT') is null,'sap_code_not_maker');
select pg_temp.assert114(public.product_vehicle_makers('{"applications":[{"automaker":"VW / GM"},{"automaker":"Volkswagen"}]}','')=array['GM','VOLKSWAGEN'],'multiple_and_dedup');
select pg_temp.assert114(public.product_vehicle_makers('{}','Veiculos / anos informados no catalogo:'||chr(10)||'FORD | TESTE')='{}','manual_note_not_source');
select pg_temp.assert114(public.product_vehicle_makers('{}','[CATALOGO_IPS_INSTALADO]'||chr(10)||'Veiculos / anos informados no catalogo:'||chr(10)||'FORD'||chr(10)||'[/CATALOGO_IPS_INSTALADO]')=array['FORD'],'maker_only_source_line');
select pg_temp.assert114(public.product_vehicle_makers('{}','[CATALOGO_IPS_INSTALADO]'||chr(10)||'Veiculos / anos informados no catalogo:'||chr(10)||'ASTRA | 1995'||chr(10)||'[/CATALOGO_IPS_INSTALADO]')='{}','model_is_not_a_make');
create temp table reg114_context as select gen_random_uuid() uid,gen_random_uuid() sid,'REG114-'||gen_random_uuid()::text grp,'8114'||lpad(floor(random()*10000000000)::bigint::text,10,'0') prefix;
grant select on reg114_context to authenticated;
do $$ declare c record;begin
 select * into c from reg114_context;
 insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data) values(c.uid,'authenticated','authenticated',c.uid||'@example.invalid','{}','{}');
 insert into public.profiles(id,usuario,nome,email,perfil,ativo) values(c.uid,c.uid::text,'REG114',c.uid||'@example.invalid','ADMIN',true);
 insert into auth.sessions(id,user_id,created_at,updated_at,not_after) values(c.sid,c.uid,now()-interval '2 minutes',now(),now()+interval '1 hour');
 insert into public.app_sessions(user_id,active_session_id,auth_created_at) values(c.uid,c.sid,now()-interval '2 minutes');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',c.uid,'role','authenticated','session_id',c.sid)::text,true);
 insert into public.products(codigo,descricao,grupo,montadora,detalhes) values
  (c.prefix||'1','MULTIMARCAS',c.grp,'01 FT',''),
  (c.prefix||'2','MERCEDES',c.grp,'01 CF','[CATALOGO_IPS_INSTALADO]'||chr(10)||'Veiculos / anos informados no catalogo:'||chr(10)||'M.BENZ | TESTE'||chr(10)||'[/CATALOGO_IPS_INSTALADO]'),
  (c.prefix||'3','SEM CATALOGO',c.grp,'TOYOTA',''),
  (c.prefix||'4','SEM CATALOGO',c.grp,'01 FT',''),
  (c.prefix||'5','UNIVERSAL',c.grp,'01 FT',''),
  (c.prefix||'6','INATIVO',c.grp,'01 FT','');
 insert into public.product_catalog_metadata(product_code,catalog_details) values
  (c.prefix||'1','{"applications":[{"automaker":"VW / GM"},{"automaker":"Volkswagen"}]}'),
  (c.prefix||'5','{"applications":[{"automaker":"UNIVERSAL"}]}'),
  (c.prefix||'6','{"applications":[{"automaker":"VW"}]}');
 perform public.set_product_active(c.prefix||'6',false,null);
end $$;
set local role authenticated;
do $$ declare c record;result jsonb;page jsonb;maker text;expected int;denied boolean;begin
 select * into c from reg114_context;
 result:=public.get_catalog_filter_options();
 perform pg_temp.assert114(result->'montadoras' ?& array['VOLKSWAGEN','MERCEDES-BENZ','__SEM_MONTADORA__'],'options');
 perform pg_temp.assert114(not(result->'montadoras' ? '01 FT'),'no_sap_options');
 foreach maker in array array['VW','GM','MERCEDES','__SEM_MONTADORA__','UNIVERSAL'] loop
  expected:=case when maker='__SEM_MONTADORA__' then 2 else 1 end;
  result:=public.search_products_v2(jsonb_build_object('group',c.grp,'vehicle_maker',maker,'limit',500));
  perform pg_temp.assert114(jsonb_array_length(result)=expected,'search_'||maker);
  result:=public.generate_commercial_list('PR-PR',jsonb_build_object('group',c.grp,'vehicle_maker',maker,'offset',0,'limit',500));
  perform pg_temp.assert114((result->>'count')::int=expected and jsonb_array_length(result->'rows')=expected,'list_'||maker);
  perform pg_temp.assert114(not exists(select 1 from jsonb_array_elements(result->'rows') item where jsonb_typeof(item->'vehicle_makers') is distinct from 'array'),'list_payload');
 end loop;
 result:=public.search_products_v2(jsonb_build_object('group',c.grp,'term','Volkswagen','limit',1));
 perform pg_temp.assert114(result->0->>'codigo'=c.prefix||'1','canonical_free_text');
 result:=public.search_products_v2(jsonb_build_object('group',c.grp,'maker','TOYOTA','limit',500));
 perform pg_temp.assert114(jsonb_array_length(result)=1 and result->0->>'codigo'=c.prefix||'3','legacy_maker_unchanged');
 result:=public.search_product_catalog_pricing(jsonb_build_object('group',c.grp,'vehicle_maker','VW','region','PR','destination_uf','RJ','limit',1));
 perform pg_temp.assert114(result->0->'vehicle_makers' ? 'VOLKSWAGEN','priced_catalog');
 page:=public.generate_commercial_list('PR-PR',jsonb_build_object('group',c.grp,'vehicle_maker','__SEM_MONTADORA__','offset',0,'limit',1));
 result:=public.generate_commercial_list('PR-PR',jsonb_build_object('group',c.grp,'vehicle_maker','__SEM_MONTADORA__','offset',1,'limit',1,'expected_revision',page->>'catalog_revision'));
 perform pg_temp.assert114((page->>'has_more')::boolean and not(result->>'has_more')::boolean and page->'rows'->0->>'product_code'<>result->'rows'->0->>'product_code','pagination');
 perform set_config('request.jwt.claims','{}',true);denied:=false;
 begin perform public.get_catalog_filter_options();exception when others then if sqlerrm='SEM_PERMISSAO' then denied:=true;else raise;end if;end;
 perform pg_temp.assert114(denied,'no_session_options');
end $$;
reset role;
select pg_temp.assert114(not has_function_privilege('anon','public.get_catalog_filter_options()','execute'),'anon');
select pg_temp.assert114(not has_function_privilege('ips_catalog_worker','public.canonical_vehicle_maker(text)','execute'),'private_helper');
rollback;
