begin;

set local lock_timeout = '10s';
set local statement_timeout = '110s';

create index if not exists products_import_stage_sync_product_dependency_idx
  on public.products_import_stage (batch_id, codigo, status)
  where sync_area = 'PRODUCT';

create index if not exists products_import_stage_sync_commit_priority_idx
  on public.products_import_stage (
    batch_id,
    (case when sync_area = 'PRODUCT' then 0 else 1 end),
    row_number,
    id
  )
  where status in ('valid','warning')
    and planned_action in ('INSERT','UPDATE')
    and cardinality(changed_fields) > 0;

create or replace function public.commit_data_sync_batch_chunk(
  target_batch_id uuid,
  chunk_size integer default 500
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '110s'
as $$
declare
  v_batch public.products_import_batches;
  v_stage public.products_import_stage;
  v_actor public.profiles;
  v_branch public.branches;
  v_before jsonb;
  v_after jsonb;
  v_data jsonb;
  v_field text;
  v_delta numeric;
  v_movement_id uuid;
  v_processed integer := 0;
  v_remaining integer := 0;
  v_inserted integer := 0;
  v_updated integer := 0;
  v_unchanged integer := 0;
  v_ignored integer := 0;
  v_invalid integer := 0;
  v_stale integer := 0;
  v_products integer := 0;
  v_products_inserted integer := 0;
  v_stocks integer := 0;
  v_prices integer := 0;
  v_fiscal integer := 0;
  v_result jsonb;
begin
  if not public.can_manage_data_sync() then
    raise exception 'SEM_PERMISSAO_SINCRONIZAR';
  end if;
  if chunk_size is null or chunk_size < 1 or chunk_size > 500 then
    raise exception 'TAMANHO_BLOCO_SINCRONIZACAO_INVALIDO';
  end if;

  select * into v_actor
  from public.profiles
  where id = auth.uid() and ativo;

  select * into v_batch
  from public.products_import_batches b
  where b.id = target_batch_id and b.contract_version = 3
  for update;

  if v_batch.id is null then
    raise exception 'LOTE_SINCRONIZACAO_NAO_ENCONTRADO';
  end if;
  if v_batch.state = 'COMMITTED' then
    return jsonb_build_object(
      'done',true,
      'processed',0,
      'remaining',0,
      'batch',public.get_data_sync_batch(target_batch_id)
    );
  end if;
  if v_batch.state not in ('PREVIEWED','COMMITTING') then
    raise exception 'LOTE_SINCRONIZACAO_NAO_VALIDADO';
  end if;

  if v_batch.state = 'PREVIEWED' then
    update public.products_import_batches
    set state = 'COMMITTING',
        status = 'processing',
        attempt_count = attempt_count + 1,
        last_attempt_started_at = now()
    where id = target_batch_id;
  end if;

  -- Validation only checked for the presence of a PRODUCT stage row. Before
  -- touching FK-backed canonical tables, require either the canonical product
  -- or a validated PRODUCT row that this commit can use to create it.
  update public.products_import_stage s
  set status = 'error',
      skip_reason = 'MISSING_PRODUCT_REFERENCE',
      blocking_errors = coalesce(s.blocking_errors,'[]'::jsonb)
        || jsonb_build_array('PRODUTO_REFERENCIADO_NAO_EXISTE'),
      errors = coalesce(s.errors,'[]'::jsonb)
        || jsonb_build_array('PRODUTO_REFERENCIADO_NAO_EXISTE')
  where s.batch_id = target_batch_id
    and s.sync_area <> 'PRODUCT'
    and s.status in ('valid','warning')
    and not exists (
      select 1
      from public.products p
      where p.codigo = s.codigo
    )
    and not exists (
      select 1
      from public.products_import_stage product_stage
      where product_stage.batch_id = target_batch_id
        and product_stage.sync_area = 'PRODUCT'
        and product_stage.codigo = s.codigo
        and (
          product_stage.status = 'committed'
          or (
            product_stage.status in ('valid','warning')
            and product_stage.planned_action = 'INSERT'
            and cardinality(product_stage.changed_fields) > 0
          )
        )
    );

  for v_stage in
    select *
    from public.products_import_stage s
    where s.batch_id = target_batch_id
      and s.status in ('valid','warning')
      and s.planned_action in ('INSERT','UPDATE')
      and cardinality(s.changed_fields) > 0
    order by case when s.sync_area = 'PRODUCT' then 0 else 1 end,
      s.row_number, s.id
    limit chunk_size
    for update
  loop
    v_processed := v_processed + 1;
    v_data := v_stage.normalized_data;
    v_movement_id := null;
    v_before := public.get_data_sync_current_values(
      v_stage.sync_area,
      v_stage.codigo,
      v_stage.branch_code,
      v_stage.route
    );

    -- Preserve the preview's optimistic concurrency and event-time guards.
    if coalesce((v_before->>'_exists')::boolean,false) then
      if (v_before->>'_updated_at')::timestamptz > v_stage.source_updated_at
         or (v_stage.sync_area = 'PRODUCT'
           and (v_before->>'_updated_at')::timestamptz is distinct from v_stage.product_version)
         or (v_stage.sync_area = 'STOCK'
           and (v_before->>'_version')::bigint is distinct from v_stage.stock_version)
         or (v_stage.sync_area in ('BASE_PRICE','ROUTE_PRICE')
           and (v_before->>'_version')::bigint is distinct from v_stage.price_version) then
        update public.products_import_stage
        set status = 'error',
            skip_reason = 'CONCURRENT_MODIFICATION',
            blocking_errors = blocking_errors || jsonb_build_array('ALTERACAO_CONCORRENTE'),
            errors = errors || jsonb_build_array('ALTERACAO_CONCORRENTE')
        where id = v_stage.id;
        continue;
      end if;
    elsif v_stage.planned_action = 'UPDATE' then
      update public.products_import_stage
      set status = 'error',
          skip_reason = 'CONCURRENT_MODIFICATION',
          blocking_errors = blocking_errors || jsonb_build_array('REGISTRO_REMOVIDO_APOS_PREVIEW'),
          errors = errors || jsonb_build_array('REGISTRO_REMOVIDO_APOS_PREVIEW')
      where id = v_stage.id;
      continue;
    end if;

    if v_stage.sync_area = 'PRODUCT' then
      insert into public.products(
        codigo,descricao,marca,aplicacao,ano,ncm,cest,ipi_rate,ipi_defined,origin_code,
        origin_description,material_group,fiscal_group,grupo,montadora,oem,detalhes,
        sync_source,sync_source_version,sync_source_updated_at,sync_batch_id
      ) values (
        v_stage.codigo,v_data->>'description',v_data->>'brand',v_data->>'application',v_data->>'year',
        v_data->>'ncm',v_data->>'cest',nullif(v_data->>'ipi_rate','')::numeric,v_data?'ipi_rate',v_data->>'origin_code',
        v_data->>'origin_description',v_data->>'material_group',v_data->>'fiscal_group',v_data->>'group',
        v_data->>'manufacturer',v_data->>'oem_01',v_data->>'item_notes',v_batch.integration_source,
        v_stage.source_version,v_stage.source_updated_at,target_batch_id
      ) on conflict(codigo) do update set
        descricao = case when v_data?'description' then v_data->>'description' else products.descricao end,
        marca = case when v_data?'brand' then v_data->>'brand' else products.marca end,
        aplicacao = case when v_data?'application' then v_data->>'application' else products.aplicacao end,
        ano = case when v_data?'year' then v_data->>'year' else products.ano end,
        ncm = case when v_data?'ncm' then v_data->>'ncm' else products.ncm end,
        cest = case when v_data?'cest' then v_data->>'cest' else products.cest end,
        ipi_rate = case when v_data?'ipi_rate' then (v_data->>'ipi_rate')::numeric else products.ipi_rate end,
        ipi_defined = case when v_data?'ipi_rate' then true else products.ipi_defined end,
        origin_code = case when v_data?'origin_code' then v_data->>'origin_code' else products.origin_code end,
        origin_description = case when v_data?'origin_description' then v_data->>'origin_description' else products.origin_description end,
        material_group = case when v_data?'material_group' then v_data->>'material_group' else products.material_group end,
        fiscal_group = case when v_data?'fiscal_group' then v_data->>'fiscal_group' else products.fiscal_group end,
        grupo = case when v_data?'group' then v_data->>'group' else products.grupo end,
        montadora = case when v_data?'manufacturer' then v_data->>'manufacturer' else products.montadora end,
        oem = case when v_data?'oem_01' then v_data->>'oem_01' else products.oem end,
        detalhes = case when v_data?'item_notes' then v_data->>'item_notes' else products.detalhes end,
        sync_source = v_batch.integration_source,
        sync_source_version = v_stage.source_version,
        sync_source_updated_at = v_stage.source_updated_at,
        sync_batch_id = target_batch_id,
        updated_at = now();

      if v_data ?| array['model','oem_01','manufacturer','item_group','sales_unit','barcode','weight','volume','item_notes'] then
        insert into public.product_sap_data(
          product_code,model,oem_01,manufacturer,item_group,sales_unit,barcode,weight,volume,item_notes,
          raw_data,source,source_version,source_updated_at,import_batch_id
        ) values (
          v_stage.codigo,v_data->>'model',v_data->>'oem_01',v_data->>'manufacturer',v_data->>'item_group',
          v_data->>'sales_unit',v_data->>'barcode',nullif(v_data->>'weight','')::numeric,
          nullif(v_data->>'volume','')::numeric,v_data->>'item_notes',v_stage.raw_data,v_batch.integration_source,
          v_stage.source_version,v_stage.source_updated_at,target_batch_id
        ) on conflict(product_code) do update set
          model = case when v_data?'model' then v_data->>'model' else product_sap_data.model end,
          oem_01 = case when v_data?'oem_01' then v_data->>'oem_01' else product_sap_data.oem_01 end,
          manufacturer = case when v_data?'manufacturer' then v_data->>'manufacturer' else product_sap_data.manufacturer end,
          item_group = case when v_data?'item_group' then v_data->>'item_group' else product_sap_data.item_group end,
          sales_unit = case when v_data?'sales_unit' then v_data->>'sales_unit' else product_sap_data.sales_unit end,
          barcode = case when v_data?'barcode' then v_data->>'barcode' else product_sap_data.barcode end,
          weight = case when v_data?'weight' then (v_data->>'weight')::numeric else product_sap_data.weight end,
          volume = case when v_data?'volume' then (v_data->>'volume')::numeric else product_sap_data.volume end,
          item_notes = case when v_data?'item_notes' then v_data->>'item_notes' else product_sap_data.item_notes end,
          raw_data = product_sap_data.raw_data || excluded.raw_data,
          source = excluded.source,
          source_version = excluded.source_version,
          source_updated_at = excluded.source_updated_at,
          import_batch_id = excluded.import_batch_id,
          updated_at = now();
      end if;
    elsif v_stage.sync_area = 'STOCK' then
      select * into v_branch from public.branches
      where code = v_stage.branch_code and active;
      select to_jsonb(s) into v_before
      from public.product_branch_stock s
      where s.product_code = v_stage.codigo and s.branch_id = v_branch.id;

      insert into public.product_branch_stock(
        product_code,branch_id,physical_qty,sap_stock_qty,sap_confirmed_qty,sap_sales_available_qty,
        sap_authorized_pending_qty,sap_general_available_qty,available_qty_capped,source_display_value,
        source_batch_id,source_updated_at,source_system,source_version,updated_by
      ) values (
        v_stage.codigo,v_branch.id,(v_data->>'stock_qty')::numeric,(v_data->>'stock_qty')::numeric,
        nullif(v_data->>'confirmed_qty','')::numeric,nullif(v_data->>'sales_available_qty','')::numeric,
        nullif(v_data->>'authorized_pending_qty','')::numeric,nullif(v_data->>'general_available_qty','')::numeric,
        coalesce((v_data->>'general_available_capped')::boolean,false),v_data->>'source_display_value',
        target_batch_id,v_stage.source_updated_at,v_batch.integration_source,v_stage.source_version,v_actor.id
      ) on conflict(product_code,branch_id) do update set
        physical_qty = case when v_data?'stock_qty' then (v_data->>'stock_qty')::numeric else product_branch_stock.physical_qty end,
        sap_stock_qty = case when v_data?'stock_qty' then (v_data->>'stock_qty')::numeric else product_branch_stock.sap_stock_qty end,
        sap_confirmed_qty = case when v_data?'confirmed_qty' then (v_data->>'confirmed_qty')::numeric else product_branch_stock.sap_confirmed_qty end,
        sap_sales_available_qty = case when v_data?'sales_available_qty' then (v_data->>'sales_available_qty')::numeric else product_branch_stock.sap_sales_available_qty end,
        sap_authorized_pending_qty = case when v_data?'authorized_pending_qty' then (v_data->>'authorized_pending_qty')::numeric else product_branch_stock.sap_authorized_pending_qty end,
        sap_general_available_qty = case when v_data?'general_available_qty' then (v_data->>'general_available_qty')::numeric else product_branch_stock.sap_general_available_qty end,
        available_qty_capped = case when v_data?'general_available_capped' then (v_data->>'general_available_capped')::boolean else product_branch_stock.available_qty_capped end,
        source_display_value = case when v_data?'source_display_value' then v_data->>'source_display_value' else product_branch_stock.source_display_value end,
        source_batch_id = target_batch_id,
        source_updated_at = v_stage.source_updated_at,
        source_system = v_batch.integration_source,
        source_version = v_stage.source_version,
        updated_by = v_actor.id;

      select to_jsonb(s) into v_after
      from public.product_branch_stock s
      where s.product_code = v_stage.codigo and s.branch_id = v_branch.id;
      v_delta := coalesce((v_after->>'physical_qty')::numeric,0)
        - coalesce((v_before->>'physical_qty')::numeric,0);
      if v_delta <> 0 then
        insert into public.stock_movements(
          branch_id,product_code,movement_type,physical_delta,balance_before,balance_after,source,
          reference_type,reference_id,idempotency_key,metadata,created_by
        ) values (
          v_branch.id,v_stage.codigo,'SYNC_ERP',v_delta,coalesce(v_before,'{}'::jsonb),v_after,
          v_batch.integration_source,'products_import_batches',target_batch_id,
          'DATA_SYNC|'||target_batch_id||'|'||v_stage.id||'|PHYSICAL',
          jsonb_build_object(
            'batch_id',target_batch_id,
            'source_version',v_stage.source_version,
            'stock_before',v_before->'physical_qty',
            'stock_received',v_after->'physical_qty',
            'difference',v_delta
          ),
          v_actor.id
        ) returning id into v_movement_id;
      end if;
    elsif v_stage.sync_area = 'BASE_PRICE' then
      select * into v_branch from public.branches
      where code = v_stage.branch_code and active;
      insert into public.product_branch_prices(
        product_code,branch_id,sale_price,currency,version,source,source_batch_id,
        source_version,source_updated_at,updated_by,valid_from
      ) values (
        v_stage.codigo,v_branch.id,(v_data->>'base_price')::numeric,coalesce(v_data->>'currency','BRL'),1,
        v_batch.integration_source,target_batch_id,v_stage.source_version,v_stage.source_updated_at,v_actor.id,current_date
      ) on conflict(product_code,branch_id) do update set
        sale_price = case when v_data?'base_price' then (v_data->>'base_price')::numeric else product_branch_prices.sale_price end,
        currency = case when v_data?'currency' then v_data->>'currency' else product_branch_prices.currency end,
        source = v_batch.integration_source,
        source_batch_id = target_batch_id,
        source_version = v_stage.source_version,
        source_updated_at = v_stage.source_updated_at,
        updated_by = v_actor.id,
        valid_until = null;
    elsif v_stage.sync_area = 'ROUTE_PRICE' then
      select * into v_branch from public.branches
      where code = left(v_stage.route,2) and active;
      insert into public.product_route_prices(
        product_code,origin_branch_id,destination_state,route,base_price,final_price,total_taxes,tax_breakdown,
        calculation_status,currency,source,source_version,source_updated_at,source_batch_id,updated_by
      ) values (
        v_stage.codigo,v_branch.id,right(v_stage.route,2),v_stage.route,nullif(v_data->>'base_price','')::numeric,
        (v_data->>'final_price')::numeric,nullif(v_data->>'total_taxes','')::numeric,coalesce(v_data->'tax_breakdown','{}'::jsonb),
        coalesce(v_data->>'calculation_status','OK'),coalesce(v_data->>'currency','BRL'),v_batch.integration_source,
        v_stage.source_version,v_stage.source_updated_at,target_batch_id,v_actor.id
      ) on conflict(product_code,route) do update set
        base_price = case when v_data?'base_price' then (v_data->>'base_price')::numeric else product_route_prices.base_price end,
        final_price = case when v_data?'final_price' then (v_data->>'final_price')::numeric else product_route_prices.final_price end,
        total_taxes = case when v_data?'total_taxes' then (v_data->>'total_taxes')::numeric else product_route_prices.total_taxes end,
        tax_breakdown = case when v_data?'tax_breakdown' then v_data->'tax_breakdown' else product_route_prices.tax_breakdown end,
        calculation_status = case when v_data?'calculation_status' then v_data->>'calculation_status' else product_route_prices.calculation_status end,
        currency = case when v_data?'currency' then v_data->>'currency' else product_route_prices.currency end,
        origin_branch_id = v_branch.id,
        destination_state = right(v_stage.route,2),
        source = v_batch.integration_source,
        source_version = v_stage.source_version,
        source_updated_at = v_stage.source_updated_at,
        source_batch_id = target_batch_id,
        updated_by = v_actor.id;
    end if;

    v_after := public.get_data_sync_current_values(
      v_stage.sync_area,
      v_stage.codigo,
      v_stage.branch_code,
      v_stage.route
    )-'_exists'-'_updated_at'-'_version';

    for v_field in select unnest(v_stage.changed_fields) loop
      insert into public.products_import_audit(
        batch_id,stage_id,codigo,action,before_data,after_data,created_by,branch_id,entity_type,
        field_name,old_value,new_value,version_before,version_after,stock_movement_id,
        source,source_version,source_updated_at,route,status
      ) values (
        target_batch_id,v_stage.id,v_stage.codigo,lower(v_stage.planned_action),
        coalesce(v_stage.product_before,v_stage.stock_before,v_stage.price_before),v_after,
        coalesce(v_actor.usuario,'SYSTEM'),
        case when v_stage.sync_area = 'PRODUCT' then null else v_branch.id end,
        v_stage.sync_area,v_field,
        coalesce(v_stage.product_before,v_stage.stock_before,v_stage.price_before)->v_field,
        v_after->v_field,
        case when v_stage.sync_area = 'STOCK' then v_stage.stock_version else v_stage.price_version end,
        case when v_stage.sync_area in ('STOCK','BASE_PRICE','ROUTE_PRICE') then
          nullif((public.get_data_sync_current_values(
            v_stage.sync_area,v_stage.codigo,v_stage.branch_code,v_stage.route
          )->>'_version'),'')::bigint
          else null
        end,
        v_movement_id,v_batch.integration_source,v_stage.source_version,
        v_stage.source_updated_at,v_stage.route,'applied'
      );
    end loop;

    -- Canonical writes, field audit, stock movement and this marker share the
    -- same RPC transaction, so a failed chunk remains safely retryable.
    update public.products_import_stage
    set status = 'committed',
        product_after = case when sync_area = 'PRODUCT' then v_after else product_after end,
        stock_after = case when sync_area = 'STOCK' then v_after else stock_after end,
        price_after = case when sync_area in ('BASE_PRICE','ROUTE_PRICE') then v_after else price_after end
    where id = v_stage.id;
  end loop;

  select count(*)::integer into v_remaining
  from public.products_import_stage s
  where s.batch_id = target_batch_id
    and s.status in ('valid','warning')
    and s.planned_action in ('INSERT','UPDATE')
    and cardinality(s.changed_fields) > 0;

  v_result := jsonb_build_object(
    'done',v_remaining = 0,
    'processed',v_processed,
    'remaining',v_remaining
  );

  if v_remaining = 0 then
    select
      count(*) filter (where status = 'committed' and planned_action = 'INSERT')::integer,
      count(*) filter (where status = 'committed' and planned_action = 'UPDATE')::integer,
      count(*) filter (where planned_action = 'NO_CHANGE')::integer,
      count(*) filter (where status = 'error')::integer,
      count(*) filter (where skip_reason = 'STALE_SOURCE_EVENT')::integer,
      count(*) filter (where status = 'committed' and sync_area = 'PRODUCT')::integer,
      count(*) filter (where status = 'committed' and sync_area = 'PRODUCT' and planned_action = 'INSERT')::integer,
      count(*) filter (where status = 'committed' and sync_area = 'STOCK')::integer,
      count(*) filter (where status = 'committed' and sync_area = 'BASE_PRICE')::integer,
      count(*) filter (where status = 'committed' and sync_area = 'ROUTE_PRICE')::integer
    into v_inserted, v_updated, v_unchanged, v_invalid, v_stale,
      v_products, v_products_inserted, v_stocks, v_prices, v_fiscal
    from public.products_import_stage
    where batch_id = target_batch_id;

    v_ignored := v_invalid + v_stale;

    update public.products_import_batches
    set state = 'COMMITTED',
        status = case when v_invalid > 0 then 'completed_with_errors' else 'completed' end,
        inserted_rows = v_inserted,
        updated_rows = v_updated,
        unchanged_rows = v_unchanged,
        ignored_rows = v_ignored,
        stale_rows = v_stale,
        invalid_rows = v_invalid,
        error_count = v_invalid,
        finished_at = now(),
        committed_at = now(),
        imported_at = now(),
        last_attempt_completed_at = now(),
        committed_by_profile_id = v_actor.id,
        summary = summary || jsonb_build_object(
          'phase','COMPLETED',
          'inserted',v_inserted,
          'updated',v_updated,
          'unchanged',v_unchanged,
          'ignored',v_ignored,
          'concurrent_conflicts',(
            select count(*) from public.products_import_stage s
            where s.batch_id = target_batch_id and s.skip_reason = 'CONCURRENT_MODIFICATION'
          ),
          'products_changed',v_products,
          'products_inserted',v_products_inserted,
          'stocks_changed',v_stocks,
          'prices_changed',v_prices,
          'fiscal_results_changed',v_fiscal,
          'completed_at',now()
        )
    where id = target_batch_id;

    update public.data_sync_sources
    set connection_status = case when v_invalid > 0 then 'DEGRADED' else 'CONNECTED' end,
        last_seen_at = now(),
        last_success_at = now(),
        last_error_at = case when v_invalid > 0 then now() else last_error_at end,
        last_error = case
          when v_invalid > 0 then 'Lote concluído com linhas ignoradas ou inválidas.'
          else null
        end,
        next_sync_at = v_batch.next_sync_at
    where source_code = v_batch.integration_source;

    v_result := v_result || jsonb_build_object(
      'batch',public.get_data_sync_batch(target_batch_id)
    );
  end if;

  return v_result;
exception when others then
  update public.data_sync_sources
  set connection_status = 'DEGRADED',
      last_error_at = now(),
      last_error = sqlerrm
  where source_code = v_batch.integration_source;
  raise;
end;
$$;

revoke all on function public.commit_data_sync_batch_chunk(uuid,integer)
  from public,anon;
grant execute on function public.commit_data_sync_batch_chunk(uuid,integer)
  to authenticated,service_role;

comment on function public.commit_data_sync_batch_chunk(uuid,integer) is
  'Aplica primeiro produtos e converte dependências sem produto criável em erro auditável antes do commit em blocos.';

commit;
