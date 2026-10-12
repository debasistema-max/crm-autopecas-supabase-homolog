create or replace function public.get_dashboard_summary()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  profile_row public.profiles;
  today_start timestamptz := date_trunc('day', now());
  orders_today_count integer := 0;
  orders_today_total numeric := 0;
  missing_products integer := 0;
  zero_stock integer := 0;
  orders_summary jsonb;
  quotations_summary jsonb;
  recent_orders jsonb;
begin
  select * into profile_row from public.profiles where id = auth.uid() and ativo = true;
  if profile_row.id is null then
    raise exception 'SEM_PERMISSAO';
  end if;

  select count(*), coalesce(sum(total), 0)
    into orders_today_count, orders_today_total
  from public.orders
  where created_at >= today_start
    and (public.is_admin() or public.has_module('pedidos') or user_id = auth.uid());

  select count(*) into missing_products
  from public.products
  where status_cadastro = 'NAO_CADASTRADO'
    and (public.has_module('produtos') or public.has_module('novo_pedido') or public.has_module('nova_cotacao') or public.is_admin());

  select count(*) into zero_stock
  from public.products
  where estoque_quantidade <= 0
    and (public.has_module('produtos') or public.has_module('novo_pedido') or public.has_module('nova_cotacao') or public.is_admin());

  with visible_orders as (
    select status::text as status, total
    from public.orders
    where public.is_admin() or public.has_module('pedidos') or user_id = auth.uid()
  )
  select jsonb_build_object(
    'total', jsonb_build_object('count', count(*), 'value', coalesce(sum(total), 0)),
    'aberto', jsonb_build_object('count', count(*) filter (where status in ('NOVO','EM_ANALISE')), 'value', coalesce(sum(total) filter (where status in ('NOVO','EM_ANALISE')), 0)),
    'efetivado', jsonb_build_object('count', count(*) filter (where status in ('APROVADO','FATURADO')), 'value', coalesce(sum(total) filter (where status in ('APROVADO','FATURADO')), 0)),
    'cancelado', jsonb_build_object('count', count(*) filter (where status = 'CANCELADO'), 'value', coalesce(sum(total) filter (where status = 'CANCELADO'), 0))
  ) into orders_summary
  from visible_orders;

  with visible_quotations as (
    select status::text as status, total
    from public.quotations
    where public.is_admin() or public.has_module('cotacoes') or user_id = auth.uid()
  )
  select jsonb_build_object(
    'total', jsonb_build_object('count', count(*), 'value', coalesce(sum(total), 0)),
    'aberto', jsonb_build_object('count', count(*) filter (where status in ('NOVA','ENVIADA')), 'value', coalesce(sum(total) filter (where status in ('NOVA','ENVIADA')), 0)),
    'efetivado', jsonb_build_object('count', count(*) filter (where status in ('APROVADA','CONVERTIDA')), 'value', coalesce(sum(total) filter (where status in ('APROVADA','CONVERTIDA')), 0)),
    'cancelado', jsonb_build_object('count', count(*) filter (where status = 'CANCELADA'), 'value', coalesce(sum(total) filter (where status = 'CANCELADA'), 0))
  ) into quotations_summary
  from visible_quotations;

  select coalesce(jsonb_agg(to_jsonb(row_data)), '[]'::jsonb)
    into recent_orders
  from (
    select numero_pedido, cliente, vendedor, status::text as status, total, created_at
    from public.orders
    where public.is_admin() or public.has_module('pedidos') or user_id = auth.uid()
    order by created_at desc
    limit 8
  ) row_data;

  return jsonb_build_object(
    'pedidosHoje', orders_today_count,
    'totalHoje', orders_today_total,
    'ultimosPedidos', recent_orders,
    'resumoPedidos', orders_summary,
    'resumoCotacoes', quotations_summary,
    'produtosSemCadastro', missing_products,
    'estoqueZerado', zero_stock
  );
end;
$$;

create or replace function public.get_product_filters()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'grupos',
      coalesce((
        select jsonb_agg(value order by value)
        from (
          select distinct nullif(trim(grupo), '') as value
          from public.products
          where grupo is not null
            and (public.has_module('produtos') or public.has_module('novo_pedido') or public.has_module('nova_cotacao') or public.is_admin())
        ) rows
        where value is not null
      ), '[]'::jsonb),
    'linhas',
      coalesce((
        select jsonb_agg(value order by value)
        from (
          select distinct nullif(trim(categoria), '') as value
          from public.products
          where categoria is not null
            and (public.has_module('produtos') or public.has_module('novo_pedido') or public.has_module('nova_cotacao') or public.is_admin())
        ) rows
        where value is not null
      ), '[]'::jsonb)
  );
$$;

create or replace function public.update_document_status(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  profile_row public.profiles;
  doc_type text := payload->>'type';
  target_id uuid := (payload->>'id')::uuid;
  target_status text := payload->>'status';
  order_row public.orders;
  quotation_row public.quotations;
begin
  select * into profile_row from public.profiles where id = auth.uid() and ativo = true;
  if profile_row.id is null then
    raise exception 'SEM_PERMISSAO';
  end if;

  if doc_type = 'pedido' then
    if not (public.is_admin() or public.has_module('pedidos')) then
      raise exception 'SEM_PERMISSAO';
    end if;
    if target_status not in ('NOVO','EM_ANALISE','APROVADO','CANCELADO','FATURADO') then
      raise exception 'STATUS_INVALIDO';
    end if;
    update public.orders
      set status = target_status::public.order_status
      where id = target_id
      returning * into order_row;
    if order_row.id is null then
      raise exception 'PEDIDO_NAO_ENCONTRADO';
    end if;
    insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
    values (profile_row.id, profile_row.usuario, 'ATUALIZAR_STATUS_PEDIDO', 'orders', target_id::text, payload);
    return jsonb_build_object('id', order_row.id, 'numero_pedido', order_row.numero_pedido, 'status', order_row.status);
  end if;

  if doc_type = 'cotacao' then
    if not (public.is_admin() or public.has_module('cotacoes')) then
      raise exception 'SEM_PERMISSAO';
    end if;
    if target_status not in ('NOVA','ENVIADA','APROVADA','CANCELADA','CONVERTIDA') then
      raise exception 'STATUS_INVALIDO';
    end if;
    update public.quotations
      set status = target_status::public.quotation_status
      where id = target_id
      returning * into quotation_row;
    if quotation_row.id is null then
      raise exception 'COTACAO_NAO_ENCONTRADA';
    end if;
    insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
    values (profile_row.id, profile_row.usuario, 'ATUALIZAR_STATUS_COTACAO', 'quotations', target_id::text, payload);
    return jsonb_build_object('id', quotation_row.id, 'numero_cotacao', quotation_row.numero_cotacao, 'status', quotation_row.status);
  end if;

  raise exception 'TIPO_INVALIDO';
end;
$$;

drop policy if exists orders_admin_update on public.orders;
drop policy if exists quotations_update on public.quotations;
