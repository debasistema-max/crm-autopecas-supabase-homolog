begin;
set local lock_timeout='10s';
set local statement_timeout='110s';

-- Business-level denylist. It deliberately has no FK to products so a portal
-- sync cannot erase the decision by deleting and recreating a product.
create table public.product_catalog_exclusions (
  normalized_code text primary key check(
    length(normalized_code) between 1 and 80
    and normalized_code=upper(btrim(normalized_code))
  ),
  reason text not null,
  created_at timestamptz not null default now()
);
alter table public.product_catalog_exclusions enable row level security;
revoke all on public.product_catalog_exclusions from public,anon,authenticated,service_role,ips_catalog_worker;

insert into public.product_catalog_exclusions(normalized_code,reason)
select upper(btrim(value)),'EXCLUSAO_COMERCIAL_PERMANENTE_2026_10_21'
from jsonb_array_elements_text($codes$[
  "8769382300","BAN001","BAN002","H100100011","H100100012",
  "H836511S010","H863521S010BIJ","H865111S000BIJ","H865231S000","H865241S000",
  "H865271S000","H865281S000","H865611S010","H866111S000BIJ","H924051S000",
  "H924061S000","HAE0160763","HAE0160764","HAE0160767","HAE0160768",
  "HAE0160769","HAE0160770","HAE0160785","HAE0160786","HIP1315","HIP1316",
  "HIP1317","HIP1318","ICMS-01","ICMS-02","IM-0001","IMOB 06","imob-01",
  "imob-02","IMOB-03","IMOB-04","IMOB-05","IMOB-06","IMOB-07","IMOB-08",
  "IMOB-09 FITA","IMOB-09FITA","IMOB-10","IMOB-11","IMOB-12","IMOB-13",
  "IMOB-14","IMOB-15","IMOB-16","IMOB-17","IMOB-18","IMOB-19","IMOB-20",
  "IMOB-21","IMOB-22","IMOB-23","IMOB-24","IMOB-25","IMOB06","IPI-01",
  "KIT 001","KIT 002","KIT001","KIT002","PIS_CONFINS","TYLP092 NA","TYLP092NA",
  "VMX 290 MAXVOLVO","VMX290MAXVOLVO","X3475523043","X6111442223","X6111442224",
  "X6115542221","X6115542222"
]$codes$::jsonb);

-- Persist the same decision in the generic activity ledger for compatibility
-- with existing reports and administrative tooling.
insert into public.product_activity_overrides(product_code,ativo,changed_by)
select p.codigo,false,null
from public.products p
join public.product_catalog_exclusions x on x.normalized_code=upper(btrim(p.codigo))
on conflict on constraint product_activity_overrides_pkey do update
  set ativo=false,changed_by=null,changed_at=now();

create or replace function public.guard_product_activity()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare v_override boolean;
begin
  if exists(select 1 from public.product_catalog_exclusions x where x.normalized_code=upper(btrim(new.codigo))) then
    new.ativo:=false;
    return new;
  end if;
  select o.ativo into v_override from public.product_activity_overrides o where o.product_code=new.codigo;
  if found then new.ativo:=v_override;
  elsif tg_op='UPDATE' then new.ativo:=old.ativo;
  else new.ativo:=true;
  end if;
  return new;
end $$;
revoke all on function public.guard_product_activity() from public,anon,authenticated,service_role,ips_catalog_worker;

create or replace function public.set_product_active(product_code text,is_active boolean,expected_active boolean default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_code text:=btrim(product_code); v_active boolean; v_saved boolean;
begin
  if not public.is_app_session_active() or not public.is_internal_user() or not public.is_admin() then
    raise exception 'SOMENTE_ADMIN_ALTERA_ATIVIDADE_PRODUTO';
  end if;
  if nullif(v_code,'') is null or length(v_code)>80 or is_active is null then raise exception 'ATIVIDADE_PRODUTO_INVALIDA'; end if;
  if is_active and exists(select 1 from public.product_catalog_exclusions x where x.normalized_code=upper(v_code)) then
    raise exception 'PRODUTO_EXCLUIDO_PERMANENTEMENTE';
  end if;
  select p.ativo into v_active from public.products p where p.codigo=v_code for update;
  if not found then raise exception 'PRODUTO_NAO_ENCONTRADO'; end if;
  if expected_active is not null and expected_active is distinct from v_active then raise exception 'PRODUTO_ALTERADO_POR_OUTRO_USUARIO'; end if;
  insert into public.product_activity_overrides(product_code,ativo,changed_by)
    values(v_code,is_active,auth.uid())
    on conflict on constraint product_activity_overrides_pkey do update set ativo=excluded.ativo,changed_by=excluded.changed_by,changed_at=now();
  if v_active is distinct from is_active then
    update public.products p set ativo=is_active where p.codigo=v_code returning p.ativo into v_saved;
    if v_saved is distinct from is_active then raise exception 'ATIVIDADE_PRODUTO_NAO_CONFIRMADA'; end if;
    insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_anteriores,dados_novos)
      select p.id,p.usuario,'ALTERAR_ATIVIDADE_PRODUTO','products',v_code,
        jsonb_build_object('ativo',v_active),jsonb_build_object('ativo',is_active)
      from public.profiles p where p.id=auth.uid();
  end if;
  return jsonb_build_object('codigo',v_code,'ativo',is_active,'changed',v_active is distinct from is_active);
end $$;
revoke all on function public.set_product_active(text,boolean,boolean) from public,anon,authenticated,service_role,ips_catalog_worker;
grant execute on function public.set_product_active(text,boolean,boolean) to authenticated;

update public.products p set ativo=false
from public.product_catalog_exclusions x
where x.normalized_code=upper(btrim(p.codigo)) and p.ativo;

-- Never expose permanent exclusions, including through the ADMIN-only inactive
-- view. Other commercial endpoints already require products.ativo=true.
do $$
declare definition text; old_text text; new_text text;
begin
  definition:=pg_get_functiondef('public.search_products_v2(jsonb)'::regprocedure);
  old_text:='and (v_brand='''' or e.marca=v_brand)';
  new_text:=old_text||' and not exists(select 1 from public.product_catalog_exclusions x where x.normalized_code=upper(btrim(e.codigo)))';
  if (length(definition)-length(replace(definition,old_text,'')))<>length(old_text) then
    raise exception 'CONTRATO_BUSCA_112_DIVERGENTE';
  end if;
  definition:=replace(definition,old_text,new_text);
  execute definition;
end;
$$;

comment on table public.product_catalog_exclusions is
  'Códigos permanentemente removidos do catálogo comercial; permanecem bloqueados após sincronizações.';
notify pgrst,'reload schema';
commit;
