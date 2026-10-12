begin;

create or replace function public.list_order_transfer_request_summaries(target_order_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  v_rows jsonb;
begin
  actor := public.commercial_active_profile();
  if actor.id is null then raise exception 'SEM_PERMISSAO'; end if;
  if not (actor.perfil = 'ADMIN' or public.has_module('pedidos')) then
    raise exception 'SEM_PERMISSAO';
  end if;

  select coalesce(jsonb_agg(to_jsonb(rows) order by rows.total desc, rows.order_id), '[]'::jsonb)
  into v_rows
  from (
    select
      r.order_id,
      count(*)::integer as total,
      count(*) filter (where r.status = 'PENDING')::integer as pending,
      count(*) filter (where r.status = 'APPROVED')::integer as approved,
      count(*) filter (where r.status = 'IN_TRANSIT')::integer as in_transit,
      count(*) filter (where r.status = 'RECEIVED')::integer as received,
      count(*) filter (where r.status = 'CANCELLED')::integer as cancelled
    from public.stock_transfer_requests r
    join public.orders o on o.id = r.order_id
    where r.order_id = any(coalesce(target_order_ids, '{}')::uuid[])
      and (actor.perfil = 'ADMIN' or o.user_id = actor.id or public.has_module('pedidos'))
    group by r.order_id
  ) rows;

  return v_rows;
end;
$$;

create or replace function public.list_order_transfer_requests(target_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  order_row public.orders;
  v_rows jsonb;
begin
  actor := public.commercial_active_profile();
  if actor.id is null then raise exception 'SEM_PERMISSAO'; end if;

  select * into order_row from public.orders where id = target_order_id;
  if order_row.id is null then raise exception 'PEDIDO_NAO_ENCONTRADO'; end if;
  if not (actor.perfil = 'ADMIN' or order_row.user_id = actor.id or public.has_module('pedidos')) then
    raise exception 'SEM_PERMISSAO';
  end if;

  select coalesce(jsonb_agg(to_jsonb(rows) order by rows.created_at desc), '[]'::jsonb)
  into v_rows
  from (
    select
      r.id,
      r.status,
      r.product_code,
      r.requested_qty,
      r.source_available_qty,
      r.target_available_qty,
      r.reason,
      r.notes,
      r.created_at,
      r.updated_at,
      src.code as source_branch_code,
      src.name as source_branch_name,
      dst.code as target_branch_code,
      dst.name as target_branch_name,
      p.descricao as product_description,
      p.marca as product_brand
    from public.stock_transfer_requests r
    join public.branches src on src.id = r.source_branch_id
    join public.branches dst on dst.id = r.target_branch_id
    left join public.products p on p.codigo = r.product_code
    where r.order_id = target_order_id
  ) rows;

  return v_rows;
end;
$$;

revoke all on function public.list_order_transfer_request_summaries(uuid[]),
  public.list_order_transfer_requests(uuid)
from public, anon;

grant execute on function public.list_order_transfer_request_summaries(uuid[]),
  public.list_order_transfer_requests(uuid)
to authenticated;

comment on function public.list_order_transfer_request_summaries(uuid[])
is 'Resumo de solicitacoes de transferencia por pedido para badges/listagens.';

comment on function public.list_order_transfer_requests(uuid)
is 'Detalhe de solicitacoes de transferencia vinculadas a um pedido.';

commit;
