-- Run after 108 in a disposable transaction. All fixtures and changes roll back.
begin;
set local statement_timeout='110s';
create function pg_temp.assert(ok boolean, label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'TEST_FAILED:%',label; end if; end $$;
select pg_temp.assert(not has_table_privilege('anon','public.installed_catalog_sync_requests','select'),'anon_table');
select pg_temp.assert(not has_table_privilege('authenticated','public.installed_catalog_sync_requests','select'),'authenticated_table');
select pg_temp.assert(not has_table_privilege('ips_catalog_worker','public.products','update'),'worker_direct_update');
select pg_temp.assert(not has_function_privilege('anon','public.request_installed_catalog_sync()','execute'),'anon_request');
select pg_temp.assert(not has_function_privilege('authenticated','public.finish_installed_catalog_sync(uuid,uuid,jsonb)','execute'),'client_commit');
select pg_temp.assert(not has_function_privilege('ips_catalog_worker','public.request_installed_catalog_sync()','execute'),'worker_enqueue');
select pg_temp.assert(has_function_privilege('ips_catalog_worker','public.finish_installed_catalog_sync(uuid,uuid,jsonb)','execute'),'worker_commit');

-- Session enforcement changes below are uncommitted fixtures, never cut over.
update public.app_session_policy set enforced=false;
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',
  (select id::text from public.profiles where ativo and perfil='ADMIN' order by id limit 1))::text,true);
create temp table fixture(job jsonb, before_value jsonb, code text, protected jsonb);
insert into fixture(job) select public.request_installed_catalog_sync();
select pg_temp.assert((select job->>'id' from fixture)=public.request_installed_catalog_sync()->>'id','deduplicates_queue');
select pg_temp.assert(not(public.list_installed_catalog_sync()->'rows'->0 ? 'claim_token'),'history_no_token');
update fixture set job=public.claim_installed_catalog_sync();
select pg_temp.assert(public.claim_installed_catalog_sync() is null,'single_claim');
select pg_temp.assert(jsonb_array_length(public.snapshot_installed_catalog_sync((select (job->>'id')::uuid from fixture),
  (select (job->>'claim_token')::uuid from fixture)))<=250,'snapshot_page_size');

update fixture f set code=p.codigo, before_value=jsonb_build_object('url_imagem',p.url_imagem,'marca',p.marca,
  'aplicacao',p.aplicacao,'categoria',p.categoria,'montadora',p.montadora,'oem',p.oem,'similar',p.similar,'detalhes',p.detalhes),
  protected=to_jsonb(p)-array['url_imagem','marca','aplicacao','categoria','montadora','oem','similar','detalhes','search_text','search_vector']
from (select p.* from public.products p order by p.codigo limit 1) p;

do $$ declare f fixture; after_value jsonb; plan jsonb; result jsonb; audit_count integer;
begin
  select * into f from fixture;
  after_value:=jsonb_set(f.before_value,'{detalhes}',to_jsonb(concat_ws(E'\n\n',nullif(public.installed_catalog_manual_notes(f.before_value->>'detalhes'),''),
    E'[CATALOGO_IPS_INSTALADO]\nOrigem: Teste transacional\n[/CATALOGO_IPS_INSTALADO]')));
  plan:=jsonb_build_object('source','IPS_INSTALLED_CATALOG','source_version',repeat('a',64),
    'summary',jsonb_build_object('source_products',1,'matched',1,'updated',1,'unchanged',0,'unmatched',0),
    'changes',jsonb_build_array(jsonb_build_object('codigo',f.code,'before',f.before_value,'after',after_value)));
  begin
    perform public.finish_installed_catalog_sync((f.job->>'id')::uuid,gen_random_uuid(),plan);
    raise exception 'TEST_FAILED:token';
  exception when raise_exception then if sqlerrm<>'LOTE_OU_EXECUTOR_INVALIDO' then raise; end if; end;
  begin
    perform public.finish_installed_catalog_sync((f.job->>'id')::uuid,(f.job->>'claim_token')::uuid,
      jsonb_set(plan,'{changes,0,after,estoque}','999'));
    raise exception 'TEST_FAILED:protected_field';
  exception when raise_exception then if sqlerrm<>'CAMPOS_CATALOGO_INVALIDOS' then raise; end if; end;
  begin
    perform public.finish_installed_catalog_sync((f.job->>'id')::uuid,(f.job->>'claim_token')::uuid,
      jsonb_set(plan,'{changes,0,before,marca}','"STALE_SNAPSHOT"'));
    raise exception 'TEST_FAILED:optimistic_lock';
  exception when raise_exception then if sqlerrm<>'PRODUTO_ALTERADO_REVALIDAR' then raise; end if; end;
  begin
    perform public.finish_installed_catalog_sync((f.job->>'id')::uuid,(f.job->>'claim_token')::uuid,
      jsonb_set(plan,'{changes,0,after,detalhes}','"NOTA APAGADA"'));
    raise exception 'TEST_FAILED:manual_notes';
  exception when raise_exception then if sqlerrm<>'NOTAS_MANUAIS_PROTEGIDAS' then raise; end if; end;
  result:=public.finish_installed_catalog_sync((f.job->>'id')::uuid,(f.job->>'claim_token')::uuid,plan);
  perform pg_temp.assert(result->>'status'='completed','committed_status');
  perform pg_temp.assert(f.protected=(select to_jsonb(p)-array['url_imagem','marca','aplicacao','categoria','montadora','oem','similar','detalhes','search_text','search_vector']
    from public.products p where p.codigo=f.code),'protected_product_data');
  select count(*) into audit_count from public.product_catalog_metadata_audit where batch_id=(result->>'batch_id')::uuid;
  perform pg_temp.assert(audit_count=1,'audit_before_after');
  perform pg_temp.assert((select before_data->'fields'=f.before_value and after_data->'fields'=after_value
    from public.product_catalog_metadata_audit where batch_id=(result->>'batch_id')::uuid),'audit_values');
  perform public.finish_installed_catalog_sync((f.job->>'id')::uuid,(f.job->>'claim_token')::uuid,plan);
  perform pg_temp.assert((select count(*)=audit_count from public.product_catalog_metadata_audit where batch_id=(result->>'batch_id')::uuid),'retry_idempotent');
end $$;

select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000001"}',true);
do $$ begin
  begin perform public.request_installed_catalog_sync(); raise exception 'TEST_FAILED:non_admin';
  exception when sqlstate 'PT403' then null; end;
  begin perform public.list_installed_catalog_sync(); raise exception 'TEST_FAILED:non_admin_history';
  exception when sqlstate 'PT403' then null; end;
end $$;
update public.app_session_policy set enforced=true;
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',
  (select id::text from public.profiles where ativo and perfil='ADMIN' order by id limit 1))::text,true);
do $$ begin
  begin perform public.request_installed_catalog_sync(); raise exception 'TEST_FAILED:inactive_session';
  exception when sqlstate 'PT403' then null; end;
end $$;
select 'PASS: queue, permissions, pagination, token, protected fields, optimistic lock, notes, audit, idempotence, inactive session; ROLLBACK' as result;
rollback;
