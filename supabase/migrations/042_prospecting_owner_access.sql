begin;

set local lock_timeout = '10s';
set local statement_timeout = '60s';

create table if not exists public.prospecting_access_users (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  access_level text not null default 'OWNER',
  active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint prospecting_access_users_level_check check (access_level in ('OWNER', 'MANAGER', 'VIEWER'))
);

drop trigger if exists prospecting_access_users_touch_updated_at on public.prospecting_access_users;
create trigger prospecting_access_users_touch_updated_at
before update on public.prospecting_access_users
for each row execute function public.touch_updated_at();

insert into public.prospecting_access_users (profile_id, access_level, active, notes)
select p.id, 'OWNER', true, 'Acesso exclusivo inicial do RADAR Comercial IPS'
from public.profiles p
where lower(p.email) = 'deivid95@gmail.com'
on conflict (profile_id) do update set
  access_level = excluded.access_level,
  active = true,
  notes = excluded.notes;

create or replace function public.can_access_prospecting()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.prospecting_access_users pau
    join public.profiles p on p.id = pau.profile_id
    where pau.profile_id = auth.uid()
      and pau.active
      and p.ativo = true
      and pau.access_level in ('OWNER', 'MANAGER', 'VIEWER')
  )
$$;

create or replace function public.can_manage_prospecting()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.prospecting_access_users pau
    join public.profiles p on p.id = pau.profile_id
    where pau.profile_id = auth.uid()
      and pau.active
      and p.ativo = true
      and pau.access_level in ('OWNER', 'MANAGER')
  )
$$;

alter table public.prospecting_access_users enable row level security;

drop policy if exists prospecting_access_users_read on public.prospecting_access_users;
create policy prospecting_access_users_read on public.prospecting_access_users
for select to authenticated using (public.can_manage_prospecting());

drop policy if exists prospecting_access_users_write on public.prospecting_access_users;
create policy prospecting_access_users_write on public.prospecting_access_users
for all to authenticated using (public.can_manage_prospecting()) with check (public.can_manage_prospecting());

revoke all on public.prospecting_access_users from public, anon, authenticated;
grant select, insert, update, delete on public.prospecting_access_users to authenticated;

revoke all on function
  public.can_access_prospecting(),
  public.can_manage_prospecting()
from public, anon;

grant execute on function
  public.can_access_prospecting(),
  public.can_manage_prospecting()
to authenticated;

update public.role_permissions
set permitido = false
where modulo in ('prospeccao', 'prospeccao_admin')
  and perfil <> 'ADMIN';

commit;
