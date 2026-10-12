do $$
begin
  create type public.quotation_status as enum ('NOVA', 'ENVIADA', 'APROVADA', 'CANCELADA', 'CONVERTIDA');
exception
  when duplicate_object then null;
end
$$;

create table if not exists public.quotations (
  id uuid primary key default gen_random_uuid(),
  numero_cotacao text unique,
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
  status public.quotation_status not null default 'NOVA',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.quotation_items (
  id uuid primary key default gen_random_uuid(),
  quotation_id uuid not null references public.quotations(id) on delete cascade,
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
  unique (quotation_id, item)
);

create index if not exists quotations_user_created_idx on public.quotations (user_id, created_at desc);
create index if not exists quotations_status_idx on public.quotations (status);
create index if not exists quotations_codigo_sap_cliente_idx on public.quotations (codigo_sap_cliente);

drop trigger if exists quotations_touch_updated_at on public.quotations;
create trigger quotations_touch_updated_at
before update on public.quotations
for each row execute function public.touch_updated_at();

alter table public.quotations enable row level security;
alter table public.quotation_items enable row level security;

drop policy if exists quotations_read on public.quotations;
create policy quotations_read on public.quotations
for select using (public.is_admin() or public.has_module('cotacoes') or user_id = auth.uid());

drop policy if exists quotations_create on public.quotations;
create policy quotations_create on public.quotations
for insert with check (public.has_module('nova_cotacao') and user_id = auth.uid());

drop policy if exists quotations_update on public.quotations;
create policy quotations_update on public.quotations
for update using (public.is_admin() or public.has_module('cotacoes')) with check (public.is_admin() or public.has_module('cotacoes'));

drop policy if exists quotation_items_read on public.quotation_items;
create policy quotation_items_read on public.quotation_items
for select using (
  exists (
    select 1 from public.quotations q
    where q.id = quotation_id
      and (public.is_admin() or q.user_id = auth.uid() or public.has_module('cotacoes'))
  )
);

drop policy if exists quotation_items_create on public.quotation_items;
create policy quotation_items_create on public.quotation_items
for insert with check (
  exists (
    select 1 from public.quotations q
    where q.id = quotation_id and q.user_id = auth.uid()
  )
);

drop policy if exists products_read on public.products;
create policy products_read on public.products
for select using (public.has_module('produtos') or public.has_module('novo_pedido') or public.has_module('nova_cotacao'));

create or replace function public.create_quotation(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  session_profile public.profiles;
  new_quotation_id uuid;
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
  if session_profile.id is null or not public.has_module('nova_cotacao') then
    raise exception 'SEM_PERMISSAO';
  end if;

  if coalesce(payload->>'cliente', '') = '' then
    raise exception 'CLIENTE_OBRIGATORIO';
  end if;

  if jsonb_array_length(coalesce(payload->'items', '[]'::jsonb)) = 0 then
    raise exception 'COTACAO_SEM_ITENS';
  end if;

  select 'COT-' || lpad((coalesce(max(regexp_replace(numero_cotacao, '\\D', '', 'g')::integer), 0) + 1)::text, 6, '0')
  into next_number
  from public.quotations
  where numero_cotacao ~ '^COT-[0-9]+$';

  insert into public.quotations (
    numero_cotacao, regiao, user_id, vendedor, codigo_sap_cliente, cliente, cnpj, telefone, endereco,
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
    'NOVA'
  )
  returning id into new_quotation_id;

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

    insert into public.quotation_items (
      quotation_id, item, codigo, descricao, marca, aplicacao, quantidade,
      preco_unitario, desconto_percentual, preco_final_unitario, total_item
    )
    values (
      new_quotation_id, idx, product_row.codigo, product_row.descricao, product_row.marca,
      product_row.aplicacao, qty, unit_price, discount, final_unit, round(final_unit * qty, 2)
    );
  end loop;

  update public.quotations
  set subtotal = round(subtotal_value, 2),
      desconto_total = round(subtotal_value - total_value, 2),
      total = round(total_value, 2)
  where id = new_quotation_id;

  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (session_profile.id, session_profile.usuario, 'CRIAR_COTACAO', 'quotations', new_quotation_id::text, payload);

  return jsonb_build_object(
    'id_cotacao', new_quotation_id,
    'numero_cotacao', next_number,
    'total', round(total_value, 2)
  );
end;
$$;

insert into public.role_permissions (perfil, modulo, permitido) values
  ('ADMIN','nova_cotacao',true),
  ('ADMIN','cotacoes',true),
  ('SUPERVISOR','nova_cotacao',true),
  ('SUPERVISOR','cotacoes',true),
  ('VENDEDOR','nova_cotacao',true),
  ('VENDEDOR','cotacoes',true)
on conflict (perfil, modulo) do update set permitido = excluded.permitido;
