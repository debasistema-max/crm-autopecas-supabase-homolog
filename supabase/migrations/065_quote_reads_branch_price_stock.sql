begin;

set local lock_timeout = '10s';
set local statement_timeout = '110s';

create or replace function public.get_branch_product_availability(product_codes text[])
returns table(
  product_code text,
  sp_available_qty numeric,
  pr_available_qty numeric,
  sp_source_display_value text,
  pr_source_display_value text,
  sp_price numeric,
  pr_price numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with requested as (
    select distinct btrim(value) as codigo
    from unnest(coalesce(product_codes,'{}'::text[])) value
    where nullif(btrim(value),'') is not null
    limit 500
  ), branch_values as (
    select
      r.codigo,
      b.code,
      case
        when s.product_code is null
          or (s.source_batch_id is null and coalesce(s.version,0) = 0) then null
        else coalesce(s.sap_general_available_qty,s.available_qty,s.physical_qty)
      end as available_qty,
      case
        when s.product_code is null
          or (s.source_batch_id is null and coalesce(s.version,0) = 0) then null
        else s.source_display_value
      end as source_display_value,
      case
        when bp.product_code is null
          or (bp.source_batch_id is null and bp.source = 'LEGACY_SYNC' and bp.sale_price = 0) then null
        else bp.sale_price
      end as sale_price
    from requested r
    join public.products p on p.codigo = r.codigo
    cross join public.branches b
    left join public.product_branch_stock s
      on s.product_code = r.codigo and s.branch_id = b.id
    left join public.product_branch_prices bp
      on bp.product_code = r.codigo and bp.branch_id = b.id
      and bp.valid_from <= current_date
      and (bp.valid_until is null or bp.valid_until >= current_date)
    where b.active and b.code in ('PR','SP')
  )
  select
    codigo as product_code,
    max(available_qty) filter (where code = 'SP') as sp_available_qty,
    max(available_qty) filter (where code = 'PR') as pr_available_qty,
    max(source_display_value) filter (where code = 'SP') as sp_source_display_value,
    max(source_display_value) filter (where code = 'PR') as pr_source_display_value,
    max(sale_price) filter (where code = 'SP') as sp_price,
    max(sale_price) filter (where code = 'PR') as pr_price
  from branch_values
  where auth.uid() is null
    or public.is_admin()
    or public.has_module('produtos')
    or public.has_module('novo_pedido')
    or public.has_module('nova_cotacao')
  group by codigo
$$;

create or replace function public.search_products(
  term text,
  region text default 'SP',
  only_available boolean default false,
  limit_count integer default 40
)
returns table(
  codigo text,
  descricao text,
  marca text,
  aplicacao text,
  ano text,
  estoque text,
  preco numeric,
  preco_sp numeric,
  preco_pr numeric,
  status_estoque text,
  status_cadastro text,
  url_imagem text,
  grupo text,
  categoria text,
  montadora text,
  "similar" text
)
language sql
stable
security definer
set search_path = public
as $$
  with candidates as (
    select p0.*
    from public.products p0
    where (
        public.is_admin()
        or public.has_module('produtos')
        or public.has_module('novo_pedido')
        or public.has_module('nova_cotacao')
      )
      and (
        lower(unaccent(coalesce(term,''))) = ''
        or p0.search_vector @@ plainto_tsquery('simple',lower(unaccent(term)))
        or p0.search_text like '%' || lower(unaccent(term)) || '%'
      )
    order by similarity(p0.search_text,lower(unaccent(coalesce(term,'')))) desc,p0.codigo
    limit least(greatest(limit_count,1) * 5,500)
  ), commercial as (
    select *
    from public.get_branch_product_availability(
      array(select p0.codigo from candidates p0)
    )
  ), selected as (
    select
      p.*,
      c.sp_price,
      c.pr_price,
      case when upper(btrim(coalesce(region,'SP'))) = 'PR'
        then c.pr_available_qty else c.sp_available_qty end as selected_qty,
      case when upper(btrim(coalesce(region,'SP'))) = 'PR'
        then c.pr_source_display_value else c.sp_source_display_value end as selected_display,
      case when upper(btrim(coalesce(region,'SP'))) = 'PR'
        then c.pr_price else c.sp_price end as selected_price
    from candidates p
    left join commercial c on c.product_code = p.codigo
  )
  select
    p.codigo,
    p.descricao,
    p.marca,
    p.aplicacao,
    p.ano,
    coalesce(
      nullif(p.selected_display,''),
      case when p.selected_qty is not null then trim(to_char(p.selected_qty,'FM999999999999990.######')) end
    ) as estoque,
    p.selected_price as preco,
    p.sp_price as preco_sp,
    p.pr_price as preco_pr,
    case
      when p.selected_qty is null then 'ESTOQUE_NAO_IMPORTADO'
      when p.selected_qty > 0 then 'DISPONIVEL'
      else 'INDISPONIVEL'
    end as status_estoque,
    p.status_cadastro,
    p.url_imagem,
    p.grupo,
    p.categoria,
    p.montadora,
    p."similar"
  from selected p
  where not only_available or p.selected_qty > 0
  order by similarity(p.search_text,lower(unaccent(coalesce(term,'')))) desc,p.codigo
  limit least(greatest(limit_count,1),100)
$$;

revoke all on function public.get_branch_product_availability(text[]) from public,anon;
revoke all on function public.search_products(text,text,boolean,integer) from public,anon;
grant execute on function public.get_branch_product_availability(text[]) to authenticated,service_role;
grant execute on function public.search_products(text,text,boolean,integer) to authenticated,service_role;

comment on function public.get_branch_product_availability(text[]) is
  'Retorna preço base e estoque efetivamente importados por filial para até 500 produtos.';
comment on function public.search_products(text,text,boolean,integer) is
  'Busca comercial usada por cotação/pedido; lê preço e estoque normalizados por filial.';

commit;
