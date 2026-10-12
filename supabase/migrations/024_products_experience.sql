begin;

set local statement_timeout = '60s';
set local lock_timeout = '10s';
set local search_path = public, extensions;

create extension if not exists pg_trgm with schema extensions;

create table if not exists public.product_favorites (
  user_id uuid not null references public.profiles(id) on delete cascade,
  codigo text not null references public.products(codigo) on delete cascade,
  created_at timestamp with time zone not null default now(),
  constraint product_favorites_pkey primary key (user_id, codigo)
);

create table if not exists public.product_recent_views (
  user_id uuid not null references public.profiles(id) on delete cascade,
  codigo text not null references public.products(codigo) on delete cascade,
  viewed_at timestamp with time zone not null default now(),
  view_count integer not null default 1,
  constraint product_recent_views_pkey primary key (user_id, codigo),
  constraint product_recent_views_count_positive check (view_count >= 1)
);

create index if not exists product_favorites_codigo_idx
on public.product_favorites (codigo);

create index if not exists product_recent_views_user_viewed_idx
on public.product_recent_views (user_id, viewed_at desc);

create index if not exists product_recent_views_codigo_idx
on public.product_recent_views (codigo);

create index if not exists products_categoria_idx
on public.products (categoria);

create index if not exists products_grupo_idx
on public.products (grupo);

create index if not exists products_montadora_idx
on public.products (montadora);

create index if not exists products_oem_trgm_idx
on public.products using gin (oem gin_trgm_ops);

create index if not exists products_similar_trgm_idx
on public.products using gin ("similar" gin_trgm_ops);

create index if not exists products_aplicacao_trgm_idx
on public.products using gin (aplicacao gin_trgm_ops);

create index if not exists products_url_imagem_present_idx
on public.products (codigo)
where url_imagem is not null and url_imagem <> '';

alter table public.product_favorites enable row level security;
alter table public.product_recent_views enable row level security;

drop policy if exists product_favorites_select_own on public.product_favorites;
drop policy if exists product_favorites_insert_own on public.product_favorites;
drop policy if exists product_favorites_delete_own on public.product_favorites;
drop policy if exists product_favorites_own_read on public.product_favorites;
drop policy if exists product_favorites_own_write on public.product_favorites;

create policy product_favorites_select_own
on public.product_favorites
for select
using (user_id = auth.uid());

create policy product_favorites_insert_own
on public.product_favorites
for insert
with check (user_id = auth.uid());

create policy product_favorites_delete_own
on public.product_favorites
for delete
using (user_id = auth.uid());

drop policy if exists product_recent_views_select_own on public.product_recent_views;
drop policy if exists product_recent_views_insert_own on public.product_recent_views;
drop policy if exists product_recent_views_update_own on public.product_recent_views;
drop policy if exists product_recent_views_delete_own on public.product_recent_views;
drop policy if exists product_recent_views_own_read on public.product_recent_views;
drop policy if exists product_recent_views_own_write on public.product_recent_views;

create policy product_recent_views_select_own
on public.product_recent_views
for select
using (user_id = auth.uid());

create policy product_recent_views_insert_own
on public.product_recent_views
for insert
with check (user_id = auth.uid());

create policy product_recent_views_update_own
on public.product_recent_views
for update
using (user_id = auth.uid())
with check (user_id = auth.uid());

create policy product_recent_views_delete_own
on public.product_recent_views
for delete
using (user_id = auth.uid());

revoke all on public.product_favorites from public, anon, authenticated;
revoke all on public.product_recent_views from public, anon, authenticated;

grant select, insert, delete on public.product_favorites to authenticated;
grant select, insert, update, delete on public.product_recent_views to authenticated;

create or replace function public.record_product_recent_view(product_code text, max_items integer default 30)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_limit integer := greatest(1, least(coalesce(max_items, 30), 50));
  v_profile public.profiles;
begin
  select *
    into v_profile
  from public.profiles
  where id = v_user_id
    and ativo = true;

  if v_profile.id is null or not (
    public.has_module('produtos')
    or public.has_module('novo_pedido')
    or public.has_module('nova_cotacao')
  ) then
    raise exception 'SEM_PERMISSAO';
  end if;

  if not exists (select 1 from public.products where codigo = product_code) then
    raise exception 'PRODUTO_NAO_ENCONTRADO';
  end if;

  insert into public.product_recent_views (user_id, codigo, viewed_at, view_count)
  values (v_user_id, product_code, now(), 1)
  on conflict (user_id, codigo)
  do update set
    viewed_at = excluded.viewed_at,
    view_count = public.product_recent_views.view_count + 1;

  delete from public.product_recent_views rv
  where rv.user_id = v_user_id
    and rv.codigo not in (
      select keep.codigo
      from public.product_recent_views keep
      where keep.user_id = v_user_id
      order by keep.viewed_at desc
      limit v_limit
    );
end;
$$;

create or replace function public.get_product_price_history(product_code text, limit_count integer default 20)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  if auth.uid() is null or not (
    public.has_module('produtos')
    or public.has_module('novo_pedido')
    or public.has_module('nova_cotacao')
  ) then
    raise exception 'SEM_PERMISSAO';
  end if;

  select coalesce(jsonb_agg(item order by item->>'changed_at' desc), '[]'::jsonb)
    into v_result
  from (
    select jsonb_build_object(
      'changed_at', a.created_at,
      'batch_id', a.batch_id,
      'field', a.field_name,
      'old_value', a.old_value,
      'new_value', a.new_value
    ) as item,
    a.created_at as changed_at
    from public.products_import_audit a
    where a.codigo = product_code
      and a.field_name in ('preco_sp', 'preco_pr', 'preco_sem_imposto')

    union all

    select jsonb_build_object(
      'changed_at', a.created_at,
      'batch_id', a.batch_id,
      'field', legacy.field_name,
      'old_value', legacy.old_value,
      'new_value', legacy.new_value
    ) as item,
    a.created_at as changed_at
    from public.products_import_audit a
    cross join lateral (values
      ('preco_sp', a.before_data->'preco_sp', a.after_data->'preco_sp'),
      ('preco_pr', a.before_data->'preco_pr', a.after_data->'preco_pr'),
      ('preco_sem_imposto', a.before_data->'preco_sem_imposto', a.after_data->'preco_sem_imposto')
    ) legacy(field_name, old_value, new_value)
    where a.codigo = product_code
      and a.field_name is null
      and legacy.old_value is distinct from legacy.new_value
      and (legacy.old_value is not null or legacy.new_value is not null)

    order by changed_at desc
    limit greatest(1, least(coalesce(limit_count, 20), 100))
  ) history;

  return coalesce(v_result, '[]'::jsonb);
end;
$$;

create or replace function public.get_product_stock_history(product_code text, limit_count integer default 20)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  if auth.uid() is null or not (
    public.has_module('produtos')
    or public.has_module('novo_pedido')
    or public.has_module('nova_cotacao')
  ) then
    raise exception 'SEM_PERMISSAO';
  end if;

  select coalesce(jsonb_agg(item order by item->>'changed_at' desc), '[]'::jsonb)
    into v_result
  from (
    select jsonb_build_object(
      'changed_at', a.created_at,
      'batch_id', a.batch_id,
      'field', a.field_name,
      'old_value', a.old_value,
      'new_value', a.new_value
    ) as item,
    a.created_at as changed_at
    from public.products_import_audit a
    where a.codigo = product_code
      and a.field_name in ('estoque', 'estoque_quantidade', 'status_estoque')

    union all

    select jsonb_build_object(
      'changed_at', a.created_at,
      'batch_id', a.batch_id,
      'field', legacy.field_name,
      'old_value', legacy.old_value,
      'new_value', legacy.new_value
    ) as item,
    a.created_at as changed_at
    from public.products_import_audit a
    cross join lateral (values
      ('estoque', a.before_data->'estoque', a.after_data->'estoque'),
      ('estoque_quantidade', a.before_data->'estoque_quantidade', a.after_data->'estoque_quantidade'),
      ('status_estoque', a.before_data->'status_estoque', a.after_data->'status_estoque')
    ) legacy(field_name, old_value, new_value)
    where a.codigo = product_code
      and a.field_name is null
      and legacy.old_value is distinct from legacy.new_value
      and (legacy.old_value is not null or legacy.new_value is not null)

    order by changed_at desc
    limit greatest(1, least(coalesce(limit_count, 20), 100))
  ) history;

  return coalesce(v_result, '[]'::jsonb);
end;
$$;

create or replace function public.get_top_selling_products(limit_count integer default 12)
returns table (
  codigo text,
  descricao text,
  marca text,
  aplicacao text,
  montadora text,
  oem text,
  similar text,
  url_imagem text,
  estoque text,
  estoque_quantidade numeric,
  preco_sp numeric,
  preco_pr numeric,
  quantidade_vendida numeric,
  valor_vendido numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
begin
  select *
    into v_profile
  from public.profiles
  where id = auth.uid()
    and ativo = true;

  if v_profile.id is null or v_profile.perfil not in ('ADMIN', 'SUPERVISOR') then
    return;
  end if;

  return query
  select
    p.codigo,
    p.descricao,
    p.marca,
    p.aplicacao,
    p.montadora,
    p.oem,
    p."similar",
    p.url_imagem,
    p.estoque,
    p.estoque_quantidade,
    p.preco_sp,
    p.preco_pr,
    coalesce(sum(oi.quantidade), 0) as quantidade_vendida,
    coalesce(sum(oi.total_item), 0) as valor_vendido
  from public.order_items oi
  join public.products p on p.codigo = oi.codigo
  group by p.codigo, p.descricao, p.marca, p.aplicacao, p.montadora, p.oem, p."similar",
    p.url_imagem, p.estoque, p.estoque_quantidade, p.preco_sp, p.preco_pr
  order by coalesce(sum(oi.quantidade), 0) desc, coalesce(sum(oi.total_item), 0) desc, p.codigo
  limit greatest(1, least(coalesce(limit_count, 12), 50));
end;
$$;

revoke all on function public.record_product_recent_view(text, integer) from public, anon;
revoke all on function public.get_product_price_history(text, integer) from public, anon;
revoke all on function public.get_product_stock_history(text, integer) from public, anon;
revoke all on function public.get_top_selling_products(integer) from public, anon;

grant execute on function public.record_product_recent_view(text, integer) to authenticated;
grant execute on function public.get_product_price_history(text, integer) to authenticated;
grant execute on function public.get_product_stock_history(text, integer) to authenticated;
grant execute on function public.get_top_selling_products(integer) to authenticated;

comment on table public.product_favorites is 'Fase 2A: favoritos de produtos por usuario autenticado.';
comment on table public.product_recent_views is 'Fase 2A: produtos consultados recentemente por usuario autenticado.';
comment on function public.get_top_selling_products(integer) is 'Fase 2A: ranking agregado restrito a ADMIN e SUPERVISOR.';

commit;
