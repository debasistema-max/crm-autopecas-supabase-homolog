begin;
set local lock_timeout='10s';
set local statement_timeout='110s';

-- Preserve legacy product pickers. Only the catalog opts into fiscal pricing.
create function public.search_product_catalog_pricing(filters jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare
  v_origin text:=upper(btrim(coalesce(filters->>'region','SP')));
  v_destination text:=public.normalize_fiscal_uf(coalesce(filters->>'destination_uf',filters->>'region','SP'));
  v_result jsonb:='[]'; v_product jsonb; v_price jsonb; v_status text;
  v_base numeric; v_taxes numeric; v_final numeric;
begin
  if not public.is_app_session_active() or not public.is_internal_user()
    or not(public.is_admin() or public.has_module('produtos')) then raise exception 'SEM_PERMISSAO'; end if;
  if jsonb_typeof(filters) is distinct from 'object' then raise exception 'FILTROS_INVALIDOS'; end if;
  if v_origin not in ('SP','PR') or v_destination is null then raise exception 'ROTA_INVALIDA'; end if;
  for v_product in select value from jsonb_array_elements(public.search_products_v2(
    filters||jsonb_build_object('region',v_origin,'context','produtos')
  )) loop
    v_price:=public.get_product_commercial_price(v_product->>'codigo',v_origin,v_destination,public.commercial_business_date(),'REVENDA');
    v_status:=coalesce(v_price->>'status','PRECO_FISCAL_INDISPONIVEL');
    v_base:=nullif(v_price->>'base_price','')::numeric;
    v_taxes:=nullif(v_price->>'total_taxes','')::numeric;
    v_final:=nullif(v_price->>'final_price','')::numeric;
    if v_base is null or v_base<=0 then v_base:=null; end if;
    if upper(v_status) not like 'OK%' then
      v_taxes:=null;v_final:=null;
    elsif v_base is null or v_taxes is null or v_taxes<0 or v_final is null or v_final<=0 then
      v_status:='PRECO_FISCAL_INCOMPLETO';v_taxes:=null;v_final:=null;
    end if;
    v_result:=v_result||jsonb_build_array(v_product||jsonb_build_object(
      'preco',v_final,'fiscal',jsonb_build_object('origin',v_origin,'destination',v_destination,
        'route',v_origin||'-'||v_destination,'base_price',v_base,'total_taxes',v_taxes,'final_price',v_final,
        'status',v_status,'price_source',v_price->'price_source','warnings',coalesce(v_price->'warnings','[]'::jsonb))
    ));
  end loop;
  return v_result;
end $$;
revoke all on function public.search_product_catalog_pricing(jsonb) from public,anon,authenticated,service_role,ips_catalog_worker;
grant execute on function public.search_product_catalog_pricing(jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
