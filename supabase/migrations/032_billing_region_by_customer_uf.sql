create or replace function public.resolve_billing_region(
  billing_uf text,
  fallback_region text default 'PR'
)
returns public.order_region
language sql
immutable
as $$
  select case
    when upper(regexp_replace(coalesce(billing_uf, ''), '[^A-Za-z]', '', 'g')) = 'SP'
      then 'SP'::public.order_region
    when nullif(upper(regexp_replace(coalesce(billing_uf, ''), '[^A-Za-z]', '', 'g')), '') is not null
      then 'PR'::public.order_region
    when upper(coalesce(fallback_region, 'PR')) = 'SP'
      then 'SP'::public.order_region
    else 'PR'::public.order_region
  end;
$$;

create or replace function public.commercial_create_document(document_type text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  region_value public.order_region;
  item_data jsonb;
  product_row public.products;
  new_id uuid;
  document_number text;
  idx integer := 0;
  qty numeric;
  discount numeric;
  unit_price numeric;
  final_unit numeric;
  subtotal_value numeric := 0;
  total_value numeric := 0;
  max_discount numeric := public.max_discount_percent();
begin
  actor := public.commercial_active_profile();
  if actor.id is null then raise exception 'SEM_PERMISSAO'; end if;
  if document_type = 'pedido' and not public.has_module('novo_pedido') then raise exception 'SEM_PERMISSAO'; end if;
  if document_type = 'cotacao' and not public.has_module('nova_cotacao') then raise exception 'SEM_PERMISSAO'; end if;
  if document_type not in ('pedido', 'cotacao') then raise exception 'TIPO_DOCUMENTO_INVALIDO'; end if;
  if coalesce(btrim(payload->>'cliente'), '') = '' then raise exception 'CLIENTE_OBRIGATORIO'; end if;
  if jsonb_typeof(payload->'items') <> 'array' or jsonb_array_length(payload->'items') = 0 then raise exception 'ITENS_OBRIGATORIOS'; end if;

  region_value := public.resolve_billing_region(payload->>'cliente_estado', coalesce(nullif(payload->>'regiao', ''), 'PR'));

  if document_type = 'pedido' then
    document_number := lpad(nextval('public.order_commercial_number_seq')::text, 6, '0');
    insert into public.orders (
      numero_pedido, regiao, user_id, vendedor, codigo_sap_cliente, cliente, cnpj, telefone, endereco,
      prazo, transportadora, transportadora_cnpj, transportadora_endereco, observacao, status
    ) values (
      document_number, region_value, actor.id, actor.nome, nullif(btrim(payload->>'codigo_sap_cliente'), ''), btrim(payload->>'cliente'),
      nullif(regexp_replace(coalesce(payload->>'cnpj', ''), '\D', '', 'g'), ''), nullif(btrim(payload->>'telefone'), ''),
      nullif(btrim(payload->>'endereco'), ''), nullif(btrim(payload->>'prazo'), ''), nullif(btrim(payload->>'transportadora'), ''),
      nullif(regexp_replace(coalesce(payload->>'transportadora_cnpj', ''), '\D', '', 'g'), ''),
      nullif(btrim(payload->>'transportadora_endereco'), ''), nullif(btrim(payload->>'observacao'), ''), 'NOVO'
    ) returning id into new_id;
  else
    document_number := lpad(nextval('public.quotation_commercial_number_seq')::text, 6, '0');
    insert into public.quotations (
      numero_cotacao, regiao, user_id, vendedor, codigo_sap_cliente, cliente, cnpj, telefone, endereco,
      prazo, transportadora, transportadora_cnpj, transportadora_endereco, observacao, status
    ) values (
      document_number, region_value, actor.id, actor.nome, nullif(btrim(payload->>'codigo_sap_cliente'), ''), btrim(payload->>'cliente'),
      nullif(regexp_replace(coalesce(payload->>'cnpj', ''), '\D', '', 'g'), ''), nullif(btrim(payload->>'telefone'), ''),
      nullif(btrim(payload->>'endereco'), ''), nullif(btrim(payload->>'prazo'), ''), nullif(btrim(payload->>'transportadora'), ''),
      nullif(regexp_replace(coalesce(payload->>'transportadora_cnpj', ''), '\D', '', 'g'), ''),
      nullif(btrim(payload->>'transportadora_endereco'), ''), nullif(btrim(payload->>'observacao'), ''), 'NOVA'
    ) returning id into new_id;
  end if;

  for item_data in select value from jsonb_array_elements(payload->'items') loop
    idx := idx + 1;
    select * into product_row from public.products where codigo = btrim(item_data->>'codigo');
    if product_row.codigo is null then raise exception 'PRODUTO_NAO_ENCONTRADO: item %', idx; end if;
    qty := coalesce(nullif(item_data->>'quantidade', '')::numeric, 0);
    discount := coalesce(nullif(item_data->>'desconto_percentual', '')::numeric, 0);
    if qty <= 0 then raise exception 'QUANTIDADE_INVALIDA: item %', idx; end if;
    if discount < 0 or discount > max_discount then raise exception 'DESCONTO_INVALIDO: item %', idx; end if;
    unit_price := case when region_value = 'PR' then product_row.preco_pr else product_row.preco_sp end;
    if unit_price is null or unit_price < 0 then raise exception 'PRECO_INVALIDO: item %', idx; end if;
    final_unit := round(unit_price * (1 - discount / 100), 4);
    subtotal_value := subtotal_value + unit_price * qty;
    total_value := total_value + final_unit * qty;

    if document_type = 'pedido' then
      insert into public.order_items (order_id, item, codigo, descricao, marca, aplicacao, quantidade, preco_unitario, desconto_percentual, preco_final_unitario, total_item)
      values (new_id, idx, product_row.codigo, product_row.descricao, product_row.marca, product_row.aplicacao, qty, unit_price, discount, final_unit, round(final_unit * qty, 2));
    else
      insert into public.quotation_items (quotation_id, item, codigo, descricao, marca, aplicacao, quantidade, preco_unitario, desconto_percentual, preco_final_unitario, total_item)
      values (new_id, idx, product_row.codigo, product_row.descricao, product_row.marca, product_row.aplicacao, qty, unit_price, discount, final_unit, round(final_unit * qty, 2));
    end if;
  end loop;

  if document_type = 'pedido' then
    update public.orders set subtotal = round(subtotal_value, 2), desconto_total = round(subtotal_value - total_value, 2), total = round(total_value, 2) where id = new_id;
  else
    update public.quotations set subtotal = round(subtotal_value, 2), desconto_total = round(subtotal_value - total_value, 2), total = round(total_value, 2) where id = new_id;
  end if;
  update public.customer_timeline_events set amount = round(total_value, 2)
  where entity_id = new_id and event_type in ('PEDIDO_CRIADO', 'COTACAO_CRIADA');

  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (actor.id, actor.usuario, case when document_type = 'pedido' then 'CRIAR_PEDIDO' else 'CRIAR_COTACAO' end,
          case when document_type = 'pedido' then 'orders' else 'quotations' end, new_id::text,
          jsonb_build_object('numero', document_number, 'regiao', region_value, 'uf_faturamento', nullif(payload->>'cliente_estado', ''), 'itens', idx, 'total', round(total_value, 2)));
  return jsonb_build_object('id', new_id, case when document_type = 'pedido' then 'numero_pedido' else 'numero_cotacao' end, document_number);
exception when invalid_text_representation or numeric_value_out_of_range then
  raise exception 'VALOR_NUMERICO_INVALIDO';
end;
$$;

comment on function public.resolve_billing_region(text, text)
is 'Resolve faturamento comercial: UF SP usa filial/preco SP; demais UFs usam matriz/preco PR. Sem UF, respeita fallback normalizado, padrao PR.';
