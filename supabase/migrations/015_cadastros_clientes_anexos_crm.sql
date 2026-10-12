alter table public.cadastros_clientes
  add column if not exists anexos jsonb not null default '[]'::jsonb;

drop policy if exists cadastros_clientes_storage_crm_read on storage.objects;
create policy cadastros_clientes_storage_crm_read
on storage.objects
for select
to authenticated
using (
  bucket_id = 'cadastros-clientes'
  and (
    public.has_module('cadastros')
    or public.is_admin()
  )
);
