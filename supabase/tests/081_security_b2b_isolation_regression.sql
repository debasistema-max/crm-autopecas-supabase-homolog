begin;

select set_config('request.jwt.claims',(
  select jsonb_build_object('sub',a.user_id,'role','authenticated')::text
  from public.customer_portal_accounts a where a.active order by a.created_at limit 1
),true);
select set_config('audit.expected_client_id',(
  select a.client_id::text from public.customer_portal_accounts a
  where a.user_id=auth.uid()
),true);
select set_config('audit.other_order_id',coalesce((
  select o.id::text from public.orders o
  where o.client_id is distinct from current_setting('audit.expected_client_id')::uuid
  order by o.created_at desc limit 1
),''),true);

set local role authenticated;

do $$
declare
  v_count integer;
  v_context jsonb;
  v_allowed boolean;
  v_other text:=current_setting('audit.other_order_id',true);
begin
  select count(*) into v_count from public.products;
  if v_count<>0 then raise exception 'SECURITY_TEST: B2B leu products diretamente'; end if;
  select count(*) into v_count from public.profiles;
  if v_count<>0 then raise exception 'SECURITY_TEST: B2B leu profiles diretamente'; end if;
  select count(*) into v_count from public.clients;
  if v_count<>0 then raise exception 'SECURITY_TEST: B2B leu clients diretamente'; end if;
  select count(*) into v_count from public.customer_portal_accounts;
  if v_count<>1 then raise exception 'SECURITY_TEST: conta B2B fora do proprio escopo: %',v_count; end if;

  v_context:=public.get_b2b_session();
  if v_context->'client'->>'id'<>current_setting('audit.expected_client_id') then
    raise exception 'SECURITY_TEST: sessao B2B vinculada ao cliente errado';
  end if;

  v_allowed:=false;
  begin
    perform public.check_existing_product_codes('["6111032201"]'::jsonb);
    v_allowed:=true;
  exception when insufficient_privilege then null;
            when others then if sqlerrm not like '%SEM_PERMISSAO%' then raise; end if;
  end;
  if v_allowed then raise exception 'SECURITY_TEST: B2B enumerou codigos internos'; end if;

  v_allowed:=false;
  begin
    execute $q$select public.calculate_product_price('6111032201','PR','SC',100,current_date,'REVENDA')$q$;
    v_allowed:=true;
  exception when insufficient_privilege then null;
  end;
  if v_allowed then raise exception 'SECURITY_TEST: B2B executou helper fiscal interno'; end if;

  if nullif(v_other,'') is not null then
    v_allowed:=false;
    begin
      perform public.b2b_get_document('pedido',v_other::uuid);
      v_allowed:=true;
    exception when others then
      if sqlerrm not like '%DOCUMENTO_B2B_NAO_ENCONTRADO%' then raise; end if;
    end;
    if v_allowed then raise exception 'SECURITY_TEST: B2B leu pedido de outro cliente'; end if;
  end if;
end;
$$;

reset role;
rollback;
