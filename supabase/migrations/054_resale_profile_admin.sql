begin;

-- Keep the resale calculation profile editable through the existing audited
-- fiscal-rule administration RPC. Missing profile fields preserve the current
-- value so older import clients remain backward compatible.
create or replace function public.save_fiscal_tax_rule(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  v_id uuid:=nullif(payload->>'id','')::uuid;
  v_record public.fiscal_tax_rules;
  v_before jsonb;
begin
  actor:=public.commercial_active_profile();
  if actor.id is null or not public.can_manage_fiscal_tax_rules() then raise exception 'SEM_PERMISSAO'; end if;
  if v_id is null then
    select r.id into v_id from public.fiscal_tax_rules r
    where r.ncm=public.normalize_ncm(payload->>'ncm')
      and r.uf_origem=public.normalize_fiscal_uf(payload->>'uf_origem')
      and r.uf_destino=public.normalize_fiscal_uf(payload->>'uf_destino')
      and r.operation_type=upper(coalesce(nullif(btrim(payload->>'operation_type'),''),'VENDA'))
      and r.customer_type=upper(coalesce(nullif(btrim(payload->>'customer_type'),''),'GERAL'))
      and r.effective_from=coalesce(nullif(payload->>'effective_from','')::date,current_date)
    limit 1;
  end if;
  if v_id is not null then select to_jsonb(r) into v_before from public.fiscal_tax_rules r where id=v_id; end if;
  insert into public.fiscal_tax_rules(
    id,ncm,uf_origem,uf_destino,operation_type,customer_type,cest,cfop,cst_code,has_st,
    icms_percent,icms_st_percent,mva_percent,ipi_percent,pis_percent,cofins_percent,fcp_percent,
    base_reduction_rate,freight_rate,insurance_rate,other_expenses_rate,
    resale_calculation_method,resale_icms_st_rate,resale_include_own_icms,
    effective_from,effective_to,active,notes,source,created_by,updated_by
  ) values(
    coalesce(v_id,gen_random_uuid()),public.normalize_ncm(payload->>'ncm'),public.normalize_fiscal_uf(payload->>'uf_origem'),
    public.normalize_fiscal_uf(payload->>'uf_destino'),upper(coalesce(nullif(btrim(payload->>'operation_type'),''),'VENDA')),
    upper(coalesce(nullif(btrim(payload->>'customer_type'),''),'GERAL')),public.normalize_cest(payload->>'cest'),nullif(btrim(payload->>'cfop'),''),
    nullif(btrim(payload->>'cst_code'),''),coalesce((payload->>'has_st')::boolean,false),
    coalesce(nullif(payload->>'icms_percent','')::numeric,0),coalesce(nullif(payload->>'icms_st_percent','')::numeric,0),
    coalesce(nullif(payload->>'mva_percent','')::numeric,0),coalesce(nullif(payload->>'ipi_percent','')::numeric,0),
    coalesce(nullif(payload->>'pis_percent','')::numeric,0),coalesce(nullif(payload->>'cofins_percent','')::numeric,0),coalesce(nullif(payload->>'fcp_percent','')::numeric,0),
    coalesce(nullif(payload->>'base_reduction_percent','')::numeric/100,0),coalesce(nullif(payload->>'freight_percent','')::numeric/100,0),
    coalesce(nullif(payload->>'insurance_percent','')::numeric/100,0),coalesce(nullif(payload->>'other_expenses_percent','')::numeric/100,0),
    coalesce(nullif(upper(btrim(payload->>'resale_calculation_method')),''),v_before->>'resale_calculation_method','MVA_ST'),
    case when payload ? 'resale_icms_st_percent' then nullif(payload->>'resale_icms_st_percent','')::numeric/100
      else nullif(v_before->>'resale_icms_st_rate','')::numeric end,
    case when payload ? 'resale_include_own_icms' then coalesce((payload->>'resale_include_own_icms')::boolean,false)
      else coalesce((v_before->>'resale_include_own_icms')::boolean,false) end,
    coalesce(nullif(payload->>'effective_from','')::date,current_date),nullif(payload->>'effective_to','')::date,
    coalesce((payload->>'active')::boolean,true),nullif(btrim(payload->>'notes'),''),'MANUAL',actor.id,actor.id
  )
  on conflict(id) do update set ncm=excluded.ncm,uf_origem=excluded.uf_origem,uf_destino=excluded.uf_destino,
    operation_type=excluded.operation_type,customer_type=excluded.customer_type,cest=excluded.cest,cfop=excluded.cfop,cst_code=excluded.cst_code,
    has_st=excluded.has_st,icms_percent=excluded.icms_percent,icms_st_percent=excluded.icms_st_percent,mva_percent=excluded.mva_percent,
    ipi_percent=excluded.ipi_percent,pis_percent=excluded.pis_percent,cofins_percent=excluded.cofins_percent,fcp_percent=excluded.fcp_percent,
    base_reduction_rate=excluded.base_reduction_rate,freight_rate=excluded.freight_rate,insurance_rate=excluded.insurance_rate,
    other_expenses_rate=excluded.other_expenses_rate,resale_calculation_method=excluded.resale_calculation_method,
    resale_icms_st_rate=excluded.resale_icms_st_rate,resale_include_own_icms=excluded.resale_include_own_icms,
    effective_from=excluded.effective_from,effective_to=excluded.effective_to,
    active=excluded.active,notes=excluded.notes,source='MANUAL',updated_by=actor.id,updated_at=now()
  returning * into v_record;
  insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_anteriores,dados_novos)
  values(actor.id,actor.usuario,'SALVAR_REGRA_FISCAL','fiscal_tax_rules',v_record.id::text,v_before,to_jsonb(v_record));
  return to_jsonb(v_record);
end;
$$;

grant execute on function public.save_fiscal_tax_rule(jsonb) to authenticated;
comment on function public.save_fiscal_tax_rule(jsonb)
  is 'Administra e audita regra fiscal, incluindo o perfil de cálculo comercial para REVENDA.';

commit;
