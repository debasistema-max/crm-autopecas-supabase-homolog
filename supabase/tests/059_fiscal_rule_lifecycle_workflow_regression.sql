begin;

select set_config('request.jwt.claim.sub',(
  select id::text from public.profiles where perfil='ADMIN' and ativo order by created_at limit 1
),true);

do $$
declare
  actor_id uuid := auth.uid();
  original_profile public.user_profile;
  first_rule jsonb;
  next_rule jsonb;
  result jsonb;
  first_id uuid;
  next_id uuid;
  historical public.fiscal_tax_rules;
begin
  if actor_id is null then raise exception 'ADMIN_DE_TESTE_AUSENTE'; end if;
  if has_function_privilege('anon','public.transition_fiscal_tax_rule(uuid,text,text,text)','execute') then
    raise exception 'TRANSICAO_FISCAL_EXPOSTA_AO_ANON';
  end if;
  if not has_function_privilege('authenticated','public.transition_fiscal_tax_rule(uuid,text,text,text)','execute') then
    raise exception 'TRANSICAO_FISCAL_INDISPONIVEL_AO_AUTENTICADO';
  end if;
  if has_table_privilege('authenticated','public.fiscal_tax_rule_versions','select') then
    raise exception 'HISTORICO_FISCAL_EXPOSTO_DIRETAMENTE';
  end if;

  first_rule:=public.save_fiscal_tax_rule(jsonb_build_object(
    'ncm','99999992','uf_origem','PR','uf_destino','SP',
    'operation_type','VENDA','customer_type','LIFECYCLE_TEST',
    'icms_percent',12,'icms_st_percent',18,'mva_percent',50,'ipi_percent',5,
    'has_st',true,'effective_from',(current_date-10)::text,
    'change_reason','Criação do golden test de ciclo de vida.'
  ));
  first_id:=(first_rule->>'id')::uuid;
  if (first_rule->>'active')::boolean or first_rule->>'lifecycle_status'<>'DRAFT' then
    raise exception 'NOVA_REGRA_NAO_NASCEU_RASCUNHO: %',first_rule;
  end if;

  begin
    perform public.transition_fiscal_tax_rule(first_id,'VALIDATED','Tentativa sem fundamento.',null);
    raise exception 'VALIDOU_SEM_FUNDAMENTO';
  exception when others then
    if sqlerrm not like '%FUNDAMENTO_LEGAL_OBRIGATORIO%' then raise; end if;
  end;

  result:=public.transition_fiscal_tax_rule(
    first_id,'VALIDATED','Cenário conferido no teste automatizado.',
    'REFERENCIA_OFICIAL_DE_TESTE_SEM_VALOR_LEGAL'
  );
  if result->>'lifecycle_status'<>'VALIDATED' or (result->>'active')::boolean then
    raise exception 'VALIDACAO_NAO_CONTROLADA: %',result;
  end if;

  result:=public.transition_fiscal_tax_rule(
    first_id,'ACTIVE','Ativação controlada do cenário de teste.',null
  );
  if result->>'lifecycle_status'<>'ACTIVE' or not (result->>'active')::boolean then
    raise exception 'ATIVACAO_FALHOU: %',result;
  end if;

  begin
    perform public.save_fiscal_tax_rule(jsonb_build_object('id',first_id,'mva_percent',55));
    raise exception 'REGRA_ATIVA_FOI_EDITADA';
  exception when others then
    if sqlerrm not like '%REGRA_FISCAL_ATIVA_IMUTAVEL%' then raise; end if;
  end;

  next_rule:=public.create_fiscal_tax_rule_version(
    first_id,current_date,'Nova vigência para comprovar substituição sem perda histórica.'
  );
  next_id:=(next_rule->>'id')::uuid;
  if next_rule->>'lifecycle_status'<>'DRAFT' or (next_rule->>'active')::boolean
     or (next_rule->>'supersedes_rule_id')::uuid<>first_id then
    raise exception 'CLONE_VERSIONADO_INVALIDO: %',next_rule;
  end if;

  next_rule:=public.save_fiscal_tax_rule(jsonb_build_object(
    'id',next_id,'mva_percent',60,'change_reason','MVA alterada apenas no rascunho sucessor.'
  ));
  perform public.transition_fiscal_tax_rule(
    next_id,'VALIDATED','Segunda versão conferida.',
    'SEGUNDA_REFERENCIA_OFICIAL_DE_TESTE_SEM_VALOR_LEGAL'
  );
  result:=public.transition_fiscal_tax_rule(
    next_id,'ACTIVE','Substituição atômica da versão anterior.',null
  );

  if result->>'lifecycle_status'<>'ACTIVE' or not (result->>'active')::boolean then
    raise exception 'NOVA_VERSAO_NAO_ATIVADA: %',result;
  end if;
  if not exists(
    select 1 from public.fiscal_tax_rules
    where id=first_id and lifecycle_status='EXPIRED' and active
      and effective_to=current_date-1
  ) then raise exception 'VERSAO_ANTERIOR_NAO_FOI_ENCERRADA'; end if;

  historical:=public.resolve_fiscal_tax_rule('99999992','PR','SP','LIFECYCLE_TEST',current_date-5);
  if historical.id is distinct from first_id then raise exception 'HISTORICO_NAO_RESOLVEU_VERSAO_ANTERIOR'; end if;
  historical:=public.resolve_fiscal_tax_rule('99999992','PR','SP','LIFECYCLE_TEST',current_date);
  if historical.id is distinct from next_id then raise exception 'DATA_ATUAL_NAO_RESOLVEU_NOVA_VERSAO'; end if;

  if jsonb_array_length(public.list_fiscal_tax_rule_versions(next_id))<4 then
    raise exception 'HISTORICO_DA_NOVA_VERSAO_INCOMPLETO';
  end if;

  result:=public.delete_fiscal_tax_rule(next_id);
  if not coalesce((result->>'disabled')::boolean,false)
     or not exists(select 1 from public.fiscal_tax_rules where id=next_id and lifecycle_status='DISABLED' and not active)
     or not exists(select 1 from public.fiscal_tax_rule_versions where rule_id=next_id and change_type='DISABLED') then
    raise exception 'DESATIVACAO_NAO_PRESERVOU_HISTORICO: %',result;
  end if;

  select perfil into original_profile from public.profiles where id=actor_id;
  update public.profiles set perfil='VENDEDOR' where id=actor_id;
  begin
    perform public.create_fiscal_tax_rule_version(first_id,current_date+30,'Usuário sem permissão.');
    raise exception 'VENDEDOR_ALTEROU_REGRA_FISCAL';
  exception when others then
    if sqlerrm not like '%SEM_PERMISSAO%' then raise; end if;
  end;
  update public.profiles set perfil=original_profile where id=actor_id;

  raise notice 'FISCAL_LIFECYCLE_WORKFLOW_OK';
end;
$$;

rollback;
