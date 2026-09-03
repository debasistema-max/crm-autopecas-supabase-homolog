begin;

select set_config('request.jwt.claim.sub','0599a872-82f0-4bf5-a7b4-9f908f4bcc1b',true);

do $$
declare
  v_admin uuid := '0599a872-82f0-4bf5-a7b4-9f908f4bcc1b';
  v_batch uuid;
  v_result jsonb;
begin
  update public.profiles set perfil='ADMIN' where id=v_admin;

  v_batch := (public.create_sap_import_batch(jsonb_build_object(
    'import_kind','COMMERCIAL_PRODUCTS','file_hash',repeat('1',64),'original_filename','cadastro-comercial.csv',
    'detected_fields',jsonb_build_array('product_code','description','brand','application','year')
  ))->>'batch_id')::uuid;
  perform public.stage_sap_import_rows(v_batch,jsonb_build_array(jsonb_build_object('row_number',1,'data',jsonb_build_object(
    'product_code','6111032202','description','PRODUTO COMERCIAL TEST','brand','IPS','application','TESTE','year','2020+'
  ))));
  perform public.validate_sap_import_batch(v_batch); perform public.approve_sap_import_batch(v_batch); perform public.commit_sap_import_batch(v_batch);
  if not exists(select 1 from public.products where codigo='6111032202' and descricao='PRODUTO COMERCIAL TEST') then
    raise exception 'CADASTRO_COMERCIAL_FALHOU';
  end if;

  v_batch := (public.create_sap_import_batch(jsonb_build_object(
    'import_kind','STOCK_SP','file_hash',repeat('2',64),'original_filename','estoque-sp.tsv',
    'detected_fields',jsonb_build_array('product_code','general_available_qty')
  ))->>'batch_id')::uuid;
  perform public.stage_sap_import_rows(v_batch,jsonb_build_array(jsonb_build_object('row_number',1,'data',jsonb_build_object(
    'product_code','6111032202','stock_qty',18,'confirmed_qty',2,'sales_available_qty',16,
    'authorized_pending_qty',1,'general_available_qty',15,'general_available_capped',false,'source_display_value','15'
  ))));
  perform public.validate_sap_import_batch(v_batch); perform public.approve_sap_import_batch(v_batch); perform public.commit_sap_import_batch(v_batch);
  if not exists(select 1 from public.product_branch_stock s join public.branches b on b.id=s.branch_id
    where s.product_code='6111032202' and b.code='SP' and s.sap_general_available_qty=15 and not s.available_qty_capped) then
    raise exception 'ESTOQUE_SP_FALHOU';
  end if;

  v_batch := (public.create_sap_import_batch(jsonb_build_object(
    'import_kind','BASE_PRICE_SP','file_hash',repeat('3',64),'original_filename','preco-sp.xlsx',
    'detected_fields',jsonb_build_array('product_code','base_price')
  ))->>'batch_id')::uuid;
  perform public.stage_sap_import_rows(v_batch,jsonb_build_array(jsonb_build_object('row_number',1,'data',jsonb_build_object(
    'product_code','6111032202','base_price','R$ 232,00'
  ))));
  perform public.validate_sap_import_batch(v_batch); perform public.approve_sap_import_batch(v_batch); perform public.commit_sap_import_batch(v_batch);
  if not exists(select 1 from public.product_branch_prices p join public.branches b on b.id=p.branch_id
    where p.product_code='6111032202' and b.code='SP' and p.sale_price=232) then
    raise exception 'PRECO_SP_FALHOU';
  end if;

  update public.products set ncm='85122011',cest='0100100',ipi_rate=0.0975,ipi_defined=true where codigo='6111032202';
  -- Isola o teste das regras reais vigentes. O rollback restaura o estado original.
  update public.fiscal_tax_rules
     set active=false
   where ncm='85122011'
     and uf_origem='SP'
     and uf_destino='SP'
     and operation_type='VENDA'
     and customer_type='GERAL'
     and active;

  v_batch := (public.create_sap_import_batch(jsonb_build_object(
    'import_kind','FISCAL_RULES_SP','file_hash',repeat('4',64),'original_filename','fiscal-sp.csv',
    'detected_fields',jsonb_build_array('ncm','destination_state','interstate_icms_rate','internal_icms_rate','mva_rate','ipi_rate','has_st')
  ))->>'batch_id')::uuid;
  perform public.stage_sap_import_rows(v_batch,jsonb_build_array(jsonb_build_object('row_number',1,'data',jsonb_build_object(
    'ncm','8512.20.11','destination_state','SP','interstate_icms_rate',0.04,'internal_icms_rate',0.18,
    'mva_rate',1.0111,'ipi_rate',0.0975,'pis_rate',0,'cofins_rate',0,'fcp_rate',0,'has_st',true
  ))));
  perform public.validate_sap_import_batch(v_batch); perform public.approve_sap_import_batch(v_batch); perform public.commit_sap_import_batch(v_batch);
  v_result:=public.get_product_commercial_price('6111032202','SP','SP');
  if v_result->>'status'<>'OK' or round((v_result->>'final_price')::numeric,6)<>346.791931 then
    raise exception 'FISCAL_SP_FALHOU: %',v_result;
  end if;

  if (select count(*) from public.products_import_audit where batch_id=v_batch and entity_type='FISCAL_RULE')<>1 then
    raise exception 'AUDITORIA_SP_FALHOU';
  end if;
  raise notice 'ALL_IMPORT_TYPES_REGRESSION_OK';
end;
$$;

rollback;
