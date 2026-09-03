begin;

select set_config('request.jwt.claim.sub',(
  select id::text from public.profiles where perfil = 'ADMIN' and ativo order by created_at limit 1
),true);

do $$
declare
  first_rule jsonb;
  updated_rule jsonb;
  zero_rule jsonb;
  conflict_blocked boolean := false;
begin
  if public.normalize_fiscal_uf('ZZ') is not null then raise exception 'UF_FICTICIA_ACEITA'; end if;
  if public.normalize_fiscal_uf(' pr ') <> 'PR' then raise exception 'UF_BRASILEIRA_NAO_NORMALIZADA'; end if;

  first_rule := public.save_fiscal_tax_rule(jsonb_build_object(
    'ncm', '99999991', 'uf_origem', 'AC', 'uf_destino', 'AL',
    'operation_type', 'VENDA', 'customer_type', 'TESTE_056',
    'has_st', false, 'icms_percent', 12,
    'ipi_percent', '', 'pis_percent', '', 'cofins_percent', '', 'fcp_percent', '',
    'effective_from', '2026-01-01', 'effective_to', '2026-12-31', 'active', true
  ));
  if first_rule->>'pis_percent' is not null or first_rule->>'pis_rate' is not null then
    raise exception 'AUSENCIA_PIS_FOI_CONVERTIDA_EM_ZERO: %', first_rule;
  end if;

  updated_rule := public.save_fiscal_tax_rule(jsonb_build_object(
    'id', first_rule->>'id', 'ncm', '99999991', 'uf_origem', 'AC', 'uf_destino', 'AL',
    'has_st', false, 'icms_percent', 12, 'pis_percent', '', 'notes', 'ATUALIZADA'
  ));
  if updated_rule->>'pis_percent' is not null then raise exception 'VAZIO_ALTEROU_PIS_NULO'; end if;

  zero_rule := public.save_fiscal_tax_rule(jsonb_build_object(
    'id', first_rule->>'id', 'ncm', '99999991', 'uf_origem', 'AC', 'uf_destino', 'AL',
    'has_st', false, 'icms_percent', 12, 'pis_percent', 0
  ));
  if (zero_rule->>'pis_percent')::numeric <> 0 or (zero_rule->>'pis_rate')::numeric <> 0 then
    raise exception 'ZERO_EXPLICITO_NAO_FOI_PRESERVADO: %', zero_rule;
  end if;

  begin
    perform public.save_fiscal_tax_rule(jsonb_build_object(
      'ncm', '99999991', 'uf_origem', 'AC', 'uf_destino', 'AL',
      'operation_type', 'VENDA', 'customer_type', 'TESTE_056',
      'has_st', false, 'icms_percent', 12,
      'effective_from', '2026-06-01', 'effective_to', '2027-01-01', 'active', true
    ));
  exception when exclusion_violation then
    conflict_blocked := sqlerrm like '%REGRA_FISCAL_CONFLITANTE%';
  end;
  if not conflict_blocked then raise exception 'SOBREPOSICAO_FISCAL_NAO_BLOQUEADA'; end if;
end;
$$;

rollback;
