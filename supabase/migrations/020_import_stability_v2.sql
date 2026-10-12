alter table public.products_import_batches
  add column if not exists region text,
  add column if not exists approved_at timestamptz,
  add column if not exists approved_by text,
  add column if not exists imported_at timestamptz,
  add column if not exists failed_at timestamptz;

alter table public.products_import_audit
  add column if not exists field_name text,
  add column if not exists old_value jsonb,
  add column if not exists new_value jsonb,
  add column if not exists created_by text;

create index if not exists products_import_batches_status_idx
  on public.products_import_batches (status, created_at desc);

create index if not exists products_import_audit_field_idx
  on public.products_import_audit (batch_id, codigo, field_name);

insert into public.role_permissions (perfil, modulo, permitido)
values ('ADMIN', 'aprovar_importacao', true)
on conflict (perfil, modulo) do update set permitido = excluded.permitido;

create or replace function public.can_approve_products_import()
returns boolean
language sql
security definer
set search_path = public
as $$
  select public.is_admin() or public.has_module('aprovar_importacao');
$$;

create or replace function public.create_products_import_batch(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_usuario text;
  products jsonb := coalesce(payload->'products', '[]'::jsonb);
  product_data jsonb;
  v_batch_id uuid;
  v_import_type text := coalesce(payload->>'import_type', payload->>'tipo', 'CADASTRO_COMPLETO');
  v_region text := nullif(upper(trim(coalesce(payload->>'region', payload->>'filial', payload->>'estado', ''))), '');
  v_source_name text := nullif(payload->>'source_name', '');
  v_file_hash text := nullif(payload->>'file_hash', '');
  code_text text;
  descricao_text text;
  row_number integer;
  duplicate_map jsonb := '{}'::jsonb;
  errors jsonb;
  warnings jsonb;
  existing_product public.products;
  status_text text;
  old_price numeric;
  new_price numeric;
  new_stock numeric;
  total_count integer := 0;
  error_rows integer := 0;
  warning_rows integer := 0;
  warning_total integer := 0;
  new_count integer := 0;
  updated_count integer := 0;
  price_changed_count integer := 0;
  stock_changed_count integer := 0;
  description_changed_count integer := 0;
  normalized jsonb;
begin
  select p.id, p.usuario
  into v_user_id, v_usuario
  from public.profiles p
  where p.id = auth.uid()
    and p.ativo = true;

  if v_user_id is null or not (public.has_module('alimentacao') or public.is_admin()) then
    raise exception 'SEM_PERMISSAO';
  end if;

  if jsonb_array_length(products) = 0 then
    raise exception 'IMPORTACAO_SEM_PRODUTOS';
  end if;

  if v_file_hash is not null and exists (
    select 1
    from public.products_import_batches b
    where b.file_hash = v_file_hash
      and b.status in ('committed', 'imported')
  ) then
    raise exception 'ARQUIVO_JA_IMPORTADO';
  end if;

  select coalesce(jsonb_object_agg(codigo, total), '{}'::jsonb)
  into duplicate_map
  from (
    select nullif(trim(value->>'codigo'), '') as codigo, count(*) as total
    from jsonb_array_elements(products) value
    group by nullif(trim(value->>'codigo'), '')
    having nullif(trim(value->>'codigo'), '') is not null and count(*) > 1
  ) duplicated;

  insert into public.products_import_batches (
    created_by, import_type, region, source_name, file_hash, status
  )
  values (
    v_usuario, v_import_type, v_region, v_source_name, v_file_hash, 'validating'
  )
  returning id into v_batch_id;

  for product_data in select value from jsonb_array_elements(products) value
  loop
    row_number := coalesce((product_data->>'row_number')::integer, total_count + 1);
    code_text := nullif(trim(coalesce(product_data->>'codigo', '')), '');
    descricao_text := nullif(trim(coalesce(product_data->>'descricao', product_data->>'descricao_base', '')), '');
    new_price := case
      when v_import_type = 'PRECO_PR' then public.products_import_to_numeric(product_data->>'preco_pr')
      else public.products_import_to_numeric(product_data->>'preco_sp')
    end;
    new_stock := coalesce(
      public.products_import_to_numeric(product_data->>'estoque_quantidade'),
      public.products_import_to_numeric(product_data->>'estoque_sp'),
      public.products_import_to_numeric(product_data->>'estoque_pr')
    );
    errors := '[]'::jsonb;
    warnings := '[]'::jsonb;
    existing_product := null;
    total_count := total_count + 1;

    if code_text is null then
      errors := errors || jsonb_build_array('codigo vazio');
    elsif length(code_text) > 80 then
      errors := errors || jsonb_build_array('codigo com mais de 80 caracteres');
    end if;

    if v_import_type = 'CADASTRO_COMPLETO' and descricao_text is null then
      errors := errors || jsonb_build_array('descricao obrigatoria');
    end if;

    if v_import_type = 'CATALOGO_PESQUISA'
      and nullif(trim(coalesce(product_data->>'categoria', '')), '') is null
      and nullif(trim(coalesce(product_data->>'grupo', '')), '') is null
      and nullif(trim(coalesce(product_data->>'aplicacao', '')), '') is null
      and nullif(trim(coalesce(product_data->>'detalhes', '')), '') is null
      and nullif(trim(coalesce(product_data->>'similar', '')), '') is null then
      errors := errors || jsonb_build_array('catalogo sem linha, grupo, veiculos, detalhes ou similares');
    end if;

    if v_import_type = 'PRECO_SP' and coalesce(public.products_import_to_numeric(product_data->>'preco_sp'), 0) <= 0 then
      errors := errors || jsonb_build_array('preco SP obrigatorio maior que zero');
    end if;

    if v_import_type = 'PRECO_PR' and coalesce(public.products_import_to_numeric(product_data->>'preco_pr'), 0) <= 0 then
      errors := errors || jsonb_build_array('preco PR obrigatorio maior que zero');
    end if;

    if v_import_type = 'PORTAL_ESTOQUE' and new_stock is null then
      errors := errors || jsonb_build_array('estoque obrigatorio');
    elsif v_import_type <> 'PORTAL_ESTOQUE'
      and nullif(trim(coalesce(product_data->>'estoque', '')), '') is not null
      and new_stock is null then
      errors := errors || jsonb_build_array('estoque invalido');
    elsif new_stock is not null and new_stock < 0 then
      errors := errors || jsonb_build_array('estoque negativo');
    end if;

    if public.products_import_to_numeric(product_data->>'preco_sem_imposto') < 0 then
      errors := errors || jsonb_build_array('preco sem imposto negativo');
    end if;

    if code_text is not null and duplicate_map ? code_text then
      errors := errors || jsonb_build_array('codigo duplicado no arquivo');
    end if;

    if code_text is not null then
      select
        p.codigo, p.descricao, p.marca, p.aplicacao, p.ano, p.ipi, p.preco_sem_imposto,
        p.estoque, p.estoque_quantidade, p.preco_sp, p.preco_pr, p.status_estoque,
        p.status_cadastro, p.url_imagem, p.grupo, p.categoria, p.montadora, p.detalhes,
        p.oem, p."similar", p.search_text, p.search_vector, p.updated_at
      into existing_product
      from public.products p
      where p.codigo = code_text;
    end if;

    if code_text is not null and existing_product.codigo is null then
      warnings := warnings || jsonb_build_array('produto novo');
      if jsonb_array_length(errors) = 0 then
        new_count := new_count + 1;
      end if;
    elsif code_text is not null and jsonb_array_length(errors) = 0 then
      updated_count := updated_count + 1;
    end if;

    if descricao_text is not null and length(descricao_text) < 8 then
      warnings := warnings || jsonb_build_array('descricao muito curta');
    end if;

    if new_stock is not null and new_stock > 10000 then
      warnings := warnings || jsonb_build_array('estoque acima de 10000');
    end if;

    if coalesce(public.products_import_to_numeric(product_data->>'preco_sp'), 0) > 10000
      or coalesce(public.products_import_to_numeric(product_data->>'preco_pr'), 0) > 10000 then
      warnings := warnings || jsonb_build_array('preco acima de 10000');
    end if;

    if existing_product.codigo is not null and descricao_text is not null and coalesce(existing_product.descricao, '') <> descricao_text then
      warnings := warnings || jsonb_build_array('descricao alterada em produto existente');
      description_changed_count := description_changed_count + 1;
    end if;

    if existing_product.codigo is not null then
      old_price := case when v_import_type = 'PRECO_PR' then existing_product.preco_pr else existing_product.preco_sp end;
      if new_price is not null and old_price > 0 and abs(new_price - old_price) / old_price > 0.4 then
        warnings := warnings || jsonb_build_array('preco mudou mais de 40%');
        price_changed_count := price_changed_count + 1;
      end if;
      if new_stock is not null and existing_product.estoque_quantidade is distinct from new_stock then
        stock_changed_count := stock_changed_count + 1;
      end if;
    end if;

    if nullif(product_data->>'marca', '') is not null
      and not exists (select 1 from public.products p where p.marca = product_data->>'marca') then
      warnings := warnings || jsonb_build_array('marca nova');
    end if;

    if nullif(product_data->>'grupo', '') is not null
      and not exists (select 1 from public.products p where p.grupo = product_data->>'grupo') then
      warnings := warnings || jsonb_build_array('grupo novo');
    end if;

    normalized := jsonb_strip_nulls(jsonb_build_object(
      'codigo', code_text,
      'descricao', descricao_text,
      'marca', nullif(product_data->>'marca', ''),
      'aplicacao', nullif(coalesce(product_data->>'aplicacao', product_data->>'aplicacao_texto'), ''),
      'ano', nullif(product_data->>'ano', ''),
      'ipi', public.products_import_to_numeric(product_data->>'ipi'),
      'preco_sem_imposto', public.products_import_to_numeric(product_data->>'preco_sem_imposto'),
      'estoque', nullif(product_data->>'estoque', ''),
      'estoque_quantidade', new_stock,
      'preco_sp', public.products_import_to_numeric(product_data->>'preco_sp'),
      'preco_pr', public.products_import_to_numeric(product_data->>'preco_pr'),
      'status_estoque', nullif(product_data->>'status_estoque', ''),
      'status_cadastro', nullif(product_data->>'status_cadastro', ''),
      'url_imagem', nullif(product_data->>'url_imagem', ''),
      'grupo', nullif(product_data->>'grupo', ''),
      'categoria', nullif(coalesce(product_data->>'categoria', product_data->>'modelo'), ''),
      'montadora', nullif(product_data->>'montadora', ''),
      'detalhes', nullif(product_data->>'detalhes', ''),
      'oem', nullif(product_data->>'oem', ''),
      'similar', nullif(product_data->>'similar', '')
    ));

    status_text := case
      when jsonb_array_length(errors) > 0 then 'error'
      when jsonb_array_length(warnings) > 0 then 'warning'
      else 'pending'
    end;

    if status_text = 'error' then
      error_rows := error_rows + 1;
    end if;
    if jsonb_array_length(warnings) > 0 then
      warning_rows := warning_rows + 1;
      warning_total := warning_total + jsonb_array_length(warnings);
    end if;

    insert into public.products_import_stage (
      batch_id, row_number, codigo, descricao_base, marca, grupo, montadora, modelo,
      aplicacao_texto, preco_sp, preco_pr, estoque_sp, estoque_pr,
      raw_data, normalized_data, status, errors, warnings
    )
    values (
      v_batch_id,
      row_number,
      code_text,
      descricao_text,
      nullif(product_data->>'marca', ''),
      nullif(product_data->>'grupo', ''),
      nullif(product_data->>'montadora', ''),
      nullif(coalesce(product_data->>'modelo', product_data->>'categoria'), ''),
      nullif(coalesce(product_data->>'aplicacao_texto', product_data->>'aplicacao'), ''),
      public.products_import_to_numeric(product_data->>'preco_sp'),
      public.products_import_to_numeric(product_data->>'preco_pr'),
      public.products_import_to_numeric(product_data->>'estoque_sp'),
      public.products_import_to_numeric(product_data->>'estoque_pr'),
      product_data,
      normalized,
      status_text,
      errors,
      warnings
    );
  end loop;

  update public.products_import_batches b
  set
    total_rows = total_count,
    valid_rows = total_count - error_rows,
    invalid_rows = error_rows,
    warning_count = warning_total,
    error_count = error_rows,
    status = case when error_rows > 0 then 'failed' else 'validated' end,
    failed_at = case when error_rows > 0 then now() else null end,
    summary = jsonb_build_object(
      'totalRows', total_count,
      'validRows', total_count - error_rows,
      'invalidRows', error_rows,
      'ignoredCount', error_rows,
      'warningRows', warning_rows,
      'warningCount', warning_total,
      'errorCount', error_rows,
      'newCount', new_count,
      'updatedCount', updated_count,
      'priceChanged', price_changed_count,
      'stockChanged', stock_changed_count,
      'descriptionChanged', description_changed_count,
      'region', v_region
    )
  where b.id = v_batch_id;

  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (
    v_user_id,
    v_usuario,
    'VALIDAR_IMPORTACAO_PRODUTOS',
    'products_import_batches',
    v_batch_id::text,
    jsonb_build_object('import_type', v_import_type, 'region', v_region, 'source_name', v_source_name)
  );

  return public.preview_products_import_batch(v_batch_id);
end;
$$;

create or replace function public.preview_products_import_batch(batch_id uuid)
returns jsonb
language sql
security definer
set search_path = public
as $$
  with batch as (
    select
      b.id, b.import_type, b.region, b.source_name, b.file_hash, b.status,
      b.summary, b.approved_at, b.approved_by, b.imported_at
    from public.products_import_batches b
    where b.id = $1
  ),
  rows_base as (
    select
      s.id, s.batch_id, s.row_number, s.codigo, s.normalized_data, s.status, s.errors, s.warnings,
      p.codigo is not null as exists_now,
      to_jsonb(p) as before_data
    from public.products_import_stage s
    left join public.products p on p.codigo = s.codigo
    where s.batch_id = $1
  ),
  differences as (
    select jsonb_agg(jsonb_build_object(
      'row_number', row_number,
      'codigo', codigo,
      'exists_now', exists_now,
      'warnings', warnings,
      'before_data', before_data,
      'after_data', normalized_data
    ) order by row_number) as items
    from rows_base
    where exists_now = true and warnings <> '[]'::jsonb
  )
  select jsonb_build_object(
    'batch_id', b.id,
    'status', b.status,
    'summary', b.summary || jsonb_build_object(
      'batchId', b.id,
      'importType', b.import_type,
      'region', b.region,
      'sourceName', b.source_name,
      'fileHash', b.file_hash,
      'status', b.status,
      'approvedAt', b.approved_at,
      'approvedBy', b.approved_by,
      'importedAt', b.imported_at
    ),
    'errors', coalesce((
      select jsonb_agg(jsonb_build_object(
        'row_number', row_number,
        'codigo', codigo,
        'errors', errors
      ) order by row_number)
      from rows_base
      where errors <> '[]'::jsonb
      limit 100
    ), '[]'::jsonb),
    'warnings', coalesce((
      select jsonb_agg(jsonb_build_object(
        'row_number', row_number,
        'codigo', codigo,
        'warnings', warnings
      ) order by row_number)
      from rows_base
      where warnings <> '[]'::jsonb
      limit 150
    ), '[]'::jsonb),
    'differences', coalesce((select items from differences), '[]'::jsonb),
    'preview', coalesce((
      select jsonb_agg(normalized_data || jsonb_build_object(
        'row_number', row_number,
        'status', status,
        'errors', errors,
        'warnings', warnings
      ) order by row_number)
      from (
        select normalized_data, row_number, status, errors, warnings
        from rows_base
        order by row_number
        limit 20
      ) limited
    ), '[]'::jsonb)
  )
  from batch b;
$$;

create or replace function public.approve_products_import_batch(batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_usuario text;
  batch_row public.products_import_batches;
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
  where b.id = approve_products_import_batch.batch_id
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

  if batch_row.status = 'approved' then
    return public.preview_products_import_batch(approve_products_import_batch.batch_id);
  end if;

  if batch_row.status <> 'validated' then
    raise exception 'IMPORTACAO_NAO_APROVADA';
  end if;

  update public.products_import_batches b
  set status = 'approved',
      approved_at = now(),
      approved_by = v_usuario
  where b.id = approve_products_import_batch.batch_id;

  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (
    v_user_id,
    v_usuario,
    'APROVAR_IMPORTACAO_PRODUTOS',
    'products_import_batches',
    approve_products_import_batch.batch_id::text,
    jsonb_build_object('source_name', batch_row.source_name, 'region', batch_row.region)
  );

  return public.preview_products_import_batch(approve_products_import_batch.batch_id);
end;
$$;

create or replace function public.commit_products_import_batch(batch_id uuid)
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
  where b.id = commit_products_import_batch.batch_id
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
    where b.id = commit_products_import_batch.batch_id;
  elsif batch_row.status <> 'approved' then
    raise exception 'IMPORTACAO_NAO_APROVADA';
  end if;

  for stage_row in
    select
      s.id, s.batch_id, s.row_number, s.codigo, s.descricao_base, s.marca, s.grupo,
      s.montadora, s.modelo, s.aplicacao_texto, s.preco_sp, s.preco_pr, s.estoque_sp,
      s.estoque_pr, s.raw_data, s.normalized_data, s.status, s.errors, s.warnings
    from public.products_import_stage s
    where s.batch_id = commit_products_import_batch.batch_id
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
      codigo, descricao, marca, aplicacao, ano, ipi, preco_sem_imposto, estoque,
      estoque_quantidade, preco_sp, preco_pr, status_estoque, status_cadastro,
      url_imagem, grupo, categoria, montadora, detalhes, oem, "similar"
    )
    values (
      stage_row.codigo,
      nullif(product_data->>'descricao', ''),
      nullif(product_data->>'marca', ''),
      nullif(product_data->>'aplicacao', ''),
      nullif(product_data->>'ano', ''),
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
          commit_products_import_batch.batch_id,
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
  where b.id = commit_products_import_batch.batch_id;

  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (
    v_user_id,
    v_usuario,
    'IMPORTAR_PRODUTOS',
    'products_import_batches',
    commit_products_import_batch.batch_id::text,
    jsonb_build_object('summary', batch_row.summary, 'source_name', batch_row.source_name, 'region', batch_row.region)
  );

  return public.preview_products_import_batch(commit_products_import_batch.batch_id);
end;
$$;

grant execute on function public.can_approve_products_import() to authenticated;
grant execute on function public.create_products_import_batch(jsonb) to authenticated;
grant execute on function public.preview_products_import_batch(uuid) to authenticated;
grant execute on function public.approve_products_import_batch(uuid) to authenticated;
grant execute on function public.commit_products_import_batch(uuid) to authenticated;
