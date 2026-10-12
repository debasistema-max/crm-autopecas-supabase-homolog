create or replace function public.resolve_login_email(login_text text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select p.email
  from public.profiles p
  where p.ativo = true
    and p.email is not null
    and (
      lower(p.usuario) = lower(trim(login_text))
      or lower(p.email) = lower(trim(login_text))
    )
  limit 1
$$;

grant execute on function public.resolve_login_email(text) to anon, authenticated;
