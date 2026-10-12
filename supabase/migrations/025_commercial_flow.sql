begin;

set local lock_timeout = '10s';
set local statement_timeout = '120s';

create sequence if not exists public.order_commercial_number_seq;
create sequence if not exists public.quotation_commercial_number_seq;

do $$
declare
  order_max bigint;
  quote_max bigint;
  current_value bigint;
  already_called boolean;
begin
  select coalesce(max((regexp_match(numero_pedido, '^[0-9]+$'))[1]::bigint), 0)
    into order_max from public.orders;
  select last_value, is_called into current_value, already_called
    from public.order_commercial_number_seq;
  perform setval('public.order_commercial_number_seq', greatest(current_value, order_max, 1), already_called or order_max > 0);

  select coalesce(max((regexp_match(numero_cotacao, '^[0-9]+$'))[1]::bigint), 0)
    into quote_max from public.quotations;
  select last_value, is_called into current_value, already_called
    from public.quotation_commercial_number_seq;
  perform setval('public.quotation_commercial_number_seq', greatest(current_value, quote_max, 1), already_called or quote_max > 0);
end;
$$;

create table if not exists public.customer_favorites (
  user_id uuid not null references public.profiles(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, client_id)
);

create table if not exists public.customer_notes (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  note text not null check (char_length(btrim(note)) between 1 and 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.customer_timeline_events (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  event_type text not null check (event_type in ('PEDIDO_CRIADO', 'PEDIDO_STATUS', 'COTACAO_CRIADA', 'COTACAO_STATUS', 'COTACAO_CONVERTIDA', 'NOTA_CRIADA', 'NOTA_ATUALIZADA')),
  title text not null check (char_length(title) between 1 and 160),
  description text check (description is null or char_length(description) <= 500),
  entity text check (entity is null or entity in ('orders', 'quotations', 'customer_notes')),
  entity_id uuid,
  amount numeric(14,2),
  event_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table if not exists public.quotation_order_conversions (
  quotation_id uuid primary key references public.quotations(id) on delete restrict,
  order_id uuid not null unique references public.orders(id) on delete restrict,
  converted_by uuid not null references public.profiles(id) on delete restrict,
  converted_at timestamptz not null default now()
);

create index if not exists customer_notes_client_created_idx on public.customer_notes (client_id, created_at desc);
create index if not exists customer_notes_user_created_idx on public.customer_notes (user_id, created_at desc);
create index if not exists customer_timeline_client_event_idx on public.customer_timeline_events (client_id, event_at desc);
create index if not exists customer_timeline_user_event_idx on public.customer_timeline_events (user_id, event_at desc);
create index if not exists orders_client_lookup_idx on public.orders (codigo_sap_cliente, cnpj, created_at desc);
create index if not exists quotations_client_lookup_idx on public.quotations (codigo_sap_cliente, cnpj, created_at desc);

drop trigger if exists customer_notes_touch_updated_at on public.customer_notes;
create trigger customer_notes_touch_updated_at
before update on public.customer_notes
for each row execute function public.touch_updated_at();

create or replace function public.commercial_active_profile()
returns public.profiles
language sql
stable
security definer
set search_path = public
as $$
  select p from public.profiles p where p.id = auth.uid() and p.ativo = true
$$;

create or replace function public.can_access_commercial_client(target_client_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    join public.clients c on c.id = target_client_id and c.ativo = true
    where p.id = auth.uid()
      and p.ativo = true
      and (p.perfil = 'ADMIN' or public.has_module('parceiros'))
  )
$$;

create or replace function public.resolve_commercial_client(client_sap text, client_cnpj text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select c.id
  from public.clients c
  where c.ativo = true
    and (
      (nullif(btrim(client_sap), '') is not null and c.codigo_sap_cliente = btrim(client_sap))
      or
      (nullif(regexp_replace(coalesce(client_cnpj, ''), '\D', '', 'g'), '') is not null
       and regexp_replace(coalesce(c.cnpj, ''), '\D', '', 'g') = regexp_replace(client_cnpj, '\D', '', 'g'))
    )
  order by case when c.codigo_sap_cliente = btrim(client_sap) then 0 else 1 end, c.created_at
  limit 1
$$;

alter table public.customer_favorites enable row level security;
alter table public.customer_notes enable row level security;
alter table public.customer_timeline_events enable row level security;
alter table public.quotation_order_conversions enable row level security;

drop policy if exists customer_favorites_own_read on public.customer_favorites;
drop policy if exists customer_favorites_own_insert on public.customer_favorites;
drop policy if exists customer_favorites_own_delete on public.customer_favorites;
drop policy if exists customer_favorites_own_write on public.customer_favorites;
create policy customer_favorites_own_read on public.customer_favorites for select to authenticated using (user_id = auth.uid());
create policy customer_favorites_own_insert on public.customer_favorites for insert to authenticated with check (user_id = auth.uid() and public.can_access_commercial_client(client_id));
create policy customer_favorites_own_delete on public.customer_favorites for delete to authenticated using (user_id = auth.uid());

drop policy if exists customer_notes_scoped_read on public.customer_notes;
drop policy if exists customer_notes_commercial_read on public.customer_notes;
drop policy if exists customer_notes_commercial_write on public.customer_notes;
create policy customer_notes_scoped_read on public.customer_notes for select to authenticated
using (public.is_admin() or user_id = auth.uid());

drop policy if exists customer_timeline_scoped_read on public.customer_timeline_events;
drop policy if exists customer_timeline_commercial_read on public.customer_timeline_events;
drop policy if exists customer_timeline_commercial_write on public.customer_timeline_events;
create policy customer_timeline_scoped_read on public.customer_timeline_events for select to authenticated
using (public.is_admin() or user_id = auth.uid());

drop policy if exists quotation_order_conversions_scoped_read on public.quotation_order_conversions;
create policy quotation_order_conversions_scoped_read on public.quotation_order_conversions for select to authenticated
using (
  public.is_admin()
  or exists (select 1 from public.quotations q where q.id = quotation_id and q.user_id = auth.uid())
);

drop policy if exists orders_read on public.orders;
create policy orders_read on public.orders for select to authenticated
using (public.is_admin() or user_id = auth.uid());

drop policy if exists orders_admin_update on public.orders;
drop policy if exists orders_scoped_update on public.orders;
create policy orders_scoped_update on public.orders for update to authenticated
using (public.is_admin() or user_id = auth.uid())
with check (public.is_admin() or user_id = auth.uid());

drop policy if exists order_items_read on public.order_items;
create policy order_items_read on public.order_items for select to authenticated
using (exists (select 1 from public.orders o where o.id = order_id and (public.is_admin() or o.user_id = auth.uid())));

drop policy if exists quotations_read on public.quotations;
create policy quotations_read on public.quotations for select to authenticated
using (public.is_admin() or user_id = auth.uid());

drop policy if exists quotations_update on public.quotations;
drop policy if exists quotations_scoped_update on public.quotations;
create policy quotations_scoped_update on public.quotations for update to authenticated
using (public.is_admin() or user_id = auth.uid())
with check (public.is_admin() or user_id = auth.uid());

drop policy if exists quotation_items_read on public.quotation_items;
create policy quotation_items_read on public.quotation_items for select to authenticated
using (exists (select 1 from public.quotations q where q.id = quotation_id and (public.is_admin() or q.user_id = auth.uid())));

revoke all on public.customer_favorites, public.customer_notes, public.customer_timeline_events, public.quotation_order_conversions from public, anon;
revoke all on public.customer_favorites, public.customer_notes, public.customer_timeline_events, public.quotation_order_conversions from authenticated;
grant select, insert, delete on public.customer_favorites to authenticated;
grant select on public.customer_notes, public.customer_timeline_events, public.quotation_order_conversions to authenticated;
revoke all on public.orders, public.order_items, public.quotations, public.quotation_items from public, anon, authenticated;
grant select on public.orders, public.order_items, public.quotations, public.quotation_items to authenticated;
revoke all on sequence public.order_commercial_number_seq, public.quotation_commercial_number_seq from public, anon, authenticated;

insert into public.role_permissions (perfil, modulo, permitido)
values ('SUPERVISOR', 'novo_pedido', true)
on conflict (perfil, modulo) do update set permitido = excluded.permitido;

create or replace function public.commercial_create_document(document_type text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  item_data jsonb;
  product_row public.products;
  new_id uuid;
  document_number text;
  idx integer := 0;
  qty numeric;
  discount numeric;
  unit_price numeric;
  final_unit numeric;
  subtotal_value numeric := 0;
  total_value numeric := 0;
  max_discount numeric := public.max_discount_percent();
  region_value public.order_region;
begin
  actor := public.commercial_active_profile();
  if actor.id is null then raise exception 'SEM_PERMISSAO'; end if;
  if document_type = 'pedido' and not public.has_module('novo_pedido') then raise exception 'SEM_PERMISSAO'; end if;
  if document_type = 'cotacao' and not public.has_module('nova_cotacao') then raise exception 'SEM_PERMISSAO'; end if;
  if document_type not in ('pedido', 'cotacao') then raise exception 'TIPO_DOCUMENTO_INVALIDO'; end if;
  if coalesce(btrim(payload->>'cliente'), '') = '' then raise exception 'CLIENTE_OBRIGATORIO'; end if;
  if jsonb_typeof(payload->'items') <> 'array' or jsonb_array_length(payload->'items') = 0 then raise exception 'ITENS_OBRIGATORIOS'; end if;
  region_value := coalesce(nullif(payload->>'regiao', ''), 'SP')::public.order_region;

  if document_type = 'pedido' then
    document_number := lpad(nextval('public.order_commercial_number_seq')::text, 6, '0');
    insert into public.orders (
      numero_pedido, regiao, user_id, vendedor, codigo_sap_cliente, cliente, cnpj, telefone, endereco,
      prazo, transportadora, transportadora_cnpj, transportadora_endereco, observacao, status
    ) values (
      document_number, region_value, actor.id, actor.nome, nullif(btrim(payload->>'codigo_sap_cliente'), ''), btrim(payload->>'cliente'),
      nullif(regexp_replace(coalesce(payload->>'cnpj', ''), '\D', '', 'g'), ''), nullif(btrim(payload->>'telefone'), ''),
      nullif(btrim(payload->>'endereco'), ''), nullif(btrim(payload->>'prazo'), ''), nullif(btrim(payload->>'transportadora'), ''),
      nullif(regexp_replace(coalesce(payload->>'transportadora_cnpj', ''), '\D', '', 'g'), ''),
      nullif(btrim(payload->>'transportadora_endereco'), ''), nullif(btrim(payload->>'observacao'), ''), 'NOVO'
    ) returning id into new_id;
  else
    document_number := lpad(nextval('public.quotation_commercial_number_seq')::text, 6, '0');
    insert into public.quotations (
      numero_cotacao, regiao, user_id, vendedor, codigo_sap_cliente, cliente, cnpj, telefone, endereco,
      prazo, transportadora, transportadora_cnpj, transportadora_endereco, observacao, status
    ) values (
      document_number, region_value, actor.id, actor.nome, nullif(btrim(payload->>'codigo_sap_cliente'), ''), btrim(payload->>'cliente'),
      nullif(regexp_replace(coalesce(payload->>'cnpj', ''), '\D', '', 'g'), ''), nullif(btrim(payload->>'telefone'), ''),
      nullif(btrim(payload->>'endereco'), ''), nullif(btrim(payload->>'prazo'), ''), nullif(btrim(payload->>'transportadora'), ''),
      nullif(regexp_replace(coalesce(payload->>'transportadora_cnpj', ''), '\D', '', 'g'), ''),
      nullif(btrim(payload->>'transportadora_endereco'), ''), nullif(btrim(payload->>'observacao'), ''), 'NOVA'
    ) returning id into new_id;
  end if;

  for item_data in select value from jsonb_array_elements(payload->'items') loop
    idx := idx + 1;
    select * into product_row from public.products where codigo = btrim(item_data->>'codigo');
    if product_row.codigo is null then raise exception 'PRODUTO_NAO_ENCONTRADO: item %', idx; end if;
    qty := coalesce(nullif(item_data->>'quantidade', '')::numeric, 0);
    discount := coalesce(nullif(item_data->>'desconto_percentual', '')::numeric, 0);
    if qty <= 0 then raise exception 'QUANTIDADE_INVALIDA: item %', idx; end if;
    if discount < 0 or discount > max_discount then raise exception 'DESCONTO_INVALIDO: item %', idx; end if;
    unit_price := case when region_value = 'PR' then product_row.preco_pr else product_row.preco_sp end;
    if unit_price is null or unit_price < 0 then raise exception 'PRECO_INVALIDO: item %', idx; end if;
    final_unit := round(unit_price * (1 - discount / 100), 4);
    subtotal_value := subtotal_value + unit_price * qty;
    total_value := total_value + final_unit * qty;

    if document_type = 'pedido' then
      insert into public.order_items (order_id, item, codigo, descricao, marca, aplicacao, quantidade, preco_unitario, desconto_percentual, preco_final_unitario, total_item)
      values (new_id, idx, product_row.codigo, product_row.descricao, product_row.marca, product_row.aplicacao, qty, unit_price, discount, final_unit, round(final_unit * qty, 2));
    else
      insert into public.quotation_items (quotation_id, item, codigo, descricao, marca, aplicacao, quantidade, preco_unitario, desconto_percentual, preco_final_unitario, total_item)
      values (new_id, idx, product_row.codigo, product_row.descricao, product_row.marca, product_row.aplicacao, qty, unit_price, discount, final_unit, round(final_unit * qty, 2));
    end if;
  end loop;

  if document_type = 'pedido' then
    update public.orders set subtotal = round(subtotal_value, 2), desconto_total = round(subtotal_value - total_value, 2), total = round(total_value, 2) where id = new_id;
  else
    update public.quotations set subtotal = round(subtotal_value, 2), desconto_total = round(subtotal_value - total_value, 2), total = round(total_value, 2) where id = new_id;
  end if;
  update public.customer_timeline_events set amount = round(total_value, 2)
  where entity_id = new_id and event_type in ('PEDIDO_CRIADO', 'COTACAO_CRIADA');

  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (actor.id, actor.usuario, case when document_type = 'pedido' then 'CRIAR_PEDIDO' else 'CRIAR_COTACAO' end,
          case when document_type = 'pedido' then 'orders' else 'quotations' end, new_id::text,
          jsonb_build_object('numero', document_number, 'itens', idx, 'total', round(total_value, 2)));
  return jsonb_build_object('id', new_id, case when document_type = 'pedido' then 'numero_pedido' else 'numero_cotacao' end, document_number);
exception when invalid_text_representation or numeric_value_out_of_range then
  raise exception 'VALOR_NUMERICO_INVALIDO';
end;
$$;

create or replace function public.commercial_create_order(payload jsonb) returns jsonb
language sql security definer set search_path = public
as $$ select public.commercial_create_document('pedido', payload) $$;

create or replace function public.commercial_create_quotation(payload jsonb) returns jsonb
language sql security definer set search_path = public
as $$ select public.commercial_create_document('cotacao', payload) $$;

create or replace function public.commercial_update_document_items(document_type text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  owner_id uuid;
  current_status text;
  region_value public.order_region;
  item_data jsonb;
  product_row public.products;
  target_id uuid;
  idx integer := 0;
  qty numeric;
  discount numeric;
  unit_price numeric;
  final_unit numeric;
  subtotal_value numeric := 0;
  total_value numeric := 0;
  max_discount numeric := public.max_discount_percent();
begin
  actor := public.commercial_active_profile();
  if actor.id is null then raise exception 'SEM_PERMISSAO'; end if;
  if document_type = 'pedido' and not (actor.perfil = 'ADMIN' or public.has_module('pedidos')) then raise exception 'SEM_PERMISSAO'; end if;
  if document_type = 'cotacao' and not (actor.perfil = 'ADMIN' or public.has_module('cotacoes')) then raise exception 'SEM_PERMISSAO'; end if;
  target_id := (payload->>'id')::uuid;
  if jsonb_typeof(payload->'items') <> 'array' or jsonb_array_length(payload->'items') = 0 then raise exception 'ITENS_OBRIGATORIOS'; end if;

  if document_type = 'pedido' then
    select user_id, status::text, regiao into owner_id, current_status, region_value from public.orders where id = target_id for update;
    if current_status not in ('NOVO', 'EM_ANALISE') then raise exception 'PEDIDO_NAO_EDITAVEL'; end if;
  elsif document_type = 'cotacao' then
    select user_id, status::text, regiao into owner_id, current_status, region_value from public.quotations where id = target_id for update;
    if current_status not in ('NOVA', 'ENVIADA') then raise exception 'COTACAO_NAO_EDITAVEL'; end if;
  else raise exception 'TIPO_DOCUMENTO_INVALIDO';
  end if;
  if owner_id is null then raise exception 'DOCUMENTO_NAO_ENCONTRADO'; end if;
  if actor.perfil <> 'ADMIN' and owner_id <> actor.id then raise exception 'SEM_PERMISSAO'; end if;

  if document_type = 'pedido' then delete from public.order_items where order_id = target_id;
  else delete from public.quotation_items where quotation_id = target_id; end if;

  for item_data in select value from jsonb_array_elements(payload->'items') loop
    idx := idx + 1;
    select * into product_row from public.products where codigo = btrim(item_data->>'codigo');
    if product_row.codigo is null then raise exception 'PRODUTO_NAO_ENCONTRADO: item %', idx; end if;
    qty := coalesce(nullif(item_data->>'quantidade', '')::numeric, 0);
    discount := coalesce(nullif(item_data->>'desconto_percentual', '')::numeric, 0);
    if qty <= 0 then raise exception 'QUANTIDADE_INVALIDA: item %', idx; end if;
    if discount < 0 or discount > max_discount then raise exception 'DESCONTO_INVALIDO: item %', idx; end if;
    unit_price := case when region_value = 'PR' then product_row.preco_pr else product_row.preco_sp end;
    if unit_price is null or unit_price < 0 then raise exception 'PRECO_INVALIDO: item %', idx; end if;
    final_unit := round(unit_price * (1 - discount / 100), 4);
    subtotal_value := subtotal_value + unit_price * qty;
    total_value := total_value + final_unit * qty;
    if document_type = 'pedido' then
      insert into public.order_items (order_id, item, codigo, descricao, marca, aplicacao, quantidade, preco_unitario, desconto_percentual, preco_final_unitario, total_item)
      values (target_id, idx, product_row.codigo, product_row.descricao, product_row.marca, product_row.aplicacao, qty, unit_price, discount, final_unit, round(final_unit * qty, 2));
    else
      insert into public.quotation_items (quotation_id, item, codigo, descricao, marca, aplicacao, quantidade, preco_unitario, desconto_percentual, preco_final_unitario, total_item)
      values (target_id, idx, product_row.codigo, product_row.descricao, product_row.marca, product_row.aplicacao, qty, unit_price, discount, final_unit, round(final_unit * qty, 2));
    end if;
  end loop;

  if document_type = 'pedido' then
    update public.orders set subtotal = round(subtotal_value, 2), desconto_total = round(subtotal_value - total_value, 2), total = round(total_value, 2) where id = target_id;
  else
    update public.quotations set subtotal = round(subtotal_value, 2), desconto_total = round(subtotal_value - total_value, 2), total = round(total_value, 2) where id = target_id;
  end if;
  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (actor.id, actor.usuario, 'ATUALIZAR_ITENS', case when document_type = 'pedido' then 'orders' else 'quotations' end,
          target_id::text, jsonb_build_object('itens', idx, 'total', round(total_value, 2)));
  return jsonb_build_object('id', target_id, 'subtotal', round(subtotal_value, 2), 'desconto_total', round(subtotal_value - total_value, 2), 'total', round(total_value, 2));
end;
$$;

create or replace function public.commercial_update_order_items(payload jsonb) returns jsonb
language sql security definer set search_path = public
as $$ select public.commercial_update_document_items('pedido', payload) $$;

create or replace function public.commercial_update_quotation_items(payload jsonb) returns jsonb
language sql security definer set search_path = public
as $$ select public.commercial_update_document_items('cotacao', payload) $$;

create or replace function public.commercial_update_document_status(document_type text, target_id uuid, target_status text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare actor public.profiles; owner_id uuid; old_status text;
begin
  actor := public.commercial_active_profile();
  if actor.id is null then raise exception 'SEM_PERMISSAO'; end if;
  if document_type = 'pedido' and not (actor.perfil = 'ADMIN' or public.has_module('pedidos')) then raise exception 'SEM_PERMISSAO'; end if;
  if document_type = 'cotacao' and not (actor.perfil = 'ADMIN' or public.has_module('cotacoes')) then raise exception 'SEM_PERMISSAO'; end if;
  if document_type = 'pedido' then
    select user_id, status::text into owner_id, old_status from public.orders where id = target_id for update;
    if owner_id is null then raise exception 'DOCUMENTO_NAO_ENCONTRADO'; end if;
    if actor.perfil <> 'ADMIN' and owner_id <> actor.id then raise exception 'SEM_PERMISSAO'; end if;
    if not ((old_status = 'NOVO' and target_status in ('EM_ANALISE','APROVADO','CANCELADO')) or
            (old_status = 'EM_ANALISE' and target_status in ('APROVADO','CANCELADO')) or
            (old_status = 'APROVADO' and target_status in ('FATURADO','CANCELADO')) or old_status = target_status)
    then raise exception 'TRANSICAO_STATUS_INVALIDA'; end if;
    update public.orders set status = target_status::public.order_status where id = target_id;
  elsif document_type = 'cotacao' then
    select user_id, status::text into owner_id, old_status from public.quotations where id = target_id for update;
    if owner_id is null then raise exception 'DOCUMENTO_NAO_ENCONTRADO'; end if;
    if actor.perfil <> 'ADMIN' and owner_id <> actor.id then raise exception 'SEM_PERMISSAO'; end if;
    if not ((old_status = 'NOVA' and target_status in ('ENVIADA','APROVADA','CANCELADA')) or
            (old_status = 'ENVIADA' and target_status in ('APROVADA','CANCELADA')) or old_status = target_status)
    then raise exception 'TRANSICAO_STATUS_INVALIDA'; end if;
    update public.quotations set status = target_status::public.quotation_status where id = target_id;
  else raise exception 'TIPO_DOCUMENTO_INVALIDO'; end if;
  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (actor.id, actor.usuario, 'ATUALIZAR_STATUS', case when document_type = 'pedido' then 'orders' else 'quotations' end,
          target_id::text, jsonb_build_object('anterior', old_status, 'novo', target_status));
  return jsonb_build_object('id', target_id, 'status', target_status);
end;
$$;

create or replace function public.commercial_update_order_status(target_id uuid, target_status text) returns jsonb
language sql security definer set search_path = public
as $$ select public.commercial_update_document_status('pedido', target_id, target_status) $$;

create or replace function public.commercial_update_quotation_status(target_id uuid, target_status text) returns jsonb
language sql security definer set search_path = public
as $$ select public.commercial_update_document_status('cotacao', target_id, target_status) $$;

create or replace function public.capture_commercial_timeline_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  target_client uuid;
  event_kind text;
  event_title text;
  event_description text;
  entity_name text;
  document_number text;
begin
  target_client := public.resolve_commercial_client(new.codigo_sap_cliente, new.cnpj);
  if target_client is null or new.user_id is null then return new; end if;

  if tg_table_name = 'orders' then
    entity_name := 'orders';
    document_number := new.numero_pedido;
    if tg_op = 'INSERT' then event_kind := 'PEDIDO_CRIADO'; event_title := 'Pedido ' || new.numero_pedido || ' criado';
    elsif old.status is distinct from new.status then event_kind := 'PEDIDO_STATUS'; event_title := 'Status do pedido ' || new.numero_pedido; event_description := old.status::text || ' -> ' || new.status::text;
    else return new; end if;
  else
    entity_name := 'quotations';
    document_number := new.numero_cotacao;
    if tg_op = 'INSERT' then event_kind := 'COTACAO_CRIADA'; event_title := 'Cotacao ' || new.numero_cotacao || ' criada';
    elsif old.status is distinct from new.status then
      event_kind := case when new.status = 'CONVERTIDA' then 'COTACAO_CONVERTIDA' else 'COTACAO_STATUS' end;
      event_title := 'Status da cotacao ' || new.numero_cotacao;
      event_description := old.status::text || ' -> ' || new.status::text;
    else return new; end if;
  end if;

  insert into public.customer_timeline_events(client_id,user_id,event_type,title,description,entity,entity_id,amount,event_at)
  values(target_client,new.user_id,event_kind,event_title,event_description,entity_name,new.id,new.total,coalesce(new.updated_at,new.created_at,now()));
  return new;
end;
$$;

drop trigger if exists orders_commercial_timeline on public.orders;
create trigger orders_commercial_timeline after insert or update of status on public.orders
for each row execute function public.capture_commercial_timeline_event();

drop trigger if exists quotations_commercial_timeline on public.quotations;
create trigger quotations_commercial_timeline after insert or update of status on public.quotations
for each row execute function public.capture_commercial_timeline_event();

create or replace function public.get_customer_commercial_profile(target_client_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare actor public.profiles; client_row public.clients; admin_access boolean; result jsonb;
begin
  actor := public.commercial_active_profile();
  if actor.id is null or not public.can_access_commercial_client(target_client_id) then raise exception 'SEM_PERMISSAO'; end if;
  admin_access := actor.perfil = 'ADMIN';
  select * into client_row from public.clients where id = target_client_id;
  if client_row.id is null then raise exception 'CLIENTE_NAO_ENCONTRADO'; end if;

  with scoped_orders as (
    select o.* from public.orders o where (admin_access or o.user_id = actor.id) and
      ((client_row.codigo_sap_cliente is not null and o.codigo_sap_cliente = client_row.codigo_sap_cliente) or
       (nullif(regexp_replace(coalesce(client_row.cnpj,''),'\D','','g'),'') is not null and regexp_replace(coalesce(o.cnpj,''),'\D','','g') = regexp_replace(client_row.cnpj,'\D','','g')))
  ), scoped_quotes as (
    select q.* from public.quotations q where (admin_access or q.user_id = actor.id) and
      ((client_row.codigo_sap_cliente is not null and q.codigo_sap_cliente = client_row.codigo_sap_cliente) or
       (nullif(regexp_replace(coalesce(client_row.cnpj,''),'\D','','g'),'') is not null and regexp_replace(coalesce(q.cnpj,''),'\D','','g') = regexp_replace(client_row.cnpj,'\D','','g')))
  )
  select jsonb_build_object(
    'client', to_jsonb(client_row) - 'observacoes',
    'favorite', exists(select 1 from public.customer_favorites f where f.client_id = target_client_id and f.user_id = actor.id),
    'metrics', jsonb_build_object(
      'total_orders', (select count(*) from scoped_orders),
      'total_quotations', (select count(*) from scoped_quotes),
      'converted_quotations', (select count(*) from scoped_quotes where status = 'CONVERTIDA'),
      'conversion_rate', coalesce((select round(100.0 * count(*) filter (where status = 'CONVERTIDA') / nullif(count(*),0), 2) from scoped_quotes), 0),
      'purchased_value', coalesce((select round(sum(total),2) from scoped_orders where status <> 'CANCELADO'),0),
      'average_ticket', coalesce((select round(avg(total),2) from scoped_orders where status <> 'CANCELADO'),0)
    ),
    'orders', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (select id,numero_pedido,created_at,regiao,vendedor,status,total from scoped_orders order by created_at desc limit 10) x),'[]'::jsonb),
    'quotations', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (select id,numero_cotacao,created_at,regiao,vendedor,status,total from scoped_quotes order by created_at desc limit 10) x),'[]'::jsonb),
    'notes', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (select n.id,n.note,n.created_at,n.updated_at,p.nome usuario,n.user_id = actor.id can_edit from public.customer_notes n left join public.profiles p on p.id=n.user_id where n.client_id=target_client_id and (admin_access or n.user_id=actor.id) order by n.created_at desc limit 20) x),'[]'::jsonb),
    'timeline', coalesce((select jsonb_agg(to_jsonb(x) order by x.event_at desc) from (select event_type,title,description,entity,entity_id,amount,event_at from public.customer_timeline_events where client_id=target_client_id and (admin_access or user_id=actor.id) order by event_at desc limit 50) x),'[]'::jsonb)
  ) into result;
  return result;
end;
$$;

create or replace function public.add_customer_note(target_client_id uuid, note_text text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare actor public.profiles; note_row public.customer_notes;
begin
  actor := public.commercial_active_profile();
  if actor.id is null or not public.can_access_commercial_client(target_client_id) then raise exception 'SEM_PERMISSAO'; end if;
  if char_length(btrim(coalesce(note_text,''))) not between 1 and 2000 then raise exception 'OBSERVACAO_INVALIDA'; end if;
  insert into public.customer_notes(client_id,user_id,note) values(target_client_id,actor.id,btrim(note_text)) returning * into note_row;
  insert into public.customer_timeline_events(client_id,user_id,event_type,title,description,entity,entity_id)
  values(target_client_id,actor.id,'NOTA_CRIADA','Observacao comercial',left(btrim(note_text),500),'customer_notes',note_row.id);
  return to_jsonb(note_row);
end;
$$;

create or replace function public.update_customer_note(target_note_id uuid, note_text text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare actor public.profiles; note_row public.customer_notes;
begin
  actor := public.commercial_active_profile();
  if actor.id is null or not (actor.perfil = 'ADMIN' or public.has_module('parceiros')) then raise exception 'SEM_PERMISSAO'; end if;
  if char_length(btrim(coalesce(note_text,''))) not between 1 and 2000 then raise exception 'OBSERVACAO_INVALIDA'; end if;
  update public.customer_notes set note=btrim(note_text)
  where id=target_note_id and (actor.perfil='ADMIN' or user_id=actor.id) returning * into note_row;
  if note_row.id is null then raise exception 'SEM_PERMISSAO'; end if;
  insert into public.customer_timeline_events(client_id,user_id,event_type,title,description,entity,entity_id)
  values(note_row.client_id,actor.id,'NOTA_ATUALIZADA','Observacao comercial atualizada',left(btrim(note_text),500),'customer_notes',note_row.id);
  return to_jsonb(note_row);
end;
$$;

create or replace function public.delete_customer_note(target_note_id uuid)
returns boolean language plpgsql security definer set search_path = public
as $$
declare actor public.profiles; removed_id uuid;
begin
  actor := public.commercial_active_profile();
  if actor.id is null or not (actor.perfil = 'ADMIN' or public.has_module('parceiros')) then raise exception 'SEM_PERMISSAO'; end if;
  delete from public.customer_notes where id=target_note_id and (actor.perfil='ADMIN' or user_id=actor.id) returning id into removed_id;
  if removed_id is null then raise exception 'SEM_PERMISSAO'; end if;
  return true;
end;
$$;

create or replace function public.toggle_customer_favorite(target_client_id uuid, favorite boolean)
returns boolean language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null or not public.can_access_commercial_client(target_client_id) then raise exception 'SEM_PERMISSAO'; end if;
  if favorite then insert into public.customer_favorites(user_id,client_id) values(auth.uid(),target_client_id) on conflict do nothing;
  else delete from public.customer_favorites where user_id=auth.uid() and client_id=target_client_id; end if;
  return favorite;
end;
$$;

create or replace function public.convert_quotation_to_order(target_quotation_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare actor public.profiles; source public.quotations; new_order_id uuid; new_number text; existing public.quotation_order_conversions; item_count integer;
begin
  actor := public.commercial_active_profile();
  if actor.id is null or not public.has_module('novo_pedido') or not public.has_module('cotacoes') then raise exception 'SEM_PERMISSAO'; end if;
  select * into source from public.quotations where id=target_quotation_id for update;
  if source.id is null then raise exception 'COTACAO_NAO_ENCONTRADA'; end if;
  if actor.perfil <> 'ADMIN' and source.user_id <> actor.id then raise exception 'SEM_PERMISSAO'; end if;
  select * into existing from public.quotation_order_conversions where quotation_id=source.id;
  if existing.quotation_id is not null then
    return (select jsonb_build_object('id_pedido',o.id,'numero_pedido',o.numero_pedido,'numero_cotacao',source.numero_cotacao,'already_converted',true) from public.orders o where o.id=existing.order_id);
  end if;
  if source.status <> 'APROVADA' then raise exception 'COTACAO_NAO_APROVADA'; end if;
  select count(*) into item_count from public.quotation_items where quotation_id=source.id;
  if item_count=0 then raise exception 'COTACAO_SEM_ITENS'; end if;
  new_number := lpad(nextval('public.order_commercial_number_seq')::text,6,'0');
  insert into public.orders(numero_pedido,regiao,user_id,vendedor,codigo_sap_cliente,cliente,cnpj,telefone,endereco,prazo,transportadora,transportadora_cnpj,transportadora_endereco,observacao,subtotal,desconto_total,total,status)
  values(new_number,source.regiao,source.user_id,source.vendedor,source.codigo_sap_cliente,source.cliente,source.cnpj,source.telefone,source.endereco,source.prazo,source.transportadora,source.transportadora_cnpj,source.transportadora_endereco,nullif(concat_ws(E'\n',source.observacao,'Convertido da cotacao '||source.numero_cotacao),''),source.subtotal,source.desconto_total,source.total,'NOVO') returning id into new_order_id;
  insert into public.order_items(order_id,item,codigo,descricao,marca,aplicacao,quantidade,preco_unitario,desconto_percentual,preco_final_unitario,total_item)
  select new_order_id,item,codigo,descricao,marca,aplicacao,quantidade,preco_unitario,desconto_percentual,preco_final_unitario,total_item from public.quotation_items where quotation_id=source.id order by item;
  insert into public.quotation_order_conversions(quotation_id,order_id,converted_by) values(source.id,new_order_id,actor.id);
  update public.quotations set status='CONVERTIDA' where id=source.id;
  insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_novos) values(actor.id,actor.usuario,'CONVERTER_COTACAO_PEDIDO','orders',new_order_id::text,jsonb_build_object('quotation_id',source.id,'numero_cotacao',source.numero_cotacao));
  return jsonb_build_object('id_pedido',new_order_id,'numero_pedido',new_number,'numero_cotacao',source.numero_cotacao,'already_converted',false);
end;
$$;

revoke execute on function public.create_order(jsonb), public.create_quotation(jsonb), public.update_order_items(jsonb), public.update_quotation_items(jsonb), public.update_document_status(jsonb) from public, anon, authenticated;
revoke execute on function public.commercial_active_profile(), public.can_access_commercial_client(uuid), public.resolve_commercial_client(text,text), public.commercial_create_document(text,jsonb), public.commercial_update_document_items(text,jsonb), public.commercial_update_document_status(text,uuid,text), public.capture_commercial_timeline_event() from public, anon, authenticated;
grant execute on function public.can_access_commercial_client(uuid) to authenticated;
revoke execute on function public.commercial_create_order(jsonb), public.commercial_create_quotation(jsonb), public.commercial_update_order_items(jsonb), public.commercial_update_quotation_items(jsonb), public.commercial_update_order_status(uuid,text), public.commercial_update_quotation_status(uuid,text), public.get_customer_commercial_profile(uuid), public.add_customer_note(uuid,text), public.update_customer_note(uuid,text), public.delete_customer_note(uuid), public.toggle_customer_favorite(uuid,boolean), public.convert_quotation_to_order(uuid) from public, anon;
grant execute on function public.commercial_create_order(jsonb), public.commercial_create_quotation(jsonb), public.commercial_update_order_items(jsonb), public.commercial_update_quotation_items(jsonb), public.commercial_update_order_status(uuid,text), public.commercial_update_quotation_status(uuid,text), public.get_customer_commercial_profile(uuid), public.add_customer_note(uuid,text), public.update_customer_note(uuid,text), public.delete_customer_note(uuid), public.toggle_customer_favorite(uuid,boolean), public.convert_quotation_to_order(uuid) to authenticated;

commit;
