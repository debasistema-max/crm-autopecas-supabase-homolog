create sequence if not exists public.cadastros_clientes_seq;

create table if not exists public.cadastros_clientes (
  id uuid primary key default gen_random_uuid(),
  protocolo text unique,
  status text not null default 'Novo' check (status in ('Novo','Em analise','Pendente','Aprovado','Reprovado','Finalizado SAP')),
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

create index if not exists cadastros_clientes_created_idx on public.cadastros_clientes (created_at desc);
create index if not exists cadastros_clientes_status_idx on public.cadastros_clientes (status);
create index if not exists cadastros_clientes_cnpj_idx on public.cadastros_clientes (cnpj);

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
  if TG_OP = 'INSERT' and exists (
    select 1
    from public.cadastros_clientes c
    where c.cnpj = new.cnpj
      and c.created_at >= now() - interval '15 minutes'
  ) then
    raise exception 'Ja existe um cadastro recente para este CNPJ.';
  end if;
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

drop policy if exists cadastros_clientes_crm_read on public.cadastros_clientes;
create policy cadastros_clientes_crm_read
on public.cadastros_clientes
for select
to authenticated
using (
  public.has_module('cadastros')
  or public.is_admin()
  or (
    public.has_module('novo_pedido')
    and status in ('Aprovado', 'Finalizado SAP')
  )
);

drop policy if exists cadastros_clientes_crm_update on public.cadastros_clientes;
create policy cadastros_clientes_crm_update
on public.cadastros_clientes
for update
to authenticated
using (public.has_module('cadastros') or public.is_admin())
with check (public.has_module('cadastros') or public.is_admin());

insert into public.role_permissions (perfil, modulo, permitido)
values
  ('ADMIN','cadastros',true),
  ('SUPERVISOR','cadastros',true)
on conflict (perfil, modulo) do update set permitido = excluded.permitido;

grant insert on public.cadastros_clientes to anon;
grant select, update on public.cadastros_clientes to authenticated;
grant usage on sequence public.cadastros_clientes_seq to anon, authenticated;
