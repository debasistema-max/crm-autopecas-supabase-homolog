begin;

select set_config(
  'request.jwt.claim.sub',
  (select id::text from public.profiles where ativo and perfil::text='VENDEDOR' order by created_at limit 1),
  true
);
set local role authenticated;

do $$
declare
  clients jsonb;
  request_result jsonb;
begin
  if not public.is_crm_seller() then raise exception 'SELLER_ROLE_NOT_DETECTED'; end if;

  clients:=public.list_business_clients_scoped('{}'::jsonb);
  if exists(
    select 1 from jsonb_array_elements(clients) x
    where x->>'assigned_seller_id'<>auth.uid()::text
  ) then raise exception 'PORTFOLIO_SCOPE_INVALID'; end if;
  if exists(
    select 1 from jsonb_array_elements(clients) x
    where x->'commercial_discount_percent'<>'null'::jsonb
  ) then raise exception 'SELLER_DISCOUNT_EXPOSED'; end if;

  begin
    perform public.list_stock_transfer_requests('{}'::jsonb);
    raise exception 'TRANSFER_ACCESS_NOT_BLOCKED';
  exception when others then
    if sqlerrm not like '%SEM_PERMISSAO_TRANSFERENCIAS%' then raise; end if;
  end;

  begin
    perform public.commercial_create_quotation('{"items":[]}'::jsonb);
    raise exception 'ANONYMOUS_QUOTATION_DID_NOT_VALIDATE_ITEMS';
  exception when others then
    if sqlerrm not like '%ITENS_OBRIGATORIOS%' then raise; end if;
  end;

  begin
    perform public.commercial_create_order('{"cliente":"FORA DA CARTEIRA","items":[]}'::jsonb);
    raise exception 'ORDER_OUTSIDE_PORTFOLIO_NOT_BLOCKED';
  exception when others then
    if sqlerrm not like '%CLIENTE_DA_CARTEIRA_OBRIGATORIO%' then raise; end if;
  end;

  request_result:=public.submit_client_registration_request(jsonb_build_object(
    'cnpj','12345678000199',
    'razao_social','TESTE ROLLBACK CARTEIRA',
    'email_compras','teste@example.com'
  ));
  if coalesce(request_result->>'protocolo','')='' then
    raise exception 'REQUEST_PROTOCOL_MISSING';
  end if;
end;
$$;

rollback;
