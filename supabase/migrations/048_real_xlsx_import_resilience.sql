begin;

-- A corrected XLSX normalization contract must be able to reprocess a file
-- previously committed with the v2 duplicate-header mapping.
alter table public.products_import_batches drop constraint if exists products_import_batches_v2_required_check;
alter table public.products_import_batches
  add constraint products_import_batches_v2_required_check check (
    contract_version = 0
    or (contract_version = 1
      and branch_id is not null
      and mode in ('UPDATE_STOCK','UPDATE_PRICES','CREATE_PRODUCTS','CUSTOM_UPDATE','FULL_IMPORT')
      and cardinality(field_mask) > 0
      and normalization_algorithm = 'branch-import-v1'
      and hash_algorithm = 'SHA-256'
      and (state in ('DRAFT','FAILED') or (normalized_file_hash is not null and idempotency_key is not null)))
    or (contract_version = 2
      and import_kind in ('COMMERCIAL_PRODUCTS','SAP_ITEM_MASTER','STOCK_PR','STOCK_SP','BASE_PRICE_PR','BASE_PRICE_SP','FISCAL_RULES_PR','FISCAL_RULES_SP')
      and normalization_algorithm in ('sap-import-v2','sap-import-v3')
      and hash_algorithm = 'SHA-256')
  );

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
  v_key := encode(digest(convert_to(concat_ws('|','SAP_IMPORT_V3',v_kind,coalesce(v_branch.code,''),coalesce(v_origin,''),
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
    v_origin,public.normalize_fiscal_uf(payload->>'destination_state'),2,'sap-import-v3','SHA-256','DRAFT','draft',
    coalesce((payload->>'clear_empty_fields')::boolean,false),
    coalesce(array(select jsonb_array_elements_text(coalesce(payload->'detected_fields','[]'::jsonb))),'{}'::text[]),
    array(select required_field from unnest(public.sap_import_required_fields(v_kind)) required_field
      where not required_field=any(coalesce(array(select jsonb_array_elements_text(coalesce(payload->'detected_fields','[]'::jsonb))),'{}'::text[]))),
    coalesce(array(select jsonb_array_elements_text(coalesce(payload->'detected_fields','[]'::jsonb))),'{}'::text[]),
    jsonb_build_object('phase','UPLOAD','created_at',now(),'normalization','sap-import-v3')
  ) returning id into v_id;
  return jsonb_build_object('batch_id',v_id,'state','DRAFT','duplicate',false,'idempotency_key',v_key,
    'required_fields',public.sap_import_required_fields(v_kind));
exception when invalid_text_representation or numeric_value_out_of_range then
  raise exception 'METADADOS_IMPORTACAO_INVALIDOS';
end;
$$;

-- Large SAP masters legitimately take longer than the API role default.
-- The function remains transactional; only the timeout envelope changes.
alter function public.commit_sap_import_batch(uuid) set statement_timeout = '120s';
alter function public.validate_sap_import_batch(uuid) set statement_timeout = '120s';

comment on function public.create_sap_import_batch(jsonb)
  is 'Central SAP v3: idempotência inclui a versão corrigida de normalização de XLSX e cabeçalhos duplicados.';

commit;
