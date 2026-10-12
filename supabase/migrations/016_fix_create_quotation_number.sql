create or replace function public.create_quotation(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  session_profile public.profiles;
  new_quotation_id uuid;
  next_number text;
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
  if session_profile.id is null or not public.has_module('nova_cotacao') then
    raise exception 'SEM_PERMISSAO';
  end if;

  if coalesce(payload->>'cliente', '') = '' then
    raise exception 'CLIENTE_OBRIGATORIO';
  end if;

  if jsonb_array_length(coalesce(payload->'items', '[]'::jsonb)) = 0 then
    raise exception 'COTACAO_SEM_ITENS';
  end if;

  select 'COT-' || lpad((coalesce(max(regexp_replace(numero_cotacao, '\D', '', 'g')::integer), 0) + 1)::text, 6, '0')
    into next_number
  from public.quotations
  where numero_cotacao ~ '^COT-[0-9]+$';

  insert into public.quotations (
    numero_cotacao, regiao, user_id, vendedor, codigo_sap_cliente, cliente, cnpj, telefone, endereco,
    prazo, transportadora, transportadora_cnpj, transportadora_endereco, observacao, status
  )
  values (
    next_number,
    coalesce((payload->>'regiao')::public.order_region, 'SP'),
    session_profile.id,
    session_profile.nome,
    nullif(payload->>'codigo_sap_cliente', ''),
    payload->>'cliente',
    payload->>'cnpj',
    payload->>'telefone',
    payload->>'endereco',
    payload->>'prazo',
    payload->>'transportadora',
    payload->>'transportadora_cnpj',
    payload->>'transportadora_endereco',
    payload->>'observacao',
    'NOVA'
  )
  returning id into new_quotation_id;

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

    unit_price := case when coalesce(payload->>'regiao', 'SP') = 'PR' then product_row.preco_pr else product_row.preco_sp end;
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
      new_quotation_id, idx, product_row.codigo, product_row.descricao, product_row.marca,
      product_row.aplicacao, qty, unit_price, discount, final_unit, round(final_unit * qty, 2)
    );
  end loop;

  update public.quotations
  set subtotal = round(subtotal_value, 2),
      desconto_total = round(subtotal_value - total_value, 2),
      total = round(total_value, 2)
  where id = new_quotation_id;

  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (session_profile.id, session_profile.usuario, 'CRIAR_COTACAO', 'quotations', new_quotation_id::text, payload);

  return jsonb_build_object(
    'id_cotacao', new_quotation_id,
    'numero_cotacao', next_number,
    'total', round(total_value, 2)
  );
end;
$$;

grant execute on function public.create_quotation(jsonb) to authenticated;
