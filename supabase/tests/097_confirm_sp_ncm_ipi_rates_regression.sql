begin;

do $$
declare
  v_row record;
  v_product_code text;
  v_result jsonb;
  v_expected numeric(12,8);
begin
  for v_row in
    select * from (values
      ('84145990'::text, 0.00000000::numeric),
      ('84835090'::text, 0.07800000::numeric),
      ('84839000'::text, 0.00000000::numeric),
      ('85122022'::text, 0.09750000::numeric),
      ('87082913'::text, 0.03250000::numeric),
      ('84136019'::text, 0.00000000::numeric),
      ('84213100'::text, 0.05200000::numeric),
      ('87089490'::text, 0.03250000::numeric)
    ) as confirmed(ncm, ipi_rate)
  loop
    if not exists(
      select 1 from public.fiscal_tax_rules r
      where r.ncm = v_row.ncm
        and r.uf_origem = 'SP' and r.uf_destino = 'SP'
        and r.operation_type = 'VENDA' and r.customer_type = 'GERAL'
        and r.active and r.lifecycle_status = 'ACTIVE'
        and r.ipi_rate = v_row.ipi_rate
        and r.effective_from <= date '2026-10-01'
        and (r.effective_to is null or r.effective_to >= date '2026-10-01')
    ) then
      raise exception 'REGRA_SP_IPI_AUSENTE_OU_DIVERGENTE: %', v_row.ncm;
    end if;

    select p.codigo into v_product_code
    from public.products p
    where public.normalize_ncm(p.ncm) = v_row.ncm
    order by p.codigo
    limit 1;

    if v_product_code is null then
      raise exception 'PRODUTO_TESTE_NAO_ENCONTRADO: %', v_row.ncm;
    end if;

    v_result := public.calculate_product_price_crm_rules(
      v_product_code, 'SP', 'SP', 100, date '2026-10-05', 'REVENDA'
    );
    v_expected := round(100 * v_row.ipi_rate, 6);

    if (v_result->>'fiscal_rule_id') is null
       or (v_result->>'ipi_rate')::numeric <> v_row.ipi_rate
       or (v_result->>'ipi_amount')::numeric <> v_expected then
      raise exception 'CALCULO_SP_IPI_DIVERGENTE: % => %', v_row.ncm, v_result;
    end if;
  end loop;
end;
$$;

rollback;
