begin;
set local lock_timeout='10s';
set local statement_timeout='110s';

-- Browser roles need CRUD under RLS, never table-administration privileges.
revoke truncate, references, trigger on all tables in schema public from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke truncate, references, trigger on tables from anon, authenticated;

do $$
begin
  if exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
    cross join pg_roles r where n.nspname='public' and c.relkind in ('r','p')
    and r.rolname in ('anon','authenticated') and (
      has_table_privilege(r.oid,c.oid,'TRUNCATE') or has_table_privilege(r.oid,c.oid,'REFERENCES')
      or has_table_privilege(r.oid,c.oid,'TRIGGER'))) then raise exception 'CLIENT_ADMIN_PRIVILEGE_REMAINS';end if;
  insert into public.logs(acao,entidade,id_entidade,usuario,dados_novos)
    values('SECURITY_CLIENT_PRIVILEGES_RESTRICTED','database','116','MIGRATION',
      jsonb_build_object('migration','116','roles',jsonb_build_array('anon','authenticated'),
        'revoked',jsonb_build_array('TRUNCATE','REFERENCES','TRIGGER')));
end $$;
commit;
