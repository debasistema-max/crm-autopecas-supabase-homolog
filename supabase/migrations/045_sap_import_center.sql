begin;

create or replace function public.can_stage_sap_import()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id=auth.uid() and p.ativo
      and (p.perfil='ADMIN' or public.has_module('alimentacao') or public.has_module('importar_estoque_preco'))
  )
$$;

create or replace function public.can_commit_sap_import(import_kind text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id=auth.uid() and p.ativo and (
      p.perfil='ADMIN'
      or (p.perfil='SUPERVISOR'
        and import_kind in ('STOCK_PR','STOCK_SP','BASE_PRICE_PR','BASE_PRICE_SP')
        and public.has_module('importar_estoque_preco')
        and public.has_module('aprovar_importacao'))
    )
  )
$$;

create or replace function public.sap_import_required_fields(import_kind text)
returns text[]
language sql
immutable
parallel safe
as $$
  select case upper(import_kind)
    when 'COMMERCIAL_PRODUCTS' then array['product_code','description']
    when 'SAP_ITEM_MASTER' then array['product_code','description']
    when 'STOCK_PR' then array['product_code','general_available_qty']
    when 'STOCK_SP' then array['product_code','general_available_qty']
    when 'BASE_PRICE_PR' then array['product_code','base_price']
    when 'BASE_PRICE_SP' then array['product_code','base_price']
    when 'FISCAL_RULES_PR' then array['ncm','destination_state','interstate_icms_rate','internal_icms_rate','mva_rate','ipi_rate','has_st']
    when 'FISCAL_RULES_SP' then array['ncm','destination_state','interstate_icms_rate','internal_icms_rate','mva_rate','ipi_rate','has_st']
    else '{}'::text[] end
$$;

create or replace function public.create_sap_import_batch(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_actor public.profiles;
  v_kind text := upper(btrim(coalesce(payload->>'import_kind','')));
  v_branch_code text;
  v_branch public.branches;
  v_origin text;
  v_hash text := lower(btrim(coalesce(payload->>'file_hash','')));
  v_key text;
  v_existing uuid;
  v_id uuid;
begin
  select * into v_actor from public.profiles where id=auth.uid() and ativo;
  if v_actor.id is null or not public.can_stage_sap_import() then raise exception 'SEM_PERMISSAO_IMPORTAR'; end if;
  if v_kind not in ('COMMERCIAL_PRODUCTS','SAP_ITEM_MASTER','STOCK_PR','STOCK_SP','BASE_PRICE_PR','BASE_PRICE_SP','FISCAL_RULES_PR','FISCAL_RULES_SP') then
    raise exception 'TIPO_IMPORTACAO_INVALIDO';
  end if;
  if v_hash !~ '^[0-9a-f]{64}$' then raise exception 'HASH_ARQUIVO_INVALIDO'; end if;
  v_branch_code := case
    when v_kind like '%_PR' then 'PR'
    when v_kind like '%_SP' then 'SP'
    else upper(nullif(btrim(payload->>'branch_code'),'')) end;
  if v_branch_code is not null then
    select * into v_branch from public.branches where code=v_branch_code and active;
    if v_branch.id is null then raise exception 'FILIAL_INVALIDA'; end if;
    if not public.can_access_branch(v_branch.id) then raise exception 'SEM_ACESSO_FILIAL'; end if;
  end if;
  v_origin := case when v_kind like 'FISCAL_RULES_%' then right(v_kind,2) else v_branch.state end;
  v_key := encode(digest(convert_to(concat_ws('|','SAP_IMPORT_V2',v_kind,coalesce(v_branch.code,''),coalesce(v_origin,''),
    coalesce(payload->>'sheet_name',''),v_hash),'UTF8'),'sha256'),'hex');
  select id into v_existing from public.products_import_batches
  where contract_version=2 and idempotency_key=v_key and state='COMMITTED' limit 1;
  if v_existing is not null then
    return jsonb_build_object('batch_id',v_existing,'state','COMMITTED','duplicate',true,'idempotency_key',v_key);
  end if;

  insert into public.products_import_batches(
    created_by,created_by_profile_id,import_type,import_kind,source_name,original_filename,sheet_name,file_size,
    file_hash,client_file_hash,idempotency_key,region,branch_id,origin_state,destination_state,
    contract_version,normalization_algorithm,hash_algorithm,state,status,clear_empty_fields,
    detected_fields,missing_fields,field_mask,summary
  ) values (
    v_actor.usuario,v_actor.id,v_kind,v_kind,nullif(payload->>'source_name',''),nullif(payload->>'original_filename',''),
    nullif(payload->>'sheet_name',''),nullif(payload->>'file_size','')::bigint,v_hash,v_hash,v_key,v_branch.code,v_branch.id,
    v_origin,public.normalize_fiscal_uf(payload->>'destination_state'),2,'sap-import-v2','SHA-256','DRAFT','draft',
    coalesce((payload->>'clear_empty_fields')::boolean,false),
    coalesce(array(select jsonb_array_elements_text(coalesce(payload->'detected_fields','[]'::jsonb))),'{}'::text[]),
    array(select required_field from unnest(public.sap_import_required_fields(v_kind)) required_field
      where not required_field=any(coalesce(array(select jsonb_array_elements_text(coalesce(payload->'detected_fields','[]'::jsonb))),'{}'::text[]))),
    coalesce(array(select jsonb_array_elements_text(coalesce(payload->'detected_fields','[]'::jsonb))),'{}'::text[]),
    jsonb_build_object('phase','UPLOAD','created_at',now())
  ) returning id into v_id;
  return jsonb_build_object('batch_id',v_id,'state','DRAFT','duplicate',false,'idempotency_key',v_key,
    'required_fields',public.sap_import_required_fields(v_kind));
exception when invalid_text_representation or numeric_value_out_of_range then
  raise exception 'METADADOS_IMPORTACAO_INVALIDOS';
end;
$$;

create or replace function public.stage_sap_import_rows(batch_id uuid, rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch public.products_import_batches;
  v_row jsonb;
  v_data jsonb;
  v_row_number integer;
  v_key text;
  v_count integer := 0;
begin
  select * into v_batch from public.products_import_batches b
  where b.id=batch_id and b.contract_version=2 and b.state='DRAFT'
    and (b.created_by_profile_id=auth.uid() or public.is_admin()) for update;
  if v_batch.id is null then raise exception 'LOTE_NAO_AUTORIZADO_OU_FORA_DE_ESTADO'; end if;
  if jsonb_typeof(rows)<>'array' or jsonb_array_length(rows)=0 then raise exception 'STAGING_SEM_LINHAS'; end if;
  for v_row in select value from jsonb_array_elements(rows) loop
    v_row_number := coalesce((v_row->>'row_number')::integer,v_count+1);
    v_data := coalesce(v_row->'data','{}'::jsonb);
    if jsonb_typeof(v_data)<>'object' then raise exception 'LINHA_NORMALIZADA_INVALIDA: %',v_row_number; end if;
    v_key := case when v_batch.import_kind like 'FISCAL_RULES_%'
      then coalesce(public.normalize_ncm(v_data->>'ncm'),'INVALID') || '|' || coalesce(public.normalize_fiscal_uf(v_batch.origin_state),'') || '|' || coalesce(public.normalize_fiscal_uf(v_data->>'destination_state'),'')
      else nullif(btrim(v_data->>'product_code'),'') end;
    if v_key is null then v_key := 'ROW|'||v_row_number; end if;
    insert into public.products_import_stage(batch_id,row_number,codigo,normalized_code,raw_data,normalized_data,status,
      provided_fields,field_mask,row_hash)
    values(batch_id,v_row_number,nullif(btrim(v_data->>'product_code'),''),v_key,coalesce(v_row->'raw',v_data),v_data,'pending',
      array(select jsonb_object_keys(v_data)),v_batch.field_mask,md5(v_data::text))
    on conflict do nothing;
    v_count := v_count + 1;
  end loop;
  update public.products_import_batches set total_rows=(select count(*) from public.products_import_stage where products_import_stage.batch_id=stage_sap_import_rows.batch_id),
    summary=summary||jsonb_build_object('phase','STAGING','staged_at',now()) where id=batch_id;
  return jsonb_build_object('batch_id',batch_id,'staged_rows',v_count,'total_rows',(select count(*) from public.products_import_stage where products_import_stage.batch_id=stage_sap_import_rows.batch_id));
end;
$$;

create or replace function public.validate_sap_import_batch(batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch public.products_import_batches;
  v_stage public.products_import_stage;
  v_data jsonb;
  v_errors jsonb;
  v_warnings jsonb;
  v_before jsonb;
  v_after jsonb;
  v_code text;
  v_ncm text;
  v_destination text;
  v_number numeric;
  v_valid integer := 0;
  v_invalid integer := 0;
  v_warning_count integer := 0;
begin
  select * into v_batch from public.products_import_batches b
  where b.id=batch_id and b.contract_version=2 and b.state in ('DRAFT','FAILED')
    and (b.created_by_profile_id=auth.uid() or public.is_admin()) for update;
  if v_batch.id is null then raise exception 'LOTE_NAO_AUTORIZADO_OU_FORA_DE_ESTADO'; end if;
  for v_stage in select * from public.products_import_stage where products_import_stage.batch_id=validate_sap_import_batch.batch_id order by row_number loop
    v_data:=v_stage.normalized_data; v_errors:='[]'::jsonb; v_warnings:='[]'::jsonb; v_before:=null; v_after:=v_data;
    v_code:=nullif(btrim(v_data->>'product_code'),''); v_ncm:=public.normalize_ncm(v_data->>'ncm');
    v_destination:=public.normalize_fiscal_uf(v_data->>'destination_state');
    if v_batch.import_kind not like 'FISCAL_RULES_%' then
      if v_code is null then v_errors:=v_errors||jsonb_build_array('CODIGO_AUSENTE');
      else select to_jsonb(p) into v_before from public.products p where p.codigo=v_code; end if;
    end if;
    if v_batch.import_kind in ('COMMERCIAL_PRODUCTS','SAP_ITEM_MASTER') then
      if v_before is null and nullif(btrim(v_data->>'description'),'') is null then v_errors:=v_errors||jsonb_build_array('DESCRICAO_AUSENTE_PRODUTO_NOVO'); end if;
      if v_data ? 'ncm' and nullif(v_data->>'ncm','') is not null and v_ncm is null then v_errors:=v_errors||jsonb_build_array('NCM_INVALIDO'); end if;
      if v_data ? 'cest' and nullif(v_data->>'cest','') is not null and public.normalize_cest(v_data->>'cest') is null then v_errors:=v_errors||jsonb_build_array('CEST_INVALIDO'); end if;
      if not (v_data ? 'ncm') then v_warnings:=v_warnings||jsonb_build_array('NCM_AUSENTE'); end if;
    elsif v_batch.import_kind like 'STOCK_%' then
      if v_before is null then v_errors:=v_errors||jsonb_build_array('PRODUTO_INEXISTENTE'); end if;
      v_number:=public.parse_sap_decimal(v_data->>'general_available_qty');
      if v_number is null then v_errors:=v_errors||jsonb_build_array('DISP_GERAL_INVALIDA'); elsif v_number<0 then v_errors:=v_errors||jsonb_build_array('QUANTIDADE_NEGATIVA'); end if;
      select to_jsonb(s) into v_before from public.product_branch_stock s where s.product_code=v_code and s.branch_id=v_batch.branch_id;
    elsif v_batch.import_kind like 'BASE_PRICE_%' then
      if v_before is null then v_errors:=v_errors||jsonb_build_array('PRODUTO_INEXISTENTE'); end if;
      v_number:=public.parse_sap_decimal(v_data->>'base_price');
      if v_number is null then v_errors:=v_errors||jsonb_build_array('PRECO_INVALIDO'); elsif v_number<0 then v_errors:=v_errors||jsonb_build_array('PRECO_NEGATIVO'); end if;
      select to_jsonb(p) into v_before from public.product_branch_prices p where p.product_code=v_code and p.branch_id=v_batch.branch_id;
    else
      if v_ncm is null then v_errors:=v_errors||jsonb_build_array('NCM_INVALIDO'); end if;
      if v_destination is null then v_errors:=v_errors||jsonb_build_array('UF_DESTINO_INVALIDA'); end if;
      if not (v_data ? 'has_st') then v_errors:=v_errors||jsonb_build_array('HAS_ST_NAO_DEFINIDO'); end if;
      foreach v_code in array array['interstate_icms_rate','internal_icms_rate','mva_rate','ipi_rate'] loop
        v_number:=public.parse_sap_decimal(v_data->>v_code);
        if v_number is null then v_errors:=v_errors||jsonb_build_array(upper(v_code)||'_INVALIDA');
        elsif v_number<0 or (v_code<>'mva_rate' and v_number>10) then v_errors:=v_errors||jsonb_build_array(upper(v_code)||'_FORA_FAIXA'); end if;
      end loop;
      select to_jsonb(f) into v_before from public.fiscal_tax_rules f
      where f.ncm=v_ncm and f.uf_origem=v_batch.origin_state and f.uf_destino=v_destination
        and f.operation_type='VENDA' and f.customer_type='GERAL'
        and f.effective_from=coalesce((v_data->>'effective_from')::date,current_date);
    end if;
    if v_batch.import_kind in ('COMMERCIAL_PRODUCTS','SAP_ITEM_MASTER') and v_before is not null then
      v_after:=v_before||v_data;
    elsif v_before is not null then v_after:=v_before||v_data; end if;
    update public.products_import_stage set blocking_errors=v_errors,warnings=v_warnings,errors=v_errors,
      status=case when jsonb_array_length(v_errors)>0 then 'error' when jsonb_array_length(v_warnings)>0 then 'warning' else 'valid' end,
      planned_action=case when v_before is null then 'INSERT' else 'UPDATE' end,
      product_before=case when v_batch.import_kind in ('COMMERCIAL_PRODUCTS','SAP_ITEM_MASTER') then v_before else null end,
      product_after=case when v_batch.import_kind in ('COMMERCIAL_PRODUCTS','SAP_ITEM_MASTER') then v_after else null end,
      stock_before=case when v_batch.import_kind like 'STOCK_%' then v_before else null end,
      stock_after=case when v_batch.import_kind like 'STOCK_%' then v_after else null end,
      price_before=case when v_batch.import_kind like 'BASE_PRICE_%' or v_batch.import_kind like 'FISCAL_RULES_%' then v_before else null end,
      price_after=case when v_batch.import_kind like 'BASE_PRICE_%' or v_batch.import_kind like 'FISCAL_RULES_%' then v_after else null end
    where id=v_stage.id;
    if jsonb_array_length(v_errors)>0 then v_invalid:=v_invalid+1; else v_valid:=v_valid+1; end if;
    v_warning_count:=v_warning_count+jsonb_array_length(v_warnings);
  end loop;
  update public.products_import_batches set state=case when v_invalid>0 then 'FAILED' else 'PREVIEWED' end,
    status=case when v_invalid>0 then 'failed' else 'validated' end,total_rows=v_valid+v_invalid,valid_rows=v_valid,
    invalid_rows=v_invalid,error_count=v_invalid,warning_count=v_warning_count,previewed_at=now(),
    summary=summary||jsonb_build_object('phase','VALIDATION','valid',v_valid,'invalid',v_invalid,'warnings',v_warning_count,'validated_at',now()),
    last_failure_code=case when v_invalid>0 then 'VALIDATION_ERRORS' else null end
  where id=batch_id;
  return public.preview_sap_import_batch(batch_id,1,50);
end;
$$;

create or replace function public.preview_sap_import_batch(batch_id uuid, page integer default 1, page_size integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_batch public.products_import_batches; v_rows jsonb;
begin
  select * into v_batch from public.products_import_batches b where b.id=batch_id and b.contract_version=2
    and (b.created_by_profile_id=auth.uid() or public.is_admin() or public.can_view_products_import_batches());
  if v_batch.id is null then raise exception 'LOTE_NAO_AUTORIZADO'; end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.row_number),'[]'::jsonb) into v_rows from (
    select id,row_number,normalized_code,normalized_data,status,errors,warnings,planned_action,
      coalesce(product_before,stock_before,price_before) before_data,
      coalesce(product_after,stock_after,price_after) after_data
    from public.products_import_stage where products_import_stage.batch_id=preview_sap_import_batch.batch_id
    order by row_number limit least(greatest(page_size,1),500) offset greatest(page-1,0)*least(greatest(page_size,1),500)
  ) x;
  return jsonb_build_object('batch',jsonb_build_object('id',v_batch.id,'import_kind',v_batch.import_kind,'state',v_batch.state,
    'source_name',v_batch.source_name,'filename',v_batch.original_filename,'sheet_name',v_batch.sheet_name,'branch_id',v_batch.branch_id,
    'origin_state',v_batch.origin_state,'total_rows',v_batch.total_rows,'valid_rows',v_batch.valid_rows,'invalid_rows',v_batch.invalid_rows,
    'warning_count',v_batch.warning_count,'error_count',v_batch.error_count,'summary',v_batch.summary,'created_at',v_batch.created_at,
    'committed_at',v_batch.committed_at),'rows',v_rows,'page',page,'page_size',page_size);
end;
$$;

create or replace function public.approve_sap_import_batch(batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_batch public.products_import_batches; v_actor public.profiles;
begin
  select * into v_actor from public.profiles where id=auth.uid() and ativo;
  select * into v_batch from public.products_import_batches where id=batch_id and contract_version=2 for update;
  if v_batch.id is null then raise exception 'LOTE_NAO_ENCONTRADO'; end if;
  if v_batch.state='COMMITTED' then return jsonb_build_object('batch_id',batch_id,'state','COMMITTED','already_committed',true); end if;
  if v_batch.state<>'PREVIEWED' or v_batch.error_count>0 then raise exception 'LOTE_NAO_VALIDADO'; end if;
  if not public.can_commit_sap_import(v_batch.import_kind) then raise exception 'SEM_PERMISSAO_APROVAR_IMPORTACAO'; end if;
  update public.products_import_batches set state='APPROVED',status='approved',approved_at=now(),approved_by=v_actor.usuario,
    approved_by_profile_id=v_actor.id,summary=summary||jsonb_build_object('phase','APPROVAL','approved_at',now()) where id=batch_id;
  return jsonb_build_object('batch_id',batch_id,'state','APPROVED');
end;
$$;

create or replace function public.commit_sap_import_batch(batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch public.products_import_batches;
  v_actor public.profiles;
  v_affected integer := 0;
begin
  select * into v_actor from public.profiles where id=auth.uid() and ativo;
  select * into v_batch from public.products_import_batches where id=batch_id and contract_version=2 for update;
  if v_batch.id is null then raise exception 'LOTE_NAO_ENCONTRADO'; end if;
  if v_batch.state='COMMITTED' then return public.preview_sap_import_batch(batch_id,1,50)||jsonb_build_object('already_committed',true); end if;
  if v_batch.state<>'APPROVED' or not public.can_commit_sap_import(v_batch.import_kind) then raise exception 'LOTE_NAO_APROVADO'; end if;
  if exists(select 1 from public.products_import_stage where products_import_stage.batch_id=commit_sap_import_batch.batch_id and status='error') then raise exception 'LOTE_COM_ERROS'; end if;
  update public.products_import_batches set state='COMMITTING',last_attempt_started_at=now(),attempt_count=attempt_count+1 where id=batch_id;

  insert into public.products_import_audit(batch_id,stage_id,codigo,action,before_data,after_data,created_by,branch_id,entity_type,field_name,old_value,new_value)
  select s.batch_id,s.id,s.codigo,lower(coalesce(s.planned_action,'update')),coalesce(s.product_before,s.stock_before,s.price_before),
    coalesce(s.product_after,s.stock_after,s.price_after),v_actor.usuario,v_batch.branch_id,
    case when v_batch.import_kind in ('COMMERCIAL_PRODUCTS','SAP_ITEM_MASTER') then 'PRODUCT'
      when v_batch.import_kind like 'STOCK_%' then 'STOCK' when v_batch.import_kind like 'BASE_PRICE_%' then 'PRICE' else 'FISCAL_RULE' end,
    '*',coalesce(s.product_before,s.stock_before,s.price_before),coalesce(s.product_after,s.stock_after,s.price_after)
  from public.products_import_stage s where s.batch_id=commit_sap_import_batch.batch_id and s.status<>'error';

  if v_batch.import_kind in ('COMMERCIAL_PRODUCTS','SAP_ITEM_MASTER') then
    insert into public.products(codigo,descricao,marca,aplicacao,ano,ncm,cest,ipi_rate,ipi_defined,origin_code,origin_description,
      material_group,fiscal_group,fiscal_source,fiscal_updated_at,fiscal_import_batch_id,grupo,montadora,oem,detalhes)
    select s.normalized_data->>'product_code',nullif(s.normalized_data->>'description',''),nullif(s.normalized_data->>'brand',''),
      nullif(s.normalized_data->>'application',''),nullif(s.normalized_data->>'year',''),public.normalize_ncm(s.normalized_data->>'ncm'),
      public.normalize_cest(s.normalized_data->>'cest'),public.parse_sap_decimal(s.normalized_data->>'ipi_rate'),s.normalized_data ? 'ipi_rate',
      nullif(s.normalized_data->>'origin_code',''),nullif(s.normalized_data->>'origin_description',''),nullif(s.normalized_data->>'material_group',''),
      nullif(s.normalized_data->>'fiscal_group',''),v_batch.import_kind,now(),v_batch.id,nullif(s.normalized_data->>'group',''),
      nullif(s.normalized_data->>'manufacturer',''),nullif(s.normalized_data->>'oem_01',''),nullif(s.normalized_data->>'item_notes','')
    from public.products_import_stage s where s.batch_id=v_batch.id and s.status<>'error'
    on conflict(codigo) do update set
      descricao=coalesce(excluded.descricao,products.descricao),marca=coalesce(excluded.marca,products.marca),
      aplicacao=coalesce(excluded.aplicacao,products.aplicacao),ano=coalesce(excluded.ano,products.ano),ncm=coalesce(excluded.ncm,products.ncm),
      cest=coalesce(excluded.cest,products.cest),ipi_rate=case when excluded.ipi_defined then excluded.ipi_rate else products.ipi_rate end,
      ipi_defined=products.ipi_defined or excluded.ipi_defined,origin_code=coalesce(excluded.origin_code,products.origin_code),
      origin_description=coalesce(excluded.origin_description,products.origin_description),material_group=coalesce(excluded.material_group,products.material_group),
      fiscal_group=coalesce(excluded.fiscal_group,products.fiscal_group),fiscal_source=excluded.fiscal_source,fiscal_updated_at=now(),
      fiscal_import_batch_id=excluded.fiscal_import_batch_id,grupo=coalesce(excluded.grupo,products.grupo),montadora=coalesce(excluded.montadora,products.montadora),
      oem=coalesce(excluded.oem,products.oem),detalhes=coalesce(excluded.detalhes,products.detalhes),updated_at=now();
    get diagnostics v_affected=row_count;
    if v_batch.import_kind='SAP_ITEM_MASTER' then
      insert into public.product_sap_data(product_code,sap_description,brand,model,year_text,in_stock_text,ordered_qty,oem_01,delivery_text,
        last_purchase_date,compatible_text,import_notes,item_group,sales_unit,item_notes,weight,volume,manufacturer_code_01,manufacturer_code_02,
        manufacturer,barcode,product_source,material_type,origin_and_fiscal_group,materials_group,origin_and_ncm,raw_data,source,import_batch_id)
      select d->>'product_code',nullif(d->>'description',''),nullif(d->>'brand',''),nullif(d->>'model',''),nullif(d->>'year',''),
        nullif(d->>'in_stock',''),public.parse_sap_decimal(d->>'ordered_qty'),nullif(d->>'oem_01',''),nullif(d->>'delivery',''),
        nullif(d->>'last_purchase_date','')::date,nullif(d->>'compatible',''),nullif(d->>'import_notes',''),nullif(d->>'item_group',''),
        nullif(d->>'sales_unit',''),nullif(d->>'item_notes',''),public.parse_sap_decimal(d->>'weight'),public.parse_sap_decimal(d->>'volume'),
        nullif(d->>'manufacturer_code_01',''),nullif(d->>'manufacturer_code_02',''),nullif(d->>'manufacturer',''),nullif(d->>'barcode',''),
        nullif(d->>'product_source',''),nullif(d->>'material_type',''),nullif(d->>'origin_and_fiscal_group',''),nullif(d->>'materials_group',''),
        nullif(d->>'origin_and_ncm',''),raw_data,'SAP_ITEM_MASTER',v_batch.id
      from (select normalized_data d,raw_data from public.products_import_stage where products_import_stage.batch_id=v_batch.id and status<>'error') x
      on conflict(product_code) do update set sap_description=coalesce(excluded.sap_description,product_sap_data.sap_description),
        brand=coalesce(excluded.brand,product_sap_data.brand),model=coalesce(excluded.model,product_sap_data.model),year_text=coalesce(excluded.year_text,product_sap_data.year_text),
        in_stock_text=coalesce(excluded.in_stock_text,product_sap_data.in_stock_text),ordered_qty=coalesce(excluded.ordered_qty,product_sap_data.ordered_qty),
        oem_01=coalesce(excluded.oem_01,product_sap_data.oem_01),delivery_text=coalesce(excluded.delivery_text,product_sap_data.delivery_text),
        last_purchase_date=coalesce(excluded.last_purchase_date,product_sap_data.last_purchase_date),compatible_text=coalesce(excluded.compatible_text,product_sap_data.compatible_text),
        import_notes=coalesce(excluded.import_notes,product_sap_data.import_notes),item_group=coalesce(excluded.item_group,product_sap_data.item_group),
        sales_unit=coalesce(excluded.sales_unit,product_sap_data.sales_unit),item_notes=coalesce(excluded.item_notes,product_sap_data.item_notes),
        weight=coalesce(excluded.weight,product_sap_data.weight),volume=coalesce(excluded.volume,product_sap_data.volume),
        manufacturer_code_01=coalesce(excluded.manufacturer_code_01,product_sap_data.manufacturer_code_01),
        manufacturer_code_02=coalesce(excluded.manufacturer_code_02,product_sap_data.manufacturer_code_02),manufacturer=coalesce(excluded.manufacturer,product_sap_data.manufacturer),
        barcode=coalesce(excluded.barcode,product_sap_data.barcode),product_source=coalesce(excluded.product_source,product_sap_data.product_source),
        material_type=coalesce(excluded.material_type,product_sap_data.material_type),origin_and_fiscal_group=coalesce(excluded.origin_and_fiscal_group,product_sap_data.origin_and_fiscal_group),
        materials_group=coalesce(excluded.materials_group,product_sap_data.materials_group),origin_and_ncm=coalesce(excluded.origin_and_ncm,product_sap_data.origin_and_ncm),
        raw_data=product_sap_data.raw_data||excluded.raw_data,source=excluded.source,import_batch_id=excluded.import_batch_id,updated_at=now();
    end if;
  elsif v_batch.import_kind like 'STOCK_%' then
    insert into public.product_branch_stock(product_code,branch_id,physical_qty,sap_stock_qty,sap_confirmed_qty,sap_sales_available_qty,
      sap_authorized_pending_qty,sap_general_available_qty,available_qty_capped,source_display_value,source_batch_id,source_updated_at,updated_by)
    select d->>'product_code',v_batch.branch_id,coalesce(public.parse_sap_decimal(d->>'stock_qty'),public.parse_sap_decimal(d->>'general_available_qty')),
      public.parse_sap_decimal(d->>'stock_qty'),public.parse_sap_decimal(d->>'confirmed_qty'),public.parse_sap_decimal(d->>'sales_available_qty'),
      public.parse_sap_decimal(d->>'authorized_pending_qty'),public.parse_sap_decimal(d->>'general_available_qty'),coalesce((d->>'general_available_capped')::boolean,false),
      nullif(d->>'source_display_value',''),v_batch.id,now(),v_actor.id
    from (select normalized_data d from public.products_import_stage where products_import_stage.batch_id=v_batch.id and status<>'error') x
    on conflict(product_code,branch_id) do update set physical_qty=excluded.physical_qty,sap_stock_qty=excluded.sap_stock_qty,
      sap_confirmed_qty=excluded.sap_confirmed_qty,sap_sales_available_qty=excluded.sap_sales_available_qty,
      sap_authorized_pending_qty=excluded.sap_authorized_pending_qty,sap_general_available_qty=excluded.sap_general_available_qty,
      available_qty_capped=excluded.available_qty_capped,source_display_value=excluded.source_display_value,source_batch_id=excluded.source_batch_id,
      source_updated_at=now(),updated_by=excluded.updated_by;
    get diagnostics v_affected=row_count;
  elsif v_batch.import_kind like 'BASE_PRICE_%' then
    insert into public.product_branch_prices(product_code,branch_id,sale_price,currency,version,source,source_batch_id,updated_by,valid_from)
    select d->>'product_code',v_batch.branch_id,public.parse_sap_decimal(d->>'base_price'),'BRL',1,'BRANCH_IMPORT_V2',v_batch.id,v_actor.id,
      coalesce(nullif(d->>'valid_from','')::date,current_date)
    from (select normalized_data d from public.products_import_stage where products_import_stage.batch_id=v_batch.id and status<>'error') x
    on conflict(product_code,branch_id) do update set sale_price=excluded.sale_price,version=product_branch_prices.version+1,source=excluded.source,
      source_batch_id=excluded.source_batch_id,updated_by=excluded.updated_by,valid_from=excluded.valid_from,valid_until=null,updated_at=now();
    get diagnostics v_affected=row_count;
  else
    insert into public.fiscal_tax_rules(ncm,uf_origem,uf_destino,operation_type,customer_type,icms_percent,icms_st_percent,mva_percent,ipi_percent,
      interstate_icms_rate,internal_icms_rate,mva_rate,ipi_rate,pis_rate,cofins_rate,fcp_rate,has_st,cest,cfop,cst_code,
      base_reduction_rate,freight_rate,insurance_rate,other_expenses_rate,effective_from,effective_to,active,source,source_code,notes,import_batch_id,created_by,updated_by)
    select public.normalize_ncm(d->>'ncm'),v_batch.origin_state,public.normalize_fiscal_uf(d->>'destination_state'),'VENDA','GERAL',
      public.parse_sap_decimal(d->>'interstate_icms_rate')*100,public.parse_sap_decimal(d->>'internal_icms_rate')*100,
      public.parse_sap_decimal(d->>'mva_rate')*100,public.parse_sap_decimal(d->>'ipi_rate')*100,
      public.parse_sap_decimal(d->>'interstate_icms_rate'),public.parse_sap_decimal(d->>'internal_icms_rate'),public.parse_sap_decimal(d->>'mva_rate'),
      public.parse_sap_decimal(d->>'ipi_rate'),public.parse_sap_decimal(d->>'pis_rate'),public.parse_sap_decimal(d->>'cofins_rate'),
      public.parse_sap_decimal(d->>'fcp_rate'),(d->>'has_st')::boolean,public.normalize_cest(d->>'cest'),nullif(d->>'cfop',''),nullif(d->>'cst_code',''),
      coalesce(public.parse_sap_decimal(d->>'base_reduction_rate'),0),coalesce(public.parse_sap_decimal(d->>'freight_rate'),0),
      coalesce(public.parse_sap_decimal(d->>'insurance_rate'),0),coalesce(public.parse_sap_decimal(d->>'other_expenses_rate'),0),
      coalesce(nullif(d->>'effective_from','')::date,current_date),nullif(d->>'effective_to','')::date,true,'SAP_FISCAL',nullif(d->>'source_code',''),
      nullif(d->>'notes',''),v_batch.id,v_actor.id,v_actor.id
    from (select normalized_data d from public.products_import_stage where products_import_stage.batch_id=v_batch.id and status<>'error') x
    on conflict(ncm,uf_origem,uf_destino,operation_type,customer_type,effective_from) do update set
      icms_percent=excluded.icms_percent,icms_st_percent=excluded.icms_st_percent,mva_percent=excluded.mva_percent,ipi_percent=excluded.ipi_percent,
      interstate_icms_rate=excluded.interstate_icms_rate,internal_icms_rate=excluded.internal_icms_rate,mva_rate=excluded.mva_rate,ipi_rate=excluded.ipi_rate,
      pis_rate=coalesce(excluded.pis_rate,fiscal_tax_rules.pis_rate),cofins_rate=coalesce(excluded.cofins_rate,fiscal_tax_rules.cofins_rate),
      fcp_rate=coalesce(excluded.fcp_rate,fiscal_tax_rules.fcp_rate),has_st=excluded.has_st,cest=coalesce(excluded.cest,fiscal_tax_rules.cest),
      cfop=coalesce(excluded.cfop,fiscal_tax_rules.cfop),cst_code=coalesce(excluded.cst_code,fiscal_tax_rules.cst_code),
      base_reduction_rate=excluded.base_reduction_rate,freight_rate=excluded.freight_rate,insurance_rate=excluded.insurance_rate,
      other_expenses_rate=excluded.other_expenses_rate,effective_to=excluded.effective_to,active=true,source=excluded.source,source_code=excluded.source_code,
      notes=coalesce(excluded.notes,fiscal_tax_rules.notes),import_batch_id=excluded.import_batch_id,updated_by=excluded.updated_by,updated_at=now();
    get diagnostics v_affected=row_count;
  end if;

  update public.products_import_batches set state='COMMITTED',status='imported',committed_at=now(),imported_at=now(),committed_by_profile_id=v_actor.id,
    last_attempt_completed_at=now(),summary=summary||jsonb_build_object('phase','COMMIT','affected',v_affected,'committed_at',now()) where id=batch_id;
  insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_novos)
  values(v_actor.id,v_actor.usuario,'IMPORTAR_SAP_'||v_batch.import_kind,'products_import_batches',batch_id::text,
    jsonb_build_object('import_kind',v_batch.import_kind,'branch_id',v_batch.branch_id,'origin_state',v_batch.origin_state,'affected',v_affected,'file',v_batch.original_filename));
  return public.preview_sap_import_batch(batch_id,1,50)||jsonb_build_object('affected',v_affected,'already_committed',false);
exception when others then
  -- The exception aborts the complete transaction; no partial data is retained.
  raise;
end;
$$;

create or replace function public.list_sap_import_batches(filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_rows jsonb;
begin
  if not (public.is_admin() or public.has_module('visualizar_lotes_importacao') or public.has_module('alimentacao')) then raise exception 'SEM_PERMISSAO'; end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_rows from (
    select b.id,b.created_at,b.import_kind,b.original_filename,b.sheet_name,b.region,b.origin_state,b.state,b.total_rows,b.valid_rows,
      b.invalid_rows,b.warning_count,b.error_count,b.committed_at,b.summary,p.nome created_by_name
    from public.products_import_batches b left join public.profiles p on p.id=b.created_by_profile_id
    where b.contract_version=2 and (nullif(filters->>'import_kind','') is null or b.import_kind=filters->>'import_kind')
      and (nullif(filters->>'state','') is null or b.state=filters->>'state')
    order by b.created_at desc limit least(greatest(coalesce((filters->>'limit')::integer,100),1),1000)
  ) x;
  return jsonb_build_object('rows',v_rows,'count',jsonb_array_length(v_rows));
end;
$$;

grant execute on function public.can_stage_sap_import(),public.can_commit_sap_import(text),public.sap_import_required_fields(text),
  public.create_sap_import_batch(jsonb),public.stage_sap_import_rows(uuid,jsonb),public.validate_sap_import_batch(uuid),
  public.preview_sap_import_batch(uuid,integer,integer),public.approve_sap_import_batch(uuid),public.commit_sap_import_batch(uuid),
  public.list_sap_import_batches(jsonb) to authenticated;

comment on function public.commit_sap_import_batch(uuid) is 'Commit atômico da Central de Importações; qualquer erro causa rollback integral.';

commit;
