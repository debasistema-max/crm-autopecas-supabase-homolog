begin;

create or replace function public.create_fiscal_tax_rule_version(
  source_rule_id uuid,
  new_effective_from date,
  reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  source_rule public.fiscal_tax_rules;
  new_rule public.fiscal_tax_rules;
begin
  actor := public.commercial_active_profile();
  if actor.id is null or not public.can_manage_fiscal_tax_rules() then raise exception 'SEM_PERMISSAO'; end if;
  if nullif(btrim(reason), '') is null then raise exception 'MOTIVO_OBRIGATORIO'; end if;

  select * into source_rule from public.fiscal_tax_rules where id=source_rule_id for update;
  if source_rule.id is null then raise exception 'REGRA_FISCAL_NAO_ENCONTRADA'; end if;
  if new_effective_from is null or new_effective_from <= source_rule.effective_from then
    raise exception 'NOVA_VIGENCIA_DEVE_SER_POSTERIOR';
  end if;
  if exists(
    select 1 from public.fiscal_tax_rules r
    where r.ncm=source_rule.ncm and r.uf_origem=source_rule.uf_origem
      and r.uf_destino=source_rule.uf_destino and r.operation_type=source_rule.operation_type
      and r.customer_type=source_rule.customer_type and r.effective_from=new_effective_from
  ) then
    raise exception 'VERSAO_FISCAL_JA_EXISTE_NA_DATA';
  end if;

  insert into public.fiscal_tax_rules(
    ncm, uf_origem, uf_destino, operation_type, customer_type,
    icms_percent, icms_st_percent, mva_percent, ipi_percent,
    pis_percent, cofins_percent, fcp_percent,
    cest, cfop, cst_code, has_st,
    interstate_icms_rate, internal_icms_rate, mva_rate, ipi_rate,
    pis_rate, cofins_rate, fcp_rate, base_reduction_rate,
    freight_rate, insurance_rate, other_expenses_rate,
    source, source_code, resale_calculation_method, resale_icms_st_rate,
    resale_include_own_icms, effective_from, effective_to, active,
    lifecycle_status, legal_basis, change_reason, supersedes_rule_id,
    created_by, updated_by
  ) values(
    source_rule.ncm, source_rule.uf_origem, source_rule.uf_destino,
    source_rule.operation_type, source_rule.customer_type,
    source_rule.icms_percent, source_rule.icms_st_percent, source_rule.mva_percent,
    source_rule.ipi_percent, source_rule.pis_percent, source_rule.cofins_percent,
    source_rule.fcp_percent, source_rule.cest, source_rule.cfop, source_rule.cst_code,
    source_rule.has_st, source_rule.interstate_icms_rate, source_rule.internal_icms_rate,
    source_rule.mva_rate, source_rule.ipi_rate, source_rule.pis_rate,
    source_rule.cofins_rate, source_rule.fcp_rate, source_rule.base_reduction_rate,
    source_rule.freight_rate, source_rule.insurance_rate, source_rule.other_expenses_rate,
    'MANUAL_VERSION', source_rule.source_code, source_rule.resale_calculation_method,
    source_rule.resale_icms_st_rate, source_rule.resale_include_own_icms,
    new_effective_from, source_rule.effective_to, false,
    'DRAFT', null, btrim(reason), source_rule.id, actor.id, actor.id
  ) returning * into new_rule;

  insert into public.logs(user_id, usuario, acao, entidade, id_entidade, dados_anteriores, dados_novos)
  values(actor.id, actor.usuario, 'CRIAR_VERSAO_REGRA_FISCAL', 'fiscal_tax_rules', new_rule.id::text,
    to_jsonb(source_rule), to_jsonb(new_rule));
  return to_jsonb(new_rule);
end;
$$;

create or replace function public.transition_fiscal_tax_rule(
  target_id uuid,
  target_status text,
  reason text,
  legal_basis_text text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  current_rule public.fiscal_tax_rules;
  previous_rule public.fiscal_tax_rules;
  saved_rule public.fiscal_tax_rules;
  normalized_status text := upper(btrim(coalesce(target_status, '')));
  normalized_reason text := nullif(btrim(reason), '');
  normalized_legal_basis text;
begin
  actor := public.commercial_active_profile();
  if actor.id is null or not public.can_manage_fiscal_tax_rules() then raise exception 'SEM_PERMISSAO'; end if;
  if normalized_status not in ('DRAFT','VALIDATED','ACTIVE','REVIEW_REQUIRED','EXPIRED','DISABLED') then
    raise exception 'STATUS_FISCAL_INVALIDO';
  end if;
  if normalized_reason is null then raise exception 'MOTIVO_OBRIGATORIO'; end if;

  select * into current_rule from public.fiscal_tax_rules where id=target_id for update;
  if current_rule.id is null then raise exception 'REGRA_FISCAL_NAO_ENCONTRADA'; end if;
  normalized_legal_basis := coalesce(nullif(btrim(legal_basis_text), ''), current_rule.legal_basis);
  perform set_config('app.fiscal_transition', '1', true);

  if normalized_status = 'VALIDATED' then
    if current_rule.lifecycle_status not in ('DRAFT','REVIEW_REQUIRED') then
      raise exception 'TRANSICAO_FISCAL_INVALIDA';
    end if;
    if normalized_legal_basis is null then raise exception 'FUNDAMENTO_LEGAL_OBRIGATORIO'; end if;
    update public.fiscal_tax_rules
    set lifecycle_status='VALIDATED', active=false, legal_basis=normalized_legal_basis,
        change_reason=normalized_reason, validated_at=now(), validated_by=actor.id,
        activated_at=null, activated_by=null, updated_by=actor.id
    where id=target_id returning * into saved_rule;

  elsif normalized_status = 'ACTIVE' then
    if current_rule.lifecycle_status not in ('VALIDATED','REVIEW_REQUIRED') then
      raise exception 'REGRA_DEVE_SER_VALIDADA_ANTES_DE_ATIVAR';
    end if;
    if normalized_legal_basis is null then raise exception 'FUNDAMENTO_LEGAL_OBRIGATORIO'; end if;

    if current_rule.lifecycle_status='REVIEW_REQUIRED' then
      current_rule.validated_at := now();
      current_rule.validated_by := actor.id;
    elsif current_rule.validated_at is null or current_rule.validated_by is null then
      raise exception 'VALIDACAO_FISCAL_INCOMPLETA';
    end if;

    for previous_rule in
      select r.*
      from public.fiscal_tax_rules r
      where r.id<>current_rule.id and r.active
        and r.ncm=current_rule.ncm and r.uf_origem=current_rule.uf_origem
        and r.uf_destino=current_rule.uf_destino
        and r.operation_type=current_rule.operation_type
        and r.customer_type=current_rule.customer_type
        and daterange(r.effective_from, coalesce(r.effective_to,'infinity'::date), '[]')
          && daterange(current_rule.effective_from, coalesce(current_rule.effective_to,'infinity'::date), '[]')
      order by r.effective_from
      for update
    loop
      if previous_rule.effective_from >= current_rule.effective_from then
        raise exception 'VIGENCIA_NOVA_NAO_E_POSTERIOR_A_REGRA_ATIVA';
      end if;
      update public.fiscal_tax_rules
      set effective_to=current_rule.effective_from-1,
          lifecycle_status='EXPIRED', active=true,
          change_reason='Substituída pela regra '||current_rule.id::text||': '||normalized_reason,
          updated_by=actor.id
      where id=previous_rule.id;
    end loop;

    update public.fiscal_tax_rules
    set lifecycle_status='ACTIVE', active=true, legal_basis=normalized_legal_basis,
        change_reason=normalized_reason,
        validated_at=coalesce(current_rule.validated_at, now()),
        validated_by=coalesce(current_rule.validated_by, actor.id),
        activated_at=now(), activated_by=actor.id, updated_by=actor.id
    where id=target_id returning * into saved_rule;

  elsif normalized_status = 'REVIEW_REQUIRED' then
    if current_rule.lifecycle_status not in ('ACTIVE','VALIDATED') then raise exception 'TRANSICAO_FISCAL_INVALIDA'; end if;
    update public.fiscal_tax_rules
    set lifecycle_status='REVIEW_REQUIRED', active=current_rule.active,
        change_reason=normalized_reason, review_required_at=now(),
        review_required_by=actor.id, updated_by=actor.id
    where id=target_id returning * into saved_rule;

  elsif normalized_status = 'DISABLED' then
    update public.fiscal_tax_rules
    set lifecycle_status='DISABLED', active=false, change_reason=normalized_reason,
        disabled_at=now(), disabled_by=actor.id, updated_by=actor.id
    where id=target_id returning * into saved_rule;

  elsif normalized_status = 'EXPIRED' then
    if current_rule.effective_to is null or current_rule.effective_to >= current_date then
      raise exception 'REGRA_AINDA_NAO_EXPIRADA';
    end if;
    update public.fiscal_tax_rules
    set lifecycle_status='EXPIRED', active=true, change_reason=normalized_reason,
        updated_by=actor.id
    where id=target_id returning * into saved_rule;

  elsif normalized_status = 'DRAFT' then
    if current_rule.lifecycle_status<>'DISABLED' then raise exception 'TRANSICAO_FISCAL_INVALIDA'; end if;
    update public.fiscal_tax_rules
    set lifecycle_status='DRAFT', active=false, change_reason=normalized_reason,
        validated_at=null, validated_by=null, activated_at=null, activated_by=null,
        updated_by=actor.id
    where id=target_id returning * into saved_rule;
  end if;

  insert into public.logs(user_id, usuario, acao, entidade, id_entidade, dados_anteriores, dados_novos)
  values(actor.id, actor.usuario, 'TRANSICAO_REGRA_FISCAL_'||normalized_status,
    'fiscal_tax_rules', target_id::text, to_jsonb(current_rule), to_jsonb(saved_rule));
  return to_jsonb(saved_rule);
end;
$$;

create or replace function public.save_fiscal_tax_rule(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  v_id uuid := nullif(payload->>'id', '')::uuid;
  v_current public.fiscal_tax_rules;
  v_saved public.fiscal_tax_rules;
  v_before jsonb;
  v_ncm text;
  v_origin text;
  v_destination text;
  v_operation text;
  v_customer text;
  v_has_st boolean;
  v_effective_from date;
  v_effective_to date;
  v_icms numeric;
  v_icms_st numeric;
  v_mva numeric;
  v_ipi numeric;
  v_pis numeric;
  v_cofins numeric;
  v_fcp numeric;
  v_reduction numeric;
  v_freight numeric;
  v_insurance numeric;
  v_other numeric;
  v_resale_rate numeric;
  v_cest text;
begin
  actor := public.commercial_active_profile();
  if actor.id is null or not public.can_manage_fiscal_tax_rules() then raise exception 'SEM_PERMISSAO'; end if;

  if v_id is not null then
    select * into v_current from public.fiscal_tax_rules where id=v_id for update;
    if v_current.id is null then raise exception 'REGRA_FISCAL_NAO_ENCONTRADA'; end if;
  end if;

  v_effective_from := coalesce(nullif(payload->>'effective_from','')::date, v_current.effective_from, current_date);
  v_ncm := public.normalize_ncm(coalesce(nullif(btrim(payload->>'ncm'),''), v_current.ncm));
  v_origin := public.normalize_fiscal_uf(coalesce(nullif(btrim(payload->>'uf_origem'),''), v_current.uf_origem));
  v_destination := public.normalize_fiscal_uf(coalesce(nullif(btrim(payload->>'uf_destino'),''), v_current.uf_destino));
  v_operation := upper(coalesce(nullif(btrim(payload->>'operation_type'),''), v_current.operation_type, 'VENDA'));
  v_customer := upper(coalesce(nullif(btrim(payload->>'customer_type'),''), v_current.customer_type, 'GERAL'));

  if v_id is null then
    select * into v_current from public.fiscal_tax_rules r
    where r.ncm=v_ncm and r.uf_origem=v_origin and r.uf_destino=v_destination
      and r.operation_type=v_operation and r.customer_type=v_customer
      and r.effective_from=v_effective_from
    limit 1 for update;
    v_id := v_current.id;
  end if;

  if v_current.id is not null and v_current.active then raise exception 'REGRA_FISCAL_ATIVA_IMUTAVEL'; end if;
  v_before := case when v_current.id is null then null else to_jsonb(v_current) end;
  if v_current.id is null and not (payload ? 'has_st') then raise exception 'HAS_ST_OBRIGATORIO'; end if;
  v_has_st := case when nullif(payload->>'has_st','') is not null
    then (payload->>'has_st')::boolean else coalesce(v_current.has_st,false) end;

  v_icms := case when nullif(payload->>'icms_percent','') is not null then (payload->>'icms_percent')::numeric else v_current.icms_percent end;
  v_icms_st := case when nullif(payload->>'icms_st_percent','') is not null then (payload->>'icms_st_percent')::numeric else v_current.icms_st_percent end;
  v_mva := case when nullif(payload->>'mva_percent','') is not null then (payload->>'mva_percent')::numeric else v_current.mva_percent end;
  v_ipi := case when nullif(payload->>'ipi_percent','') is not null then (payload->>'ipi_percent')::numeric else v_current.ipi_percent end;
  v_pis := case when nullif(payload->>'pis_percent','') is not null then (payload->>'pis_percent')::numeric else v_current.pis_percent end;
  v_cofins := case when nullif(payload->>'cofins_percent','') is not null then (payload->>'cofins_percent')::numeric else v_current.cofins_percent end;
  v_fcp := case when nullif(payload->>'fcp_percent','') is not null then (payload->>'fcp_percent')::numeric else v_current.fcp_percent end;
  v_reduction := case when nullif(payload->>'base_reduction_percent','') is not null then (payload->>'base_reduction_percent')::numeric/100 else v_current.base_reduction_rate end;
  v_freight := case when nullif(payload->>'freight_percent','') is not null then (payload->>'freight_percent')::numeric/100 else v_current.freight_rate end;
  v_insurance := case when nullif(payload->>'insurance_percent','') is not null then (payload->>'insurance_percent')::numeric/100 else v_current.insurance_rate end;
  v_other := case when nullif(payload->>'other_expenses_percent','') is not null then (payload->>'other_expenses_percent')::numeric/100 else v_current.other_expenses_rate end;
  v_resale_rate := case when nullif(payload->>'resale_icms_st_percent','') is not null then (payload->>'resale_icms_st_percent')::numeric/100 else v_current.resale_icms_st_rate end;
  v_effective_to := case
    when coalesce((payload->>'clear_effective_to')::boolean,false) then null
    when nullif(payload->>'effective_to','') is not null then (payload->>'effective_to')::date
    else v_current.effective_to end;
  v_cest := case when nullif(payload->>'cest','') is not null then public.normalize_cest(payload->>'cest') else v_current.cest end;

  if v_ncm is null then raise exception 'NCM_INVALIDO'; end if;
  if v_origin is null or v_destination is null then raise exception 'UF_INVALIDA'; end if;
  if nullif(payload->>'cest','') is not null and v_cest is null then raise exception 'CEST_INVALIDO'; end if;
  if v_icms is null then raise exception 'ICMS_OBRIGATORIO'; end if;
  if v_has_st and v_icms_st is null then raise exception 'ICMS_INTERNO_OBRIGATORIO_PARA_ST'; end if;
  if v_has_st and v_mva is null then raise exception 'MVA_OBRIGATORIA_PARA_ST'; end if;
  if v_effective_to is not null and v_effective_to<v_effective_from then raise exception 'VIGENCIA_FISCAL_INVALIDA'; end if;
  if v_icms not between 0 and 100
     or (v_icms_st is not null and v_icms_st not between 0 and 100)
     or (v_mva is not null and v_mva not between 0 and 1000)
     or (v_ipi is not null and v_ipi not between 0 and 100)
     or (v_pis is not null and v_pis not between 0 and 100)
     or (v_cofins is not null and v_cofins not between 0 and 100)
     or (v_fcp is not null and v_fcp not between 0 and 100)
     or (v_reduction is not null and v_reduction not between 0 and 1)
     or (v_freight is not null and v_freight not between 0 and 10)
     or (v_insurance is not null and v_insurance not between 0 and 10)
     or (v_other is not null and v_other not between 0 and 10)
     or (v_resale_rate is not null and v_resale_rate not between 0 and 1)
  then raise exception 'ALIQUOTA_FORA_DA_FAIXA'; end if;

  insert into public.fiscal_tax_rules(
    id,ncm,uf_origem,uf_destino,operation_type,customer_type,cest,cfop,cst_code,has_st,
    icms_percent,icms_st_percent,mva_percent,ipi_percent,pis_percent,cofins_percent,fcp_percent,
    base_reduction_rate,freight_rate,insurance_rate,other_expenses_rate,
    resale_calculation_method,resale_icms_st_rate,resale_include_own_icms,
    effective_from,effective_to,active,lifecycle_status,legal_basis,change_reason,
    supersedes_rule_id,notes,source,created_by,updated_by
  ) values(
    coalesce(v_id,gen_random_uuid()),v_ncm,v_origin,v_destination,v_operation,v_customer,
    v_cest,coalesce(nullif(btrim(payload->>'cfop'),''),v_current.cfop),
    coalesce(nullif(btrim(payload->>'cst_code'),''),v_current.cst_code),
    v_has_st,v_icms,v_icms_st,v_mva,v_ipi,v_pis,v_cofins,v_fcp,
    v_reduction,v_freight,v_insurance,v_other,
    coalesce(nullif(upper(btrim(payload->>'resale_calculation_method')),''),v_current.resale_calculation_method,'MVA_ST'),
    v_resale_rate,
    case when payload ? 'resale_include_own_icms' then coalesce((payload->>'resale_include_own_icms')::boolean,false)
      else coalesce(v_current.resale_include_own_icms,false) end,
    v_effective_from,v_effective_to,false,'DRAFT',
    coalesce(nullif(btrim(payload->>'legal_basis'),''),v_current.legal_basis),
    coalesce(nullif(btrim(payload->>'change_reason'),''),v_current.change_reason,'Rascunho criado manualmente.'),
    coalesce(nullif(payload->>'supersedes_rule_id','')::uuid,v_current.supersedes_rule_id),
    coalesce(nullif(btrim(payload->>'notes'),''),v_current.notes),
    'MANUAL',coalesce(v_current.created_by,actor.id),actor.id
  )
  on conflict(id) do update set
    ncm=excluded.ncm,uf_origem=excluded.uf_origem,uf_destino=excluded.uf_destino,
    operation_type=excluded.operation_type,customer_type=excluded.customer_type,
    cest=excluded.cest,cfop=excluded.cfop,cst_code=excluded.cst_code,has_st=excluded.has_st,
    icms_percent=excluded.icms_percent,icms_st_percent=excluded.icms_st_percent,
    mva_percent=excluded.mva_percent,ipi_percent=excluded.ipi_percent,
    pis_percent=excluded.pis_percent,cofins_percent=excluded.cofins_percent,fcp_percent=excluded.fcp_percent,
    base_reduction_rate=excluded.base_reduction_rate,freight_rate=excluded.freight_rate,
    insurance_rate=excluded.insurance_rate,other_expenses_rate=excluded.other_expenses_rate,
    resale_calculation_method=excluded.resale_calculation_method,
    resale_icms_st_rate=excluded.resale_icms_st_rate,
    resale_include_own_icms=excluded.resale_include_own_icms,
    effective_from=excluded.effective_from,effective_to=excluded.effective_to,
    legal_basis=excluded.legal_basis,change_reason=excluded.change_reason,
    supersedes_rule_id=excluded.supersedes_rule_id,notes=excluded.notes,
    source='MANUAL',updated_by=actor.id,updated_at=now()
  returning * into v_saved;

  insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_anteriores,dados_novos)
  values(actor.id,actor.usuario,'SALVAR_RASCUNHO_REGRA_FISCAL','fiscal_tax_rules',v_saved.id::text,v_before,to_jsonb(v_saved));
  return to_jsonb(v_saved);
exception
  when invalid_text_representation or numeric_value_out_of_range then raise exception 'VALOR_FISCAL_INVALIDO';
end;
$$;

create or replace function public.list_fiscal_tax_rules(filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  v_ncm text := nullif(regexp_replace(coalesce(filters->>'ncm',''), '\D', '', 'g'), '');
  v_uf_destino text := nullif(upper(btrim(coalesce(filters->>'uf_destino',filters->>'uf',''))), '');
  v_active text := lower(btrim(coalesce(filters->>'active','')));
  v_lifecycle text := nullif(upper(btrim(coalesce(filters->>'lifecycle_status',''))), '');
  v_rows jsonb;
begin
  actor := public.commercial_active_profile();
  if actor.id is null or not public.can_manage_fiscal_tax_rules() then raise exception 'SEM_PERMISSAO'; end if;
  select coalesce(jsonb_agg(to_jsonb(rows) order by rows.ncm,rows.uf_origem,rows.uf_destino,rows.effective_from desc),'[]'::jsonb)
  into v_rows
  from (
    select * from public.fiscal_tax_rules r
    where (v_ncm is null or r.ncm=v_ncm)
      and (v_uf_destino is null or r.uf_destino=v_uf_destino)
      and (v_lifecycle is null or r.lifecycle_status=v_lifecycle)
      and (v_active='' or (v_active in ('true','1','sim','ativo') and r.active)
        or (v_active in ('false','0','nao','inativo') and not r.active))
    order by r.ncm,r.uf_origem,r.uf_destino,r.effective_from desc
    limit 500
  ) rows;
  return v_rows;
end;
$$;

create or replace function public.list_fiscal_tax_rule_versions(target_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  result jsonb;
begin
  actor := public.commercial_active_profile();
  if actor.id is null or not public.can_manage_fiscal_tax_rules() then raise exception 'SEM_PERMISSAO'; end if;
  select coalesce(jsonb_agg(to_jsonb(v) order by v.rule_version desc,v.changed_at desc),'[]'::jsonb)
  into result from public.fiscal_tax_rule_versions v where v.rule_id=target_id;
  return result;
end;
$$;

create or replace function public.delete_fiscal_tax_rule(target_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
begin
  result := public.transition_fiscal_tax_rule(
    target_id, 'DISABLED', 'Desativada pelo painel fiscal; histórico preservado.', null
  );
  return jsonb_build_object('deleted',false,'disabled',true,'id',target_id,'rule',result);
end;
$$;

create or replace function public.guard_commercial_item_fiscal_snapshot()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  governance jsonb;
  warnings jsonb;
begin
  if new.fiscal_details is not null
     and coalesce(new.fiscal_status,'') not in ('OK','OK_SEM_ST') then
    raise exception using
      errcode='23514',
      message=format('CALCULO_FISCAL_INVALIDO: produto %s, status %s.',
        coalesce(new.codigo,'NAO_INFORMADO'),coalesce(new.fiscal_status,'NAO_INFORMADO')),
      hint='Corrija NCM, preco base e regra fiscal antes de salvar o documento.';
  end if;

  if new.fiscal_details is not null and new.fiscal_tax_rule_id is not null then
    select jsonb_build_object(
      'rule_lifecycle_status',r.lifecycle_status,
      'rule_legal_basis',r.legal_basis,
      'rule_change_reason',r.change_reason,
      'rule_validated_at',r.validated_at,
      'rule_activated_at',r.activated_at
    ) into governance
    from public.fiscal_tax_rules r where r.id=new.fiscal_tax_rule_id;

    if governance is not null then
      new.fiscal_details := new.fiscal_details || governance;
      if governance->>'rule_lifecycle_status'='REVIEW_REQUIRED' then
        warnings := coalesce(new.fiscal_details->'warnings','[]'::jsonb);
        if not (warnings ? 'REQUIRES_FISCAL_VALIDATION') then
          new.fiscal_details := jsonb_set(
            new.fiscal_details,'{warnings}',warnings||jsonb_build_array('REQUIRES_FISCAL_VALIDATION'),true
          );
        end if;
      end if;
    end if;
  end if;
  return new;
end;
$$;

do $$
declare
  signature text;
begin
  for signature in
    select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname=any(array[
      'create_fiscal_tax_rule_version','transition_fiscal_tax_rule','save_fiscal_tax_rule',
      'list_fiscal_tax_rules','list_fiscal_tax_rule_versions','delete_fiscal_tax_rule',
      'guard_commercial_item_fiscal_snapshot'
    ])
  loop
    execute format('revoke all privileges on function %s from public',signature);
    if exists(select 1 from pg_roles where rolname='anon') then execute format('revoke all privileges on function %s from anon',signature); end if;
    if exists(select 1 from pg_roles where rolname='authenticated') then execute format('grant execute on function %s to authenticated',signature); end if;
  end loop;
end;
$$;

comment on function public.create_fiscal_tax_rule_version(uuid,date,text)
  is 'Cria rascunho versionado sem alterar a regra vigente.';
comment on function public.transition_fiscal_tax_rule(uuid,text,text,text)
  is 'Executa validação, ativação, revisão, expiração ou desativação auditada da regra.';
comment on function public.delete_fiscal_tax_rule(uuid)
  is 'Compatibilidade: desativa a regra e preserva todo o histórico; não executa DELETE.';
comment on function public.guard_commercial_item_fiscal_snapshot()
  is 'Bloqueia cálculo inválido e anexa ao snapshot a governança da regra usada.';

commit;
