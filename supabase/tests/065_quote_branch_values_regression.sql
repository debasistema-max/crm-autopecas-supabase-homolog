begin;

do $$
declare
  v_branch_pr uuid;
  v_branch_sp uuid;
  v_result record;
begin
  select id into v_branch_pr from public.branches where code = 'PR' and active limit 1;
  select id into v_branch_sp from public.branches where code = 'SP' and active limit 1;

  insert into public.products(codigo,descricao)
  values ('QUOTE-BRANCH-065','Produto teste cotacao por filial')
  on conflict(codigo) do update set descricao = excluded.descricao;

  insert into public.product_branch_prices(product_code,branch_id,sale_price,source)
  values
    ('QUOTE-BRANCH-065',v_branch_pr,123.45,'MANUAL'),
    ('QUOTE-BRANCH-065',v_branch_sp,234.56,'MANUAL')
  on conflict(product_code,branch_id) do update set
    sale_price = excluded.sale_price,source = excluded.source;

  insert into public.product_branch_stock(
    product_code,branch_id,physical_qty,sap_general_available_qty,source_batch_id,version
  ) values ('QUOTE-BRANCH-065',v_branch_pr,7,7,null,1)
  on conflict(product_code,branch_id) do update set
    physical_qty = 7,sap_general_available_qty = 7,version = 1;

  select * into v_result
  from public.get_branch_product_availability(array['QUOTE-BRANCH-065']);

  if v_result.pr_price <> 123.45 or v_result.sp_price <> 234.56
     or v_result.pr_available_qty <> 7 or v_result.sp_available_qty is not null then
    raise exception 'VALORES_COMERCIAIS_POR_FILIAL_INCORRETOS';
  end if;
end;
$$;

rollback;
