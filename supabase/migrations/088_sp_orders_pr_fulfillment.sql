begin;

-- The approved workbook has no SP stock snapshot and the SP catalogue is
-- fulfilled from PR stock. When SP stock is available, transfer only the
-- shortage; otherwise request the order quantity from PR without inventing an
-- SP balance. PR stock must always be imported and available.
create or replace function public.create_order_transfer_requests(target_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  order_row public.orders;
  v_sp_branch_id uuid;
  v_pr_branch_id uuid;
  item_row record;
  target_stock public.product_branch_stock;
  source_stock public.product_branch_stock;
  target_available numeric(14,3);
  source_available numeric(14,3);
  shortage_qty numeric(14,3);
  transfer_qty numeric(14,3);
  target_imported boolean;
  source_imported boolean;
  transfer_reason text;
  created_count integer := 0;
  updated_count integer := 0;
  partial_count integer := 0;
  warnings jsonb := '[]'::jsonb;
begin
  actor := public.commercial_active_profile();
  if actor.id is null then raise exception 'SEM_PERMISSAO'; end if;
  if not (actor.perfil = 'ADMIN' or public.has_module('pedidos') or public.has_module('novo_pedido')) then
    raise exception 'SEM_PERMISSAO';
  end if;

  select * into order_row
  from public.orders
  where id = target_order_id
  for update;

  if order_row.id is null then raise exception 'PEDIDO_NAO_ENCONTRADO'; end if;
  if actor.perfil <> 'ADMIN' and order_row.user_id <> actor.id then raise exception 'SEM_PERMISSAO'; end if;

  select id into v_sp_branch_id from public.branches where code = 'SP' and active;
  select id into v_pr_branch_id from public.branches where code = 'PR' and active;
  if v_sp_branch_id is null or v_pr_branch_id is null then raise exception 'FILIAIS_INICIAIS_NAO_CRIADAS'; end if;

  if (order_row.branch_id is distinct from v_sp_branch_id and order_row.regiao::text <> 'SP')
     or coalesce(public.normalize_fiscal_uf(order_row.billing_uf), order_row.regiao::text) <> 'SP' then
    return jsonb_build_object(
      'created',0,'updated',0,'partial',0,'warnings','[]'::jsonb,'reason','PEDIDO_NAO_EH_SP_SP'
    );
  end if;

  for item_row in
    select i.id as order_item_id, i.codigo as product_code, i.quantidade
    from public.order_items i
    where i.order_id = target_order_id
    order by i.item
  loop
    select * into target_stock
    from public.product_branch_stock
    where product_code = item_row.product_code and branch_id = v_sp_branch_id
    for update;

    target_imported := target_stock.product_code is not null
      and not (target_stock.source_batch_id is null and coalesce(target_stock.version,0) = 0);

    if target_imported then
      target_available := coalesce(target_stock.available_qty,0);
      shortage_qty := greatest(coalesce(item_row.quantidade,0) - target_available,0);
      transfer_reason := 'ORDER_SP_SHORTAGE_PR_TRANSFER';
      if shortage_qty <= 0 then continue; end if;
    else
      -- The request table requires a numeric snapshot. Zero here means that
      -- this request reserves no local SP quantity; it does not create an SP
      -- stock row or turn the missing source snapshot into inventory data.
      target_available := 0;
      shortage_qty := greatest(coalesce(item_row.quantidade,0),0);
      transfer_reason := 'ORDER_SP_PR_FULFILLMENT';
      if shortage_qty <= 0 then continue; end if;
    end if;

    select * into source_stock
    from public.product_branch_stock
    where product_code = item_row.product_code and branch_id = v_pr_branch_id
    for update;

    source_imported := source_stock.product_code is not null
      and not (source_stock.source_batch_id is null and coalesce(source_stock.version,0) = 0);

    if not source_imported then
      warnings := warnings || jsonb_build_array(jsonb_build_object(
        'code','ESTOQUE_PR_NAO_IMPORTADO',
        'product_code',item_row.product_code,
        'requested_qty',item_row.quantidade,
        'sp_available_qty',target_available
      ));
      continue;
    end if;

    source_available := coalesce(source_stock.available_qty,0);
    transfer_qty := least(shortage_qty,source_available);
    if transfer_qty <= 0 then
      warnings := warnings || jsonb_build_array(jsonb_build_object(
        'code','ESTOQUE_PR_INDISPONIVEL',
        'product_code',item_row.product_code,
        'requested_qty',item_row.quantidade,
        'sp_available_qty',target_available,
        'pr_available_qty',source_available
      ));
      continue;
    end if;

    if exists (
      select 1 from public.stock_transfer_requests r
      where r.order_id = target_order_id
        and r.product_code = item_row.product_code
        and r.source_branch_id = v_pr_branch_id
        and r.target_branch_id = v_sp_branch_id
        and r.status in ('PENDING','APPROVED','IN_TRANSIT')
    ) then
      update public.stock_transfer_requests r
      set order_item_id = item_row.order_item_id,
          requested_qty = transfer_qty,
          source_available_qty = source_available,
          target_available_qty = target_available,
          requested_by = actor.id,
          reason = transfer_reason,
          updated_at = now()
      where r.order_id = target_order_id
        and r.product_code = item_row.product_code
        and r.source_branch_id = v_pr_branch_id
        and r.target_branch_id = v_sp_branch_id
        and r.status in ('PENDING','APPROVED','IN_TRANSIT');
      updated_count := updated_count + 1;
    else
      insert into public.stock_transfer_requests(
        order_id,order_item_id,product_code,source_branch_id,target_branch_id,
        requested_qty,source_available_qty,target_available_qty,reason,requested_by
      ) values(
        target_order_id,item_row.order_item_id,item_row.product_code,v_pr_branch_id,v_sp_branch_id,
        transfer_qty,source_available,target_available,transfer_reason,actor.id
      );
      created_count := created_count + 1;
    end if;

    if transfer_qty < shortage_qty then
      partial_count := partial_count + 1;
      warnings := warnings || jsonb_build_array(jsonb_build_object(
        'code','TRANSFERENCIA_PARCIAL',
        'product_code',item_row.product_code,
        'requested_qty',item_row.quantidade,
        'sp_available_qty',target_available,
        'pr_available_qty',source_available,
        'transfer_qty',transfer_qty
      ));
    end if;
  end loop;

  if created_count + updated_count > 0 then
    update public.orders
    set logistics_status = case when stock_contract_version = 0 then logistics_status else 'AWAITING_STOCK' end
    where id = target_order_id;
  end if;

  insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_novos)
  values(
    actor.id,actor.usuario,'GERAR_SOLICITACAO_TRANSFERENCIA','stock_transfer_requests',target_order_id::text,
    jsonb_build_object('created',created_count,'updated',updated_count,'partial',partial_count,'warnings',warnings)
  );

  return jsonb_build_object(
    'created',created_count,'updated',updated_count,'partial',partial_count,'warnings',warnings
  );
end;
$$;

revoke all on function public.create_order_transfer_requests(uuid) from public,anon;
grant execute on function public.create_order_transfer_requests(uuid) to authenticated;

comment on function public.create_order_transfer_requests(uuid)
  is 'Em pedido SP-SP, usa o saldo importado de SP para calcular a falta; sem snapshot SP, solicita atendimento PR-SP pela quantidade pedida, sempre limitado ao saldo importado do PR.';

commit;
