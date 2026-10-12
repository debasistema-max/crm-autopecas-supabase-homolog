create or replace function public.import_products_transactional(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  session_profile public.profiles;
  product_data jsonb;
  import_type text := coalesce(payload->>'tipo', 'CATALOGO_PESQUISA');
  products jsonb := coalesce(payload->'products', '[]'::jsonb);
  total_rows integer := jsonb_array_length(coalesce(payload->'products', '[]'::jsonb));
  new_count integer := 0;
  updated_count integer := 0;
  code_text text;
  batch_id uuid;
begin
  select * into session_profile from public.profiles where id = auth.uid() and ativo = true;
  if session_profile.id is null or not (public.has_module('alimentacao') or public.is_admin()) then
    raise exception 'SEM_PERMISSAO';
  end if;

  if total_rows = 0 then
    raise exception 'IMPORTACAO_SEM_PRODUTOS';
  end if;

  for product_data in select * from jsonb_array_elements(products)
  loop
    code_text := nullif(trim(product_data->>'codigo'), '');
    if code_text is null then
      raise exception 'CODIGO_OBRIGATORIO';
    end if;
    if import_type = 'PRECO_SP' and not (product_data ? 'preco_sp') then
      raise exception 'PRECO_SP_OBRIGATORIO';
    end if;
    if import_type = 'PRECO_PR' and not (product_data ? 'preco_pr') then
      raise exception 'PRECO_PR_OBRIGATORIO';
    end if;

    if exists (select 1 from public.products where codigo = code_text) then
      updated_count := updated_count + 1;
    else
      new_count := new_count + 1;
    end if;

    insert into public.products (
      codigo, descricao, marca, aplicacao, ano, ipi, preco_sem_imposto, estoque,
      estoque_quantidade, preco_sp, preco_pr, status_estoque, status_cadastro,
      url_imagem, grupo, categoria, montadora, detalhes, oem, "similar"
    )
    values (
      code_text,
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
  end loop;

  insert into public.import_batches (
    usuario, tipo, total_recebido, novos, atualizados, sem_alteracao, erros, status
  )
  values (
    session_profile.usuario,
    import_type,
    coalesce((payload->>'total_recebido')::integer, total_rows),
    new_count,
    updated_count,
    coalesce((payload->>'duplicados')::integer, 0),
    coalesce((payload->>'erros')::integer, 0),
    'APLICADO'
  )
  returning id into batch_id;

  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (
    session_profile.id,
    session_profile.usuario,
    'IMPORTAR_PRODUTOS',
    'products',
    batch_id::text,
    jsonb_build_object(
      'tipo', import_type,
      'produtos_unicos', total_rows,
      'novos', new_count,
      'atualizados', updated_count,
      'batch_id', batch_id,
      'nome_arquivo', payload->>'fileName'
    )
  );

  return jsonb_build_object(
    'id', batch_id,
    'usuario', session_profile.usuario,
    'tipo', import_type,
    'total_recebido', coalesce((payload->>'total_recebido')::integer, total_rows),
    'novos', new_count,
    'atualizados', updated_count,
    'sem_alteracao', coalesce((payload->>'duplicados')::integer, 0),
    'erros', coalesce((payload->>'erros')::integer, 0),
    'status', 'APLICADO'
  );
end;
$$;

grant execute on function public.import_products_transactional(jsonb) to authenticated;
