begin;

create table if not exists public.commercial_route_aliases (
  code text primary key,
  requested_origin_state text not null check (requested_origin_state ~ '^[A-Z]{2}$'),
  requested_destination_state text not null check (requested_destination_state ~ '^[A-Z]{2}$'),
  source_origin_state text not null check (source_origin_state ~ '^[A-Z]{2}$'),
  source_destination_state text not null check (source_destination_state ~ '^[A-Z]{2}$'),
  effective_from date not null,
  effective_until date,
  active boolean not null default true,
  reason text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (effective_until is null or effective_until >= effective_from),
  check (
    requested_origin_state <> source_origin_state
    or requested_destination_state <> source_destination_state
  )
);

create unique index if not exists commercial_route_aliases_active_route_idx
  on public.commercial_route_aliases(requested_origin_state,requested_destination_state,effective_from)
  where active;

alter table public.commercial_route_aliases enable row level security;
revoke all on public.commercial_route_aliases from public,anon,authenticated;
grant select,insert,update,delete on public.commercial_route_aliases to service_role;

insert into public.commercial_route_aliases(
  code,requested_origin_state,requested_destination_state,
  source_origin_state,source_destination_state,effective_from,reason
) values(
  'PR_SP_EQUALS_PR_SC_2026_10_01','PR','SP','PR','SC',date '2026-10-01',
  'Por decisao comercial, a rota PR-SP utiliza exatamente o mesmo resultado fiscal e preco da rota PR-SC.'
)
on conflict(code) do update set
  requested_origin_state=excluded.requested_origin_state,
  requested_destination_state=excluded.requested_destination_state,
  source_origin_state=excluded.source_origin_state,
  source_destination_state=excluded.source_destination_state,
  effective_from=excluded.effective_from,
  reason=excluded.reason,
  updated_at=now();

alter function public.get_product_commercial_price(text,text,text,date,text)
  rename to get_product_commercial_price_raw_093;
revoke all on function public.get_product_commercial_price_raw_093(text,text,text,date,text)
  from public,anon,authenticated;

create function public.get_product_commercial_price(
  product_code text,
  origin_branch text,
  destination_uf text,
  target_date date default public.commercial_business_date(),
  customer_type text default 'REVENDA'
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_origin text:=public.normalize_fiscal_uf(origin_branch);
  v_destination text:=public.normalize_fiscal_uf(destination_uf);
  v_alias public.commercial_route_aliases;
  v_result jsonb;
  v_source_route text;
  v_warnings jsonb;
begin
  select * into v_alias
  from public.commercial_route_aliases a
  where a.active
    and a.requested_origin_state=v_origin
    and a.requested_destination_state=v_destination
    and a.effective_from<=target_date
    and (a.effective_until is null or a.effective_until>=target_date)
  order by a.effective_from desc,a.code
  limit 1;

  if v_alias.code is null then
    return public.get_product_commercial_price_raw_093(
      product_code,origin_branch,destination_uf,target_date,customer_type
    );
  end if;

  v_result:=public.get_product_commercial_price_raw_093(
    product_code,v_alias.source_origin_state,v_alias.source_destination_state,
    target_date,customer_type
  );
  v_source_route:=coalesce(v_result->>'route',
    v_alias.source_origin_state||'-'||v_alias.source_destination_state);
  v_warnings:=coalesce(v_result->'warnings','[]'::jsonb)
    ||jsonb_build_array('ROTA_PR_SP_USA_REGRA_PR_SC');

  return v_result||jsonb_build_object(
    'route',v_origin||'-'||v_destination,
    'origin_state',v_origin,
    'destination_state',v_destination,
    'warnings',v_warnings,
    'source_price_source',v_result->>'price_source',
    'price_source','CRM_ROUTE_ALIAS',
    'route_alias_applied',true,
    'route_alias_code',v_alias.code,
    'route_alias_source_route',v_source_route,
    'route_alias_effective_from',v_alias.effective_from,
    'route_alias_reason',v_alias.reason
  );
end;
$$;

revoke all on function public.get_product_commercial_price(text,text,text,date,text)
  from public,anon;
grant execute on function public.get_product_commercial_price(text,text,text,date,text)
  to authenticated,service_role;

comment on function public.get_product_commercial_price(text,text,text,date,text)
  is 'Resolve aliases comerciais versionados antes do calculo; PR-SP usa o resultado PR-SC desde 2026-10-01.';

commit;
