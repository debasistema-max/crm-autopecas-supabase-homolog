begin;

create table if not exists public.fiscal_tax_rules (
  id uuid primary key default gen_random_uuid(),
  ncm text not null,
  uf_origem text not null,
  uf_destino text not null,
  operation_type text not null default 'VENDA',
  customer_type text not null default 'GERAL',
  icms_percent numeric(9,4) not null default 0,
  icms_st_percent numeric(9,4) not null default 0,
  mva_percent numeric(9,4) not null default 0,
  ipi_percent numeric(9,4) not null default 0,
  pis_percent numeric(9,4) not null default 0,
  cofins_percent numeric(9,4) not null default 0,
  fcp_percent numeric(9,4) not null default 0,
  effective_from date not null default current_date,
  effective_to date,
  active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fiscal_tax_rules_ncm_check check (ncm ~ '^[0-9]{8}$'),
  constraint fiscal_tax_rules_uf_origem_check check (uf_origem ~ '^[A-Z]{2}$'),
  constraint fiscal_tax_rules_uf_destino_check check (uf_destino ~ '^[A-Z]{2}$'),
  constraint fiscal_tax_rules_percent_check check (
    icms_percent >= 0 and icms_st_percent >= 0 and mva_percent >= 0
    and ipi_percent >= 0 and pis_percent >= 0 and cofins_percent >= 0 and fcp_percent >= 0
  ),
  constraint fiscal_tax_rules_period_check check (effective_to is null or effective_to >= effective_from)
);

create unique index if not exists fiscal_tax_rules_unique_period_idx
  on public.fiscal_tax_rules (
    ncm,
    uf_origem,
    uf_destino,
    operation_type,
    customer_type,
    effective_from
  );

create index if not exists fiscal_tax_rules_lookup_idx
  on public.fiscal_tax_rules (ncm, uf_origem, uf_destino, active, effective_from desc);

drop trigger if exists fiscal_tax_rules_touch_updated_at on public.fiscal_tax_rules;
create trigger fiscal_tax_rules_touch_updated_at
before update on public.fiscal_tax_rules
for each row execute function public.touch_updated_at();

create or replace function public.can_manage_fiscal_tax_rules()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin()
    or public.has_module('configuracoes_empresa')
    or public.has_module('configuracoes');
$$;

create or replace function public.list_fiscal_tax_rules(filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  v_ncm text := nullif(regexp_replace(coalesce(filters->>'ncm', ''), '\D', '', 'g'), '');
  v_uf_destino text := nullif(upper(btrim(coalesce(filters->>'uf_destino', filters->>'uf', ''))), '');
  v_active text := lower(btrim(coalesce(filters->>'active', '')));
  v_rows jsonb;
begin
  actor := public.commercial_active_profile();
  if actor.id is null then raise exception 'SEM_PERMISSAO'; end if;
  if not public.can_manage_fiscal_tax_rules() then raise exception 'SEM_PERMISSAO'; end if;

  select coalesce(jsonb_agg(to_jsonb(rows) order by rows.ncm, rows.uf_origem, rows.uf_destino, rows.effective_from desc), '[]'::jsonb)
  into v_rows
  from (
    select *
    from public.fiscal_tax_rules r
    where (v_ncm is null or r.ncm = v_ncm)
      and (v_uf_destino is null or r.uf_destino = v_uf_destino)
      and (
        v_active = ''
        or (v_active in ('true', '1', 'sim', 'ativo') and r.active)
        or (v_active in ('false', '0', 'nao', 'inativo') and not r.active)
      )
    order by r.ncm, r.uf_origem, r.uf_destino, r.effective_from desc
    limit 500
  ) rows;

  return v_rows;
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
  v_record public.fiscal_tax_rules;
begin
  actor := public.commercial_active_profile();
  if actor.id is null then raise exception 'SEM_PERMISSAO'; end if;
  if not public.can_manage_fiscal_tax_rules() then raise exception 'SEM_PERMISSAO'; end if;

  if v_id is not null then
    update public.fiscal_tax_rules
    set ncm = regexp_replace(coalesce(payload->>'ncm', ''), '\D', '', 'g'),
        uf_origem = upper(btrim(coalesce(payload->>'uf_origem', ''))),
        uf_destino = upper(btrim(coalesce(payload->>'uf_destino', ''))),
        operation_type = upper(btrim(coalesce(nullif(payload->>'operation_type', ''), 'VENDA'))),
        customer_type = upper(btrim(coalesce(nullif(payload->>'customer_type', ''), 'GERAL'))),
        icms_percent = coalesce(nullif(payload->>'icms_percent', '')::numeric, 0),
        icms_st_percent = coalesce(nullif(payload->>'icms_st_percent', '')::numeric, 0),
        mva_percent = coalesce(nullif(payload->>'mva_percent', '')::numeric, 0),
        ipi_percent = coalesce(nullif(payload->>'ipi_percent', '')::numeric, 0),
        pis_percent = coalesce(nullif(payload->>'pis_percent', '')::numeric, 0),
        cofins_percent = coalesce(nullif(payload->>'cofins_percent', '')::numeric, 0),
        fcp_percent = coalesce(nullif(payload->>'fcp_percent', '')::numeric, 0),
        effective_from = coalesce(nullif(payload->>'effective_from', '')::date, current_date),
        effective_to = nullif(payload->>'effective_to', '')::date,
        active = coalesce((payload->>'active')::boolean, true),
        notes = nullif(btrim(coalesce(payload->>'notes', '')), '')
    where id = v_id
    returning * into v_record;

    if v_record.id is null then raise exception 'REGRA_FISCAL_NAO_ENCONTRADA'; end if;
  else
  insert into public.fiscal_tax_rules (
    ncm,
    uf_origem,
    uf_destino,
    operation_type,
    customer_type,
    icms_percent,
    icms_st_percent,
    mva_percent,
    ipi_percent,
    pis_percent,
    cofins_percent,
    fcp_percent,
    effective_from,
    effective_to,
    active,
    notes
  )
  values (
    regexp_replace(coalesce(payload->>'ncm', ''), '\D', '', 'g'),
    upper(btrim(coalesce(payload->>'uf_origem', ''))),
    upper(btrim(coalesce(payload->>'uf_destino', ''))),
    upper(btrim(coalesce(nullif(payload->>'operation_type', ''), 'VENDA'))),
    upper(btrim(coalesce(nullif(payload->>'customer_type', ''), 'GERAL'))),
    coalesce(nullif(payload->>'icms_percent', '')::numeric, 0),
    coalesce(nullif(payload->>'icms_st_percent', '')::numeric, 0),
    coalesce(nullif(payload->>'mva_percent', '')::numeric, 0),
    coalesce(nullif(payload->>'ipi_percent', '')::numeric, 0),
    coalesce(nullif(payload->>'pis_percent', '')::numeric, 0),
    coalesce(nullif(payload->>'cofins_percent', '')::numeric, 0),
    coalesce(nullif(payload->>'fcp_percent', '')::numeric, 0),
    coalesce(nullif(payload->>'effective_from', '')::date, current_date),
    nullif(payload->>'effective_to', '')::date,
    coalesce((payload->>'active')::boolean, true),
    nullif(btrim(coalesce(payload->>'notes', '')), '')
  )
  on conflict (ncm, uf_origem, uf_destino, operation_type, customer_type, effective_from) do update
  set icms_percent = excluded.icms_percent,
      icms_st_percent = excluded.icms_st_percent,
      mva_percent = excluded.mva_percent,
      ipi_percent = excluded.ipi_percent,
      pis_percent = excluded.pis_percent,
      cofins_percent = excluded.cofins_percent,
      fcp_percent = excluded.fcp_percent,
      effective_to = excluded.effective_to,
      active = excluded.active,
      notes = excluded.notes
  returning * into v_record;
  end if;

  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (
    actor.id,
    actor.usuario,
    'SALVAR_REGRA_FISCAL',
    'fiscal_tax_rules',
    v_record.id::text,
    to_jsonb(v_record)
  );

  return to_jsonb(v_record);
end;
$$;

create or replace function public.delete_fiscal_tax_rule(target_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  v_record public.fiscal_tax_rules;
begin
  actor := public.commercial_active_profile();
  if actor.id is null then raise exception 'SEM_PERMISSAO'; end if;
  if not public.can_manage_fiscal_tax_rules() then raise exception 'SEM_PERMISSAO'; end if;

  delete from public.fiscal_tax_rules
  where id = target_id
  returning * into v_record;

  if v_record.id is null then raise exception 'REGRA_FISCAL_NAO_ENCONTRADA'; end if;

  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (
    actor.id,
    actor.usuario,
    'EXCLUIR_REGRA_FISCAL',
    'fiscal_tax_rules',
    target_id::text,
    to_jsonb(v_record)
  );

  return jsonb_build_object('deleted', true, 'id', target_id);
end;
$$;

alter table public.fiscal_tax_rules enable row level security;

drop policy if exists fiscal_tax_rules_read on public.fiscal_tax_rules;
create policy fiscal_tax_rules_read
on public.fiscal_tax_rules
for select
using (public.can_manage_fiscal_tax_rules());

drop policy if exists fiscal_tax_rules_write on public.fiscal_tax_rules;
create policy fiscal_tax_rules_write
on public.fiscal_tax_rules
for all
using (public.can_manage_fiscal_tax_rules())
with check (public.can_manage_fiscal_tax_rules());

revoke all on public.fiscal_tax_rules from public, anon, authenticated;
grant select, insert, update, delete on public.fiscal_tax_rules to authenticated;

revoke all on function public.can_manage_fiscal_tax_rules(),
  public.list_fiscal_tax_rules(jsonb),
  public.save_fiscal_tax_rule(jsonb),
  public.delete_fiscal_tax_rule(uuid)
from public, anon;

grant execute on function public.can_manage_fiscal_tax_rules(),
  public.list_fiscal_tax_rules(jsonb),
  public.save_fiscal_tax_rule(jsonb),
  public.delete_fiscal_tax_rule(uuid)
to authenticated;

comment on table public.fiscal_tax_rules
is 'Regras fiscais por NCM e UF para futura composicao automatica de preco com impostos.';

comment on function public.list_fiscal_tax_rules(jsonb)
is 'Lista regras fiscais por NCM/UF para manutencao administrativa.';

comment on function public.save_fiscal_tax_rule(jsonb)
is 'Insere ou atualiza uma regra fiscal administrativa.';

commit;
