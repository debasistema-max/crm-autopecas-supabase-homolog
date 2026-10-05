begin;

set local lock_timeout = '10s';

set local statement_timeout = '110s';

-- A migration 090 passou a validar o resultado fiscal do catalogo B2B, mas
-- restringiu o status a dois textos exatos. As rotas nao abrangidas pela
-- politica SP-SP preservam o status valido da planilha (por exemplo,
-- "OK - REGRA GRUPO") e acabavam removidas do catalogo. O contrato de
-- importacao ja considera valido qualquer status iniciado por OK.
create or replace function public.b2b_search_catalog(
  search_term text,
  line_filter text,
  only_available boolean,
  limit_count integer
)
returns table(
  product_code text,description text,brand text,application text,year text,image_url text,
  route text,final_price numeric,currency text,availability text,available_qty numeric,
  source_display_value text,pr_transfer_available_qty numeric,stock_updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_discount numeric:=0;
  v_target_date date:=public.commercial_business_date();
begin
  select coalesce(c.commercial_discount_percent,0) into v_discount
  from public.customer_portal_accounts a
  join public.clients c on c.id=a.client_id and c.ativo
  where a.user_id=auth.uid() and a.active;

  return query
  select r.product_code,r.description,r.brand,r.application,r.year,r.image_url,r.route,
    round((e.calc->>'final_price')::numeric*(1-v_discount/100),4),r.currency,
    r.availability,r.available_qty,r.source_display_value,r.pr_transfer_available_qty,r.stock_updated_at
  from public.b2b_search_catalog_raw_090(search_term,line_filter,only_available,limit_count) r
  join public.branches b on b.code=split_part(r.route,'-',1) and b.active
  join public.product_route_prices rp
    on rp.product_code=r.product_code
   and rp.origin_branch_id=b.id
   and rp.route=r.route
  cross join lateral (
    select public.apply_commercial_tax_policy(jsonb_build_object(
      'product_code',r.product_code,'route',r.route,'origin_state',split_part(r.route,'-',1),
      'destination_state',split_part(r.route,'-',2),'base_price',rp.base_price,
      'total_taxes',rp.total_taxes,'final_price',rp.final_price,'ipi_amount',rp.tax_breakdown->'ipi',
      'icms_st_amount',rp.tax_breakdown->'icms_st','tax_breakdown',rp.tax_breakdown,
      'status',coalesce(rp.calculation_status,'OK'),'warnings','[]'::jsonb
    ),split_part(r.route,'-',1),split_part(r.route,'-',2),v_target_date) calc
  ) e
  where upper(coalesce(e.calc->>'status','')) like 'OK%';
end;
$$;

create or replace function public.b2b_get_catalog_product_detail(p_product_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_raw jsonb;
  v_calc jsonb;
  v_discount numeric:=0;
  v_route text;
  v_target_date date:=public.commercial_business_date();
begin
  v_raw:=public.b2b_get_catalog_product_detail_raw_090(p_product_code);
  v_route:=v_raw->>'route';

  select coalesce(c.commercial_discount_percent,0) into v_discount
  from public.customer_portal_accounts a
  join public.clients c on c.id=a.client_id and c.ativo
  where a.user_id=auth.uid() and a.active;

  select public.apply_commercial_tax_policy(jsonb_build_object(
    'product_code',rp.product_code,'route',rp.route,'origin_state',split_part(rp.route,'-',1),
    'destination_state',split_part(rp.route,'-',2),'base_price',rp.base_price,
    'total_taxes',rp.total_taxes,'final_price',rp.final_price,'ipi_amount',rp.tax_breakdown->'ipi',
    'icms_st_amount',rp.tax_breakdown->'icms_st','tax_breakdown',rp.tax_breakdown,
    'status',coalesce(rp.calculation_status,'OK'),'warnings','[]'::jsonb
  ),split_part(rp.route,'-',1),split_part(rp.route,'-',2),v_target_date) into v_calc
  from public.product_route_prices rp
  join public.branches b on b.id=rp.origin_branch_id and b.active
  where rp.product_code=public.normalize_integration_product_code(p_product_code)
    and rp.route=v_route;

  if upper(coalesce(v_calc->>'status','')) not like 'OK%' then
    raise exception 'PRECO_B2B_INDISPONIVEL';
  end if;

  return v_raw||jsonb_build_object(
    'final_price',round((v_calc->>'final_price')::numeric*(1-v_discount/100),4),
    'tax_policy_applied',coalesce((v_calc->>'tax_policy_applied')::boolean,false),
    'tax_policy_code',v_calc->>'tax_policy_code'
  );
end;
$$;

revoke all on function public.b2b_search_catalog(text,text,boolean,integer),
  public.b2b_get_catalog_product_detail(text)
  from public,anon;

grant execute on function public.b2b_search_catalog(text,text,boolean,integer),
  public.b2b_get_catalog_product_detail(text)
  to authenticated;

comment on function public.b2b_search_catalog(text,text,boolean,integer) is
  'Catalogo B2B com politica fiscal efetiva; preserva todos os status validos iniciados por OK.';

commit;
