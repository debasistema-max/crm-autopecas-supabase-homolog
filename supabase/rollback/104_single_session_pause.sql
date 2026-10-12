-- Emergency rollback: stop enforcement without deleting audit/session metadata.
update public.app_session_policy set enforced=false where id;
notify pgrst,'reload config';
-- Keep secure username login, restricted RPC grants and corrected RLS policies.
