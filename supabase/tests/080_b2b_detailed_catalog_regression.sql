begin;

do $$
declare
  v_code text:='7170505900';
  v_metadata public.product_catalog_metadata;
  v_user uuid;
  v_client public.clients;
  v_route text;
  v_detail jsonb;
  v_search_application text;
  v_document jsonb;
  v_item_application text;
  v_item_description text;
begin
  select * into v_metadata from public.product_catalog_metadata where product_code=v_code;
  if v_metadata.product_code is null then raise exception 'METADADO_DETALHADO_AUSENTE'; end if;
  if v_metadata.catalog_details#>>'{applications,0,vehicle}' is distinct from 'KICKS' then
    raise exception 'VEICULO_DETALHADO_INCORRETO: %',v_metadata.catalog_details;
  end if;
  if not (v_metadata.catalog_details->'oem_references') @> '[{"label":"48001-5RA0B"}]'::jsonb then
    raise exception 'REFERENCIA_OEM_AUSENTE: %',v_metadata.catalog_details;
  end if;
  if v_metadata.applications not like '%NISSAN KICKS 16/21%' then
    raise exception 'APLICACAO_COMPLETA_AUSENTE: %',v_metadata.applications;
  end if;

  select p.id into v_user from public.profiles p where p.ativo order by (p.perfil='ADMIN') desc,p.created_at limit 1;
  select c.* into v_client
  from public.clients c
  where c.ativo and exists(
    select 1 from public.product_route_prices rp
    join public.branches b on b.id=rp.origin_branch_id and b.active
    where rp.product_code=v_code and rp.final_price>0 and upper(coalesce(rp.calculation_status,'OK')) like 'OK%'
      and rp.destination_state=upper(btrim(c.estado))
      and b.code=case upper(btrim(c.estado)) when 'SP' then 'SP' when 'PR' then 'PR' when 'SC' then 'PR' end
  ) order by c.created_at limit 1;
  if v_user is null or v_client.id is null then raise exception 'CONTA_TESTE_B2B_INDISPONIVEL'; end if;

  insert into public.customer_portal_accounts(
    user_id,client_id,email,active,can_view_prices,can_view_stock,owner_profile_id,invited_by,
    username,login_mode,must_change_password,activation_pending
  ) values(v_user,v_client.id,'detail-080-'||v_user||'@invalid.test',true,true,true,v_user,v_user,null,'EMAIL',false,false)
  on conflict(user_id) do update set client_id=excluded.client_id,active=true,can_view_prices=true,can_view_stock=true,
    can_create_quotations=true,can_create_orders=true,
    username=null,login_mode='EMAIL',must_change_password=false,activation_pending=false;
  perform set_config('request.jwt.claim.sub',v_user::text,true);

  v_detail:=public.b2b_get_catalog_product_detail(v_code);
  if v_detail#>>'{details,applications,0,vehicle}' is distinct from 'KICKS' then
    raise exception 'RPC_DETALHE_NAO_RETORNOU_VEICULO: %',v_detail;
  end if;
  if nullif(v_detail->>'source_display_value','') is null and v_detail->>'availability'<>'NAO_IMPORTADO' then
    raise exception 'RPC_DETALHE_NAO_RETORNOU_ESTOQUE: %',v_detail;
  end if;

  select r.application into v_search_application
  from public.b2b_search_catalog(v_code,'',false,10) r where r.product_code=v_code;
  if v_search_application not like '%NISSAN KICKS 16/21%' then
    raise exception 'BUSCA_NAO_RETORNOU_VEICULO_ANO: %',v_search_application;
  end if;

  v_document:=public.b2b_create_document('cotacao',jsonb_build_object(
    'idempotency_key',gen_random_uuid()::text,
    'items',jsonb_build_array(jsonb_build_object('codigo',v_code,'quantidade',1))
  ));
  select i.aplicacao,i.descricao into v_item_application,v_item_description
  from public.quotation_items i where i.quotation_id=(v_document->>'id')::uuid;
  if v_item_application not like '%NISSAN KICKS 16/21%' then
    raise exception 'COTACAO_NAO_GRAVOU_VEICULO_ANO: %',v_item_application;
  end if;
  if v_item_description is distinct from (select p.descricao from public.products p where p.codigo=v_code) then
    raise exception 'COTACAO_NAO_PRESERVOU_DESCRICAO_COMERCIAL_CURTA: %',v_item_description;
  end if;

  if not exists(select 1 from pg_trigger where tgname='order_items_snapshot_b2b_application' and not tgisinternal)
    or not exists(select 1 from pg_trigger where tgname='quotation_items_snapshot_b2b_application' and not tgisinternal) then
    raise exception 'TRIGGERS_SNAPSHOT_APLICACAO_AUSENTES';
  end if;
end;
$$;

rollback;
