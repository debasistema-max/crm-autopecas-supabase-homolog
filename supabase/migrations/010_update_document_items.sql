create or replace function public.update_order_items(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  session_profile public.profiles;
  target_order public.orders;
  item_data jsonb;
  idx integer := 0;
  product_row public.products;
  qty numeric;
  discount numeric;
  unit_price numeric;
  final_unit numeric;
  subtotal_value numeric := 0;
  total_value numeric := 0;
  max_discount numeric := public.max_discount_percent();
begin
  select * into session_profile from public.profiles where id = auth.uid() and ativo = true;
  if session_profile.id is null or not (public.is_admin() or public.has_module('pedidos')) then
    raise exception 'SEM_PERMISSAO';
  end if;

  select * into target_order from public.orders where id = (payload->>'id')::uuid;
  if target_order.id is null then
    raise exception 'PEDIDO_NAO_ENCONTRADO';
  end if;

  if jsonb_array_length(coalesce(payload->'items', '[]'::jsonb)) = 0 then
    raise exception 'PEDIDO_SEM_ITENS';
  end if;

  delete from public.order_items where order_id = target_order.id;

  for item_data in select * from jsonb_array_elements(payload->'items')
  loop
    idx := idx + 1;
    select * into product_row from public.products where codigo = item_data->>'codigo';
    if product_row.codigo is null then
      raise exception 'PRODUTO_NAO_ENCONTRADO';
    end if;

    qty := greatest(coalesce((item_data->>'quantidade')::numeric, 1), 1);
    discount := greatest(coalesce((item_data->>'desconto_percentual')::numeric, 0), 0);
    if discount > max_discount then
      raise exception 'DESCONTO_MAXIMO_EXCEDIDO';
    end if;

    unit_price := case when target_order.regiao = 'PR' then product_row.preco_pr else product_row.preco_sp end;
    if unit_price <= 0 then
      raise exception 'PRECO_INVALIDO';
    end if;

    final_unit := unit_price * (1 - discount / 100);
    subtotal_value := subtotal_value + (unit_price * qty);
    total_value := total_value + (final_unit * qty);

    insert into public.order_items (
      order_id, item, codigo, descricao, marca, aplicacao, quantidade,
      preco_unitario, desconto_percentual, preco_final_unitario, total_item
    )
    values (
      target_order.id, idx, product_row.codigo, product_row.descricao, product_row.marca,
      product_row.aplicacao, qty, unit_price, discount, final_unit, round(final_unit * qty, 2)
    );
  end loop;

  update public.orders
  set subtotal = round(subtotal_value, 2),
      desconto_total = round(subtotal_value - total_value, 2),
      total = round(total_value, 2)
  where id = target_order.id;

  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (session_profile.id, session_profile.usuario, 'ATUALIZAR_ITENS_PEDIDO', 'orders', target_order.id::text, payload);

  return jsonb_build_object(
    'id_pedido', target_order.id,
    'numero_pedido', target_order.numero_pedido,
    'total', round(total_value, 2)
  );
end;
$$;

create or replace function public.update_quotation_items(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  session_profile public.profiles;
  target_quotation public.quotations;
  item_data jsonb;
  idx integer := 0;
  product_row public.products;
  qty numeric;
  discount numeric;
  unit_price numeric;
  final_unit numeric;
  subtotal_value numeric := 0;
  total_value numeric := 0;
  max_discount numeric := public.max_discount_percent();
begin
  select * into session_profile from public.profiles where id = auth.uid() and ativo = true;
  if session_profile.id is null or not (public.is_admin() or public.has_module('cotacoes')) then
    raise exception 'SEM_PERMISSAO';
  end if;

  select * into target_quotation from public.quotations where id = (payload->>'id')::uuid;
  if target_quotation.id is null then
    raise exception 'COTACAO_NAO_ENCONTRADA';
  end if;

  if jsonb_array_length(coalesce(payload->'items', '[]'::jsonb)) = 0 then
    raise exception 'COTACAO_SEM_ITENS';
  end if;

  delete from public.quotation_items where quotation_id = target_quotation.id;

  for item_data in select * from jsonb_array_elements(payload->'items')
  loop
    idx := idx + 1;
    select * into product_row from public.products where codigo = item_data->>'codigo';
    if product_row.codigo is null then
      raise exception 'PRODUTO_NAO_ENCONTRADO';
    end if;

    qty := greatest(coalesce((item_data->>'quantidade')::numeric, 1), 1);
    discount := greatest(coalesce((item_data->>'desconto_percentual')::numeric, 0), 0);
    if discount > max_discount then
      raise exception 'DESCONTO_MAXIMO_EXCEDIDO';
    end if;

    unit_price := case when target_quotation.regiao = 'PR' then product_row.preco_pr else product_row.preco_sp end;
    if unit_price <= 0 then
      raise exception 'PRECO_INVALIDO';
    end if;

    final_unit := unit_price * (1 - discount / 100);
    subtotal_value := subtotal_value + (unit_price * qty);
    total_value := total_value + (final_unit * qty);

    insert into public.quotation_items (
      quotation_id, item, codigo, descricao, marca, aplicacao, quantidade,
      preco_unitario, desconto_percentual, preco_final_unitario, total_item
    )
    values (
      target_quotation.id, idx, product_row.codigo, product_row.descricao, product_row.marca,
      product_row.aplicacao, qty, unit_price, discount, final_unit, round(final_unit * qty, 2)
    );
  end loop;

  update public.quotations
  set subtotal = round(subtotal_value, 2),
      desconto_total = round(subtotal_value - total_value, 2),
      total = round(total_value, 2)
  where id = target_quotation.id;

  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (session_profile.id, session_profile.usuario, 'ATUALIZAR_ITENS_COTACAO', 'quotations', target_quotation.id::text, payload);

  return jsonb_build_object(
    'id_cotacao', target_quotation.id,
    'numero_cotacao', target_quotation.numero_cotacao,
    'total', round(total_value, 2)
  );
end;
$$;
