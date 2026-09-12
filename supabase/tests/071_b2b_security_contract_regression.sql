begin;

do $$
begin
  if to_regclass('public.customer_portal_accounts') is null then
    raise exception 'B2B_ACCOUNTS_TABLE_MISSING';
  end if;
  if to_regclass('public.customer_portal_change_requests') is null then
    raise exception 'B2B_CHANGE_REQUESTS_TABLE_MISSING';
  end if;
  if to_regprocedure('public.get_b2b_session()') is null
    or to_regprocedure('public.b2b_search_catalog(text,boolean,integer)') is null
    or to_regprocedure('public.b2b_create_document(text,jsonb)') is null then
    raise exception 'B2B_SCOPED_RPC_MISSING';
  end if;
  if to_regprocedure('public.admin_review_b2b_profile_change(uuid,uuid,uuid,text,text)') is null then
    raise exception 'B2B_ATOMIC_REVIEW_MISSING';
  end if;
  if has_function_privilege('authenticated',
    'public.admin_review_b2b_profile_change(uuid,uuid,uuid,text,text)','EXECUTE') then
    raise exception 'B2B_REVIEW_EXPOSED_TO_BROWSER';
  end if;
  if has_table_privilege('authenticated','public.clients','SELECT') is false then
    raise exception 'INTERNAL_CLIENT_POLICY_CONTRACT_CHANGED';
  end if;
  if not exists (
    select 1 from pg_trigger
    where tgrelid='public.orders'::regclass
      and tgname='orders_link_b2b_client' and not tgisinternal
  ) then raise exception 'ORDER_B2B_CLIENT_LINK_TRIGGER_MISSING'; end if;
  if not exists (
    select 1 from pg_trigger
    where tgrelid='public.quotations'::regclass
      and tgname='quotations_link_b2b_client' and not tgisinternal
  ) then raise exception 'QUOTATION_B2B_CLIENT_LINK_TRIGGER_MISSING'; end if;
end;
$$;

-- Public/anonymous calls must not receive access to the scoped session.
set local role anon;
do $$
begin
  if has_function_privilege(current_user,'public.get_b2b_session()','EXECUTE') then
    raise exception 'B2B_SESSION_EXPOSED_TO_ANON';
  end if;
end;
$$;

rollback;
