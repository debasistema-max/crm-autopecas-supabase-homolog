begin;

-- The workbook remains the fiscal source of truth for the three approved
-- commercial routes. The internal fiscal engine is retained as an explicit
-- fallback for missing or non-approved route snapshots.
create or replace function public.get_product_commercial_price(
  product_code text,
  origin_branch text,
  destination_uf text,
  target_date date default current_date,
  customer_type text default 'REVENDA'
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
  v_route_price public.product_route_prices;
  v_calc jsonb;
  v_available numeric(16,6);
  v_availability text;
  v_price_imported boolean;
  v_stock_imported boolean;
  v_destination text := public.normalize_fiscal_uf(destination_uf);
  v_route text;
  v_customer_type text := case
    when upper(coalesce(nullif(btrim(customer_type),''),'REVENDA')) = 'CONSUMO' then 'REVENDA'
    else upper(coalesce(nullif(btrim(customer_type),''),'REVENDA'))
  end;
  v_fallback_warning text;
begin
  if auth.uid() is not null and not (public.is_admin() or public.has_module('produtos')
      or public.has_module('novo_pedido') or public.has_module('nova_cotacao')) then
    raise exception 'SEM_PERMISSAO';
  end if;

  select * into v_branch from public.branches
  where active and (code=upper(btrim(origin_branch)) or id::text=btrim(origin_branch))
  order by case when code=upper(btrim(origin_branch)) then 0 else 1 end limit 1;
  if v_branch.id is null then
    return jsonb_build_object('product_code',btrim(product_code),'status','FILIAL_NAO_LOCALIZADA','warnings','[]'::jsonb);
  end if;

  select * into v_product from public.products where codigo=btrim(product_code);
  if v_product.codigo is null then
    return jsonb_build_object('product_code',btrim(product_code),'branch',v_branch.code,
      'status','PRODUTO_NAO_LOCALIZADO','warnings','[]'::jsonb);
  end if;

  select bp.* into v_price from public.product_branch_prices bp
  where bp.product_code=v_product.codigo and bp.branch_id=v_branch.id
    and bp.valid_from<=target_date and (bp.valid_until is null or bp.valid_until>=target_date);
  select bs.* into v_stock from public.product_branch_stock bs
  where bs.product_code=v_product.codigo and bs.branch_id=v_branch.id;

  v_price_imported:=v_price.product_code is not null
    and not (v_price.source_batch_id is null and v_price.source='LEGACY_SYNC' and v_price.sale_price=0);
  v_stock_imported:=v_stock.product_code is not null
    and not (v_stock.source_batch_id is null and coalesce(v_stock.version,0)=0);
  v_route:=case when v_destination is null then null else v_branch.state||'-'||v_destination end;

  select rp.* into v_route_price
  from public.product_route_prices rp
  where rp.product_code=v_product.codigo
    and rp.origin_branch_id=v_branch.id
    and rp.route=v_route
  limit 1;

  if v_route_price.product_code is not null
     and v_route_price.final_price is not null
     and upper(coalesce(v_route_price.calculation_status,'OK')) like 'OK%' then
    v_calc:=jsonb_build_object(
      'product_code',v_product.codigo,
      'route',v_route,
      'origin_state',v_branch.state,
      'destination_state',v_destination,
      'ncm',public.normalize_ncm(v_product.ncm),
      'cest',v_product.cest,
      'base_price',coalesce(v_route_price.base_price,case when v_price_imported then v_price.sale_price else null end),
      'total_taxes',v_route_price.total_taxes,
      'total_expenses',0,
      'final_price',v_route_price.final_price,
      'ipi_amount',v_route_price.tax_breakdown->'ipi',
      'own_icms_amount',v_route_price.tax_breakdown->'icms_proprio',
      'icms_st_amount',v_route_price.tax_breakdown->'icms_st',
      'pis_amount',v_route_price.tax_breakdown->'pis',
      'cofins_amount',v_route_price.tax_breakdown->'cofins',
      'fcp_amount',v_route_price.tax_breakdown->'fcp',
      'tax_breakdown',v_route_price.tax_breakdown,
      'status','OK',
      'warnings','[]'::jsonb,
      'customer_type','REVENDA',
      'requested_customer_type',v_customer_type,
      'calculation_profile','EXCEL_CONSOLIDATED',
      'calculation_method','EXCEL_RESULT',
      'price_source','EXCEL_ROUTE_PRICE',
      'source_calculation_status',v_route_price.calculation_status,
      'route_price_source',v_route_price.source,
      'route_price_version',v_route_price.version,
      'route_price_source_version',v_route_price.source_version,
      'route_price_source_updated_at',v_route_price.source_updated_at,
      'route_price_batch_id',v_route_price.source_batch_id,
      'calculated_at',v_route_price.source_updated_at
    );
  else
    v_calc:=public.calculate_product_price(
      v_product.codigo,
      v_branch.state,
      v_destination,
      case when v_price_imported then v_price.sale_price else null end,
      target_date,
      v_customer_type
    );
    v_fallback_warning:=case
      when v_route_price.product_code is null then 'PRECO_ROTA_EXCEL_AUSENTE'
      else 'PRECO_ROTA_EXCEL_NAO_APROVADO'
    end;
    v_calc:=v_calc||jsonb_build_object(
      'price_source','SUPABASE_FISCAL_FALLBACK',
      'requested_customer_type',v_customer_type,
      'route_price_status',v_route_price.calculation_status,
      'warnings',coalesce(v_calc->'warnings','[]'::jsonb)||jsonb_build_array(v_fallback_warning)
    );
  end if;

  if not v_stock_imported then
    v_calc:=jsonb_set(v_calc,'{warnings}',coalesce(v_calc->'warnings','[]'::jsonb)||jsonb_build_array('ESTOQUE_NAO_IMPORTADO'),true);
  end if;
  v_available:=case when v_stock_imported then coalesce(v_stock.sap_general_available_qty,v_stock.available_qty,0) else null end;
  v_availability:=case
    when not v_stock_imported then 'ESTOQUE_NAO_IMPORTADO'
    when v_available<=0 then 'INDISPONIVEL'
    when v_stock.available_qty_capped or v_available>=50 then 'DISPONIVEL'
    else 'CONFIRMAR'
  end;

  return v_calc||jsonb_build_object(
    'description',v_product.descricao,
    'brand',v_product.marca,
    'application',v_product.aplicacao,
    'year',v_product.ano,
    'branch_id',v_branch.id,
    'branch',v_branch.code,
    'branch_name',v_branch.name,
    'base_price_version',case when v_price_imported then v_price.version else null end,
    'base_price_updated_at',case when v_price_imported then v_price.updated_at else null end,
    'available_qty',v_available,
    'available_qty_capped',case when v_stock_imported then coalesce(v_stock.available_qty_capped,false) else false end,
    'source_display_value',case when v_stock_imported then v_stock.source_display_value else null end,
    'availability',v_availability,
    'stock_version',case when v_stock_imported then v_stock.version else null end,
    'stock_updated_at',case when v_stock_imported then v_stock.updated_at else null end
  );
end;
$$;

grant execute on function public.get_product_commercial_price(text,text,text,date,text) to authenticated;

comment on function public.get_product_commercial_price(text,text,text,date,text)
  is 'Prioriza o preço fiscal final consolidado do Excel por rota; usa o motor fiscal interno apenas como contingência identificada.';

commit;
