begin;

-- The Edge Function checks this inexpensive permission predicate before it
-- contacts the external adapter. It reveals only true/false; every mutating RPC
-- still performs its own authorization check.
revoke all on function public.can_manage_data_sync() from public,anon;
grant execute on function public.can_manage_data_sync() to authenticated,service_role;

commit;
