begin;

set local lock_timeout = '10s';
set local statement_timeout = '110s';

create or replace function public.b2b_search_catalog(
  search_term text default '',
  only_available boolean default false,
  limit_count integer default 40
)
returns table(
  product_code text,
  description text,
  brand text,
  application text,
  year text,
  image_url text,
  route text,
  final_price numeric,
  currency text,
  availability text,
  available_qty numeric,
  source_display_value text,
  pr_transfer_available_qty numeric,
  stock_updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_account public.customer_portal_accounts;
  v_client_state text;
  v_origin_code text;
  v_origin_id uuid;
  v_search_value text := left(btrim(coalesce(search_term,'')),100);
begin
  select * into v_account from public.customer_portal_accounts
  where user_id = auth.uid() and active;
  if v_account.user_id is null then raise exception 'ACESSO_B2B_NAO_AUTORIZADO'; end if;
  if not v_account.can_view_prices then raise exception 'PRECO_B2B_NAO_AUTORIZADO'; end if;

  select upper(btrim(coalesce(c.estado,''))) into v_client_state
  from public.clients c where c.id = v_account.client_id and c.ativo;
  v_origin_code := case v_client_state when 'SP' then 'SP' when 'PR' then 'PR' when 'SC' then 'PR' else null end;
  if v_origin_code is null then raise exception 'ROTA_B2B_NAO_CONFIGURADA'; end if;
  select b.id into v_origin_id from public.branches b where b.code = v_origin_code and b.active;
  if v_origin_id is null then raise exception 'FILIAL_B2B_NAO_CONFIGURADA'; end if;

  return query
  with candidates as (
    select p.*
    from public.products p
    where v_search_value = ''
       or p.search_vector @@ plainto_tsquery('simple',lower(unaccent(v_search_value)))
       or p.search_text like '%'||lower(unaccent(v_search_value))||'%'
    order by similarity(p.search_text,lower(unaccent(v_search_value))) desc,p.codigo
    limit least(greatest(limit_count,1)*5,250)
  ), catalog as (
    select
      p.codigo,p.descricao,p.marca,p.aplicacao,p.ano,p.url_imagem,
      rp.route,rp.final_price,rp.currency::text,
      case
        when s.product_code is null or (s.source_batch_id is null and coalesce(s.version,0)=0) then 'NAO_IMPORTADO'
        when s.available_qty > 0 then 'DISPONIVEL'
        when v_origin_code='SP' and pr.available_qty > 0
          and not (pr.source_batch_id is null and coalesce(pr.version,0)=0) then 'TRANSFERENCIA_PR'
        else 'INDISPONIVEL'
      end as availability,
      case when v_account.can_view_stock
        and s.product_code is not null
        and not (s.source_batch_id is null and coalesce(s.version,0)=0)
        then s.available_qty else null end as available_qty,
      case when v_account.can_view_stock
        and s.product_code is not null
        and not (s.source_batch_id is null and coalesce(s.version,0)=0)
        then coalesce(nullif(s.source_display_value,''),trim(to_char(s.available_qty,'FM999999999999990.###'))) else null end as source_display_value,
      case when v_account.can_view_stock and v_origin_code='SP'
        and pr.product_code is not null
        and not (pr.source_batch_id is null and coalesce(pr.version,0)=0)
        then pr.available_qty else null end as pr_transfer_available_qty,
      case when s.product_code is not null
        and not (s.source_batch_id is null and coalesce(s.version,0)=0)
        then s.updated_at else null end as stock_updated_at,
      p.search_text
    from candidates p
    join public.product_route_prices rp
      on rp.product_code=p.codigo and rp.origin_branch_id=v_origin_id
      and rp.route=v_origin_code||'-'||v_client_state
      and rp.final_price>0 and upper(coalesce(rp.calculation_status,'OK')) like 'OK%'
    left join public.product_branch_stock s
      on s.product_code=p.codigo and s.branch_id=v_origin_id
    left join public.branches prb on prb.code='PR' and prb.active
    left join public.product_branch_stock pr
      on pr.product_code=p.codigo and pr.branch_id=prb.id
  )
  select c.codigo,c.descricao,c.marca,c.aplicacao,c.ano,c.url_imagem,c.route,
    c.final_price,c.currency,c.availability,c.available_qty,c.source_display_value,
    c.pr_transfer_available_qty,c.stock_updated_at
  from catalog c
  where not only_available or c.availability in ('DISPONIVEL','TRANSFERENCIA_PR')
  order by similarity(c.search_text,lower(unaccent(v_search_value))) desc,c.codigo
  limit least(greatest(limit_count,1),50);
end;
$$;

revoke all on function public.b2b_search_catalog(text,boolean,integer)
  from public,anon,authenticated;
grant execute on function public.b2b_search_catalog(text,boolean,integer)
  to authenticated;

comment on function public.b2b_search_catalog(text,boolean,integer) is
  'Catálogo B2B isolado por cliente, rota, preço aprovado e snapshot de estoque.';

commit;
