begin;
set local lock_timeout='10s';
set local statement_timeout='110s';

-- Deliberately independent of products: a sync must not erase an ADMIN decision
-- by recreating the product. Only the activity RPCs can write this table.
create table public.product_activity_overrides (
  product_code text primary key check(length(product_code) between 1 and 80 and product_code=btrim(product_code)),
  ativo boolean not null,
  changed_by uuid references auth.users(id) on delete set null,
  changed_at timestamptz not null default now()
);
alter table public.product_activity_overrides enable row level security;
revoke all on public.product_activity_overrides from public,anon,authenticated,service_role,ips_catalog_worker;

-- Preserve every currently inactive item; do not infer past intent from logs.
insert into public.product_activity_overrides(product_code,ativo)
  select codigo,false from public.products where not ativo;

create or replace function public.guard_product_activity()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare v_override boolean;
begin
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

create function public.deactivate_products(items jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare item jsonb; v_row record; v_result jsonb; v_rows jsonb:='[]'; v_changed integer:=0; v_count integer;
begin
  if not public.is_app_session_active() or not public.is_internal_user() or not public.is_admin() then
    raise exception 'SOMENTE_ADMIN_ALTERA_ATIVIDADE_PRODUTO';
  end if;
  if jsonb_typeof(items) is distinct from 'array' then raise exception 'LOTE_ATIVIDADE_INVALIDO'; end if;
  if jsonb_array_length(items) not between 1 and 200 then raise exception 'LOTE_ATIVIDADE_LIMITE'; end if;
  for item in select value from jsonb_array_elements(items) loop
    if jsonb_typeof(item) is distinct from 'object' or jsonb_typeof(item->'codigo') is distinct from 'string'
      or nullif(btrim(item->>'codigo'),'') is null or length(item->>'codigo')>80
      or item->>'codigo'<>btrim(item->>'codigo') or jsonb_typeof(item->'expected_active') is distinct from 'boolean' then
      raise exception 'LOTE_ATIVIDADE_INVALIDO';
    end if;
  end loop;
  if exists(select 1 from jsonb_array_elements(items) i group by i->>'codigo' having count(*)>1) then raise exception 'LOTE_ATIVIDADE_DUPLICADO'; end if;
  -- Lock every selected row in the same order before validating or changing any.
  v_count:=0;
  for v_row in select p.codigo,p.ativo from public.products p
    join jsonb_array_elements(items) i on p.codigo=i->>'codigo' order by p.codigo for update of p
  loop
    v_count:=v_count+1;
    select i into item from jsonb_array_elements(items) i where i->>'codigo'=v_row.codigo;
    if v_row.ativo is distinct from (item->>'expected_active')::boolean then raise exception 'PRODUTO_ALTERADO_POR_OUTRO_USUARIO'; end if;
  end loop;
  if v_count<>jsonb_array_length(items) then raise exception 'PRODUTO_NAO_ENCONTRADO'; end if;
  for item in select value from jsonb_array_elements(items) order by value->>'codigo' loop
    v_result:=public.set_product_active(item->>'codigo',false,(item->>'expected_active')::boolean);
    v_rows:=v_rows||jsonb_build_array(v_result);
    if (v_result->>'changed')::boolean then v_changed:=v_changed+1; end if;
  end loop;
  return jsonb_build_object('count',v_count,'changed',v_changed,'rows',v_rows);
end $$;
revoke all on function public.deactivate_products(jsonb) from public,anon,authenticated,service_role,ips_catalog_worker;
grant execute on function public.deactivate_products(jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
