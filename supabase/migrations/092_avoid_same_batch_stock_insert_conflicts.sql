begin;

create or replace function public.sync_legacy_product_stock_to_pr()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pr_branch_id uuid;
  v_sp_branch_id uuid;
  v_old_qty numeric(14,3) := case when tg_op = 'INSERT' then 0 else old.estoque_quantidade end;
  v_new_qty numeric(14,3) := coalesce(new.estoque_quantidade, 0);
  v_before jsonb;
  v_after jsonb;
begin
  if current_setting('app.stock_sync_source', true) = 'BRANCH_IMPORT_V2' then
    return new;
  end if;

  if v_new_qty < 0 then
    raise exception 'ESTOQUE_LEGADO_NEGATIVO';
  end if;

  select pr_branch_id, sp_branch_id
  into v_pr_branch_id, v_sp_branch_id
  from public.resolve_branch_import_initial_branches();

  -- A PRODUCT row is committed before its STOCK row. For products created by
  -- the data-sync pipeline, do not pre-create a zero balance for a branch that
  -- already has a valid STOCK row in the same batch; otherwise the optimistic
  -- concurrency check sees an unexpected INSERT and rejects the real stock.
  -- Branches absent from the batch keep the legacy zero-balance foundation.
  if tg_op='INSERT' and new.sync_batch_id is not null and exists (
    select 1
    from public.products_import_stage s
    where s.batch_id=new.sync_batch_id
      and s.codigo=new.codigo
      and s.sync_area='STOCK'
      and s.status<>'error'
  ) then
    insert into public.product_branch_stock(product_code,branch_id,physical_qty,updated_by)
    select new.codigo,b.id,0,auth.uid()
    from public.branches b
    where b.id in (v_pr_branch_id,v_sp_branch_id)
      and not exists (
        select 1
        from public.products_import_stage s
        where s.batch_id=new.sync_batch_id
          and s.codigo=new.codigo
          and s.sync_area='STOCK'
          and s.branch_code=b.code
          and s.status<>'error'
      )
    on conflict(product_code,branch_id) do nothing;
    return new;
  end if;

  insert into public.product_branch_stock(product_code,branch_id,physical_qty,updated_by)
  values(new.codigo,v_sp_branch_id,0,auth.uid())
  on conflict(product_code,branch_id) do nothing;

  select jsonb_build_object(
    'physical_qty',s.physical_qty,
    'reserved_order_qty',s.reserved_order_qty,
    'reserved_transfer_qty',s.reserved_transfer_qty,
    'in_transit_qty',s.in_transit_qty,
    'quarantined_qty',s.quarantined_qty
  )
  into v_before
  from public.product_branch_stock s
  where s.product_code=new.codigo and s.branch_id=v_pr_branch_id
  for update;

  if v_before is null then
    v_before:=jsonb_build_object(
      'physical_qty',0,
      'reserved_order_qty',0,
      'reserved_transfer_qty',0,
      'in_transit_qty',0,
      'quarantined_qty',0
    );
    insert into public.product_branch_stock(product_code,branch_id,physical_qty,updated_by)
    values(new.codigo,v_pr_branch_id,v_new_qty,auth.uid());
  elsif v_old_qty is distinct from v_new_qty then
    update public.product_branch_stock s
    set physical_qty=v_new_qty,updated_by=auth.uid()
    where s.product_code=new.codigo and s.branch_id=v_pr_branch_id;
  end if;

  if v_old_qty is not distinct from v_new_qty then
    return new;
  end if;

  select jsonb_build_object(
    'physical_qty',s.physical_qty,
    'reserved_order_qty',s.reserved_order_qty,
    'reserved_transfer_qty',s.reserved_transfer_qty,
    'in_transit_qty',s.in_transit_qty,
    'quarantined_qty',s.quarantined_qty
  )
  into v_after
  from public.product_branch_stock s
  where s.product_code=new.codigo and s.branch_id=v_pr_branch_id;

  insert into public.stock_movements(
    branch_id,product_code,movement_type,physical_delta,balance_before,balance_after,
    source,reference_type,idempotency_key,created_by,metadata
  ) values (
    v_pr_branch_id,new.codigo,'IMPORTACAO_ESTOQUE',v_new_qty-v_old_qty,
    v_before,v_after,'LEGACY_PRODUCTS_SYNC','products',
    'legacy-products-sync:'||gen_random_uuid()::text,auth.uid(),
    jsonb_build_object('legacy_column','products.estoque_quantidade','operation',tg_op)
  );

  return new;
end;
$$;

commit;
