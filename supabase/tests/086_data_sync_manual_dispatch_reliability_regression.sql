begin;

do $$
declare
  v_version constant text := '8600860086008600860086008600860086008600860086008600860086008600';
  v_status public.data_sync_sources;
begin
  insert into public.excel_fiscal_base_versions(
    source_version,source_updated_at,ncm_rule_count,group_rule_count
  ) values(v_version,now(),1,2)
  on conflict(source_version) do nothing;

  update public.data_sync_sources
  set connection_status='DEGRADED',last_error='TESTE_086'
  where source_code='EXCEL_API';

  insert into public.excel_fiscal_base_state(singleton,current_source_version,updated_at)
  values(true,v_version,now())
  on conflict(singleton) do update
  set current_source_version=excluded.current_source_version,updated_at=excluded.updated_at;
  select * into v_status from public.data_sync_sources where source_code='EXCEL_API';

  if v_status.connection_status<>'CONNECTED'
     or v_status.last_error is not null
     or v_status.public_metadata->>'fiscal_base_source_version'<>v_version
     or (v_status.public_metadata->>'fiscal_ncm_rules')::integer<>1
     or (v_status.public_metadata->>'fiscal_group_rules')::integer<>2 then
    raise exception 'SUCESSO_DA_BASE_NAO_ATUALIZOU_FONTE: %',to_jsonb(v_status);
  end if;
end;
$$;

rollback;
