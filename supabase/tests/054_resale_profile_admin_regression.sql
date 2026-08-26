begin;

select set_config('request.jwt.claim.sub',(
  select id::text from public.profiles where perfil='ADMIN' and ativo order by created_at limit 1
),true);

do $$
declare
  saved jsonb;
begin
  saved:=public.save_fiscal_tax_rule(jsonb_build_object(
    'ncm','99999999','uf_origem','SP','uf_destino','SP','operation_type','VENDA','customer_type','GERAL',
    'icms_percent','4','icms_st_percent','18','mva_percent','50','ipi_percent','3.25','has_st',true,
    'resale_calculation_method','RATE_DIFFERENCE','resale_icms_st_percent','13.994828',
    'resale_include_own_icms',false,'effective_from',current_date::text,'active',true
  ));
  if saved->>'resale_calculation_method'<>'RATE_DIFFERENCE'
    or abs((saved->>'resale_icms_st_rate')::numeric-0.13994828)>0.00000001
    or coalesce((saved->>'resale_include_own_icms')::boolean,true) then
    raise exception 'PERFIL_REVENDA_ADMIN_DIVERGENTE: %',saved;
  end if;
end;
$$;

rollback;
