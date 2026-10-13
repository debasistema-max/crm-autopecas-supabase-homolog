begin;
set local lock_timeout = '10s';
set local statement_timeout = '110s';

-- Fictitious identities/products only; all changes disappear at ROLLBACK.
create temporary table reg105_context on commit drop as
select gen_random_uuid() admin_id,gen_random_uuid() reader_id,gen_random_uuid() b2b_id,
  gen_random_uuid() admin_sid,gen_random_uuid() reader_sid,gen_random_uuid() b2b_sid,
  gen_random_uuid() client_id,gen_random_uuid() batch_id,gen_random_uuid() order_id,
  gen_random_uuid() quotation_id,gen_random_uuid() replay_quotation_id,gen_random_uuid() editable_quotation_id,
  '9105'||lpad(floor(random()*10000000000)::bigint::text,10,'0') prefix,
  'REG105-'||gen_random_uuid()::text fixture_group,
  'REG105-LINE-A-'||gen_random_uuid()::text line_a,
  'REG105-LINE-B-'||gen_random_uuid()::text line_b,
  (select count(*) from public.product_catalog_revision) initial_revision;
grant select on reg105_context to authenticated;

-- Instrument the real price function inside this rollback-only transaction.
create temporary sequence reg105_price_calls;
grant usage,select on sequence reg105_price_calls to authenticated,postgres;
do $$
declare v_definition text;
begin
  v_definition:=pg_get_functiondef('public.get_product_commercial_price(text,text,text,date,text)'::regprocedure);
  if (length(v_definition)-length(replace(v_definition,E'\nbegin\n','')))<>length(E'\nbegin\n') then
    raise exception 'REG105_PRICE_INSTRUMENTATION_CONTRACT';
  end if;
  execute replace(v_definition,E'\nbegin\n',E'\nbegin\n  perform pg_catalog.nextval(''pg_temp.reg105_price_calls'');\n');
end;
$$;

do $$
declare c record; v_pr uuid;
begin
  select * into c from reg105_context;
  if exists(select 1 from public.products where codigo like c.prefix||'%') then
    raise exception 'REG105_FIXTURE_PREFIX_COLLISION';
  end if;
  insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data)
  values(c.admin_id,'authenticated','authenticated','reg105-admin-'||c.admin_id||'@example.invalid','{}','{}'),
    (c.reader_id,'authenticated','authenticated','reg105-reader-'||c.reader_id||'@example.invalid','{}','{}'),
    (c.b2b_id,'authenticated','authenticated','reg105-b2b-'||c.b2b_id||'@example.invalid','{}','{}');
  insert into public.profiles(id,usuario,nome,email,perfil,ativo)
  values(c.admin_id,'reg105-admin-'||c.admin_id,'REG105 ADMIN ficticio','reg105-admin-'||c.admin_id||'@example.invalid','ADMIN',true),
    (c.reader_id,'reg105-reader-'||c.reader_id,'REG105 leitor ficticio','reg105-reader-'||c.reader_id||'@example.invalid','SUPERVISOR',true);
  insert into public.role_permissions(perfil,modulo,permitido)
  values('SUPERVISOR','produtos',true),('SUPERVISOR','alimentacao',true)
  on conflict(perfil,modulo) do update set permitido=true;
  insert into public.clients(id,nome,estado,ativo)
  values(c.client_id,'REG105 cliente ficticio','PR',true);
  insert into public.customer_portal_accounts(user_id,client_id,email,active,can_view_prices,can_view_stock,
    login_mode,username,must_change_password,activation_pending)
  values(c.b2b_id,c.client_id,'reg105-b2b-'||c.b2b_id||'@example.invalid',true,true,true,'EMAIL',null,false,false);
  insert into auth.sessions(id,user_id,created_at,updated_at,not_after)
  values(c.admin_sid,c.admin_id,now()-interval '2 minutes',now(),now()+interval '1 hour'),
    (c.reader_sid,c.reader_id,now()-interval '2 minutes',now(),now()+interval '1 hour'),
    (c.b2b_sid,c.b2b_id,now()-interval '2 minutes',now(),now()+interval '1 hour');
  insert into public.app_sessions(user_id,active_session_id,auth_created_at)
  values(c.admin_id,c.admin_sid,now()-interval '2 minutes'),
    (c.reader_id,c.reader_sid,now()-interval '2 minutes'),
    (c.b2b_id,c.b2b_sid,now()-interval '2 minutes');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',c.admin_id,'role','authenticated','session_id',c.admin_sid)::text,true);
  if not public.is_app_session_active() or not public.is_admin() then raise exception 'REG105_ADMIN_SESSION_INVALID'; end if;
  insert into public.products(codigo,descricao,categoria,grupo,status_cadastro)
  select c.prefix||lpad(n::text,3,'0'),c.prefix||'000 REG105 produto ficticio '||n,
    case when n<=203 then c.line_a else c.line_b end,c.fixture_group,'ATIVO'
  from generate_series(0,205) n;
  if exists(select 1 from public.products where grupo=c.fixture_group and not ativo) then
    raise exception 'REG105_DEFAULT_NOT_ACTIVE';
  end if;
  select id into v_pr from public.branches where code='PR' and active;
  if v_pr is null then raise exception 'REG105_PR_BRANCH_REQUIRED'; end if;
  insert into public.products_import_batches(id,created_by,import_type,source_name,status)
  values(c.batch_id,'REG105','CATALOGO','REG105 fictitious import','committed');
  insert into public.product_route_prices(product_code,origin_branch_id,destination_state,route,
    base_price,final_price,total_taxes,calculation_status,currency,source,source_version,
    source_updated_at,source_batch_id,updated_by)
  select codigo,v_pr,'PR','PR-PR',100,100,0,'OK','BRL','IMPORT_MANUAL','REG105',now(),c.batch_id,c.admin_id
  from public.products where grupo=c.fixture_group;
  insert into public.product_branch_prices(product_code,branch_id,sale_price,source,valid_from)
  select codigo,v_pr,100,'MANUAL',current_date from public.products where grupo=c.fixture_group
  on conflict(product_code,branch_id) do update set sale_price=excluded.sale_price,source=excluded.source,valid_from=excluded.valid_from;
  insert into public.product_branch_stock(product_code,branch_id,physical_qty,sap_general_available_qty,version)
  select codigo,v_pr,10000000,10000000,1 from public.products where grupo=c.fixture_group
  on conflict(product_code,branch_id) do update set physical_qty=excluded.physical_qty,
    sap_general_available_qty=excluded.sap_general_available_qty,version=excluded.version;
  insert into public.orders(id,cliente,user_id,status)
  values(c.order_id,'REG105 cliente ficticio',c.admin_id,'NOVO');
  insert into public.order_items(order_id,item,codigo,quantidade,preco_unitario,preco_final_unitario,total_item)
  values(c.order_id,1,c.prefix||'000',1000000,1,1,1000000),
    (c.order_id,2,c.prefix||'001',1000000,1,1,1000000);
  insert into public.quotations(id,cliente,client_id,user_id,regiao,status)
  values(c.quotation_id,'REG105 cliente ficticio',c.client_id,c.admin_id,'PR','APROVADA'),
    (c.replay_quotation_id,'REG105 cliente ficticio',c.client_id,c.admin_id,'PR','CONVERTIDA'),
    (c.editable_quotation_id,'REG105 cliente ficticio',c.client_id,c.admin_id,'PR','NOVA');
  insert into public.quotation_items(quotation_id,item,codigo,quantidade,preco_unitario,preco_final_unitario,total_item)
  values(c.quotation_id,1,c.prefix||'000',1,1,1,1),
    (c.replay_quotation_id,1,c.prefix||'000',1,1,1,1),
    (c.editable_quotation_id,1,c.prefix||'000',1,100,100,100);
  insert into public.quotation_order_conversions(quotation_id,order_id,converted_by)
  values(c.replay_quotation_id,c.order_id,c.admin_id);
end;
$$;

set local role authenticated;
do $$
declare c record; v_result jsonb; v_audits integer; v_denied boolean; v_revision text; v_calls bigint; v_payload jsonb;
  v_document_before jsonb; v_items_before jsonb; v_logs_before bigint;
begin
  select * into c from reg105_context;
  v_result:=public.set_product_active(c.prefix||'000',false,true);
  if v_result->>'ativo'<>'false' or v_result->>'changed'<>'true' then raise exception 'REG105_ADMIN_DEACTIVATE_FAILED'; end if;
  select count(*) into v_audits from public.logs where acao='ALTERAR_ATIVIDADE_PRODUTO' and id_entidade=c.prefix||'000';
  if v_audits<>1 or not exists(select 1 from public.logs where acao='ALTERAR_ATIVIDADE_PRODUTO'
    and id_entidade=c.prefix||'000' and user_id=c.admin_id
    and dados_anteriores->>'ativo'='true' and dados_novos->>'ativo'='false') then
    raise exception 'REG105_ACTIVITY_AUDIT_FAILED';
  end if;
  v_result:=public.set_product_active(c.prefix||'000',false,false);
  if v_result->>'changed'<>'false' then raise exception 'REG105_IDEMPOTENCY_FAILED'; end if;
  if (select count(*) from public.logs where acao='ALTERAR_ATIVIDADE_PRODUTO' and id_entidade=c.prefix||'000')<>v_audits then
    raise exception 'REG105_IDEMPOTENCY_DUPLICATED_AUDIT';
  end if;
  v_denied:=false;
  begin
    perform public.set_product_active(c.prefix||'000',true,true);
  exception when others then
    if sqlerrm='PRODUTO_ALTERADO_POR_OUTRO_USUARIO' then v_denied:=true; else raise; end if;
  end;
  if not v_denied then raise exception 'REG105_STALE_EXPECTED_ALLOWED'; end if;
  v_result:=public.set_product_active(c.prefix||'000',true,false);
  if v_result->>'ativo'<>'true' or v_result->>'changed'<>'true' then raise exception 'REG105_REACTIVATE_FAILED'; end if;
  perform public.set_product_active(c.prefix||'000',false,true);
  if (select count(*) from public.products where grupo=c.fixture_group)<>206 then raise exception 'REG105_ADMIN_VISIBILITY_FAILED'; end if;
  if not exists(select 1 from public.order_items where order_id=c.order_id and codigo=c.prefix||'000') then
    raise exception 'REG105_DEACTIVATION_DELETED_DOCUMENT_ITEM';
  end if;
  v_denied:=false;
  begin
    perform public.commercial_create_document('pedido',jsonb_build_object('items',jsonb_build_array(
      jsonb_build_object('codigo',c.prefix||'000','quantidade',1))));
  exception when others then
    if sqlerrm like 'PRODUTO_INATIVO:%' then v_denied:=true; else raise; end if;
  end;
  if not v_denied then raise exception 'REG105_NEW_CRM_DOCUMENT_INACTIVE_ALLOWED'; end if;
  for v_payload in select jsonb_build_object('items',jsonb_build_array(item)) from (values
    (jsonb_build_object('codigo',' '||c.prefix||'000 ')),
    (jsonb_build_object('codigo',c.prefix||'001','product_code',c.prefix||'000')),
    (jsonb_build_object('codigo',c.prefix||'000','product_code',c.prefix||'001'))
  ) variants(item) loop
    v_denied:=false;
    begin perform public.commercial_create_document('pedido',v_payload);
    exception when others then if sqlerrm like 'PRODUTO_INATIVO:%' then v_denied:=true; else raise; end if; end;
    if not v_denied then raise exception 'REG105_CRM_TRIM_OR_DUAL_CODE_BYPASS'; end if;
  end loop;
  v_denied:=false;
  begin perform public.convert_quotation_to_order(c.quotation_id);
  exception when others then if sqlerrm like 'PRODUTO_INATIVO:%' then v_denied:=true; else raise; end if; end;
  if not v_denied then raise exception 'REG105_NEW_CONVERSION_INACTIVE_ALLOWED'; end if;
  v_result:=public.commercial_update_quotation_items(jsonb_build_object('id',c.editable_quotation_id,
    'items',jsonb_build_array(jsonb_build_object('codigo',c.prefix||'000','quantidade',2,'desconto_percentual',0))));
  if v_result->>'id'<>c.editable_quotation_id::text or not exists(select 1 from public.quotation_items
    where quotation_id=c.editable_quotation_id and codigo=c.prefix||'000' and quantidade=2
      and preco_unitario>0 and coalesce(fiscal_status,'') in ('OK','OK_SEM_ST')) then
    raise exception 'REG105_HISTORICAL_QUOTATION_RPC_EDIT_FAILED';
  end if;
  if (select ativo from public.products where codigo=c.prefix||'000') then
    raise exception 'REG105_HISTORICAL_RPC_REACTIVATED_PRODUCT';
  end if;
  perform public.set_product_active(c.prefix||'001',false,true);
  select to_jsonb(q) into v_document_before from public.quotations q where id=c.editable_quotation_id;
  select jsonb_agg(to_jsonb(i) order by i.id) into v_items_before
    from public.quotation_items i where quotation_id=c.editable_quotation_id;
  select count(*) into v_logs_before from public.logs where user_id=c.admin_id;
  v_denied:=false;
  begin
    perform public.commercial_update_quotation_items(jsonb_build_object('id',c.editable_quotation_id,
      'items',jsonb_build_array(
        jsonb_build_object('codigo',c.prefix||'000','quantidade',3,'desconto_percentual',0),
        jsonb_build_object('codigo',c.prefix||'001','quantidade',1,'desconto_percentual',0))));
  exception when others then
    if sqlerrm like 'PRODUTO_INATIVO:%' then v_denied:=true; else raise; end if;
  end;
  if not v_denied then raise exception 'REG105_NEW_INACTIVE_ADDITION_ALLOWED'; end if;
  if (select to_jsonb(q) from public.quotations q where id=c.editable_quotation_id) is distinct from v_document_before
    or (select jsonb_agg(to_jsonb(i) order by i.id) from public.quotation_items i
      where quotation_id=c.editable_quotation_id) is distinct from v_items_before
    or (select count(*) from public.logs where user_id=c.admin_id)<>v_logs_before then
    raise exception 'REG105_REJECTED_INACTIVE_ADDITION_CHANGED_DOCUMENT';
  end if;
  perform public.set_product_active(c.prefix||'001',true,false);
  if not exists(select 1 from public.quotation_items where quotation_id=c.replay_quotation_id and codigo=c.prefix||'000') then
    raise exception 'REG105_HISTORICAL_QUOTATION_ITEM_LOST';
  end if;
  if exists(select 1 from public.get_top_selling_products(50) where codigo=c.prefix||'000')
    or not exists(select 1 from public.get_top_selling_products(50) where codigo=c.prefix||'001') then
    raise exception 'REG105_TOP_SELLING_ACTIVITY_FILTER_FAILED';
  end if;
  if exists(select 1 from public.search_products(c.prefix,'PR',false,10) where codigo=c.prefix||'000')
    or (select count(*) from public.search_products(c.prefix,'PR',false,10))<>10 then
    raise exception 'REG105_LEGACY_SEARCH_ACTIVITY_FILTER_FAILED';
  end if;
  v_result:=public.search_products_v2(jsonb_build_object('term',c.prefix||'000','group',c.fixture_group,'limit',1));
  if jsonb_array_length(v_result)<>1 or v_result->0->>'codigo'=c.prefix||'000' then
    raise exception 'REG105_SEARCH_FILTER_AFTER_LIMIT';
  end if;
  v_result:=public.search_products_v2(jsonb_build_object('term',c.prefix||'000','group',c.fixture_group,'limit',1,'include_inactive',true));
  if jsonb_array_length(v_result)<>1 or v_result->0->>'codigo'<>c.prefix||'000' or v_result->0->>'ativo'<>'false' then
    raise exception 'REG105_ADMIN_INCLUDE_INACTIVE_FAILED';
  end if;
  select case when is_called then last_value else 0 end into v_calls from reg105_price_calls;
  v_result:=public.generate_commercial_list('PR-PR',jsonb_build_object('group',c.fixture_group,'offset',0,'limit',2));
  if (select last_value from reg105_price_calls)-v_calls<>2 then raise exception 'REG105_DEFAULT_PRICED_OUTSIDE_PAGE'; end if;
  v_result:=public.generate_commercial_list('PR-PR',jsonb_build_object('group',c.fixture_group));
  if jsonb_array_length(v_result->'rows')<>205
    or exists(select 1 from jsonb_array_elements(v_result->'rows') item where item->>'product_code'=c.prefix||'000') then
    raise exception 'REG105_LEGACY_UNPAGED_COMPATIBILITY_FAILED';
  end if;
  if has_function_privilege('authenticated','public.generate_commercial_list_legacy_105(text,jsonb)','execute')
    or has_function_privilege('anon','public.generate_commercial_list_legacy_105(text,jsonb)','execute') then
    raise exception 'REG105_PRIVATE_LEGACY_EXECUTE_EXPOSED';
  end if;
  v_result:=public.generate_commercial_list('PR-PR',jsonb_build_object('group',c.fixture_group,'offset',0));
  v_revision:=v_result->>'catalog_revision';
  if v_revision !~ '^[0-9]+:[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'REG105_SNAPSHOT_VERSION_MISSING'; end if;
  if split_part(v_revision,':',2)<>public.commercial_business_date()::text then raise exception 'REG105_SNAPSHOT_BUSINESS_DATE_MISMATCH'; end if;
  if (v_result->>'count')::integer<>205 or (v_result->>'limit')::integer<>200
    or jsonb_array_length(v_result->'rows')<>200 or v_result->>'has_more'<>'true'
    or (v_result->>'next_offset')::integer<>200 then raise exception 'REG105_GENERAL_LIST_PAGE_FAILED'; end if;
  if exists(select 1 from jsonb_array_elements(v_result->'rows') item where item->>'product_code'=c.prefix||'000') then
    raise exception 'REG105_GENERAL_LIST_INACTIVE_LEAK';
  end if;
  v_result:=public.generate_commercial_list('PR-PR',jsonb_build_object('group',c.fixture_group,'offset',200,'expected_revision',v_revision));
  if (v_result->>'count')::integer<>205 or jsonb_array_length(v_result->'rows')<>5
    or v_result->>'has_more'<>'false' or (v_result->>'next_offset')::integer<>205 then
    raise exception 'REG105_GENERAL_LIST_LAST_PAGE_FAILED';
  end if;
  v_result:=public.generate_commercial_list('PR-PR',jsonb_build_object('group',c.fixture_group,'offset',0,'line',c.line_a,'limit',2));
  if (v_result->>'count')::integer<>203 or jsonb_array_length(v_result->'rows')<>2 or v_result->>'has_more'<>'true'
    or exists(select 1 from jsonb_array_elements(v_result->'rows') item where item->>'line'<>c.line_a) then
    raise exception 'REG105_LINE_LIST_PAGE_FAILED';
  end if;
  v_result:=public.generate_commercial_list('PR-PR',jsonb_build_object('group',c.fixture_group,'offset',0,'line',c.line_b));
  if (v_result->>'count')::integer<>2 or jsonb_array_length(v_result->'rows')<>2 or v_result->>'has_more'<>'false' then
    raise exception 'REG105_SECOND_LINE_FILTER_FAILED';
  end if;
  v_denied:=false;
  begin
    perform public.generate_commercial_list('PR-PR',jsonb_build_object('group',c.fixture_group,'offset',0,'expected_revision','stale:2000-01-01'));
  exception when others then
    if sqlerrm='CATALOGO_ALTERADO_DURANTE_GERACAO' then v_denied:=true; else raise; end if;
  end;
  if not v_denied then raise exception 'REG105_STALE_SNAPSHOT_ALLOWED'; end if;
  insert into public.products(codigo,descricao,grupo,categoria)
  select c.prefix||lpad(n::text,3,'0'),'REG105 caro ficticio',c.fixture_group,c.line_b from generate_series(206,506) n;
  v_denied:=false;
  begin
    perform public.generate_commercial_list('PR-PR',jsonb_build_object('group',c.fixture_group,'offset',0,'only_valid_price',true));
  exception when others then
    if sqlerrm like 'FILTROS_CALCULADOS_EXCEDEM_LIMITE:%' then v_denied:=true; else raise; end if;
  end;
  if not v_denied then raise exception 'REG105_EXPENSIVE_FILTER_CAP_MISSING'; end if;
  v_denied:=false;
  begin
    perform public.generate_commercial_list('PR-PR',jsonb_build_object('group',c.fixture_group,'offset',0,'only_available',true));
  exception when others then
    if sqlerrm like 'FILTROS_CALCULADOS_EXCEDEM_LIMITE:%' then v_denied:=true; else raise; end if;
  end;
  if not v_denied then raise exception 'REG105_AVAILABILITY_FILTER_CAP_MISSING'; end if;
end;
$$;
reset role;

do $$
declare c record; v_result jsonb;
begin
  select * into c from reg105_context;
  update public.quotation_items set descricao='REG105 historico editado' where quotation_id=c.replay_quotation_id;
  v_result:=public.convert_quotation_to_order_internal_087(c.replay_quotation_id);
  if v_result->>'already_converted'<>'true' or v_result->>'id_pedido'<>c.order_id::text then
    raise exception 'REG105_CONVERSION_REPLAY_BROKEN';
  end if;
end;
$$;

do $$
declare c record;
begin
  select * into c from reg105_context;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',c.reader_id,'role','authenticated','session_id',c.reader_sid)::text,true);
end;
$$;
set local role authenticated;
do $$
declare c record; v_denied boolean; v_count integer; v_result jsonb;
begin
  select * into c from reg105_context;
  if public.is_admin() or not public.is_app_session_active() or not public.has_module('alimentacao') then
    raise exception 'REG105_NONADMIN_SESSION_OR_MODULE_INVALID';
  end if;
  if (select count(*) from public.products where grupo=c.fixture_group)<>506
    or exists(select 1 from public.products where codigo=c.prefix||'000') then raise exception 'REG105_NONADMIN_RLS_INACTIVE_LEAK'; end if;
  v_denied:=false;
  begin
    perform public.set_product_active(c.prefix||'000',true,false);
  exception when others then
    if sqlerrm='SOMENTE_ADMIN_ALTERA_ATIVIDADE_PRODUTO' then v_denied:=true; else raise; end if;
  end;
  if not v_denied then raise exception 'REG105_NONADMIN_RPC_ALLOWED'; end if;
  v_denied:=false;
  begin
    update public.products set ativo=false where codigo=c.prefix||'001';
  exception when insufficient_privilege then v_denied:=true;
    when others then if sqlerrm='SOMENTE_ADMIN_ALTERA_ATIVIDADE_PRODUTO' then v_denied:=true; else raise; end if;
  end;
  if not v_denied then raise exception 'REG105_NONADMIN_DIRECT_UPDATE_ALLOWED'; end if;
  update public.products set ativo=true where codigo=c.prefix||'000';
  get diagnostics v_count=row_count;
  if v_count<>0 then raise exception 'REG105_NONADMIN_DIRECT_REACTIVATION_ALLOWED'; end if;
  update public.products set descricao=descricao||' REG105 update normal' where codigo=c.prefix||'001';
  get diagnostics v_count=row_count;
  if v_count<>1 then raise exception 'REG105_NORMAL_DESCRIPTION_UPDATE_BLOCKED'; end if;
  v_result:=public.search_products_v2(jsonb_build_object('term',c.prefix||'000','group',c.fixture_group,'limit',500,'include_inactive',true));
  if jsonb_array_length(v_result)<>205
    or exists(select 1 from jsonb_array_elements(v_result) item where item->>'codigo'=c.prefix||'000') then
    raise exception 'REG105_NONADMIN_INCLUDE_INACTIVE_LEAK';
  end if;
end;
$$;
reset role;

-- Import-style upserts omit the administrative flag, like partial SAP updates.
do $$
declare c record; v_before integer;
begin
  select * into c from reg105_context;
  select count(*) into v_before from public.logs where acao='ALTERAR_ATIVIDADE_PRODUTO' and id_entidade=c.prefix||'000';
  update public.products set descricao='REG105 descricao importada',status_cadastro='ATIVO' where codigo=c.prefix||'000';
  insert into public.products(codigo,descricao,status_cadastro) values(c.prefix||'000','REG105 upsert importado','ATIVO')
    on conflict(codigo) do update set descricao=excluded.descricao,status_cadastro=excluded.status_cadastro;
  if (select ativo from public.products where codigo=c.prefix||'000') then raise exception 'REG105_IMPORT_REACTIVATED_PRODUCT'; end if;
  if (select count(*) from public.logs where acao='ALTERAR_ATIVIDADE_PRODUTO' and id_entidade=c.prefix||'000')<>v_before then
    raise exception 'REG105_DESCRIPTION_UPDATE_CREATED_ACTIVITY_AUDIT';
  end if;
  if (select count(*) from public.products where grupo=c.fixture_group)<>507 then raise exception 'REG105_PRODUCT_PHYSICALLY_DELETED'; end if;
  if (select count(*) from public.product_catalog_revision)<>c.initial_revision+1 then
    raise exception 'REG105_REVISION_NOT_ONCE_PER_TRANSACTION';
  end if;
  if (select count(*) from pg_trigger where tgname='catalog_revision_changed' and not tgisinternal
    and tgrelid in ('public.products'::regclass,'public.product_branch_stock'::regclass,
      'public.product_branch_prices'::regclass,'public.product_route_prices'::regclass,
      'public.product_catalog_metadata'::regclass,'public.fiscal_tax_rules'::regclass,
      'public.commercial_tax_policies'::regclass,'public.branches'::regclass,
      'public.commercial_route_aliases'::regclass,'public.fiscal_tax_rule_versions'::regclass))<>10 then
    raise exception 'REG105_REVISION_TRIGGER_COVERAGE'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',c.b2b_id,'role','authenticated','session_id',c.b2b_sid)::text,true);
  if not public.is_app_session_active() or public.is_internal_user() then raise exception 'REG105_B2B_SESSION_INVALID'; end if;
  if exists(select 1 from public.b2b_search_catalog_raw_090(c.prefix,'',false,50) where product_code=c.prefix||'000')
    or not exists(select 1 from public.b2b_search_catalog_raw_090(c.prefix,'',false,50) where product_code=c.prefix||'001') then
    raise exception 'REG105_B2B_RAW_ACTIVITY_FILTER_FAILED';
  end if;
end;
$$;
set local role authenticated;
do $$
declare c record; v_denied boolean; v_detail jsonb; v_payload jsonb;
begin
  select * into c from reg105_context;
  if exists(select 1 from public.products where grupo=c.fixture_group) then raise exception 'REG105_B2B_DIRECT_TABLE_LEAK'; end if;
  if exists(select 1 from public.b2b_search_catalog(c.prefix,'',false,50) where product_code=c.prefix||'000')
    or not exists(select 1 from public.b2b_search_catalog(c.prefix,'',false,50) where product_code=c.prefix||'001') then
    raise exception 'REG105_B2B_WRAPPER_ACTIVITY_FILTER_FAILED';
  end if;
  v_denied:=false;
  begin
    perform public.b2b_get_catalog_product_detail(c.prefix||'000');
  exception when others then
    if sqlerrm='PRODUTO_INATIVO_OU_INEXISTENTE' then v_denied:=true; else raise; end if;
  end;
  if not v_denied then raise exception 'REG105_B2B_INACTIVE_DETAIL_ALLOWED'; end if;
  v_denied:=false;
  begin
    perform public.b2b_create_document('pedido',jsonb_build_object('items',jsonb_build_array(
      jsonb_build_object('product_code',c.prefix||'000','quantity',1))));
  exception when others then
    if sqlerrm like 'PRODUTO_INATIVO:%' then v_denied:=true; else raise; end if;
  end;
  if not v_denied then raise exception 'REG105_NEW_B2B_DOCUMENT_INACTIVE_ALLOWED'; end if;
  for v_payload in select jsonb_build_object('items',jsonb_build_array(item)) from (values
    (jsonb_build_object('product_code',' '||c.prefix||'000 ')),
    (jsonb_build_object('codigo',c.prefix||'001','product_code',c.prefix||'000')),
    (jsonb_build_object('codigo',c.prefix||'000','product_code',c.prefix||'001'))
  ) variants(item) loop
    v_denied:=false;
    begin perform public.b2b_create_document('pedido',v_payload);
    exception when others then if sqlerrm like 'PRODUTO_INATIVO:%' then v_denied:=true; else raise; end if; end;
    if not v_denied then raise exception 'REG105_B2B_TRIM_OR_DUAL_CODE_BYPASS'; end if;
  end loop;
  v_detail:=public.b2b_get_catalog_product_detail(c.prefix||'001');
  if v_detail is null then raise exception 'REG105_B2B_ACTIVE_DETAIL_MISSING'; end if;
end;
$$;
reset role;
rollback;
select 'PASS: fictional product activity, audit, authorization, search, commercial pages and B2B regression; rolled back' result;
