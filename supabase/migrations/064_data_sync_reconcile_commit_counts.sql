begin;

set local lock_timeout = '10s';
set local statement_timeout = '110s';

-- Preserve the dependency-safe implementation from 063 as an internal core.
-- The guard makes this migration safe to re-run during local recovery.
do $$
begin
  if to_regprocedure('public.commit_data_sync_batch_chunk_core(uuid,integer)') is null then
    alter function public.commit_data_sync_batch_chunk(uuid,integer)
      rename to commit_data_sync_batch_chunk_core;
  end if;
end;
$$;

create or replace function public.reconcile_data_sync_batch_counts(target_batch_id uuid)
returns void
language plpgsql
security definer
set search_path = public
set statement_timeout = '110s'
as $$
declare
  v_total integer;
  v_valid integer;
  v_invalid integer;
  v_unchanged integer;
  v_stale integer;
  v_warning_count integer;
begin
  select
    count(*)::integer,
    count(*) filter (where status in ('valid','warning','committed'))::integer,
    count(*) filter (where status = 'error')::integer,
    count(*) filter (where planned_action = 'NO_CHANGE')::integer,
    count(*) filter (where skip_reason = 'STALE_SOURCE_EVENT')::integer,
    coalesce(sum(jsonb_array_length(coalesce(warnings,'[]'::jsonb))),0)::integer
  into v_total, v_valid, v_invalid, v_unchanged, v_stale, v_warning_count
  from public.products_import_stage
  where batch_id = target_batch_id;

  update public.products_import_batches
  set total_rows = v_total,
      valid_rows = v_valid,
      invalid_rows = v_invalid,
      error_count = v_invalid,
      warning_count = v_warning_count,
      unchanged_rows = v_unchanged,
      stale_rows = v_stale,
      ignored_rows = v_invalid + v_stale,
      summary = summary || jsonb_build_object(
        'valid',v_valid,
        'invalid',v_invalid,
        'unchanged',v_unchanged,
        'stale',v_stale,
        'ignored',v_invalid + v_stale,
        'counts_reconciled_at',now()
      )
  where id = target_batch_id
    and contract_version = 3
    and state = 'COMMITTED';
end;
$$;

create or replace function public.commit_data_sync_batch_chunk(
  target_batch_id uuid,
  chunk_size integer default 500
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '110s'
as $$
declare
  v_result jsonb;
  v_state text;
begin
  if not public.can_manage_data_sync() then
    raise exception 'SEM_PERMISSAO_SINCRONIZAR';
  end if;

  v_result := public.commit_data_sync_batch_chunk_core(target_batch_id,chunk_size);

  select state into v_state
  from public.products_import_batches
  where id = target_batch_id and contract_version = 3;

  if v_state = 'COMMITTED' then
    perform public.reconcile_data_sync_batch_counts(target_batch_id);
    v_result := v_result || jsonb_build_object(
      'done',true,
      'batch',public.get_data_sync_batch(target_batch_id)
    );
  end if;

  return v_result;
end;
$$;

-- Reconcile any v3 batch completed before this fix whose dependency errors
-- were classified during commit rather than during preview.
do $$
declare
  v_batch_id uuid;
begin
  for v_batch_id in
    select b.id
    from public.products_import_batches b
    where b.contract_version = 3
      and b.state = 'COMMITTED'
      and (
        b.total_rows <> (
          select count(*) from public.products_import_stage s where s.batch_id = b.id
        )
        or b.valid_rows <> (
          select count(*) from public.products_import_stage s
          where s.batch_id = b.id and s.status in ('valid','warning','committed')
        )
        or b.invalid_rows <> (
          select count(*) from public.products_import_stage s
          where s.batch_id = b.id and s.status = 'error'
        )
      )
  loop
    perform public.reconcile_data_sync_batch_counts(v_batch_id);
  end loop;
end;
$$;

revoke all on function public.commit_data_sync_batch_chunk_core(uuid,integer)
  from public,anon,authenticated,service_role;
revoke all on function public.reconcile_data_sync_batch_counts(uuid)
  from public,anon,authenticated,service_role;
revoke all on function public.commit_data_sync_batch_chunk(uuid,integer)
  from public,anon;

grant execute on function public.commit_data_sync_batch_chunk(uuid,integer)
  to authenticated,service_role;

comment on function public.reconcile_data_sync_batch_counts(uuid) is
  'Recalcula contadores do lote a partir do estágio após classificações feitas durante o commit.';
comment on function public.commit_data_sync_batch_chunk(uuid,integer) is
  'Executa o commit seguro em blocos e reconcilia os contadores ao concluir.';

commit;
