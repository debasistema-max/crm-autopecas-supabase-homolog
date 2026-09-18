begin;
select set_config('request.jwt.claims',(
  select jsonb_build_object('sub',p.id,'role','authenticated')::text
  from public.profiles p where p.ativo and p.perfil='ADMIN' order by p.created_at limit 1
),true);
set local role authenticated;
do $$
declare v_filters jsonb; v_dashboard jsonb; v_count integer;
begin
  if not public.is_admin() then raise exception 'SECURITY_TEST: admin nao reconhecido'; end if;
  v_filters:=public.get_product_filters();
  if v_filters is null then raise exception 'SECURITY_TEST: filtros CRM indisponiveis'; end if;
  perform public.check_existing_product_codes('["6111032201"]'::jsonb);
  v_dashboard:=public.get_dashboard_summary();
  if v_dashboard is null then raise exception 'SECURITY_TEST: dashboard CRM indisponivel'; end if;
  select count(*) into v_count from public.products;
  if v_count=0 then raise exception 'SECURITY_TEST: catalogo CRM bloqueado'; end if;
end;
$$;
reset role;
rollback;
