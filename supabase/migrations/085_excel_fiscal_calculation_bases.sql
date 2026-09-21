begin;

create table if not exists public.excel_fiscal_base_versions (
  source_version text primary key check (source_version ~ '^[a-f0-9]{64}$'),
  source_updated_at timestamptz not null,
  imported_at timestamptz not null default now(),
  ncm_rule_count integer not null check (ncm_rule_count > 0),
  group_rule_count integer not null check (group_rule_count >= 0),
  source_name text not null default 'EXCEL_API'
);

create table if not exists public.excel_fiscal_ncm_rules (
  source_version text not null references public.excel_fiscal_base_versions(source_version) on delete cascade,
  rule_key text not null,
  ncm text not null check (ncm ~ '^[0-9]{8}$'),
  origin_state text not null check (origin_state ~ '^[A-Z]{2}$'),
  destination_state text not null check (destination_state ~ '^[A-Z]{2}$'),
  cest text check (cest is null or cest ~ '^[0-9]{7}$'),
  cfop text,
  cst_code text,
  mva_rate numeric(12,8),
  interstate_icms_rate numeric(12,8),
  internal_icms_rate numeric(12,8),
  base_reduction_rate numeric(12,8),
  ipi_rate numeric(12,8),
  pis_rate numeric(12,8),
  cofins_rate numeric(12,8),
  fcp_rate numeric(12,8),
  freight_rate numeric(12,8),
  insurance_rate numeric(12,8),
  other_expenses_rate numeric(12,8),
  has_st boolean not null,
  notes text,
  primary key(source_version,rule_key),
  check (mva_rate is null or mva_rate between 0 and 10),
  check (interstate_icms_rate is null or interstate_icms_rate between 0 and 1),
  check (internal_icms_rate is null or internal_icms_rate between 0 and 1),
  check (ipi_rate is null or ipi_rate between 0 and 1)
);

create table if not exists public.excel_fiscal_group_rules (
  source_version text not null references public.excel_fiscal_base_versions(source_version) on delete cascade,
  rule_key text not null,
  ncm text not null check (ncm ~ '^[0-9]{8}$'),
  item_group text not null,
  item_group_key text not null,
  route text not null check (route ~ '^[A-Z]{2}-[A-Z]{2}$'),
  mva_rate numeric(12,8) not null check (mva_rate between 0 and 10),
  ipi_rate numeric(12,8) not null check (ipi_rate between 0 and 1),
  interstate_icms_rate numeric(12,8) not null check (interstate_icms_rate between 0 and 1),
  internal_icms_rate numeric(12,8) not null check (internal_icms_rate between 0 and 1),
  has_st boolean not null,
  sample_base_price numeric(14,2),
  sample_final_price numeric(14,2),
  sample_st_amount numeric(14,2),
  sample_product_code text,
  primary key(source_version,rule_key)
);

create table if not exists public.excel_fiscal_base_state (
  singleton boolean primary key default true check (singleton),
  current_source_version text not null references public.excel_fiscal_base_versions(source_version),
  updated_at timestamptz not null default now()
);

create index if not exists excel_fiscal_ncm_rules_lookup_idx
  on public.excel_fiscal_ncm_rules(source_version,ncm,origin_state,destination_state);
create index if not exists excel_fiscal_group_rules_lookup_idx
  on public.excel_fiscal_group_rules(source_version,ncm,item_group_key,route);

alter table public.excel_fiscal_base_versions enable row level security;
alter table public.excel_fiscal_ncm_rules enable row level security;
alter table public.excel_fiscal_group_rules enable row level security;
alter table public.excel_fiscal_base_state enable row level security;
revoke all on public.excel_fiscal_base_versions,public.excel_fiscal_ncm_rules,
  public.excel_fiscal_group_rules,public.excel_fiscal_base_state from public,anon,authenticated;
grant select,insert,update,delete on public.excel_fiscal_base_versions,public.excel_fiscal_ncm_rules,
  public.excel_fiscal_group_rules,public.excel_fiscal_base_state to service_role;

create or replace function public.sync_excel_fiscal_bases(
  target_source_version text,
  target_source_updated_at timestamptz,
  ncm_rules jsonb,
  group_rules jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_version text:=lower(btrim(coalesce(target_source_version,'')));
  v_ncm_count integer;
  v_group_count integer;
  v_inserted integer;
  v_existing_group_count integer;
  v_duplicate boolean:=false;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user not in ('postgres','supabase_admin') then
    raise exception 'SEM_PERMISSAO_SINCRONIZAR_BASE_FISCAL';
  end if;
  if v_version !~ '^[a-f0-9]{64}$' then raise exception 'VERSAO_ORIGEM_INVALIDA'; end if;
  if target_source_updated_at is null or target_source_updated_at>now()+interval '5 minutes' then
    raise exception 'DATA_ORIGEM_INVALIDA';
  end if;
  if jsonb_typeof(ncm_rules)<>'array' or jsonb_typeof(group_rules)<>'array' then
    raise exception 'BASES_FISCAIS_INVALIDAS';
  end if;
  v_ncm_count:=jsonb_array_length(ncm_rules);
  v_group_count:=jsonb_array_length(group_rules);
  if v_ncm_count<1 or v_ncm_count>1000 or v_group_count>2000 then
    raise exception 'QUANTIDADE_BASE_FISCAL_INVALIDA';
  end if;

  if exists(select 1 from public.excel_fiscal_base_versions where source_version=v_version) then
    select ncm_rule_count,group_rule_count into v_inserted,v_existing_group_count
    from public.excel_fiscal_base_versions where source_version=v_version;
    if v_inserted<>v_ncm_count or v_existing_group_count<>v_group_count then
      raise exception 'VERSAO_FISCAL_EXISTENTE_DIVERGENTE';
    end if;
    v_duplicate:=true;
  else
    insert into public.excel_fiscal_base_versions(
      source_version,source_updated_at,ncm_rule_count,group_rule_count
    ) values(v_version,target_source_updated_at,v_ncm_count,v_group_count);

    insert into public.excel_fiscal_ncm_rules(
      source_version,rule_key,ncm,origin_state,destination_state,cest,cfop,cst_code,
      mva_rate,interstate_icms_rate,internal_icms_rate,base_reduction_rate,ipi_rate,
      pis_rate,cofins_rate,fcp_rate,freight_rate,insurance_rate,other_expenses_rate,has_st,notes
    )
    select v_version,
      public.normalize_ncm(x.value->>'ncm')||'|'||upper(btrim(x.value->>'origin_state'))||'|'||upper(btrim(x.value->>'destination_state')),
      public.normalize_ncm(x.value->>'ncm'),upper(btrim(x.value->>'origin_state')),upper(btrim(x.value->>'destination_state')),
      public.normalize_cest(x.value->>'cest'),nullif(btrim(x.value->>'cfop'),''),nullif(btrim(x.value->>'cst_code'),''),
      nullif(x.value->>'mva_rate','')::numeric,nullif(x.value->>'interstate_icms_rate','')::numeric,
      nullif(x.value->>'internal_icms_rate','')::numeric,coalesce(nullif(x.value->>'base_reduction_rate','')::numeric,0),
      nullif(x.value->>'ipi_rate','')::numeric,nullif(x.value->>'pis_rate','')::numeric,
      nullif(x.value->>'cofins_rate','')::numeric,nullif(x.value->>'fcp_rate','')::numeric,
      nullif(x.value->>'freight_rate','')::numeric,nullif(x.value->>'insurance_rate','')::numeric,
      nullif(x.value->>'other_expenses_rate','')::numeric,coalesce((x.value->>'has_st')::boolean,false),
      left(nullif(btrim(x.value->>'notes'),''),1000)
    from jsonb_array_elements(ncm_rules) x
    where public.normalize_ncm(x.value->>'ncm') is not null
      and upper(btrim(x.value->>'origin_state')) ~ '^[A-Z]{2}$'
      and upper(btrim(x.value->>'destination_state')) ~ '^[A-Z]{2}$';
    get diagnostics v_inserted=row_count;
    if v_inserted<>v_ncm_count then raise exception 'BASE_FISCAL_NCM_CONTEM_LINHAS_INVALIDAS'; end if;

    insert into public.excel_fiscal_group_rules(
      source_version,rule_key,ncm,item_group,item_group_key,route,mva_rate,ipi_rate,
      interstate_icms_rate,internal_icms_rate,has_st,sample_base_price,sample_final_price,
      sample_st_amount,sample_product_code
    )
    select v_version,
      public.normalize_ncm(x.value->>'ncm')||'|'||upper(regexp_replace(btrim(x.value->>'item_group'),'\s+',' ','g'))||'|'||upper(btrim(x.value->>'route')),
      public.normalize_ncm(x.value->>'ncm'),btrim(x.value->>'item_group'),
      upper(regexp_replace(btrim(x.value->>'item_group'),'\s+',' ','g')),upper(btrim(x.value->>'route')),
      (x.value->>'mva_rate')::numeric,(x.value->>'ipi_rate')::numeric,
      (x.value->>'interstate_icms_rate')::numeric,(x.value->>'internal_icms_rate')::numeric,
      coalesce((x.value->>'has_st')::boolean,false),nullif(x.value->>'sample_base_price','')::numeric,
      nullif(x.value->>'sample_final_price','')::numeric,nullif(x.value->>'sample_st_amount','')::numeric,
      public.normalize_integration_product_code(x.value->>'sample_product_code')
    from jsonb_array_elements(group_rules) x
    where public.normalize_ncm(x.value->>'ncm') is not null
      and nullif(btrim(x.value->>'item_group'),'') is not null
      and upper(btrim(x.value->>'route')) ~ '^[A-Z]{2}-[A-Z]{2}$';
    get diagnostics v_inserted=row_count;
    if v_inserted<>v_group_count then raise exception 'BASE_FISCAL_GRUPO_CONTEM_LINHAS_INVALIDAS'; end if;
  end if;

  insert into public.excel_fiscal_base_state(singleton,current_source_version,updated_at)
  values(true,v_version,now())
  on conflict(singleton) do update set current_source_version=excluded.current_source_version,updated_at=now();

  return jsonb_build_object(
    'source_version',v_version,'source_updated_at',target_source_updated_at,
    'ncm_rules',v_ncm_count,'group_rules',jsonb_array_length(group_rules),'duplicate',v_duplicate
  );
end;
$$;

revoke all on function public.sync_excel_fiscal_bases(text,timestamptz,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.sync_excel_fiscal_bases(text,timestamptz,jsonb,jsonb) to service_role;

do $$
begin
  if to_regprocedure('public.calculate_product_price_crm_rules(text,text,text,numeric,date,text)') is null then
    alter function public.calculate_product_price(text,text,text,numeric,date,text)
      rename to calculate_product_price_crm_rules;
  end if;
end;
$$;

create or replace function public.calculate_product_price_from_excel_base(
  product_code text,
  origin_state text,
  destination_state text,
  input_base_price numeric default null,
  calculation_date date default current_date,
  target_customer_type text default 'REVENDA'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_product public.products;
  v_sap public.product_sap_data;
  v_group public.excel_fiscal_group_rules;
  v_ncm public.excel_fiscal_ncm_rules;
  v_version text;
  v_base numeric(16,6):=round(input_base_price,6);
  v_origin text:=public.normalize_fiscal_uf(origin_state);
  v_destination text:=public.normalize_fiscal_uf(destination_state);
  v_route text;
  v_mva numeric(12,8);
  v_ipi_rate numeric(12,8);
  v_interstate numeric(12,8);
  v_internal numeric(12,8);
  v_has_st boolean;
  v_ipi numeric(16,6);
  v_own_icms numeric(16,6);
  v_st_base numeric(16,6);
  v_icms_st numeric(16,6);
  v_taxes numeric(16,6);
  v_status text;
  v_warnings jsonb:='[]'::jsonb;
  v_source text;
begin
  select * into v_product from public.products where codigo=btrim(product_code);
  if v_product.codigo is null or v_origin is null or v_destination is null or v_base is null or v_base<=0 then
    return null;
  end if;
  if public.normalize_ncm(v_product.ncm) is null then return null; end if;
  select current_source_version into v_version from public.excel_fiscal_base_state where singleton;
  if v_version is null then return null; end if;
  v_route:=v_origin||'-'||v_destination;
  select s.* into v_sap from public.product_sap_data s where s.product_code=v_product.codigo;
  if nullif(btrim(v_sap.item_group),'') is not null then
    select * into v_group from public.excel_fiscal_group_rules r
    where r.source_version=v_version and r.ncm=public.normalize_ncm(v_product.ncm)
      and r.item_group_key=upper(regexp_replace(btrim(v_sap.item_group),'\s+',' ','g'))
      and r.route=v_route limit 1;
  end if;
  select * into v_ncm from public.excel_fiscal_ncm_rules r
  where r.source_version=v_version and r.ncm=public.normalize_ncm(v_product.ncm)
    and r.origin_state=v_origin and r.destination_state=v_destination limit 1;
  if v_group.rule_key is null and v_ncm.rule_key is null then return null; end if;

  if v_group.rule_key is not null then
    v_mva:=v_group.mva_rate; v_ipi_rate:=v_group.ipi_rate;
    v_interstate:=v_group.interstate_icms_rate; v_internal:=v_group.internal_icms_rate;
    v_has_st:=v_group.has_st; v_source:='EXCEL_GROUP_BASE';
  else
    v_mva:=v_ncm.mva_rate; v_ipi_rate:=v_ncm.ipi_rate;
    v_interstate:=v_ncm.interstate_icms_rate; v_internal:=v_ncm.internal_icms_rate;
    v_has_st:=v_ncm.has_st; v_source:='EXCEL_NCM_BASE';
  end if;

  if v_ipi_rate is null then v_warnings:=v_warnings||jsonb_build_array('IPI_AUSENTE'); end if;
  if v_interstate is null then v_warnings:=v_warnings||jsonb_build_array('ICMS_INTERESTADUAL_AUSENTE'); end if;
  if v_has_st and v_internal is null then v_warnings:=v_warnings||jsonb_build_array('ICMS_INTERNO_AUSENTE'); end if;
  if v_has_st and v_mva is null then v_warnings:=v_warnings||jsonb_build_array('MVA_AUSENTE'); end if;
  if v_ncm.pis_rate is null then v_warnings:=v_warnings||jsonb_build_array('PIS_NAO_DEFINIDO'); end if;
  if v_ncm.cofins_rate is null then v_warnings:=v_warnings||jsonb_build_array('COFINS_NAO_DEFINIDO'); end if;
  if v_ncm.fcp_rate is null then v_warnings:=v_warnings||jsonb_build_array('FCP_NAO_DEFINIDO'); end if;

  v_ipi:=case when v_ipi_rate is null then null else round(v_base*v_ipi_rate,6) end;
  v_own_icms:=case when v_interstate is null then null else round(v_base*v_interstate,6) end;
  v_st_base:=case when not v_has_st then v_base else round((v_base+coalesce(v_ipi,0))*(1+coalesce(v_mva,0)),6) end;
  v_icms_st:=case when not v_has_st then 0
    when v_internal is null or v_mva is null or v_own_icms is null then null
    else round(greatest(0,v_st_base*v_internal-v_own_icms),6) end;
  v_taxes:=round(coalesce(v_ipi,0),2)+round(coalesce(v_icms_st,0),2);
  v_status:=case
    when v_ipi_rate is null or v_interstate is null or (v_has_st and (v_internal is null or v_mva is null))
      then 'REGRA_FISCAL_INCOMPLETA'
    when v_has_st then 'OK' else 'OK_SEM_ST' end;

  return jsonb_build_object(
    'product_code',v_product.codigo,'route',v_route,'origin_state',v_origin,'destination_state',v_destination,
    'ncm',public.normalize_ncm(v_product.ncm),'cest',coalesce(v_ncm.cest,v_product.cest),
    'base_price',round(v_base,2),'mva_rate',v_mva,'ipi_rate',v_ipi_rate,
    'interstate_icms_rate',v_interstate,'internal_icms_rate',v_internal,'base_st',v_st_base,
    'ipi_amount',v_ipi,'own_icms_amount',v_own_icms,'icms_st_amount',v_icms_st,
    'pis_amount',null,'cofins_amount',null,'fcp_amount',null,'total_expenses',0,
    'total_taxes',v_taxes,'final_price',round(v_base,2)+v_taxes,
    'has_st',v_has_st,'status',v_status,'warnings',v_warnings,'customer_type',upper(coalesce(target_customer_type,'REVENDA')),
    'calculation_profile',v_source,'calculation_method','MVA_ST','calculation_rule_source',v_source,
    'own_icms_included_in_total',false,'fiscal_base_source_version',v_version,
    'group_rule_key',v_group.rule_key,'ncm_rule_key',v_ncm.rule_key,'item_group',v_sap.item_group,
    'calculated_at',now()
  );
end;
$$;

create or replace function public.calculate_product_price(
  product_code text,
  origin_state text,
  destination_state text,
  input_base_price numeric default null,
  calculation_date date default current_date,
  target_customer_type text default 'GERAL'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  v_result:=public.calculate_product_price_from_excel_base(
    product_code,origin_state,destination_state,input_base_price,calculation_date,target_customer_type
  );
  if v_result is not null then return v_result; end if;
  v_result:=public.calculate_product_price_crm_rules(
    product_code,origin_state,destination_state,input_base_price,calculation_date,target_customer_type
  );
  return v_result||jsonb_build_object('calculation_rule_source','CRM_FISCAL_RULE');
end;
$$;

revoke all on function public.calculate_product_price_from_excel_base(text,text,text,numeric,date,text),
  public.calculate_product_price(text,text,text,numeric,date,text) from public,anon;
grant execute on function public.calculate_product_price_from_excel_base(text,text,text,numeric,date,text),
  public.calculate_product_price(text,text,text,numeric,date,text) to authenticated,service_role;

comment on table public.excel_fiscal_base_versions is 'Versões imutáveis das bases fiscais calculadas e salvas no Excel mestre.';
comment on table public.excel_fiscal_group_rules is 'Regras fiscais específicas por NCM, grupo de item e rota; têm prioridade no motor comparativo.';
comment on function public.sync_excel_fiscal_bases(text,timestamptz,jsonb,jsonb) is 'Publica atomicamente uma versão das bases fiscais do Excel, restrita ao executor server-side.';
comment on function public.calculate_product_price(text,text,text,numeric,date,text) is 'Motor comparativo: prioriza bases versionadas do Excel e usa regras antigas do CRM somente quando a planilha não possui a chave.';

commit;
