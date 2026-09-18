begin;

do $$
declare
  v_user uuid;
  v_client public.clients;
  v_origin text;
  v_branch uuid;
  v_route text;
  v_batch uuid;
  v_price numeric;
  v_session jsonb;
  v_blocked boolean:=false;
begin
  select p.id into v_user from public.profiles p where p.ativo order by (p.perfil='ADMIN') desc,p.created_at limit 1;
  select c.* into v_client from public.clients c
  where c.ativo and upper(btrim(coalesce(c.estado,''))) in ('PR','SC','SP') order by c.created_at limit 1;
  if v_user is null or v_client.id is null then raise exception 'BASE_TESTE_DESCONTO_INDISPONIVEL'; end if;
  v_origin:=case upper(btrim(v_client.estado)) when 'SP' then 'SP' else 'PR' end;
  v_route:=v_origin||'-'||upper(btrim(v_client.estado));
  select b.id into v_branch from public.branches b where b.code=v_origin and b.active limit 1;
  select b.id into v_batch from public.products_import_batches b order by b.created_at limit 1;
  if v_branch is null or v_batch is null then raise exception 'ROTA_OU_LOTE_TESTE_INDISPONIVEL'; end if;

  insert into public.customer_portal_accounts(
    user_id,client_id,email,active,can_view_prices,can_view_stock,owner_profile_id,invited_by,
    username,login_mode,must_change_password,activation_pending
  ) values(v_user,v_client.id,'discount-078-'||v_user||'@invalid.test',true,true,true,v_user,v_user,null,'EMAIL',false,false)
  on conflict(user_id) do update set client_id=excluded.client_id,active=true,can_view_prices=true,
    username=null,login_mode='EMAIL',must_change_password=false,activation_pending=false;
  perform set_config('request.jwt.claim.sub',v_user::text,true);

  update public.clients set commercial_discount_percent=7.5 where id=v_client.id;
  insert into public.products(codigo,descricao,marca,aplicacao)
  values('B2B078-A','PRODUTO TESTE DESCONTO','IPS','APLICACAO TESTE')
  on conflict(codigo) do update set descricao=excluded.descricao;
  insert into public.product_route_prices(product_code,origin_branch_id,destination_state,route,final_price,
    calculation_status,currency,source,source_version,source_updated_at,source_batch_id,updated_by)
  values('B2B078-A',v_branch,upper(btrim(v_client.estado)),v_route,100,'OK','BRL','EXCEL_API','discount-078',now(),v_batch,v_user)
  on conflict(product_code,route) do update set final_price=100,calculation_status='OK',origin_branch_id=excluded.origin_branch_id,
    destination_state=excluded.destination_state,source_batch_id=excluded.source_batch_id,updated_by=excluded.updated_by;

  select r.final_price into v_price from public.b2b_search_catalog('B2B078-A','',false,10) r
  where r.product_code='B2B078-A';
  if v_price is distinct from 92.5 then raise exception 'PRECO_B2B_NAO_APLICOU_DESCONTO: %',v_price; end if;
  v_session:=public.get_b2b_session();
  if (v_session#>>'{client,commercial_discount_percent}')::numeric is distinct from 7.5 then
    raise exception 'SESSAO_B2B_NAO_EXPOS_DESCONTO: %',v_session;
  end if;

  begin
    update public.clients set commercial_discount_percent=coalesce(public.max_discount_percent(),10)+0.01 where id=v_client.id;
  exception when others then
    v_blocked:=position('DESCONTO_CLIENTE_ACIMA_LIMITE' in sqlerrm)>0;
  end;
  if not v_blocked then raise exception 'DESCONTO_ACIMA_LIMITE_NAO_BLOQUEADO'; end if;
end;
$$;

rollback;
