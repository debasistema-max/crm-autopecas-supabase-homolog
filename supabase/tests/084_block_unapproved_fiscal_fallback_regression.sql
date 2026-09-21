begin;

do $$
declare
  v_code constant text := '9900000084';
  v_branch_pr uuid;
  v_rule_result jsonb;
  v_commercial_result jsonb;
begin
  select id into v_branch_pr from public.branches where code='PR' and active limit 1;
  if v_branch_pr is null then raise exception 'FILIAL_PR_AUSENTE'; end if;

  insert into public.products(codigo,descricao,ncm,cest,ipi_rate,ipi_defined)
  values(v_code,'TESTE ICMS PROPRIO INFORMATIVO','85122011','0105500',0.10,true)
  on conflict(codigo) do update set ncm=excluded.ncm,cest=excluded.cest,ipi_rate=excluded.ipi_rate,ipi_defined=true;

  insert into public.product_branch_prices(product_code,branch_id,sale_price,source)
  values(v_code,v_branch_pr,100,'MANUAL')
  on conflict(product_code,branch_id) do update set sale_price=100,source='MANUAL';

  perform set_config('app.fiscal_transition','1',true);
  update public.fiscal_tax_rules set active=false
  where ncm='85122011' and uf_origem='PR' and uf_destino='SC'
    and operation_type='VENDA' and customer_type='REGRESSION_084' and active;

  insert into public.fiscal_tax_rules(
    ncm,uf_origem,uf_destino,operation_type,customer_type,
    interstate_icms_rate,internal_icms_rate,mva_rate,ipi_rate,
    pis_rate,cofins_rate,fcp_rate,base_reduction_rate,
    freight_rate,insurance_rate,other_expenses_rate,has_st,
    resale_include_own_icms,effective_from,source
  ) values(
    '85122011','PR','SC','VENDA','REGRESSION_084',
    0.04,0.17,0,0.10,0,0,0,0,0,0,0,false,false,current_date,'TEST'
  );

  v_rule_result:=public.calculate_product_price(v_code,'PR','SC',100,current_date,'REGRESSION_084');
  if (v_rule_result->>'own_icms_amount')::numeric<>4
     or (v_rule_result->>'total_taxes')::numeric
        <> (v_rule_result->>'final_price')::numeric-(v_rule_result->>'base_price')::numeric
     or (v_rule_result->>'final_price')::numeric
        = (v_rule_result->>'base_price')::numeric+(v_rule_result->>'total_taxes')::numeric
          +(v_rule_result->>'own_icms_amount')::numeric
     or coalesce((v_rule_result->>'own_icms_included_in_total')::boolean,true) then
    raise exception 'ICMS_PROPRIO_ENTROU_NO_PRECO: %',v_rule_result;
  end if;

  delete from public.product_route_prices where product_code=v_code and route='PR-SC';
  v_commercial_result:=public.get_product_commercial_price(v_code,'PR','SC',current_date,'REVENDA');
  if v_commercial_result->>'status'<>'PRECO_FISCAL_INDISPONIVEL'
     or v_commercial_result->>'price_source'<>'FISCAL_FALLBACK_BLOCKED'
     or v_commercial_result->'final_price' is distinct from 'null'::jsonb
     or not (v_commercial_result->'warnings' ? 'FALLBACK_FISCAL_NAO_HOMOLOGADO') then
    raise exception 'FALLBACK_NAO_FOI_BLOQUEADO: %',v_commercial_result;
  end if;
end;
$$;

rollback;
