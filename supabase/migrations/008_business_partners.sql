alter table public.clients
  add column if not exists codigo_sap_cliente text,
  add column if not exists nome_fantasia text,
  add column if not exists email text,
  add column if not exists cidade text,
  add column if not exists estado text,
  add column if not exists ativo boolean not null default true,
  add column if not exists observacoes text;

alter table public.carriers
  add column if not exists email text,
  add column if not exists cidade text,
  add column if not exists estado text,
  add column if not exists observacoes text;

create index if not exists clients_codigo_sap_idx on public.clients (codigo_sap_cliente);
create index if not exists clients_cnpj_idx on public.clients (cnpj);
create index if not exists clients_ativo_idx on public.clients (ativo);
create index if not exists carriers_cnpj_idx on public.carriers (cnpj);
create index if not exists carriers_ativo_idx on public.carriers (ativo);

drop policy if exists clients_read on public.clients;
create policy clients_read
on public.clients
for select
using (auth.uid() is not null);

drop policy if exists clients_write on public.clients;
create policy clients_write
on public.clients
for all
using (public.is_admin() or public.has_module('parceiros'))
with check (public.is_admin() or public.has_module('parceiros'));

drop policy if exists carriers_read on public.carriers;
create policy carriers_read
on public.carriers
for select
using (auth.uid() is not null);

drop policy if exists carriers_admin_write on public.carriers;
create policy carriers_write
on public.carriers
for all
using (public.is_admin() or public.has_module('parceiros'))
with check (public.is_admin() or public.has_module('parceiros'));

insert into public.role_permissions (perfil, modulo, permitido) values
  ('ADMIN','parceiros',true),
  ('SUPERVISOR','parceiros',true),
  ('VENDEDOR','parceiros',true)
on conflict (perfil, modulo) do update set permitido = excluded.permitido;
