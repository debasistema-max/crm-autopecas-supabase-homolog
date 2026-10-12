-- Dashboard Comercial V2.1
-- Cria uma RPC agregada e segura para indicadores comerciais.
-- Esta migration nao altera fluxos de pedido, cotacao, importacao SAP ou lotes.
-- SECURITY DEFINER e usado para agregar dados de forma controlada sem depender
-- de multiplas consultas do frontend; a funcao valida auth.uid(), fixa search_path,
-- qualifica tabelas com schema e retorna somente campos necessarios.

insert into public.role_permissions (perfil, modulo, permitido)
values ('ADMIN', 'dashboard_comercial', true)
on conflict (perfil, modulo) do update set permitido = excluded.permitido;

insert into public.role_permissions (perfil, modulo, permitido)
values ('VENDEDOR', 'dashboard', true)
on conflict (perfil, modulo) do update set permitido = excluded.permitido;

create or replace function public.get_commercial_dashboard_summary(filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_user_id uuid := auth.uid();
  v_date_from date := date_trunc('month', current_date)::date;
  v_date_to date := current_date;
  v_date_to_exclusive timestamptz;
  v_region text := nullif(upper(trim(coalesce(filters->>'region', ''))), '');
  v_seller_filter text := nullif(trim(coalesce(filters->>'seller_id', '')), '');
  v_seller_id uuid := null;
  v_scope_all boolean := false;
  v_can_filter_seller boolean := false;
  v_can_access_dashboard boolean := false;
  v_can_view_imports boolean := false;
  v_can_view_products boolean := false;
  v_can_view_logs boolean := false;
  v_orders_count integer := 0;
  v_orders_total numeric := 0;
  v_orders_by_status jsonb := '[]'::jsonb;
  v_quotations_pending integer := 0;
  v_quotations_by_status jsonb := '[]'::jsonb;
  v_out_of_stock integer := 0;
  v_last_import jsonb := '{}'::jsonb;
  v_batches_by_status jsonb := '[]'::jsonb;
  v_recent_activities jsonb := '[]'::jsonb;
  v_sellers jsonb := '[]'::jsonb;
begin
  if v_user_id is null then
    raise exception 'SEM_PERMISSAO';
  end if;

  select id, legacy_id, usuario, nome, email, perfil, ativo, ultimo_login, created_at, updated_at
    into v_profile
  from public.profiles
  where id = v_user_id
    and ativo = true;

  if v_profile.id is null then
    raise exception 'SEM_PERMISSAO';
  end if;

  v_can_access_dashboard := public.is_admin() or public.has_module('dashboard') or public.has_module('dashboard_comercial');
  if not v_can_access_dashboard then
    raise exception 'SEM_PERMISSAO';
  end if;

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

  v_scope_all := public.is_admin() or public.has_module('dashboard_comercial');
  v_can_filter_seller := v_scope_all;
  v_can_view_imports := v_scope_all or public.has_module('visualizar_lotes_importacao') or public.has_module('alimentacao');
  v_can_view_products := public.is_admin() or public.has_module('produtos') or public.has_module('novo_pedido') or public.has_module('nova_cotacao');
  v_can_view_logs := v_scope_all or public.has_module('logs');
  v_date_to_exclusive := (v_date_to + 1)::timestamptz;

  if v_can_filter_seller and v_seller_filter is not null then
    begin
      v_seller_id := v_seller_filter::uuid;
    exception
      when invalid_text_representation then
        raise exception 'VENDEDOR_INVALIDO';
    end;
  end if;

  if v_can_filter_seller then
    select coalesce(jsonb_agg(to_jsonb(seller_rows) order by seller_rows.nome), '[]'::jsonb)
      into v_sellers
    from (
      select p.id, p.nome, p.usuario
      from public.profiles p
      where p.ativo = true
      order by p.nome, p.usuario
      limit 200
    ) seller_rows;
  end if;

  select count(*)::integer, coalesce(sum(o.total), 0)
    into v_orders_count, v_orders_total
  from public.orders o
  where o.created_at >= v_date_from::timestamptz
    and o.created_at < v_date_to_exclusive
    and (v_region is null or o.regiao::text = v_region)
    and (v_scope_all or o.user_id = v_user_id)
    and (v_seller_id is null or o.user_id = v_seller_id);

  select coalesce(jsonb_agg(to_jsonb(status_rows) order by status_rows.status), '[]'::jsonb)
    into v_orders_by_status
  from (
    select o.status::text as status, count(*)::integer as count, coalesce(sum(o.total), 0) as total_value
    from public.orders o
    where o.created_at >= v_date_from::timestamptz
      and o.created_at < v_date_to_exclusive
      and (v_region is null or o.regiao::text = v_region)
      and (v_scope_all or o.user_id = v_user_id)
      and (v_seller_id is null or o.user_id = v_seller_id)
    group by o.status
  ) status_rows;

  select count(*)::integer
    into v_quotations_pending
  from public.quotations q
  where q.created_at >= v_date_from::timestamptz
    and q.created_at < v_date_to_exclusive
    and q.status in ('NOVA', 'ENVIADA')
    and (v_region is null or q.regiao::text = v_region)
    and (v_scope_all or q.user_id = v_user_id)
    and (v_seller_id is null or q.user_id = v_seller_id);

  select coalesce(jsonb_agg(to_jsonb(status_rows) order by status_rows.status), '[]'::jsonb)
    into v_quotations_by_status
  from (
    select q.status::text as status, count(*)::integer as count, coalesce(sum(q.total), 0) as total_value
    from public.quotations q
    where q.created_at >= v_date_from::timestamptz
      and q.created_at < v_date_to_exclusive
      and (v_region is null or q.regiao::text = v_region)
      and (v_scope_all or q.user_id = v_user_id)
      and (v_seller_id is null or q.user_id = v_seller_id)
    group by q.status
  ) status_rows;

  if v_can_view_products then
    select count(*)::integer
      into v_out_of_stock
    from public.products p
    where p.estoque_quantidade <= 0;
  end if;

  if v_can_view_imports then
    select coalesce(to_jsonb(import_row), '{}'::jsonb)
      into v_last_import
    from (
      select
        b.id,
        b.created_at,
        b.imported_at,
        b.status,
        b.region,
        b.import_type,
        b.source_name,
        b.total_rows,
        b.valid_rows,
        b.error_count
      from public.products_import_batches b
      where b.status in ('imported', 'committed')
        and b.imported_at is not null
      order by b.imported_at desc, b.created_at desc
      limit 1
    ) import_row;

    select coalesce(jsonb_agg(to_jsonb(status_rows) order by status_rows.status), '[]'::jsonb)
      into v_batches_by_status
    from (
      select b.status, count(*)::integer as count
      from public.products_import_batches b
      where b.created_at >= v_date_from::timestamptz
        and b.created_at < v_date_to_exclusive
        and (v_region is null or b.region = v_region)
      group by b.status
    ) status_rows;
  end if;

  select coalesce(jsonb_agg(to_jsonb(activity_rows) order by activity_rows.data_hora desc), '[]'::jsonb)
    into v_recent_activities
  from (
    select
      l.data_hora,
      l.usuario,
      l.acao,
      l.entidade,
      l.id_entidade
    from public.logs l
    where l.data_hora >= v_date_from::timestamptz
      and l.data_hora < v_date_to_exclusive
      and (v_can_view_logs or l.user_id = v_user_id)
    order by l.data_hora desc
    limit 10
  ) activity_rows;

  return jsonb_build_object(
    'filters', jsonb_build_object(
      'date_from', v_date_from,
      'date_to', v_date_to,
      'region', v_region,
      'seller_id', case when v_can_filter_seller then v_seller_id::text else null end
    ),
    'access', jsonb_build_object(
      'scope', case when v_scope_all then 'all' else 'own' end,
      'can_filter_seller', v_can_filter_seller,
      'can_filter_region', true,
      'can_view_imports', v_can_view_imports,
      'can_view_products', v_can_view_products
    ),
    'sellers', coalesce(v_sellers, '[]'::jsonb),
    'orders', jsonb_build_object(
      'count', coalesce(v_orders_count, 0),
      'total_value', coalesce(v_orders_total, 0),
      'by_status', coalesce(v_orders_by_status, '[]'::jsonb)
    ),
    'quotations', jsonb_build_object(
      'pending_count', coalesce(v_quotations_pending, 0),
      'by_status', coalesce(v_quotations_by_status, '[]'::jsonb)
    ),
    'products', jsonb_build_object(
      'out_of_stock_count', coalesce(v_out_of_stock, 0)
    ),
    'imports', jsonb_build_object(
      'last_import', coalesce(v_last_import, '{}'::jsonb),
      'batches_by_status', coalesce(v_batches_by_status, '[]'::jsonb)
    ),
    'recent_activities', coalesce(v_recent_activities, '[]'::jsonb)
  );
end;
$$;

comment on function public.get_commercial_dashboard_summary(jsonb)
is 'Retorna indicadores agregados do Dashboard Comercial V2.1 com escopo por permissao e auth.uid().';

grant execute on function public.get_commercial_dashboard_summary(jsonb) to authenticated;
revoke execute on function public.get_commercial_dashboard_summary(jsonb) from public, anon;
