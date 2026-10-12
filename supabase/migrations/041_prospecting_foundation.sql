begin;

set local lock_timeout = '10s';
set local statement_timeout = '120s';

create or replace function public.normalize_cnpj(cnpj_text text)
returns text
language sql
immutable
set search_path = public
as $$
  select nullif(regexp_replace(coalesce(cnpj_text, ''), '\D', '', 'g'), '')
$$;

create or replace function public.normalize_phone(phone_text text)
returns text
language sql
immutable
set search_path = public
as $$
  select nullif(regexp_replace(coalesce(phone_text, ''), '\D', '', 'g'), '')
$$;

create or replace function public.can_access_prospecting()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.ativo = true
      and (
        p.perfil in ('ADMIN', 'SUPERVISOR')
        or public.has_module('prospeccao')
      )
  )
$$;

create or replace function public.can_manage_prospecting()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.ativo = true
      and (
        p.perfil in ('ADMIN', 'SUPERVISOR')
        or public.has_module('prospeccao_admin')
      )
  )
$$;

create table if not exists public.prospecting_cnae_rules (
  id uuid primary key default gen_random_uuid(),
  cnae text not null,
  descricao text not null,
  categoria text not null default 'D',
  pontuacao integer not null default 0,
  ativo boolean not null default true,
  observacao text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint prospecting_cnae_rules_cnae_check check (cnae ~ '^[0-9]{7}$'),
  constraint prospecting_cnae_rules_categoria_check check (categoria in ('A', 'B', 'C', 'D', 'X')),
  constraint prospecting_cnae_rules_pontuacao_check check (pontuacao between -100 and 100)
);

create unique index if not exists prospecting_cnae_rules_cnae_key
  on public.prospecting_cnae_rules (cnae);

create index if not exists prospecting_cnae_rules_active_category_idx
  on public.prospecting_cnae_rules (ativo, categoria, pontuacao desc);

create table if not exists public.prospecting_regions (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  state text,
  cities text[] not null default '{}',
  cep_prefixes text[] not null default '{}',
  priority_points integer not null default 0,
  active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint prospecting_regions_state_check check (state is null or state ~ '^[A-Z]{2}$'),
  constraint prospecting_regions_priority_check check (priority_points between -100 and 100)
);

create index if not exists prospecting_regions_state_active_idx
  on public.prospecting_regions (state, active);

create table if not exists public.prospecting_territories (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete restrict,
  region_id uuid references public.prospecting_regions(id) on delete set null,
  state text,
  city text,
  cep_prefix text,
  carteira text,
  priority integer not null default 100,
  active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint prospecting_territories_state_check check (state is null or state ~ '^[A-Z]{2}$'),
  constraint prospecting_territories_cep_prefix_check check (cep_prefix is null or cep_prefix ~ '^[0-9]{1,8}$')
);

create index if not exists prospecting_territories_lookup_idx
  on public.prospecting_territories (active, state, city, cep_prefix, priority);

create index if not exists prospecting_territories_profile_idx
  on public.prospecting_territories (profile_id, active);

create table if not exists public.prospecting_imports (
  id uuid primary key default gen_random_uuid(),
  source_name text not null,
  source_kind text not null default 'receita_federal',
  source_url text,
  file_name text,
  filters jsonb not null default '{}'::jsonb,
  status text not null default 'DRAFT',
  total_rows integer not null default 0,
  accepted_rows integer not null default 0,
  rejected_rows integer not null default 0,
  started_at timestamptz,
  finished_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  error_message text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint prospecting_imports_status_check check (status in ('DRAFT', 'RUNNING', 'APPLIED', 'FAILED', 'CANCELLED'))
);

create index if not exists prospecting_imports_created_idx
  on public.prospecting_imports (created_at desc);

create table if not exists public.prospects (
  id uuid primary key default gen_random_uuid(),
  cnpj text not null,
  cnpj_basico text generated always as (substring(cnpj from 1 for 8)) stored,
  razao_social text not null,
  nome_fantasia text,
  cnae_principal text,
  cnae_principal_descricao text,
  situacao_cadastral text,
  data_abertura date,
  natureza_juridica text,
  porte text,
  capital_social numeric(18,2),
  uf text,
  municipio text,
  cep text,
  bairro text,
  tipo_logradouro text,
  logradouro text,
  numero text,
  complemento text,
  endereco text,
  latitude numeric(10,7),
  longitude numeric(10,7),
  source_import_id uuid references public.prospecting_imports(id) on delete set null,
  source_updated_at date,
  crm_match_status text not null default 'NOT_CHECKED',
  matched_client_id uuid references public.clients(id) on delete set null,
  duplicate_signals jsonb not null default '{}'::jsonb,
  prospect_status text not null default 'NOVO',
  assigned_profile_id uuid references public.profiles(id) on delete set null,
  assigned_territory_id uuid references public.prospecting_territories(id) on delete set null,
  last_activity_at timestamptz,
  next_action_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint prospects_cnpj_digits_check check (cnpj ~ '^[0-9]{14}$'),
  constraint prospects_cnae_principal_check check (cnae_principal is null or cnae_principal ~ '^[0-9]{7}$'),
  constraint prospects_uf_check check (uf is null or uf ~ '^[A-Z]{2}$'),
  constraint prospects_match_status_check check (crm_match_status in ('NOT_CHECKED', 'NOT_IN_CRM', 'CRM_CUSTOMER', 'POSSIBLE_DUPLICATE', 'SUPPRESSED'))
);

create unique index if not exists prospects_cnpj_key
  on public.prospects (cnpj);

create index if not exists prospects_geo_idx
  on public.prospects (uf, municipio, bairro);

create index if not exists prospects_cnae_idx
  on public.prospects (cnae_principal);

create index if not exists prospects_match_status_idx
  on public.prospects (crm_match_status, updated_at desc);

create index if not exists prospects_assigned_idx
  on public.prospects (assigned_profile_id, prospect_status, next_action_at);

create index if not exists prospects_name_trgm_idx
  on public.prospects using gin ((lower(coalesce(nome_fantasia, razao_social))) gin_trgm_ops);

create table if not exists public.prospect_cnaes (
  prospect_id uuid not null references public.prospects(id) on delete cascade,
  cnae text not null,
  descricao text,
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (prospect_id, cnae),
  constraint prospect_cnaes_cnae_check check (cnae ~ '^[0-9]{7}$')
);

create index if not exists prospect_cnaes_cnae_idx
  on public.prospect_cnaes (cnae, is_primary);

create table if not exists public.prospect_contacts (
  id uuid primary key default gen_random_uuid(),
  prospect_id uuid not null references public.prospects(id) on delete cascade,
  contact_type text not null,
  value text not null,
  normalized_value text,
  is_primary boolean not null default false,
  is_valid boolean,
  source_name text not null default 'unknown',
  confidence numeric(5,2) not null default 50,
  collected_at timestamptz not null default now(),
  last_verified_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint prospect_contacts_type_check check (contact_type in ('phone', 'whatsapp', 'email', 'website', 'instagram', 'facebook', 'google_business', 'other')),
  constraint prospect_contacts_confidence_check check (confidence between 0 and 100)
);

create index if not exists prospect_contacts_prospect_idx
  on public.prospect_contacts (prospect_id, contact_type, is_primary desc);

create index if not exists prospect_contacts_normalized_idx
  on public.prospect_contacts (contact_type, normalized_value)
  where normalized_value is not null;

create unique index if not exists prospect_contacts_unique_source_value_idx
  on public.prospect_contacts (prospect_id, contact_type, normalized_value, source_name)
  where normalized_value is not null;

create table if not exists public.prospect_sources (
  id uuid primary key default gen_random_uuid(),
  prospect_id uuid not null references public.prospects(id) on delete cascade,
  source_name text not null,
  source_kind text not null,
  field_name text not null,
  field_value jsonb,
  confidence numeric(5,2) not null default 50,
  collected_at timestamptz not null default now(),
  source_url text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint prospect_sources_confidence_check check (confidence between 0 and 100)
);

create index if not exists prospect_sources_prospect_field_idx
  on public.prospect_sources (prospect_id, field_name, collected_at desc);

create table if not exists public.prospecting_suppression_list (
  id uuid primary key default gen_random_uuid(),
  cnpj text,
  contact_value text,
  normalized_contact_value text,
  reason text not null,
  source text not null default 'manual',
  active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint prospecting_suppression_cnpj_check check (cnpj is null or cnpj ~ '^[0-9]{14}$'),
  constraint prospecting_suppression_has_target_check check (cnpj is not null or normalized_contact_value is not null)
);

create index if not exists prospecting_suppression_cnpj_idx
  on public.prospecting_suppression_list (cnpj, active)
  where cnpj is not null;

create index if not exists prospecting_suppression_contact_idx
  on public.prospecting_suppression_list (normalized_contact_value, active)
  where normalized_contact_value is not null;

create table if not exists public.prospecting_searches (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete set null,
  raw_query text,
  structured_filters jsonb not null default '{}'::jsonb,
  result_count integer,
  created_at timestamptz not null default now()
);

create index if not exists prospecting_searches_user_created_idx
  on public.prospecting_searches (user_id, created_at desc);

drop trigger if exists prospecting_cnae_rules_touch_updated_at on public.prospecting_cnae_rules;
create trigger prospecting_cnae_rules_touch_updated_at
before update on public.prospecting_cnae_rules
for each row execute function public.touch_updated_at();

drop trigger if exists prospecting_regions_touch_updated_at on public.prospecting_regions;
create trigger prospecting_regions_touch_updated_at
before update on public.prospecting_regions
for each row execute function public.touch_updated_at();

drop trigger if exists prospecting_territories_touch_updated_at on public.prospecting_territories;
create trigger prospecting_territories_touch_updated_at
before update on public.prospecting_territories
for each row execute function public.touch_updated_at();

drop trigger if exists prospecting_imports_touch_updated_at on public.prospecting_imports;
create trigger prospecting_imports_touch_updated_at
before update on public.prospecting_imports
for each row execute function public.touch_updated_at();

drop trigger if exists prospects_touch_updated_at on public.prospects;
create trigger prospects_touch_updated_at
before update on public.prospects
for each row execute function public.touch_updated_at();

drop trigger if exists prospect_contacts_touch_updated_at on public.prospect_contacts;
create trigger prospect_contacts_touch_updated_at
before update on public.prospect_contacts
for each row execute function public.touch_updated_at();

drop trigger if exists prospecting_suppression_touch_updated_at on public.prospecting_suppression_list;
create trigger prospecting_suppression_touch_updated_at
before update on public.prospecting_suppression_list
for each row execute function public.touch_updated_at();

create or replace function public.assign_prospect_by_territory(target_prospect_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  prospect_row public.prospects;
  territory_row public.prospecting_territories;
begin
  if not public.can_manage_prospecting() and not public.can_access_prospecting() then
    raise exception 'SEM_PERMISSAO';
  end if;

  select * into prospect_row
  from public.prospects
  where id = target_prospect_id;

  if prospect_row.id is null then
    raise exception 'PROSPECT_NAO_ENCONTRADO';
  end if;

  select t.* into territory_row
  from public.prospecting_territories t
  left join public.prospecting_regions r on r.id = t.region_id
  where t.active
    and (t.state is null or t.state = prospect_row.uf)
    and (t.city is null or unaccent(lower(t.city)) = unaccent(lower(coalesce(prospect_row.municipio, ''))))
    and (t.cep_prefix is null or coalesce(prospect_row.cep, '') like t.cep_prefix || '%')
    and (
      t.region_id is null
      or (
        r.active
        and (r.state is null or r.state = prospect_row.uf)
        and (
          cardinality(r.cities) = 0
          or unaccent(lower(coalesce(prospect_row.municipio, ''))) = any (
            select unaccent(lower(city_value)) from unnest(r.cities) as city_list(city_value)
          )
        )
      )
    )
  order by
    case when t.city is not null then 0 else 1 end,
    case when t.cep_prefix is not null then 0 else 1 end,
    case when t.region_id is not null then 0 else 1 end,
    t.priority,
    t.created_at
  limit 1;

  if territory_row.id is null then
    return jsonb_build_object('assigned', false);
  end if;

  update public.prospects
  set assigned_profile_id = territory_row.profile_id,
      assigned_territory_id = territory_row.id
  where id = target_prospect_id;

  return jsonb_build_object(
    'assigned', true,
    'profile_id', territory_row.profile_id,
    'territory_id', territory_row.id
  );
end;
$$;

create or replace function public.refresh_prospect_crm_match(target_prospect_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  prospect_row public.prospects;
  client_row public.clients;
  phone_match public.clients;
  name_match public.clients;
  phone_values text[];
  suppression_hit boolean;
  signals jsonb := '{}'::jsonb;
begin
  if not public.can_access_prospecting() then
    raise exception 'SEM_PERMISSAO';
  end if;

  select * into prospect_row
  from public.prospects
  where id = target_prospect_id;

  if prospect_row.id is null then
    raise exception 'PROSPECT_NAO_ENCONTRADO';
  end if;

  select exists (
    select 1
    from public.prospecting_suppression_list s
    where s.active
      and (
        s.cnpj = prospect_row.cnpj
        or exists (
          select 1
          from public.prospect_contacts pc
          where pc.prospect_id = prospect_row.id
            and pc.normalized_value = s.normalized_contact_value
        )
      )
  ) into suppression_hit;

  if suppression_hit then
    update public.prospects
    set crm_match_status = 'SUPPRESSED',
        matched_client_id = null,
        duplicate_signals = jsonb_build_object('suppression', true)
    where id = prospect_row.id;

    return jsonb_build_object('status', 'SUPPRESSED');
  end if;

  select c.* into client_row
  from public.clients c
  where c.ativo = true
    and public.normalize_cnpj(c.cnpj) = prospect_row.cnpj
  order by c.created_at
  limit 1;

  if client_row.id is not null then
    update public.prospects
    set crm_match_status = 'CRM_CUSTOMER',
        matched_client_id = client_row.id,
        duplicate_signals = jsonb_build_object('cnpj', true, 'client_id', client_row.id)
    where id = prospect_row.id;

    return jsonb_build_object('status', 'CRM_CUSTOMER', 'client_id', client_row.id, 'reason', 'cnpj');
  end if;

  select array_agg(distinct pc.normalized_value) into phone_values
  from public.prospect_contacts pc
  where pc.prospect_id = prospect_row.id
    and pc.contact_type in ('phone', 'whatsapp')
    and pc.normalized_value is not null;

  if coalesce(array_length(phone_values, 1), 0) > 0 then
    select c.* into phone_match
    from public.clients c
    where c.ativo = true
      and public.normalize_phone(c.telefone) = any(phone_values)
    order by c.created_at
    limit 1;
  end if;

  if phone_match.id is not null then
    signals := signals || jsonb_build_object('phone', true, 'client_id', phone_match.id);
  end if;

  select c.* into name_match
  from public.clients c
  where c.ativo = true
    and coalesce(c.estado, '') = coalesce(prospect_row.uf, '')
    and unaccent(lower(coalesce(c.cidade, ''))) = unaccent(lower(coalesce(prospect_row.municipio, '')))
    and similarity(
      unaccent(lower(coalesce(c.nome_fantasia, c.nome, ''))),
      unaccent(lower(coalesce(prospect_row.nome_fantasia, prospect_row.razao_social, '')))
    ) >= 0.72
  order by similarity(
      unaccent(lower(coalesce(c.nome_fantasia, c.nome, ''))),
      unaccent(lower(coalesce(prospect_row.nome_fantasia, prospect_row.razao_social, '')))
    ) desc,
    c.created_at
  limit 1;

  if name_match.id is not null then
    signals := signals || jsonb_build_object('name_city', true, 'name_client_id', name_match.id);
  end if;

  if signals <> '{}'::jsonb then
    update public.prospects
    set crm_match_status = 'POSSIBLE_DUPLICATE',
        matched_client_id = coalesce(phone_match.id, name_match.id),
        duplicate_signals = signals
    where id = prospect_row.id;

    return jsonb_build_object('status', 'POSSIBLE_DUPLICATE', 'signals', signals);
  end if;

  update public.prospects
  set crm_match_status = 'NOT_IN_CRM',
      matched_client_id = null,
      duplicate_signals = '{}'::jsonb
  where id = prospect_row.id;

  return jsonb_build_object('status', 'NOT_IN_CRM');
end;
$$;

create or replace function public.list_prospects(filters jsonb default '{}'::jsonb)
returns table (
  id uuid,
  cnpj text,
  razao_social text,
  nome_fantasia text,
  municipio text,
  uf text,
  cnae_principal text,
  cnae_categoria text,
  cnae_pontuacao integer,
  crm_match_status text,
  matched_client_id uuid,
  prospect_status text,
  assigned_profile_id uuid,
  assigned_profile_name text,
  primary_phone text,
  primary_whatsapp text,
  primary_website text,
  created_at timestamptz,
  updated_at timestamptz,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit integer := least(greatest(coalesce((filters->>'limit')::integer, 50), 1), 200);
  v_offset integer := greatest(coalesce((filters->>'offset')::integer, 0), 0);
  v_uf text := nullif(upper(btrim(coalesce(filters->>'uf', ''))), '');
  v_municipio text := nullif(btrim(coalesce(filters->>'municipio', '')), '');
  v_cnae text := nullif(regexp_replace(coalesce(filters->>'cnae', ''), '\D', '', 'g'), '');
  v_match_status text := nullif(upper(btrim(coalesce(filters->>'crm_match_status', ''))), '');
  v_q text := nullif(btrim(coalesce(filters->>'q', '')), '');
  v_include_crm boolean := coalesce((filters->>'include_crm_customers')::boolean, false);
begin
  if not public.can_access_prospecting() then
    raise exception 'SEM_PERMISSAO';
  end if;

  return query
  with filtered as (
    select p.*
    from public.prospects p
    where (v_uf is null or p.uf = v_uf)
      and (v_municipio is null or unaccent(lower(p.municipio)) = unaccent(lower(v_municipio)))
      and (v_cnae is null or p.cnae_principal = v_cnae or exists (
        select 1 from public.prospect_cnaes pc where pc.prospect_id = p.id and pc.cnae = v_cnae
      ))
      and (v_match_status is null or p.crm_match_status = v_match_status)
      and (v_include_crm or p.crm_match_status <> 'CRM_CUSTOMER')
      and (
        v_q is null
        or unaccent(coalesce(p.razao_social, '')) ilike '%' || unaccent(v_q) || '%'
        or unaccent(coalesce(p.nome_fantasia, '')) ilike '%' || unaccent(v_q) || '%'
        or p.cnpj = public.normalize_cnpj(v_q)
      )
      and (
        public.can_manage_prospecting()
        or p.assigned_profile_id is null
        or p.assigned_profile_id = auth.uid()
        or public.has_module('prospeccao')
      )
  ),
  counted as (
    select count(*) as total_count from filtered
  ),
  page as (
    select f.*
    from filtered f
    order by
      case f.crm_match_status when 'NOT_IN_CRM' then 0 when 'NOT_CHECKED' then 1 when 'POSSIBLE_DUPLICATE' then 2 else 3 end,
      f.updated_at desc
    limit v_limit offset v_offset
  )
  select
    p.id,
    p.cnpj,
    p.razao_social,
    p.nome_fantasia,
    p.municipio,
    p.uf,
    p.cnae_principal,
    cr.categoria as cnae_categoria,
    cr.pontuacao as cnae_pontuacao,
    p.crm_match_status,
    p.matched_client_id,
    p.prospect_status,
    p.assigned_profile_id,
    pr.nome as assigned_profile_name,
    phone.value as primary_phone,
    whatsapp.value as primary_whatsapp,
    website.value as primary_website,
    p.created_at,
    p.updated_at,
    counted.total_count
  from page p
  cross join counted
  left join public.prospecting_cnae_rules cr on cr.cnae = p.cnae_principal and cr.ativo
  left join public.profiles pr on pr.id = p.assigned_profile_id
  left join lateral (
    select pc.value from public.prospect_contacts pc
    where pc.prospect_id = p.id and pc.contact_type = 'phone'
    order by pc.is_primary desc, pc.confidence desc, pc.created_at
    limit 1
  ) phone on true
  left join lateral (
    select pc.value from public.prospect_contacts pc
    where pc.prospect_id = p.id and pc.contact_type = 'whatsapp'
    order by pc.is_primary desc, pc.confidence desc, pc.created_at
    limit 1
  ) whatsapp on true
  left join lateral (
    select pc.value from public.prospect_contacts pc
    where pc.prospect_id = p.id and pc.contact_type = 'website'
    order by pc.is_primary desc, pc.confidence desc, pc.created_at
    limit 1
  ) website on true;
end;
$$;

alter table public.prospecting_cnae_rules enable row level security;
alter table public.prospecting_regions enable row level security;
alter table public.prospecting_territories enable row level security;
alter table public.prospecting_imports enable row level security;
alter table public.prospects enable row level security;
alter table public.prospect_cnaes enable row level security;
alter table public.prospect_contacts enable row level security;
alter table public.prospect_sources enable row level security;
alter table public.prospecting_suppression_list enable row level security;
alter table public.prospecting_searches enable row level security;

drop policy if exists prospecting_cnae_rules_read on public.prospecting_cnae_rules;
create policy prospecting_cnae_rules_read on public.prospecting_cnae_rules
for select to authenticated using (public.can_access_prospecting());

drop policy if exists prospecting_cnae_rules_write on public.prospecting_cnae_rules;
create policy prospecting_cnae_rules_write on public.prospecting_cnae_rules
for all to authenticated using (public.can_manage_prospecting()) with check (public.can_manage_prospecting());

drop policy if exists prospecting_regions_read on public.prospecting_regions;
create policy prospecting_regions_read on public.prospecting_regions
for select to authenticated using (public.can_access_prospecting());

drop policy if exists prospecting_regions_write on public.prospecting_regions;
create policy prospecting_regions_write on public.prospecting_regions
for all to authenticated using (public.can_manage_prospecting()) with check (public.can_manage_prospecting());

drop policy if exists prospecting_territories_read on public.prospecting_territories;
create policy prospecting_territories_read on public.prospecting_territories
for select to authenticated using (public.can_access_prospecting());

drop policy if exists prospecting_territories_write on public.prospecting_territories;
create policy prospecting_territories_write on public.prospecting_territories
for all to authenticated using (public.can_manage_prospecting()) with check (public.can_manage_prospecting());

drop policy if exists prospecting_imports_read on public.prospecting_imports;
create policy prospecting_imports_read on public.prospecting_imports
for select to authenticated using (public.can_access_prospecting());

drop policy if exists prospecting_imports_write on public.prospecting_imports;
create policy prospecting_imports_write on public.prospecting_imports
for all to authenticated using (public.can_manage_prospecting()) with check (public.can_manage_prospecting());

drop policy if exists prospects_read on public.prospects;
create policy prospects_read on public.prospects
for select to authenticated using (
  public.can_manage_prospecting()
  or public.can_access_prospecting()
  or assigned_profile_id = auth.uid()
);

drop policy if exists prospects_write on public.prospects;
create policy prospects_write on public.prospects
for all to authenticated using (public.can_manage_prospecting()) with check (public.can_manage_prospecting());

drop policy if exists prospect_cnaes_read on public.prospect_cnaes;
create policy prospect_cnaes_read on public.prospect_cnaes
for select to authenticated using (
  exists (select 1 from public.prospects p where p.id = prospect_id)
);

drop policy if exists prospect_cnaes_write on public.prospect_cnaes;
create policy prospect_cnaes_write on public.prospect_cnaes
for all to authenticated using (public.can_manage_prospecting()) with check (public.can_manage_prospecting());

drop policy if exists prospect_contacts_read on public.prospect_contacts;
create policy prospect_contacts_read on public.prospect_contacts
for select to authenticated using (
  exists (select 1 from public.prospects p where p.id = prospect_id)
);

drop policy if exists prospect_contacts_write on public.prospect_contacts;
create policy prospect_contacts_write on public.prospect_contacts
for all to authenticated using (public.can_manage_prospecting()) with check (public.can_manage_prospecting());

drop policy if exists prospect_sources_read on public.prospect_sources;
create policy prospect_sources_read on public.prospect_sources
for select to authenticated using (
  exists (select 1 from public.prospects p where p.id = prospect_id)
);

drop policy if exists prospect_sources_write on public.prospect_sources;
create policy prospect_sources_write on public.prospect_sources
for all to authenticated using (public.can_manage_prospecting()) with check (public.can_manage_prospecting());

drop policy if exists prospecting_suppression_read on public.prospecting_suppression_list;
create policy prospecting_suppression_read on public.prospecting_suppression_list
for select to authenticated using (public.can_access_prospecting());

drop policy if exists prospecting_suppression_write on public.prospecting_suppression_list;
create policy prospecting_suppression_write on public.prospecting_suppression_list
for all to authenticated using (public.can_manage_prospecting()) with check (public.can_manage_prospecting());

drop policy if exists prospecting_searches_own_read on public.prospecting_searches;
create policy prospecting_searches_own_read on public.prospecting_searches
for select to authenticated using (user_id = auth.uid() or public.can_manage_prospecting());

drop policy if exists prospecting_searches_insert on public.prospecting_searches;
create policy prospecting_searches_insert on public.prospecting_searches
for insert to authenticated with check (user_id = auth.uid() and public.can_access_prospecting());

revoke all on
  public.prospecting_cnae_rules,
  public.prospecting_regions,
  public.prospecting_territories,
  public.prospecting_imports,
  public.prospects,
  public.prospect_cnaes,
  public.prospect_contacts,
  public.prospect_sources,
  public.prospecting_suppression_list,
  public.prospecting_searches
from public, anon, authenticated;

grant select, insert, update, delete on
  public.prospecting_cnae_rules,
  public.prospecting_regions,
  public.prospecting_territories,
  public.prospecting_imports,
  public.prospects,
  public.prospect_cnaes,
  public.prospect_contacts,
  public.prospect_sources,
  public.prospecting_suppression_list
to authenticated;

grant select, insert on public.prospecting_searches to authenticated;

revoke all on function
  public.normalize_cnpj(text),
  public.normalize_phone(text),
  public.can_access_prospecting(),
  public.can_manage_prospecting(),
  public.assign_prospect_by_territory(uuid),
  public.refresh_prospect_crm_match(uuid),
  public.list_prospects(jsonb)
from public, anon;

grant execute on function
  public.normalize_cnpj(text),
  public.normalize_phone(text),
  public.can_access_prospecting(),
  public.can_manage_prospecting(),
  public.assign_prospect_by_territory(uuid),
  public.refresh_prospect_crm_match(uuid),
  public.list_prospects(jsonb)
to authenticated;

insert into public.role_permissions (perfil, modulo, permitido) values
  ('ADMIN', 'prospeccao', true),
  ('SUPERVISOR', 'prospeccao', true),
  ('VENDEDOR', 'prospeccao', true),
  ('ADMIN', 'prospeccao_admin', true),
  ('SUPERVISOR', 'prospeccao_admin', true),
  ('VENDEDOR', 'prospeccao_admin', false)
on conflict (perfil, modulo) do update set permitido = excluded.permitido;

insert into public.prospecting_cnae_rules (cnae, descricao, categoria, pontuacao, observacao) values
  ('4530703', 'Comercio a varejo de pecas e acessorios novos para veiculos automotores', 'A', 30, 'ICP inicial IPS/Yokomitsu'),
  ('4530704', 'Comercio a varejo de pecas e acessorios usados para veiculos automotores', 'A', 24, 'ICP inicial IPS/Yokomitsu'),
  ('4530701', 'Comercio por atacado de pecas e acessorios novos para veiculos automotores', 'A', 30, 'ICP inicial IPS/Yokomitsu'),
  ('4520001', 'Servicos de manutencao e reparacao mecanica de veiculos automotores', 'B', 20, 'Bom potencial para oficinas estruturadas'),
  ('4520002', 'Servicos de lanternagem ou funilaria e pintura de veiculos automotores', 'B', 12, 'Potencial indireto'),
  ('4520003', 'Servicos de manutencao e reparacao eletrica de veiculos automotores', 'B', 12, 'Potencial indireto'),
  ('4520004', 'Servicos de alinhamento e balanceamento de veiculos automotores', 'B', 18, 'Aderente a suspensao/direcao'),
  ('4520005', 'Servicos de lavagem, lubrificacao e polimento de veiculos automotores', 'C', 8, 'Complementar'),
  ('4511101', 'Comercio a varejo de automoveis, camionetas e utilitarios novos', 'C', 8, 'Complementar'),
  ('4511102', 'Comercio a varejo de automoveis, camionetas e utilitarios usados', 'C', 8, 'Complementar'),
  ('4530705', 'Comercio a varejo de pneumaticos e camaras-de-ar', 'C', 10, 'Complementar com potencial automotivo')
on conflict (cnae) do update set
  descricao = excluded.descricao,
  categoria = excluded.categoria,
  pontuacao = excluded.pontuacao,
  observacao = excluded.observacao,
  ativo = true;

commit;
