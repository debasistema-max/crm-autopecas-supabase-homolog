begin;

set local lock_timeout = '10s';
set local statement_timeout = '110s';

-- Keep the commercial Excel snapshot separate from the quantity that can
-- actually be reserved for an internal transfer. The transfer quantity uses
-- the generated available_qty column (physical minus active reservations),
-- exactly like create_order_transfer_requests.
create or replace function public.get_branch_product_availability_v2(product_codes text[])
returns table(
  product_code text,
  sp_available_qty numeric,
  pr_available_qty numeric,
  sp_transfer_available_qty numeric,
  pr_transfer_available_qty numeric,
  sp_source_display_value text,
  pr_source_display_value text,
  sp_price numeric,
  pr_price numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with requested as (
    select distinct btrim(value) as codigo
    from unnest(coalesce(product_codes,'{}'::text[])) value
    where nullif(btrim(value),'') is not null
    limit 500
  ), branch_values as (
    select
      r.codigo,
      b.code,
      case
        when s.product_code is null
          or (s.source_batch_id is null and coalesce(s.version,0) = 0) then null
        else coalesce(s.sap_general_available_qty,s.available_qty,s.physical_qty)
      end as commercial_available_qty,
      case
        when s.product_code is null
          or (s.source_batch_id is null and coalesce(s.version,0) = 0) then null
        else s.available_qty
      end as transfer_available_qty,
      case
        when s.product_code is null
          or (s.source_batch_id is null and coalesce(s.version,0) = 0) then null
        else s.source_display_value
      end as source_display_value,
      case
        when bp.product_code is null
          or (bp.source_batch_id is null and bp.source = 'LEGACY_SYNC' and bp.sale_price = 0) then null
        else bp.sale_price
      end as sale_price
    from requested r
    join public.products p on p.codigo = r.codigo
    cross join public.branches b
    left join public.product_branch_stock s
      on s.product_code = r.codigo and s.branch_id = b.id
    left join public.product_branch_prices bp
      on bp.product_code = r.codigo and bp.branch_id = b.id
      and bp.valid_from <= current_date
      and (bp.valid_until is null or bp.valid_until >= current_date)
    where b.active and b.code in ('PR','SP')
  )
  select
    codigo as product_code,
    max(commercial_available_qty) filter (where code = 'SP') as sp_available_qty,
    max(commercial_available_qty) filter (where code = 'PR') as pr_available_qty,
    max(transfer_available_qty) filter (where code = 'SP') as sp_transfer_available_qty,
    max(transfer_available_qty) filter (where code = 'PR') as pr_transfer_available_qty,
    max(source_display_value) filter (where code = 'SP') as sp_source_display_value,
    max(source_display_value) filter (where code = 'PR') as pr_source_display_value,
    max(sale_price) filter (where code = 'SP') as sp_price,
    max(sale_price) filter (where code = 'PR') as pr_price
  from branch_values
  where auth.uid() is null
    or public.is_admin()
    or public.has_module('produtos')
    or public.has_module('novo_pedido')
    or public.has_module('nova_cotacao')
  group by codigo
$$;

revoke all on function public.get_branch_product_availability_v2(text[]) from public,anon;
grant execute on function public.get_branch_product_availability_v2(text[]) to authenticated,service_role;

comment on function public.get_branch_product_availability_v2(text[]) is
  'Retorna snapshot comercial e saldo transferível líquido de reservas por filial para até 500 produtos.';

commit;
