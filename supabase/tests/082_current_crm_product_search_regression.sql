begin;

select set_config('request.jwt.claims',(
  select jsonb_build_object('sub',p.id,'role','authenticated')::text
  from public.profiles p where p.ativo and p.perfil='ADMIN' order by p.created_at limit 1
),true);
set local role authenticated;

do $$
declare
  v_rows jsonb;
  v_first jsonb;
begin
  v_rows:=public.search_products_v2(jsonb_build_object(
    'term','6111032201','region','SP','limit',10
  ));
  if jsonb_typeof(v_rows)<>'array' then
    raise exception 'SEARCH_V2_NAO_RETORNOU_ARRAY';
  end if;

  if jsonb_array_length(v_rows)>0 then
    v_first:=v_rows->0;
    if v_first->>'codigo'<>'6111032201' then
      raise exception 'CODIGO_EXATO_NAO_PRIORIZADO';
    end if;
    if not (v_first ? 'branch_stock')
       or not (v_first ? 'estoque_quantidade')
       or not (v_first ? 'preco') then
      raise exception 'SNAPSHOT_ATUAL_DA_FILIAL_AUSENTE';
    end if;
  end if;

  perform public.search_products_v2(jsonb_build_object(
    'term','caixa hilux','region','PR','only_available',true,'limit',100
  ));
end;
$$;

reset role;

select set_config('request.jwt.claims',coalesce((
  select jsonb_build_object('sub',a.user_id,'role','authenticated')::text
  from public.customer_portal_accounts a where a.active order by a.created_at limit 1
),'{}'),true);
set local role authenticated;

do $$
declare v_has_b2b boolean; v_denied boolean:=false;
begin
  select exists(select 1 from public.customer_portal_accounts a where a.user_id=auth.uid() and a.active)
  into v_has_b2b;
  if v_has_b2b then
    begin
      perform public.search_products_v2(jsonb_build_object('term','hilux','limit',10));
    exception when others then
      v_denied:=sqlerrm like '%SEM_PERMISSAO%';
    end;
    if not v_denied then raise exception 'B2B_ACESSOU_BUSCA_INTERNA_CRM'; end if;
  end if;
end;
$$;

reset role;
rollback;
