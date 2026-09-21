begin;

do $$
declare
  v_code constant text := '9900000085';
  v_version constant text := '8500850085008500850085008500850085008500850085008500850085008500';
  v_result jsonb;
begin
  insert into public.products(codigo,descricao,ncm,cest,ipi_rate,ipi_defined)
  values(v_code,'TESTE BASE FISCAL EXCEL','84136019','0100200',0.10,true)
  on conflict(codigo) do update set ncm=excluded.ncm,cest=excluded.cest,ipi_rate=excluded.ipi_rate,ipi_defined=true;

  insert into public.product_sap_data(product_code,item_group)
  values(v_code,'GRUPO TESTE')
  on conflict(product_code) do update set item_group=excluded.item_group;

  perform public.sync_excel_fiscal_bases(
    v_version,now(),
    jsonb_build_array(jsonb_build_object(
      'ncm','84136019','origin_state','PR','destination_state','PR','cest','0100200',
      'mva_rate',0.10,'ipi_rate',0.10,'interstate_icms_rate',0.12,
      'internal_icms_rate',0.18,'has_st',true
    )),
    jsonb_build_array(jsonb_build_object(
      'ncm','84136019','item_group','GRUPO TESTE','route','PR-PR',
      'mva_rate',0.20,'ipi_rate',0.10,'interstate_icms_rate',0.12,
      'internal_icms_rate',0.18,'has_st',true,'sample_product_code',v_code
    ))
  );

  v_result:=public.calculate_product_price(v_code,'PR','PR',100,current_date,'REVENDA');
  if v_result->>'calculation_rule_source'<>'EXCEL_GROUP_BASE'
     or v_result->>'fiscal_base_source_version'<>v_version
     or (v_result->>'ipi_amount')::numeric<>10
     or (v_result->>'own_icms_amount')::numeric<>12
     or (v_result->>'icms_st_amount')::numeric<>11.76
     or (v_result->>'final_price')::numeric<>121.76
     or coalesce((v_result->>'own_icms_included_in_total')::boolean,true) then
    raise exception 'BASE_FISCAL_GRUPO_DIVERGENTE: %',v_result;
  end if;

  update public.product_sap_data set item_group='GRUPO SEM REGRA' where product_code=v_code;
  v_result:=public.calculate_product_price(v_code,'PR','PR',100,current_date,'REVENDA');
  if v_result->>'calculation_rule_source'<>'EXCEL_NCM_BASE'
     or (v_result->>'icms_st_amount')::numeric<>9.78
     or (v_result->>'final_price')::numeric<>119.78 then
    raise exception 'BASE_FISCAL_NCM_DIVERGENTE: %',v_result;
  end if;
end;
$$;

rollback;
