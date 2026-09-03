begin;

do $$
begin
  if has_function_privilege('anon', 'public.get_product_commercial_price(text,text,text,date,text)', 'EXECUTE') then
    raise exception 'ANON_AINDA_EXECUTA_PRECO_COMERCIAL';
  end if;
  if has_function_privilege('anon', 'public.get_fiscal_pending(jsonb)', 'EXECUTE') then
    raise exception 'ANON_AINDA_EXECUTA_PENDENCIAS_FISCAIS';
  end if;
  if not has_function_privilege('authenticated', 'public.get_product_commercial_price(text,text,text,date,text)', 'EXECUTE') then
    raise exception 'AUTHENTICATED_SEM_PRECO_COMERCIAL';
  end if;
end;
$$;

select set_config('request.jwt.claim.sub',(
  select id::text from public.profiles where perfil = 'ADMIN' and ativo order by created_at limit 1
),true);

insert into public.products(codigo, descricao, ncm, ipi_rate, ipi_defined, preco_pr)
values('SECURITY-FISCAL-055', 'REGRESSAO GUARD FISCAL', '85122011', 0.0975, true, 123)
on conflict(codigo) do update set descricao = excluded.descricao, ncm = excluded.ncm,
  ipi_rate = excluded.ipi_rate, ipi_defined = excluded.ipi_defined, preco_pr = excluded.preco_pr;

insert into public.product_branch_prices(product_code, branch_id, sale_price, source)
select 'SECURITY-FISCAL-055', id, 123, 'MANUAL' from public.branches where code = 'PR'
on conflict(product_code, branch_id) do update set sale_price = excluded.sale_price, source = excluded.source;

do $$
declare
  before_count bigint := (select count(*) from public.quotations where cliente = 'REGRESSAO GUARD FISCAL 055');
  blocked boolean := false;
begin
  begin
    perform public.commercial_create_document('cotacao', jsonb_build_object(
      'regiao', 'PR',
      'cliente_estado', 'AC',
      'customer_type', 'GERAL',
      'cliente', 'REGRESSAO GUARD FISCAL 055',
      'items', jsonb_build_array(jsonb_build_object(
        'codigo', 'SECURITY-FISCAL-055', 'quantidade', 1, 'desconto_percentual', 0
      ))
    ));
  exception when check_violation then
    blocked := sqlerrm like '%CALCULO_FISCAL_INVALIDO%';
  end;

  if not blocked then raise exception 'DOCUMENTO_FISCAL_INVALIDO_NAO_FOI_BLOQUEADO'; end if;
  if (select count(*) from public.quotations where cliente = 'REGRESSAO GUARD FISCAL 055') <> before_count then
    raise exception 'DOCUMENTO_PARCIAL_PERMANECEU_APOS_ROLLBACK';
  end if;
end;
$$;

rollback;
