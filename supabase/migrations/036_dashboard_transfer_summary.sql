begin;

create or replace function public.get_dashboard_transfer_summary()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  v_summary jsonb;
begin
  actor := public.commercial_active_profile();
  if actor.id is null then raise exception 'SEM_PERMISSAO'; end if;
  if not (actor.perfil = 'ADMIN' or public.has_module('pedidos')) then
    raise exception 'SEM_PERMISSAO';
  end if;

  with visible_requests as (
    select
      r.status,
      r.requested_qty,
      r.created_at
    from public.stock_transfer_requests r
    join public.orders o on o.id = r.order_id
    where actor.perfil = 'ADMIN'
      or public.has_module('pedidos')
      or o.user_id = actor.id
  )
  select jsonb_build_object(
    'pending', count(*) filter (where status = 'PENDING'),
    'approved', count(*) filter (where status = 'APPROVED'),
    'in_transit', count(*) filter (where status = 'IN_TRANSIT'),
    'received', count(*) filter (where status = 'RECEIVED'),
    'cancelled', count(*) filter (where status = 'CANCELLED'),
    'active', count(*) filter (where status in ('PENDING', 'APPROVED', 'IN_TRANSIT')),
    'active_qty', coalesce(sum(requested_qty) filter (where status in ('PENDING', 'APPROVED', 'IN_TRANSIT')), 0),
    'oldest_active_at', min(created_at) filter (where status in ('PENDING', 'APPROVED', 'IN_TRANSIT')),
    'latest_active_at', max(created_at) filter (where status in ('PENDING', 'APPROVED', 'IN_TRANSIT'))
  )
  into v_summary
  from visible_requests;

  return coalesce(v_summary, jsonb_build_object(
    'pending', 0,
    'approved', 0,
    'in_transit', 0,
    'received', 0,
    'cancelled', 0,
    'active', 0,
    'active_qty', 0,
    'oldest_active_at', null,
    'latest_active_at', null
  ));
end;
$$;

revoke all on function public.get_dashboard_transfer_summary()
from public, anon;

grant execute on function public.get_dashboard_transfer_summary()
to authenticated;

comment on function public.get_dashboard_transfer_summary()
is 'Resumo operacional de solicitacoes de transferencia para o Inicio, sem movimentar estoque.';

commit;
