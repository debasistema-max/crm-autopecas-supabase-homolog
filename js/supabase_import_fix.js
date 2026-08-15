async function supabaseImportProducts(payload) {
  const plan = await supabasePreviewImportProducts(payload);
  const mapped = (plan.productsUnique || []).map((product) => (
    typeof filterProductFields === 'function' ? filterProductFields(product) : product
  ));
  if (!mapped.length) throw new Error('Nenhum produto valido encontrado para importar.');

  const session = getStoredSession() || {};
  let novos = 0;
  let atualizados = 0;
  const codes = mapped.map((product) => product.codigo);
  for (const chunk of chunkArray(codes, 500)) {
    const { data, error } = await supabaseClient
      .from('products')
      .select('codigo')
      .in('codigo', chunk);
    if (error) throw error;
    const existing = new Set((data || []).map((item) => item.codigo));
    chunk.forEach((code) => {
      if (existing.has(code)) atualizados += 1;
      else novos += 1;
    });
  }

  const chunks = chunkArray(mapped, 300);
  for (let index = 0; index < chunks.length; index += 1) {
    const { error } = await supabaseClient
      .from('products')
      .upsert(chunks[index], { onConflict: 'codigo', defaultToNull: false });
    if (error) throw error;
    if (typeof payload.onProgress === 'function') {
      payload.onProgress({
        done: Math.min((index + 1) * 300, mapped.length),
        total: mapped.length,
        batch: index + 1,
        batches: chunks.length
      });
    }
  }

  const batch = {
    usuario: session.usuario || null,
    tipo: plan.tipo,
    total_recebido: plan.totalRows,
    novos,
    atualizados,
    sem_alteracao: plan.duplicates,
    erros: plan.invalidRows.length,
    status: 'APLICADO'
  };
  await supabaseClient.from('import_batches').insert(batch);
  await supabaseLog('IMPORTAR_PRODUTOS', 'products', plan.tipo, {
    data_hora: new Date().toISOString(),
    usuario: session.usuario || null,
    nome_arquivo: payload.fileName || null,
    linhas_validas: plan.validRows,
    produtos_unicos: plan.uniqueRows,
    codigos_duplicados: plan.duplicateCodes || [],
    campos_atualizados: plan.fieldsUpdated || [],
    status: 'sucesso',
    resumo: batch
  });
  return { summary: batch, preview: plan.preview };
}
