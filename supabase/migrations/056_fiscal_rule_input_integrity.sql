begin;

create or replace function public.normalize_fiscal_uf(uf_text text)
returns text
language sql
immutable
parallel safe
as $$
  with normalized as (
    select upper(regexp_replace(coalesce(uf_text, ''), '[^A-Za-z]', '', 'g')) value
  )
  select case when value = any(array[
    'AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG',
    'PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO'
  ]) then value else null end
  from normalized
$$;

create or replace function public.prevent_overlapping_fiscal_rule_periods()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  normalized_ncm text := public.normalize_ncm(new.ncm);
  normalized_origin text := public.normalize_fiscal_uf(new.uf_origem);
  normalized_destination text := public.normalize_fiscal_uf(new.uf_destino);
begin
  if normalized_ncm is null then raise exception 'NCM_INVALIDO'; end if;
  if normalized_origin is null or normalized_destination is null then raise exception 'UF_INVALIDA'; end if;
  if new.effective_to is not null and new.effective_to < new.effective_from then
    raise exception 'VIGENCIA_FISCAL_INVALIDA';
  end if;

  new.ncm := normalized_ncm;
  new.uf_origem := normalized_origin;
  new.uf_destino := normalized_destination;

  if coalesce(new.active, false) then
    perform pg_advisory_xact_lock(hashtextextended(concat_ws('|',
      new.ncm, new.uf_origem, new.uf_destino, new.operation_type, new.customer_type
    ), 0));

    if exists(
      select 1
      from public.fiscal_tax_rules existing
      where existing.id <> new.id
        and existing.active
        and existing.ncm = new.ncm
        and existing.uf_origem = new.uf_origem
        and existing.uf_destino = new.uf_destino
        and existing.operation_type = new.operation_type
        and existing.customer_type = new.customer_type
        and daterange(
          existing.effective_from,
          coalesce(existing.effective_to, 'infinity'::date),
          '[]'
        ) && daterange(
          new.effective_from,
          coalesce(new.effective_to, 'infinity'::date),
          '[]'
        )
    ) then
      raise exception using
        errcode = '23P01',
        message = 'REGRA_FISCAL_CONFLITANTE',
        detail = format('Já existe regra ativa sobreposta para %s %s-%s.', new.ncm, new.uf_origem, new.uf_destino),
        hint = 'Encerre a vigência anterior ou salve a nova regra como inativa.';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists fiscal_tax_rules_prevent_period_overlap on public.fiscal_tax_rules;
create trigger fiscal_tax_rules_prevent_period_overlap
before insert or update of ncm, uf_origem, uf_destino, operation_type,
  customer_type, effective_from, effective_to, active
on public.fiscal_tax_rules
for each row execute function public.prevent_overlapping_fiscal_rule_periods();

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
begin
  actor := public.commercial_active_profile();
  if actor.id is null or not public.can_manage_fiscal_tax_rules() then
    raise exception 'SEM_PERMISSAO';
  end if;

  if v_id is not null then
    select * into v_current from public.fiscal_tax_rules where id = v_id for update;
    if v_current.id is null then raise exception 'REGRA_FISCAL_NAO_ENCONTRADA'; end if;
  end if;

  v_effective_from := coalesce(
    nullif(payload->>'effective_from', '')::date,
    v_current.effective_from,
    current_date
  );
  v_ncm := public.normalize_ncm(coalesce(nullif(btrim(payload->>'ncm'), ''), v_current.ncm));
  v_origin := public.normalize_fiscal_uf(coalesce(nullif(btrim(payload->>'uf_origem'), ''), v_current.uf_origem));
  v_destination := public.normalize_fiscal_uf(coalesce(nullif(btrim(payload->>'uf_destino'), ''), v_current.uf_destino));
  v_operation := upper(coalesce(nullif(btrim(payload->>'operation_type'), ''), v_current.operation_type, 'VENDA'));
  v_customer := upper(coalesce(nullif(btrim(payload->>'customer_type'), ''), v_current.customer_type, 'GERAL'));

  if v_id is null then
    select * into v_current
    from public.fiscal_tax_rules r
    where r.ncm = v_ncm
      and r.uf_origem = v_origin
      and r.uf_destino = v_destination
      and r.operation_type = v_operation
      and r.customer_type = v_customer
      and r.effective_from = v_effective_from
    limit 1
    for update;
    v_id := v_current.id;
  end if;

  v_before := case when v_current.id is null then null else to_jsonb(v_current) end;
  if v_current.id is null and not (payload ? 'has_st') then raise exception 'HAS_ST_OBRIGATORIO'; end if;
  v_has_st := case when nullif(payload->>'has_st', '') is not null
    then (payload->>'has_st')::boolean else coalesce(v_current.has_st, false) end;

  v_icms := case when nullif(payload->>'icms_percent', '') is not null
    then (payload->>'icms_percent')::numeric else v_current.icms_percent end;
  v_icms_st := case when nullif(payload->>'icms_st_percent', '') is not null
    then (payload->>'icms_st_percent')::numeric else v_current.icms_st_percent end;
  v_mva := case when nullif(payload->>'mva_percent', '') is not null
    then (payload->>'mva_percent')::numeric else v_current.mva_percent end;
  v_ipi := case when nullif(payload->>'ipi_percent', '') is not null
    then (payload->>'ipi_percent')::numeric else v_current.ipi_percent end;
  v_pis := case when nullif(payload->>'pis_percent', '') is not null
    then (payload->>'pis_percent')::numeric else v_current.pis_percent end;
  v_cofins := case when nullif(payload->>'cofins_percent', '') is not null
    then (payload->>'cofins_percent')::numeric else v_current.cofins_percent end;
  v_fcp := case when nullif(payload->>'fcp_percent', '') is not null
    then (payload->>'fcp_percent')::numeric else v_current.fcp_percent end;
  v_reduction := case when nullif(payload->>'base_reduction_percent', '') is not null
    then (payload->>'base_reduction_percent')::numeric / 100 else v_current.base_reduction_rate end;
  v_freight := case when nullif(payload->>'freight_percent', '') is not null
    then (payload->>'freight_percent')::numeric / 100 else v_current.freight_rate end;
  v_insurance := case when nullif(payload->>'insurance_percent', '') is not null
    then (payload->>'insurance_percent')::numeric / 100 else v_current.insurance_rate end;
  v_other := case when nullif(payload->>'other_expenses_percent', '') is not null
    then (payload->>'other_expenses_percent')::numeric / 100 else v_current.other_expenses_rate end;
  v_resale_rate := case when nullif(payload->>'resale_icms_st_percent', '') is not null
    then (payload->>'resale_icms_st_percent')::numeric / 100 else v_current.resale_icms_st_rate end;
  v_effective_to := case
    when coalesce((payload->>'clear_effective_to')::boolean, false) then null
    when nullif(payload->>'effective_to', '') is not null then (payload->>'effective_to')::date
    else v_current.effective_to
  end;

  if v_ncm is null then raise exception 'NCM_INVALIDO'; end if;
  if v_origin is null or v_destination is null then raise exception 'UF_INVALIDA'; end if;
  if v_icms is null then raise exception 'ICMS_OBRIGATORIO'; end if;
  if v_has_st and v_icms_st is null then raise exception 'ICMS_INTERNO_OBRIGATORIO_PARA_ST'; end if;
  if v_has_st and v_mva is null then raise exception 'MVA_OBRIGATORIA_PARA_ST'; end if;
  if v_effective_to is not null and v_effective_to < v_effective_from then raise exception 'VIGENCIA_FISCAL_INVALIDA'; end if;
  if v_icms not between 0 and 100
     or (v_icms_st is not null and v_icms_st not between 0 and 100)
     or (v_mva is not null and v_mva not between 0 and 1000)
     or (v_ipi is not null and v_ipi not between 0 and 100)
     or (v_pis is not null and v_pis not between 0 and 100)
     or (v_cofins is not null and v_cofins not between 0 and 100)
     or (v_fcp is not null and v_fcp not between 0 and 100)
     or (v_resale_rate is not null and v_resale_rate not between 0 and 1)
  then raise exception 'ALIQUOTA_FORA_DA_FAIXA'; end if;

  insert into public.fiscal_tax_rules(
    id, ncm, uf_origem, uf_destino, operation_type, customer_type,
    cest, cfop, cst_code, has_st,
    icms_percent, icms_st_percent, mva_percent, ipi_percent,
    pis_percent, cofins_percent, fcp_percent,
    base_reduction_rate, freight_rate, insurance_rate, other_expenses_rate,
    resale_calculation_method, resale_icms_st_rate, resale_include_own_icms,
    effective_from, effective_to, active, notes, source, created_by, updated_by
  ) values (
    coalesce(v_id, gen_random_uuid()), v_ncm, v_origin, v_destination,
    v_operation, v_customer,
    case when nullif(payload->>'cest', '') is not null then public.normalize_cest(payload->>'cest') else v_current.cest end,
    coalesce(nullif(btrim(payload->>'cfop'), ''), v_current.cfop),
    coalesce(nullif(btrim(payload->>'cst_code'), ''), v_current.cst_code),
    v_has_st, v_icms, v_icms_st, v_mva, v_ipi, v_pis, v_cofins, v_fcp,
    v_reduction, v_freight, v_insurance, v_other,
    coalesce(nullif(upper(btrim(payload->>'resale_calculation_method')), ''), v_current.resale_calculation_method, 'MVA_ST'),
    v_resale_rate,
    case when payload ? 'resale_include_own_icms'
      then coalesce((payload->>'resale_include_own_icms')::boolean, false)
      else coalesce(v_current.resale_include_own_icms, false) end,
    v_effective_from, v_effective_to,
    case when payload ? 'active' then coalesce((payload->>'active')::boolean, true)
      else coalesce(v_current.active, true) end,
    coalesce(nullif(btrim(payload->>'notes'), ''), v_current.notes),
    'MANUAL', coalesce(v_current.created_by, actor.id), actor.id
  )
  on conflict(id) do update set
    ncm = excluded.ncm,
    uf_origem = excluded.uf_origem,
    uf_destino = excluded.uf_destino,
    operation_type = excluded.operation_type,
    customer_type = excluded.customer_type,
    cest = excluded.cest,
    cfop = excluded.cfop,
    cst_code = excluded.cst_code,
    has_st = excluded.has_st,
    icms_percent = excluded.icms_percent,
    icms_st_percent = excluded.icms_st_percent,
    mva_percent = excluded.mva_percent,
    ipi_percent = excluded.ipi_percent,
    pis_percent = excluded.pis_percent,
    cofins_percent = excluded.cofins_percent,
    fcp_percent = excluded.fcp_percent,
    base_reduction_rate = excluded.base_reduction_rate,
    freight_rate = excluded.freight_rate,
    insurance_rate = excluded.insurance_rate,
    other_expenses_rate = excluded.other_expenses_rate,
    resale_calculation_method = excluded.resale_calculation_method,
    resale_icms_st_rate = excluded.resale_icms_st_rate,
    resale_include_own_icms = excluded.resale_include_own_icms,
    effective_from = excluded.effective_from,
    effective_to = excluded.effective_to,
    active = excluded.active,
    notes = excluded.notes,
    source = 'MANUAL',
    updated_by = actor.id,
    updated_at = now()
  returning * into v_saved;

  insert into public.logs(user_id, usuario, acao, entidade, id_entidade, dados_anteriores, dados_novos)
  values(actor.id, actor.usuario, 'SALVAR_REGRA_FISCAL', 'fiscal_tax_rules', v_saved.id::text, v_before, to_jsonb(v_saved));
  return to_jsonb(v_saved);
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception 'VALOR_FISCAL_INVALIDO';
end;
$$;

revoke all privileges on function public.save_fiscal_tax_rule(jsonb) from public;
revoke all privileges on function public.save_fiscal_tax_rule(jsonb) from anon;
grant execute on function public.save_fiscal_tax_rule(jsonb) to authenticated;

revoke all privileges on function public.prevent_overlapping_fiscal_rule_periods() from public;
revoke all privileges on function public.prevent_overlapping_fiscal_rule_periods() from anon;

comment on function public.prevent_overlapping_fiscal_rule_periods()
  is 'Impede duas regras fiscais ativas com a mesma chave lógica e períodos de vigência sobrepostos.';
comment on function public.save_fiscal_tax_rule(jsonb)
  is 'Administração fiscal auditada: preserva campos vazios, mantém NULL distinto de zero e rejeita conflitos.';

commit;
