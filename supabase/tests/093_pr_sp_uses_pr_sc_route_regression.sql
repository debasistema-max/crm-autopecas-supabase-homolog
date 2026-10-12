begin;

do $$
declare
  v_product_code text;
  v_pr_pr jsonb;
  v_pr_sc jsonb;
  v_pr_sp jsonb;
  v_sp_sp jsonb;
begin
  select rp.product_code into v_product_code
  from public.product_route_prices rp
  join public.branches b on b.id=rp.origin_branch_id and b.code='PR'
  where rp.route='PR-SC'
    and rp.final_price>0
    and upper(coalesce(rp.calculation_status,'OK')) like 'OK%'
  order by rp.product_code
  limit 1;

  if v_product_code is null then
    raise exception 'SEM_PRODUTO_PR_SC_PARA_REGRESSAO';
  end if;

  v_pr_pr:=public.get_product_commercial_price(v_product_code,'PR','PR',date '2026-10-01','REVENDA');
  v_pr_sc:=public.get_product_commercial_price(v_product_code,'PR','SC',date '2026-10-01','REVENDA');
  v_pr_sp:=public.get_product_commercial_price(v_product_code,'PR','SP',date '2026-10-01','REVENDA');
  v_sp_sp:=public.get_product_commercial_price(v_product_code,'SP','SP',date '2026-10-01','REVENDA');

  if v_pr_sc->>'status' not like 'OK%' then
    raise exception 'ROTA_FONTE_PR_SC_INDISPONIVEL:%',v_pr_sc;
  end if;
  if v_pr_sp->>'status' is distinct from v_pr_sc->>'status'
     or (v_pr_sp->>'base_price')::numeric is distinct from (v_pr_sc->>'base_price')::numeric
     or (v_pr_sp->>'final_price')::numeric is distinct from (v_pr_sc->>'final_price')::numeric
     or (v_pr_sp->>'total_taxes')::numeric is distinct from (v_pr_sc->>'total_taxes')::numeric
     or v_pr_sp->'tax_breakdown' is distinct from v_pr_sc->'tax_breakdown' then
    raise exception 'PR_SP_DIVERGIU_DE_PR_SC:PR_SC=% PR_SP=%',v_pr_sc,v_pr_sp;
  end if;
  if v_pr_sp->>'route'<>'PR-SP'
     or v_pr_sp->>'destination_state'<>'SP'
     or coalesce((v_pr_sp->>'route_alias_applied')::boolean,false) is not true
     or v_pr_sp->>'route_alias_source_route'<>'PR-SC'
     or v_pr_sp->>'price_source'<>'CRM_ROUTE_ALIAS'
     or not coalesce(v_pr_sp->'warnings','[]'::jsonb) ? 'ROTA_PR_SP_USA_REGRA_PR_SC' then
    raise exception 'METADADOS_ALIAS_PR_SP_INVALIDOS:%',v_pr_sp;
  end if;
  if coalesce((v_pr_sc->>'route_alias_applied')::boolean,false)
     or coalesce((v_pr_pr->>'route_alias_applied')::boolean,false)
     or coalesce((v_sp_sp->>'route_alias_applied')::boolean,false) then
    raise exception 'ALIAS_PR_SP_ALTEROU_OUTRA_ROTA';
  end if;
end;
$$;

rollback;
