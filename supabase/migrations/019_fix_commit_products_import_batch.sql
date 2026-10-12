create or replace function public.commit_products_import_batch(batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  session_profile public.profiles;
  batch_row public.products_import_batches;
  stage_row public.products_import_stage;
  before_json jsonb;
  action_text text;
  product_data jsonb;
begin
  select * into session_profile
  from public.profiles
  where id = auth.uid() and ativo = true;

  if session_profile.id is null or not (public.has_module('alimentacao') or public.is_admin()) then
    raise exception 'SEM_PERMISSAO';
  end if;

  select * into batch_row
  from public.products_import_batches b
  where b.id = commit_products_import_batch.batch_id
  for update;

  if batch_row.id is null then
    raise exception 'LOTE_NAO_ENCONTRADO';
  end if;

  if batch_row.status = 'committed' then
    raise exception 'LOTE_JA_IMPORTADO';
  end if;

  if batch_row.error_count > 0 then
    raise exception 'IMPORTACAO_BLOQUEADA_COM_ERROS';
  end if;

  for stage_row in
    select *
    from public.products_import_stage s
    where s.batch_id = commit_products_import_batch.batch_id
    order by s.row_number
  loop
    product_data := stage_row.normalized_data;
    select to_jsonb(p) into before_json
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

    insert into public.products_import_audit (
      batch_id, codigo, action, before_data, after_data
    )
    values (
      commit_products_import_batch.batch_id, stage_row.codigo, action_text, before_json, product_data
    );
  end loop;

  update public.products_import_batches b
  set status = 'committed'
  where b.id = commit_products_import_batch.batch_id;

  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (
    session_profile.id,
    session_profile.usuario,
    'IMPORTAR_PRODUTOS',
    'products_import_batches',
    commit_products_import_batch.batch_id::text,
    jsonb_build_object('summary', batch_row.summary, 'source_name', batch_row.source_name)
  );

  return public.preview_products_import_batch(commit_products_import_batch.batch_id);
end;
$$;

grant execute on function public.commit_products_import_batch(uuid) to authenticated;
