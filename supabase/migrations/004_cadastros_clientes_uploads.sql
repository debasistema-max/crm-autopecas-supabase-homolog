insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'cadastros-clientes',
  'cadastros-clientes',
  false,
  5242880,
  array[
    'application/pdf',
    'image/jpeg',
    'image/png',
    'image/webp'
  ]
)
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

alter table public.cadastros_clientes
  add column if not exists anexos jsonb not null default '[]'::jsonb;
