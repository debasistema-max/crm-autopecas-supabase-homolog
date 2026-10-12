begin;

-- Fase 2C: indices voltados ao recorte temporal e ao ownership do dashboard.
create index if not exists orders_dashboard_status_created_idx
  on public.orders (status, created_at desc);

create index if not exists orders_dashboard_user_status_created_idx
  on public.orders (user_id, status, created_at desc);

create index if not exists quotations_dashboard_status_created_idx
  on public.quotations (status, created_at desc);

create index if not exists quotations_dashboard_user_status_created_idx
  on public.quotations (user_id, status, created_at desc);

create or replace function public.get_dashboard_summary(filters jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_profile public.profiles;
  v_is_admin boolean := false;
  v_scope_user_id uuid;
  v_requested_seller text := nullif(trim(coalesce(filters->>'seller_id', '')), '');
  v_region text := nullif(upper(trim(coalesce(filters->>'region', ''))), '');
  v_date_from date := date_trunc('month', current_date)::date;
  v_date_to date := current_date;
  v_timezone text := 'America/Sao_Paulo';
  v_from_utc timestamptz;
  v_to_utc timestamptz;
  v_granularity text;
  v_bucket_start timestamp;
  v_bucket_step interval;
  v_orders_document_count bigint := 0;
  v_orders_count bigint := 0;
  v_orders_realized_count bigint := 0;
  v_orders_value numeric := 0;
  v_average_ticket numeric := 0;
  v_quotations_document_count bigint := 0;
  v_quotations_count bigint := 0;
  v_quotations_value numeric := 0;
  v_pending_quotations bigint := 0;
  v_approved_quotations bigint := 0;
  v_converted_quotations bigint := 0;
  v_conversion_rate numeric := 0;
  v_active_clients bigint := 0;
  v_products_sold bigint := 0;
  v_orders_by_status jsonb := '[]'::jsonb;
  v_quotations_by_status jsonb := '[]'::jsonb;
  v_sellers jsonb := '[]'::jsonb;
  v_seller_ranking jsonb := '[]'::jsonb;
  v_product_ranking jsonb := '[]'::jsonb;
  v_client_ranking jsonb := '[]'::jsonb;
  v_abc_curve jsonb := '[]'::jsonb;
  v_series jsonb := '[]'::jsonb;
  v_stock jsonb := '{}'::jsonb;
  v_imports jsonb := '{}'::jsonb;
  v_result jsonb;
begin
  if v_user_id is null then
    raise exception 'SEM_PERMISSAO';
  end if;

  select p.*
    into v_profile
  from public.profiles p
  where p.id = v_user_id
    and p.ativo = true;

  if v_profile.id is null
     or v_profile.perfil::text not in ('ADMIN', 'SUPERVISOR', 'VENDEDOR')
     or not (public.is_admin() or public.has_module('dashboard') or public.has_module('dashboard_comercial')) then
    raise exception 'SEM_PERMISSAO';
  end if;

  if filters is not null and jsonb_typeof(filters) <> 'object' then
    raise exception 'FILTROS_INVALIDOS';
  end if;

  v_is_admin := v_profile.perfil::text = 'ADMIN' and public.is_admin();
  v_scope_user_id := case when v_is_admin then null else v_user_id end;

  begin
    v_date_from := coalesce(nullif(filters->>'date_from', '')::date, date_trunc('month', current_date)::date);
    v_date_to := coalesce(nullif(filters->>'date_to', '')::date, current_date);
  exception
    when invalid_datetime_format or datetime_field_overflow then
      raise exception 'DATA_INVALIDA';
  end;

  if v_date_to < v_date_from then
    raise exception 'PERIODO_INVALIDO';
  end if;

  if v_date_to - v_date_from > 370 then
    raise exception 'PERIODO_MUITO_LONGO';
  end if;

  if v_region is not null and v_region not in ('SP', 'PR') then
    raise exception 'REGIAO_INVALIDA';
  end if;

  if v_requested_seller is not null then
    if not v_is_admin then
      raise exception 'FILTRO_VENDEDOR_NAO_PERMITIDO';
    end if;

    begin
      v_scope_user_id := v_requested_seller::uuid;
    exception
      when invalid_text_representation then
        raise exception 'VENDEDOR_INVALIDO';
    end;

    if not exists (
      select 1
      from public.profiles p
      where p.id = v_scope_user_id
        and p.ativo = true
        and p.perfil::text in ('ADMIN', 'SUPERVISOR', 'VENDEDOR')
    ) then
      raise exception 'VENDEDOR_INVALIDO';
    end if;
  end if;

  select nullif(trim(cs.timezone), '')
    into v_timezone
  from public.company_settings cs
  where cs.id = true;

  if v_timezone is null
     or not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = v_timezone) then
    v_timezone := 'America/Sao_Paulo';
  end if;

  v_from_utc := v_date_from::timestamp at time zone v_timezone;
  v_to_utc := (v_date_to + 1)::timestamp at time zone v_timezone;

  if v_date_to - v_date_from <= 31 then
    v_granularity := 'day';
    v_bucket_start := v_date_from::timestamp;
    v_bucket_step := interval '1 day';
  elsif v_date_to - v_date_from <= 180 then
    v_granularity := 'week';
    v_bucket_start := date_trunc('week', v_date_from::timestamp);
    v_bucket_step := interval '1 week';
  else
    v_granularity := 'month';
    v_bucket_start := date_trunc('month', v_date_from::timestamp);
    v_bucket_step := interval '1 month';
  end if;

  select
    count(*),
    count(*) filter (where o.status <> 'CANCELADO'),
    count(*) filter (where o.status in ('APROVADO', 'FATURADO')),
    coalesce(sum(o.total) filter (where o.status in ('APROVADO', 'FATURADO')), 0),
    count(distinct coalesce(
      nullif(trim(o.codigo_sap_cliente), ''),
      nullif(regexp_replace(coalesce(o.cnpj, ''), '[^0-9]', '', 'g'), ''),
      nullif(lower(trim(o.cliente)), '')
    ))
  into
    v_orders_document_count,
    v_orders_count,
    v_orders_realized_count,
    v_orders_value,
    v_active_clients
  from public.orders o
  where o.created_at >= v_from_utc
    and o.created_at < v_to_utc
    and (v_region is null or o.regiao::text = v_region)
    and (v_scope_user_id is null or o.user_id = v_scope_user_id);

  v_average_ticket := case
    when v_orders_realized_count > 0 then round(v_orders_value / v_orders_realized_count, 2)
    else 0
  end;

  select count(distinct oi.codigo)
    into v_products_sold
  from public.order_items oi
  join public.orders o on o.id = oi.order_id
  where o.created_at >= v_from_utc
    and o.created_at < v_to_utc
    and o.status in ('APROVADO', 'FATURADO')
    and (v_region is null or o.regiao::text = v_region)
    and (v_scope_user_id is null or o.user_id = v_scope_user_id);

  select coalesce(jsonb_agg(to_jsonb(status_rows) order by status_rows.status), '[]'::jsonb)
    into v_orders_by_status
  from (
    select
      o.status::text as status,
      count(*)::bigint as count,
      round(coalesce(sum(o.total), 0), 2) as total_value
    from public.orders o
    where o.created_at >= v_from_utc
      and o.created_at < v_to_utc
      and (v_region is null or o.regiao::text = v_region)
      and (v_scope_user_id is null or o.user_id = v_scope_user_id)
    group by o.status
  ) status_rows;

  select
    count(*),
    count(*) filter (where q.status in ('ENVIADA', 'APROVADA', 'CONVERTIDA')),
    coalesce(sum(q.total) filter (where q.status in ('ENVIADA', 'APROVADA', 'CONVERTIDA')), 0),
    count(*) filter (where q.status in ('NOVA', 'ENVIADA')),
    count(*) filter (where q.status in ('APROVADA', 'CONVERTIDA')),
    count(distinct q.id) filter (
      where q.status in ('ENVIADA', 'APROVADA', 'CONVERTIDA')
        and c.quotation_id is not null
    )
  into
    v_quotations_document_count,
    v_quotations_count,
    v_quotations_value,
    v_pending_quotations,
    v_approved_quotations,
    v_converted_quotations
  from public.quotations q
  left join public.quotation_order_conversions c on c.quotation_id = q.id
  where q.created_at >= v_from_utc
    and q.created_at < v_to_utc
    and (v_region is null or q.regiao::text = v_region)
    and (v_scope_user_id is null or q.user_id = v_scope_user_id);

  v_conversion_rate := case
    when v_quotations_count > 0 then round(100.0 * v_converted_quotations / v_quotations_count, 2)
    else 0
  end;

  select coalesce(jsonb_agg(to_jsonb(status_rows) order by status_rows.status), '[]'::jsonb)
    into v_quotations_by_status
  from (
    select
      q.status::text as status,
      count(*)::bigint as count,
      round(coalesce(sum(q.total), 0), 2) as total_value
    from public.quotations q
    where q.created_at >= v_from_utc
      and q.created_at < v_to_utc
      and (v_region is null or q.regiao::text = v_region)
      and (v_scope_user_id is null or q.user_id = v_scope_user_id)
    group by q.status
  ) status_rows;

  if v_is_admin then
    select coalesce(jsonb_agg(to_jsonb(seller_rows) order by seller_rows.nome, seller_rows.usuario), '[]'::jsonb)
      into v_sellers
    from (
      select p.id, p.nome, p.usuario
      from public.profiles p
      where p.ativo = true
        and p.perfil::text in ('ADMIN', 'SUPERVISOR', 'VENDEDOR')
      order by p.nome, p.usuario
      limit 200
    ) seller_rows;

    select coalesce(jsonb_agg(to_jsonb(ranking_rows) order by ranking_rows.total desc, ranking_rows.nome), '[]'::jsonb)
      into v_seller_ranking
    from (
      select
        o.user_id as id,
        case
          when o.user_id is null then 'Sem responsavel'
          when p.ativo = true then coalesce(nullif(trim(p.nome), ''), p.usuario)
          else 'Usuario inativo'
        end as nome,
        count(*)::bigint as pedidos,
        round(coalesce(sum(o.total), 0), 2) as total,
        round(coalesce(avg(o.total), 0), 2) as ticket_medio
      from public.orders o
      left join public.profiles p on p.id = o.user_id
      where o.created_at >= v_from_utc
        and o.created_at < v_to_utc
        and o.status in ('APROVADO', 'FATURADO')
        and (v_region is null or o.regiao::text = v_region)
        and (v_scope_user_id is null or o.user_id = v_scope_user_id)
      group by o.user_id, p.ativo, p.nome, p.usuario
      order by total desc, nome
      limit 10
    ) ranking_rows;
  end if;

  select coalesce(jsonb_agg(to_jsonb(ranking_rows) order by ranking_rows.total desc, ranking_rows.codigo), '[]'::jsonb)
    into v_product_ranking
  from (
    select
      oi.codigo,
      coalesce(nullif(max(trim(oi.descricao)), ''), oi.codigo) as descricao,
      round(coalesce(sum(oi.quantidade), 0), 3) as quantidade,
      round(coalesce(sum(oi.total_item), 0), 2) as total
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    where o.created_at >= v_from_utc
      and o.created_at < v_to_utc
      and o.status in ('APROVADO', 'FATURADO')
      and (v_region is null or o.regiao::text = v_region)
      and (v_scope_user_id is null or o.user_id = v_scope_user_id)
    group by oi.codigo
    order by total desc, quantidade desc, oi.codigo
    limit 10
  ) ranking_rows;

  select coalesce(jsonb_agg(to_jsonb(ranking_rows) order by ranking_rows.total desc, ranking_rows.nome), '[]'::jsonb)
    into v_client_ranking
  from (
    select
      coalesce(
        nullif(trim(o.codigo_sap_cliente), ''),
        nullif(regexp_replace(coalesce(o.cnpj, ''), '[^0-9]', '', 'g'), ''),
        lower(trim(o.cliente))
      ) as client_key,
      max(o.cliente) as nome,
      count(*)::bigint as pedidos,
      round(coalesce(sum(o.total), 0), 2) as total,
      round(coalesce(avg(o.total), 0), 2) as ticket_medio
    from public.orders o
    where o.created_at >= v_from_utc
      and o.created_at < v_to_utc
      and o.status in ('APROVADO', 'FATURADO')
      and (v_region is null or o.regiao::text = v_region)
      and (v_scope_user_id is null or o.user_id = v_scope_user_id)
    group by coalesce(
      nullif(trim(o.codigo_sap_cliente), ''),
      nullif(regexp_replace(coalesce(o.cnpj, ''), '[^0-9]', '', 'g'), ''),
      lower(trim(o.cliente))
    )
    order by total desc, nome
    limit 10
  ) ranking_rows;

  with product_sales as (
    select
      oi.codigo,
      round(coalesce(sum(oi.total_item), 0), 2) as total_value
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    where o.created_at >= v_from_utc
      and o.created_at < v_to_utc
      and o.status in ('APROVADO', 'FATURADO')
      and (v_region is null or o.regiao::text = v_region)
      and (v_scope_user_id is null or o.user_id = v_scope_user_id)
    group by oi.codigo
    having coalesce(sum(oi.total_item), 0) > 0
  ), ranked as (
    select
      ps.*,
      sum(ps.total_value) over () as grand_total,
      sum(ps.total_value) over (
        order by ps.total_value desc, ps.codigo
        rows between unbounded preceding and current row
      ) - ps.total_value as previous_total
    from product_sales ps
  ), classified as (
    select
      case
        when grand_total <= 0 or previous_total / grand_total < 0.80 then 'A'
        when previous_total / grand_total < 0.95 then 'B'
        else 'C'
      end as curve,
      total_value
    from ranked
  )
  select coalesce(jsonb_agg(to_jsonb(curve_rows) order by curve_rows.curve), '[]'::jsonb)
    into v_abc_curve
  from (
    select curve, count(*)::bigint as products, round(sum(total_value), 2) as total_value
    from classified
    group by curve
  ) curve_rows;

  with buckets as (
    select generate_series(v_bucket_start, v_date_to::timestamp, v_bucket_step) as bucket
  ), order_values as (
    select
      date_trunc(v_granularity, o.created_at at time zone v_timezone) as bucket,
      count(*)::bigint as orders_count,
      round(coalesce(sum(o.total), 0), 2) as orders_value
    from public.orders o
    where o.created_at >= v_from_utc
      and o.created_at < v_to_utc
      and o.status in ('APROVADO', 'FATURADO')
      and (v_region is null or o.regiao::text = v_region)
      and (v_scope_user_id is null or o.user_id = v_scope_user_id)
    group by 1
  ), quotation_values as (
    select
      date_trunc(v_granularity, q.created_at at time zone v_timezone) as bucket,
      count(*)::bigint as quotations_count
    from public.quotations q
    where q.created_at >= v_from_utc
      and q.created_at < v_to_utc
      and q.status in ('ENVIADA', 'APROVADA', 'CONVERTIDA')
      and (v_region is null or q.regiao::text = v_region)
      and (v_scope_user_id is null or q.user_id = v_scope_user_id)
    group by 1
  ), conversion_values as (
    select
      date_trunc(v_granularity, c.converted_at at time zone v_timezone) as bucket,
      count(*)::bigint as conversions_count
    from public.quotation_order_conversions c
    join public.quotations q on q.id = c.quotation_id
    where c.converted_at >= v_from_utc
      and c.converted_at < v_to_utc
      and (v_region is null or q.regiao::text = v_region)
      and (v_scope_user_id is null or q.user_id = v_scope_user_id)
    group by 1
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'period', b.bucket::date,
      'label', case
        when v_granularity = 'month' then to_char(b.bucket, 'MM/YYYY')
        else to_char(b.bucket, 'DD/MM')
      end,
      'orders_count', coalesce(o.orders_count, 0),
      'orders_value', coalesce(o.orders_value, 0),
      'quotations_count', coalesce(q.quotations_count, 0),
      'conversions_count', coalesce(c.conversions_count, 0)
    ) order by b.bucket
  ), '[]'::jsonb)
    into v_series
  from buckets b
  left join order_values o on o.bucket = b.bucket
  left join quotation_values q on q.bucket = b.bucket
  left join conversion_values c on c.bucket = b.bucket;

  if v_is_admin then
    select jsonb_build_object(
      'total_products', count(*),
      'out_of_stock', count(*) filter (where coalesce(p.estoque_quantidade, 0) <= 0),
      'without_price', count(*) filter (where coalesce(p.preco_sp, 0) <= 0 and coalesce(p.preco_pr, 0) <= 0),
      'without_image', count(*) filter (where nullif(trim(p.url_imagem), '') is null)
    )
      into v_stock
    from public.products p;

    select jsonb_build_object(
      'last_batch', coalesce((
        select to_jsonb(last_row)
        from (
          select b.id, b.created_at, b.imported_at, b.status, b.region,
                 b.import_type, b.source_name, b.total_rows, b.valid_rows, b.error_count
          from public.products_import_batches b
          order by coalesce(b.imported_at, b.created_at) desc, b.created_at desc
          limit 1
        ) last_row
      ), '{}'::jsonb),
      'recent_failures', (
        select count(*)
        from public.products_import_batches b
        where b.created_at >= v_from_utc
          and b.created_at < v_to_utc
          and (b.status = 'failed' or b.error_count > 0)
      )
    ) into v_imports;
  end if;

  v_result := jsonb_build_object(
    'meta', jsonb_build_object(
      'version', '2C',
      'fallback', false,
      'timezone', v_timezone,
      'granularity', v_granularity
    ),
    'filters', jsonb_build_object(
      'date_from', v_date_from,
      'date_to', v_date_to,
      'region', v_region,
      'seller_id', case when v_is_admin then v_scope_user_id else null end
    ),
    'access', jsonb_build_object(
      'profile', v_profile.perfil::text,
      'scope', case
        when v_is_admin and v_scope_user_id is null then 'all'
        when v_is_admin then 'filtered'
        else 'own'
      end,
      'can_filter_seller', v_is_admin,
      'can_view_seller_ranking', v_is_admin,
      'can_view_stock', v_is_admin,
      'can_view_imports', v_is_admin
    ),
    'kpis', jsonb_build_object(
      'orders_count', v_orders_count,
      'orders_realized_count', v_orders_realized_count,
      'orders_value', round(v_orders_value, 2),
      'quotations_count', v_quotations_count,
      'quotations_value', round(v_quotations_value, 2),
      'pending_quotations', v_pending_quotations,
      'approved_quotations', v_approved_quotations,
      'converted_quotations', v_converted_quotations,
      'conversion_rate', v_conversion_rate,
      'average_ticket', v_average_ticket,
      'active_clients', v_active_clients,
      'products_sold', v_products_sold
    ),
    'orders', jsonb_build_object(
      'document_count', v_orders_document_count,
      'by_status', v_orders_by_status
    ),
    'quotations', jsonb_build_object(
      'document_count', v_quotations_document_count,
      'by_status', v_quotations_by_status
    ),
    'rankings', jsonb_build_object(
      'products', v_product_ranking,
      'clients', v_client_ranking
    ),
    'abc_curve', v_abc_curve,
    'series', v_series
  );

  if v_is_admin then
    v_result := v_result || jsonb_build_object(
      'sellers', v_sellers,
      'rankings', (v_result->'rankings') || jsonb_build_object('sellers', v_seller_ranking),
      'stock', v_stock,
      'imports', v_imports
    );
  end if;

  return v_result;
end;
$$;

comment on function public.get_dashboard_summary(jsonb)
is 'Fase 2C: resumo comercial por periodo, com escopo global apenas para ADMIN e ownership para SUPERVISOR/VENDEDOR.';

revoke all on function public.get_dashboard_summary(jsonb) from public, anon, authenticated, service_role;
grant execute on function public.get_dashboard_summary(jsonb) to authenticated;

commit;
