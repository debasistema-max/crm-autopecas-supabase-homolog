begin;

create or replace function public.get_fiscal_pending(filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit integer:=least(greatest(coalesce((filters->>'limit')::integer,200),1),5000);
  v_offset integer:=greatest(coalesce((filters->>'offset')::integer,0),0);
  v_rows jsonb;
  v_summary jsonb;
begin
  if auth.uid() is not null and not (public.is_admin() or public.has_module('alimentacao') or public.has_module('configuracoes')) then
    raise exception 'SEM_PERMISSAO';
  end if;
  with routes(origin,destination) as (values ('PR','PR'),('SP','SP'),('PR','SC')),
  pending as (
    select p.codigo,p.descricao,p.marca,p.ncm,p.cest,p.ipi_defined,r.origin||'-'||r.destination route,
      case
        when p.ncm is null then 'NCM_AUSENTE'
        when fr.id is null then 'REGRA_FISCAL_AUSENTE'
        when fr.interstate_icms_rate is null or (coalesce(fr.has_st,false) and (fr.internal_icms_rate is null or fr.mva_rate is null)) then 'REGRA_FISCAL_INCOMPLETA'
        when bp.product_code is null or bp.sale_price<=0 or (bp.source_batch_id is null and bp.source='LEGACY_SYNC') then 'PRECO_AUSENTE'
        when bs.product_code is null or (bs.source_batch_id is null and coalesce(bs.version,0)=0) then 'ESTOQUE_NAO_IMPORTADO'
        else null
      end status
    from public.products p cross join routes r
    left join public.branches b on b.code=r.origin and b.active
    left join public.product_branch_prices bp on bp.product_code=p.codigo and bp.branch_id=b.id
    left join public.product_branch_stock bs on bs.product_code=p.codigo and bs.branch_id=b.id
    left join lateral (
      select x.* from public.fiscal_tax_rules x where x.active and x.ncm=p.ncm and x.uf_origem=r.origin and x.uf_destino=r.destination
        and x.effective_from<=current_date and (x.effective_to is null or x.effective_to>=current_date)
      order by x.effective_from desc limit 1
    ) fr on true
  ), filtered as (
    select * from pending where status is not null
      and (nullif(filters->>'status','') is null or status=filters->>'status')
      and (nullif(filters->>'route','') is null or route=upper(filters->>'route'))
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.codigo,x.route),'[]'::jsonb) into v_rows
  from (select * from filtered order by codigo,route limit v_limit offset v_offset) x;

  select jsonb_build_object(
    'products_without_ncm',(select count(*) from public.products where ncm is null),
    'products_without_cest',(select count(*) from public.products where cest is null),
    'products_without_ipi',(select count(*) from public.products where not ipi_defined),
    'rules_incomplete',(select count(*) from public.fiscal_tax_rules f where f.active and
      (f.interstate_icms_rate is null or (coalesce(f.has_st,false) and (f.internal_icms_rate is null or f.mva_rate is null)))),
    'fiscal_source_rows_rejected',(
      select count(*) from (
        select distinct b.file_hash,b.import_kind,s.row_number,coalesce(s.normalized_data->>'source_code','') source_code
        from public.products_import_batches b
        join public.products_import_stage s on s.batch_id=b.id
        where b.import_kind like 'FISCAL_RULES_%' and s.status='error'
      ) rejected
    ),
    'products_without_price_pr',(select count(*) from public.products p join public.branches b on b.code='PR'
      left join public.product_branch_prices bp on bp.product_code=p.codigo and bp.branch_id=b.id
      where bp.product_code is null or bp.sale_price<=0 or (bp.source_batch_id is null and bp.source='LEGACY_SYNC')),
    'products_without_price_sp',(select count(*) from public.products p join public.branches b on b.code='SP'
      left join public.product_branch_prices bp on bp.product_code=p.codigo and bp.branch_id=b.id
      where bp.product_code is null or bp.sale_price<=0 or (bp.source_batch_id is null and bp.source='LEGACY_SYNC')),
    'products_without_stock_pr',(select count(*) from public.products p join public.branches b on b.code='PR'
      left join public.product_branch_stock bs on bs.product_code=p.codigo and bs.branch_id=b.id
      where bs.product_code is null or (bs.source_batch_id is null and coalesce(bs.version,0)=0)),
    'products_without_stock_sp',(select count(*) from public.products p join public.branches b on b.code='SP'
      left join public.product_branch_stock bs on bs.product_code=p.codigo and bs.branch_id=b.id
      where bs.product_code is null or (bs.source_batch_id is null and coalesce(bs.version,0)=0))
  ) into v_summary;
  return jsonb_build_object('summary',v_summary,'rows',v_rows,'limit',v_limit,'offset',v_offset);
end;
$$;

comment on function public.get_fiscal_pending(jsonb)
  is 'Pendencias fiscais, comerciais e linhas de origem rejeitadas pela validacao antes do commit.';

commit;
