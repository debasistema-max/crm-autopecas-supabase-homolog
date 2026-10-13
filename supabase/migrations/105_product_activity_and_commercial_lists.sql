begin;
set local lock_timeout = '10s';
set local statement_timeout = '110s';

-- Administrative visibility is independent of SAP registration status.
alter table public.products add column ativo boolean not null default true;
create index products_active_line_code_idx on public.products(categoria,codigo) where ativo;

create function public.guard_product_activity()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare v_changed boolean;
begin
  if tg_op='INSERT' then v_changed:=not new.ativo;
  else v_changed:=new.ativo is distinct from old.ativo;
  end if;
  if not v_changed then return new; end if;
  if not public.is_app_session_active() or not public.is_internal_user() or not public.is_admin() then
    raise exception 'SOMENTE_ADMIN_ALTERA_ATIVIDADE_PRODUTO';
  end if;
  insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_anteriores,dados_novos)
  select p.id,p.usuario,'ALTERAR_ATIVIDADE_PRODUTO','products',new.codigo,
    case when tg_op='INSERT' then null else jsonb_build_object('ativo',old.ativo) end,
    jsonb_build_object('ativo',new.ativo)
  from public.profiles p where p.id=auth.uid();
  return new;
end;
$$;
revoke all on function public.guard_product_activity() from public,anon,authenticated;
create trigger products_activity_guard before insert or update on public.products
for each row execute function public.guard_product_activity();

-- A restrictive policy cannot widen the pre-existing module/session policies.
create policy products_active_visibility on public.products as restrictive
for select to anon,authenticated using(ativo or public.is_admin());

-- One committed marker per transaction makes exports consistent without a
-- shared counter lock. Include instance startup time to support restored dumps.
create table public.product_catalog_revision(
  transaction_id bigint not null,
  instance_started_at timestamptz not null,
  primary key(transaction_id,instance_started_at)
);
alter table public.product_catalog_revision enable row level security;
revoke all on public.product_catalog_revision from public,anon,authenticated;
create function public.bump_product_catalog_revision()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  insert into public.product_catalog_revision(transaction_id,instance_started_at)
  values(txid_current(),pg_postmaster_start_time()) on conflict do nothing;
  return null;
end;
$$;
revoke all on function public.bump_product_catalog_revision() from public,anon,authenticated;
do $$ declare v_table text; begin
  foreach v_table in array array['products','product_branch_stock','product_branch_prices','product_route_prices',
    'product_catalog_metadata','fiscal_tax_rules','fiscal_tax_rule_versions','commercial_tax_policies',
    'branches','commercial_route_aliases'] loop
    execute format('create trigger catalog_revision_changed after insert or update or delete or truncate on public.%I for each statement execute function public.bump_product_catalog_revision()',v_table);
  end loop;
end; $$;

create function public.assert_active_document_products(payload jsonb)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_product record;
begin
  if not public.is_app_session_active() then raise exception 'SESSAO_SUBSTITUIDA'; end if;
  if jsonb_typeof(payload->'items') is distinct from 'array' then return; end if;
  -- The lock also prevents administrative deactivation while creating a document.
  for v_product in select p.codigo,p.ativo from public.products p
    where p.codigo=any(array(select distinct supplied.code
      from jsonb_array_elements(payload->'items') i
      cross join lateral(values(btrim(i->>'codigo')),(btrim(i->>'product_code')),
        (public.normalize_integration_product_code(i->>'codigo')),
        (public.normalize_integration_product_code(i->>'product_code'))) supplied(code)
      where supplied.code is not null))
    order by p.codigo for share
  loop
    if not v_product.ativo then raise exception 'PRODUTO_INATIVO: %',v_product.codigo; end if;
  end loop;
end;
$$;
revoke all on function public.assert_active_document_products(jsonb) from public,anon,authenticated;

create function public.set_product_active(product_code text,is_active boolean,expected_active boolean default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_code text:=btrim(product_code); v_active boolean;
begin
  if not public.is_app_session_active() or not public.is_internal_user() or not public.is_admin() then
    raise exception 'SOMENTE_ADMIN_ALTERA_ATIVIDADE_PRODUTO';
  end if;
  if nullif(v_code,'') is null or length(v_code)>80 or is_active is null then
    raise exception 'ATIVIDADE_PRODUTO_INVALIDA';
  end if;
  select p.ativo into v_active from public.products p where p.codigo=v_code for update;
  if not found then raise exception 'PRODUTO_NAO_ENCONTRADO'; end if;
  if expected_active is not null and expected_active is distinct from v_active then
    raise exception 'PRODUTO_ALTERADO_POR_OUTRO_USUARIO';
  end if;
  if v_active is distinct from is_active then
    update public.products p set ativo=is_active where p.codigo=v_code;
  end if;
  return jsonb_build_object('codigo',v_code,'ativo',is_active,'changed',v_active is distinct from is_active);
end;
$$;
revoke all on function public.set_product_active(text,boolean,boolean) from public,anon,authenticated;
grant execute on function public.set_product_active(text,boolean,boolean) to authenticated;

-- Keep existing search/price implementations and ACLs. Fail atomically if the
-- deployed function differs from the reviewed predecessor; never patch silently.
alter function public.generate_commercial_list(text,jsonb) rename to generate_commercial_list_legacy_105;
revoke all on function public.generate_commercial_list_legacy_105(text,jsonb) from public,anon,authenticated,service_role;
do $$
declare v_patch record; v_definition text; v_old text; v_new text;
begin
  for v_patch in select * from (values
    ('public.generate_commercial_list_legacy_105(text,jsonb)',
      'where (nullif(filters->>''group'','''') is null or p.grupo=filters->>''group'')',
      'where p.ativo and (nullif(filters->>''group'','''') is null or p.grupo=filters->>''group'')'),
    ('public.search_products_v2(jsonb)',
      E'from enriched e\n      where\n',
      E'from enriched e\n      where (e.ativo or (public.is_admin() and coalesce((filters->>''include_inactive'')::boolean,false))) and\n'),
    ('public.search_products_v2(jsonb)',
      '''status_cadastro'',s.status_cadastro,',
      '''ativo'',s.ativo,''status_cadastro'',s.status_cadastro,'),
    ('public.search_products(text,text,boolean,integer)',
      E'from public.products p0\n    where (',
      E'from public.products p0\n    where p0.ativo and ('),
    ('public.get_top_selling_products(integer)',
      E'join public.products p on p.codigo = oi.codigo\n  group by',
      E'join public.products p on p.codigo = oi.codigo\n  where p.ativo\n  group by'),
    ('public.b2b_search_catalog_raw_090(text,text,boolean,integer)',
      'on rp.product_code=p.codigo and rp.origin_branch_id=v_origin_id',
      'on p.ativo and rp.product_code=p.codigo and rp.origin_branch_id=v_origin_id'),
    ('public.b2b_get_catalog_product_detail(text)',
      'v_raw:=public.b2b_get_catalog_product_detail_raw_090(p_product_code);',
      'if not exists(select 1 from public.products p where p.codigo=public.normalize_integration_product_code(p_product_code) and p.ativo) then raise exception ''PRODUTO_INATIVO_OU_INEXISTENTE''; end if; v_raw:=public.b2b_get_catalog_product_detail_raw_090(p_product_code);'),
    ('public.commercial_create_document(text,jsonb)',
      'v_result:=public.commercial_create_document_raw_090(document_type,payload);',
      'perform public.assert_active_document_products(payload); v_result:=public.commercial_create_document_raw_090(document_type,payload);'),
    ('public.b2b_create_document(text,jsonb)',
      'v_result:=public.b2b_create_document_raw_090(document_type,payload);',
      'perform public.assert_active_document_products(payload); v_result:=public.b2b_create_document_raw_090(document_type,payload);'),
    ('public.commercial_update_document_items_raw_090(text,jsonb)',
      'if document_type=''pedido'' then delete from public.order_items where order_id=target_id; else delete from public.quotation_items where quotation_id=target_id; end if;',
      'perform public.assert_active_document_products(jsonb_build_object(''items'',(select coalesce(jsonb_agg(i),''[]''::jsonb) from jsonb_array_elements(payload->''items'') i where not exists(select 1 from public.order_items oi where document_type=''pedido'' and oi.order_id=target_id and oi.codigo=btrim(i->>''codigo'') union all select 1 from public.quotation_items qi where document_type=''cotacao'' and qi.quotation_id=target_id and qi.codigo=btrim(i->>''codigo''))))); if document_type=''pedido'' then delete from public.order_items where order_id=target_id; else delete from public.quotation_items where quotation_id=target_id; end if;'),
    ('public.convert_quotation_to_order_internal_087(uuid)',
      'if source.status<>''APROVADA'' then raise exception ''COTACAO_NAO_APROVADA''; end if;',
      'if source.status<>''APROVADA'' then raise exception ''COTACAO_NAO_APROVADA''; end if; perform public.assert_active_document_products(jsonb_build_object(''items'',(select coalesce(jsonb_agg(jsonb_build_object(''codigo'',qi.codigo)),''[]''::jsonb) from public.quotation_items qi where qi.quotation_id=source.id)));')
  ) as patches(signature,old_text,new_text)
  loop
    v_definition:=pg_get_functiondef(to_regprocedure(v_patch.signature));
    v_old:=v_patch.old_text; v_new:=v_patch.new_text;
    -- Historical Windows deployments retain CRLF in this function body.
    -- Match only whitespace at the reviewed JOIN/GROUP BY boundary.
    if v_patch.signature='public.get_top_selling_products(integer)' then
      v_old:=substring(v_definition from 'join public[.]products p on p[.]codigo = oi[.]codigo[[:space:]]+group by');
      v_new:=regexp_replace(v_old,'[[:space:]]+group by$',E'\n  where p.ativo\n  group by');
    end if;
    if v_definition is null or v_old is null or (length(v_definition)-length(replace(v_definition,v_old,'')))<>length(v_old) then
      raise exception 'CONTRATO_FUNCAO_105_DIVERGENTE: %',v_patch.signature;
    end if;
    execute replace(v_definition,v_old,v_new);
  end loop;
end;
$$;

create or replace function public.get_product_filters()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_result jsonb;
begin
  if not public.is_app_session_active() or not public.is_internal_user()
    or not (public.is_admin() or public.has_module('produtos') or public.has_module('novo_pedido')
      or public.has_module('nova_cotacao') or public.has_module('alimentacao')) then
    raise exception 'SEM_PERMISSAO';
  end if;
  select jsonb_build_object(
    'linhas',coalesce(jsonb_agg(distinct line order by line) filter(where line is not null),'[]'::jsonb),
    'grupos',coalesce(jsonb_agg(distinct product_group order by product_group) filter(where product_group is not null),'[]'::jsonb),
    'marcas',coalesce(jsonb_agg(distinct brand order by brand) filter(where brand is not null),'[]'::jsonb),
    'montadoras',coalesce(jsonb_agg(distinct maker order by maker) filter(where maker is not null),'[]'::jsonb)
  ) into v_result from (
    select nullif(btrim(coalesce(nullif(p.categoria,''),m.line_name)),'') as line,
      nullif(btrim(p.grupo),'') as product_group,nullif(btrim(p.marca),'') as brand,
      nullif(btrim(p.montadora),'') as maker
    from public.products p left join public.product_catalog_metadata m on m.product_code=p.codigo
    where p.ativo
  ) options;
  return v_result;
end;
$$;
revoke all on function public.get_product_filters() from public,anon;
grant execute on function public.get_product_filters() to authenticated;

create or replace function public.generate_commercial_list(route text,filters jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare
  v_route text:=upper(replace(btrim(route),'→','-'));
  v_origin text:=split_part(v_route,'-',1); v_destination text:=split_part(v_route,'-',2);
  v_limit integer:=least(greatest(coalesce((filters->>'limit')::integer,200),1),500);
  v_offset integer:=greatest(coalesce((filters->>'offset')::integer,0),0);
  v_rows jsonb; v_count bigint;
  v_revision text;
begin
  if not public.is_app_session_active() or not public.is_internal_user()
    or not (public.is_admin() or public.has_module('produtos')) then
    raise exception 'SEM_PERMISSAO';
  end if;
  if jsonb_typeof(coalesce(filters,'{}'::jsonb))<>'object' then raise exception 'FILTROS_INVALIDOS'; end if;
  if v_origin not in ('PR','SP') or public.normalize_fiscal_uf(v_destination) is null
    or v_route<>v_origin||'-'||v_destination then raise exception 'ROTA_INVALIDA'; end if;
  -- Open sessions using the old frontend must not receive a truncated page.
  if not (coalesce(filters,'{}'::jsonb) ? 'offset') then
    return public.generate_commercial_list_legacy_105(route,filters);
  end if;
  select count(*)::text||':'||public.commercial_business_date()::text into v_revision from public.product_catalog_revision;
  if filters ? 'expected_revision' and filters->>'expected_revision' is distinct from v_revision then
    raise exception 'CATALOGO_ALTERADO_DURANTE_GERACAO';
  end if;
  if coalesce((filters->>'only_valid_price')::boolean,false) or coalesce((filters->>'only_available')::boolean,false) then
    select count(*) into v_count from public.products p
    left join public.product_catalog_metadata m on m.product_code=p.codigo
    where p.ativo
      and (nullif(btrim(filters->>'group'),'') is null or p.grupo=btrim(filters->>'group'))
      and (nullif(btrim(filters->>'brand'),'') is null or p.marca=btrim(filters->>'brand'))
      and (nullif(btrim(filters->>'line'),'') is null or coalesce(nullif(p.categoria,''),m.line_name)=btrim(filters->>'line'));
    if v_count>500 then raise exception 'FILTROS_CALCULADOS_EXCEDEM_LIMITE: selecione linha, grupo ou marca'; end if;
  end if;
  with eligible as materialized (
    select p.codigo,p.grupo,coalesce(nullif(p.categoria,''),m.line_name) as line
    from public.products p left join public.product_catalog_metadata m on m.product_code=p.codigo
    where p.ativo
      and (nullif(btrim(filters->>'group'),'') is null or p.grupo=btrim(filters->>'group'))
      and (nullif(btrim(filters->>'brand'),'') is null or p.marca=btrim(filters->>'brand'))
      and (nullif(btrim(filters->>'line'),'') is null or coalesce(nullif(p.categoria,''),m.line_name)=btrim(filters->>'line'))
  ), priced as materialized (
    select e.codigo,e.line,e.grupo,case when coalesce((filters->>'only_valid_price')::boolean,false)
      or coalesce((filters->>'only_available')::boolean,false)
      then public.get_product_commercial_price(e.codigo,v_origin,v_destination) else null end as row_data
    from eligible e
  ), filtered as (
    select codigo,line,grupo,row_data from priced
    where (not coalesce((filters->>'only_valid_price')::boolean,false) or upper(row_data->>'status') like 'OK%')
      and (not coalesce((filters->>'only_available')::boolean,false) or row_data->>'availability'<>'INDISPONIVEL')
  ), page as (select codigo,line,grupo,row_data from filtered order by codigo offset v_offset limit v_limit)
  select (select count(*) from filtered),
    coalesce((select jsonb_agg(coalesce(row_data,public.get_product_commercial_price(codigo,v_origin,v_destination))
      ||jsonb_build_object('line',line,'group',grupo) order by codigo) from page),'[]'::jsonb)
  into v_count,v_rows;
  return jsonb_build_object('route',v_route,'rows',v_rows,'count',v_count,'catalog_revision',v_revision,'offset',v_offset,'limit',v_limit,
    'has_more',v_offset+jsonb_array_length(v_rows)<v_count,'next_offset',v_offset+jsonb_array_length(v_rows));
end;
$$;
revoke all on function public.generate_commercial_list(text,jsonb) from public,anon;
grant execute on function public.generate_commercial_list(text,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
