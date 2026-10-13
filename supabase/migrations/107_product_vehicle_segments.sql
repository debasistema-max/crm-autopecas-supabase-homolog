begin;
set local lock_timeout='10s';
set local statement_timeout='110s';

-- Commercial segments inferred only from stated applications, not manufacturer,
-- part description, fuel or an assumed legal gross vehicle weight.
create function public.product_vehicle_types(application text)
returns text[] language plpgsql stable set search_path=public,pg_temp as $$
declare value text:=btrim(regexp_replace(upper(unaccent(coalesce(application,''))),'[^A-Z0-9]+',' ','g'));
  passenger_value text; result text[]:='{}';
begin
  passenger_value:=regexp_replace(value,E'\\m(COROLLA CROSS|CROSS ?FOX|C[34] AIRCROSS|C4 CACTUS)\\M',' ','g');
  if passenger_value ~ '(^| )(ASTRA|CORSA|VECTRA|COROLLA|YARIS|CIVIC|FIT|CITY|SENTRA|VERSA|MARCH|TIIDA|FIESTA|FOCUS|KA|ESCORT|FUSION|GOL|GOLF|POLO|FOX|JETTA|PASSAT|PALIO|UNO|PUNTO|SIENA|MOBI|ARGO|CRONOS|LOGAN|SANDERO|CLIO|MEGANE|FLUENCE|KWID|HB20|I30|ELANTRA|CERATO|PICANTO|C3|C4)( |$)' then result:=array_append(result,'LEVE'); end if;
  if value ~ '(^| )(HILUX|SW4|RANGER|FRONTIER|TRITON|L200|AMAROK|S ?10|STRADA|TORO|FIORINO|SAVEIRO|MONTANA|DUSTER|OROCH|SPRINTER|TRANSIT|DUCATO|MASTER|KANGOO|DOBLO|KOMBI|BONGO|HR|H100|PAJERO|RAV ?4|CR ?V|HR ?V|TRACKER|ECOSPORT|KICKS|CAPTUR|CRETA|TUCSON|SPORTAGE|VITARA|COMPASS|RENEGADE|COROLLA CROSS|CROSS ?FOX|C[34] AIRCROSS|C4 CACTUS|T CROSS|TIGUAN|TAOS|TERRITORY)( |$)' then result:=array_append(result,'UTILITARIO'); end if;
  if value ~ '(^| )(CAMINHAO|CAMINHOES|ONIBUS|ATEGO|ACCELO|ACTROS|AXOR|AROCS|CONSTELLATION|DELIVERY|VOLVO (FH|FM|FMX|VM))( |$)' then result:=array_append(result,'PESADO'); end if;
  return case when cardinality(result)=0 then array['NAO_CLASSIFICADO'] else result end;
end;
$$;
revoke all on function public.product_vehicle_types(text) from public,anon,authenticated;

do $$
declare definition text; patch record;
begin
  definition:=pg_get_functiondef('public.search_products_v2(jsonb)'::regprocedure);
  for patch in select * from (values
    ('coalesce(nullif(p.aplicacao,''''),nullif(m.applications,'''')) as current_application',
      'coalesce(nullif(btrim(p.aplicacao),''''),nullif(btrim(m.applications),'''')) as current_application'),
    ('and (v_line='''' or e.current_line=v_line or e.categoria=v_line)',
      'and (v_line='''' or e.current_line=v_line or e.categoria=v_line) and (nullif(upper(btrim(filters->>''vehicle_type'')),'''') is null or upper(btrim(filters->>''vehicle_type''))=any(public.product_vehicle_types(e.current_application)))'),
    ('''codigo'',s.codigo,','''codigo'',s.codigo,''vehicle_types'',public.product_vehicle_types(s.current_application),'),
    ('v_term := btrim(regexp_replace(v_term,''[[:space:]]+'','' '',''g''));',
      'if nullif(upper(btrim(filters->>''vehicle_type'')),'''') is not null and upper(btrim(filters->>''vehicle_type'')) not in (''LEVE'',''UTILITARIO'',''PESADO'',''NAO_CLASSIFICADO'') then raise exception ''TIPO_VEICULO_INVALIDO''; end if; v_term := btrim(regexp_replace(v_term,''[[:space:]]+'','' '',''g''));')
  ) patches(old_text,new_text) loop
    if (length(definition)-length(replace(definition,patch.old_text,'')))<>length(patch.old_text) then raise exception 'CONTRATO_BUSCA_107_DIVERGENTE'; end if;
    definition:=replace(definition,patch.old_text,patch.new_text);
  end loop;
  execute definition;

  definition:=pg_get_functiondef('public.generate_commercial_list(text,jsonb)'::regprocedure);
  for patch in select * from (values
    ('v_revision text; v_lines text[];', 'v_revision text; v_lines text[]; v_vehicle_type text:=nullif(upper(btrim(filters->>''vehicle_type'')),'''');',1),
    ('where p.ativo','where p.ativo and (v_vehicle_type is null or v_vehicle_type=any(public.product_vehicle_types(coalesce(nullif(btrim(p.aplicacao),''''),m.applications))))',2),
    ('public.commercial_product_line(p.categoria,m.line_name,p.descricao) as line',
      'public.commercial_product_line(p.categoria,m.line_name,p.descricao) as line,public.product_vehicle_types(coalesce(nullif(btrim(p.aplicacao),''''),m.applications)) as vehicle_types',1),
    ('select e.codigo,e.line,e.grupo,','select e.codigo,e.line,e.grupo,e.vehicle_types,',1),
    ('select codigo,line,grupo,row_data from priced','select codigo,line,grupo,vehicle_types,row_data from priced',1),
    ('select codigo,line,grupo,row_data from filtered','select codigo,line,grupo,vehicle_types,row_data from filtered',1),
    ('jsonb_build_object(''line'',line,''group'',grupo)','jsonb_build_object(''line'',line,''group'',grupo,''vehicle_types'',vehicle_types)',1),
    ('if jsonb_typeof(coalesce(filters,''{}''::jsonb))<>''object'' then raise exception ''FILTROS_INVALIDOS''; end if;',
      'if jsonb_typeof(coalesce(filters,''{}''::jsonb))<>''object'' then raise exception ''FILTROS_INVALIDOS''; end if; if v_vehicle_type is not null and v_vehicle_type not in (''LEVE'',''UTILITARIO'',''PESADO'',''NAO_CLASSIFICADO'') then raise exception ''TIPO_VEICULO_INVALIDO''; end if;',1),
    ('(coalesce(filters,''{}''::jsonb) ? ''offset'' or coalesce(filters,''{}''::jsonb) ? ''lines'')',
      '(coalesce(filters,''{}''::jsonb) ? ''offset'' or coalesce(filters,''{}''::jsonb) ? ''lines'' or coalesce(filters,''{}''::jsonb) ? ''vehicle_type'')',1)
  ) patches(old_text,new_text,expected_count) loop
    if (length(definition)-length(replace(definition,patch.old_text,'')))<>length(patch.old_text)*patch.expected_count then raise exception 'CONTRATO_LISTA_107_DIVERGENTE'; end if;
    definition:=replace(definition,patch.old_text,patch.new_text);
  end loop;
  execute definition;
end;
$$;

-- Invalidate exports already paging while classification rules change.
insert into public.product_catalog_revision(transaction_id,instance_started_at)
values(txid_current(),pg_postmaster_start_time()) on conflict do nothing;
notify pgrst,'reload schema';
commit;
