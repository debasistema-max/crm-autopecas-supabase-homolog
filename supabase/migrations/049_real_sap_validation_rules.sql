begin;

create or replace function public.validate_sap_import_batch(batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
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
  v_has_st boolean;
  v_valid integer := 0;
  v_invalid integer := 0;
  v_warning_count integer := 0;
begin
  select * into v_batch from public.products_import_batches b
  where b.id=batch_id and b.contract_version=2 and b.state in ('DRAFT','FAILED')
    and (b.created_by_profile_id=auth.uid() or public.is_admin()) for update;
  if v_batch.id is null then raise exception 'LOTE_NAO_AUTORIZADO_OU_FORA_DE_ESTADO'; end if;

  for v_stage in select * from public.products_import_stage
    where products_import_stage.batch_id=validate_sap_import_batch.batch_id order by row_number loop
    v_data:=v_stage.normalized_data; v_errors:='[]'::jsonb; v_warnings:='[]'::jsonb; v_before:=null; v_after:=v_data;
    v_code:=nullif(btrim(v_data->>'product_code'),''); v_ncm:=public.normalize_ncm(v_data->>'ncm');
    v_destination:=public.normalize_fiscal_uf(v_data->>'destination_state');
    v_has_st:=coalesce((v_data->>'has_st')::boolean,false);

    if v_batch.import_kind not like 'FISCAL_RULES_%' then
      if v_code is null then v_errors:=v_errors||jsonb_build_array('CODIGO_AUSENTE');
      else
        select to_jsonb(p) into v_before from public.products p where p.codigo=v_code;
        if exists(select 1 from public.products_import_stage duplicate
          where duplicate.batch_id=v_stage.batch_id and duplicate.row_number<v_stage.row_number
            and nullif(btrim(duplicate.normalized_data->>'product_code'),'')=v_code) then
          v_errors:=v_errors||jsonb_build_array('CODIGO_DUPLICADO_NO_ARQUIVO');
        end if;
      end if;
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
      if exists(select 1 from public.products_import_stage duplicate
        where duplicate.batch_id=v_stage.batch_id and duplicate.row_number<v_stage.row_number
          and public.normalize_ncm(duplicate.normalized_data->>'ncm')=v_ncm
          and public.normalize_fiscal_uf(duplicate.normalized_data->>'destination_state')=v_destination) then
        v_errors:=v_errors||jsonb_build_array('REGRA_DUPLICADA_NO_ARQUIVO');
      end if;

      v_number:=public.parse_sap_decimal(v_data->>'interstate_icms_rate');
      if v_number is null then v_errors:=v_errors||jsonb_build_array('INTERSTATE_ICMS_RATE_INVALIDA');
      elsif v_number<0 or v_number>1 then v_errors:=v_errors||jsonb_build_array('INTERSTATE_ICMS_RATE_FORA_FAIXA'); end if;

      v_number:=public.parse_sap_decimal(v_data->>'internal_icms_rate');
      if v_has_st and v_number is null then v_errors:=v_errors||jsonb_build_array('INTERNAL_ICMS_RATE_INVALIDA');
      elsif v_number is not null and (v_number<0 or v_number>1) then v_errors:=v_errors||jsonb_build_array('INTERNAL_ICMS_RATE_FORA_FAIXA'); end if;

      v_number:=public.parse_sap_decimal(v_data->>'mva_rate');
      if v_has_st and v_number is null then v_errors:=v_errors||jsonb_build_array('MVA_RATE_INVALIDA');
      elsif v_number is not null and (v_number<0 or v_number>10) then v_errors:=v_errors||jsonb_build_array('MVA_RATE_FORA_FAIXA'); end if;

      v_number:=public.parse_sap_decimal(v_data->>'ipi_rate');
      if v_number is null then v_warnings:=v_warnings||jsonb_build_array('IPI_REGRA_AUSENTE_USARA_PRODUTO');
      elsif v_number<0 or v_number>1 then v_errors:=v_errors||jsonb_build_array('IPI_RATE_FORA_FAIXA'); end if;

      select to_jsonb(f) into v_before from public.fiscal_tax_rules f
      where f.ncm=v_ncm and f.uf_origem=v_batch.origin_state and f.uf_destino=v_destination
        and f.operation_type='VENDA' and f.customer_type='GERAL'
        and f.effective_from=coalesce((v_data->>'effective_from')::date,current_date);
    end if;

    if v_before is not null then v_after:=v_before||v_data; end if;
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

comment on function public.validate_sap_import_batch(uuid)
  is 'Validação SAP real: detecta duplicidade, aceita fallback de IPI do produto e exige MVA/ICMS interno apenas quando has_st=true.';

commit;
