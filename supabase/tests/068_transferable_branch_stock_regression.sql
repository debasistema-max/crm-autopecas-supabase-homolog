begin;

do $$
declare
  v_branch_pr uuid;
  v_branch_sp uuid;
  v_result record;
begin
  select id into v_branch_pr from public.branches where code='PR' and active limit 1;
  select id into v_branch_sp from public.branches where code='SP' and active limit 1;

  insert into public.products(codigo,descricao)
  values ('TRANSFER-STOCK-068','Produto teste saldo transferivel')
  on conflict(codigo) do update set descricao=excluded.descricao;

  insert into public.product_branch_stock(
    product_code,branch_id,physical_qty,reserved_order_qty,
    sap_general_available_qty,source_batch_id,version
  ) values
    ('TRANSFER-STOCK-068',v_branch_pr,10,10,50,null,1),
    ('TRANSFER-STOCK-068',v_branch_sp,0,0,0,null,1)
  on conflict(product_code,branch_id) do update set
    physical_qty=excluded.physical_qty,
    reserved_order_qty=excluded.reserved_order_qty,
    sap_general_available_qty=excluded.sap_general_available_qty,
    version=1;

  select * into v_result
  from public.get_branch_product_availability_v2(array['TRANSFER-STOCK-068']);

  if v_result.pr_available_qty<>50
     or v_result.pr_transfer_available_qty<>0
     or v_result.sp_available_qty<>0
     or v_result.sp_transfer_available_qty<>0 then
    raise exception 'SALDO_COMERCIAL_E_TRANSFERIVEL_NAO_FORAM_SEPARADOS: %',to_jsonb(v_result);
  end if;
end;
$$;

rollback;
