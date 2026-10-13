begin;
set local lock_timeout='10s';
set local statement_timeout='110s';

-- Display-only fallback. Never write inferred families into the SAP catalog.
create function public.commercial_product_line(category text,metadata_line text,description text)
returns text language sql stable set search_path=public,pg_temp as $function$
  select coalesce(nullif(btrim(category),''),nullif(btrim(metadata_line),''),
    case
      when upper(unaccent(btrim(description))) ~ '^CX[. ]' then 'CAIXA'
      when upper(unaccent(btrim(description))) ~ '^SEMI[ -]+EIXO' then 'SEMIEIXO'
      else case substring(upper(unaccent(btrim(description))) from '^([A-Z]{3,})')
        when 'RAD' then 'RADIADOR' when 'RESERV' then 'RESERVATORIO'
        when 'ACAB' then 'ACABAMENTO' when 'TERM' then 'TERMINAL'
        when 'MOLD' then 'MOLDURA'
        else substring(upper(unaccent(btrim(description))) from '^([A-Z]{3,})') end
    end,'SEM LINHA');
$function$;
revoke all on function public.commercial_product_line(text,text,text) from public,anon,authenticated;

create function public.get_commercial_list_lines()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare result jsonb;
begin
  if not public.is_app_session_active() or not public.is_internal_user()
    or not(public.is_admin() or public.has_module('produtos')) then raise exception 'SEM_PERMISSAO'; end if;
  select jsonb_build_object('linhas',coalesce(jsonb_agg(line order by line),'[]'::jsonb)) into result
  from (select distinct public.commercial_product_line(p.categoria,m.line_name,p.descricao) line
    from public.products p left join public.product_catalog_metadata m on m.product_code=p.codigo
    where p.ativo) options;
  return result;
end;
$$;
revoke all on function public.get_commercial_list_lines() from public,anon;
grant execute on function public.get_commercial_list_lines() to authenticated;

-- Retain the existing authorization, revision, price engine and pagination.
do $$
declare definition text; patch record;
begin
  definition:=pg_get_functiondef('public.generate_commercial_list(text,jsonb)'::regprocedure);
  for patch in select * from (values
    ('v_revision text;','v_revision text; v_lines text[];',1),
    ('coalesce(nullif(p.categoria,''''),m.line_name)',
      'public.commercial_product_line(p.categoria,m.line_name,p.descricao)',3),
    ('and (nullif(btrim(filters->>''line''),'''') is null or public.commercial_product_line(p.categoria,m.line_name,p.descricao)=btrim(filters->>''line''))',
      'and (v_lines is null or public.commercial_product_line(p.categoria,m.line_name,p.descricao)=any(v_lines))',2),
    ('if jsonb_typeof(coalesce(filters,''{}''::jsonb))<>''object'' then raise exception ''FILTROS_INVALIDOS''; end if;',
      $validation$if jsonb_typeof(coalesce(filters,'{}'::jsonb))<>'object' then raise exception 'FILTROS_INVALIDOS'; end if;
      if filters ? 'lines' then
        if jsonb_typeof(filters->'lines') is distinct from 'array' then raise exception 'LINHAS_INVALIDAS'; end if;
        if jsonb_array_length(filters->'lines')>100 then raise exception 'EXCESSO_DE_LINHAS'; end if;
        if exists(select 1 from jsonb_array_elements(filters->'lines') item
          where jsonb_typeof(item)<>'string' or length(item #>> '{}')>120) then raise exception 'LINHAS_INVALIDAS'; end if;
        select array_agg(distinct btrim(item #>> '{}')) into v_lines
          from jsonb_array_elements(filters->'lines') item where nullif(btrim(item #>> '{}'),'') is not null;
      elsif nullif(btrim(filters->>'line'),'') is not null then
        v_lines:=array[btrim(filters->>'line')];
      end if;
      $validation$,1),
    ('(coalesce(filters,''{}''::jsonb) ? ''offset'')',
      '(coalesce(filters,''{}''::jsonb) ? ''offset'' or coalesce(filters,''{}''::jsonb) ? ''lines'')',1)
  ) as patches(old_text,new_text,expected_count)
  loop
    if (length(definition)-length(replace(definition,patch.old_text,'')))<>length(patch.old_text)*patch.expected_count then
      raise exception 'CONTRATO_FUNCAO_106_DIVERGENTE';
    end if;
    definition:=replace(definition,patch.old_text,patch.new_text);
  end loop;
  execute definition;
end;
$$;
insert into public.product_catalog_revision(transaction_id,instance_started_at)
values(txid_current(),pg_postmaster_start_time()) on conflict do nothing;
notify pgrst,'reload schema';
commit;
