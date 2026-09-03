begin;

select set_config('request.jwt.claim.sub','0599a872-82f0-4bf5-a7b4-9f908f4bcc1b',true);

do $$
declare
  v_admin uuid := '0599a872-82f0-4bf5-a7b4-9f908f4bcc1b';
  v_batch uuid;
  v_duplicate jsonb;
  v_original_ncm text;
  v_quote_id uuid;
  v_order_id uuid;
  v_document jsonb;
begin
  update public.profiles set perfil='VENDEDOR' where id=v_admin;
  if public.can_stage_sap_import() then raise exception 'VENDEDOR_NAO_PODE_IMPORTAR'; end if;
  update public.profiles set perfil='SUPERVISOR' where id=v_admin;
  if public.can_commit_sap_import('STOCK_PR') then raise exception 'SUPERVISOR_SEM_PERMISSAO_NAO_PODE_CONFIRMAR'; end if;
  update public.role_permissions set permitido=true where perfil='SUPERVISOR' and modulo in ('importar_estoque_preco','aprovar_importacao');
  if not public.can_commit_sap_import('STOCK_PR') then raise exception 'SUPERVISOR_AUTORIZADO_DEVE_CONFIRMAR_ESTOQUE'; end if;
  if public.can_commit_sap_import('FISCAL_RULES_PR') then raise exception 'SUPERVISOR_NAO_PODE_CONFIRMAR_FISCAL'; end if;
  update public.profiles set perfil='ADMIN' where id=v_admin;

  v_batch := (public.create_sap_import_batch(jsonb_build_object(
    'import_kind','SAP_ITEM_MASTER','branch_code','PR','file_hash',repeat('a',64),'original_filename','cadastro-item-sap.csv',
    'detected_fields',jsonb_build_array('product_code','description','ncm','cest','ipi_rate')
  ))->>'batch_id')::uuid;
  perform public.stage_sap_import_rows(v_batch,jsonb_build_array(jsonb_build_object('row_number',1,'data',jsonb_build_object(
    'product_code','6111032201','description','PRODUTO IMPORT TEST','brand','TEST','ncm','85122011','cest','0100100','ipi_rate',0.0975,
    'manufacturer','TEST FAB','oem_01','OEM-1'
  ))));
  if public.validate_sap_import_batch(v_batch)#>>'{batch,state}' <> 'PREVIEWED' then raise exception 'CADASTRO_SAP_PREVIEW_FALHOU'; end if;
  perform public.approve_sap_import_batch(v_batch); perform public.commit_sap_import_batch(v_batch);
  if not exists(select 1 from public.products where codigo='6111032201' and ncm='85122011' and cest='0100100' and ipi_defined) then raise exception 'CADASTRO_SAP_COMMIT_FALHOU'; end if;
  if not exists(select 1 from public.product_sap_data where product_code='6111032201' and manufacturer='TEST FAB') then raise exception 'DADOS_SAP_NAO_GRAVADOS'; end if;

  v_duplicate:=public.create_sap_import_batch(jsonb_build_object('import_kind','SAP_ITEM_MASTER','branch_code','PR','file_hash',repeat('a',64),
    'original_filename','cadastro-item-sap.csv','detected_fields',jsonb_build_array('product_code','description')));
  if not coalesce((v_duplicate->>'duplicate')::boolean,false) or (v_duplicate->>'batch_id')::uuid<>v_batch then raise exception 'IDEMPOTENCIA_FALHOU: %',v_duplicate; end if;

  v_original_ncm:=(select ncm from public.products where codigo='6111032201');
  v_batch := (public.create_sap_import_batch(jsonb_build_object('import_kind','SAP_ITEM_MASTER','branch_code','PR','file_hash',repeat('e',64),
    'original_filename','cadastro-sem-ncm.csv','detected_fields',jsonb_build_array('product_code','description','brand')))->>'batch_id')::uuid;
  perform public.stage_sap_import_rows(v_batch,jsonb_build_array(jsonb_build_object('row_number',1,'data',jsonb_build_object(
    'product_code','6111032201','description','PRODUTO IMPORT TEST','brand','NOVA MARCA'))));
  perform public.validate_sap_import_batch(v_batch); perform public.approve_sap_import_batch(v_batch); perform public.commit_sap_import_batch(v_batch);
  if (select ncm from public.products where codigo='6111032201') is distinct from v_original_ncm then raise exception 'CAMPO_VAZIO_APAGOU_NCM'; end if;

  v_batch := (public.create_sap_import_batch(jsonb_build_object('import_kind','STOCK_PR','file_hash',repeat('b',64),
    'original_filename','estoque-pr.csv','detected_fields',jsonb_build_array('product_code','general_available_qty')))->>'batch_id')::uuid;
  perform public.stage_sap_import_rows(v_batch,jsonb_build_array(jsonb_build_object('row_number',1,'data',jsonb_build_object(
    'product_code','6111032201','stock_qty',75,'general_available_qty',50,'general_available_capped',true,'source_display_value','50+'))));
  perform public.validate_sap_import_batch(v_batch); perform public.approve_sap_import_batch(v_batch); perform public.commit_sap_import_batch(v_batch);
  if not exists(select 1 from public.product_branch_stock s join public.branches b on b.id=s.branch_id
    where s.product_code='6111032201' and b.code='PR' and s.sap_general_available_qty=50 and s.available_qty_capped) then raise exception 'ESTOQUE_PR_FALHOU'; end if;

  v_batch := (public.create_sap_import_batch(jsonb_build_object('import_kind','BASE_PRICE_PR','file_hash',repeat('c',64),
    'original_filename','preco-pr.csv','detected_fields',jsonb_build_array('product_code','base_price')))->>'batch_id')::uuid;
  perform public.stage_sap_import_rows(v_batch,jsonb_build_array(jsonb_build_object('row_number',1,'data',jsonb_build_object('product_code','6111032201','base_price',232))));
  perform public.validate_sap_import_batch(v_batch); perform public.approve_sap_import_batch(v_batch); perform public.commit_sap_import_batch(v_batch);
  if not exists(select 1 from public.product_branch_prices p join public.branches b on b.id=p.branch_id
    where p.product_code='6111032201' and b.code='PR' and p.sale_price=232) then raise exception 'PRECO_PR_FALHOU'; end if;

  -- Isola o teste das regras reais vigentes. O rollback restaura o estado original.
  update public.fiscal_tax_rules
     set active=false
   where ncm='85122011'
     and uf_origem='PR'
     and uf_destino in ('PR','SC')
     and operation_type='VENDA'
     and customer_type='GERAL'
     and active;

  v_batch := (public.create_sap_import_batch(jsonb_build_object('import_kind','FISCAL_RULES_PR','file_hash',repeat('d',64),
    'original_filename','fiscal-pr.csv','detected_fields',jsonb_build_array('ncm','destination_state','interstate_icms_rate','internal_icms_rate','mva_rate','ipi_rate','has_st')))->>'batch_id')::uuid;
  perform public.stage_sap_import_rows(v_batch,jsonb_build_array(
    jsonb_build_object('row_number',1,'data',jsonb_build_object('ncm','85122011','destination_state','PR','interstate_icms_rate',0.12,
      'internal_icms_rate',0.195,'mva_rate',0.8778,'ipi_rate',0.0975,'pis_rate',0,'cofins_rate',0,'fcp_rate',0,'has_st',true)),
    jsonb_build_object('row_number',2,'data',jsonb_build_object('ncm','85122011','destination_state','SC','interstate_icms_rate',0.04,
      'internal_icms_rate',0.17,'mva_rate',0,'ipi_rate',0.0975,'pis_rate',0,'cofins_rate',0,'fcp_rate',0,'has_st',false))));
  perform public.validate_sap_import_batch(v_batch); perform public.approve_sap_import_batch(v_batch); perform public.commit_sap_import_batch(v_batch);
  if (public.get_product_commercial_price('6111032201','PR','PR')->>'status')<>'OK' then raise exception 'CALCULO_POS_IMPORT_FALHOU'; end if;
  if (public.get_product_commercial_price('6111032201','PR','SC')->>'status')<>'OK_SEM_ST' then raise exception 'SEM_ST_CONFIGURAVEL_FALHOU'; end if;

  v_document:=public.commercial_create_document('cotacao',jsonb_build_object(
    'cliente','CLIENTE TESTE','cliente_estado','PR','regiao','PR',
    'items',jsonb_build_array(jsonb_build_object('codigo','6111032201','quantidade',1,'desconto_percentual',0))));
  v_quote_id:=(v_document->>'id')::uuid;
  if not exists(select 1 from public.quotation_items where quotation_id=v_quote_id and fiscal_status='OK'
    and preco_sem_imposto_unitario=232 and preco_unitario=347.854460 and fiscal_rule_version is not null and fiscal_calculated_at is not null)
    then raise exception 'SNAPSHOT_COTACAO_FALHOU: %',(
      select jsonb_build_object(
        'fiscal_status',fiscal_status,'base',preco_sem_imposto_unitario,'final',preco_unitario,
        'rule_version',fiscal_rule_version,'calculated_at',fiscal_calculated_at,'details',fiscal_details
      ) from public.quotation_items where quotation_id=v_quote_id limit 1
    ); end if;
  update public.quotations set status='APROVADA' where id=v_quote_id;
  v_document:=public.convert_quotation_to_order(v_quote_id); v_order_id:=(v_document->>'id_pedido')::uuid;
  if not exists(select 1 from public.order_items oi join public.quotation_items qi on qi.quotation_id=v_quote_id and qi.codigo=oi.codigo
    where oi.order_id=v_order_id and oi.fiscal_details=qi.fiscal_details and oi.preco_unitario=qi.preco_unitario
      and oi.fiscal_rule_version=qi.fiscal_rule_version and oi.fiscal_calculated_at=qi.fiscal_calculated_at)
    then raise exception 'SNAPSHOT_PEDIDO_DIVERGIU_DA_COTACAO'; end if;

  if not exists(select 1 from public.products_import_audit where batch_id=v_batch and entity_type='FISCAL_RULE') then raise exception 'AUDITORIA_FISCAL_AUSENTE'; end if;
  raise notice 'SAP_IMPORT_REGRESSION_OK';
end;
$$;

rollback;
