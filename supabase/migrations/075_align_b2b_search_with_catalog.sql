begin;

set local lock_timeout = '10s';
set local statement_timeout = '110s';

create or replace function public.b2b_search_catalog(
  search_term text,
  line_filter text,
  only_available boolean,
  limit_count integer
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
  v_search_value text := left(regexp_replace(
    lower(unaccent(btrim(coalesce(search_term,'')))),
    '[^a-z0-9]+',' ','g'
  ),100);
  v_line_value text := upper(btrim(unaccent(coalesce(line_filter,''))));
  v_tokens text[];
begin
  v_search_value := btrim(regexp_replace(v_search_value,'[[:space:]]+',' ','g'));
  v_tokens := case when v_search_value='' then array[]::text[]
    else regexp_split_to_array(v_search_value,'[[:space:]]+') end;

  select * into v_account from public.customer_portal_accounts
  where user_id=auth.uid() and active;
  if v_account.user_id is null then raise exception 'ACESSO_B2B_NAO_AUTORIZADO'; end if;
  if not v_account.can_view_prices then raise exception 'PRECO_B2B_NAO_AUTORIZADO'; end if;

  select upper(btrim(coalesce(c.estado,''))) into v_client_state
  from public.clients c where c.id=v_account.client_id and c.ativo;
  v_origin_code := case v_client_state when 'SP' then 'SP' when 'PR' then 'PR' when 'SC' then 'PR' else null end;
  if v_origin_code is null then raise exception 'ROTA_B2B_NAO_CONFIGURADA'; end if;
  select b.id into v_origin_id from public.branches b where b.code=v_origin_code and b.active;
  if v_origin_id is null then raise exception 'FILIAL_B2B_NAO_CONFIGURADA'; end if;

  return query
  with eligible as (
    select
      p.codigo,p.descricao,p.marca,p.aplicacao,p.ano,p.url_imagem,
      rp.route,rp.final_price,rp.currency::text,
      lower(unaccent(concat_ws(' ',p.codigo,p.descricao,p.marca,p.aplicacao,p.ano,
        p.oem,p."similar",p.grupo,p.categoria,p.montadora,p.detalhes,p.search_text))) as search_document,
      lower(unaccent(concat_ws(' ',p.codigo,p.oem,p."similar"))) as identifier_document,
      lower(unaccent(coalesce(p.descricao,''))) as description_document,
      lower(unaccent(coalesce(p.aplicacao,''))) as application_document,
      lower(unaccent(concat_ws(' ',p.marca,p.montadora))) as brand_document
    from public.products p
    join public.product_route_prices rp
      on rp.product_code=p.codigo and rp.origin_branch_id=v_origin_id
      and rp.route=v_origin_code||'-'||v_client_state
      and rp.final_price>0 and upper(coalesce(rp.calculation_status,'OK')) like 'OK%'
    where v_line_value=''
       or upper(btrim(unaccent(coalesce(p.categoria,''))))=v_line_value
  ), scored as (
    select e.*,
      score.matched_terms,
      score.identifier_terms*45 + score.application_terms*25
        + score.description_terms*20 + score.brand_terms*10 as field_score,
      e.codigo=regexp_replace(v_search_value,'[[:space:]]+','','g') as exact_code,
      e.search_document like '%'||v_search_value||'%' as phrase_match
    from eligible e
    cross join lateral (
      select
        count(*) filter (where e.search_document like '%'||term.token||'%')::integer as matched_terms,
        count(*) filter (where e.identifier_document like '%'||term.token||'%')::integer as identifier_terms,
        count(*) filter (where e.application_document like '%'||term.token||'%')::integer as application_terms,
        count(*) filter (where e.description_document like '%'||term.token||'%')::integer as description_terms,
        count(*) filter (where e.brand_document like '%'||term.token||'%')::integer as brand_terms
      from unnest(v_tokens) as term(token)
    ) score
    where v_search_value='' or score.matched_terms=cardinality(v_tokens)
  ), catalog as (
    select
      p.*,
      case
        when s.product_code is null or (s.source_batch_id is null and coalesce(s.version,0)=0) then 'NAO_IMPORTADO'
        when s.available_qty>0 then 'DISPONIVEL'
        when v_origin_code='SP' and pr.available_qty>0
          and not (pr.source_batch_id is null and coalesce(pr.version,0)=0) then 'TRANSFERENCIA_PR'
        else 'INDISPONIVEL'
      end as availability,
      case when v_account.can_view_stock and s.product_code is not null
        and not (s.source_batch_id is null and coalesce(s.version,0)=0)
        then s.available_qty else null end as available_qty,
      case when v_account.can_view_stock and s.product_code is not null
        and not (s.source_batch_id is null and coalesce(s.version,0)=0)
        then coalesce(nullif(s.source_display_value,''),trim(to_char(s.available_qty,'FM999999999999990.###'))) else null end as source_display_value,
      case when v_account.can_view_stock and v_origin_code='SP' and pr.product_code is not null
        and not (pr.source_batch_id is null and coalesce(pr.version,0)=0)
        then pr.available_qty else null end as pr_transfer_available_qty,
      case when s.product_code is not null
        and not (s.source_batch_id is null and coalesce(s.version,0)=0)
        then s.updated_at else null end as stock_updated_at
    from scored p
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
  order by c.exact_code desc,c.phrase_match desc,c.matched_terms desc,
    c.field_score desc,c.codigo
  limit least(greatest(limit_count,1),50);
end;
$$;

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
language sql
stable
security definer
set search_path = public
as $$
  select * from public.b2b_search_catalog(search_term,'',only_available,limit_count)
$$;

create or replace function public.b2b_list_catalog_lines()
returns table(value text,label text)
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
begin
  select * into v_account from public.customer_portal_accounts
  where user_id=auth.uid() and active;
  if v_account.user_id is null then raise exception 'ACESSO_B2B_NAO_AUTORIZADO'; end if;
  if not v_account.can_view_prices then raise exception 'PRECO_B2B_NAO_AUTORIZADO'; end if;

  select upper(btrim(coalesce(c.estado,''))) into v_client_state
  from public.clients c where c.id=v_account.client_id and c.ativo;
  v_origin_code := case v_client_state when 'SP' then 'SP' when 'PR' then 'PR' when 'SC' then 'PR' else null end;
  if v_origin_code is null then raise exception 'ROTA_B2B_NAO_CONFIGURADA'; end if;
  select b.id into v_origin_id from public.branches b where b.code=v_origin_code and b.active;
  if v_origin_id is null then raise exception 'FILIAL_B2B_NAO_CONFIGURADA'; end if;

  return query
  select distinct btrim(p.categoria),btrim(p.categoria)
  from public.products p
  join public.product_route_prices rp
    on rp.product_code=p.codigo and rp.origin_branch_id=v_origin_id
    and rp.route=v_origin_code||'-'||v_client_state
    and rp.final_price>0 and upper(coalesce(rp.calculation_status,'OK')) like 'OK%'
  where nullif(btrim(p.categoria),'') is not null
  order by 2;
end;
$$;

revoke all on function public.b2b_search_catalog(text,text,boolean,integer),
  public.b2b_search_catalog(text,boolean,integer),public.b2b_list_catalog_lines()
  from public,anon,authenticated;
grant execute on function public.b2b_search_catalog(text,text,boolean,integer),
  public.b2b_search_catalog(text,boolean,integer),public.b2b_list_catalog_lines()
  to authenticated;

comment on function public.b2b_search_catalog(text,text,boolean,integer) is
  'Busca B2B por todas as palavras e linha, alinhada ao catálogo público Yokomitsu.';
comment on function public.b2b_list_catalog_lines() is
  'Linhas de produto com preço aprovado na rota do cliente B2B autenticado.';

commit;
