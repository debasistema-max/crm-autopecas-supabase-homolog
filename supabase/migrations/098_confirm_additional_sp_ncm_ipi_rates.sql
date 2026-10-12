begin;

-- Segundo lote de NCMs SP-SP validado na homologacao em 06/10/2026.
-- Para todos os produtos atuais destes NCMs, o IPI calculado pelo motor com a
-- aliquota abaixo coincidiu com a referencia da planilha dentro da tolerancia
-- operacional de R$ 0,02. A planilha permanece somente como evidencia; o
-- preco operacional continua sendo calculado pelo motor fiscal do CRM.
do $$
declare
  v_actor_id uuid;
  v_expected integer;
begin
  select p.id into v_actor_id
  from public.profiles p
  where p.ativo and p.perfil::text = 'ADMIN'
  order by case when p.usuario = 'admin' then 0 else 1 end, p.updated_at desc
  limit 1;

  if v_actor_id is null then
    raise exception 'ADMIN_ATIVO_NAO_ENCONTRADO';
  end if;

  perform set_config('app.fiscal_transition', '1', true);

  create temporary table confirmed_sp_ipi_rates_098(
    ncm text primary key,
    ipi_rate numeric(12,8) not null,
    source_code text not null
  ) on commit drop;

  insert into confirmed_sp_ipi_rates_098(ncm, ipi_rate, source_code) values
    ('87088000', 0.03250000, '539'),
    ('87082999', 0.03250000, '512'),
    ('85122011', 0.09750000, '296'),
    ('87089483', 0.03250000, '593'),
    ('87082993', 0.03250000, '485'),
    ('87089990', 0.03250000, '647'),
    ('87081000', 0.03250000, '431'),
    ('87082991', 0.03250000, '458'),
    ('85122021', 0.09750000, '350'),
    ('87089100', 0.03250000, '566'),
    ('84212300', 0.05200000, '107'),
    ('84821010', 0.07800000, '188');

  -- A homologacao possui uma regra MANUAL legada de 5% para o NCM 87089990,
  -- iniciada em 16/08, e a regra SAP sucessora de 3,25%, iniciada em 25/08.
  -- Encerra somente a vigencia da regra legada na vespera da sucessora. O
  -- registro e seu historico sao preservados; em producao, onde ele nao existe,
  -- esta atualizacao nao afeta nenhuma linha.
  update public.fiscal_tax_rules r
  set effective_to = date '2026-08-24',
      change_reason = 'Vigencia encerrada antes da regra SAP sucessora validada contra a referencia Excel.',
      updated_by = v_actor_id,
      updated_at = now(),
      rule_version = r.rule_version + 1
  where r.ncm = '87089990'
    and r.uf_origem = 'SP'
    and r.uf_destino = 'SP'
    and r.operation_type = 'VENDA'
    and r.customer_type = 'GERAL'
    and r.source = 'MANUAL'
    and r.ipi_rate = 0.05000000
    and r.effective_from = date '2026-08-16'
    and r.effective_to is null
    and r.active
    and exists(
      select 1
      from public.fiscal_tax_rules successor
      where successor.ncm = r.ncm
        and successor.uf_origem = r.uf_origem
        and successor.uf_destino = r.uf_destino
        and successor.operation_type = r.operation_type
        and successor.customer_type = r.customer_type
        and successor.source = 'SAP_FISCAL'
        and successor.source_code = '647'
        and successor.ipi_rate = 0.03250000
        and successor.effective_from = date '2026-08-25'
        and successor.active
    );

  -- Na homologacao as regras vieram da carga SAP como REVIEW_REQUIRED. A
  -- atualizacao preserva a identidade da regra e registra a validacao.
  update public.fiscal_tax_rules r
  set ipi_rate = c.ipi_rate,
      ipi_percent = c.ipi_rate * 100,
      source = 'SAP_FISCAL',
      source_code = c.source_code,
      lifecycle_status = 'ACTIVE',
      active = true,
      legal_basis = 'Regra SAP validada contra a referencia Excel SP-SP em 06/10/2026; aplicacao comercial somente de IPI.',
      change_reason = 'IPI confirmado pelo comparativo integral do motor CRM com a planilha na homologacao.',
      validated_at = now(),
      validated_by = v_actor_id,
      activated_at = now(),
      activated_by = v_actor_id,
      review_required_at = null,
      review_required_by = null,
      updated_by = v_actor_id,
      updated_at = now(),
      rule_version = r.rule_version + 1
  from confirmed_sp_ipi_rates_098 c
  where r.ncm = c.ncm
    and r.uf_origem = 'SP'
    and r.uf_destino = 'SP'
    and r.operation_type = 'VENDA'
    and r.customer_type = 'GERAL'
    and r.active
    and r.effective_from <= date '2026-10-01'
    and (r.effective_to is null or r.effective_to >= date '2026-10-01')
    and (
      r.ipi_rate is distinct from c.ipi_rate
      or r.source is distinct from 'SAP_FISCAL'
      or r.source_code is distinct from c.source_code
      or r.lifecycle_status <> 'ACTIVE'
      or r.legal_basis is distinct from 'Regra SAP validada contra a referencia Excel SP-SP em 06/10/2026; aplicacao comercial somente de IPI.'
    );

  -- O repositorio canonico de producao nao possuia as regras em revisao da
  -- homologacao. Para esses casos cria somente a regra minima SP-SP necessaria
  -- para a politica base + IPI, sem ICMS-ST no preco comercial.
  insert into public.fiscal_tax_rules(
    ncm, uf_origem, uf_destino, operation_type, customer_type,
    icms_percent, ipi_percent, has_st,
    interstate_icms_rate, ipi_rate,
    source, source_code, effective_from, active,
    lifecycle_status, legal_basis, change_reason,
    validated_at, validated_by, activated_at, activated_by,
    created_by, updated_by
  )
  select
    c.ncm, 'SP', 'SP', 'VENDA', 'GERAL',
    0, c.ipi_rate * 100, false,
    0, c.ipi_rate,
    'SAP_FISCAL', c.source_code, date '2026-10-01', true,
    'ACTIVE',
    'Regra SAP validada contra a referencia Excel SP-SP em 06/10/2026; aplicacao comercial somente de IPI.',
    'IPI confirmado pelo comparativo integral do motor CRM com a planilha na homologacao.',
    now(), v_actor_id, now(), v_actor_id,
    v_actor_id, v_actor_id
  from confirmed_sp_ipi_rates_098 c
  where not exists(
    select 1
    from public.fiscal_tax_rules r
    where r.ncm = c.ncm
      and r.uf_origem = 'SP'
      and r.uf_destino = 'SP'
      and r.operation_type = 'VENDA'
      and r.customer_type = 'GERAL'
      and r.active
      and r.effective_from <= date '2026-10-01'
      and (r.effective_to is null or r.effective_to >= date '2026-10-01')
  );

  select count(*) into v_expected
  from confirmed_sp_ipi_rates_098 c
  where exists(
    select 1
    from public.fiscal_tax_rules r
    where r.ncm = c.ncm
      and r.uf_origem = 'SP'
      and r.uf_destino = 'SP'
      and r.operation_type = 'VENDA'
      and r.customer_type = 'GERAL'
      and r.active
      and r.lifecycle_status = 'ACTIVE'
      and r.ipi_rate = c.ipi_rate
      and r.source = 'SAP_FISCAL'
      and r.source_code = c.source_code
      and r.effective_from <= date '2026-10-01'
      and (r.effective_to is null or r.effective_to >= date '2026-10-01')
  );

  if v_expected <> 12 then
    raise exception 'CONFIRMACAO_IPI_SP_098_INCOMPLETA: % de 12 regras', v_expected;
  end if;
end;
$$;

commit;
