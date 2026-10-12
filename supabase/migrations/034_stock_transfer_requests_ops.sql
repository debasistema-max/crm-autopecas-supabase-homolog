begin;

create or replace function public.list_stock_transfer_requests(filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  v_status text := nullif(upper(btrim(coalesce(filters->>'status', ''))), '');
  v_term text := nullif(btrim(coalesce(filters->>'term', '')), '');
  v_digits text := nullif(regexp_replace(coalesce(filters->>'term', ''), '\D', '', 'g'), '');
  v_from timestamptz := nullif(filters->>'from', '')::timestamptz;
  v_to timestamptz := nullif(filters->>'to', '')::timestamptz;
  v_rows jsonb;
begin
  actor := public.commercial_active_profile();
  if actor.id is null then raise exception 'SEM_PERMISSAO'; end if;
  if not (actor.perfil = 'ADMIN' or public.has_module('pedidos')) then
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
      o.id as order_id,
      o.numero_pedido,
      o.cliente,
      o.cnpj,
      o.vendedor,
      p.descricao as product_description,
      p.marca as product_brand
    from public.stock_transfer_requests r
    join public.orders o on o.id = r.order_id
    join public.branches src on src.id = r.source_branch_id
    join public.branches dst on dst.id = r.target_branch_id
    left join public.products p on p.codigo = r.product_code
    where (actor.perfil = 'ADMIN' or o.user_id = actor.id or public.has_module('pedidos'))
      and (v_status is null or r.status = v_status)
      and (v_from is null or r.created_at >= v_from)
      and (v_to is null or r.created_at < v_to)
      and (
        v_term is null
        or o.numero_pedido ilike '%' || v_term || '%'
        or o.cliente ilike '%' || v_term || '%'
        or (v_digits is not null and o.cnpj ilike '%' || v_digits || '%')
        or r.product_code ilike '%' || v_term || '%'
        or p.descricao ilike '%' || v_term || '%'
      )
    order by r.created_at desc
    limit 300
  ) rows;

  return v_rows;
end;
$$;

create or replace function public.update_stock_transfer_request_status(
  target_request_id uuid,
  target_status text,
  target_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  request_row public.stock_transfer_requests;
  normalized_status text := upper(btrim(coalesce(target_status, '')));
begin
  actor := public.commercial_active_profile();
  if actor.id is null then raise exception 'SEM_PERMISSAO'; end if;
  if not (actor.perfil = 'ADMIN' or public.has_module('pedidos')) then
    raise exception 'SEM_PERMISSAO';
  end if;

  if normalized_status not in ('PENDING', 'APPROVED', 'IN_TRANSIT', 'RECEIVED', 'CANCELLED') then
    raise exception 'STATUS_TRANSFERENCIA_INVALIDO';
  end if;

  select * into request_row
  from public.stock_transfer_requests
  where id = target_request_id
  for update;

  if request_row.id is null then raise exception 'SOLICITACAO_TRANSFERENCIA_NAO_ENCONTRADA'; end if;

  update public.stock_transfer_requests
  set status = normalized_status,
      notes = nullif(btrim(coalesce(target_notes, notes, '')), '')
  where id = target_request_id
  returning * into request_row;

  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (
    actor.id,
    actor.usuario,
    'ATUALIZAR_STATUS_TRANSFERENCIA',
    'stock_transfer_requests',
    target_request_id::text,
    jsonb_build_object('status', normalized_status)
  );

  return to_jsonb(request_row);
end;
$$;

revoke all on function public.list_stock_transfer_requests(jsonb),
  public.update_stock_transfer_request_status(uuid, text, text)
from public, anon;

grant execute on function public.list_stock_transfer_requests(jsonb),
  public.update_stock_transfer_request_status(uuid, text, text)
to authenticated;

comment on function public.list_stock_transfer_requests(jsonb)
is 'Lista solicitacoes operacionais de transferencia sem movimentar estoque.';

comment on function public.update_stock_transfer_request_status(uuid, text, text)
is 'Atualiza somente o status operacional da solicitacao de transferencia, sem baixa ou entrada de estoque.';

commit;
