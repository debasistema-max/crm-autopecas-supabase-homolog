begin;

set local lock_timeout = '10s';
set local statement_timeout = '110s';

-- One internal search contract for catalog, quotations and orders.  It reads
-- the current normalized branch snapshots instead of the legacy stock/price
-- columns kept on products for backwards compatibility.
create or replace function public.search_products_v2(filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_term text := left(
    regexp_replace(lower(unaccent(btrim(coalesce(filters->>'term','')))),'[^a-z0-9]+',' ','g'),
    120
  );
  v_compact_term text;
  v_tokens text[];
  v_region text := case when upper(btrim(coalesce(filters->>'region','SP')))='PR' then 'PR' else 'SP' end;
  v_line text := btrim(coalesce(filters->>'line',''));
  v_group text := btrim(coalesce(filters->>'group',''));
  v_maker text := btrim(coalesce(filters->>'maker',''));
  v_brand text := btrim(coalesce(filters->>'brand',''));
  v_only_available boolean := coalesce((filters->>'only_available')::boolean,false);
  v_with_oem boolean := coalesce((filters->>'with_oem')::boolean,false);
  v_with_photo boolean := coalesce((filters->>'with_photo')::boolean,false);
  v_limit integer := least(greatest(coalesce((filters->>'limit')::integer,60),1),500);
  v_favorites text[] := '{}';
begin
  if not public.is_internal_user()
     or not (
       public.is_admin()
       or public.has_module('produtos')
       or public.has_module('novo_pedido')
       or public.has_module('nova_cotacao')
     ) then
    raise exception 'SEM_PERMISSAO';
  end if;

  if jsonb_typeof(coalesce(filters,'{}'::jsonb))<>'object' then
    raise exception 'FILTROS_INVALIDOS';
  end if;

  v_term := btrim(regexp_replace(v_term,'[[:space:]]+',' ','g'));
  v_compact_term := regexp_replace(v_term,'[[:space:]]+','','g');
  v_tokens := case when v_term='' then '{}'::text[] else regexp_split_to_array(v_term,'[[:space:]]+') end;

  if filters ? 'favorite_codes' then
    if jsonb_typeof(filters->'favorite_codes')<>'array'
       or jsonb_array_length(filters->'favorite_codes')>500 then
      raise exception 'FAVORITOS_INVALIDOS';
    end if;
    select coalesce(array_agg(distinct btrim(item #>> '{}')) filter(where btrim(item #>> '{}')<>''),'{}')
    into v_favorites
    from jsonb_array_elements(filters->'favorite_codes') as favorite(item);
  end if;

  return (
    with stock_values as (
      select
        s.product_code,
        max(case when b.code='SP' and not (s.source_batch_id is null and coalesce(s.version,0)=0)
          then coalesce(s.sap_general_available_qty,s.available_qty,s.physical_qty) end) as sp_available_qty,
        max(case when b.code='PR' and not (s.source_batch_id is null and coalesce(s.version,0)=0)
          then coalesce(s.sap_general_available_qty,s.available_qty,s.physical_qty) end) as pr_available_qty,
        max(case when b.code='SP' and not (s.source_batch_id is null and coalesce(s.version,0)=0)
          then s.available_qty end) as sp_transfer_available_qty,
        max(case when b.code='PR' and not (s.source_batch_id is null and coalesce(s.version,0)=0)
          then s.available_qty end) as pr_transfer_available_qty,
        max(case when b.code='SP' and not (s.source_batch_id is null and coalesce(s.version,0)=0)
          then s.source_display_value end) as sp_source_display_value,
        max(case when b.code='PR' and not (s.source_batch_id is null and coalesce(s.version,0)=0)
          then s.source_display_value end) as pr_source_display_value
      from public.product_branch_stock s
      join public.branches b on b.id=s.branch_id and b.active and b.code in ('PR','SP')
      group by s.product_code
    ), price_values as (
      select
        bp.product_code,
        max(case when b.code='SP' and not (
          bp.source_batch_id is null and bp.source='LEGACY_SYNC' and bp.sale_price=0
        ) then bp.sale_price end) as sp_price,
        max(case when b.code='PR' and not (
          bp.source_batch_id is null and bp.source='LEGACY_SYNC' and bp.sale_price=0
        ) then bp.sale_price end) as pr_price
      from public.product_branch_prices bp
      join public.branches b on b.id=bp.branch_id and b.active and b.code in ('PR','SP')
      where bp.valid_from<=current_date and (bp.valid_until is null or bp.valid_until>=current_date)
      group by bp.product_code
    ), enriched as (
      select
        p.*,
        coalesce(nullif(p.descricao,''),nullif(m.product_name,'')) as current_description,
        coalesce(nullif(p.aplicacao,''),nullif(m.applications,'')) as current_application,
        coalesce(nullif(p.categoria,''),nullif(m.line_name,'')) as current_line,
        coalesce(nullif(p.url_imagem,''),nullif(m.official_image_url,'')) as current_image,
        s.sp_available_qty,s.pr_available_qty,
        s.sp_transfer_available_qty,s.pr_transfer_available_qty,
        s.sp_source_display_value,s.pr_source_display_value,
        pv.sp_price,pv.pr_price,
        lower(unaccent(concat_ws(' ',
          p.codigo,p.descricao,p.marca,p.aplicacao,p.ano,p.oem,p."similar",
          p.grupo,p.categoria,p.montadora,p.detalhes,p.search_text,
          m.product_name,m.applications,m.line_name,m.catalog_details::text
        ))) as search_document
      from public.products p
      left join public.product_catalog_metadata m on m.product_code=p.codigo
      left join stock_values s on s.product_code=p.codigo
      left join price_values pv on pv.product_code=p.codigo
    ), ranked as (
      select
        e.*,
        e.codigo=v_compact_term as exact_code,
        e.search_document like '%'||v_term||'%' as phrase_match,
        case when v_term='' then 0 else similarity(e.search_document,v_term) end as fuzzy_score,
        case when v_region='PR' then e.pr_available_qty else e.sp_available_qty end as selected_qty,
        case when v_region='PR' then e.pr_source_display_value else e.sp_source_display_value end as selected_display,
        case when v_region='PR' then e.pr_price else e.sp_price end as selected_price
      from enriched e
      where
        (v_term='' or not exists (
          select 1 from unnest(v_tokens) token where e.search_document not like '%'||token||'%'
        ))
        and (v_line='' or e.current_line=v_line or e.categoria=v_line)
        and (v_group='' or e.grupo=v_group)
        and (v_maker='' or e.montadora=v_maker)
        and (v_brand='' or e.marca=v_brand)
        and (not v_with_oem or nullif(btrim(e.oem),'') is not null)
        and (not v_with_photo or e.current_image is not null)
        and (cardinality(v_favorites)=0 or e.codigo=any(v_favorites))
    ), selected as (
      select r.*
      from ranked r
      where not v_only_available or r.selected_qty>0
      order by r.exact_code desc,r.phrase_match desc,r.fuzzy_score desc,r.codigo
      limit v_limit
    ), payload as (
      select
        s.codigo,
        s.exact_code,
        s.phrase_match,
        s.fuzzy_score,
        jsonb_build_object(
          'codigo',s.codigo,
          'descricao',s.current_description,
          'marca',s.marca,
          'aplicacao',s.current_application,
          'ano',s.ano,
          'ncm',s.ncm,
          'cest',s.cest,
          'ipi',s.ipi,
          'ipi_rate',s.ipi_rate,
          'ipi_defined',s.ipi_defined,
          'origin_code',s.origin_code,
          'origin_description',s.origin_description,
          'material_group',s.material_group,
          'fiscal_group',s.fiscal_group,
          'preco_sem_imposto',s.preco_sem_imposto,
          'status_cadastro',s.status_cadastro,
          'grupo',s.grupo,
          'categoria',s.current_line,
          'linha',s.current_line,
          'montadora',s.montadora,
          'detalhes',s.detalhes,
          'oem',s.oem,
          'similar',s."similar",
          'url_imagem',s.current_image,
          'estoque',coalesce(nullif(s.selected_display,''),
            case when s.selected_qty is not null then trim(to_char(s.selected_qty,'FM999999999999990.######')) end),
          'estoque_quantidade',s.selected_qty,
          'preco',s.selected_price,
          'preco_sp',s.sp_price,
          'preco_pr',s.pr_price,
          'status_estoque',case
            when s.selected_qty is null then 'ESTOQUE_NAO_IMPORTADO'
            when s.selected_qty>0 then 'DISPONIVEL'
            else 'INDISPONIVEL'
          end,
          'branch_stock',jsonb_build_object(
            'product_code',s.codigo,
            'sp_available_qty',s.sp_available_qty,
            'pr_available_qty',s.pr_available_qty,
            'sp_transfer_available_qty',s.sp_transfer_available_qty,
            'pr_transfer_available_qty',s.pr_transfer_available_qty,
            'sp_source_display_value',s.sp_source_display_value,
            'pr_source_display_value',s.pr_source_display_value,
            'sp_price',s.sp_price,
            'pr_price',s.pr_price
          )
        ) as row_data
      from selected s
    )
    select coalesce(jsonb_agg(p.row_data order by p.exact_code desc,p.phrase_match desc,p.fuzzy_score desc,p.codigo),'[]'::jsonb)
    from payload p
  );
end;
$$;

revoke all on function public.search_products_v2(jsonb) from public,anon,authenticated;
grant execute on function public.search_products_v2(jsonb) to authenticated,service_role;

comment on function public.search_products_v2(jsonb) is
  'Busca unificada do CRM por palavras-chave e filtros; usa estoque/preço normalizados atuais por filial e metadados do catálogo.';

commit;
