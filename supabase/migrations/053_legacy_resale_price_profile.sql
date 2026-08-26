begin;

-- The price lists reproduce the reference workbook, while sales quotations from
-- the existing portal use a different tax composition for resale. Keep both
-- profiles explicit and configurable instead of changing the workbook engine.
alter table public.fiscal_tax_rules
  add column if not exists resale_calculation_method text not null default 'MVA_ST',
  add column if not exists resale_icms_st_rate numeric(12,8),
  add column if not exists resale_include_own_icms boolean not null default false;

alter table public.fiscal_tax_rules
  drop constraint if exists fiscal_tax_rules_resale_method_check;
alter table public.fiscal_tax_rules
  add constraint fiscal_tax_rules_resale_method_check
  check (resale_calculation_method in ('MVA_ST','RATE_DIFFERENCE'));

alter table public.fiscal_tax_rules
  drop constraint if exists fiscal_tax_rules_resale_icms_st_rate_check;
alter table public.fiscal_tax_rules
  add constraint fiscal_tax_rules_resale_icms_st_rate_check
  check (resale_icms_st_rate is null or resale_icms_st_rate between 0 and 1);

-- Evidence from the company portal shows SP->SP resale charging the difference
-- between the destination/internal rate and the own ICMS rate, without adding
-- own ICMS again to the customer total. Other routes remain on the workbook/MVA
-- profile until equivalent company evidence is supplied.
update public.fiscal_tax_rules
set resale_calculation_method='RATE_DIFFERENCE',
    resale_include_own_icms=false
where active and uf_origem='SP' and uf_destino='SP' and coalesce(has_st,false);

-- Observed regression: product 7175526020, NCM 8708.94.83, base 580.00,
-- ICMS-ST 81.17 and IPI 18.85, final 680.02 in the existing company portal.
update public.fiscal_tax_rules
set resale_icms_st_rate=round(81.17::numeric/580::numeric,8),
    resale_calculation_method='RATE_DIFFERENCE',
    resale_include_own_icms=false
where active and ncm=public.normalize_ncm('8708.94.83') and uf_origem='SP' and uf_destino='SP';

create or replace function public.calculate_product_price(
  product_code text,
  origin_state text,
  destination_state text,
  input_base_price numeric default null,
  calculation_date date default current_date,
  target_customer_type text default 'GERAL'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_product public.products;
  v_rule public.fiscal_tax_rules;
  v_base numeric(16,6);
  v_origin text:=public.normalize_fiscal_uf(origin_state);
  v_destination text:=public.normalize_fiscal_uf(destination_state);
  v_customer_type text:=upper(coalesce(nullif(btrim(target_customer_type),''),'GERAL'));
  v_use_resale_profile boolean;
  v_calculation_method text;
  v_ipi_rate numeric(12,8);
  v_ipi numeric(16,6);
  v_own_icms numeric(16,6);
  v_st_base numeric(16,6);
  v_icms_st numeric(16,6);
  v_pis numeric(16,6);
  v_cofins numeric(16,6);
  v_fcp numeric(16,6);
  v_freight numeric(16,6);
  v_insurance numeric(16,6);
  v_other numeric(16,6);
  v_taxes numeric(16,6);
  v_expenses numeric(16,6);
  v_status text;
  v_warnings jsonb:='[]'::jsonb;
begin
  select * into v_product from public.products where codigo=btrim(product_code);
  if v_product.codigo is null then
    return jsonb_build_object('product_code',btrim(product_code),'status','PRODUTO_NAO_LOCALIZADO','warnings',v_warnings);
  end if;
  if v_origin is null or v_destination is null then
    return jsonb_build_object('product_code',v_product.codigo,'status','UF_INVALIDA','warnings',v_warnings);
  end if;
  v_base:=round(input_base_price,6);
  if v_base is null or v_base<=0 then
    return jsonb_build_object('product_code',v_product.codigo,'route',v_origin||'-'||v_destination,
      'ncm',v_product.ncm,'cest',v_product.cest,'status','PRECO_AUSENTE','warnings',v_warnings);
  end if;
  if public.normalize_ncm(v_product.ncm) is null then
    return jsonb_build_object('product_code',v_product.codigo,'route',v_origin||'-'||v_destination,
      'base_price',v_base,'status','NCM_AUSENTE','warnings',v_warnings);
  end if;

  v_rule:=public.resolve_fiscal_tax_rule(v_product.ncm,v_origin,v_destination,v_customer_type,calculation_date);
  if v_rule.id is null then
    return jsonb_build_object('product_code',v_product.codigo,'route',v_origin||'-'||v_destination,
      'ncm',v_product.ncm,'cest',v_product.cest,'base_price',v_base,
      'status','REGRA_FISCAL_AUSENTE','warnings',v_warnings);
  end if;

  v_calculation_method:=coalesce(v_rule.resale_calculation_method,'MVA_ST');
  v_use_resale_profile:=v_customer_type='REVENDA' and v_calculation_method='RATE_DIFFERENCE';
  v_ipi_rate:=coalesce(v_rule.ipi_rate,case when v_product.ipi_defined then v_product.ipi_rate else null end);
  if v_ipi_rate is null then v_warnings:=v_warnings||jsonb_build_array('IPI_AUSENTE'); end if;
  if v_product.cest is null and v_rule.cest is null then v_warnings:=v_warnings||jsonb_build_array('CEST_AUSENTE'); end if;
  if v_rule.interstate_icms_rate is null then v_warnings:=v_warnings||jsonb_build_array('ICMS_INTERESTADUAL_AUSENTE'); end if;
  if coalesce(v_rule.has_st,false) and v_rule.internal_icms_rate is null then v_warnings:=v_warnings||jsonb_build_array('ICMS_INTERNO_AUSENTE'); end if;
  if coalesce(v_rule.has_st,false) and not v_use_resale_profile and v_rule.mva_rate is null then v_warnings:=v_warnings||jsonb_build_array('MVA_AUSENTE'); end if;
  if v_rule.pis_rate is null then v_warnings:=v_warnings||jsonb_build_array('PIS_NAO_DEFINIDO'); end if;
  if v_rule.cofins_rate is null then v_warnings:=v_warnings||jsonb_build_array('COFINS_NAO_DEFINIDO'); end if;
  if v_rule.fcp_rate is null then v_warnings:=v_warnings||jsonb_build_array('FCP_NAO_DEFINIDO'); end if;

  v_ipi:=case when v_ipi_rate is null then null else round(v_base*v_ipi_rate,6) end;
  v_own_icms:=case when v_rule.interstate_icms_rate is null then null else round(v_base*v_rule.interstate_icms_rate,6) end;
  v_st_base:=case when v_use_resale_profile then v_base
    else round((v_base+coalesce(v_ipi,0))*(1+coalesce(v_rule.mva_rate,0)),6) end;
  v_icms_st:=case
    when not coalesce(v_rule.has_st,false) then 0
    when v_rule.internal_icms_rate is null or v_own_icms is null then null
    when v_use_resale_profile then round(greatest(0,v_base*coalesce(v_rule.resale_icms_st_rate,
      greatest(0,v_rule.internal_icms_rate-v_rule.interstate_icms_rate))),6)
    when v_rule.mva_rate is null then null
    else round(greatest(0,v_st_base*(1-coalesce(v_rule.base_reduction_rate,0))*v_rule.internal_icms_rate-v_own_icms),6)
  end;
  v_pis:=case when v_rule.pis_rate is null then null else round(v_base*v_rule.pis_rate,6) end;
  v_cofins:=case when v_rule.cofins_rate is null then null else round(v_base*v_rule.cofins_rate,6) end;
  v_fcp:=case when v_rule.fcp_rate is null then null else round(v_st_base*v_rule.fcp_rate,6) end;
  v_freight:=case when v_rule.freight_rate is null then null else round(v_base*v_rule.freight_rate,6) end;
  v_insurance:=case when v_rule.insurance_rate is null then null else round(v_base*v_rule.insurance_rate,6) end;
  v_other:=case when v_rule.other_expenses_rate is null then null else round(v_base*v_rule.other_expenses_rate,6) end;
  v_taxes:=round(coalesce(v_ipi,0)
    +case when not v_use_resale_profile or v_rule.resale_include_own_icms then coalesce(v_own_icms,0) else 0 end
    +coalesce(v_icms_st,0)+coalesce(v_pis,0)+coalesce(v_cofins,0)+coalesce(v_fcp,0),6);
  v_expenses:=round(coalesce(v_freight,0)+coalesce(v_insurance,0)+coalesce(v_other,0),6);

  v_status:=case
    when v_ipi_rate is null or v_rule.interstate_icms_rate is null
      or (coalesce(v_rule.has_st,false) and v_rule.internal_icms_rate is null)
      or (coalesce(v_rule.has_st,false) and not v_use_resale_profile and v_rule.mva_rate is null)
      then 'REGRA_FISCAL_INCOMPLETA'
    when coalesce(v_rule.has_st,false) then 'OK'
    else 'OK_SEM_ST'
  end;

  return jsonb_build_object(
    'product_code',v_product.codigo,'route',v_origin||'-'||v_destination,
    'origin_state',v_origin,'destination_state',v_destination,
    'ncm',public.normalize_ncm(v_product.ncm),
    'ncm_formatted',substring(v_product.ncm from 1 for 4)||'.'||substring(v_product.ncm from 5 for 2)||'.'||substring(v_product.ncm from 7 for 2),
    'cest',coalesce(v_rule.cest,v_product.cest),'base_price',v_base,
    'mva_rate',v_rule.mva_rate,'ipi_rate',v_ipi_rate,
    'interstate_icms_rate',v_rule.interstate_icms_rate,'internal_icms_rate',v_rule.internal_icms_rate,
    'base_reduction_rate',v_rule.base_reduction_rate,'base_st',v_st_base,
    'ipi_amount',v_ipi,'own_icms_amount',v_own_icms,'icms_st_amount',v_icms_st,
    'pis_amount',v_pis,'cofins_amount',v_cofins,'fcp_amount',v_fcp,
    'freight_amount',v_freight,'insurance_amount',v_insurance,'other_expenses_amount',v_other,
    'total_taxes',v_taxes,'total_expenses',v_expenses,'final_price',round(v_base+v_taxes+v_expenses,6),
    'has_st',coalesce(v_rule.has_st,false),'status',v_status,'warnings',v_warnings,
    'customer_type',v_customer_type,
    'calculation_profile',case when v_use_resale_profile then 'LEGACY_REVENDA' else 'PRICE_LIST_MVA' end,
    'calculation_method',case when v_use_resale_profile then v_calculation_method else 'MVA_ST' end,
    'own_icms_included_in_total',case when v_use_resale_profile then v_rule.resale_include_own_icms else true end,
    'resale_icms_st_rate',case when v_use_resale_profile then coalesce(v_rule.resale_icms_st_rate,
      greatest(0,v_rule.internal_icms_rate-v_rule.interstate_icms_rate)) else null end,
    'fiscal_rule_id',v_rule.id,'fiscal_rule_version',v_rule.rule_version,
    'rule_valid_from',v_rule.effective_from,'rule_valid_until',v_rule.effective_to,'calculated_at',now()
  );
end;
$$;

comment on column public.fiscal_tax_rules.resale_calculation_method
  is 'Perfil de cotação/pedido para REVENDA: MVA_ST mantém lista; RATE_DIFFERENCE reproduz portal legado.';
comment on column public.fiscal_tax_rules.resale_icms_st_rate
  is 'Alíquota efetiva opcional do ICMS-ST no perfil REVENDA; NULL usa ICMS interno menos ICMS próprio.';
comment on function public.calculate_product_price(text,text,text,numeric,date,text)
  is 'Motor central com perfis PRICE_LIST_MVA e LEGACY_REVENDA configurados por regra fiscal.';

commit;
