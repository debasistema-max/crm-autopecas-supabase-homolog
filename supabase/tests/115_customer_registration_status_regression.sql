begin;
do $$
declare v text; i integer:=0; v_constraint_name text;
begin
  if not exists(select 1 from pg_constraint where conrelid='public.cadastros_clientes'::regclass
    and conname='cadastros_clientes_status_check' and convalidated) then raise exception 'STATUS_CONSTRAINT_NOT_VALIDATED';end if;
  foreach v in array array['Novo','Em analise','Pendente','Aprovado','Reprovado','Finalizado SAP'] loop
    i:=i+1;
    insert into public.cadastros_clientes(protocolo,cnpj,status,origem)
      values('TEST-115-'||gen_random_uuid(),lpad(i::text,14,'0'),v,'regression_test');
  end loop;
  begin
    insert into public.cadastros_clientes(protocolo,cnpj,status,origem)
      values('TEST-115-'||gen_random_uuid(),'00000000000115','INVALID_STATUS','regression_test');
    raise exception 'INVALID_STATUS_ACCEPTED';
  exception when check_violation then
    get stacked diagnostics v_constraint_name=constraint_name;
    if v_constraint_name<>'cadastros_clientes_status_check' then raise;end if;
  end;
  if not exists(select 1 from pg_class where oid='public.cadastros_clientes'::regclass and relrowsecurity)
    then raise exception 'REGISTRATION_RLS_DISABLED';end if;
end $$;
rollback;
