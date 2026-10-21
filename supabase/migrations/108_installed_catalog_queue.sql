begin;
set local lock_timeout = '10s';
set local statement_timeout = '110s';

-- This login is provisioned separately on the Windows executor, never in Git.
do $$ begin
  if not exists(select 1 from pg_roles where rolname='ips_catalog_worker') then
    create role ips_catalog_worker nologin noinherit nosuperuser nocreatedb nocreaterole nobypassrls;
  end if;
end $$;
grant usage on schema public to ips_catalog_worker;

create table public.installed_catalog_sync_requests (
  id uuid primary key default gen_random_uuid(),
  requested_by uuid not null references public.profiles(id),
  status text not null default 'queued' check(status in ('queued','running','completed','failed')),
  requested_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  lease_until timestamptz,
  claim_token uuid,
  batch_id uuid references public.catalog_metadata_sync_batches(id),
  summary jsonb not null default '{}'::jsonb,
  error_code text
);
create unique index installed_catalog_one_pending on public.installed_catalog_sync_requests((true))
  where status in ('queued','running');
create index installed_catalog_history on public.installed_catalog_sync_requests(requested_at desc);
alter table public.installed_catalog_sync_requests enable row level security;
revoke all on public.installed_catalog_sync_requests from public,anon,authenticated,ips_catalog_worker;

create function public.request_installed_catalog_sync()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.installed_catalog_sync_requests;
begin
  if not public.is_app_session_active() or not public.is_admin() then
    raise sqlstate 'PT403' using message='SOMENTE_ADMIN_CATALOGO';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('ips-installed-catalog-queue',0));
  update public.installed_catalog_sync_requests set status='failed',finished_at=now(),error_code='EXECUTOR_TEMPO_ESGOTADO',claim_token=null
    where (status='running' and lease_until<now()) or (status='queued' and requested_at<now()-interval '24 hours');
  select * into r from public.installed_catalog_sync_requests where status in ('queued','running') limit 1;
  if r.id is null then
    insert into public.installed_catalog_sync_requests(requested_by) values(auth.uid()) returning * into r;
    insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_novos)
      values(auth.uid(),(select usuario from public.profiles where id=auth.uid()),'SOLICITAR_CATALOGO_IPS',
        'installed_catalog_sync_requests',r.id::text,jsonb_build_object('source','IPS_INSTALLED_CATALOG'));
  end if;
  return jsonb_build_object('id',r.id,'status',r.status,'requested_at',r.requested_at);
end $$;

create function public.list_installed_catalog_sync()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
  if not public.is_app_session_active() or not public.is_admin() then
    raise sqlstate 'PT403' using message='SOMENTE_ADMIN_CATALOGO';
  end if;
  return jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(t)) from (
    select r.id,r.status,r.requested_at,r.started_at,r.finished_at,r.lease_until,r.batch_id,r.summary,r.error_code,p.usuario
    from public.installed_catalog_sync_requests r join public.profiles p on p.id=r.requested_by
    order by r.requested_at desc limit 20
  ) t),'[]'::jsonb));
end $$;

create function public.claim_installed_catalog_sync()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.installed_catalog_sync_requests;
begin
  perform pg_advisory_xact_lock(hashtextextended('ips-installed-catalog-queue',0));
  update public.installed_catalog_sync_requests set status='failed',finished_at=now(),error_code='EXECUTOR_TEMPO_ESGOTADO',claim_token=null
    where (status='running' and lease_until<now()) or (status='queued' and requested_at<now()-interval '24 hours');
  select * into r from public.installed_catalog_sync_requests where status='queued' order by requested_at limit 1 for update;
  if r.id is null then return null; end if;
  update public.installed_catalog_sync_requests set status='running',started_at=now(),lease_until=now()+interval '30 minutes',claim_token=gen_random_uuid()
    where id=r.id returning * into r;
  return jsonb_build_object('id',r.id,'claim_token',r.claim_token);
end $$;

create function public.snapshot_installed_catalog_sync(job_id uuid, token uuid, after_code text default '')
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
  if not exists(select 1 from public.installed_catalog_sync_requests where id=job_id and status='running' and claim_token=token and lease_until>now()) then
    raise exception 'LOTE_OU_EXECUTOR_INVALIDO';
  end if;
  return coalesce((select jsonb_agg(to_jsonb(t)) from (
    select p.codigo,p.url_imagem,p.marca,p.aplicacao,p.categoria,p.montadora,p.oem,p.similar,p.detalhes,
      m.line_name as catalog_line,m.applications as catalog_application
    from public.products p left join public.product_catalog_metadata m on m.product_code=p.codigo
    where p.codigo>after_code order by p.codigo limit 250
  ) t),'[]'::jsonb);
end $$;

-- Preserve manual notes outside the single, explicitly delimited source block.
create function public.installed_catalog_manual_notes(value text)
returns text language plpgsql immutable set search_path=public,pg_temp as $$
declare a text:='[CATALOGO_IPS_INSTALADO]'; b text:='[/CATALOGO_IPS_INSTALADO]';
  v text:=btrim(coalesce(value,''),E' \t\r\n'); prefix text; suffix text;
begin
  if strpos(v,a)=0 and strpos(v,b)=0 then return v; end if;
  if (length(v)-length(replace(v,a,'')))/length(a)<>1 or
     (length(v)-length(replace(v,b,'')))/length(b)<>1 or strpos(v,a)>strpos(v,b) then
    raise exception 'MARCADORES_CATALOGO_INVALIDOS';
  end if;
  prefix:=btrim(split_part(v,a,1),E' \t\r\n'); suffix:=btrim(split_part(v,b,2),E' \t\r\n');
  return concat_ws(E'\n',nullif(prefix,''),nullif(suffix,''));
end $$;

create function public.finish_installed_catalog_sync(job_id uuid, token uuid, plan jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.installed_catalog_sync_requests; item jsonb; before_value jsonb; after_value jsonb;
  actual jsonb; k text; batch uuid; changed integer:=0; v_summary jsonb;
  fields text[]:=array['url_imagem','marca','aplicacao','categoria','montadora','oem','similar','detalhes'];
begin
  select * into r from public.installed_catalog_sync_requests where id=job_id for update;
  if r.status='completed' and r.claim_token=token then return jsonb_build_object('status',r.status,'summary',r.summary); end if;
  if r.id is null or r.status<>'running' or r.claim_token is distinct from token or r.lease_until<=now() then
    raise exception 'LOTE_OU_EXECUTOR_INVALIDO';
  end if;
  if not exists(select 1 from public.profiles where id=r.requested_by and ativo and perfil='ADMIN') then
    raise exception 'SOLICITANTE_SEM_PERMISSAO';
  end if;
  if jsonb_typeof(plan) is distinct from 'object' or plan->>'source' is distinct from 'IPS_INSTALLED_CATALOG'
    or coalesce(plan->>'source_version','') !~ '^[a-f0-9]{64}$' or jsonb_typeof(plan->'changes') is distinct from 'array'
    or jsonb_array_length(plan->'changes')>10000 or jsonb_typeof(plan->'summary') is distinct from 'object' then
    raise exception 'PLANO_CATALOGO_INVALIDO';
  end if;
  if exists(select 1 from jsonb_array_elements(plan->'changes') x group by x->>'codigo' having count(*)>1) then
    raise exception 'CODIGO_DUPLICADO';
  end if;
  v_summary:=plan->'summary';
  foreach k in array array['source_products','matched','updated','unchanged','unmatched'] loop
    if coalesce(v_summary->>k,'') !~ '^[0-9]{1,6}$' then raise exception 'RESUMO_CATALOGO_INVALIDO'; end if;
  end loop;
  if (v_summary->>'matched')::integer+(v_summary->>'unmatched')::integer<>(v_summary->>'source_products')::integer
    or (v_summary->>'unchanged')::integer+(v_summary->>'updated')::integer<>(v_summary->>'matched')::integer then
    raise exception 'RESUMO_CATALOGO_DIVERGENTE';
  end if;
  insert into public.catalog_metadata_sync_batches(source,source_version,total_received,summary)
    values('IPS_INSTALLED_CATALOG',(plan->>'source_version')||':'||job_id::text,
      (v_summary->>'source_products')::integer,v_summary) returning id into batch;
  for item in select x from jsonb_array_elements(plan->'changes') x order by x->>'codigo' loop
    before_value:=item->'before'; after_value:=item->'after';
    if jsonb_typeof(before_value) is distinct from 'object' or jsonb_typeof(after_value) is distinct from 'object'
      or not (before_value ?& fields) or not (after_value ?& fields)
      or exists(select 1 from jsonb_object_keys(before_value) t where not(t=any(fields)))
      or exists(select 1 from jsonb_object_keys(after_value) t where not(t=any(fields))) then raise exception 'CAMPOS_CATALOGO_INVALIDOS'; end if;
    select jsonb_build_object('url_imagem',p.url_imagem,'marca',p.marca,'aplicacao',p.aplicacao,'categoria',p.categoria,
      'montadora',p.montadora,'oem',p.oem,'similar',p.similar,'detalhes',p.detalhes) into actual
      from public.products p where p.codigo=item->>'codigo' for update;
    if actual is null or actual is distinct from before_value then raise exception 'PRODUTO_ALTERADO_REVALIDAR'; end if;
    if exists(select 1 from public.product_catalog_metadata m where m.product_code=item->>'codigo' and (
      (nullif(btrim(m.line_name),'') is not null and before_value->'categoria' is distinct from after_value->'categoria') or
      (nullif(btrim(m.applications),'') is not null and before_value->'aplicacao' is distinct from after_value->'aplicacao')
    )) then raise exception 'CATALOGO_OFICIAL_ALTERADO_REVALIDAR'; end if;
    foreach k in array fields loop
      if jsonb_typeof(after_value->k) not in ('string','null') or length(coalesce(after_value->>k,''))>64000 then raise exception 'VALOR_CATALOGO_INVALIDO'; end if;
      if k<>'detalhes' and nullif(btrim(before_value->>k),'') is not null and before_value->k is distinct from after_value->k then
        raise exception 'CAMPO_PREENCHIDO_PROTEGIDO';
      end if;
    end loop;
    if after_value->'url_imagem' is distinct from before_value->'url_imagem' and
      coalesce(after_value->>'url_imagem','') !~ '^https://pub-1c42f71f3a974244953a13b83a68b545[.]r2[.]dev/[^?#]+[.](png|jpg|jpeg|webp)$' then
      raise exception 'ORIGEM_IMAGEM_INVALIDA';
    end if;
    if public.installed_catalog_manual_notes(before_value->>'detalhes') is distinct from public.installed_catalog_manual_notes(after_value->>'detalhes')
      or strpos(coalesce(after_value->>'detalhes',''),'[CATALOGO_IPS_INSTALADO]')=0 then raise exception 'NOTAS_MANUAIS_PROTEGIDAS'; end if;
    if before_value is distinct from after_value then
      update public.products set url_imagem=after_value->>'url_imagem',marca=after_value->>'marca',aplicacao=after_value->>'aplicacao',
        categoria=after_value->>'categoria',montadora=after_value->>'montadora',oem=after_value->>'oem',"similar"=after_value->>'similar',detalhes=after_value->>'detalhes'
        where codigo=item->>'codigo';
      insert into public.product_catalog_metadata_audit(batch_id,product_code,action,before_data,after_data)
        values(batch,item->>'codigo','update',jsonb_build_object('target_table','products','fields',before_value),jsonb_build_object('target_table','products','fields',after_value));
      changed:=changed+1;
    end if;
  end loop;
  if changed<>(v_summary->>'updated')::integer then raise exception 'RESUMO_CATALOGO_DIVERGENTE'; end if;
  update public.catalog_metadata_sync_batches set status='completed',finished_at=now(),matched_products=(v_summary->>'matched')::integer,
    updated_rows=changed,unchanged_rows=(v_summary->>'unchanged')::integer,ignored_rows=(v_summary->>'unmatched')::integer where id=batch;
  update public.installed_catalog_sync_requests set status='completed',finished_at=now(),batch_id=batch,summary=plan->'summary' where id=job_id;
  insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_novos)
    values(r.requested_by,(select usuario from public.profiles where id=r.requested_by),'SINCRONIZAR_CATALOGO_IPS',
      'catalog_metadata_sync_batches',batch::text,jsonb_build_object('request_id',job_id,'summary',v_summary));
  return jsonb_build_object('status','completed','batch_id',batch,'summary',v_summary);
end $$;

create function public.fail_installed_catalog_sync(job_id uuid, token uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.installed_catalog_sync_requests;
begin
  update public.installed_catalog_sync_requests set status='failed',finished_at=now(),error_code='FALHA_EXECUTOR_LOCAL'
    where id=job_id and claim_token=token and status='running' returning * into r;
  if r.id is not null then
    insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_novos)
      values(r.requested_by,(select usuario from public.profiles where id=r.requested_by),'FALHA_CATALOGO_IPS',
        'installed_catalog_sync_requests',job_id::text,jsonb_build_object('error_code',r.error_code));
  end if;
end $$;

revoke all on function public.request_installed_catalog_sync(), public.list_installed_catalog_sync(),
  public.claim_installed_catalog_sync(),public.snapshot_installed_catalog_sync(uuid,uuid,text),
  public.installed_catalog_manual_notes(text),public.finish_installed_catalog_sync(uuid,uuid,jsonb),
  public.fail_installed_catalog_sync(uuid,uuid) from public,anon,authenticated;
grant execute on function public.request_installed_catalog_sync(),public.list_installed_catalog_sync() to authenticated;
grant execute on function public.claim_installed_catalog_sync(),public.snapshot_installed_catalog_sync(uuid,uuid,text),
  public.finish_installed_catalog_sync(uuid,uuid,jsonb),public.fail_installed_catalog_sync(uuid,uuid) to ips_catalog_worker;
notify pgrst,'reload schema';
commit;
