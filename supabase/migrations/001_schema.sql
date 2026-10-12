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
  "similar" text,
  search_text text,
  search_vector tsvector,
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

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_touch_updated_at
before update on public.profiles
for each row execute function public.touch_updated_at();

create trigger orders_touch_updated_at
before update on public.orders
for each row execute function public.touch_updated_at();

create trigger clients_touch_updated_at
before update on public.clients
for each row execute function public.touch_updated_at();

create or replace function public.products_search_refresh()
returns trigger
language plpgsql
as $$
begin
  new.search_text := lower(unaccent(coalesce(new.codigo,'') || ' ' || coalesce(new.descricao,'') || ' ' ||
    coalesce(new.marca,'') || ' ' || coalesce(new.aplicacao,'') || ' ' ||
    coalesce(new.ano,'') || ' ' || coalesce(new.grupo,'') || ' ' ||
    coalesce(new.categoria,'') || ' ' || coalesce(new.montadora,'') || ' ' ||
    coalesce(new.detalhes,'') || ' ' || coalesce(new.oem,'') || ' ' || coalesce(new."similar",'')));
  new.search_vector := to_tsvector('simple', new.search_text);
  return new;
end;
$$;

create trigger products_search_refresh_insert_update
before insert or update on public.products
for each row execute function public.products_search_refresh();

create or replace function public.current_profile()
returns public.profiles
language sql
stable
security definer
set search_path = public
as $$
  select * from public.profiles where id = auth.uid() and ativo = true limit 1
$$;

create or replace function public.has_module(module_name text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    join public.role_permissions rp on rp.perfil = p.perfil
    where p.id = auth.uid()
      and p.ativo = true
      and rp.modulo = module_name
      and rp.permitido = true
  )
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and ativo = true and perfil = 'ADMIN'
  )
$$;

create or replace function public.max_discount_percent()
returns numeric
language sql
stable
as $$
  select coalesce((value->>'maxDiscountPercent')::numeric, 10)
  from public.settings
  where key = 'commercial'
$$;

create or replace function public.search_products(term text, region text default 'SP', only_available boolean default false, limit_count integer default 40)
returns table (
  codigo text,
  descricao text,
  marca text,
  aplicacao text,
  ano text,
  estoque text,
  preco numeric,
  preco_sp numeric,
  preco_pr numeric,
  status_estoque text,
  status_cadastro text,
  url_imagem text,
  grupo text,
  categoria text,
  montadora text,
  "similar" text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.codigo,
    p.descricao,
    p.marca,
    p.aplicacao,
    p.ano,
    p.estoque,
    case when upper(region) = 'PR' then p.preco_pr else p.preco_sp end as preco,
    p.preco_sp,
    p.preco_pr,
    p.status_estoque,
    p.status_cadastro,
    p.url_imagem,
    p.grupo,
    p.categoria,
    p.montadora,
    p."similar"
  from public.products p
  where public.has_module('produtos')
    and (not only_available or p.estoque_quantidade > 0)
    and (
      lower(unaccent(coalesce(term, ''))) = ''
      or p.search_vector @@ plainto_tsquery('simple', lower(unaccent(term)))
      or p.search_text like '%' || lower(unaccent(term)) || '%'
    )
  order by similarity(p.search_text, lower(unaccent(coalesce(term, '')))) desc, p.codigo
  limit least(greatest(limit_count, 1), 100);
$$;

create or replace function public.create_order(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  session_profile public.profiles;
  new_order_id uuid;
  next_number text;
  item_data jsonb;
  idx integer := 0;
  product_row public.products;
  qty numeric;
  discount numeric;
  unit_price numeric;
  final_unit numeric;
  subtotal_value numeric := 0;
  total_value numeric := 0;
  max_discount numeric := public.max_discount_percent();
begin
  select * into session_profile from public.profiles where id = auth.uid() and ativo = true;
  if session_profile.id is null or not public.has_module('novo_pedido') then
    raise exception 'SEM_PERMISSAO';
  end if;

  if coalesce(payload->>'cliente', '') = '' then
    raise exception 'CLIENTE_OBRIGATORIO';
  end if;

  if jsonb_array_length(coalesce(payload->'items', '[]'::jsonb)) = 0 then
    raise exception 'PEDIDO_SEM_ITENS';
  end if;

  select lpad((coalesce(max(regexp_replace(numero_pedido, '\\D', '', 'g')::integer), 0) + 1)::text, 6, '0')
  into next_number
  from public.orders
  where numero_pedido ~ '^[0-9]+$';

  insert into public.orders (
    numero_pedido, regiao, user_id, vendedor, codigo_sap_cliente, cliente, cnpj, telefone, endereco,
    prazo, transportadora, transportadora_cnpj, transportadora_endereco, observacao, status
  )
  values (
    next_number,
    coalesce((payload->>'regiao')::public.order_region, 'SP'),
    session_profile.id,
    session_profile.nome,
    nullif(payload->>'codigo_sap_cliente', ''),
    payload->>'cliente',
    payload->>'cnpj',
    payload->>'telefone',
    payload->>'endereco',
    payload->>'prazo',
    payload->>'transportadora',
    payload->>'transportadora_cnpj',
    payload->>'transportadora_endereco',
    payload->>'observacao',
    'NOVO'
  )
  returning id into new_order_id;

  for item_data in select * from jsonb_array_elements(payload->'items')
  loop
    idx := idx + 1;
    select * into product_row from public.products where codigo = item_data->>'codigo';
    if product_row.codigo is null then
      raise exception 'PRODUTO_NAO_ENCONTRADO';
    end if;

    qty := greatest(coalesce((item_data->>'quantidade')::numeric, 1), 1);
    discount := greatest(coalesce((item_data->>'desconto_percentual')::numeric, 0), 0);
    if discount > max_discount then
      raise exception 'DESCONTO_MAXIMO_EXCEDIDO';
    end if;

    unit_price := case when coalesce(payload->>'regiao', 'SP') = 'PR' then product_row.preco_pr else product_row.preco_sp end;
    if unit_price <= 0 then
      raise exception 'PRECO_INVALIDO';
    end if;

    final_unit := unit_price * (1 - discount / 100);
    subtotal_value := subtotal_value + (unit_price * qty);
    total_value := total_value + (final_unit * qty);

    insert into public.order_items (
      order_id, item, codigo, descricao, marca, aplicacao, quantidade,
      preco_unitario, desconto_percentual, preco_final_unitario, total_item
    )
    values (
      new_order_id, idx, product_row.codigo, product_row.descricao, product_row.marca,
      product_row.aplicacao, qty, unit_price, discount, final_unit, round(final_unit * qty, 2)
    );
  end loop;

  update public.orders
  set subtotal = round(subtotal_value, 2),
      desconto_total = round(subtotal_value - total_value, 2),
      total = round(total_value, 2)
  where id = new_order_id;

  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (session_profile.id, session_profile.usuario, 'CRIAR_PEDIDO', 'orders', new_order_id::text, payload);

  return jsonb_build_object(
    'id_pedido', new_order_id,
    'numero_pedido', next_number,
    'total', round(total_value, 2)
  );
end;
$$;

alter table public.profiles enable row level security;
alter table public.role_permissions enable row level security;
alter table public.settings enable row level security;
alter table public.products enable row level security;
alter table public.carriers enable row level security;
alter table public.payment_terms enable row level security;
alter table public.clients enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.import_batches enable row level security;
alter table public.import_changes enable row level security;
alter table public.logs enable row level security;

create policy profiles_read on public.profiles for select using (id = auth.uid() or public.is_admin());
create policy profiles_admin_write on public.profiles for all using (public.is_admin()) with check (public.is_admin());

create policy permissions_read on public.role_permissions for select using (auth.uid() is not null);
create policy permissions_admin_write on public.role_permissions for all using (public.is_admin()) with check (public.is_admin());

create policy settings_read on public.settings for select using (auth.uid() is not null);
create policy settings_admin_write on public.settings for all using (public.is_admin()) with check (public.is_admin());

create policy products_read on public.products for select using (public.has_module('produtos') or public.has_module('novo_pedido'));
create policy products_admin_write on public.products for all using (public.has_module('alimentacao') or public.is_admin()) with check (public.has_module('alimentacao') or public.is_admin());

create policy carriers_read on public.carriers for select using (auth.uid() is not null);
create policy carriers_admin_write on public.carriers for all using (public.is_admin()) with check (public.is_admin());

create policy payment_terms_read on public.payment_terms for select using (auth.uid() is not null);
create policy payment_terms_admin_write on public.payment_terms for all using (public.is_admin()) with check (public.is_admin());

create policy clients_read on public.clients for select using (auth.uid() is not null);
create policy clients_write on public.clients for all using (auth.uid() is not null) with check (auth.uid() is not null);

create policy orders_read on public.orders for select using (public.is_admin() or public.has_module('pedidos') or user_id = auth.uid());
create policy orders_create on public.orders for insert with check (public.has_module('novo_pedido') and user_id = auth.uid());
create policy orders_admin_update on public.orders for update using (public.is_admin() or public.has_module('pedidos')) with check (public.is_admin() or public.has_module('pedidos'));

create policy order_items_read on public.order_items for select using (
  exists (select 1 from public.orders o where o.id = order_id and (public.is_admin() or o.user_id = auth.uid() or public.has_module('pedidos')))
);
create policy order_items_create on public.order_items for insert with check (
  exists (select 1 from public.orders o where o.id = order_id and o.user_id = auth.uid())
);

create policy import_read on public.import_batches for select using (public.has_module('alimentacao') or public.is_admin());
create policy import_write on public.import_batches for all using (public.has_module('alimentacao') or public.is_admin()) with check (public.has_module('alimentacao') or public.is_admin());
create policy import_changes_read on public.import_changes for select using (public.has_module('alimentacao') or public.is_admin());
create policy import_changes_write on public.import_changes for all using (public.has_module('alimentacao') or public.is_admin()) with check (public.has_module('alimentacao') or public.is_admin());

create policy logs_read on public.logs for select using (public.has_module('logs') or public.is_admin());
create policy logs_insert on public.logs for insert with check (auth.uid() is not null);

insert into public.settings (key, value)
values ('commercial', '{"maxDiscountPercent":10}'::jsonb)
on conflict (key) do update set value = excluded.value;

insert into public.role_permissions (perfil, modulo, permitido) values
('ADMIN','dashboard',true),
('ADMIN','produtos',true),
('ADMIN','alimentacao',true),
('ADMIN','novo_pedido',true),
('ADMIN','pedidos',true),
('ADMIN','transportadoras',true),
('ADMIN','prazos',true),
('ADMIN','usuarios',true),
('ADMIN','logs',true),
('ADMIN','configuracoes',true),
('SUPERVISOR','dashboard',true),
('SUPERVISOR','produtos',true),
('SUPERVISOR','pedidos',true),
('SUPERVISOR','transportadoras',true),
('SUPERVISOR','prazos',true),
('SUPERVISOR','logs',true),
('VENDEDOR','produtos',true),
('VENDEDOR','novo_pedido',true),
('VENDEDOR','pedidos',true)
on conflict (perfil, modulo) do update set permitido = excluded.permitido;

commit;
