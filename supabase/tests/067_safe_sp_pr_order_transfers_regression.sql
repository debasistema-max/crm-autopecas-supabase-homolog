begin;

select set_config('request.jwt.claim.sub',(
  select id::text from public.profiles where perfil='ADMIN' and ativo order by created_at limit 1
),true);

do $$
declare
  v_admin uuid:=auth.uid();
  v_branch_pr uuid;
  v_branch_sp uuid;
  v_batch uuid;
  v_source_at timestamptz:=clock_timestamp();
  v_result jsonb;
  v_order_id uuid;
  v_transfer public.stock_transfer_requests;
begin
  if v_admin is null then raise exception 'ADMIN_ATIVO_NAO_ENCONTRADO'; end if;
  select id into v_branch_pr from public.branches where code='PR' and active limit 1;
  select id into v_branch_sp from public.branches where code='SP' and active limit 1;

  insert into public.products(codigo,descricao,ncm)
  values
    ('9900000067','PRODUTO TESTE TRANSFERENCIA SP PR','85122011'),
    ('9900000068','PRODUTO TESTE SP SEM SNAPSHOT','85122011')
  on conflict(codigo) do update set descricao=excluded.descricao,ncm=excluded.ncm;

  v_batch:=(public.create_data_sync_batch(jsonb_build_object(
    'source','EXCEL_API','source_version','safe-transfer-067','source_updated_at',v_source_at,
    'file_hash',repeat('7',64),'original_filename','safe-transfer-067.xlsx'
  ))->>'batch_id')::uuid;

  perform public.stage_data_sync_rows(v_batch,jsonb_build_array(
    jsonb_build_object('row_number',1,'area','BASE_PRICE','product_code','9900000067','branch_code','SP',
      'fields',jsonb_build_object('base_price',100,'currency','BRL'),'field_mask',jsonb_build_array('base_price','currency')),
    jsonb_build_object('row_number',2,'area','ROUTE_PRICE','product_code','9900000067','route','SP-SP',
      'fields',jsonb_build_object('base_price',100,'final_price',110,'total_taxes',10,'calculation_status','OK','currency','BRL'),
      'field_mask',jsonb_build_array('base_price','final_price','total_taxes','calculation_status','currency')),
    jsonb_build_object('row_number',3,'area','BASE_PRICE','product_code','9900000068','branch_code','SP',
      'fields',jsonb_build_object('base_price',100,'currency','BRL'),'field_mask',jsonb_build_array('base_price','currency')),
    jsonb_build_object('row_number',4,'area','ROUTE_PRICE','product_code','9900000068','route','SP-SP',
      'fields',jsonb_build_object('base_price',100,'final_price',110,'total_taxes',10,'calculation_status','OK','currency','BRL'),
      'field_mask',jsonb_build_array('base_price','final_price','total_taxes','calculation_status','currency'))
  ));
  perform public.validate_data_sync_batch(v_batch);
  perform public.commit_data_sync_batch(v_batch);

  insert into public.product_branch_stock(
    product_code,branch_id,physical_qty,sap_general_available_qty,source_batch_id,source_updated_at,version
  ) values
    ('9900000067',v_branch_sp,0,0,v_batch,v_source_at,1),
    ('9900000067',v_branch_pr,5,5,v_batch,v_source_at,1),
    ('9900000068',v_branch_pr,5,5,v_batch,v_source_at,1)
  on conflict(product_code,branch_id) do update set
    physical_qty=excluded.physical_qty,sap_general_available_qty=excluded.sap_general_available_qty,
    source_batch_id=excluded.source_batch_id,source_updated_at=excluded.source_updated_at,version=1;

  delete from public.product_branch_stock
  where product_code='9900000068' and branch_id=v_branch_sp;

  v_result:=public.commercial_create_document('pedido',jsonb_build_object(
    'regiao','SP','cliente_estado','SP','customer_type','REVENDA','cliente','TESTE TRANSFERENCIA',
    'items',jsonb_build_array(jsonb_build_object('codigo','9900000067','quantidade',2,'desconto_percentual',0))
  ));
  v_order_id:=(v_result->>'id')::uuid;
  select * into v_transfer from public.stock_transfer_requests
  where order_id=v_order_id and product_code='9900000067';

  if coalesce((v_result->'transferencias'->>'created')::integer,0)<>1
     or v_transfer.id is null
     or v_transfer.requested_qty<>2
     or v_transfer.source_branch_id<>v_branch_pr
     or v_transfer.target_branch_id<>v_branch_sp
     or v_transfer.status<>'PENDING'
     or v_transfer.reason<>'ORDER_SP_SHORTAGE_PR_TRANSFER' then
    raise exception 'TRANSFERENCIA_SP_PR_NAO_CRIADA: % / %',v_result,to_jsonb(v_transfer);
  end if;

  v_result:=public.commercial_create_document('pedido',jsonb_build_object(
    'regiao','SP','cliente_estado','SP','customer_type','REVENDA','cliente','TESTE SNAPSHOT AUSENTE',
    'items',jsonb_build_array(jsonb_build_object('codigo','9900000068','quantidade',1,'desconto_percentual',0))
  ));
  v_order_id:=(v_result->>'id')::uuid;

  if coalesce((v_result->'transferencias'->>'created')::integer,0)<>0
     or not exists(
       select 1 from jsonb_array_elements(v_result->'transferencias'->'warnings') w
       where w->>'code'='ESTOQUE_SP_NAO_IMPORTADO' and w->>'product_code'='9900000068'
     )
     or exists(select 1 from public.stock_transfer_requests where order_id=v_order_id)
     or exists(select 1 from public.product_branch_stock where product_code='9900000068' and branch_id=v_branch_sp) then
    raise exception 'SNAPSHOT_SP_AUSENTE_FOI_TRATADO_COMO_ZERO: %',v_result;
  end if;
end;
$$;

rollback;
