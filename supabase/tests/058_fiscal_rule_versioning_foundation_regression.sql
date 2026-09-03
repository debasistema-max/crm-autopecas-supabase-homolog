begin;

do $$
declare
  v_rule public.fiscal_tax_rules;
  v_version bigint;
begin
  insert into public.fiscal_tax_rules(
    ncm,uf_origem,uf_destino,operation_type,customer_type,
    icms_percent,icms_st_percent,mva_percent,ipi_percent,
    has_st,effective_from,active,lifecycle_status,source,change_reason
  ) values(
    '99999991','PR','PR','VENDA','VERSION_TEST',12,null,null,0,
    false,current_date,false,'DRAFT','TEST','Criação do teste de versionamento.'
  ) returning * into v_rule;

  if v_rule.active or v_rule.lifecycle_status<>'DRAFT' then
    raise exception 'RASCUNHO_NAO_DEVE_NASCER_ATIVO: %',to_jsonb(v_rule);
  end if;
  if not exists(
    select 1 from public.fiscal_tax_rule_versions
    where rule_id=v_rule.id and rule_version=v_rule.rule_version and change_type='CREATED'
  ) then raise exception 'VERSAO_INICIAL_NAO_CAPTURADA'; end if;

  v_version:=v_rule.rule_version;
  update public.fiscal_tax_rules
  set notes='Alteração controlada de rascunho.'
  where id=v_rule.id returning rule_version into v_version;
  if v_version<=v_rule.rule_version then raise exception 'VERSAO_NAO_INCREMENTADA'; end if;
  if not exists(
    select 1 from public.fiscal_tax_rule_versions
    where rule_id=v_rule.id and rule_version=v_version and change_type='UPDATED'
  ) then raise exception 'ATUALIZACAO_NAO_VERSIONADA'; end if;

  begin
    update public.fiscal_tax_rule_versions
    set change_reason='Tentativa indevida'
    where rule_id=v_rule.id and rule_version=v_version;
    raise exception 'HISTORICO_PERMITIU_UPDATE';
  exception when sqlstate '55000' then null;
  end;

  begin
    delete from public.fiscal_tax_rule_versions where rule_id=v_rule.id;
    raise exception 'HISTORICO_PERMITIU_DELETE';
  exception when sqlstate '55000' then null;
  end;

  insert into public.fiscal_tax_rules(
    ncm,uf_origem,uf_destino,operation_type,customer_type,
    icms_percent,ipi_percent,has_st,effective_from,active,lifecycle_status,source
  ) values(
    '99999990','SP','SP','VENDA','DRAFT_ACTIVE_TEST',18,0,false,current_date,true,'DRAFT','TEST'
  ) returning * into v_rule;
  if v_rule.active or v_rule.lifecycle_status<>'DRAFT' then
    raise exception 'GOVERNANCA_PERMITIU_RASCUNHO_ATIVO';
  end if;

  raise notice 'FISCAL_VERSIONING_FOUNDATION_OK';
end;
$$;

rollback;
