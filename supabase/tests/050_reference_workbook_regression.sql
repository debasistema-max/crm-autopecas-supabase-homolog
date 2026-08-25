begin;

select set_config('request.jwt.claim.sub','0599a872-82f0-4bf5-a7b4-9f908f4bcc1b',true);

do $$
declare
  v_hash constant text := '19918d547beb8da80ead65f365f1908183fafb7fcb0454341e4d33d00ae5e03d';
  v_pr_pr jsonb := public.get_product_commercial_price('6111032201','PR','PR');
  v_sp_sp jsonb := public.get_product_commercial_price('6111032201','SP','SP');
  v_pr_sc jsonb := public.get_product_commercial_price('6111032201','PR','SC');
  v_duplicate jsonb;
  v_batch record;
begin
  if (select count(*) from public.products_import_batches
      where file_hash=v_hash and normalization_algorithm='sap-import-v3' and state='COMMITTED') <> 7 then
    raise exception 'QUANTIDADE_LOTES_REAIS_DIVERGENTE';
  end if;

  for v_batch in
    select * from public.products_import_batches
    where file_hash=v_hash and normalization_algorithm='sap-import-v3' and state='COMMITTED'
  loop
    v_duplicate := public.create_sap_import_batch(jsonb_build_object(
      'import_kind',v_batch.import_kind,
      'branch_code',coalesce(v_batch.region,'PR'),
      'file_hash',v_batch.file_hash,
      'original_filename',v_batch.original_filename,
      'sheet_name',v_batch.sheet_name,
      'file_size',v_batch.file_size,
      'source_name',v_batch.source_name,
      'detected_fields',to_jsonb(v_batch.detected_fields)
    ));
    if not coalesce((v_duplicate->>'duplicate')::boolean,false)
       or (v_duplicate->>'batch_id')::uuid <> v_batch.id then
      raise exception 'IDEMPOTENCIA_REAL_FALHOU PARA %: %',v_batch.import_kind,v_duplicate;
    end if;
  end loop;

  if abs((v_pr_pr->>'final_price')::numeric-347.854460)>0.000001
     or abs((v_sp_sp->>'final_price')::numeric-346.791931)>0.000001
     or abs((v_pr_sc->>'final_price')::numeric-263.900000)>0.000001 then
    raise exception 'REGRESSAO_FISCAL_REAL_DIVERGIU: PR-PR %, SP-SP %, PR-SC %',v_pr_pr,v_sp_sp,v_pr_sc;
  end if;
  if v_pr_pr->>'status'<>'OK' or v_sp_sp->>'status'<>'OK' or v_pr_sc->>'status'<>'OK_SEM_ST' then
    raise exception 'STATUS_FISCAL_REAL_DIVERGIU';
  end if;
  if v_sp_sp->>'availability'<>'ESTOQUE_NAO_IMPORTADO'
     or not (v_sp_sp->'warnings' ? 'ESTOQUE_NAO_IMPORTADO') then
    raise exception 'ESTOQUE_SP_VAZIO_FOI_TRATADO_COMO QUANTIDADE: %',v_sp_sp;
  end if;
  if (v_pr_pr->>'pis_amount') is not null or (v_pr_pr->>'cofins_amount') is not null
     or (v_pr_pr->>'fcp_amount') is not null then
    raise exception 'TRIBUTOS AUSENTES FORAM INVENTADOS: %',v_pr_pr;
  end if;
  if exists(select 1 from public.fiscal_tax_rules
      where ncm='84149020' and uf_origem='SP' and uf_destino='SP' and active) then
    raise exception 'REGRA SP INCOMPLETA FOI ATIVADA';
  end if;
  if coalesce((public.get_fiscal_pending(jsonb_build_object('limit',1))#>>'{summary,fiscal_source_rows_rejected}')::integer,0) < 1 then
    raise exception 'LINHA FISCAL REJEITADA NAO ESTA AUDITAVEL';
  end if;

  raise notice 'REFERENCE_WORKBOOK_REGRESSION_OK PR-PR=% SP-SP=% PR-SC=%',
    v_pr_pr->>'final_price',v_sp_sp->>'final_price',v_pr_sc->>'final_price';
end;
$$;

rollback;
