begin;

select set_config('request.jwt.claim.sub',(
  select id::text from public.profiles where perfil='ADMIN' and ativo order by created_at limit 1
),true);

do $$
declare
  price_list jsonb:=public.get_product_commercial_price('7175526020','SP','SP',current_date,'GERAL');
  resale jsonb:=public.get_product_commercial_price('7175526020','SP','SP',current_date,'REVENDA');
  quote_result jsonb;
  order_result jsonb;
  quote_price numeric;
  order_price numeric;
begin
  if abs((price_list->>'final_price')::numeric-816.096012)>0.000001 then
    raise exception 'PRICE_LIST_SP_SP_ALTERADA: %',price_list;
  end if;
  if abs((resale->>'ipi_amount')::numeric-18.85)>0.000001 then
    raise exception 'IPI_LEGADO_DIVERGENTE: %',resale;
  end if;
  if abs((resale->>'icms_st_amount')::numeric-81.17)>0.00001 then
    raise exception 'ICMS_ST_LEGADO_DIVERGENTE: %',resale;
  end if;
  if abs((resale->>'final_price')::numeric-680.02)>0.00001 then
    raise exception 'TOTAL_LEGADO_DIVERGENTE: %',resale;
  end if;
  if resale->>'calculation_profile'<>'LEGACY_REVENDA'
    or coalesce((resale->>'own_icms_included_in_total')::boolean,true) then
    raise exception 'PERFIL_REVENDA_INCORRETO: %',resale;
  end if;

  quote_result:=public.commercial_create_document('cotacao',jsonb_build_object(
    'regiao','SP','cliente_estado','SP','customer_type','REVENDA','cliente','TESTE REGRESSAO FISCAL',
    'items',jsonb_build_array(jsonb_build_object('codigo','7175526020','quantidade',1,'desconto_percentual',0))
  ));
  order_result:=public.commercial_create_document('pedido',jsonb_build_object(
    'regiao','SP','cliente_estado','SP','customer_type','REVENDA','cliente','TESTE REGRESSAO FISCAL',
    'items',jsonb_build_array(jsonb_build_object('codigo','7175526020','quantidade',1,'desconto_percentual',0))
  ));
  select preco_unitario into quote_price from public.quotation_items where quotation_id=(quote_result->>'id')::uuid;
  select preco_unitario into order_price from public.order_items where order_id=(order_result->>'id')::uuid;
  if abs(quote_price-680.02)>0.00001 or abs(order_price-680.02)>0.00001 or quote_price<>order_price then
    raise exception 'SNAPSHOT_COTACAO_PEDIDO_DIVERGENTE: quote %, order %',quote_price,order_price;
  end if;
end;
$$;

rollback;
