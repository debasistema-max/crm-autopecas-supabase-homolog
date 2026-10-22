begin;
set local lock_timeout='10s';
set local statement_timeout='110s';

create function public.canonical_vehicle_maker(value text)
returns text language plpgsql stable set search_path=public,pg_temp as $$
declare name text:=btrim(regexp_replace(upper(unaccent(coalesce(value,''))),'[^A-Z0-9]+',' ','g'));
begin
  return case
    when name in ('VW','VOLKSWAGEN') then 'VOLKSWAGEN'
    when name in ('MB','M BENZ','MERCEDES','MERCEDES BENZ') then 'MERCEDES-BENZ'
    when name in ('SSANG YONG','SSANGYONG') then 'SSANGYONG'
    when name in ('JAC','JAC MOTORS') then 'JAC'
    when name in ('','NAO INFORMADO','NAO INFORMADA','SEM INFORMACAO','NENHUM FABRICANTE','NULL','UNDEFINED') then null
    when name !~ '^[A-Z][A-Z ]{1,79}$' then null
    else name end;
end;
$$;
revoke all on function public.canonical_vehicle_maker(text) from public,anon,authenticated,service_role,ips_catalog_worker;

create or replace function public.product_vehicle_makers(catalog_details jsonb,details text)
returns text[] language plpgsql stable set search_path=public,pg_temp as $$
declare raw text;part text;maker text;block text;line text;source_text text:=coalesce(details,'');
  result text[]:='{}';start_marker text:='[CATALOGO_IPS_INSTALADO]';end_marker text:='[/CATALOGO_IPS_INSTALADO]';
  known_legacy_makers text[]:=array['AGRALE','ALFA','ASIA MOTORS','AUDI','BMW','CHERY','CHRYSLER','CITROEN','DAEWOO','DAIHATSU',
    'DODGE','EFFA','FIAT','FORD','GM','HONDA','HUMMER','HYUNDAI','ISUZU','IVECO','JAC','JEEP','KIA','LAND ROVER','LEXUS','LIFAN',
    'MAZDA','MERCEDES-BENZ','MINI','MITSUBISHI','NISSAN','PEUGEOT','PORSCHE','RENAULT','SCANIA','SEAT','SSANGYONG','SUBARU',
    'SUZUKI','TOYOTA','TROLLER','UNIVERSAL','VOLKSWAGEN','VOLVO'];
begin
  if jsonb_typeof(catalog_details->'applications')='array' then
    for raw in select application->>'automaker' from jsonb_array_elements(catalog_details->'applications') application
      where jsonb_typeof(application->'automaker')='string' loop
      foreach part in array regexp_split_to_array(raw,'[[:space:]]*/[[:space:]]*') loop
        maker:=public.canonical_vehicle_maker(part);
        if maker is not null then result:=array_append(result,maker);end if;
      end loop;
    end loop;
  end if;
  if strpos(source_text,start_marker)>0 and strpos(source_text,end_marker)>strpos(source_text,start_marker)
    and length(source_text)-length(replace(source_text,start_marker,''))=length(start_marker)
    and length(source_text)-length(replace(source_text,end_marker,''))=length(end_marker) then
    block:=split_part(split_part(split_part(replace(source_text,chr(13),''),start_marker,2),end_marker,1),
      'Veiculos / anos informados no catalogo:'||chr(10),2);
    foreach line in array string_to_array(block,chr(10)) loop
      foreach part in array regexp_split_to_array(split_part(line,'|',1),'[[:space:]]*/[[:space:]]*') loop
        maker:=public.canonical_vehicle_maker(part);
        -- The legacy writer omits empty columns; a model must not become a make.
        if maker=any(known_legacy_makers) then result:=array_append(result,maker);end if;
      end loop;
    end loop;
  end if;
  return array(select distinct value from unnest(result) value order by value);
end;
$$;
revoke all on function public.product_vehicle_makers(jsonb,text) from public,anon,authenticated,service_role,ips_catalog_worker;

create function public.matches_product_vehicle_maker(filter text,catalog_details jsonb,details text)
returns boolean language sql stable set search_path=public,pg_temp as $$
  select case when nullif(btrim(filter),'') is null then true
    when filter='__SEM_MONTADORA__' then cardinality(public.product_vehicle_makers(catalog_details,details))=0
    else coalesce(public.canonical_vehicle_maker(filter)=any(public.product_vehicle_makers(catalog_details,details)),false) end;
$$;
revoke all on function public.matches_product_vehicle_maker(text,jsonb,text) from public,anon,authenticated,service_role,ips_catalog_worker;

-- A new options endpoint leaves old frontend/picker contracts unchanged.
create function public.get_catalog_filter_options()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare result jsonb; makers jsonb; missing boolean;
begin
  result:=public.get_product_filters();
  select coalesce(jsonb_agg(maker order by maker),'[]'::jsonb) into makers
  from (select distinct maker from public.products p
    left join public.product_catalog_metadata m on m.product_code=p.codigo
    cross join lateral unnest(public.product_vehicle_makers(m.catalog_details,p.detalhes)) maker where p.ativo) options;
  select exists(select 1 from public.products p left join public.product_catalog_metadata m on m.product_code=p.codigo
    where p.ativo and cardinality(public.product_vehicle_makers(m.catalog_details,p.detalhes))=0) into missing;
  return result||jsonb_build_object('montadoras',makers||case when missing then '["__SEM_MONTADORA__"]'::jsonb else '[]'::jsonb end);
end $$;
revoke all on function public.get_catalog_filter_options() from public,anon,authenticated,service_role,ips_catalog_worker;
grant execute on function public.get_catalog_filter_options() to authenticated;

do $$ declare definition text; patch record;
begin
  definition:=pg_get_functiondef('public.search_products_v2(jsonb)'::regprocedure);
  for patch in select * from (values
    ('and (v_brand='''' or e.marca=v_brand)',
     'and (v_brand='''' or e.marca=v_brand) and public.matches_product_vehicle_maker(filters->>''vehicle_maker'',e.current_catalog_details,e.detalhes)'),
    ('m.product_name,m.applications,m.line_name,m.catalog_details::text',
     'm.product_name,m.applications,m.line_name,m.catalog_details::text,array_to_string(public.product_vehicle_makers(m.catalog_details,p.detalhes),'' '')')
  ) patches(old_text,new_text) loop
    if (length(definition)-length(replace(definition,patch.old_text,'')))<>length(patch.old_text) then raise exception 'CONTRATO_BUSCA_114_DIVERGENTE';end if;
    definition:=replace(definition,patch.old_text,patch.new_text);
  end loop;
  execute definition;
  definition:=pg_get_functiondef('public.generate_commercial_list(text,jsonb)'::regprocedure);
  for patch in select * from (values
    ('where p.ativo','where p.ativo and public.matches_product_vehicle_maker(filters->>''vehicle_maker'',m.catalog_details,p.detalhes)',2),
    ('as vehicle_types','as vehicle_types,public.product_vehicle_makers(m.catalog_details,p.detalhes) as vehicle_makers',1),
    ('select e.codigo,e.line,e.grupo,e.vehicle_types,','select e.codigo,e.line,e.grupo,e.vehicle_types,e.vehicle_makers,',1),
    ('select codigo,line,grupo,vehicle_types,row_data','select codigo,line,grupo,vehicle_types,vehicle_makers,row_data',2),
    ('''vehicle_types'',vehicle_types)','''vehicle_types'',vehicle_types,''vehicle_makers'',vehicle_makers)',1),
    ('? ''vehicle_type'')','? ''vehicle_type'' or coalesce(filters,''{}''::jsonb) ? ''vehicle_maker'')',1)
  ) patches(old_text,new_text,expected_count) loop
    if (length(definition)-length(replace(definition,patch.old_text,'')))<>length(patch.old_text)*patch.expected_count then raise exception 'CONTRATO_LISTA_114_DIVERGENTE';end if;
    definition:=replace(definition,patch.old_text,patch.new_text);
  end loop;
  execute definition;
end $$;
insert into public.product_catalog_revision(transaction_id,instance_started_at) values(txid_current(),pg_postmaster_start_time()) on conflict do nothing;
notify pgrst,'reload schema';
commit;
