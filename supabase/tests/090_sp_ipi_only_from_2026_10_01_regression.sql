begin;

do $$
declare
  v_source jsonb:=jsonb_build_object(
    'product_code','9900000090','route','SP-SP','origin_state','SP','destination_state','SP',
    'base_price',100,'total_taxes',23.25,'final_price',123.25,
    'ipi_amount',3.25,'icms_st_amount',20,
    'tax_breakdown',jsonb_build_object('ipi',3.25,'icms_proprio',12,'icms_st',20),
    'status','OK','warnings','[]'::jsonb,'price_source','EXCEL_ROUTE_PRICE'
  );
  v_before jsonb;
  v_after jsonb;
  v_without_excel jsonb;
  v_pr jsonb;
  v_branch_sp uuid;
begin
  select id into v_branch_sp from public.branches where code='SP' and active limit 1;
  if v_branch_sp is null then raise exception 'FILIAL_SP_AUSENTE'; end if;

  insert into public.products(codigo,descricao,ncm,cest,ipi_rate,ipi_defined)
  values('9900000090','TESTE MOTOR CRM SP SEM ST','99000090','9999999',0.0325,true)
  on conflict(codigo) do update set ncm=excluded.ncm,cest=excluded.cest,
    ipi_rate=excluded.ipi_rate,ipi_defined=true;

  insert into public.product_branch_prices(product_code,branch_id,sale_price,source)
  values('9900000090',v_branch_sp,100,'MANUAL')
  on conflict(product_code,branch_id) do update set sale_price=100,source='MANUAL';

  perform set_config('app.fiscal_transition','1',true);
  update public.fiscal_tax_rules set active=false
  where ncm='99000090' and uf_origem='SP' and uf_destino='SP'
    and operation_type='VENDA' and customer_type='REVENDA' and active;
  insert into public.fiscal_tax_rules(
    ncm,uf_origem,uf_destino,operation_type,customer_type,
    interstate_icms_rate,internal_icms_rate,mva_rate,ipi_rate,
    pis_rate,cofins_rate,fcp_rate,base_reduction_rate,
    freight_rate,insurance_rate,other_expenses_rate,has_st,
    resale_include_own_icms,effective_from,source,
    lifecycle_status,review_required_at,active
  ) values(
    '99000090','SP','SP','VENDA','REVENDA',
    0.12,0.18,0.40,0.0325,0,0,0,0,0,0,0,true,false,date '2026-01-01','TEST',
    'REVIEW_REQUIRED',now(),true
  );

  v_before:=public.apply_commercial_tax_policy(v_source,'SP','SP',date '2026-09-30');
  if v_before is distinct from v_source then
    raise exception 'POLITICA_SP_ATIVADA_ANTES_DA_VIGENCIA: %',v_before;
  end if;

  v_after:=public.apply_commercial_tax_policy(v_source,'SP','SP',date '2026-10-01');
  if v_after->>'status'<>'OK_SEM_ST'
     or v_after->>'price_source'<>'CRM_FISCAL_ENGINE_SP_IPI_ONLY'
     or v_after->>'calculation_rule_source'<>'CRM_FISCAL_RULE'
     or v_after->>'validation_status'<>'MATCH'
     or coalesce((v_after->>'tax_policy_applied')::boolean,false) is not true
     or (v_after->>'base_price')::numeric<>100
     or (v_after->>'total_taxes')::numeric<>3.25
     or (v_after->>'final_price')::numeric<>103.25
     or (v_after->>'ipi_amount')::numeric<>3.25
     or (v_after->>'icms_st_amount')::numeric<>0
     or (v_after#>>'{tax_breakdown,icms_st}')::numeric<>0
     or (v_after->>'source_final_price')::numeric<>123.25
     or (v_after->>'source_total_taxes')::numeric<>23.25
     or (v_after->>'validation_excel_ipi_only_price')::numeric<>103.25 then
    raise exception 'POLITICA_SP_IPI_INCORRETA: %',v_after;
  end if;

  v_without_excel:=public.apply_commercial_tax_policy(
    v_source||jsonb_build_object('status','PRECO_FISCAL_INDISPONIVEL','final_price',null,
      'total_taxes',null,'tax_breakdown','{}'::jsonb),
    'SP','SP',date '2026-10-01'
  );
  if v_without_excel->>'status'<>'OK_SEM_ST'
     or v_without_excel->>'price_source'<>'CRM_FISCAL_ENGINE_SP_IPI_ONLY'
     or v_without_excel->>'validation_status'<>'EXCEL_REFERENCE_MISSING'
     or (v_without_excel->>'final_price')::numeric<>103.25 then
    raise exception 'PLANILHA_VIROU_DEPENDENCIA_OPERACIONAL: %',v_without_excel;
  end if;

  v_pr:=public.apply_commercial_tax_policy(v_source||jsonb_build_object('route','PR-PR'),'PR','PR',date '2026-10-01');
  if v_pr is distinct from (v_source||jsonb_build_object('route','PR-PR')) then
    raise exception 'POLITICA_SP_ALTEROU_OUTRA_ROTA: %',v_pr;
  end if;

  if has_function_privilege('authenticated','public.get_product_commercial_price_raw_090(text,text,text,date,text)','EXECUTE')
     or has_function_privilege('authenticated','public.normalize_document_tax_policy(text,uuid)','EXECUTE') then
    raise exception 'FUNCAO_INTERNA_EXPOSTA';
  end if;
  if not has_function_privilege('authenticated','public.get_product_commercial_price(text,text,text,date,text)','EXECUTE') then
    raise exception 'FUNCAO_COMERCIAL_SEM_ACESSO_AUTENTICADO';
  end if;
end;
$$;

rollback;
