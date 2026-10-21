begin;
set local statement_timeout='110s';
create function pg_temp.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'TEST_FAILED:%',label; end if; end $$;
select pg_temp.assert(not has_table_privilege('authenticated','public.product_activity_overrides','update'),'override_private');
select pg_temp.assert(not has_table_privilege('service_role','public.product_activity_overrides','update'),'service_no_override');
select pg_temp.assert(not has_function_privilege('anon','public.deactivate_products(jsonb)','execute'),'anon_no_bulk');
select pg_temp.assert(not has_function_privilege('ips_catalog_worker','public.deactivate_products(jsonb)','execute'),'catalog_worker_no_bulk');
select pg_temp.assert(not exists(select 1 from public.products p left join public.product_activity_overrides o on o.product_code=p.codigo
  where not p.ativo and o.ativo is distinct from false),'existing_inactive_preserved');
update public.app_session_policy set enforced=false;
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',
  (select id::text from public.profiles where ativo and perfil='ADMIN' order by id limit 1))::text,true);
insert into public.products(codigo,descricao) values('__IPS_ACTIVITY_A__','Fixture A'),('__IPS_ACTIVITY_B__','Fixture B');
select public.set_product_active('__IPS_ACTIVITY_A__',false,true);
select pg_temp.assert((select not ativo from public.product_activity_overrides where product_code='__IPS_ACTIVITY_A__'),'admin_override_saved');

-- Even ADMIN-authenticated sync must not change the administrative decision.
update public.products set ativo=true,descricao='Metadata sincronizada' where codigo='__IPS_ACTIVITY_A__';
select pg_temp.assert((select not ativo and descricao='Metadata sincronizada' from public.products where codigo='__IPS_ACTIVITY_A__'),'sync_keeps_inactive');
select set_config('request.jwt.claims','{"role":"service_role"}',true);
insert into public.products(codigo,descricao,ativo) values('__IPS_ACTIVITY_A__','Upsert sincronizado',true)
  on conflict(codigo) do update set ativo=excluded.ativo,descricao=excluded.descricao;
select pg_temp.assert((select not ativo and descricao='Upsert sincronizado' from public.products where codigo='__IPS_ACTIVITY_A__'),'service_upsert_keeps_inactive');
delete from public.product_branch_stock where product_code='__IPS_ACTIVITY_A__';
delete from public.product_branch_prices where product_code='__IPS_ACTIVITY_A__';
delete from public.products where codigo='__IPS_ACTIVITY_A__';
insert into public.products(codigo,descricao,ativo) values('__IPS_ACTIVITY_A__','Recriado',true);
select pg_temp.assert((select not ativo from public.products where codigo='__IPS_ACTIVITY_A__'),'recreate_keeps_inactive');
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',
  (select id::text from public.profiles where ativo and perfil='ADMIN' order by id limit 1))::text,true);
select public.set_product_active('__IPS_ACTIVITY_A__',true,false);
select pg_temp.assert((select ativo from public.products where codigo='__IPS_ACTIVITY_A__'),'admin_can_reactivate');

do $$ declare result jsonb; before_logs integer;
begin
  select count(*) into before_logs from public.logs where acao='ALTERAR_ATIVIDADE_PRODUTO' and id_entidade in ('__IPS_ACTIVITY_A__','__IPS_ACTIVITY_B__');
  begin
    perform public.deactivate_products('[{"codigo":"__IPS_ACTIVITY_A__","expected_active":true},{"codigo":"__IPS_ACTIVITY_B__","expected_active":false}]');
    raise exception 'TEST_FAILED:conflict';
  exception when raise_exception then if sqlerrm<>'PRODUTO_ALTERADO_POR_OUTRO_USUARIO' then raise; end if; end;
  perform pg_temp.assert((select bool_and(ativo) from public.products where codigo in ('__IPS_ACTIVITY_A__','__IPS_ACTIVITY_B__')),'conflict_rolls_back_all');
  begin
    perform public.deactivate_products('[{"codigo":"__IPS_ACTIVITY_A__","expected_active":true},{"codigo":"MISSING_FIXTURE","expected_active":true}]');
    raise exception 'TEST_FAILED:missing';
  exception when raise_exception then if sqlerrm<>'PRODUTO_NAO_ENCONTRADO' then raise; end if; end;
  begin
    perform public.deactivate_products('[{"codigo":"__IPS_ACTIVITY_A__","expected_active":true},{"codigo":"__IPS_ACTIVITY_A__","expected_active":true}]');
    raise exception 'TEST_FAILED:duplicate';
  exception when raise_exception then if sqlerrm<>'LOTE_ATIVIDADE_DUPLICADO' then raise; end if; end;
  result:=public.deactivate_products('[{"codigo":"__IPS_ACTIVITY_A__","expected_active":true},{"codigo":"__IPS_ACTIVITY_B__","expected_active":true}]');
  perform pg_temp.assert(result->>'count'='2' and result->>'changed'='2','bulk_success');
  perform pg_temp.assert((select bool_and(not ativo) from public.products where codigo in ('__IPS_ACTIVITY_A__','__IPS_ACTIVITY_B__')),'both_inactive');
  perform pg_temp.assert((select count(*)=before_logs+2 from public.logs where acao='ALTERAR_ATIVIDADE_PRODUTO' and id_entidade in ('__IPS_ACTIVITY_A__','__IPS_ACTIVITY_B__')),'individual_logs');
end $$;

-- A failure after the first update must roll back products, override and logs.
select public.set_product_active('__IPS_ACTIVITY_A__',true,false);
select public.set_product_active('__IPS_ACTIVITY_B__',true,false);
create function pg_temp.fail_second_activity() returns trigger language plpgsql as $$
begin if new.codigo='__IPS_ACTIVITY_B__' and not new.ativo then raise exception 'TEST_FORCED_FAILURE'; end if; return new; end $$;
create trigger zzz_test_activity_failure before update on public.products for each row execute function pg_temp.fail_second_activity();
do $$ declare before_logs integer; begin
  select count(*) into before_logs from public.logs;
  begin
    perform public.deactivate_products('[{"codigo":"__IPS_ACTIVITY_A__","expected_active":true},{"codigo":"__IPS_ACTIVITY_B__","expected_active":true}]');
    raise exception 'TEST_FAILED:rollback';
  exception when raise_exception then if sqlerrm<>'TEST_FORCED_FAILURE' then raise; end if; end;
  perform pg_temp.assert((select bool_and(ativo) from public.products where codigo in ('__IPS_ACTIVITY_A__','__IPS_ACTIVITY_B__')),'transaction_products');
  perform pg_temp.assert((select bool_and(ativo) from public.product_activity_overrides where product_code in ('__IPS_ACTIVITY_A__','__IPS_ACTIVITY_B__')),'transaction_overrides');
  perform pg_temp.assert((select count(*)=before_logs from public.logs),'transaction_logs');
end $$;
drop trigger zzz_test_activity_failure on public.products;

select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000001"}',true);
do $$ begin
  begin perform public.deactivate_products('[{"codigo":"__IPS_ACTIVITY_A__","expected_active":true}]');raise exception 'TEST_FAILED:non_admin';
  exception when raise_exception then if sqlerrm<>'SOMENTE_ADMIN_ALTERA_ATIVIDADE_PRODUTO' then raise; end if; end;
end $$;
update public.app_session_policy set enforced=true;
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',
  (select id::text from public.profiles where ativo and perfil='ADMIN' order by id limit 1))::text,true);
do $$ begin
  begin perform public.deactivate_products('[{"codigo":"__IPS_ACTIVITY_A__","expected_active":true}]');raise exception 'TEST_FAILED:inactive_session';
  exception when raise_exception then if sqlerrm<>'SOMENTE_ADMIN_ALTERA_ATIVIDADE_PRODUTO' then raise; end if; end;
end $$;
select 'PASS_109: persistent inactivity, source upsert, recreate, admin reactivation, bulk, atomic rollback, audit, permissions, session; ROLLBACK' as result;
rollback;
