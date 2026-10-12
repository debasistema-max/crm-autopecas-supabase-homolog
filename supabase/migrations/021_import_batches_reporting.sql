-- Relatorios administrativos dos lotes de importacao SAP.
-- Esta migration nao altera o fluxo de validacao/aprovacao/importacao da V2.

insert into public.role_permissions (perfil, modulo, permitido)
values ('ADMIN', 'visualizar_lotes_importacao', true)
on conflict (perfil, modulo) do update set permitido = excluded.permitido;

create or replace function public.can_view_products_import_batches()
returns boolean
language sql
security definer
set search_path = public
as $$
  select public.is_admin()
    or public.has_module('visualizar_lotes_importacao');
$$;

drop policy if exists products_import_batches_read on public.products_import_batches;
create policy products_import_batches_read
on public.products_import_batches
for select
using (public.can_view_products_import_batches());

drop policy if exists products_import_stage_read on public.products_import_stage;
create policy products_import_stage_read
on public.products_import_stage
for select
using (public.can_view_products_import_batches());

drop policy if exists products_import_audit_read on public.products_import_audit;
create policy products_import_audit_read
on public.products_import_audit
for select
using (public.can_view_products_import_batches());

create index if not exists products_import_batches_region_idx
  on public.products_import_batches (region, created_at desc);

create index if not exists products_import_batches_created_by_idx
  on public.products_import_batches (created_by, created_at desc);

create index if not exists products_import_stage_status_idx
  on public.products_import_stage (batch_id, status);

create or replace function public.get_products_import_batches_report(filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_page integer := greatest(coalesce((filters->>'page')::integer, 1), 1);
  v_page_size integer := least(greatest(coalesce((filters->>'page_size')::integer, 25), 1), 100);
  v_offset integer := 0;
  v_date_from timestamptz := nullif(filters->>'date_from', '')::timestamptz;
  v_date_to timestamptz := nullif(filters->>'date_to', '')::timestamptz;
  v_status text := nullif(filters->>'status', '');
  v_region text := nullif(upper(trim(coalesce(filters->>'region', ''))), '');
  v_user text := nullif(trim(coalesce(filters->>'user', '')), '');
  v_search text := nullif(trim(coalesce(filters->>'search', '')), '');
  v_source text := nullif(trim(coalesce(filters->>'source_name', '')), '');
  v_error_only boolean := coalesce((filters->>'error_only')::boolean, false);
  v_imported_only boolean := coalesce((filters->>'imported_only')::boolean, false);
  v_pending_only boolean := coalesce((filters->>'pending_only')::boolean, false);
begin
  if not public.can_view_products_import_batches() then
    raise exception 'SEM_PERMISSAO_VISUALIZAR_LOTES';
  end if;

  v_offset := (v_page - 1) * v_page_size;

  return (
    with filtered as materialized (
      select
        b.id,
        b.created_at,
        b.created_by,
        b.import_type,
        b.region,
        b.source_name,
        b.file_hash,
        b.status,
        b.total_rows,
        b.valid_rows,
        b.invalid_rows,
        b.warning_count,
        b.error_count,
        b.summary,
        b.approved_at,
        b.approved_by,
        b.imported_at,
        extract(epoch from (coalesce(b.imported_at, b.approved_at, b.failed_at, b.created_at) - b.created_at))::integer as duration_seconds,
        case when b.status in ('approved', 'imported', 'committed') then b.valid_rows else 0 end as approved_rows,
        case when b.status in ('imported', 'committed') then b.valid_rows else 0 end as imported_rows
      from public.products_import_batches b
      where (v_date_from is null or b.created_at >= v_date_from)
        and (v_date_to is null or b.created_at < v_date_to + interval '1 day')
        and (v_status is null or b.status = v_status)
        and (v_region is null or b.region = v_region)
        and (v_user is null or b.created_by ilike '%' || v_user || '%' or b.approved_by ilike '%' || v_user || '%')
        and (v_source is null or b.source_name ilike '%' || v_source || '%')
        and (not v_error_only or b.error_count > 0 or b.status = 'failed')
        and (not v_imported_only or b.status in ('imported', 'committed'))
        and (not v_pending_only or b.status in ('validating', 'validated', 'approved'))
        and (
          v_search is null
          or b.id::text ilike '%' || v_search || '%'
          or b.source_name ilike '%' || v_search || '%'
          or b.file_hash ilike '%' || v_search || '%'
          or b.created_by ilike '%' || v_search || '%'
          or b.approved_by ilike '%' || v_search || '%'
        )
    ),
    totals as (
      select
        count(*)::integer as total_batches,
        count(*) filter (where status in ('imported', 'committed'))::integer as imported_batches,
        count(*) filter (where error_count > 0 or status = 'failed')::integer as error_batches,
        count(*) filter (where status in ('validating', 'validated', 'approved'))::integer as pending_batches,
        coalesce(sum(total_rows), 0)::integer as total_products,
        coalesce(sum(imported_rows), 0)::integer as imported_products,
        coalesce(round(avg(case when total_rows > 0 then valid_rows::numeric / total_rows * 100 else null end), 2), 0) as success_percent
      from filtered
    ),
    paged as (
      select
        id,
        created_at,
        created_by,
        import_type,
        region,
        source_name,
        file_hash,
        status,
        total_rows,
        valid_rows,
        invalid_rows,
        warning_count,
        error_count,
        summary,
        approved_at,
        approved_by,
        imported_at,
        duration_seconds,
        approved_rows,
        imported_rows
      from filtered
      order by created_at desc, id desc
      limit v_page_size offset v_offset
    )
    select jsonb_build_object(
      'summary', to_jsonb(totals),
      'pagination', jsonb_build_object(
        'page', v_page,
        'pageSize', v_page_size,
        'total', totals.total_batches,
        'hasNext', v_offset + v_page_size < totals.total_batches,
        'hasPrevious', v_page > 1
      ),
      'rows', coalesce((
        select jsonb_agg(to_jsonb(paged) order by paged.created_at desc, paged.id desc)
        from paged
      ), '[]'::jsonb)
    )
    from totals
  );
end;
$$;

create or replace function public.get_products_import_batch_details(
  batch_id uuid,
  page integer default 1,
  page_size integer default 25
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_page integer := greatest(coalesce(page, 1), 1);
  v_page_size integer := least(greatest(coalesce(page_size, 25), 1), 100);
  v_offset integer := 0;
begin
  if not public.can_view_products_import_batches() then
    raise exception 'SEM_PERMISSAO_VISUALIZAR_LOTES';
  end if;

  v_offset := (v_page - 1) * v_page_size;

  return (
    with batch as (
      select
        b.id,
        b.created_at,
        b.created_by,
        b.import_type,
        b.region,
        b.source_name,
        b.file_hash,
        b.status,
        b.total_rows,
        b.valid_rows,
        b.invalid_rows,
        b.warning_count,
        b.error_count,
        b.summary,
        b.approved_at,
        b.approved_by,
        b.imported_at,
        extract(epoch from (coalesce(b.imported_at, b.approved_at, b.failed_at, b.created_at) - b.created_at))::integer as duration_seconds
      from public.products_import_batches b
      where b.id = get_products_import_batch_details.batch_id
    ),
    item_base as (
      select
        s.id,
        s.row_number,
        s.codigo,
        s.descricao_base,
        s.marca,
        s.grupo,
        s.montadora,
        s.modelo,
        s.aplicacao_texto,
        s.preco_sp,
        s.preco_pr,
        s.estoque_sp,
        s.estoque_pr,
        s.normalized_data,
        s.status,
        s.errors,
        s.warnings,
        coalesce(a.action, '') as action
      from public.products_import_stage s
      left join lateral (
        select pa.action
        from public.products_import_audit pa
        where pa.batch_id = s.batch_id
          and pa.codigo = s.codigo
        order by pa.created_at desc
        limit 1
      ) a on true
      where s.batch_id = get_products_import_batch_details.batch_id
    ),
    item_totals as (
      select count(*)::integer as total_items
      from item_base
    ),
    paged_items as (
      select
        id,
        row_number,
        codigo,
        descricao_base,
        marca,
        grupo,
        montadora,
        modelo,
        aplicacao_texto,
        preco_sp,
        preco_pr,
        estoque_sp,
        estoque_pr,
        normalized_data,
        status,
        errors,
        warnings,
        action
      from item_base
      order by row_number, id
      limit v_page_size offset v_offset
    ),
    audit_rows as (
      select
        a.id,
        a.created_at,
        a.created_by,
        a.action,
        a.codigo,
        a.field_name,
        a.old_value,
        a.new_value
      from public.products_import_audit a
      where a.batch_id = get_products_import_batch_details.batch_id
      order by a.created_at asc, a.codigo, a.field_name
      limit 150
    )
    select jsonb_build_object(
      'batch', coalesce((select to_jsonb(batch) from batch), '{}'::jsonb),
      'items', coalesce((select jsonb_agg(to_jsonb(paged_items) order by paged_items.row_number) from paged_items), '[]'::jsonb),
      'itemsPagination', jsonb_build_object(
        'page', v_page,
        'pageSize', v_page_size,
        'total', coalesce((select total_items from item_totals), 0),
        'hasNext', v_offset + v_page_size < coalesce((select total_items from item_totals), 0),
        'hasPrevious', v_page > 1
      ),
      'audit', coalesce((select jsonb_agg(to_jsonb(audit_rows) order by audit_rows.created_at asc, audit_rows.codigo, audit_rows.field_name) from audit_rows), '[]'::jsonb)
    )
  );
end;
$$;

grant execute on function public.can_view_products_import_batches() to authenticated;
grant execute on function public.get_products_import_batches_report(jsonb) to authenticated;
grant execute on function public.get_products_import_batch_details(uuid, integer, integer) to authenticated;

revoke execute on function public.can_view_products_import_batches() from public, anon;
revoke execute on function public.get_products_import_batches_report(jsonb) from public, anon;
revoke execute on function public.get_products_import_batch_details(uuid, integer, integer) from public, anon;
