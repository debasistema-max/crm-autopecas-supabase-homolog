create extension if not exists pgcrypto;

create sequence if not exists public.cadastros_clientes_seq;

create table if not exists public.cadastros_clientes (
  id uuid primary key default gen_random_uuid(),
  protocolo text unique,
  status text not null default 'Novo',
  cnpj text not null,
  razao_social text,
  nome_fantasia text,
  ie text,
  telefone text,
  whatsapp text,
  email_compras text,
  email_financeiro text,
  responsavel_compras text,
  responsavel_financeiro text,
  cep text,
  endereco text,
  numero text,
  bairro text,
  complemento text,
  cidade text,
  estado text,
  site text,
  instagram text,
  como_conheceu text,
  segmento text,
  transportadora text,
  vendedor text,
  prazo_desejado text,
  volume_estimado text,
  observacoes text,
  observacoes_internas text,
  atividade_principal text,
  cnae text,
  situacao_cadastral text,
  possui_regime_especial boolean not null default false,
  descricao_regime text,
  estados_regime text,
  origem text not null default 'portal_publico',
  dados_api_cnpj jsonb,
  ip_hash text,
  user_agent text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.cadastros_clientes
  add column if not exists protocolo text,
  add column if not exists status text not null default 'Novo',
  add column if not exists cnpj text,
  add column if not exists razao_social text,
  add column if not exists nome_fantasia text,
  add column if not exists ie text,
  add column if not exists telefone text,
  add column if not exists whatsapp text,
  add column if not exists email_compras text,
  add column if not exists email_financeiro text,
  add column if not exists responsavel_compras text,
  add column if not exists responsavel_financeiro text,
  add column if not exists cep text,
  add column if not exists endereco text,
  add column if not exists numero text,
  add column if not exists bairro text,
  add column if not exists complemento text,
  add column if not exists cidade text,
  add column if not exists estado text,
  add column if not exists site text,
  add column if not exists instagram text,
  add column if not exists como_conheceu text,
  add column if not exists segmento text,
  add column if not exists transportadora text,
  add column if not exists vendedor text,
  add column if not exists prazo_desejado text,
  add column if not exists volume_estimado text,
  add column if not exists observacoes text,
  add column if not exists observacoes_internas text,
  add column if not exists atividade_principal text,
  add column if not exists cnae text,
  add column if not exists situacao_cadastral text,
  add column if not exists possui_regime_especial boolean not null default false,
  add column if not exists descricao_regime text,
  add column if not exists estados_regime text,
  add column if not exists origem text not null default 'portal_publico',
  add column if not exists dados_api_cnpj jsonb,
  add column if not exists ip_hash text,
  add column if not exists user_agent text,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now();

create unique index if not exists cadastros_clientes_protocolo_key
  on public.cadastros_clientes (protocolo);
create index if not exists cadastros_clientes_created_idx
  on public.cadastros_clientes (created_at desc);
create index if not exists cadastros_clientes_status_idx
  on public.cadastros_clientes (status);
create index if not exists cadastros_clientes_cnpj_idx
  on public.cadastros_clientes (cnpj);

create or replace function public.next_cadastro_cliente_protocolo()
returns text
language plpgsql
as $$
begin
  return 'CAD-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('public.cadastros_clientes_seq')::text, 6, '0');
end;
$$;

create or replace function public.set_cadastro_cliente_defaults()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.protocolo is null or new.protocolo = '' then
    new.protocolo := public.next_cadastro_cliente_protocolo();
  end if;
  new.cnpj := regexp_replace(coalesce(new.cnpj, ''), '\D', '', 'g');
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists cadastros_clientes_defaults on public.cadastros_clientes;
create trigger cadastros_clientes_defaults
before insert or update on public.cadastros_clientes
for each row execute function public.set_cadastro_cliente_defaults();

alter table public.cadastros_clientes enable row level security;

drop policy if exists cadastros_clientes_public_insert on public.cadastros_clientes;
create policy cadastros_clientes_public_insert
on public.cadastros_clientes
for insert
to anon
with check (
  origem = 'portal_publico'
  and length(regexp_replace(coalesce(cnpj, ''), '\D', '', 'g')) = 14
);

grant insert on public.cadastros_clientes to anon;
grant select, insert, update on public.cadastros_clientes to authenticated;
grant usage on sequence public.cadastros_clientes_seq to anon, authenticated;
