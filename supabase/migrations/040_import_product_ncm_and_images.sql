begin;

create or replace function public.commit_products_import_batch_v0_impl(batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_usuario text;
  batch_row public.products_import_batches;
  stage_row public.products_import_stage;
  before_json jsonb;
  after_json jsonb;
  action_text text;
  product_data jsonb;
  audit_field text;
  audit_new_value jsonb;
  audit_old_value jsonb;
begin
  select p.id, p.usuario
  into v_user_id, v_usuario
  from public.profiles p
  where p.id = auth.uid()
    and p.ativo = true;

  if v_user_id is null or not public.can_approve_products_import() then
    raise exception 'SEM_PERMISSAO_APROVAR_IMPORTACAO';
  end if;

  select
    b.id, b.created_at, b.created_by, b.import_type, b.source_name, b.file_hash,
    b.total_rows, b.valid_rows, b.invalid_rows, b.warning_count, b.error_count,
    b.status, b.summary, b.region, b.approved_at, b.approved_by, b.imported_at, b.failed_at
  into batch_row
  from public.products_import_batches b
  where b.id = commit_products_import_batch_v0_impl.batch_id
  for update;

  if batch_row.id is null then
    raise exception 'LOTE_NAO_ENCONTRADO';
  end if;

  if batch_row.status in ('committed', 'imported') then
    raise exception 'LOTE_JA_IMPORTADO';
  end if;

  if batch_row.error_count > 0 or batch_row.status = 'failed' then
    raise exception 'IMPORTACAO_BLOQUEADA_COM_ERROS';
  end if;

  if batch_row.status = 'validated' then
    update public.products_import_batches b
    set status = 'approved',
        approved_at = now(),
        approved_by = v_usuario
    where b.id = commit_products_import_batch_v0_impl.batch_id;
  elsif batch_row.status <> 'approved' then
    raise exception 'IMPORTACAO_NAO_APROVADA';
  end if;

  for stage_row in
    select
      s.id, s.batch_id, s.row_number, s.codigo, s.descricao_base, s.marca, s.grupo,
      s.montadora, s.modelo, s.aplicacao_texto, s.preco_sp, s.preco_pr, s.estoque_sp,
      s.estoque_pr, s.raw_data, s.normalized_data, s.status, s.errors, s.warnings
    from public.products_import_stage s
    where s.batch_id = commit_products_import_batch_v0_impl.batch_id
      and s.status <> 'error'
    order by s.row_number
  loop
    product_data := stage_row.normalized_data;
    select to_jsonb(p)
    into before_json
    from public.products p
    where p.codigo = stage_row.codigo;

    action_text := case when before_json is null then 'insert' else 'update' end;

    insert into public.products (
      codigo, descricao, marca, aplicacao, ano, ncm, ipi, preco_sem_imposto, estoque,
      estoque_quantidade, preco_sp, preco_pr, status_estoque, status_cadastro,
      url_imagem, grupo, categoria, montadora, detalhes, oem, "similar"
    )
    values (
      stage_row.codigo,
      nullif(product_data->>'descricao', ''),
      nullif(product_data->>'marca', ''),
      nullif(product_data->>'aplicacao', ''),
      nullif(product_data->>'ano', ''),
      public.normalize_ncm(product_data->>'ncm'),
      coalesce((product_data->>'ipi')::numeric, 0),
      coalesce((product_data->>'preco_sem_imposto')::numeric, 0),
      nullif(product_data->>'estoque', ''),
      coalesce((product_data->>'estoque_quantidade')::numeric, 0),
      coalesce((product_data->>'preco_sp')::numeric, 0),
      coalesce((product_data->>'preco_pr')::numeric, 0),
      nullif(product_data->>'status_estoque', ''),
      nullif(product_data->>'status_cadastro', ''),
      nullif(product_data->>'url_imagem', ''),
      nullif(product_data->>'grupo', ''),
      nullif(product_data->>'categoria', ''),
      nullif(product_data->>'montadora', ''),
      nullif(product_data->>'detalhes', ''),
      nullif(product_data->>'oem', ''),
      nullif(product_data->>'similar', '')
    )
    on conflict (codigo) do update set
      descricao = coalesce(excluded.descricao, public.products.descricao),
      marca = coalesce(excluded.marca, public.products.marca),
      aplicacao = coalesce(excluded.aplicacao, public.products.aplicacao),
      ano = coalesce(excluded.ano, public.products.ano),
      ncm = case when product_data ? 'ncm' then excluded.ncm else public.products.ncm end,
      ipi = case when product_data ? 'ipi' then excluded.ipi else public.products.ipi end,
      preco_sem_imposto = case when product_data ? 'preco_sem_imposto' then excluded.preco_sem_imposto else public.products.preco_sem_imposto end,
      estoque = coalesce(excluded.estoque, public.products.estoque),
      estoque_quantidade = case when product_data ? 'estoque_quantidade' then excluded.estoque_quantidade else public.products.estoque_quantidade end,
      preco_sp = case when product_data ? 'preco_sp' then excluded.preco_sp else public.products.preco_sp end,
      preco_pr = case when product_data ? 'preco_pr' then excluded.preco_pr else public.products.preco_pr end,
      status_estoque = coalesce(excluded.status_estoque, public.products.status_estoque),
      status_cadastro = coalesce(excluded.status_cadastro, public.products.status_cadastro),
      url_imagem = coalesce(excluded.url_imagem, public.products.url_imagem),
      grupo = coalesce(excluded.grupo, public.products.grupo),
      categoria = coalesce(excluded.categoria, public.products.categoria),
      montadora = coalesce(excluded.montadora, public.products.montadora),
      detalhes = coalesce(excluded.detalhes, public.products.detalhes),
      oem = coalesce(excluded.oem, public.products.oem),
      "similar" = coalesce(excluded."similar", public.products."similar"),
      updated_at = now();

    select to_jsonb(p)
    into after_json
    from public.products p
    where p.codigo = stage_row.codigo;

    for audit_field, audit_new_value in
      select key, value
      from jsonb_each(product_data)
      where key <> 'codigo'
    loop
      audit_old_value := case when before_json is null then null else before_json -> audit_field end;
      if before_json is null or audit_old_value is distinct from audit_new_value then
        insert into public.products_import_audit (
          batch_id, codigo, action, field_name, old_value, new_value, before_data, after_data, created_by
        )
        values (
          commit_products_import_batch_v0_impl.batch_id,
          stage_row.codigo,
          action_text,
          audit_field,
          audit_old_value,
          audit_new_value,
          before_json,
          after_json,
          v_usuario
        );
      end if;
    end loop;
  end loop;

  update public.products_import_batches b
  set status = 'imported',
      imported_at = now(),
      summary = b.summary || jsonb_build_object('status', 'imported', 'importedAt', now())
  where b.id = commit_products_import_batch_v0_impl.batch_id;

  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (
    v_user_id,
    v_usuario,
    'IMPORTAR_PRODUTOS',
    'products_import_batches',
    commit_products_import_batch_v0_impl.batch_id::text,
    jsonb_build_object('summary', batch_row.summary, 'source_name', batch_row.source_name, 'region', batch_row.region)
  );

  return public.preview_products_import_batch(commit_products_import_batch_v0_impl.batch_id);
end;
$$;

grant execute on function public.commit_products_import_batch_v0_impl(uuid) to authenticated;

create or replace function public.create_products_import_batch(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_batch_id uuid;
  v_profile_id uuid;
  v_profile_user text;
  v_pr uuid;
  v_sp uuid;
  v_inferred_branch_id uuid;
begin
  v_result := public.create_products_import_batch_v0_impl(payload);
  v_batch_id := nullif(v_result->>'batch_id', '')::uuid;

  select p.id, p.usuario
  into v_profile_id, v_profile_user
  from public.profiles p
  where p.id = auth.uid()
    and p.ativo;

  if v_batch_id is not null then
    update public.products_import_stage s
    set normalized_data = jsonb_strip_nulls(
      s.normalized_data || jsonb_build_object('ncm', public.normalize_ncm(coalesce(s.raw_data->>'ncm', s.raw_data->>'NCM')))
    )
    where s.batch_id = v_batch_id
      and public.normalize_ncm(coalesce(s.raw_data->>'ncm', s.raw_data->>'NCM')) is not null;
  end if;

  if v_batch_id is not null and v_profile_id is not null then
    select pr_branch_id, sp_branch_id
    into v_pr, v_sp
    from public.resolve_branch_import_initial_branches();

    select case upper(btrim(coalesce(b.region, '')))
      when 'PR' then v_pr
      when 'SP' then v_sp
      else null
    end
    into v_inferred_branch_id
    from public.products_import_batches b
    where b.id = v_batch_id
      and b.contract_version = 0
      and b.created_by is not distinct from v_profile_user;

    update public.products_import_batches b
    set
      created_by_profile_id = coalesce(b.created_by_profile_id, v_profile_id),
      branch_id = case
        when b.branch_id is not null then b.branch_id
        when v_inferred_branch_id is not null
          and public.can_access_branch(v_inferred_branch_id)
        then v_inferred_branch_id
        else null
      end
    where b.id = v_batch_id
      and b.contract_version = 0
      and b.created_by is not distinct from v_profile_user;
  end if;

  if v_batch_id is not null then
    return public.preview_products_import_batch(v_batch_id);
  end if;

  return v_result;
end;
$$;

grant execute on function public.create_products_import_batch(jsonb) to authenticated;

commit;
