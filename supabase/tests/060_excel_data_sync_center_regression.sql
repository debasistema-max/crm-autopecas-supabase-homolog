begin;

select set_config('request.jwt.claim.sub',(
  select id::text from public.profiles where perfil='ADMIN' and ativo order by created_at limit 1
),true);

do $$
declare
  v_admin uuid := auth.uid();
  v_batch uuid;
  v_duplicate jsonb;
  v_result jsonb;
  v_branch_sp uuid;
  v_source_at timestamptz;
  v_price numeric;
begin
  if v_admin is null then raise exception 'ADMIN_ATIVO_NAO_ENCONTRADO'; end if;

  update public.profiles set perfil='VENDEDOR' where id=v_admin;
  if public.can_manage_data_sync() then raise exception 'VENDEDOR_PODE_SINCRONIZAR'; end if;
  update public.profiles set perfil='ADMIN' where id=v_admin;
  if not public.can_manage_data_sync() then raise exception 'ADMIN_NAO_PODE_SINCRONIZAR'; end if;
  if has_function_privilege('anon','public.create_data_sync_batch(jsonb)','execute') then
    raise exception 'ANON_PODE_CRIAR_LOTE';
  end if;

  if public.normalize_integration_product_code(' 6111032201 ') <> '6111032201'
     or public.normalize_integration_product_code('6111032201.0') <> '6111032201'
     or public.normalize_integration_product_code('6.111032201E+9') <> '6111032201' then
    raise exception 'NORMALIZACAO_CODIGO_FALHOU';
  end if;

  select id into v_branch_sp from public.branches where code='SP' and active;
  insert into public.products(codigo,descricao) values('SYNC-060-SP','PRODUTO SP PRESERVADO')
  on conflict(codigo) do update set descricao=excluded.descricao;
  insert into public.product_branch_stock(product_code,branch_id,physical_qty,updated_by)
  values('SYNC-060-SP',v_branch_sp,9,v_admin)
  on conflict(product_code,branch_id) do update set physical_qty=9,updated_by=v_admin;

  v_source_at:=clock_timestamp();
  v_batch:=(public.create_data_sync_batch(jsonb_build_object(
    'source','EXCEL_API','source_version','sync-060-v1','source_updated_at',v_source_at,
    'file_hash',repeat('a',64),'original_filename','excel-master-v1.xlsx'
  ))->>'batch_id')::uuid;
  perform public.stage_data_sync_rows(v_batch,jsonb_build_array(
    jsonb_build_object('row_number',1,'area','PRODUCT','product_code',' 6111032201.0 ',
      'fields',jsonb_build_object('description','PRODUTO DATA SYNC','brand','','ncm','8512.20.11','ipi_rate',0),
      'field_mask',jsonb_build_array('description','brand','ncm','ipi_rate')),
    jsonb_build_object('row_number',2,'area','STOCK','product_code','6111032201','branch_code','PR',
      'fields',jsonb_build_object('stock_qty',0,'general_available_qty',0),
      'field_mask',jsonb_build_array('stock_qty','general_available_qty')),
    jsonb_build_object('row_number',3,'area','BASE_PRICE','product_code','6111032201','branch_code','PR',
      'fields',jsonb_build_object('base_price',580,'currency','BRL')),
    jsonb_build_object('row_number',4,'area','ROUTE_PRICE','product_code','6111032201','route','PR-PR',
      'fields',jsonb_build_object('base_price',580,'final_price',700,'total_taxes',120,
        'tax_breakdown',jsonb_build_object('ipi',20),'calculation_status','OK','currency','BRL')),
    jsonb_build_object('row_number',5,'area','STOCK','product_code','6111032201','branch_code','XX',
      'fields',jsonb_build_object('stock_qty',3)),
    jsonb_build_object('row_number',6,'area','BASE_PRICE','product_code','6111032201','branch_code','SP',
      'fields',jsonb_build_object('base_price','=A1'))
  ));
  v_result:=public.validate_data_sync_batch(v_batch);
  if v_result->>'state'<>'PREVIEWED' or (v_result->>'error_count')::integer<>2 then
    raise exception 'VALIDACAO_PARCIAL_FALHOU: %',v_result;
  end if;
  v_result:=public.commit_data_sync_batch(v_batch);
  if v_result->>'status'<>'completed_with_errors' then raise exception 'STATUS_PARCIAL_INCORRETO: %',v_result; end if;
  if not exists(select 1 from public.products where codigo='6111032201' and descricao='PRODUTO DATA SYNC' and ncm='85122011' and ipi_rate=0) then
    raise exception 'PRODUTO_NAO_SINCRONIZADO';
  end if;
  if not exists(select 1 from public.product_branch_stock s join public.branches b on b.id=s.branch_id
    where s.product_code='6111032201' and b.code='PR' and s.physical_qty=0 and s.sap_general_available_qty=0) then
    raise exception 'ZERO_EXPLICITO_NAO_APLICADO';
  end if;
  if not exists(select 1 from public.product_branch_prices p join public.branches b on b.id=p.branch_id
    where p.product_code='6111032201' and b.code='PR' and p.sale_price=580) then raise exception 'PRECO_BASE_NAO_APLICADO'; end if;
  if not exists(select 1 from public.product_route_prices where product_code='6111032201' and route='PR-PR' and final_price=700) then
    raise exception 'PRECO_ROTA_NAO_APLICADO';
  end if;
  if exists(select 1 from public.products_import_audit where batch_id=v_batch and field_name='*')
     or not exists(select 1 from public.products_import_audit where batch_id=v_batch and field_name='final_price' and old_value is distinct from new_value) then
    raise exception 'AUDITORIA_CAMPO_A_CAMPO_FALHOU';
  end if;
  if (select physical_qty from public.product_branch_stock where product_code='SYNC-060-SP' and branch_id=v_branch_sp)<>9 then
    raise exception 'ABA_SP_AUSENTE_ZEROU_ESTOQUE';
  end if;

  v_duplicate:=public.create_data_sync_batch(jsonb_build_object(
    'source','EXCEL_API','source_version','sync-060-v1','source_updated_at',v_source_at,
    'file_hash',repeat('a',64),'original_filename','retry.xlsx'));
  if not (v_duplicate->>'duplicate')::boolean or (v_duplicate->>'batch_id')::uuid<>v_batch then
    raise exception 'IDEMPOTENCIA_FALHOU: %',v_duplicate;
  end if;

  -- Stock-only update: price and product fields remain untouched; SYNC_ERP records an absolute snapshot delta.
  v_source_at:=clock_timestamp();
  v_batch:=(public.create_data_sync_batch(jsonb_build_object(
    'source','EXCEL_API','source_version','sync-060-v2','source_updated_at',v_source_at,'file_hash',repeat('b',64)
  ))->>'batch_id')::uuid;
  perform public.stage_data_sync_rows(v_batch,jsonb_build_array(jsonb_build_object(
    'row_number',1,'area','STOCK','product_code','6111032201','branch_code','PR',
    'fields',jsonb_build_object('stock_qty',5),'field_mask',jsonb_build_array('stock_qty')
  )));
  perform public.validate_data_sync_batch(v_batch); perform public.commit_data_sync_batch(v_batch);
  if not exists(select 1 from public.stock_movements where reference_id=v_batch and movement_type='SYNC_ERP' and physical_delta=5) then
    raise exception 'MOVIMENTO_SYNC_ERP_AUSENTE';
  end if;
  if not exists(select 1 from public.product_branch_prices p join public.branches b on b.id=p.branch_id
    where p.product_code='6111032201' and b.code='PR' and p.sale_price=580) then raise exception 'ESTOQUE_ALTEROU_PRECO'; end if;

  -- No-change detection avoids version increments and audit writes.
  v_source_at:=clock_timestamp();
  v_batch:=(public.create_data_sync_batch(jsonb_build_object(
    'source','EXCEL_API','source_version','sync-060-v3','source_updated_at',v_source_at,'file_hash',repeat('c',64)
  ))->>'batch_id')::uuid;
  perform public.stage_data_sync_rows(v_batch,jsonb_build_array(jsonb_build_object(
    'row_number',1,'area','BASE_PRICE','product_code','6111032201','branch_code','PR',
    'fields',jsonb_build_object('base_price',580),'field_mask',jsonb_build_array('base_price')
  )));
  perform public.validate_data_sync_batch(v_batch); v_result:=public.commit_data_sync_batch(v_batch);
  if (v_result->>'unchanged_rows')::integer<>1 or exists(select 1 from public.products_import_audit where batch_id=v_batch) then
    raise exception 'SEM_ALTERACAO_GEROU_WRITE: %',v_result;
  end if;

  -- Empty does not clear; explicit clear does.
  v_source_at:=clock_timestamp();
  v_batch:=(public.create_data_sync_batch(jsonb_build_object(
    'source','EXCEL_API','source_version','sync-060-v4','source_updated_at',v_source_at,'file_hash',repeat('d',64)
  ))->>'batch_id')::uuid;
  perform public.stage_data_sync_rows(v_batch,jsonb_build_array(jsonb_build_object(
    'row_number',1,'area','PRODUCT','product_code','6111032201','fields',jsonb_build_object('description',''),
    'field_mask',jsonb_build_array('description'))));
  perform public.validate_data_sync_batch(v_batch); perform public.commit_data_sync_batch(v_batch);
  if (select descricao from public.products where codigo='6111032201')<>'PRODUTO DATA SYNC' then raise exception 'VAZIO_APAGOU_DESCRICAO'; end if;

  v_source_at:=clock_timestamp();
  v_batch:=(public.create_data_sync_batch(jsonb_build_object(
    'source','EXCEL_API','source_version','sync-060-v5','source_updated_at',v_source_at,'file_hash',repeat('e',64)
  ))->>'batch_id')::uuid;
  perform public.stage_data_sync_rows(v_batch,jsonb_build_array(jsonb_build_object(
    'row_number',1,'area','PRODUCT','product_code','6111032201','fields',jsonb_build_object('brand',null),
    'field_mask',jsonb_build_array('brand'),'clear_fields',jsonb_build_array('brand'))));
  perform public.validate_data_sync_batch(v_batch); perform public.commit_data_sync_batch(v_batch);
  if (select marca from public.products where codigo='6111032201') is not null then raise exception 'LIMPEZA_EXPLICITA_FALHOU'; end if;

  -- Old source event cannot overwrite a newer stored value.
  v_batch:=(public.create_data_sync_batch(jsonb_build_object(
    'source','EXCEL_API','source_version','sync-060-old','source_updated_at','2000-01-01T00:00:00Z','file_hash',repeat('f',64)
  ))->>'batch_id')::uuid;
  perform public.stage_data_sync_rows(v_batch,jsonb_build_array(jsonb_build_object(
    'row_number',1,'area','BASE_PRICE','product_code','6111032201','branch_code','PR',
    'fields',jsonb_build_object('base_price',1),'field_mask',jsonb_build_array('base_price')
  )));
  perform public.validate_data_sync_batch(v_batch); perform public.commit_data_sync_batch(v_batch);
  select p.sale_price into v_price from public.product_branch_prices p join public.branches b on b.id=p.branch_id
  where p.product_code='6111032201' and b.code='PR';
  if v_price<>580 then raise exception 'LOTE_ANTIGO_SOBRESCREVEU_PRECO: %',v_price; end if;

  -- Optimistic concurrency catches a manual edit between preview and commit.
  v_source_at:=clock_timestamp();
  v_batch:=(public.create_data_sync_batch(jsonb_build_object(
    'source','EXCEL_API','source_version','sync-060-v6','source_updated_at',v_source_at,'file_hash',repeat('1',64)
  ))->>'batch_id')::uuid;
  perform public.stage_data_sync_rows(v_batch,jsonb_build_array(jsonb_build_object(
    'row_number',1,'area','BASE_PRICE','product_code','6111032201','branch_code','PR',
    'fields',jsonb_build_object('base_price',590),'field_mask',jsonb_build_array('base_price')
  )));
  perform public.validate_data_sync_batch(v_batch);
  update public.product_branch_prices set sale_price=610,source='MANUAL',source_batch_id=null,updated_by=v_admin
  where product_code='6111032201' and branch_id=(select id from public.branches where code='PR');
  v_result:=public.commit_data_sync_batch(v_batch);
  if (select sale_price from public.product_branch_prices where product_code='6111032201'
    and branch_id=(select id from public.branches where code='PR'))<>610 then raise exception 'CONCORRENCIA_SOBRESCREVEU_MANUAL'; end if;
  if v_result->>'status'<>'completed_with_errors' then raise exception 'CONFLITO_NAO_REPORTADO: %',v_result; end if;

  if (public.get_data_sync_status(jsonb_build_object('source','EXCEL_API'))#>>'{last_batch,id}')::uuid<>v_batch then
    raise exception 'STATUS_NAO_REFLETE_ULTIMO_LOTE';
  end if;
  if jsonb_array_length(public.list_data_sync_errors(jsonb_build_object('batch_id',v_batch))->'rows')=0 then
    raise exception 'LOG_ERROS_VAZIO';
  end if;
  v_result:=public.mark_data_sync_source_failure('EXCEL_API','ADAPTER_INDISPONIVEL_TESTE');
  if v_result#>>'{source,connection_status}'<>'DEGRADED' or (v_result->>'connected')::boolean then
    raise exception 'FALHA_DO_ADAPTER_NAO_DEGRADOU_FONTE: %',v_result;
  end if;
  raise notice 'DATA_SYNC_060_REGRESSION_OK';
end;
$$;

rollback;
