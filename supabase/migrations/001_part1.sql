begin;

create extension if not exists pgcrypto;
create extension if not exists unaccent;
create extension if not exists pg_trgm;

create type public.user_profile as enum ('ADMIN', 'SUPERVISOR', 'VENDEDOR');
create type public.order_region as enum ('SP', 'PR');
create type public.order_status as enum ('NOVO', 'EM_ANALISE', 'APROVADO', 'CANCELADO', 'FATURADO');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  legacy_id text unique,
  usuario text unique not null,
  nome text not null,
  email text unique not null,
  perfil public.user_profile not null default 'VENDEDOR',
  ativo boolean not null default true,
  ultimo_login timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.role_permissions (
  perfil public.user_profile not null,
  modulo text not null,
  permitido boolean not null default true,
  primary key (perfil, modulo)
);

create table public.settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

create table public.products (
  codigo text primary key,
  descricao text,
  marca text,
  aplicacao text,
  ano text,
  ipi numeric(12,4) not null default 0,
  preco_sem_imposto numeric(14,4) not null default 0,
  estoque text,
  estoque_quantidade numeric(14,3) not null default 0,
  preco_sp numeric(14,4) not null default 0,
  preco_pr numeric(14,4) not null default 0,
  status_estoque text,
  status_cadastro text,
  url_imagem text,
  grupo text,
  categoria text,
  montadora text,
  detalhes text,
  oem text,
  similar text,
  search_text text generated always as (
    lower(unaccent(coalesce(codigo,'') || ' ' || coalesce(descricao,'') || ' ' ||
    coalesce(marca,'') || ' ' || coalesce(aplicacao,'') || ' ' ||
    coalesce(ano,'') || ' ' || coalesce(grupo,'') || ' ' ||
    coalesce(categoria,'') || ' ' || coalesce(montadora,'') || ' ' ||
    coalesce(detalhes,'') || ' ' || coalesce(oem,'') || ' ' || coalesce(similar,'')))
  ) stored,
  search_vector tsvector generated always as (
    to_tsvector('simple', lower(unaccent(coalesce(codigo,'') || ' ' || coalesce(descricao,'') || ' ' ||
    coalesce(marca,'') || ' ' || coalesce(aplicacao,'') || ' ' ||
    coalesce(ano,'') || ' ' || coalesce(grupo,'') || ' ' ||
    coalesce(categoria,'') || ' ' || coalesce(montadora,'') || ' ' ||
    coalesce(detalhes,'') || ' ' || coalesce(oem,'') || ' ' || coalesce(similar,''))))
  ) stored,
  updated_at timestamptz not null default now()
);

create table public.carriers (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  cnpj text,
  nome text not null,
  telefone text,
  endereco text,
  ativo boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.payment_terms (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  descricao text not null,
  ativo boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.clients (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  cnpj text,
  telefone text,
  endereco text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  numero_pedido text unique,
  data_hora timestamptz not null default now(),
  regiao public.order_region not null default 'SP',
  user_id uuid references public.profiles(id),
  vendedor text,
  codigo_sap_cliente text,
  cliente text not null,
  cnpj text,
  telefone text,
  endereco text,
  prazo text,
  transportadora text,
  transportadora_cnpj text,
  transportadora_endereco text,
  observacao text,
  subtotal numeric(14,2) not null default 0,
  desconto_total numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  status public.order_status not null default 'NOVO',
  pdf_url text,
  excel_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  item integer not null,
  codigo text not null references public.products(codigo),
  descricao text,
  marca text,
  aplicacao text,
  quantidade numeric(14,3) not null check (quantidade > 0),
  preco_unitario numeric(14,4) not null default 0,
  desconto_percentual numeric(6,2) not null default 0 check (desconto_percentual >= 0),
  preco_final_unitario numeric(14,4) not null default 0,
  total_item numeric(14,2) not null default 0,
  unique (order_id, item)
);

create table public.import_batches (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  data_hora timestamptz not null default now(),
  usuario text,
  tipo text not null,
  total_recebido integer not null default 0,
  novos integer not null default 0,
  atualizados integer not null default 0,
  sem_alteracao integer not null default 0,
  erros integer not null default 0,
  status text not null default 'APLICADO'
);

create table public.import_changes (
  id uuid primary key default gen_random_uuid(),
  import_batch_id uuid references public.import_batches(id) on delete cascade,
  data_hora timestamptz not null default now(),
  usuario text,
  tipo text,
  codigo text,
  campo text,
  valor_anterior text,
  valor_novo text,
  status text,
  mensagem text
);

create table public.logs (
  id uuid primary key default gen_random_uuid(),
  data_hora timestamptz not null default now(),
  user_id uuid references public.profiles(id),
  usuario text,
  acao text not null,
  entidade text,
  id_entidade text,
  dados_anteriores jsonb,
  dados_novos jsonb
);

create index products_search_vector_idx on public.products using gin (search_vector);
create index products_search_text_trgm_idx on public.products using gin (search_text gin_trgm_ops);
create index products_marca_idx on public.products (marca);
create index products_status_estoque_idx on public.products (status_estoque);
create index orders_user_created_idx on public.orders (user_id, created_at desc);
create index orders_status_idx on public.orders (status);
create index logs_data_idx on public.logs (data_hora desc);

