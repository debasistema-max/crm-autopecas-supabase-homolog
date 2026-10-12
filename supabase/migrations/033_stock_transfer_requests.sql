begin;

create table if not exists public.stock_transfer_requests (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  order_item_id uuid references public.order_items(id) on delete set null,
  product_code text not null references public.products(codigo) on update cascade on delete restrict,
  source_branch_id uuid not null references public.branches(id) on delete restrict,
  target_branch_id uuid not null references public.branches(id) on delete restrict,
  requested_qty numeric(14,3) not null,
  source_available_qty numeric(14,3) not null default 0,
  target_available_qty numeric(14,3) not null default 0,
  status text not null default 'PENDING',
  reason text not null default 'ORDER_BRANCH_SHORTAGE',
  notes text,
  requested_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint stock_transfer_requests_qty_check check (requested_qty > 0),
  constraint stock_transfer_requests_status_check check (status in ('PENDING', 'APPROVED', 'IN_TRANSIT', 'RECEIVED', 'CANCELLED')),
  constraint stock_transfer_requests_branch_check check (source_branch_id <> target_branch_id)
);

create unique index if not exists stock_transfer_requests_pending_item_idx
  on public.stock_transfer_requests (order_id, product_code, source_branch_id, target_branch_id)
  where status in ('PENDING', 'APPROVED', 'IN_TRANSIT');

create index if not exists stock_transfer_requests_order_idx
  on public.stock_transfer_requests (order_id, created_at desc);

create index if not exists stock_transfer_requests_status_idx
  on public.stock_transfer_requests (status, created_at desc);

drop trigger if exists stock_transfer_requests_touch_updated_at
  on public.stock_transfer_requests;
create trigger stock_transfer_requests_touch_updated_at
before update on public.stock_transfer_requests
for each row execute function public.touch_updated_at();

do $backfill_branch_stock$
declare
  v_pr_branch_id uuid;
  v_sp_branch_id uuid;
begin
  select id into v_pr_branch_id from public.branches where code = 'PR' and active;
  select id into v_sp_branch_id from public.branches where code = 'SP' and active;

  if v_pr_branch_id is null or v_sp_branch_id is null then
    raise exception 'FILIAIS_INICIAIS_NAO_CRIADAS';
  end if;

  insert into public.product_branch_stock (product_code, branch_id, physical_qty)
  select p.codigo, v_pr_branch_id, greatest(coalesce(p.estoque_quantidade, 0), 0)
  from public.products p
  on conflict (product_code, branch_id) do update
  set physical_qty = greatest(coalesce(excluded.physical_qty, 0), public.product_branch_stock.physical_qty);

  insert into public.product_branch_stock (product_code, branch_id, physical_qty)
  select p.codigo, v_sp_branch_id, 0
  from public.products p
  on conflict (product_code, branch_id) do nothing;
end
$backfill_branch_stock$;

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
  shortage_qty numeric(14,3);
  transfer_qty numeric(14,3);
  created_count integer := 0;
  updated_count integer := 0;
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

  if v_sp_branch_id is null or v_pr_branch_id is null then
    raise exception 'FILIAIS_INICIAIS_NAO_CRIADAS';
  end if;

  if order_row.branch_id is distinct from v_sp_branch_id and order_row.regiao::text <> 'SP' then
    return jsonb_build_object('created', 0, 'updated', 0, 'reason', 'PEDIDO_NAO_EH_SP');
  end if;

  for item_row in
    select i.id as order_item_id, i.codigo as product_code, i.quantidade
    from public.order_items i
    where i.order_id = target_order_id
    order by i.item
  loop
    insert into public.product_branch_stock (product_code, branch_id, physical_qty)
    values (item_row.product_code, v_sp_branch_id, 0)
    on conflict (product_code, branch_id) do nothing;

    insert into public.product_branch_stock (product_code, branch_id, physical_qty)
    select p.codigo, v_pr_branch_id, greatest(coalesce(p.estoque_quantidade, 0), 0)
    from public.products p
    where p.codigo = item_row.product_code
    on conflict (product_code, branch_id) do nothing;

    select * into target_stock
    from public.product_branch_stock
    where product_code = item_row.product_code
      and branch_id = v_sp_branch_id
    for update;

    select * into source_stock
    from public.product_branch_stock
    where product_code = item_row.product_code
      and branch_id = v_pr_branch_id
    for update;

    shortage_qty := greatest(coalesce(item_row.quantidade, 0) - coalesce(target_stock.available_qty, 0), 0);
    transfer_qty := least(shortage_qty, coalesce(source_stock.available_qty, 0));

    if transfer_qty > 0 then
      if exists (
        select 1
        from public.stock_transfer_requests r
        where r.order_id = target_order_id
          and r.product_code = item_row.product_code
          and r.source_branch_id = v_pr_branch_id
          and r.target_branch_id = v_sp_branch_id
          and r.status in ('PENDING', 'APPROVED', 'IN_TRANSIT')
      ) then
        update public.stock_transfer_requests r
        set order_item_id = item_row.order_item_id,
            requested_qty = transfer_qty,
            source_available_qty = coalesce(source_stock.available_qty, 0),
            target_available_qty = coalesce(target_stock.available_qty, 0),
            requested_by = actor.id,
            updated_at = now()
        where r.order_id = target_order_id
          and r.product_code = item_row.product_code
          and r.source_branch_id = v_pr_branch_id
          and r.target_branch_id = v_sp_branch_id
          and r.status in ('PENDING', 'APPROVED', 'IN_TRANSIT');
        updated_count := updated_count + 1;
      else
        insert into public.stock_transfer_requests (
          order_id,
          order_item_id,
          product_code,
          source_branch_id,
          target_branch_id,
          requested_qty,
          source_available_qty,
          target_available_qty,
          requested_by
        )
        values (
          target_order_id,
          item_row.order_item_id,
          item_row.product_code,
          v_pr_branch_id,
          v_sp_branch_id,
          transfer_qty,
          coalesce(source_stock.available_qty, 0),
          coalesce(target_stock.available_qty, 0),
          actor.id
        );
        created_count := created_count + 1;
      end if;
    end if;
  end loop;

  if created_count + updated_count > 0 then
    update public.orders
    set logistics_status = case
          when stock_contract_version = 0 then logistics_status
          else 'AWAITING_STOCK'
        end
    where id = target_order_id;
  end if;

  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (
    actor.id,
    actor.usuario,
    'GERAR_SOLICITACAO_TRANSFERENCIA',
    'stock_transfer_requests',
    target_order_id::text,
    jsonb_build_object('created', created_count, 'updated', updated_count)
  );

  return jsonb_build_object('created', created_count, 'updated', updated_count);
end;
$$;

create or replace function public.get_order_stock_transfer_suggestions(target_order_id uuid)
returns table (
  product_code text,
  requested_qty numeric,
  target_available_qty numeric,
  source_available_qty numeric,
  can_transfer boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  order_row public.orders;
  v_sp_branch_id uuid;
  v_pr_branch_id uuid;
begin
  actor := public.commercial_active_profile();
  if actor.id is null then raise exception 'SEM_PERMISSAO'; end if;

  select * into order_row from public.orders where id = target_order_id;
  if order_row.id is null then raise exception 'PEDIDO_NAO_ENCONTRADO'; end if;
  if actor.perfil <> 'ADMIN' and order_row.user_id <> actor.id then raise exception 'SEM_PERMISSAO'; end if;

  select id into v_sp_branch_id from public.branches where code = 'SP' and active;
  select id into v_pr_branch_id from public.branches where code = 'PR' and active;

  return query
  select
    i.codigo,
    greatest(coalesce(i.quantidade, 0) - coalesce(sp.available_qty, 0), 0)::numeric(14,3),
    coalesce(sp.available_qty, 0)::numeric(14,3),
    coalesce(pr.available_qty, 0)::numeric(14,3),
    coalesce(pr.available_qty, 0) >= greatest(coalesce(i.quantidade, 0) - coalesce(sp.available_qty, 0), 0)
  from public.order_items i
  left join public.product_branch_stock sp
    on sp.product_code = i.codigo
   and sp.branch_id = v_sp_branch_id
  left join public.product_branch_stock pr
    on pr.product_code = i.codigo
   and pr.branch_id = v_pr_branch_id
  where i.order_id = target_order_id
    and (order_row.regiao::text = 'SP' or order_row.branch_id = v_sp_branch_id)
    and greatest(coalesce(i.quantidade, 0) - coalesce(sp.available_qty, 0), 0) > 0
    and coalesce(pr.available_qty, 0) > 0;
end;
$$;

alter table public.stock_transfer_requests enable row level security;

drop policy if exists stock_transfer_requests_read on public.stock_transfer_requests;
create policy stock_transfer_requests_read
on public.stock_transfer_requests
for select to authenticated
using (
  public.is_admin()
  or exists (
    select 1
    from public.orders o
    where o.id = order_id
      and o.user_id = auth.uid()
  )
  or public.can_access_branch(source_branch_id)
  or public.can_access_branch(target_branch_id)
);

drop policy if exists stock_transfer_requests_admin_write on public.stock_transfer_requests;
create policy stock_transfer_requests_admin_write
on public.stock_transfer_requests
for all to authenticated
using (public.is_admin())
with check (public.is_admin());

revoke all on public.stock_transfer_requests from public, anon, authenticated;
grant select on public.stock_transfer_requests to authenticated;

revoke all on function public.create_order_transfer_requests(uuid),
  public.get_order_stock_transfer_suggestions(uuid)
from public, anon;
grant execute on function public.create_order_transfer_requests(uuid),
  public.get_order_stock_transfer_suggestions(uuid)
to authenticated;

comment on table public.stock_transfer_requests
is 'Fila de solicitacoes de transferencia entre filiais gerada por falta de estoque no pedido.';

comment on function public.create_order_transfer_requests(uuid)
is 'Gera solicitacoes PR -> SP para pedidos SP quando falta estoque local e ha saldo disponivel na matriz PR.';

commit;
