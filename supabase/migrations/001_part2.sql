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
  similar text
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
    p.similar
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

