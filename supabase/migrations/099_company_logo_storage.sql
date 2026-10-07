insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'company-assets',
  'company-assets',
  true,
  2097152,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists company_assets_admin_insert on storage.objects;
create policy company_assets_admin_insert
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'company-assets'
  and name like 'identity/%'
  and public.is_admin()
);

drop policy if exists company_assets_admin_delete on storage.objects;
create policy company_assets_admin_delete
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'company-assets'
  and name like 'identity/%'
  and public.is_admin()
);
