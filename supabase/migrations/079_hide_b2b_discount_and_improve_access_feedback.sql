begin;

set local lock_timeout = '10s';
set local statement_timeout = '60s';

-- O desconto continua aplicado no servidor ao preço final, mas o percentual é
-- uma condição comercial interna e não precisa fazer parte da sessão do portal.
create or replace function public.get_b2b_session()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  account_row public.customer_portal_accounts;
  client_row public.clients;
  destination_state text;
  origin_branch text;
begin
  select a.* into account_row from public.customer_portal_accounts a
  where a.user_id=auth.uid() and (a.active or a.activation_pending);
  if account_row.user_id is null then raise exception 'ACESSO_B2B_NAO_AUTORIZADO'; end if;

  select c.* into client_row from public.clients c where c.id=account_row.client_id and c.ativo;
  if client_row.id is null then raise exception 'CLIENTE_B2B_INATIVO'; end if;

  destination_state:=upper(btrim(coalesce(client_row.estado,'')));
  origin_branch:=case destination_state when 'SP' then 'SP' when 'PR' then 'PR' when 'SC' then 'PR' else null end;

  update public.customer_portal_accounts set last_login_at=now(),updated_at=now()
  where user_id=account_row.user_id and (last_login_at is null or last_login_at<now()-interval '15 minutes');

  return jsonb_build_object(
    'account',jsonb_build_object(
      'user_id',account_row.user_id,
      'email',case when account_row.login_mode='EMAIL' then account_row.email else null end,
      'username',account_row.username,
      'login_mode',account_row.login_mode,
      'must_change_password',account_row.must_change_password,
      'activation_pending',account_row.activation_pending,
      'contact_name',account_row.contact_name,
      'can_create_quotations',account_row.can_create_quotations,
      'can_create_orders',account_row.can_create_orders,
      'can_view_stock',account_row.can_view_stock,
      'can_view_prices',account_row.can_view_prices
    ),
    'client',jsonb_build_object(
      'id',client_row.id,
      'codigo_sap_cliente',client_row.codigo_sap_cliente,
      'nome',client_row.nome,
      'nome_fantasia',client_row.nome_fantasia,
      'cnpj',client_row.cnpj,
      'telefone',client_row.telefone,
      'email',client_row.email,
      'cidade',client_row.cidade,
      'estado',client_row.estado,
      'endereco',client_row.endereco
    ),
    'route',case when origin_branch is null then null else origin_branch||'-'||destination_state end,
    'origin_branch',origin_branch,
    'destination_state',nullif(destination_state,''),
    'route_supported',origin_branch is not null
  );
end;
$$;

revoke all on function public.get_b2b_session() from public,anon,authenticated;
grant execute on function public.get_b2b_session() to authenticated;

comment on function public.get_b2b_session() is
  'Retorna somente o contexto operacional do cliente B2B; condições internas de desconto não são expostas.';

commit;
