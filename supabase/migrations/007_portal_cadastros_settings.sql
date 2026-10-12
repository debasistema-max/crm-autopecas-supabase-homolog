insert into public.settings (key, value)
values (
  'portal_cadastros',
  jsonb_build_object(
    'email_principal', coalesce(nullif(current_setting('app.cadastro_email_to', true), ''), 'financeiro@ipsbrasil.com.br'),
    'updated_at', now()
  )
)
on conflict (key) do nothing;

grant select on public.settings to authenticated;
