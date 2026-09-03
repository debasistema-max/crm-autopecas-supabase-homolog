begin;

create or replace function public.preserve_unprovided_stock_import_fields()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  staged_data jsonb;
begin
  if new.source_batch_id is null or new.source_batch_id is not distinct from old.source_batch_id then
    return new;
  end if;

  select s.normalized_data into staged_data
  from public.products_import_stage s
  where s.batch_id = new.source_batch_id
    and s.normalized_data->>'product_code' = new.product_code
    and s.status <> 'error'
  order by s.row_number
  limit 1;

  if staged_data is null then return new; end if;

  if not (staged_data ? 'stock_qty') then new.sap_stock_qty := old.sap_stock_qty; end if;
  if not (staged_data ? 'confirmed_qty') then new.sap_confirmed_qty := old.sap_confirmed_qty; end if;
  if not (staged_data ? 'sales_available_qty') then new.sap_sales_available_qty := old.sap_sales_available_qty; end if;
  if not (staged_data ? 'authorized_pending_qty') then
    new.sap_authorized_pending_qty := old.sap_authorized_pending_qty;
  end if;
  if not (staged_data ? 'general_available_qty') then
    new.sap_general_available_qty := old.sap_general_available_qty;
    new.available_qty_capped := old.available_qty_capped;
    new.source_display_value := old.source_display_value;
  end if;
  if not (staged_data ? 'stock_qty') and not (staged_data ? 'general_available_qty') then
    new.physical_qty := old.physical_qty;
  end if;
  return new;
end;
$$;

drop trigger if exists product_branch_stock_preserve_unprovided_import_fields on public.product_branch_stock;
create trigger product_branch_stock_preserve_unprovided_import_fields
before update on public.product_branch_stock
for each row execute function public.preserve_unprovided_stock_import_fields();

revoke all privileges on function public.preserve_unprovided_stock_import_fields() from public;
revoke all privileges on function public.preserve_unprovided_stock_import_fields() from anon;

comment on function public.preserve_unprovided_stock_import_fields()
  is 'Aplica field-mask implícita do staging: campos ausentes no arquivo não apagam estoque SAP existente.';

commit;
