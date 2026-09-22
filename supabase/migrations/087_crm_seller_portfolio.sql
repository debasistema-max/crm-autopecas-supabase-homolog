begin;

set local lock_timeout = '10s';
set local statement_timeout = '110s';

-- A carteira passa a ser um vínculo explícito. Isso evita inferir o vendedor
-- pelo nome e permite que a segurança seja aplicada também fora da interface.
alter table public.clients
  add column if not exists assigned_seller_id uuid references public.profiles(id) on delete set null;

create index if not exists clients_assigned_seller_idx
  on public.clients(assigned_seller_id,nome);

alter table public.cadastros_clientes
  add column if not exists requested_by uuid references public.profiles(id) on delete set null;

create index if not exists cadastros_clientes_requested_by_idx
  on public.cadastros_clientes(requested_by,created_at desc);

-- Preserve assignments that can be inferred from historical documents.
with latest_seller as (
  select distinct on (client_id) client_id,user_id
  from (
    select client_id,user_id,created_at from public.orders
    where client_id is not null and user_id is not null
    union all
    select client_id,user_id,created_at from public.quotations
    where client_id is not null and user_id is not null
  ) documents
  join public.profiles p on p.id=documents.user_id and p.ativo and p.perfil::text='VENDEDOR'
  order by client_id,documents.created_at desc
)
update public.clients c
set assigned_seller_id=s.user_id
from latest_seller s
where c.id=s.client_id and c.assigned_seller_id is null;

-- On installations with a single active salesperson, keep the existing CRM
-- immediately usable by assigning the still-unowned legacy clients to them.
do $$
declare seller_count integer; sole_seller uuid;
begin
  select count(*),min(id::text)::uuid into seller_count,sole_seller
  from public.profiles where ativo and perfil::text='VENDEDOR';
  if seller_count=1 then
    update public.clients set assigned_seller_id=sole_seller
    where assigned_seller_id is null;
  end if;
end;
$$;

create or replace function public.is_crm_seller()
returns boolean
language sql
stable security definer
set search_path=public
as $$
  select exists(
    select 1 from public.profiles p
    where p.id=auth.uid() and p.ativo and p.perfil::text='VENDEDOR'
  )
$$;

revoke all on function public.is_crm_seller() from public,anon;
grant execute on function public.is_crm_seller() to authenticated;

create or replace function public.can_access_commercial_client(target_client_id uuid)
returns boolean
language sql
stable security definer
set search_path=public
as $$
  select exists(
    select 1
    from public.profiles p
    join public.clients c on c.id=target_client_id and c.ativo
    where p.id=auth.uid() and p.ativo
      and (
        (p.perfil::text='VENDEDOR' and c.assigned_seller_id=p.id)
        or (p.perfil::text<>'VENDEDOR' and (p.perfil::text='ADMIN' or public.has_module('parceiros')))
      )
  )
$$;

revoke all on function public.can_access_commercial_client(uuid) from public,anon;
grant execute on function public.can_access_commercial_client(uuid) to authenticated;

drop policy if exists clients_read on public.clients;
create policy clients_read on public.clients for select to authenticated
using (
  public.is_internal_user()
  and (not public.is_crm_seller() or assigned_seller_id=auth.uid())
);

drop policy if exists clients_write on public.clients;
create policy clients_write on public.clients for all to authenticated
using (
  not public.is_crm_seller()
  and (public.is_admin() or public.has_module('parceiros'))
)
with check (
  not public.is_crm_seller()
  and (public.is_admin() or public.has_module('parceiros'))
);

drop policy if exists carriers_write on public.carriers;
create policy carriers_write on public.carriers for all to authenticated
using (
  not public.is_crm_seller()
  and (public.is_admin() or public.has_module('parceiros'))
)
with check (
  not public.is_crm_seller()
  and (public.is_admin() or public.has_module('parceiros'))
);

create or replace function public.list_business_clients_scoped(filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  actor public.profiles;
  search_term text:=nullif(btrim(coalesce(filters->>'termo','')),'');
  active_only boolean:=coalesce((filters->>'ativos')::boolean,false);
  rows_json jsonb;
begin
  actor:=public.commercial_active_profile();
  if actor.id is null or not (actor.perfil::text='ADMIN' or public.has_module('parceiros')) then
    raise exception 'SEM_PERMISSAO';
  end if;

  select coalesce(jsonb_agg(to_jsonb(rows) order by rows.nome),'[]'::jsonb)
  into rows_json
  from (
    select c.id,c.codigo_sap_cliente,c.nome,c.nome_fantasia,c.cnpj,c.telefone,c.email,
      c.endereco,c.cidade,c.estado,c.ativo,c.observacoes,c.created_at,c.updated_at,
      c.assigned_seller_id,s.nome as assigned_seller_name,
      case when actor.perfil::text='VENDEDOR' then null else c.commercial_discount_percent end
        as commercial_discount_percent
    from public.clients c
    left join public.profiles s on s.id=c.assigned_seller_id
    where (actor.perfil::text<>'VENDEDOR' or c.assigned_seller_id=actor.id)
      and (not active_only or c.ativo)
      and (
        search_term is null
        or c.codigo_sap_cliente ilike '%'||search_term||'%'
        or c.nome ilike '%'||search_term||'%'
        or c.nome_fantasia ilike '%'||search_term||'%'
        or (regexp_replace(search_term,'\D','','g')<>'' and c.cnpj ilike '%'||regexp_replace(search_term,'\D','','g')||'%')
        or c.cidade ilike '%'||search_term||'%'
      )
    order by c.nome
    limit 300
  ) rows;
  return rows_json;
end;
$$;

revoke all on function public.list_business_clients_scoped(jsonb) from public,anon,authenticated;
grant execute on function public.list_business_clients_scoped(jsonb) to authenticated;

create or replace function public.list_active_crm_sellers()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare actor public.profiles; rows_json jsonb;
begin
  actor:=public.commercial_active_profile();
  if actor.id is null or actor.perfil::text='VENDEDOR' then raise exception 'SEM_PERMISSAO'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'nome',p.nome,'usuario',p.usuario) order by p.nome),'[]'::jsonb)
  into rows_json from public.profiles p where p.ativo and p.perfil::text='VENDEDOR';
  return rows_json;
end;
$$;

revoke all on function public.list_active_crm_sellers() from public,anon,authenticated;
grant execute on function public.list_active_crm_sellers() to authenticated;

-- Sellers submit a request to the same internal queue used by the public portal.
create or replace function public.submit_client_registration_request(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  actor public.profiles;
  clean_cnpj text:=regexp_replace(coalesce(payload->>'cnpj',''),'\D','','g');
  clean_email text:=lower(btrim(coalesce(payload->>'email_compras','')));
  created_row public.cadastros_clientes;
begin
  actor:=public.commercial_active_profile();
  if actor.id is null or actor.perfil::text<>'VENDEDOR' then raise exception 'SEM_PERMISSAO'; end if;
  if clean_cnpj !~ '^[0-9]{14}$' then raise exception 'CNPJ_INVALIDO'; end if;
  if coalesce(btrim(payload->>'razao_social'),'')='' then raise exception 'RAZAO_SOCIAL_OBRIGATORIA'; end if;
  if clean_email='' or clean_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'EMAIL_INVALIDO'; end if;
  if exists(
    select 1 from public.cadastros_clientes c
    where regexp_replace(coalesce(c.cnpj,''),'\D','','g')=clean_cnpj
      and c.created_at>=now()-interval '15 minutes'
  ) then raise exception 'CADASTRO_RECENTE_EXISTENTE'; end if;

  insert into public.cadastros_clientes(
    cnpj,razao_social,nome_fantasia,ie,telefone,whatsapp,email_compras,
    responsavel_compras,cep,endereco,numero,bairro,complemento,cidade,estado,
    segmento,transportadora,prazo_desejado,observacoes,vendedor,origem,requested_by
  ) values (
    clean_cnpj,left(btrim(payload->>'razao_social'),180),nullif(left(btrim(payload->>'nome_fantasia'),180),''),
    nullif(left(btrim(payload->>'ie'),40),''),nullif(left(btrim(payload->>'telefone'),40),''),
    nullif(left(btrim(payload->>'whatsapp'),40),''),left(clean_email,250),
    nullif(left(btrim(payload->>'responsavel_compras'),120),''),nullif(left(regexp_replace(coalesce(payload->>'cep',''),'\D','','g'),8),''),
    nullif(left(btrim(payload->>'endereco'),220),''),nullif(left(btrim(payload->>'numero'),30),''),
    nullif(left(btrim(payload->>'bairro'),120),''),nullif(left(btrim(payload->>'complemento'),120),''),
    nullif(left(btrim(payload->>'cidade'),120),''),nullif(left(upper(btrim(payload->>'estado')),2),''),
    nullif(left(btrim(payload->>'segmento'),120),''),nullif(left(btrim(payload->>'transportadora'),180),''),
    nullif(left(btrim(payload->>'prazo_desejado'),120),''),nullif(left(btrim(payload->>'observacoes'),1500),''),
    actor.nome,'crm_vendedor',actor.id
  ) returning * into created_row;

  insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_novos)
  values(actor.id,actor.usuario,'SOLICITAR_CADASTRO_CLIENTE','cadastros_clientes',created_row.id::text,
    jsonb_build_object('protocolo',created_row.protocolo,'cnpj',clean_cnpj));

  return jsonb_build_object('id',created_row.id,'protocolo',created_row.protocolo,'status',created_row.status);
end;
$$;

revoke all on function public.submit_client_registration_request(jsonb) from public,anon,authenticated;
grant execute on function public.submit_client_registration_request(jsonb) to authenticated;

drop policy if exists cadastros_clientes_crm_read on public.cadastros_clientes;
create policy cadastros_clientes_crm_read on public.cadastros_clientes for select to authenticated
using (
  public.is_admin()
  or public.has_module('cadastros')
  or (public.is_crm_seller() and requested_by=auth.uid())
  or (not public.is_crm_seller() and public.has_module('novo_pedido') and status in ('Aprovado','Finalizado SAP'))
);

-- Orders must use a customer from the seller's portfolio. Quotations may be
-- anonymous, but an identified customer must still belong to that portfolio.
create or replace function public.assert_seller_client_scope(payload jsonb,allow_anonymous boolean)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  actor public.profiles;
  sap_code text:=nullif(btrim(payload->>'codigo_sap_cliente'),'');
  clean_cnpj text:=nullif(regexp_replace(coalesce(payload->>'cnpj',''),'\D','','g'),'');
  client_name text:=nullif(btrim(payload->>'cliente'),'');
begin
  actor:=public.commercial_active_profile();
  if actor.id is null then raise exception 'SEM_PERMISSAO'; end if;
  if actor.perfil::text<>'VENDEDOR' then return; end if;
  if allow_anonymous and sap_code is null and clean_cnpj is null
     and (client_name is null or upper(client_name)='CLIENTE NÃO INFORMADO') then return; end if;
  if sap_code is null and clean_cnpj is null then raise exception 'CLIENTE_DA_CARTEIRA_OBRIGATORIO'; end if;
  if not exists(
    select 1 from public.clients c
    where c.ativo and c.assigned_seller_id=actor.id
      and ((sap_code is not null and c.codigo_sap_cliente=sap_code)
        or (clean_cnpj is not null and regexp_replace(coalesce(c.cnpj,''),'\D','','g')=clean_cnpj))
  ) then raise exception 'CLIENTE_FORA_DA_CARTEIRA'; end if;
end;
$$;

revoke all on function public.assert_seller_client_scope(jsonb,boolean) from public,anon,authenticated;

create or replace function public.commercial_create_order(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare result jsonb;
begin
  perform public.assert_seller_client_scope(payload,false);
  result:=public.commercial_create_document('pedido',payload);
  if public.is_crm_seller() then result:=result-'transferencias'; end if;
  return result;
end;
$$;

create or replace function public.commercial_create_quotation(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare safe_payload jsonb:=coalesce(payload,'{}'::jsonb);
begin
  perform public.assert_seller_client_scope(safe_payload,true);
  if coalesce(btrim(safe_payload->>'cliente'),'')='' then
    safe_payload:=jsonb_set(safe_payload,'{cliente}',to_jsonb('CLIENTE NÃO INFORMADO'::text),true);
  end if;
  return public.commercial_create_document('cotacao',safe_payload);
end;
$$;

revoke all on function public.commercial_create_order(jsonb) from public,anon,authenticated;
revoke all on function public.commercial_create_quotation(jsonb) from public,anon,authenticated;
grant execute on function public.commercial_create_order(jsonb) to authenticated;
grant execute on function public.commercial_create_quotation(jsonb) to authenticated;

-- The commercial history remains available in read-only mode, without
-- returning the B2B discount in the seller response.
alter function public.get_customer_commercial_profile(uuid)
  rename to get_customer_commercial_profile_internal_087;
revoke all on function public.get_customer_commercial_profile_internal_087(uuid) from public,anon,authenticated;

create function public.get_customer_commercial_profile(target_client_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare result jsonb;
begin
  result:=public.get_customer_commercial_profile_internal_087(target_client_id);
  if public.is_crm_seller() then
    result:=jsonb_set(result,'{client}',coalesce(result->'client','{}'::jsonb)-'commercial_discount_percent',true);
  end if;
  return result;
end;
$$;

revoke all on function public.get_customer_commercial_profile(uuid) from public,anon,authenticated;
grant execute on function public.get_customer_commercial_profile(uuid) to authenticated;

-- A quotation without customer is intentionally a quotation only.
alter function public.convert_quotation_to_order(uuid)
  rename to convert_quotation_to_order_internal_087;
revoke all on function public.convert_quotation_to_order_internal_087(uuid) from public,anon,authenticated;

create function public.convert_quotation_to_order(target_quotation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare source public.quotations;
begin
  select * into source from public.quotations where id=target_quotation_id;
  if source.id is null then raise exception 'COTACAO_NAO_ENCONTRADA'; end if;
  if source.client_id is null and source.codigo_sap_cliente is null and source.cnpj is null
     and upper(btrim(source.cliente))='CLIENTE NÃO INFORMADO' then
    raise exception 'CLIENTE_OBRIGATORIO_PARA_CONVERSAO';
  end if;
  return public.convert_quotation_to_order_internal_087(target_quotation_id);
end;
$$;

revoke all on function public.convert_quotation_to_order(uuid) from public,anon,authenticated;
grant execute on function public.convert_quotation_to_order(uuid) to authenticated;

-- Keep automatic operational generation intact, but remove every read/update
-- entry point exposed to the salesperson profile.
alter function public.list_stock_transfer_requests(jsonb)
  rename to list_stock_transfer_requests_internal_087;
alter function public.list_order_transfer_requests(uuid)
  rename to list_order_transfer_requests_internal_087;
alter function public.list_order_transfer_request_summaries(uuid[])
  rename to list_order_transfer_request_summaries_internal_087;
alter function public.get_dashboard_transfer_summary()
  rename to get_dashboard_transfer_summary_internal_087;
alter function public.update_stock_transfer_request_status(uuid,text,text)
  rename to update_stock_transfer_request_status_internal_087;

revoke all on function public.list_stock_transfer_requests_internal_087(jsonb) from public,anon,authenticated;
revoke all on function public.list_order_transfer_requests_internal_087(uuid) from public,anon,authenticated;
revoke all on function public.list_order_transfer_request_summaries_internal_087(uuid[]) from public,anon,authenticated;
revoke all on function public.get_dashboard_transfer_summary_internal_087() from public,anon,authenticated;
revoke all on function public.update_stock_transfer_request_status_internal_087(uuid,text,text) from public,anon,authenticated;

create function public.list_stock_transfer_requests(filters jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if public.is_crm_seller() then raise exception 'SEM_PERMISSAO_TRANSFERENCIAS'; end if;
  return public.list_stock_transfer_requests_internal_087(filters);
end;
$$;

create function public.list_order_transfer_requests(target_order_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if public.is_crm_seller() then raise exception 'SEM_PERMISSAO_TRANSFERENCIAS'; end if;
  return public.list_order_transfer_requests_internal_087(target_order_id);
end;
$$;

create function public.list_order_transfer_request_summaries(target_order_ids uuid[])
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if public.is_crm_seller() then raise exception 'SEM_PERMISSAO_TRANSFERENCIAS'; end if;
  return public.list_order_transfer_request_summaries_internal_087(target_order_ids);
end;
$$;

create function public.get_dashboard_transfer_summary()
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if public.is_crm_seller() then raise exception 'SEM_PERMISSAO_TRANSFERENCIAS'; end if;
  return public.get_dashboard_transfer_summary_internal_087();
end;
$$;

create function public.update_stock_transfer_request_status(target_request_id uuid,target_status text,target_notes text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if public.is_crm_seller() then raise exception 'SEM_PERMISSAO_TRANSFERENCIAS'; end if;
  return public.update_stock_transfer_request_status_internal_087(target_request_id,target_status,target_notes);
end;
$$;

revoke all on function public.list_stock_transfer_requests(jsonb) from public,anon,authenticated;
revoke all on function public.list_order_transfer_requests(uuid) from public,anon,authenticated;
revoke all on function public.list_order_transfer_request_summaries(uuid[]) from public,anon,authenticated;
revoke all on function public.get_dashboard_transfer_summary() from public,anon,authenticated;
revoke all on function public.update_stock_transfer_request_status(uuid,text,text) from public,anon,authenticated;
grant execute on function public.list_stock_transfer_requests(jsonb) to authenticated;
grant execute on function public.list_order_transfer_requests(uuid) to authenticated;
grant execute on function public.list_order_transfer_request_summaries(uuid[]) to authenticated;
grant execute on function public.get_dashboard_transfer_summary() to authenticated;
grant execute on function public.update_stock_transfer_request_status(uuid,text,text) to authenticated;

drop policy if exists stock_transfer_requests_read on public.stock_transfer_requests;
create policy stock_transfer_requests_read on public.stock_transfer_requests for select to authenticated
using (
  not public.is_crm_seller()
  and (
    public.is_admin()
    or exists(select 1 from public.orders o where o.id=order_id and o.user_id=auth.uid())
    or public.can_access_branch(source_branch_id)
    or public.can_access_branch(target_branch_id)
  )
);

comment on column public.clients.assigned_seller_id is
  'Vendedor responsável pela carteira; usado como limite de leitura e seleção no CRM.';
comment on column public.cadastros_clientes.requested_by is
  'Perfil interno que solicitou o cadastro pelo CRM.';

commit;
