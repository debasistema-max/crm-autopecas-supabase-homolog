begin;

-- A successful fiscal-base confirmation is also a successful contact with the
-- workbook executor. This must refresh the source even when the operational
-- batch is an idempotent duplicate and therefore creates no new batch row.
create or replace function public.mark_excel_fiscal_base_sync_success()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_version public.excel_fiscal_base_versions;
begin
  select * into v_version
  from public.excel_fiscal_base_versions
  where source_version=new.current_source_version;

  update public.data_sync_sources
  set connection_status='CONNECTED',
      last_seen_at=now(),
      last_success_at=now(),
      last_error=null,
      public_metadata=coalesce(public_metadata,'{}'::jsonb)||jsonb_build_object(
        'fiscal_base_source_version',new.current_source_version,
        'fiscal_base_source_updated_at',v_version.source_updated_at,
        'fiscal_base_confirmed_at',now(),
        'fiscal_ncm_rules',v_version.ncm_rule_count,
        'fiscal_group_rules',v_version.group_rule_count
      ),
      updated_at=now()
  where source_code='EXCEL_API';
  return new;
end;
$$;

revoke all on function public.mark_excel_fiscal_base_sync_success() from public,anon,authenticated;

drop trigger if exists excel_fiscal_base_sync_success on public.excel_fiscal_base_state;
create trigger excel_fiscal_base_sync_success
after insert or update on public.excel_fiscal_base_state
for each row execute function public.mark_excel_fiscal_base_sync_success();

comment on function public.mark_excel_fiscal_base_sync_success()
  is 'Confirma a conectividade do executor após publicar ou revalidar atomicamente as bases fiscais do Excel.';

commit;
