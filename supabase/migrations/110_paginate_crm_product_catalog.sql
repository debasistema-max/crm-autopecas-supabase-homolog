begin;
set local lock_timeout='10s';
set local statement_timeout='110s';

-- Keep the existing search contract and all later patches intact. Only add a
-- bounded offset so the CRM can display the complete catalog page by page.
do $$
declare definition text;
begin
  definition:=pg_get_functiondef('public.search_products_v2(jsonb)'::regprocedure);

  if (length(definition)-length(replace(definition,
    'v_limit integer := least(greatest(coalesce((filters->>''limit'')::integer,60),1),500);','')))
      <>length('v_limit integer := least(greatest(coalesce((filters->>''limit'')::integer,60),1),500);') then
    raise exception 'CONTRATO_BUSCA_110_LIMITE_DIVERGENTE';
  end if;
  definition:=replace(definition,
    'v_limit integer := least(greatest(coalesce((filters->>''limit'')::integer,60),1),500);',
    'v_limit integer := least(greatest(coalesce((filters->>''limit'')::integer,60),1),500); v_offset integer := least(greatest(coalesce((filters->>''offset'')::integer,0),0),50000);');

  if (length(definition)-length(replace(definition,E'limit v_limit\n','')))<>length(E'limit v_limit\n') then
    raise exception 'CONTRATO_BUSCA_110_PAGINACAO_DIVERGENTE';
  end if;
  definition:=replace(definition,E'limit v_limit\n',E'limit v_limit\n      offset v_offset\n');
  execute definition;
end;
$$;

notify pgrst,'reload schema';
commit;
