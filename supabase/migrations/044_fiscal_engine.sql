begin;

-- Central fiscal engine. Monetary calculations retain six decimal places and all
-- rates are fractions. Frontends must consume these RPCs instead of recalculating.

create or replace function public.calculate_taxed_unit_price(
  base_price numeric,
  rule_row public.fiscal_tax_rules
)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_base numeric(16,6) := round(coalesce(base_price, 0), 6);
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
begin
  if rule_row.id is null or v_base <= 0 then
    return jsonb_build_object('status', 'REGRA_FISCAL_AUSENTE', 'base_price', v_base,
      'total_taxes', null, 'final_price', null);
  end if;

  v_ipi := case when rule_row.ipi_rate is null then null else round(v_base * rule_row.ipi_rate, 6) end;
  v_own_icms := case when rule_row.interstate_icms_rate is null then null else round(v_base * rule_row.interstate_icms_rate, 6) end;
  v_st_base := round((v_base + coalesce(v_ipi, 0)) * (1 + coalesce(rule_row.mva_rate, 0)), 6);
  v_icms_st := case
    when not coalesce(rule_row.has_st, false) then 0
    when rule_row.internal_icms_rate is null or v_own_icms is null then null
    else round(greatest(0,
      v_st_base * (1 - coalesce(rule_row.base_reduction_rate, 0)) * rule_row.internal_icms_rate
      - v_own_icms), 6)
  end;
  v_pis := case when rule_row.pis_rate is null then null else round(v_base * rule_row.pis_rate, 6) end;
  v_cofins := case when rule_row.cofins_rate is null then null else round(v_base * rule_row.cofins_rate, 6) end;
  v_fcp := case when rule_row.fcp_rate is null then null else round(v_st_base * rule_row.fcp_rate, 6) end;
  v_freight := case when rule_row.freight_rate is null then null else round(v_base * rule_row.freight_rate, 6) end;
  v_insurance := case when rule_row.insurance_rate is null then null else round(v_base * rule_row.insurance_rate, 6) end;
  v_other := case when rule_row.other_expenses_rate is null then null else round(v_base * rule_row.other_expenses_rate, 6) end;
  v_taxes := round(coalesce(v_ipi, 0) + coalesce(v_own_icms, 0) + coalesce(v_icms_st, 0)
    + coalesce(v_pis, 0) + coalesce(v_cofins, 0) + coalesce(v_fcp, 0), 6);
  v_expenses := round(coalesce(v_freight, 0) + coalesce(v_insurance, 0) + coalesce(v_other, 0), 6);

  return jsonb_build_object(
    'status', case when coalesce(rule_row.has_st, false) then 'OK' else 'OK_SEM_ST' end,
    'rule_id', rule_row.id,
    'rule_version', rule_row.rule_version,
    'base_price', v_base,
    'mva_rate', rule_row.mva_rate,
    'ipi_rate', rule_row.ipi_rate,
    'interstate_icms_rate', rule_row.interstate_icms_rate,
    'internal_icms_rate', rule_row.internal_icms_rate,
    'base_reduction_rate', rule_row.base_reduction_rate,
    'base_st', v_st_base,
    'ipi_amount', v_ipi,
    'own_icms_amount', v_own_icms,
    'icms_st_amount', v_icms_st,
    'pis_amount', v_pis,
    'cofins_amount', v_cofins,
    'fcp_amount', v_fcp,
    'freight_amount', v_freight,
    'insurance_amount', v_insurance,
    'other_expenses_amount', v_other,
    'total_taxes', v_taxes,
    'total_expenses', v_expenses,
    'tax_total', v_taxes + v_expenses,
    'final_price', round(v_base + v_taxes + v_expenses, 6),
    'has_st', coalesce(rule_row.has_st, false),
    'ncm', rule_row.ncm,
    'cest', rule_row.cest,
    'uf_origem', rule_row.uf_origem,
    'uf_destino', rule_row.uf_destino,
    'customer_type', rule_row.customer_type
  );
end;
$$;

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
  v_origin text := public.normalize_fiscal_uf(origin_state);
  v_destination text := public.normalize_fiscal_uf(destination_state);
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
  v_warnings jsonb := '[]'::jsonb;
begin
  select * into v_product from public.products where codigo = btrim(product_code);
  if v_product.codigo is null then
    return jsonb_build_object('product_code', btrim(product_code), 'status', 'PRODUTO_NAO_LOCALIZADO', 'warnings', v_warnings);
  end if;
  if v_origin is null or v_destination is null then
    return jsonb_build_object('product_code', v_product.codigo, 'status', 'UF_INVALIDA', 'warnings', v_warnings);
  end if;
  v_base := round(input_base_price, 6);
  if v_base is null or v_base <= 0 then
    return jsonb_build_object('product_code', v_product.codigo, 'route', v_origin || '-' || v_destination,
      'ncm', v_product.ncm, 'cest', v_product.cest, 'status', 'PRECO_AUSENTE', 'warnings', v_warnings);
  end if;
  if public.normalize_ncm(v_product.ncm) is null then
    return jsonb_build_object('product_code', v_product.codigo, 'route', v_origin || '-' || v_destination,
      'base_price', v_base, 'status', 'NCM_AUSENTE', 'warnings', v_warnings);
  end if;

  v_rule := public.resolve_fiscal_tax_rule(v_product.ncm, v_origin, v_destination, target_customer_type, calculation_date);
  if v_rule.id is null then
    return jsonb_build_object('product_code', v_product.codigo, 'route', v_origin || '-' || v_destination,
      'ncm', v_product.ncm, 'cest', v_product.cest, 'base_price', v_base,
      'status', 'REGRA_FISCAL_AUSENTE', 'warnings', v_warnings);
  end if;

  v_ipi_rate := coalesce(v_rule.ipi_rate, case when v_product.ipi_defined then v_product.ipi_rate else null end);
  if v_ipi_rate is null then v_warnings := v_warnings || jsonb_build_array('IPI_AUSENTE'); end if;
  if v_product.cest is null and v_rule.cest is null then v_warnings := v_warnings || jsonb_build_array('CEST_AUSENTE'); end if;
  if v_rule.interstate_icms_rate is null then v_warnings := v_warnings || jsonb_build_array('ICMS_INTERESTADUAL_AUSENTE'); end if;
  if coalesce(v_rule.has_st, false) and v_rule.internal_icms_rate is null then v_warnings := v_warnings || jsonb_build_array('ICMS_INTERNO_AUSENTE'); end if;
  if coalesce(v_rule.has_st, false) and v_rule.mva_rate is null then v_warnings := v_warnings || jsonb_build_array('MVA_AUSENTE'); end if;
  if v_rule.pis_rate is null then v_warnings := v_warnings || jsonb_build_array('PIS_NAO_DEFINIDO'); end if;
  if v_rule.cofins_rate is null then v_warnings := v_warnings || jsonb_build_array('COFINS_NAO_DEFINIDO'); end if;
  if v_rule.fcp_rate is null then v_warnings := v_warnings || jsonb_build_array('FCP_NAO_DEFINIDO'); end if;

  v_ipi := case when v_ipi_rate is null then null else round(v_base * v_ipi_rate, 6) end;
  v_own_icms := case when v_rule.interstate_icms_rate is null then null else round(v_base * v_rule.interstate_icms_rate, 6) end;
  v_st_base := round((v_base + coalesce(v_ipi, 0)) * (1 + coalesce(v_rule.mva_rate, 0)), 6);
  v_icms_st := case
    when not coalesce(v_rule.has_st, false) then 0
    when v_rule.internal_icms_rate is null or v_own_icms is null or v_rule.mva_rate is null then null
    else round(greatest(0,
      v_st_base * (1 - coalesce(v_rule.base_reduction_rate, 0)) * v_rule.internal_icms_rate
      - v_own_icms), 6)
  end;
  v_pis := case when v_rule.pis_rate is null then null else round(v_base * v_rule.pis_rate, 6) end;
  v_cofins := case when v_rule.cofins_rate is null then null else round(v_base * v_rule.cofins_rate, 6) end;
  v_fcp := case when v_rule.fcp_rate is null then null else round(v_st_base * v_rule.fcp_rate, 6) end;
  v_freight := case when v_rule.freight_rate is null then null else round(v_base * v_rule.freight_rate, 6) end;
  v_insurance := case when v_rule.insurance_rate is null then null else round(v_base * v_rule.insurance_rate, 6) end;
  v_other := case when v_rule.other_expenses_rate is null then null else round(v_base * v_rule.other_expenses_rate, 6) end;
  v_taxes := round(coalesce(v_ipi, 0) + coalesce(v_own_icms, 0) + coalesce(v_icms_st, 0)
    + coalesce(v_pis, 0) + coalesce(v_cofins, 0) + coalesce(v_fcp, 0), 6);
  v_expenses := round(coalesce(v_freight, 0) + coalesce(v_insurance, 0) + coalesce(v_other, 0), 6);

  v_status := case
    when v_ipi_rate is null or v_rule.interstate_icms_rate is null
      or (coalesce(v_rule.has_st, false) and (v_rule.internal_icms_rate is null or v_rule.mva_rate is null))
      then 'REGRA_FISCAL_INCOMPLETA'
    when coalesce(v_rule.has_st, false) then 'OK'
    else 'OK_SEM_ST'
  end;

  return jsonb_build_object(
    'product_code', v_product.codigo,
    'route', v_origin || '-' || v_destination,
    'origin_state', v_origin,
    'destination_state', v_destination,
    'ncm', public.normalize_ncm(v_product.ncm),
    'ncm_formatted', substring(v_product.ncm from 1 for 4) || '.' || substring(v_product.ncm from 5 for 2) || '.' || substring(v_product.ncm from 7 for 2),
    'cest', coalesce(v_rule.cest, v_product.cest),
    'base_price', v_base,
    'mva_rate', v_rule.mva_rate,
    'ipi_rate', v_ipi_rate,
    'interstate_icms_rate', v_rule.interstate_icms_rate,
    'internal_icms_rate', v_rule.internal_icms_rate,
    'base_reduction_rate', v_rule.base_reduction_rate,
    'base_st', v_st_base,
    'ipi_amount', v_ipi,
    'own_icms_amount', v_own_icms,
    'icms_st_amount', v_icms_st,
    'pis_amount', v_pis,
    'cofins_amount', v_cofins,
    'fcp_amount', v_fcp,
    'freight_amount', v_freight,
    'insurance_amount', v_insurance,
    'other_expenses_amount', v_other,
    'total_taxes', v_taxes,
    'total_expenses', v_expenses,
    'final_price', round(v_base + v_taxes + v_expenses, 6),
    'has_st', coalesce(v_rule.has_st, false),
    'status', v_status,
    'warnings', v_warnings,
    'fiscal_rule_id', v_rule.id,
    'fiscal_rule_version', v_rule.rule_version,
    'rule_valid_from', v_rule.effective_from,
    'rule_valid_until', v_rule.effective_to,
    'calculated_at', now()
  );
end;
$$;

create or replace function public.get_product_commercial_price(
  product_code text,
  origin_branch text,
  destination_uf text,
  target_date date default current_date,
  customer_type text default 'GERAL'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_branch public.branches;
  v_product public.products;
  v_price public.product_branch_prices;
  v_stock public.product_branch_stock;
  v_calc jsonb;
  v_available numeric(16,6);
  v_availability text;
begin
  if auth.uid() is not null and not (public.is_admin() or public.has_module('produtos')
      or public.has_module('novo_pedido') or public.has_module('nova_cotacao')) then
    raise exception 'SEM_PERMISSAO';
  end if;
  select * into v_branch from public.branches
  where active and (code = upper(btrim(origin_branch)) or id::text = btrim(origin_branch))
  order by case when code = upper(btrim(origin_branch)) then 0 else 1 end limit 1;
  if v_branch.id is null then
    return jsonb_build_object('product_code', btrim(product_code), 'status', 'FILIAL_NAO_LOCALIZADA', 'warnings', '[]'::jsonb);
  end if;
  select * into v_product from public.products where codigo = btrim(product_code);
  if v_product.codigo is null then
    return jsonb_build_object('product_code', btrim(product_code), 'branch', v_branch.code,
      'status', 'PRODUTO_NAO_LOCALIZADO', 'warnings', '[]'::jsonb);
  end if;
  select bp.* into v_price from public.product_branch_prices bp
  where bp.product_code = v_product.codigo and bp.branch_id = v_branch.id
    and bp.valid_from <= target_date and (bp.valid_until is null or bp.valid_until >= target_date);
  select bs.* into v_stock from public.product_branch_stock bs
  where bs.product_code = v_product.codigo and bs.branch_id = v_branch.id;

  v_calc := public.calculate_product_price(v_product.codigo, v_branch.state, destination_uf,
    v_price.sale_price, target_date, customer_type);
  v_available := coalesce(v_stock.sap_general_available_qty, v_stock.available_qty, 0);
  v_availability := case
    when v_stock.product_code is null then 'ESTOQUE_NAO_IMPORTADO'
    when v_available <= 0 then 'INDISPONIVEL'
    when v_stock.available_qty_capped or v_available >= 50 then 'DISPONIVEL'
    else 'CONFIRMAR'
  end;
  return v_calc || jsonb_build_object(
    'description', v_product.descricao,
    'brand', v_product.marca,
    'application', v_product.aplicacao,
    'year', v_product.ano,
    'branch_id', v_branch.id,
    'branch', v_branch.code,
    'branch_name', v_branch.name,
    'base_price_version', v_price.version,
    'base_price_updated_at', v_price.updated_at,
    'available_qty', v_available,
    'available_qty_capped', coalesce(v_stock.available_qty_capped, false),
    'source_display_value', v_stock.source_display_value,
    'availability', v_availability,
    'stock_version', v_stock.version,
    'stock_updated_at', v_stock.updated_at
  );
end;
$$;

create or replace function public.get_products_commercial_prices(
  product_codes jsonb,
  origin_branch text,
  destination_uf text,
  target_date date default current_date,
  customer_type text default 'GERAL'
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(public.get_product_commercial_price(value, origin_branch, destination_uf, target_date, customer_type)), '[]'::jsonb)
  from jsonb_array_elements_text(coalesce(product_codes, '[]'::jsonb))
$$;

create or replace function public.get_product_route_prices(product_code text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_array(
    public.get_product_commercial_price(product_code, 'PR', 'PR'),
    public.get_product_commercial_price(product_code, 'SP', 'SP'),
    public.get_product_commercial_price(product_code, 'PR', 'SC')
  )
$$;

create or replace function public.get_fiscal_pending(filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit integer := least(greatest(coalesce((filters->>'limit')::integer, 200), 1), 5000);
  v_offset integer := greatest(coalesce((filters->>'offset')::integer, 0), 0);
  v_rows jsonb;
  v_summary jsonb;
begin
  if auth.uid() is not null and not (public.is_admin() or public.has_module('alimentacao') or public.has_module('configuracoes')) then
    raise exception 'SEM_PERMISSAO';
  end if;
  with routes(origin, destination) as (values ('PR','PR'),('SP','SP'),('PR','SC')),
  pending as (
    select p.codigo, p.descricao, p.marca, p.ncm, p.cest, p.ipi_defined,
      r.origin || '-' || r.destination as route,
      case
        when p.ncm is null then 'NCM_AUSENTE'
        when fr.id is null then 'REGRA_FISCAL_AUSENTE'
        when fr.interstate_icms_rate is null or (coalesce(fr.has_st,false) and (fr.internal_icms_rate is null or fr.mva_rate is null)) then 'REGRA_FISCAL_INCOMPLETA'
        when bp.product_code is null or bp.sale_price <= 0 then 'PRECO_AUSENTE'
        else null
      end as status
    from public.products p cross join routes r
    left join public.branches b on b.code=r.origin and b.active
    left join public.product_branch_prices bp on bp.product_code=p.codigo and bp.branch_id=b.id
    left join lateral (
      select x.* from public.fiscal_tax_rules x
      where x.active and x.ncm=p.ncm and x.uf_origem=r.origin and x.uf_destino=r.destination
        and x.effective_from <= current_date and (x.effective_to is null or x.effective_to >= current_date)
      order by x.effective_from desc limit 1
    ) fr on true
  ), filtered as (
    select * from pending where status is not null
      and (nullif(filters->>'status','') is null or status=filters->>'status')
      and (nullif(filters->>'route','') is null or route=upper(filters->>'route'))
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.codigo,x.route),'[]'::jsonb)
  into v_rows from (select * from filtered order by codigo,route limit v_limit offset v_offset) x;

  select jsonb_build_object(
    'products_without_ncm', count(*) filter(where p.ncm is null),
    'products_without_cest', count(*) filter(where p.cest is null),
    'products_without_ipi', count(*) filter(where not p.ipi_defined),
    'rules_incomplete', count(*) filter(where f.interstate_icms_rate is null or (coalesce(f.has_st,false) and (f.internal_icms_rate is null or f.mva_rate is null)))
  ) into v_summary
  from public.products p
  left join public.fiscal_tax_rules f on f.ncm=p.ncm and f.active;
  return jsonb_build_object('summary', v_summary, 'rows', v_rows, 'limit', v_limit, 'offset', v_offset);
end;
$$;

create or replace function public.generate_commercial_list(
  route text,
  filters jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_route text := upper(replace(btrim(route), '→', '-'));
  v_origin text := split_part(v_route, '-', 1);
  v_destination text := split_part(v_route, '-', 2);
  v_limit integer := least(greatest(coalesce((filters->>'limit')::integer, 10000), 1), 50000);
  v_result jsonb;
begin
  if v_origin not in ('PR','SP') or public.normalize_fiscal_uf(v_destination) is null then raise exception 'ROTA_INVALIDA'; end if;
  if auth.uid() is not null and not (public.is_admin() or public.has_module('produtos')) then raise exception 'SEM_PERMISSAO'; end if;
  select coalesce(jsonb_agg(row_data order by row_data->>'product_code'), '[]'::jsonb)
  into v_result
  from (
    select public.get_product_commercial_price(p.codigo, v_origin, v_destination) as row_data
    from public.products p
    where (nullif(filters->>'group','') is null or p.grupo=filters->>'group')
      and (nullif(filters->>'brand','') is null or p.marca=filters->>'brand')
      and (nullif(filters->>'line','') is null or p.categoria=filters->>'line')
    order by p.codigo limit v_limit
  ) q
  where (coalesce((filters->>'only_valid_price')::boolean,false)=false or row_data->>'status' in ('OK','OK_SEM_ST'))
    and (coalesce((filters->>'only_available')::boolean,false)=false or row_data->>'availability' <> 'INDISPONIVEL');
  return jsonb_build_object('route', v_origin || '-' || v_destination, 'rows', v_result, 'count', jsonb_array_length(v_result));
end;
$$;

grant execute on function public.calculate_taxed_unit_price(numeric, public.fiscal_tax_rules),
  public.calculate_product_price(text,text,text,numeric,date,text),
  public.get_product_commercial_price(text,text,text,date,text),
  public.get_products_commercial_prices(jsonb,text,text,date,text),
  public.get_product_route_prices(text),
  public.get_fiscal_pending(jsonb),
  public.generate_commercial_list(text,jsonb) to authenticated;

comment on function public.calculate_product_price(text,text,text,numeric,date,text)
  is 'Fonte de verdade fiscal: IPI, ICMS próprio, base MVA, ICMS-ST, PIS, COFINS, FCP e despesas com precisão numeric(16,6).';
comment on function public.get_product_commercial_price(text,text,text,date,text)
  is 'Une preço base e estoque da filial ao cálculo fiscal da rota.';

commit;
