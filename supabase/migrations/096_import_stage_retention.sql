begin;

-- Staging contains the temporary, row-level working copy of an import. Batch
-- summaries and products_import_audit remain authoritative and are never
-- deleted by this routine.
create or replace function public.maintain_products_import_stage(
  p_committed_retention_days integer default 14,
  p_failed_retention_days integer default 30,
  p_keep_recent_batches integer default 3,
  p_max_batches integer default 1,
  p_include_failed boolean default false,
  p_dry_run boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
set statement_timeout = '120s'
as $$
declare
  v_committed_cutoff timestamptz;
  v_failed_cutoff timestamptz;
  v_candidate_ids uuid[] := '{}'::uuid[];
  v_locked_ids uuid[] := '{}'::uuid[];
  v_batch_id uuid;
  v_candidate_batches integer := 0;
  v_candidate_stage_rows bigint := 0;
  v_audit_links bigint := 0;
  v_deleted_stage_rows bigint := 0;
begin
  if not (
    session_user in ('postgres', 'supabase_admin')
    or coalesce(auth.role(), '') = 'service_role'
    or coalesce(public.is_admin(), false)
  ) then
    raise exception 'SEM_PERMISSAO_MANTER_STAGING_IMPORTACAO';
  end if;

  if p_committed_retention_days is null
     or p_committed_retention_days < 7
     or p_committed_retention_days > 3650 then
    raise exception 'RETENCAO_COMMITTED_FORA_DO_INTERVALO_7_3650_DIAS';
  end if;
  if p_failed_retention_days is null
     or p_failed_retention_days < 30
     or p_failed_retention_days > 3650 then
    raise exception 'RETENCAO_FAILED_FORA_DO_INTERVALO_30_3650_DIAS';
  end if;
  if p_keep_recent_batches is null
     or p_keep_recent_batches < 0
     or p_keep_recent_batches > 100 then
    raise exception 'LOTES_RECENTES_FORA_DO_INTERVALO_0_100';
  end if;
  if p_max_batches is null or p_max_batches < 1 or p_max_batches > 100 then
    raise exception 'LIMITE_LOTES_FORA_DO_INTERVALO_1_100';
  end if;

  v_committed_cutoff := clock_timestamp() - make_interval(days => p_committed_retention_days);
  v_failed_cutoff := clock_timestamp() - make_interval(days => p_failed_retention_days);

  with ranked as (
    select
      b.id,
      b.state,
      coalesce(
        b.finished_at,
        b.committed_at,
        b.failed_at,
        b.last_attempt_completed_at,
        b.created_at
      ) as terminal_at,
      row_number() over (
        partition by
          coalesce(b.integration_source, ''),
          b.contract_version,
          coalesce(b.import_kind, ''),
          coalesce(b.branch_id::text, ''),
          b.state
        order by
          coalesce(
            b.finished_at,
            b.committed_at,
            b.failed_at,
            b.last_attempt_completed_at,
            b.created_at
          ) desc,
          b.id
      ) as retention_rank
    from public.products_import_batches b
    where b.state = 'COMMITTED'
       or (p_include_failed and b.state = 'FAILED')
  ), eligible as (
    select r.id, r.terminal_at
    from ranked r
    where r.retention_rank > p_keep_recent_batches
      and (
        (r.state = 'COMMITTED' and r.terminal_at < v_committed_cutoff)
        or
        (p_include_failed and r.state = 'FAILED' and r.terminal_at < v_failed_cutoff)
      )
      and exists (
        select 1
        from public.products_import_stage s
        where s.batch_id = r.id
      )
    order by r.terminal_at, r.id
    limit p_max_batches
  )
  select coalesce(array_agg(e.id order by e.terminal_at, e.id), '{}'::uuid[])
  into v_candidate_ids
  from eligible e;

  if not coalesce(p_dry_run, true) then
    -- Lock and revalidate each batch immediately before deletion. A batch that
    -- moved back to an active state is skipped rather than partially cleaned.
    for v_batch_id in
      select b.id
      from public.products_import_batches b
      where b.id = any(v_candidate_ids)
        and (
          (
            b.state = 'COMMITTED'
            and coalesce(
              b.finished_at,
              b.committed_at,
              b.failed_at,
              b.last_attempt_completed_at,
              b.created_at
            ) < v_committed_cutoff
          )
          or
          (
            p_include_failed
            and b.state = 'FAILED'
            and coalesce(
              b.finished_at,
              b.committed_at,
              b.failed_at,
              b.last_attempt_completed_at,
              b.created_at
            ) < v_failed_cutoff
          )
        )
      order by array_position(v_candidate_ids, b.id)
      for update of b skip locked
    loop
      v_locked_ids := array_append(v_locked_ids, v_batch_id);
    end loop;
    v_candidate_ids := v_locked_ids;
  end if;

  v_candidate_batches := cardinality(v_candidate_ids);

  select count(*)
  into v_candidate_stage_rows
  from public.products_import_stage s
  where s.batch_id = any(v_candidate_ids);

  select count(*)
  into v_audit_links
  from public.products_import_audit a
  where a.stage_id in (
    select s.id
    from public.products_import_stage s
    where s.batch_id = any(v_candidate_ids)
  );

  if not coalesce(p_dry_run, true) and v_candidate_batches > 0 then
    delete from public.products_import_stage s
    where s.batch_id = any(v_candidate_ids);
    get diagnostics v_deleted_stage_rows = row_count;
  end if;

  return jsonb_build_object(
    'dry_run', coalesce(p_dry_run, true),
    'committed_retention_days', p_committed_retention_days,
    'failed_retention_days', p_failed_retention_days,
    'include_failed', p_include_failed,
    'keep_recent_batches_per_source', p_keep_recent_batches,
    'max_batches', p_max_batches,
    'candidate_batches', v_candidate_batches,
    'candidate_stage_rows', v_candidate_stage_rows,
    'audit_stage_links_preserved', v_audit_links,
    'deleted_stage_rows', v_deleted_stage_rows,
    'batch_ids', to_jsonb(v_candidate_ids),
    'batches_deleted', 0,
    'audit_rows_deleted', 0
  );
end;
$$;

revoke all on function public.maintain_products_import_stage(integer, integer, integer, integer, boolean, boolean)
  from public, anon;
grant execute on function public.maintain_products_import_stage(integer, integer, integer, integer, boolean, boolean)
  to authenticated, service_role;

comment on function public.maintain_products_import_stage(integer, integer, integer, integer, boolean, boolean)
  is 'Simula ou remove somente staging de lotes terminais antigos. Preserva batches e auditoria; dry-run e lotes COMMITTED sao o padrao.';

commit;
