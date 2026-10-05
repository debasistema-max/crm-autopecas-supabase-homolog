begin;

-- Confirmações fornecidas pelo usuário em 05/10/2026 para a política SP-SP
-- vigente desde 01/10/2026. O preço comercial dessa rota continua sendo
-- calculado pelo motor do CRM como preço-base + IPI (migration 090).
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
    raise exception 'ADMIN_HOMOLOGACAO_NAO_ENCONTRADO';
  end if;

  perform set_config('app.fiscal_transition', '1', true);

  create temporary table confirmed_sp_ipi_rates(
    ncm text primary key,
    ipi_rate numeric(12,8) not null
  ) on commit drop;

  insert into confirmed_sp_ipi_rates(ncm, ipi_rate) values
    ('84145990', 0.00000000),
    ('84835090', 0.07800000),
    ('84839000', 0.00000000),
    ('85122022', 0.09750000),
    ('87082913', 0.03250000),
    ('84136019', 0.00000000),
    ('84213100', 0.05200000),
    ('87089490', 0.03250000);

  -- Atualiza somente a regra ativa já existente. O flag de transição mantém o
  -- histórico versionado e evita alterar os demais parâmetros vindos do SAP.
  update public.fiscal_tax_rules r
  set ipi_rate = c.ipi_rate,
      ipi_percent = c.ipi_rate * 100,
      lifecycle_status = 'ACTIVE',
      active = true,
      legal_basis = 'Confirmação operacional do NCM e da alíquota de IPI informada pelo usuário em 05/10/2026; aplicação limitada à homologação da política SP-SP somente IPI.',
      change_reason = 'IPI confirmado para a rota SP-SP a partir de 01/10/2026.',
      validated_at = now(),
      validated_by = v_actor_id,
      activated_at = now(),
      activated_by = v_actor_id,
      review_required_at = null,
      review_required_by = null,
      updated_by = v_actor_id,
      updated_at = now(),
      rule_version = r.rule_version + 1
  from confirmed_sp_ipi_rates c
  where r.ncm = c.ncm
    and r.uf_origem = 'SP'
    and r.uf_destino = 'SP'
    and r.operation_type = 'VENDA'
    and r.customer_type = 'GERAL'
    and r.active
    and (
      r.ipi_rate is distinct from c.ipi_rate
      or r.lifecycle_status <> 'ACTIVE'
      or r.legal_basis is distinct from 'Confirmação operacional do NCM e da alíquota de IPI informada pelo usuário em 05/10/2026; aplicação limitada à homologação da política SP-SP somente IPI.'
    );

  -- Para NCMs sem regra SP-SP, cria uma regra mínima e explícita: ICMS e ST
  -- não compõem o preço comercial desta política; somente o IPI confirmado.
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
    'MANUAL_CONFIRMED', 'USER_CONFIRMED_20261005', date '2026-10-01', true,
    'ACTIVE',
    'Confirmação operacional do NCM e da alíquota de IPI informada pelo usuário em 05/10/2026; aplicação limitada à homologação da política SP-SP somente IPI.',
    'IPI confirmado para a rota SP-SP a partir de 01/10/2026.',
    now(), v_actor_id, now(), v_actor_id,
    v_actor_id, v_actor_id
  from confirmed_sp_ipi_rates c
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
  from confirmed_sp_ipi_rates c
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
      and r.effective_from <= date '2026-10-01'
      and (r.effective_to is null or r.effective_to >= date '2026-10-01')
  );

  if v_expected <> 8 then
    raise exception 'CONFIRMACAO_IPI_SP_INCOMPLETA: % de 8 regras', v_expected;
  end if;
end;
$$;

commit;
