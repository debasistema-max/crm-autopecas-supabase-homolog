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
