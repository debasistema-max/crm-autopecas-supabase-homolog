begin;
set local statement_timeout='110s';
create function pg_temp.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'REG113:%',label;end if;end $$;
create temp table reg113_context(uid uuid,sid uuid,code text);
insert into reg113_context select gen_random_uuid(),gen_random_uuid(),codigo from public.products where ativo order by codigo limit 1;
grant select on reg113_context to authenticated;
do $$ declare c record;begin
 select * into c from reg113_context;
 if c.code is null then raise exception 'REG113_NO_ACTIVE_FIXTURE';end if;
 insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data)
 values(c.uid,'authenticated','authenticated',c.uid||'@example.invalid','{}','{}');
 insert into public.profiles(id,usuario,nome,email,perfil,ativo) values(c.uid,c.uid::text,'REG113',c.uid||'@example.invalid','ADMIN',true);
 insert into auth.sessions(id,user_id,created_at,updated_at,not_after) values(c.sid,c.uid,now()-interval '2 minutes',now(),now()+interval '1 hour');
 insert into public.app_sessions(user_id,active_session_id,auth_created_at) values(c.uid,c.sid,now()-interval '2 minutes');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',c.uid,'role','authenticated','session_id',c.sid)::text,true);
end $$;
set local role authenticated;
do $$ declare c record;origin text;destination text;result jsonb;expected jsonb;item jsonb;denied boolean;begin
 select * into c from reg113_context;
 foreach origin in array array['SP','PR'] loop
  foreach destination in array array['SP','PR','SC','RJ'] loop
   result:=public.search_product_catalog_pricing(jsonb_build_object('region',origin,'destination_uf',destination,'term',c.code,'limit',1));
   perform pg_temp.assert(jsonb_array_length(result)=1,'row_count');item:=result->0;
   perform pg_temp.assert(item->>'codigo'=c.code,'exact_code');
   perform pg_temp.assert(item->'fiscal'->>'route'=origin||'-'||destination,'route');
   expected:=public.get_product_commercial_price(c.code,origin,destination,public.commercial_business_date(),'REVENDA');
   if upper(expected->>'status') like 'OK%' and (expected->>'base_price')::numeric>0
     and (expected->>'total_taxes')::numeric>=0 and (expected->>'final_price')::numeric>0 then
    perform pg_temp.assert(item->'fiscal'->'base_price'=expected->'base_price','base_matches_engine');
    perform pg_temp.assert(item->'fiscal'->'total_taxes'=expected->'total_taxes','tax_matches_engine');
    perform pg_temp.assert(item->'preco'=expected->'final_price','final_matches_engine');
   else
    perform pg_temp.assert(item->'preco'='null'::jsonb and item->'fiscal'->'final_price'='null'::jsonb,'blocked_final_null');
   end if;
  end loop;
 end loop;
 denied:=false;begin perform public.search_product_catalog_pricing('{"region":"RJ","destination_uf":"SP"}');
 exception when others then if sqlerrm='ROTA_INVALIDA' then denied:=true;else raise;end if;end;
 perform pg_temp.assert(denied,'invalid_origin');
 denied:=false;begin perform public.search_product_catalog_pricing('{"region":"SP","destination_uf":"XX"}');
 exception when others then if sqlerrm='ROTA_INVALIDA' then denied:=true;else raise;end if;end;
 perform pg_temp.assert(denied,'invalid_destination');
 perform set_config('request.jwt.claims','{}',true);
 denied:=false;begin perform public.search_product_catalog_pricing('{}');
 exception when others then if sqlerrm='SEM_PERMISSAO' then denied:=true;else raise;end if;end;
 perform pg_temp.assert(denied,'no_session');
end $$;
reset role;
select pg_temp.assert(not has_function_privilege('anon','public.search_product_catalog_pricing(jsonb)','execute'),'anon_denied');
select pg_temp.assert(not has_function_privilege('ips_catalog_worker','public.search_product_catalog_pricing(jsonb)','execute'),'worker_denied');
select pg_temp.assert(not has_function_privilege('service_role','public.search_product_catalog_pricing(jsonb)','execute'),'service_denied');
rollback;
