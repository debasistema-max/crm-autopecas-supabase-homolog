begin;

select set_config('request.jwt.claim.sub',(
  select id::text from public.profiles where perfil='ADMIN' and ativo order by created_at limit 1
),true);

do $$
declare
  v_admin uuid:=auth.uid();
  v_branch_pr uuid;
  v_batch uuid;
  v_source_at timestamptz:=clock_timestamp();
  v_result jsonb;
  v_document jsonb;
  v_item record;
begin
  if v_admin is null then raise exception 'ADMIN_ATIVO_NAO_ENCONTRADO'; end if;
  select id into v_branch_pr from public.branches where code='PR' and active limit 1;

  insert into public.products(codigo,descricao,ncm)
  values('9900000066','PRODUTO TESTE PRECO ROTA EXCEL','85122011')
  on conflict(codigo) do update set descricao=excluded.descricao,ncm=excluded.ncm;

  v_batch:=(public.create_data_sync_batch(jsonb_build_object(
    'source','EXCEL_API',
    'source_version','route-priority-066',
    'source_updated_at',v_source_at,
    'file_hash',repeat('6',64),
    'original_filename','route-priority-066.xlsx'
  ))->>'batch_id')::uuid;

  perform public.stage_data_sync_rows(v_batch,jsonb_build_array(
    jsonb_build_object(
      'row_number',1,'area','BASE_PRICE','product_code','9900000066','branch_code','PR',
      'fields',jsonb_build_object('base_price',500,'currency','BRL'),
      'field_mask',jsonb_build_array('base_price','currency')
    ),
    jsonb_build_object(
      'row_number',2,'area','ROUTE_PRICE','product_code','9900000066','route','PR-PR',
      'fields',jsonb_build_object(
        'base_price',500,'final_price',612.34,'total_taxes',112.34,
        'tax_breakdown',jsonb_build_object('ipi',20,'icms_proprio',60,'icms_st',32.34),
        'calculation_status','OK - REGRA GRUPO','currency','BRL'
      ),
      'field_mask',jsonb_build_array('base_price','final_price','total_taxes','tax_breakdown','calculation_status','currency')
    )
  ));
  perform public.validate_data_sync_batch(v_batch);
  perform public.commit_data_sync_batch(v_batch);

  insert into public.product_branch_stock(product_code,branch_id,physical_qty,sap_general_available_qty,source_batch_id,source_updated_at,version)
  values('9900000066',v_branch_pr,8,8,v_batch,v_source_at,1)
  on conflict(product_code,branch_id) do update set
    physical_qty=8,sap_general_available_qty=8,source_batch_id=v_batch,source_updated_at=v_source_at,version=1;

  v_result:=public.get_product_commercial_price('9900000066','PR','PR',current_date,'CONSUMO');
  if v_result->>'price_source'<>'EXCEL_ROUTE_PRICE'
     or v_result->>'customer_type'<>'REVENDA'
     or abs((v_result->>'final_price')::numeric-612.34)>0.000001
     or abs((v_result->>'total_taxes')::numeric-112.34)>0.000001
     or v_result->>'source_calculation_status'<>'OK - REGRA GRUPO' then
    raise exception 'PRECO_ROTA_EXCEL_NAO_PRIORIZADO: %',v_result;
  end if;

  v_document:=public.commercial_create_document('cotacao',jsonb_build_object(
    'regiao','PR','cliente_estado','PR','customer_type','CONSUMO','cliente','TESTE ROTA EXCEL',
    'items',jsonb_build_array(jsonb_build_object('codigo','9900000066','quantidade',1,'desconto_percentual',0))
  ));
  select * into v_item from public.quotation_items where quotation_id=(v_document->>'id')::uuid;
  if abs(v_item.preco_unitario-612.34)>0.000001
     or v_item.fiscal_details->>'price_source'<>'EXCEL_ROUTE_PRICE'
     or v_item.fiscal_details->>'customer_type'<>'REVENDA' then
    raise exception 'DOCUMENTO_NAO_PRESERVOU_PRECO_EXCEL_REVENDA: %',to_jsonb(v_item);
  end if;

  v_result:=public.get_product_commercial_price('9900000066','PR','RS',current_date,'REVENDA');
  if v_result->>'price_source'<>'FISCAL_FALLBACK_BLOCKED'
     or v_result->>'status'<>'PRECO_FISCAL_INDISPONIVEL'
     or v_result->'final_price' is distinct from 'null'::jsonb
     or not (v_result->'warnings' ? 'PRECO_ROTA_EXCEL_AUSENTE')
     or not (v_result->'warnings' ? 'FALLBACK_FISCAL_NAO_HOMOLOGADO') then
    raise exception 'CONTINGENCIA_NAO_FOI_BLOQUEADA: %',v_result;
  end if;
end;
$$;

rollback;
