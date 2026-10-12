create table if not exists public.company_settings (
  id boolean primary key default true,
  company_name text not null default 'Nova Empresa',
  trade_name text,
  cnpj text,
  address text,
  city text,
  state text,
  zip_code text,
  phone text,
  whatsapp text,
  email text,
  website text,
  logo_url text,
  primary_color text not null default '#0d6b5f',
  secondary_color text not null default '#17212b',
  currency text not null default 'BRL',
  timezone text not null default 'America/Sao_Paulo',
  language text not null default 'pt-BR',
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  constraint company_settings_singleton check (id = true),
  constraint company_settings_state_len check (state is null or char_length(state) <= 2),
  constraint company_settings_currency_len check (char_length(currency) = 3),
  constraint company_settings_timezone_len check (char_length(timezone) between 1 and 80),
  constraint company_settings_language_len check (char_length(language) between 2 and 16),
  constraint company_settings_primary_color_hex check (primary_color ~ '^#[0-9A-Fa-f]{6}$'),
  constraint company_settings_secondary_color_hex check (secondary_color ~ '^#[0-9A-Fa-f]{6}$')
);

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists company_settings_touch_updated_at on public.company_settings;
create trigger company_settings_touch_updated_at
before update on public.company_settings
for each row execute function public.touch_updated_at();

alter table public.company_settings enable row level security;

drop policy if exists company_settings_read on public.company_settings;
create policy company_settings_read
on public.company_settings
for select
using (auth.uid() is not null);

drop policy if exists company_settings_admin_write on public.company_settings;
create policy company_settings_admin_write
on public.company_settings
for all
using (public.is_admin())
with check (public.is_admin());

revoke all on public.company_settings from anon;
revoke all on public.company_settings from authenticated;
grant select on public.company_settings to authenticated;
grant insert, update, delete on public.company_settings to authenticated;

create or replace function public.get_public_company_identity()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'company_name', company_name,
    'trade_name', trade_name,
    'logo_url', logo_url,
    'primary_color', primary_color,
    'secondary_color', secondary_color,
    'website', website,
    'phone', phone,
    'whatsapp', whatsapp,
    'email', email,
    'city', city,
    'state', state,
    'language', language
  )
  from public.company_settings
  where id = true;
$$;

grant execute on function public.get_public_company_identity() to anon, authenticated;

insert into public.company_settings (id, company_name, currency, timezone, language)
values (true, 'Nova Empresa', 'BRL', 'America/Sao_Paulo', 'pt-BR')
on conflict (id) do nothing;

insert into public.role_permissions (perfil, modulo, permitido)
values ('ADMIN', 'configuracoes_empresa', true)
on conflict (perfil, modulo) do update
set permitido = excluded.permitido;
