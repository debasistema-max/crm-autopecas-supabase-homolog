begin;

set local lock_timeout = '10s';
set local statement_timeout = '110s';

-- Internal quotations/orders must also appear in the customer's portal. Resolve
-- the canonical client on every future document without changing the existing
-- commercial RPC contracts.
create or replace function public.link_commercial_document_client()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare resolved_client_id uuid;
begin
  if new.client_id is not null then return new; end if;
  resolved_client_id := public.resolve_commercial_client(new.codigo_sap_cliente,new.cnpj);
  if resolved_client_id is not null then new.client_id := resolved_client_id; end if;
  return new;
end;
$$;

drop trigger if exists orders_link_b2b_client on public.orders;
create trigger orders_link_b2b_client
before insert or update of codigo_sap_cliente,cnpj on public.orders
for each row execute function public.link_commercial_document_client();

drop trigger if exists quotations_link_b2b_client on public.quotations;
create trigger quotations_link_b2b_client
before insert or update of codigo_sap_cliente,cnpj on public.quotations
for each row execute function public.link_commercial_document_client();

update public.orders o
set client_id=public.resolve_commercial_client(o.codigo_sap_cliente,o.cnpj)
where o.client_id is null
  and public.resolve_commercial_client(o.codigo_sap_cliente,o.cnpj) is not null;

update public.quotations q
set client_id=public.resolve_commercial_client(q.codigo_sap_cliente,q.cnpj)
where q.client_id is null
  and public.resolve_commercial_client(q.codigo_sap_cliente,q.cnpj) is not null;

revoke all on function public.link_commercial_document_client()
  from public,anon,authenticated;

comment on function public.link_commercial_document_client() is
  'Vincula documentos criados pelo CRM interno ao cadastro canônico exibido no Portal B2B.';

-- Review and application are one database transaction. This prevents two
-- administrators from approving the same request or a partial client update.
create or replace function public.admin_review_b2b_profile_change(
  p_request_id uuid,
  p_client_id uuid,
  p_reviewer uuid,
  p_decision text,
  p_notes text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reviewer_row public.profiles;
  request_row public.customer_portal_change_requests;
  old_client jsonb;
  new_client jsonb;
  clean_decision text := upper(btrim(coalesce(p_decision,'')));
begin
  select * into reviewer_row from public.profiles
  where id=p_reviewer and ativo and perfil='ADMIN';
  if reviewer_row.id is null then raise exception 'APENAS_ADMIN'; end if;
  if clean_decision not in ('APPROVED','REJECTED') then raise exception 'DECISAO_INVALIDA'; end if;

  select * into request_row from public.customer_portal_change_requests
  where id=p_request_id and client_id=p_client_id
  for update;
  if request_row.id is null then raise exception 'SOLICITACAO_NAO_ENCONTRADA'; end if;
  if request_row.status <> 'PENDING' then raise exception 'SOLICITACAO_JA_REVISADA'; end if;

  select to_jsonb(c) into old_client from public.clients c where c.id=p_client_id for update;
  if old_client is null then raise exception 'CLIENTE_NAO_ENCONTRADO'; end if;

  if clean_decision='APPROVED' then
    if request_row.requested_data ? 'estado'
      and request_row.requested_data->>'estado' !~ '^[A-Z]{2}$' then raise exception 'UF_INVALIDA'; end if;
    if request_row.requested_data ? 'email'
      and request_row.requested_data->>'email' !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'EMAIL_INVALIDO'; end if;
    update public.clients
    set telefone=case when request_row.requested_data ? 'telefone' then request_row.requested_data->>'telefone' else telefone end,
        email=case when request_row.requested_data ? 'email' then lower(request_row.requested_data->>'email') else email end,
        endereco=case when request_row.requested_data ? 'endereco' then request_row.requested_data->>'endereco' else endereco end,
        cidade=case when request_row.requested_data ? 'cidade' then request_row.requested_data->>'cidade' else cidade end,
        estado=case when request_row.requested_data ? 'estado' then upper(request_row.requested_data->>'estado') else estado end,
        updated_at=now()
    where id=p_client_id;
  end if;

  update public.customer_portal_change_requests
  set status=clean_decision,reviewed_by=p_reviewer,reviewed_at=now(),
      review_notes=nullif(left(btrim(coalesce(p_notes,'')),500),''),updated_at=now()
  where id=p_request_id;

  select to_jsonb(c) into new_client from public.clients c where c.id=p_client_id;
  insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_anteriores,dados_novos)
  values(
    p_reviewer,reviewer_row.usuario,
    case when clean_decision='APPROVED' then 'APROVAR_ALTERACAO_CADASTRAL_B2B' else 'REJEITAR_ALTERACAO_CADASTRAL_B2B' end,
    'customer_portal_change_requests',p_request_id::text,
    jsonb_build_object('request_status',request_row.status,'client',old_client),
    jsonb_build_object('request_status',clean_decision,'client',new_client,'review_notes',nullif(left(btrim(coalesce(p_notes,'')),500),''))
  );

  return jsonb_build_object('id',p_request_id,'status',clean_decision,'client_updated',clean_decision='APPROVED');
end;
$$;

revoke all on function public.admin_review_b2b_profile_change(uuid,uuid,uuid,text,text)
  from public,anon,authenticated;
grant execute on function public.admin_review_b2b_profile_change(uuid,uuid,uuid,text,text)
  to service_role;

comment on function public.admin_review_b2b_profile_change(uuid,uuid,uuid,text,text) is
  'Aplica ou rejeita atomicamente uma solicitação cadastral B2B, com trava concorrente e auditoria.';

commit;
