begin;

do $$
declare
  v_user uuid;
  v_client public.clients;
  v_origin_code text;
  v_origin_id uuid;
  v_route text;
  v_batch uuid;
  v_codes text[];
begin
  select p.id into v_user from public.profiles p
  where p.ativo order by (p.perfil='ADMIN') desc,p.created_at limit 1;
  select c.* into v_client from public.clients c
  where c.ativo and upper(btrim(coalesce(c.estado,''))) in ('PR','SC','SP')
  order by c.created_at limit 1;
  if v_user is null or v_client.id is null then raise exception 'BASE_TESTE_B2B_INDISPONIVEL'; end if;

  v_origin_code:=case upper(btrim(v_client.estado)) when 'SP' then 'SP' else 'PR' end;
  v_route:=v_origin_code||'-'||upper(btrim(v_client.estado));
  select b.id into v_origin_id from public.branches b where b.code=v_origin_code and b.active limit 1;
  select b.id into v_batch from public.products_import_batches b order by b.created_at limit 1;
  if v_origin_id is null or v_batch is null then raise exception 'ROTA_OU_LOTE_TESTE_INDISPONIVEL'; end if;

  insert into public.customer_portal_accounts(
    user_id,client_id,email,active,can_view_prices,can_view_stock,owner_profile_id,invited_by,
    username,login_mode,must_change_password,activation_pending
  ) values (
    v_user,v_client.id,'search-074-'||v_user||'@invalid.test',true,true,true,v_user,v_user,
    null,'EMAIL',false,false
  ) on conflict(user_id) do update set
    client_id=excluded.client_id,email=excluded.email,active=true,can_view_prices=true,can_view_stock=true,
    username=null,login_mode='EMAIL',must_change_password=false,activation_pending=false;
  perform set_config('request.jwt.claim.sub',v_user::text,true);

  insert into public.products(codigo,descricao,marca,aplicacao)
  values
    ('B2B074-A','CAIXA074 COMPLETA','IPS','HILUX074 2016 A 2024'),
    ('B2B074-B','FAROL DIANTEIRO','IPS','HILUX074 2016 A 2024'),
    ('B2B074-C','CAIXA074 FILTRO DE AR','IPS','COROLLA'),
    ('B2B074-D','CAIXA074 SEM PRECO','IPS','HILUX074')
  on conflict(codigo) do update set
    descricao=excluded.descricao,marca=excluded.marca,aplicacao=excluded.aplicacao;

  insert into public.product_route_prices(
    product_code,origin_branch_id,destination_state,route,final_price,calculation_status,
    currency,source,source_version,source_updated_at,source_batch_id,updated_by
  ) values
    ('B2B074-A',v_origin_id,upper(btrim(v_client.estado)),v_route,100,'OK','BRL','EXCEL_API','search-074',now(),v_batch,v_user),
    ('B2B074-B',v_origin_id,upper(btrim(v_client.estado)),v_route,110,'OK','BRL','EXCEL_API','search-074',now(),v_batch,v_user),
    ('B2B074-C',v_origin_id,upper(btrim(v_client.estado)),v_route,120,'OK','BRL','EXCEL_API','search-074',now(),v_batch,v_user)
  on conflict(product_code,route) do update set
    final_price=excluded.final_price,calculation_status='OK',origin_branch_id=excluded.origin_branch_id,
    destination_state=excluded.destination_state,source='EXCEL_API',source_version='search-074',
    source_updated_at=excluded.source_updated_at,source_batch_id=excluded.source_batch_id,updated_by=excluded.updated_by;

  select array_agg(result.product_code order by result.position) into v_codes
  from (
    select row_number() over() as position,found.product_code
    from public.b2b_search_catalog('caixa074 hilux074',false,20) found
  ) result;

  if array_position(v_codes,'B2B074-A') is null
     or array_position(v_codes,'B2B074-B') is null
     or array_position(v_codes,'B2B074-C') is null then
    raise exception 'BUSCA_B2B_NAO_INCLUIU_TERMOS_RELACIONADOS: %',v_codes;
  end if;
  if array_position(v_codes,'B2B074-D') is not null then
    raise exception 'BUSCA_B2B_EXPOS_PRODUTO_SEM_PRECO_DE_ROTA: %',v_codes;
  end if;
  if not (array_position(v_codes,'B2B074-A')<array_position(v_codes,'B2B074-B')
      and array_position(v_codes,'B2B074-B')<array_position(v_codes,'B2B074-C')) then
    raise exception 'RANKING_B2B_INCORRETO: %',v_codes;
  end if;
end;
$$;

rollback;
