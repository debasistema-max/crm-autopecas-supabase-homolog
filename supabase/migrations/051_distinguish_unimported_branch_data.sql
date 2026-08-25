begin;

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
  v_price_imported boolean;
  v_stock_imported boolean;
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
  v_calc:=public.calculate_product_price(v_product.codigo,v_branch.state,destination_uf,
    case when v_price_imported then v_price.sale_price else null end,target_date,customer_type);
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
    'description',v_product.descricao,'brand',v_product.marca,'application',v_product.aplicacao,'year',v_product.ano,
    'branch_id',v_branch.id,'branch',v_branch.code,'branch_name',v_branch.name,
    'base_price_version',case when v_price_imported then v_price.version else null end,
    'base_price_updated_at',case when v_price_imported then v_price.updated_at else null end,
    'available_qty',v_available,'available_qty_capped',case when v_stock_imported then coalesce(v_stock.available_qty_capped,false) else false end,
    'source_display_value',case when v_stock_imported then v_stock.source_display_value else null end,
    'availability',v_availability,'stock_version',case when v_stock_imported then v_stock.version else null end,
    'stock_updated_at',case when v_stock_imported then v_stock.updated_at else null end
  );
end;
$$;

create or replace function public.get_fiscal_pending(filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit integer:=least(greatest(coalesce((filters->>'limit')::integer,200),1),5000);
  v_offset integer:=greatest(coalesce((filters->>'offset')::integer,0),0);
  v_rows jsonb;
  v_summary jsonb;
begin
  if auth.uid() is not null and not (public.is_admin() or public.has_module('alimentacao') or public.has_module('configuracoes')) then
    raise exception 'SEM_PERMISSAO';
  end if;
  with routes(origin,destination) as (values ('PR','PR'),('SP','SP'),('PR','SC')),
  pending as (
    select p.codigo,p.descricao,p.marca,p.ncm,p.cest,p.ipi_defined,r.origin||'-'||r.destination route,
      case
        when p.ncm is null then 'NCM_AUSENTE'
        when fr.id is null then 'REGRA_FISCAL_AUSENTE'
        when fr.interstate_icms_rate is null or (coalesce(fr.has_st,false) and (fr.internal_icms_rate is null or fr.mva_rate is null)) then 'REGRA_FISCAL_INCOMPLETA'
        when bp.product_code is null or bp.sale_price<=0 or (bp.source_batch_id is null and bp.source='LEGACY_SYNC') then 'PRECO_AUSENTE'
        when bs.product_code is null or (bs.source_batch_id is null and coalesce(bs.version,0)=0) then 'ESTOQUE_NAO_IMPORTADO'
        else null
      end status
    from public.products p cross join routes r
    left join public.branches b on b.code=r.origin and b.active
    left join public.product_branch_prices bp on bp.product_code=p.codigo and bp.branch_id=b.id
    left join public.product_branch_stock bs on bs.product_code=p.codigo and bs.branch_id=b.id
    left join lateral (
      select x.* from public.fiscal_tax_rules x where x.active and x.ncm=p.ncm and x.uf_origem=r.origin and x.uf_destino=r.destination
        and x.effective_from<=current_date and (x.effective_to is null or x.effective_to>=current_date)
      order by x.effective_from desc limit 1
    ) fr on true
  ), filtered as (
    select * from pending where status is not null
      and (nullif(filters->>'status','') is null or status=filters->>'status')
      and (nullif(filters->>'route','') is null or route=upper(filters->>'route'))
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.codigo,x.route),'[]'::jsonb) into v_rows
  from (select * from filtered order by codigo,route limit v_limit offset v_offset) x;

  select jsonb_build_object(
    'products_without_ncm',(select count(*) from public.products where ncm is null),
    'products_without_cest',(select count(*) from public.products where cest is null),
    'products_without_ipi',(select count(*) from public.products where not ipi_defined),
    'rules_incomplete',(select count(*) from public.fiscal_tax_rules f where f.active and
      (f.interstate_icms_rate is null or (coalesce(f.has_st,false) and (f.internal_icms_rate is null or f.mva_rate is null)))),
    'products_without_price_pr',(select count(*) from public.products p join public.branches b on b.code='PR'
      left join public.product_branch_prices bp on bp.product_code=p.codigo and bp.branch_id=b.id
      where bp.product_code is null or bp.sale_price<=0 or (bp.source_batch_id is null and bp.source='LEGACY_SYNC')),
    'products_without_price_sp',(select count(*) from public.products p join public.branches b on b.code='SP'
      left join public.product_branch_prices bp on bp.product_code=p.codigo and bp.branch_id=b.id
      where bp.product_code is null or bp.sale_price<=0 or (bp.source_batch_id is null and bp.source='LEGACY_SYNC')),
    'products_without_stock_pr',(select count(*) from public.products p join public.branches b on b.code='PR'
      left join public.product_branch_stock bs on bs.product_code=p.codigo and bs.branch_id=b.id
      where bs.product_code is null or (bs.source_batch_id is null and coalesce(bs.version,0)=0)),
    'products_without_stock_sp',(select count(*) from public.products p join public.branches b on b.code='SP'
      left join public.product_branch_stock bs on bs.product_code=p.codigo and bs.branch_id=b.id
      where bs.product_code is null or (bs.source_batch_id is null and coalesce(bs.version,0)=0))
  ) into v_summary;
  return jsonb_build_object('summary',v_summary,'rows',v_rows,'limit',v_limit,'offset',v_offset);
end;
$$;

comment on function public.get_product_commercial_price(text,text,text,date,text)
  is 'Preço/estoque comercial distingue valores importados de linhas técnicas LEGACY_SYNC criadas apenas para compatibilidade.';

commit;
