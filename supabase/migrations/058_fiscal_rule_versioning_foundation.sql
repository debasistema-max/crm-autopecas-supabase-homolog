begin;

alter table public.fiscal_tax_rules
  add column if not exists lifecycle_status text not null default 'DRAFT',
  add column if not exists legal_basis text,
  add column if not exists change_reason text,
  add column if not exists validated_at timestamptz,
  add column if not exists validated_by uuid,
  add column if not exists activated_at timestamptz,
  add column if not exists activated_by uuid,
  add column if not exists review_required_at timestamptz,
  add column if not exists review_required_by uuid,
  add column if not exists disabled_at timestamptz,
  add column if not exists disabled_by uuid,
  add column if not exists supersedes_rule_id uuid;

-- Regras legadas continuam resolvíveis para preservar a operação, mas não são
-- promovidas silenciosamente a validadas sem fundamento fiscal registrado.
update public.fiscal_tax_rules
set lifecycle_status = case when active then 'REVIEW_REQUIRED' else 'DISABLED' end,
    review_required_at = case when active then coalesce(review_required_at, now()) else review_required_at end,
    change_reason = coalesce(change_reason, 'Classificação inicial da governança fiscal; validação externa pendente.');

do $$
begin
  if not exists(
    select 1 from pg_constraint
    where conrelid='public.fiscal_tax_rules'::regclass
      and conname='fiscal_tax_rules_lifecycle_status_check'
  ) then
    alter table public.fiscal_tax_rules
      add constraint fiscal_tax_rules_lifecycle_status_check
      check (lifecycle_status in ('DRAFT','VALIDATED','ACTIVE','REVIEW_REQUIRED','EXPIRED','DISABLED'));
  end if;

  if not exists(
    select 1 from pg_constraint
    where conrelid='public.fiscal_tax_rules'::regclass
      and conname='fiscal_tax_rules_validated_by_fkey'
  ) then
    alter table public.fiscal_tax_rules
      add constraint fiscal_tax_rules_validated_by_fkey
      foreign key(validated_by) references public.profiles(id) on delete set null;
  end if;

  if not exists(
    select 1 from pg_constraint
    where conrelid='public.fiscal_tax_rules'::regclass
      and conname='fiscal_tax_rules_activated_by_fkey'
  ) then
    alter table public.fiscal_tax_rules
      add constraint fiscal_tax_rules_activated_by_fkey
      foreign key(activated_by) references public.profiles(id) on delete set null;
  end if;

  if not exists(
    select 1 from pg_constraint
    where conrelid='public.fiscal_tax_rules'::regclass
      and conname='fiscal_tax_rules_review_required_by_fkey'
  ) then
    alter table public.fiscal_tax_rules
      add constraint fiscal_tax_rules_review_required_by_fkey
      foreign key(review_required_by) references public.profiles(id) on delete set null;
  end if;

  if not exists(
    select 1 from pg_constraint
    where conrelid='public.fiscal_tax_rules'::regclass
      and conname='fiscal_tax_rules_disabled_by_fkey'
  ) then
    alter table public.fiscal_tax_rules
      add constraint fiscal_tax_rules_disabled_by_fkey
      foreign key(disabled_by) references public.profiles(id) on delete set null;
  end if;

  if not exists(
    select 1 from pg_constraint
    where conrelid='public.fiscal_tax_rules'::regclass
      and conname='fiscal_tax_rules_supersedes_rule_id_fkey'
  ) then
    alter table public.fiscal_tax_rules
      add constraint fiscal_tax_rules_supersedes_rule_id_fkey
      foreign key(supersedes_rule_id) references public.fiscal_tax_rules(id) on delete restrict;
  end if;
end;
$$;

create index if not exists fiscal_tax_rules_lifecycle_idx
  on public.fiscal_tax_rules(lifecycle_status, active, effective_from desc);
create index if not exists fiscal_tax_rules_supersedes_idx
  on public.fiscal_tax_rules(supersedes_rule_id)
  where supersedes_rule_id is not null;

create table if not exists public.fiscal_tax_rule_versions (
  id uuid primary key default gen_random_uuid(),
  rule_id uuid not null references public.fiscal_tax_rules(id) on delete restrict,
  rule_version bigint not null,
  lifecycle_status text not null,
  change_type text not null,
  change_reason text,
  legal_basis text,
  snapshot jsonb not null,
  import_batch_id uuid references public.products_import_batches(id) on delete set null,
  changed_by uuid references public.profiles(id) on delete set null,
  changed_at timestamptz not null default now(),
  constraint fiscal_tax_rule_versions_unique unique(rule_id, rule_version),
  constraint fiscal_tax_rule_versions_status_check
    check (lifecycle_status in ('DRAFT','VALIDATED','ACTIVE','REVIEW_REQUIRED','EXPIRED','DISABLED')),
  constraint fiscal_tax_rule_versions_change_type_check
    check (change_type in ('BASELINE','CREATED','UPDATED','IMPORTED','STATUS_CHANGED','SUPERSEDED','DISABLED'))
);

create index if not exists fiscal_tax_rule_versions_rule_history_idx
  on public.fiscal_tax_rule_versions(rule_id, rule_version desc, changed_at desc);
create index if not exists fiscal_tax_rule_versions_import_batch_idx
  on public.fiscal_tax_rule_versions(import_batch_id)
  where import_batch_id is not null;

insert into public.fiscal_tax_rule_versions(
  rule_id, rule_version, lifecycle_status, change_type, change_reason,
  legal_basis, snapshot, import_batch_id, changed_by, changed_at
)
select r.id, r.rule_version, r.lifecycle_status, 'BASELINE', r.change_reason,
       r.legal_basis, to_jsonb(r), r.import_batch_id,
       coalesce(r.updated_by, r.created_by), coalesce(r.updated_at, r.created_at, now())
from public.fiscal_tax_rules r
on conflict(rule_id, rule_version) do nothing;

create or replace function public.enforce_fiscal_rule_governance()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_transition boolean := coalesce(current_setting('app.fiscal_transition', true), '') = '1';
  v_meaningful_change boolean := false;
begin
  if tg_op = 'INSERT' then
    if new.import_batch_id is not null then
      new.lifecycle_status := 'REVIEW_REQUIRED';
      new.review_required_at := coalesce(new.review_required_at, now());
      new.change_reason := coalesce(new.change_reason, 'Regra recebida por importação; validação fiscal pendente.');
    elsif coalesce(new.lifecycle_status, 'DRAFT') = 'DRAFT' then
      new.lifecycle_status := 'DRAFT';
      new.active := false;
    end if;
  else
    v_meaningful_change :=
      (to_jsonb(new) - array[
        'lifecycle_status','legal_basis','change_reason','validated_at','validated_by',
        'activated_at','activated_by','review_required_at','review_required_by',
        'disabled_at','disabled_by','updated_at','rule_version'
      ]::text[])
      is distinct from
      (to_jsonb(old) - array[
        'lifecycle_status','legal_basis','change_reason','validated_at','validated_by',
        'activated_at','activated_by','review_required_at','review_required_by',
        'disabled_at','disabled_by','updated_at','rule_version'
      ]::text[]);

    if old.active and v_meaningful_change and not v_transition then
      raise exception using
        errcode='55000',
        message='REGRA_FISCAL_ATIVA_IMUTAVEL',
        hint='Crie uma nova versão com vigência própria e valide antes de ativá-la.';
    end if;

    if v_meaningful_change and not v_transition then
      if new.import_batch_id is not null then
        new.lifecycle_status := 'REVIEW_REQUIRED';
        new.review_required_at := now();
        new.review_required_by := auth.uid();
      else
        new.lifecycle_status := 'DRAFT';
        new.active := false;
      end if;
      new.validated_at := null;
      new.validated_by := null;
      new.activated_at := null;
      new.activated_by := null;
    end if;
  end if;

  if new.lifecycle_status in ('VALIDATED','ACTIVE') then
    if nullif(btrim(new.legal_basis), '') is null
       or new.validated_at is null or new.validated_by is null then
      raise exception 'VALIDACAO_FISCAL_INCOMPLETA';
    end if;
  end if;

  if new.lifecycle_status = 'ACTIVE' then
    new.active := true;
  elsif new.lifecycle_status in ('DRAFT','VALIDATED','DISABLED') then
    new.active := false;
  elsif new.lifecycle_status = 'EXPIRED' then
    -- Mantém resolução histórica pela data de vigência.
    new.active := true;
  end if;

  return new;
end;
$$;

create or replace function public.capture_fiscal_tax_rule_version()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_change_type text;
begin
  v_change_type := case
    when tg_op = 'INSERT' then 'CREATED'
    when new.lifecycle_status is distinct from old.lifecycle_status and new.lifecycle_status='DISABLED' then 'DISABLED'
    when new.lifecycle_status is distinct from old.lifecycle_status and new.lifecycle_status='EXPIRED' then 'SUPERSEDED'
    when new.lifecycle_status is distinct from old.lifecycle_status then 'STATUS_CHANGED'
    when new.import_batch_id is distinct from old.import_batch_id then 'IMPORTED'
    else 'UPDATED'
  end;

  insert into public.fiscal_tax_rule_versions(
    rule_id, rule_version, lifecycle_status, change_type, change_reason,
    legal_basis, snapshot, import_batch_id, changed_by, changed_at
  ) values(
    new.id, new.rule_version, new.lifecycle_status, v_change_type, new.change_reason,
    new.legal_basis, to_jsonb(new), new.import_batch_id,
    coalesce(auth.uid(), new.updated_by, new.created_by), now()
  )
  on conflict(rule_id, rule_version) do nothing;
  return new;
end;
$$;

create or replace function public.prevent_fiscal_rule_version_mutation()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  raise exception using
    errcode='55000',
    message='HISTORICO_FISCAL_IMUTAVEL';
end;
$$;

drop trigger if exists fiscal_tax_rules_00_governance on public.fiscal_tax_rules;
create trigger fiscal_tax_rules_00_governance
before insert or update on public.fiscal_tax_rules
for each row execute function public.enforce_fiscal_rule_governance();

drop trigger if exists fiscal_tax_rules_capture_version on public.fiscal_tax_rules;
create trigger fiscal_tax_rules_capture_version
after insert or update on public.fiscal_tax_rules
for each row execute function public.capture_fiscal_tax_rule_version();

drop trigger if exists fiscal_tax_rule_versions_immutable on public.fiscal_tax_rule_versions;
create trigger fiscal_tax_rule_versions_immutable
before update or delete on public.fiscal_tax_rule_versions
for each row execute function public.prevent_fiscal_rule_version_mutation();

alter table public.fiscal_tax_rule_versions enable row level security;
drop policy if exists fiscal_tax_rule_versions_read on public.fiscal_tax_rule_versions;
create policy fiscal_tax_rule_versions_read
on public.fiscal_tax_rule_versions for select
using (public.can_manage_fiscal_tax_rules());

revoke all on table public.fiscal_tax_rule_versions from public, anon, authenticated;

revoke all privileges on function public.enforce_fiscal_rule_governance() from public, anon;
revoke all privileges on function public.capture_fiscal_tax_rule_version() from public, anon;
revoke all privileges on function public.prevent_fiscal_rule_version_mutation() from public, anon;

comment on column public.fiscal_tax_rules.lifecycle_status
  is 'Ciclo de vida: DRAFT, VALIDATED, ACTIVE, REVIEW_REQUIRED, EXPIRED ou DISABLED.';
comment on column public.fiscal_tax_rules.legal_basis
  is 'Fundamento legal ou referência oficial usada na validação; não deve ser inventado.';
comment on table public.fiscal_tax_rule_versions
  is 'Histórico imutável de cada versão efetivamente persistida de uma regra fiscal.';

commit;
