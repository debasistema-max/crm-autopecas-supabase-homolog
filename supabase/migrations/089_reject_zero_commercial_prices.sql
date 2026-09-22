begin;

-- Zero is not a commercial price. Rows without a usable source price remain
-- absent from the commercial catalogue until the workbook supplies one.
delete from public.product_route_prices
where coalesce(base_price,0) <= 0 or final_price <= 0;

delete from public.product_branch_prices
where sale_price <= 0;

alter table public.product_route_prices
  drop constraint if exists product_route_prices_values_check;
alter table public.product_route_prices
  add constraint product_route_prices_values_check check (
    base_price > 0 and final_price > 0 and final_price >= base_price
    and (total_taxes is null or total_taxes >= 0)
  );

alter table public.product_branch_prices
  drop constraint if exists product_branch_prices_sale_price_positive_check;
alter table public.product_branch_prices
  add constraint product_branch_prices_sale_price_positive_check check (sale_price > 0);

-- The legacy products table defaults PR/SP prices to zero. Zero now means
-- "price absent", so the compatibility trigger removes the branch row instead
-- of trying to persist an invalid commercial price.
create or replace function public.sync_legacy_product_prices_to_branches()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pr uuid;
  v_sp uuid;
begin
  if current_setting('app.price_sync_source', true) = 'BRANCH_IMPORT_V2' then
    return new;
  end if;

  select pr_branch_id, sp_branch_id into v_pr, v_sp
  from public.resolve_branch_import_initial_branches();

  if tg_op = 'INSERT' or old.preco_pr is distinct from new.preco_pr then
    if coalesce(new.preco_pr,0) <= 0 then
      delete from public.product_branch_prices
      where product_code = new.codigo and branch_id = v_pr;
    else
      insert into public.product_branch_prices(
        product_code,branch_id,sale_price,currency,source,source_batch_id,updated_by
      ) values(
        new.codigo,v_pr,new.preco_pr,'BRL','LEGACY_SYNC',null,auth.uid()
      )
      on conflict(product_code,branch_id) do update
      set sale_price=excluded.sale_price,currency=excluded.currency,source=excluded.source,
          source_batch_id=null,updated_by=excluded.updated_by
      where product_branch_prices.sale_price is distinct from excluded.sale_price
         or product_branch_prices.currency is distinct from excluded.currency;
    end if;
  end if;

  if tg_op = 'INSERT' or old.preco_sp is distinct from new.preco_sp then
    if coalesce(new.preco_sp,0) <= 0 then
      delete from public.product_branch_prices
      where product_code = new.codigo and branch_id = v_sp;
    else
      insert into public.product_branch_prices(
        product_code,branch_id,sale_price,currency,source,source_batch_id,updated_by
      ) values(
        new.codigo,v_sp,new.preco_sp,'BRL','LEGACY_SYNC',null,auth.uid()
      )
      on conflict(product_code,branch_id) do update
      set sale_price=excluded.sale_price,currency=excluded.currency,source=excluded.source,
          source_batch_id=null,updated_by=excluded.updated_by
      where product_branch_prices.sale_price is distinct from excluded.sale_price
         or product_branch_prices.currency is distinct from excluded.currency;
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.normalize_data_sync_fields(
  target_area text,
  input_data jsonb,
  requested_fields text[],
  requested_clears text[] default '{}'::text[]
)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_area text := upper(coalesce(target_area,''));
  v_field text;
  v_text text;
  v_number numeric;
  v_allowed text[] := public.data_sync_allowed_fields(target_area);
  v_clearable constant text[] := array[
    'brand','application','year','ncm','cest','origin_code','origin_description',
    'material_group','fiscal_group','group','model','oem_01','manufacturer','item_group',
    'sales_unit','barcode','item_notes','source_display_value'
  ];
  v_data jsonb := '{}'::jsonb;
  v_errors jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_effective text[] := '{}'::text[];
begin
  if jsonb_typeof(coalesce(input_data,'{}'::jsonb)) <> 'object' then
    return jsonb_build_object('data','{}'::jsonb,'effective_fields','[]'::jsonb,
      'errors',jsonb_build_array('FIELDS_INVALIDO'),'warnings','[]'::jsonb);
  end if;
  for v_field in select distinct lower(btrim(value)) from unnest(coalesce(requested_fields,'{}'::text[])) value order by 1 loop
    if not (v_field = any(v_allowed)) then
      v_errors := v_errors || jsonb_build_array('CAMPO_NAO_PERMITIDO:'||v_field);
      continue;
    end if;
    if not input_data ? v_field then
      v_warnings := v_warnings || jsonb_build_array('CAMPO_AUSENTE_IGNORADO:'||v_field);
      continue;
    end if;
    if jsonb_typeof(input_data->v_field) = 'string' and btrim(input_data->>v_field) like '=%' then
      v_errors := v_errors || jsonb_build_array('FORMULA_NAO_PERMITIDA:'||v_field);
      continue;
    end if;
    v_text := nullif(btrim(input_data->>v_field),'');
    if jsonb_typeof(input_data->v_field) = 'null' or v_text is null then
      if v_field = any(coalesce(requested_clears,'{}'::text[])) and v_field = any(v_clearable) then
        v_data := v_data || jsonb_build_object(v_field,null);
        v_effective := array_append(v_effective,v_field);
      elsif v_field = any(coalesce(requested_clears,'{}'::text[])) then
        v_errors := v_errors || jsonb_build_array('LIMPEZA_NAO_PERMITIDA:'||v_field);
      else
        v_warnings := v_warnings || jsonb_build_array('VAZIO_IGNORADO:'||v_field);
      end if;
      continue;
    end if;

    if v_field in ('stock_qty','confirmed_qty','sales_available_qty','authorized_pending_qty',
                   'general_available_qty','base_price','final_price','total_taxes','ipi_rate','weight','volume') then
      v_number := public.parse_sap_decimal(v_text);
      if v_number is null then
        v_errors := v_errors || jsonb_build_array('NUMERO_INVALIDO:'||v_field);
        continue;
      end if;
      if v_number < 0 then
        v_errors := v_errors || jsonb_build_array('NUMERO_NEGATIVO:'||v_field);
        continue;
      end if;
      if v_field in ('base_price','final_price') and v_number = 0 then
        v_errors := v_errors || jsonb_build_array('PRECO_NAO_POSITIVO:'||v_field);
        continue;
      end if;
      if v_field = 'ipi_rate' and v_number > 10 then
        v_errors := v_errors || jsonb_build_array('PERCENTUAL_FORA_FAIXA:'||v_field);
        continue;
      end if;
      v_data := v_data || jsonb_build_object(v_field,v_number);
    elsif v_field = 'ncm' then
      v_text := public.normalize_ncm(v_text);
      if v_text is null then v_errors := v_errors || jsonb_build_array('NCM_INVALIDO'); continue; end if;
      v_data := v_data || jsonb_build_object(v_field,v_text);
    elsif v_field = 'cest' then
      v_text := public.normalize_cest(v_text);
      if v_text is null then v_errors := v_errors || jsonb_build_array('CEST_INVALIDO'); continue; end if;
      v_data := v_data || jsonb_build_object(v_field,v_text);
    elsif v_field = 'currency' then
      v_text := upper(v_text);
      if v_text !~ '^[A-Z]{3}$' then v_errors := v_errors || jsonb_build_array('MOEDA_INVALIDA'); continue; end if;
      v_data := v_data || jsonb_build_object(v_field,v_text);
    elsif v_field = 'general_available_capped' then
      if lower(v_text) not in ('true','false','1','0','sim','nao','não') then
        v_errors := v_errors || jsonb_build_array('BOOLEANO_INVALIDO:'||v_field); continue;
      end if;
      v_data := v_data || jsonb_build_object(v_field,lower(v_text) in ('true','1','sim'));
    elsif v_field = 'tax_breakdown' then
      if jsonb_typeof(input_data->v_field) <> 'object' then
        v_errors := v_errors || jsonb_build_array('MEMORIA_FISCAL_INVALIDA'); continue;
      end if;
      v_data := v_data || jsonb_build_object(v_field,input_data->v_field);
    elsif v_field = 'calculation_status' then
      v_data := v_data || jsonb_build_object(v_field,upper(v_text));
    else
      v_data := v_data || jsonb_build_object(v_field,v_text);
    end if;
    v_effective := array_append(v_effective,v_field);
  end loop;
  for v_field in select unnest(coalesce(requested_clears,'{}'::text[])) loop
    if not (v_field = any(coalesce(requested_fields,'{}'::text[]))) then
      v_errors := v_errors || jsonb_build_array('LIMPEZA_FORA_DA_MASCARA:'||v_field);
    end if;
  end loop;
  return jsonb_build_object(
    'data',v_data,
    'effective_fields',to_jsonb(v_effective),
    'errors',v_errors,
    'warnings',v_warnings
  );
end;
$$;

comment on constraint product_route_prices_values_check on public.product_route_prices
  is 'Commercial route prices require positive base and final values; zero tax remains valid.';
comment on constraint product_branch_prices_sale_price_positive_check on public.product_branch_prices
  is 'A missing commercial price is represented by absence of a row, never by zero.';

commit;
