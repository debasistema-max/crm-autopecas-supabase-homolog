insert into public.role_permissions (perfil, modulo, permitido)
values ('ADMIN', 'cadastros', true)
on conflict (perfil, modulo) do update set permitido = excluded.permitido;
