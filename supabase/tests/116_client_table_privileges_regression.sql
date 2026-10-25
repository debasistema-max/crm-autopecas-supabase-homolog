begin;
do $$
begin
  if exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
    cross join pg_roles r where n.nspname='public' and c.relkind in ('r','p')
    and r.rolname in ('anon','authenticated') and (
      has_table_privilege(r.oid,c.oid,'TRUNCATE') or has_table_privilege(r.oid,c.oid,'REFERENCES')
      or has_table_privilege(r.oid,c.oid,'TRIGGER'))) then raise exception 'CLIENT_ADMIN_PRIVILEGE_REMAINS';end if;
  if not has_table_privilege('authenticated','public.products','SELECT')
    or not has_function_privilege('authenticated','public.search_product_catalog_pricing(jsonb)','EXECUTE')
    or not has_function_privilege('authenticated','public.commercial_create_document(text,jsonb)','EXECUTE')
    or not has_function_privilege('authenticated','public.get_app_session_status()','EXECUTE')
    then raise exception 'EXISTING_CLIENT_ACCESS_BROKEN';end if;
  if has_table_privilege('anon','public.products','SELECT')
    or has_table_privilege('anon','public.profiles','SELECT') then raise exception 'ANON_DATA_EXPOSED';end if;
end $$;
create table public.security_default_privilege_probe_116(id integer);
do $$
begin
  if exists(select 1 from pg_roles r where r.rolname in ('anon','authenticated') and (
    has_table_privilege(r.oid,'public.security_default_privilege_probe_116'::regclass,'TRUNCATE')
    or has_table_privilege(r.oid,'public.security_default_privilege_probe_116'::regclass,'TRIGGER')
    or has_table_privilege(r.oid,'public.security_default_privilege_probe_116'::regclass,'REFERENCES')))
    then raise exception 'UNSAFE_FUTURE_TABLE_DEFAULTS';end if;
end $$;
rollback;
