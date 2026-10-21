begin;
set local lock_timeout='10s';
set local statement_timeout='110s';

-- Return vehicle makes from the catalog application tables. The legacy
-- products.montadora field stores supplier/manufacturer codes and must not be
-- presented as the vehicle manufacturer in commercial exports.
create or replace function public.product_vehicle_makers(catalog_details jsonb,details text)
returns text[]
language sql
stable
set search_path=public,pg_temp
as $$
  with raw_makers as (
    select upper(btrim(application->>'automaker')) as maker
    from jsonb_array_elements(
      case when jsonb_typeof(coalesce(catalog_details,'{}'::jsonb)->'applications')='array'
        then catalog_details->'applications' else '[]'::jsonb end
    ) application
    union all
    select upper(btrim(split_part(line,'|',1)))
    from regexp_split_to_table(
      split_part(
        split_part(replace(coalesce(details,''),chr(13),''),'Veiculos / anos informados no catalogo:'||chr(10),2),
        '[/CATALOGO_IPS_INSTALADO]',1
      ),
      chr(10)
    ) line
  ), individual_makers as (
    select upper(btrim(part)) as maker
    from raw_makers
    cross join lateral regexp_split_to_table(raw_makers.maker,'[[:space:]]*/[[:space:]]*') part
    where nullif(btrim(raw_makers.maker),'') is not null
  )
  select coalesce(array_agg(distinct maker order by maker) filter(
    where nullif(maker,'') is not null and length(maker)<=80
  ),'{}'::text[])
  from individual_makers;
$$;

revoke all on function public.product_vehicle_makers(jsonb,text) from public,anon,authenticated;

do $$
declare definition text; patch record;
begin
  definition:=pg_get_functiondef('public.search_products_v2(jsonb)'::regprocedure);
  for patch in select * from (values
    ('coalesce(nullif(p.url_imagem,''''),nullif(m.official_image_url,'''')) as current_image',
      'coalesce(nullif(p.url_imagem,''''),nullif(m.official_image_url,'''')) as current_image,coalesce(m.catalog_details,''{}''::jsonb) as current_catalog_details'),
    ('''grupo'',s.grupo,',
      '''grupo'',coalesce(nullif(btrim(s.grupo),''''),nullif(btrim(s.material_group),''''),nullif(btrim(s.fiscal_group),'''')),'),
    ('''montadora'',s.montadora,',
      '''montadora'',s.montadora,''vehicle_makers'',public.product_vehicle_makers(s.current_catalog_details,s.detalhes),')
  ) patches(old_text,new_text) loop
    if (length(definition)-length(replace(definition,patch.old_text,'')))<>length(patch.old_text) then
      raise exception 'CONTRATO_BUSCA_111_DIVERGENTE';
    end if;
    definition:=replace(definition,patch.old_text,patch.new_text);
  end loop;
  execute definition;
end;
$$;

notify pgrst,'reload schema';
commit;
