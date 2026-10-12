alter table public.cadastros_clientes
  add column if not exists codigo_sap_cliente text;

create index if not exists cadastros_clientes_codigo_sap_idx
  on public.cadastros_clientes (codigo_sap_cliente);

alter table public.orders
  add column if not exists codigo_sap_cliente text;

create index if not exists orders_codigo_sap_cliente_idx
  on public.orders (codigo_sap_cliente);

drop policy if exists cadastros_clientes_crm_read on public.cadastros_clientes;
create policy cadastros_clientes_crm_read
on public.cadastros_clientes
for select
to authenticated
using (
  public.has_module('cadastros')
  or public.is_admin()
  or (
    public.has_module('novo_pedido')
    and status in ('Aprovado', 'Finalizado SAP')
  )
);

create or replace function public.create_order(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  session_profile public.profiles;
  new_order_id uuid;
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
  if session_profile.id is null or not public.has_module('novo_pedido') then
    raise exception 'SEM_PERMISSAO';
  end if;

  if coalesce(payload->>'cliente', '') = '' then
    raise exception 'CLIENTE_OBRIGATORIO';
  end if;

  if jsonb_array_length(coalesce(payload->'items', '[]'::jsonb)) = 0 then
    raise exception 'PEDIDO_SEM_ITENS';
  end if;

  select lpad((coalesce(max(regexp_replace(numero_pedido, '\\D', '', 'g')::integer), 0) + 1)::text, 6, '0')
  into next_number
  from public.orders
  where numero_pedido ~ '^[0-9]+$';

  insert into public.orders (
    numero_pedido, regiao, user_id, vendedor, codigo_sap_cliente, cliente, cnpj, telefone, endereco,
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
    'NOVO'
  )
  returning id into new_order_id;

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

    insert into public.order_items (
      order_id, item, codigo, descricao, marca, aplicacao, quantidade,
      preco_unitario, desconto_percentual, preco_final_unitario, total_item
    )
    values (
      new_order_id, idx, product_row.codigo, product_row.descricao, product_row.marca,
      product_row.aplicacao, qty, unit_price, discount, final_unit, round(final_unit * qty, 2)
    );
  end loop;

  update public.orders
  set subtotal = round(subtotal_value, 2),
      desconto_total = round(subtotal_value - total_value, 2),
      total = round(total_value, 2)
  where id = new_order_id;

  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (session_profile.id, session_profile.usuario, 'CRIAR_PEDIDO', 'orders', new_order_id::text, payload);

  return jsonb_build_object(
    'id_pedido', new_order_id,
    'numero_pedido', next_number,
    'total', round(total_value, 2)
  );
end;
$$;
