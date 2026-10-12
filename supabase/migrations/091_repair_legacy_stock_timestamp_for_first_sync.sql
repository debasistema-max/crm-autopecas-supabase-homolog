begin;

-- Migration 033 reconciles the legacy PR stock with product_branch_stock using
-- an UPSERT. PostgreSQL executes its UPDATE branch even when physical_qty does
-- not change, so the touch trigger advances updated_at/version for every PR
-- row. On an existing installation upgraded shortly before its first Excel
-- sync, that technical timestamp can be newer than the workbook and makes the
-- idempotent pipeline reject valid stock as STALE_SOURCE_EVENT.
--
-- Repair only the exact no-op footprint: unattributed PR rows at version 1
-- whose current physical balance still matches their last audited movement
-- (or zero when no movement exists). Any sourced row, later version or balance
-- that diverges from the audit trail is intentionally left untouched.
alter table public.product_branch_stock
  disable trigger product_branch_stock_touch_updated_at;

with latest_movement as (
  select distinct on (m.branch_id,m.product_code)
    m.branch_id,
    m.product_code,
    m.created_at as audited_at,
    coalesce((m.balance_after->>'physical_qty')::numeric,0) as audited_physical_qty
  from public.stock_movements m
  order by m.branch_id,m.product_code,m.created_at desc,m.id desc
), repairable as (
  select
    s.product_code,
    s.branch_id,
    coalesce(m.audited_at,s.created_at) as audited_at
  from public.product_branch_stock s
  join public.branches b on b.id=s.branch_id and b.code='PR'
  left join latest_movement m
    on m.branch_id=s.branch_id and m.product_code=s.product_code
  where s.source_batch_id is null
    and s.source_updated_at is null
    and s.source_system is null
    and s.version=1
    and s.updated_at>coalesce(m.audited_at,s.created_at)
    and s.physical_qty=coalesce(m.audited_physical_qty,0)
)
update public.product_branch_stock s
set updated_at=r.audited_at,
    version=0
from repairable r
where s.product_code=r.product_code
  and s.branch_id=r.branch_id;

alter table public.product_branch_stock
  enable trigger product_branch_stock_touch_updated_at;

commit;
