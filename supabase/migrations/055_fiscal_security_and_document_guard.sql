begin;

-- Supabase exposes functions through PostgREST when the database role has
-- EXECUTE. Granting authenticated does not remove PostgreSQL's default PUBLIC
-- privilege, so every sensitive RPC is explicitly closed to PUBLIC and anon.
do $$
declare
  function_signature text;
begin
  for function_signature in
    select p.oid::regprocedure::text
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and p.proname = any(array[
        'calculate_taxed_unit_price',
        'calculate_product_price',
        'get_product_commercial_price',
        'get_products_commercial_prices',
        'get_product_route_prices',
        'get_fiscal_pending',
        'generate_commercial_list',
        'list_fiscal_tax_rules',
        'save_fiscal_tax_rule',
        'delete_fiscal_tax_rule',
        'can_stage_sap_import',
        'can_commit_sap_import',
        'create_sap_import_batch',
        'stage_sap_import_rows',
        'validate_sap_import_batch',
        'preview_sap_import_batch',
        'approve_sap_import_batch',
        'commit_sap_import_batch',
        'list_sap_import_batches',
        'commercial_create_document',
        'commercial_update_document_items',
        'convert_quotation_to_order'
      ])
  loop
    execute format('revoke all privileges on function %s from public', function_signature);
    if exists(select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all privileges on function %s from anon', function_signature);
    end if;
    if exists(select 1 from pg_roles where rolname = 'authenticated') then
      execute format('grant execute on function %s to authenticated', function_signature);
    end if;
  end loop;
end;
$$;

-- Avoid reintroducing public EXECUTE when the migration owner creates a new RPC.
alter default privileges in schema public revoke execute on functions from public;

create or replace function public.guard_commercial_item_fiscal_snapshot()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- Legacy rows without a fiscal snapshot remain readable/editable. New central
  -- document flows always provide fiscal_details and must never persist a
  -- fallback price when the authoritative engine rejected the calculation.
  if new.fiscal_details is not null
     and coalesce(new.fiscal_status, '') not in ('OK', 'OK_SEM_ST') then
    raise exception using
      errcode = '23514',
      message = format(
        'CALCULO_FISCAL_INVALIDO: produto %s, status %s.',
        coalesce(new.codigo, 'NAO_INFORMADO'),
        coalesce(new.fiscal_status, 'NAO_INFORMADO')
      ),
      hint = 'Corrija NCM, preco base e regra fiscal antes de salvar o documento.';
  end if;
  return new;
end;
$$;

drop trigger if exists order_items_guard_fiscal_snapshot on public.order_items;
create trigger order_items_guard_fiscal_snapshot
before insert or update of fiscal_details, fiscal_status, preco_unitario
on public.order_items
for each row execute function public.guard_commercial_item_fiscal_snapshot();

drop trigger if exists quotation_items_guard_fiscal_snapshot on public.quotation_items;
create trigger quotation_items_guard_fiscal_snapshot
before insert or update of fiscal_details, fiscal_status, preco_unitario
on public.quotation_items
for each row execute function public.guard_commercial_item_fiscal_snapshot();

revoke all privileges on function public.guard_commercial_item_fiscal_snapshot() from public;
revoke all privileges on function public.guard_commercial_item_fiscal_snapshot() from anon;

comment on function public.guard_commercial_item_fiscal_snapshot()
  is 'Bloqueia preço legado silencioso quando a engine fiscal central devolve status inválido.';

commit;
