begin;

select set_config('request.jwt.claim.sub',(
  select id::text from public.profiles where perfil='ADMIN' and ativo order by created_at limit 1
),true);

do $$
declare
  v_batch uuid;
  v_result jsonb;
  v_source_at timestamptz:=clock_timestamp();
begin
  if exists(select 1 from public.product_route_prices where coalesce(base_price,0)<=0 or final_price<=0) then
    raise exception 'PRECO_ROTA_ZERO_PERMANECEU';
  end if;
  if exists(select 1 from public.product_branch_prices where sale_price<=0) then
    raise exception 'PRECO_FILIAL_ZERO_PERMANECEU';
  end if;

  insert into public.products(codigo,descricao,ncm)
  values('ZERO-PRICE-089','TESTE PRECO ZERO','85122011')
  on conflict(codigo) do update set descricao=excluded.descricao,ncm=excluded.ncm;

  v_batch:=(public.create_data_sync_batch(jsonb_build_object(
    'source','EXCEL_API','source_version','zero-price-089','source_updated_at',v_source_at,
    'file_hash',repeat('8',64),'original_filename','zero-price-089.xlsx'
  ))->>'batch_id')::uuid;

  perform public.stage_data_sync_rows(v_batch,jsonb_build_array(
    jsonb_build_object('row_number',1,'area','BASE_PRICE','product_code','ZERO-PRICE-089','branch_code','SP',
      'fields',jsonb_build_object('base_price',0,'currency','BRL'),
      'field_mask',jsonb_build_array('base_price','currency')),
    jsonb_build_object('row_number',2,'area','ROUTE_PRICE','product_code','ZERO-PRICE-089','route','SP-SP',
      'fields',jsonb_build_object('base_price',0,'final_price',0,'total_taxes',0,
        'calculation_status','OK','currency','BRL'),
      'field_mask',jsonb_build_array('base_price','final_price','total_taxes','calculation_status','currency')),
    jsonb_build_object('row_number',3,'area','ROUTE_PRICE','product_code','ZERO-PRICE-089','route','PR-PR',
      'fields',jsonb_build_object('base_price',100,'final_price',100,'total_taxes',0,
        'calculation_status','OK_SEM_ST','currency','BRL'),
      'field_mask',jsonb_build_array('base_price','final_price','total_taxes','calculation_status','currency'))
  ));

  v_result:=public.validate_data_sync_batch(v_batch);
  if (v_result->>'error_count')::integer<>2 then
    raise exception 'PRECO_ZERO_NAO_REJEITADO: %',v_result;
  end if;
  perform public.commit_data_sync_batch(v_batch);

  if exists(select 1 from public.product_branch_prices p join public.branches b on b.id=p.branch_id
    where p.product_code='ZERO-PRICE-089' and b.code='SP') then
    raise exception 'PRECO_BASE_ZERO_FOI_GRAVADO';
  end if;
  if exists(select 1 from public.product_route_prices where product_code='ZERO-PRICE-089' and route='SP-SP') then
    raise exception 'PRECO_ROTA_ZERO_FOI_GRAVADO';
  end if;
  if not exists(select 1 from public.product_route_prices
    where product_code='ZERO-PRICE-089' and route='PR-PR'
      and base_price=100 and final_price=100 and total_taxes=0) then
    raise exception 'TRIBUTO_ZERO_VALIDO_FOI_REJEITADO';
  end if;
end;
$$;

rollback;
