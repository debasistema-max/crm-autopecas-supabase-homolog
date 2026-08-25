begin;

insert into public.products(codigo,descricao,ncm,cest,ipi_rate,ipi_defined)
values('6111032201','PRODUTO REGRESSAO FISCAL','85122011','0100100',0.0975,true)
on conflict (codigo) do update set
  descricao=excluded.descricao,ncm=excluded.ncm,cest=excluded.cest,
  ipi_rate=excluded.ipi_rate,ipi_defined=excluded.ipi_defined;

insert into public.product_branch_prices(product_code,branch_id,sale_price,source)
select '6111032201',id,232.000000,'MANUAL' from public.branches where code in ('PR','SP')
on conflict(product_code,branch_id) do update set sale_price=excluded.sale_price,source='MANUAL',source_batch_id=null;

insert into public.product_branch_stock(product_code,branch_id,physical_qty,sap_general_available_qty,available_qty_capped,source_display_value)
select '6111032201',id,50,50,true,'50+' from public.branches where code in ('PR','SP')
on conflict(product_code,branch_id) do update set physical_qty=50,sap_general_available_qty=50,available_qty_capped=true,source_display_value='50+';

insert into public.fiscal_tax_rules(
  ncm,uf_origem,uf_destino,operation_type,customer_type,
  interstate_icms_rate,internal_icms_rate,mva_rate,ipi_rate,pis_rate,cofins_rate,fcp_rate,
  base_reduction_rate,freight_rate,insurance_rate,other_expenses_rate,has_st,
  icms_percent,icms_st_percent,mva_percent,ipi_percent,pis_percent,cofins_percent,fcp_percent,
  effective_from,source,notes
) values
  ('85122011','PR','PR','VENDA','GERAL',0.12,0.195,0.8778,0.0975,0,0,0,0,0,0,0,true,12,19.5,87.78,9.75,0,0,0,current_date,'TEST','REGRESSAO PR-PR'),
  ('85122011','SP','SP','VENDA','GERAL',0.04,0.18,1.0111,0.0975,0,0,0,0,0,0,0,true,4,18,101.11,9.75,0,0,0,current_date,'TEST','REGRESSAO SP-SP'),
  ('85122011','PR','SC','VENDA','GERAL',0.04,0.17,0,0.0975,0,0,0,0,0,0,0,false,4,17,0,9.75,0,0,0,current_date,'TEST','REGRESSAO PR-SC')
on conflict(ncm,uf_origem,uf_destino,operation_type,customer_type,effective_from) do update set
  interstate_icms_rate=excluded.interstate_icms_rate,
  internal_icms_rate=excluded.internal_icms_rate,
  mva_rate=excluded.mva_rate,
  ipi_rate=excluded.ipi_rate,
  pis_rate=excluded.pis_rate,
  cofins_rate=excluded.cofins_rate,
  fcp_rate=excluded.fcp_rate,
  has_st=excluded.has_st,
  source=excluded.source,
  notes=excluded.notes;

do $$
declare
  pr_pr jsonb := public.get_product_commercial_price('6111032201','PR','PR');
  sp_sp jsonb := public.get_product_commercial_price('6111032201','SP','SP');
  pr_sc jsonb := public.get_product_commercial_price('6111032201','PR','SC');
begin
  if abs((pr_pr->>'ipi_amount')::numeric-22.620000)>0.000001 then raise exception 'PR-PR IPI divergente: %',pr_pr; end if;
  if abs((pr_pr->>'own_icms_amount')::numeric-27.840000)>0.000001 then raise exception 'PR-PR ICMS proprio divergente: %',pr_pr; end if;
  if abs((pr_pr->>'icms_st_amount')::numeric-65.394460)>0.000001 then raise exception 'PR-PR ICMS-ST divergente: %',pr_pr; end if;
  if abs((pr_pr->>'total_taxes')::numeric-115.854460)>0.000001 then raise exception 'PR-PR tributos divergentes: %',pr_pr; end if;
  if abs((pr_pr->>'final_price')::numeric-347.854460)>0.000001 or pr_pr->>'status'<>'OK' then raise exception 'PR-PR final divergente: %',pr_pr; end if;

  if abs((sp_sp->>'ipi_amount')::numeric-22.620000)>0.000001 then raise exception 'SP-SP IPI divergente: %',sp_sp; end if;
  if abs((sp_sp->>'own_icms_amount')::numeric-9.280000)>0.000001 then raise exception 'SP-SP ICMS proprio divergente: %',sp_sp; end if;
  if abs((sp_sp->>'icms_st_amount')::numeric-82.891931)>0.000001 then raise exception 'SP-SP ICMS-ST divergente: %',sp_sp; end if;
  if abs((sp_sp->>'total_taxes')::numeric-114.791931)>0.000001 then raise exception 'SP-SP tributos divergentes: %',sp_sp; end if;
  if abs((sp_sp->>'final_price')::numeric-346.791931)>0.000001 or sp_sp->>'status'<>'OK' then raise exception 'SP-SP final divergente: %',sp_sp; end if;

  if abs((pr_sc->>'ipi_amount')::numeric-22.620000)>0.000001 then raise exception 'PR-SC IPI divergente: %',pr_sc; end if;
  if abs((pr_sc->>'own_icms_amount')::numeric-9.280000)>0.000001 then raise exception 'PR-SC ICMS proprio divergente: %',pr_sc; end if;
  if (pr_sc->>'icms_st_amount')::numeric<>0 or (pr_sc->>'total_taxes')::numeric<>31.900000 then raise exception 'PR-SC tributos divergentes: %',pr_sc; end if;
  if (pr_sc->>'final_price')::numeric<>263.900000 or pr_sc->>'status'<>'OK_SEM_ST' then raise exception 'PR-SC final divergente: %',pr_sc; end if;

  raise notice 'REGRESSION_OK PR-PR=% SP-SP=% PR-SC=%',pr_pr->>'final_price',sp_sp->>'final_price',pr_sc->>'final_price';
end;
$$;

rollback;
