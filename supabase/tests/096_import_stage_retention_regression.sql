begin;

do $$
declare
  v_committed_batch uuid := gen_random_uuid();
  v_active_batch uuid := gen_random_uuid();
  v_committed_stage uuid := gen_random_uuid();
  v_active_stage uuid := gen_random_uuid();
  v_preview jsonb;
  v_execution jsonb;
begin
  insert into public.products_import_batches(
    id, created_at, import_type, source_name, state, status, summary
  ) values
    (
      v_committed_batch,
      now() - interval '60 days',
      'RETENTION_TEST',
      'TEST_096',
      'COMMITTED',
      'completed',
      '{}'::jsonb
    ),
    (
      v_active_batch,
      now() - interval '60 days',
      'RETENTION_TEST',
      'TEST_096',
      'DRAFT',
      'draft',
      '{}'::jsonb
    );

  insert into public.products_import_stage(
    id, batch_id, row_number, codigo, raw_data, normalized_data, status
  ) values
    (v_committed_stage, v_committed_batch, 1, 'RET-096-C', '{}'::jsonb, '{}'::jsonb, 'committed'),
    (v_active_stage, v_active_batch, 1, 'RET-096-A', '{}'::jsonb, '{}'::jsonb, 'pending');

  insert into public.products_import_audit(
    batch_id, stage_id, codigo, action, before_data, after_data
  ) values (
    v_committed_batch,
    v_committed_stage,
    'RET-096-C',
    'UPDATE',
    '{"stock": 1}'::jsonb,
    '{"stock": 2}'::jsonb
  );

  select public.maintain_products_import_stage(7, 30, 0, 10, false, true)
  into v_preview;

  if (v_preview->>'candidate_batches')::integer <> 1
     or (v_preview->>'candidate_stage_rows')::integer <> 1
     or (v_preview->>'deleted_stage_rows')::integer <> 0 then
    raise exception 'DRY_RUN_INCORRETO: %', v_preview;
  end if;
  if not exists(select 1 from public.products_import_stage where id = v_committed_stage) then
    raise exception 'DRY_RUN_REMOVEU_STAGING';
  end if;

  select public.maintain_products_import_stage(7, 30, 0, 10, false, false)
  into v_execution;

  if (v_execution->>'deleted_stage_rows')::integer <> 1 then
    raise exception 'EXECUCAO_NAO_REMOVEU_STAGING_ESPERADO: %', v_execution;
  end if;
  if exists(select 1 from public.products_import_stage where id = v_committed_stage) then
    raise exception 'STAGING_TERMINAL_NAO_REMOVIDO';
  end if;
  if not exists(select 1 from public.products_import_stage where id = v_active_stage) then
    raise exception 'STAGING_ATIVO_FOI_REMOVIDO';
  end if;
  if not exists(select 1 from public.products_import_batches where id = v_committed_batch) then
    raise exception 'RESUMO_DO_LOTE_FOI_REMOVIDO';
  end if;
  if not exists(
    select 1
    from public.products_import_audit
    where batch_id = v_committed_batch and stage_id is null
  ) then
    raise exception 'AUDITORIA_NAO_FOI_PRESERVADA';
  end if;
end;
$$;

do $$
begin
  if has_function_privilege(
    'anon',
    'public.maintain_products_import_stage(integer,integer,integer,integer,boolean,boolean)',
    'EXECUTE'
  ) then
    raise exception 'ANON_NAO_DEVERIA_EXECUTAR_RETENCAO';
  end if;
  if not has_function_privilege(
    'authenticated',
    'public.maintain_products_import_stage(integer,integer,integer,integer,boolean,boolean)',
    'EXECUTE'
  ) then
    raise exception 'AUTHENTICATED_DEVERIA_TER_ACESSO_A_RPC_PROTEGIDA';
  end if;
end;
$$;

rollback;
