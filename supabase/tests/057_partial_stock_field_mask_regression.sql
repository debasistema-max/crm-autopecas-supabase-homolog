begin;

select set_config('request.jwt.claim.sub',(
  select id::text from public.profiles where perfil = 'ADMIN' and ativo order by created_at limit 1
),true);

insert into public.products(codigo, descricao)
values('STOCK-MASK-057', 'REGRESSAO FIELD MASK ESTOQUE')
on conflict(codigo) do update set descricao = excluded.descricao;

do $$
declare
  first_batch uuid;
  second_batch uuid;
  stock_row public.product_branch_stock;
begin
  first_batch := (public.create_sap_import_batch(jsonb_build_object(
    'import_kind', 'STOCK_PR', 'branch_code', 'PR',
    'file_hash', repeat('a', 64), 'original_filename', 'stock-mask-full.tsv',
    'detected_fields', jsonb_build_array('product_code', 'stock_qty', 'confirmed_qty', 'general_available_qty')
  ))->>'batch_id')::uuid;
  perform public.stage_sap_import_rows(first_batch, jsonb_build_array(jsonb_build_object(
    'row_number', 2, 'data', jsonb_build_object(
      'product_code', 'STOCK-MASK-057', 'stock_qty', 40,
      'confirmed_qty', 7, 'general_available_qty', 33
    )
  )));
  perform public.validate_sap_import_batch(first_batch);
  perform public.approve_sap_import_batch(first_batch);
  perform public.commit_sap_import_batch(first_batch);

  second_batch := (public.create_sap_import_batch(jsonb_build_object(
    'import_kind', 'STOCK_PR', 'branch_code', 'PR',
    'file_hash', repeat('b', 64), 'original_filename', 'stock-mask-partial.tsv',
    'detected_fields', jsonb_build_array('product_code', 'general_available_qty')
  ))->>'batch_id')::uuid;
  perform public.stage_sap_import_rows(second_batch, jsonb_build_array(jsonb_build_object(
    'row_number', 2, 'data', jsonb_build_object(
      'product_code', 'STOCK-MASK-057', 'general_available_qty', 25
    )
  )));
  perform public.validate_sap_import_batch(second_batch);
  perform public.approve_sap_import_batch(second_batch);
  perform public.commit_sap_import_batch(second_batch);

  select s.* into stock_row
  from public.product_branch_stock s
  join public.branches b on b.id = s.branch_id
  where s.product_code = 'STOCK-MASK-057' and b.code = 'PR';

  if stock_row.sap_stock_qty <> 40 or stock_row.sap_confirmed_qty <> 7 then
    raise exception 'IMPORTACAO_PARCIAL_APAGOU_ESTOQUE: %', to_jsonb(stock_row);
  end if;
  if stock_row.sap_general_available_qty <> 25 then
    raise exception 'CAMPO_FORNECIDO_NAO_FOI_ATUALIZADO: %', to_jsonb(stock_row);
  end if;
end;
$$;

rollback;
