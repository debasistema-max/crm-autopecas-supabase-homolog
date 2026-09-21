const DATA_SYNC_STATUS_LABELS = {
  pending: 'Pendente', processing: 'Processando', completed: 'Concluído',
  completed_with_errors: 'Concluído com erros', failed: 'Falhou'
};

const dataSyncUiState = { status: null, batches: [], activePanel: 'history' };

async function renderDataSyncCenter(container) {
  container.innerHTML = `
    <div class="module-page data-sync-workspace">
      ${CrmUi.renderPageHeader(
        'Central de Dados',
        'Acompanhe a integração do Excel mestre sem tornar o CRM dependente do arquivo de origem.',
        '',
        'Operação'
      )}
      <section class="panel data-sync-status-panel" aria-labelledby="dataSyncStatusTitle">
        <div class="section-heading">
          <div><h3 id="dataSyncStatusTitle">Status da integração</h3><p>O CRM continua usando a última versão válida salva no Supabase.</p></div>
          <button class="btn btn-ghost" id="dataSyncRefresh" type="button">Atualizar</button>
        </div>
        <div id="dataSyncStatusContent">${CrmUi.renderState('loading', 'Consultando sincronização', 'Carregando a última execução e o estado do adapter.')}</div>
      </section>
      <section class="panel data-sync-actions-panel" aria-labelledby="dataSyncActionsTitle">
        <div class="section-heading"><div><h3 id="dataSyncActionsTitle">Ações</h3><p>A execução ocorre no backend; nenhuma credencial é enviada ao navegador.</p></div></div>
        <div class="actions-row data-sync-actions">
          <button class="btn btn-primary" id="dataSyncNow" type="button">Sincronizar agora</button>
          <button class="btn btn-secondary" id="dataSyncDetails" type="button">Visualizar detalhes</button>
          <button class="btn btn-secondary" id="dataSyncErrors" type="button">Visualizar erros</button>
          <button class="btn btn-secondary" id="dataSyncHistory" type="button">Visualizar histórico</button>
        </div>
        <p class="form-message" id="dataSyncMessage" role="status" aria-live="polite"></p>
      </section>
      <section class="panel data-sync-result-panel" id="dataSyncResult" aria-live="polite">
        ${CrmUi.renderState('loading', 'Carregando histórico', 'Consultando os lotes mais recentes.')}
      </section>
    </div>`;
  document.getElementById('dataSyncRefresh').addEventListener('click', loadDataSyncOverview);
  document.getElementById('dataSyncNow').addEventListener('click', triggerDataSyncFromUi);
  document.getElementById('dataSyncDetails').addEventListener('click', () => renderDataSyncPanel('details'));
  document.getElementById('dataSyncErrors').addEventListener('click', () => renderDataSyncPanel('errors'));
  document.getElementById('dataSyncHistory').addEventListener('click', () => renderDataSyncPanel('history'));
  await loadDataSyncOverview();
}

async function loadDataSyncOverview() {
  const statusTarget = document.getElementById('dataSyncStatusContent');
  const resultTarget = document.getElementById('dataSyncResult');
  if (!statusTarget || !resultTarget) return;
  statusTarget.innerHTML = CrmUi.renderState('loading', 'Consultando sincronização', 'Carregando a última execução e o estado do adapter.');
  try {
    const [status, history] = await Promise.all([
      supabaseGetDataSyncStatus({ source: 'EXCEL_API' }),
      supabaseListDataSyncBatches({ source: 'EXCEL_API', limit: 100 })
    ]);
    dataSyncUiState.status = status;
    dataSyncUiState.batches = history.rows || [];
    statusTarget.innerHTML = renderDataSyncStatus(status);
    await renderDataSyncPanel(dataSyncUiState.activePanel);
  } catch (error) {
    statusTarget.innerHTML = CrmUi.renderState('error', 'Status indisponível', error.message || 'Não foi possível consultar a integração.');
    resultTarget.innerHTML = CrmUi.renderState('error', 'Dados indisponíveis', 'A última versão válida do CRM não foi alterada.');
  }
}

function renderDataSyncStatus(status) {
  const source = status.source || {};
  const batch = status.last_batch || {};
  const summary = batch.summary || {};
  const connected = status.connected === true;
  const degraded = source.connection_status === 'DEGRADED';
  const connectionClass = connected ? 'is-online' : (degraded ? 'is-warning' : 'is-offline');
  const connectionLabel = connected ? 'Conectado' : (degraded ? 'Com alertas' : 'Indisponível');
  return `
    <div class="data-sync-health">
      <article><span>Excel/API</span><strong><i class="data-sync-dot ${connectionClass}"></i>${connectionLabel}</strong><small>${escapeHtml(source.connection_status || 'UNKNOWN')}</small></article>
      <article><span>Última sincronização</span><strong>${batch.finished_at ? escapeHtml(formatDataSyncDateTime(batch.finished_at)) : 'Ainda não executada'}</strong><small>${batch.source_updated_at ? `Origem: ${escapeHtml(formatDataSyncDateTime(batch.source_updated_at))}` : 'Sem versão recebida'}</small></article>
      <article><span>Duração</span><strong>${formatDataSyncDuration(batch.duration_seconds)}</strong><small>${batch.started_at ? `Início: ${escapeHtml(formatDataSyncDateTime(batch.started_at))}` : '—'}</small></article>
      <article><span>Último lote</span><strong>${batch.id ? escapeHtml(shortDataSyncId(batch.id)) : '—'}</strong><small>${escapeHtml(DATA_SYNC_STATUS_LABELS[batch.status] || batch.status || 'Sem status')}</small></article>
      <article><span>Próxima sincronização</span><strong>${source.next_sync_at ? escapeHtml(formatDataSyncDateTime(source.next_sync_at)) : 'Não agendada'}</strong><small>${escapeHtml(source.adapter_type || 'HTTP_ADAPTER')}</small></article>
    </div>
    <div class="data-sync-counters" aria-label="Contadores do último lote">
      ${dataSyncCounter('Produtos analisados', summary.products_analyzed)}
      ${dataSyncCounter('Produtos novos', summary.products_inserted)}
      ${dataSyncCounter('Registros alterados', batch.updated_rows)}
      ${dataSyncCounter('Preços alterados', summary.prices_changed)}
      ${dataSyncCounter('Estoques alterados', summary.stocks_changed)}
      ${dataSyncCounter('Cadastros alterados', summary.products_changed)}
      ${dataSyncCounter('Dados fiscais alterados', summary.fiscal_results_changed)}
      ${dataSyncCounter('Sem alteração', batch.unchanged_rows)}
      ${dataSyncCounter('Ignorados', batch.ignored_rows)}
      ${dataSyncCounter('Erros', batch.error_count, Number(batch.error_count || 0) > 0)}
    </div>`;
}

function dataSyncCounter(label, value, danger = false) {
  return `<article class="${danger ? 'has-errors' : ''}"><strong>${Number(value || 0).toLocaleString('pt-BR')}</strong><span>${escapeHtml(label)}</span></article>`;
}

async function triggerDataSyncFromUi() {
  const button = document.getElementById('dataSyncNow');
  const message = document.getElementById('dataSyncMessage');
  button.disabled = true;
  message.textContent = 'Sincronização iniciada. O arquivo será lido e validado no backend.';
  try {
    const result = await supabaseTriggerDataSync();
    if (result.queued) {
      message.textContent = 'Atualização colocada na fila. O processamento ocorre em segundo plano e costuma levar cerca de 3 minutos.';
      scheduleDataSyncRefreshes();
      return;
    }
    const batch = result.batch || {};
    message.textContent = result.duplicate
      ? `A versão já foi processada no lote ${shortDataSyncId(batch.id)}.`
      : `Sincronização ${DATA_SYNC_STATUS_LABELS[batch.status] || batch.status || 'concluída'}. Lote ${shortDataSyncId(batch.id)}.`;
    await loadDataSyncOverview();
  } catch (error) {
    message.textContent = `${error.message || 'Não foi possível sincronizar'} A última versão válida permanece disponível no CRM.`;
  } finally {
    button.disabled = false;
  }
}

function scheduleDataSyncRefreshes() {
  [15000, 45000, 90000, 150000].forEach((delay) => {
    setTimeout(() => {
      if (document.getElementById('dataSyncStatusContent')) loadDataSyncOverview();
    }, delay);
  });
}

async function renderDataSyncPanel(panel) {
  dataSyncUiState.activePanel = panel;
  const target = document.getElementById('dataSyncResult');
  if (!target) return;
  document.querySelectorAll('.data-sync-actions .btn-secondary').forEach((button) => button.classList.remove('is-selected'));
  const selected = { details: 'dataSyncDetails', errors: 'dataSyncErrors', history: 'dataSyncHistory' }[panel];
  document.getElementById(selected)?.classList.add('is-selected');
  if (panel === 'details') return renderDataSyncAudit(target);
  if (panel === 'errors') return renderDataSyncErrors(target);
  return renderDataSyncHistory(target);
}

function renderDataSyncHistory(target) {
  const rows = dataSyncUiState.batches || [];
  target.innerHTML = `<div class="section-heading"><div><h3>Histórico de sincronizações</h3><p>Versão, origem, contadores e resultado de cada lote automático.</p></div></div>
    ${rows.length ? `<div class="table-wrap data-sync-table-wrap"><table><thead><tr><th>Data</th><th>Lote</th><th>Origem</th><th>Versão</th><th>Lidas</th><th>Novas</th><th>Alteradas</th><th>Ignoradas</th><th>Erros</th><th>Status</th></tr></thead><tbody>
      ${rows.map((row) => `<tr><td>${escapeHtml(formatDataSyncDateTime(row.created_at))}</td><td>${escapeHtml(shortDataSyncId(row.id))}</td><td>${escapeHtml(row.integration_source)}</td><td title="${escapeHtml(row.source_version)}">${escapeHtml(shortDataSyncId(row.source_version))}</td><td>${row.total_rows || 0}</td><td>${row.inserted_rows || 0}</td><td>${row.updated_rows || 0}</td><td>${row.ignored_rows || 0}</td><td>${row.error_count || 0}</td><td><span class="status-pill data-sync-status-${escapeHtml(row.status)}">${escapeHtml(DATA_SYNC_STATUS_LABELS[row.status] || row.status)}</span></td></tr>`).join('')}
    </tbody></table></div>` : CrmUi.renderState('empty', 'Nenhuma sincronização', 'O primeiro lote automático aparecerá aqui.')}`;
}

async function renderDataSyncErrors(target) {
  target.innerHTML = `${renderDataSyncErrorFilters()}${CrmUi.renderState('loading', 'Carregando erros', 'Consultando linhas inválidas, antigas ou concorrentes.')}`;
  document.getElementById('dataSyncErrorFilters').addEventListener('submit', async (event) => {
    event.preventDefault();
    await loadDataSyncErrors(target, readDataSyncErrorFilters());
  });
  await loadDataSyncErrors(target, {});
}

function renderDataSyncErrorFilters() {
  const batches = dataSyncUiState.batches || [];
  return `<form class="data-sync-error-filters" id="dataSyncErrorFilters">
    <label>Lote<select id="dataSyncFilterBatch"><option value="">Todos</option>${batches.map((row) => `<option value="${escapeHtml(row.id)}">${escapeHtml(shortDataSyncId(row.id))}</option>`).join('')}</select></label>
    <label>Data inicial<input id="dataSyncFilterFrom" type="date"></label>
    <label>Área<select id="dataSyncFilterArea"><option value="">Todas</option><option>PRODUCT</option><option>STOCK</option><option>BASE_PRICE</option><option>ROUTE_PRICE</option></select></label>
    <label>Filial<select id="dataSyncFilterBranch"><option value="">Todas</option><option>PR</option><option>SP</option></select></label>
    <label>Status<select id="dataSyncFilterStatus"><option value="">Todos</option><option value="error">Erro</option><option value="warning">Aviso</option></select></label>
    <label>Produto<input id="dataSyncFilterProduct" inputmode="numeric" placeholder="Código IPS"></label>
    <button class="btn btn-secondary" type="submit">Filtrar</button>
  </form><div id="dataSyncErrorRows"></div>`;
}

function readDataSyncErrorFilters() {
  return {
    batch_id: document.getElementById('dataSyncFilterBatch').value,
    from: document.getElementById('dataSyncFilterFrom').value,
    area: document.getElementById('dataSyncFilterArea').value,
    branch: document.getElementById('dataSyncFilterBranch').value,
    status: document.getElementById('dataSyncFilterStatus').value,
    product_code: document.getElementById('dataSyncFilterProduct').value.trim(),
    limit: 500
  };
}

async function loadDataSyncErrors(target, filters) {
  const rowsTarget = document.getElementById('dataSyncErrorRows') || target;
  rowsTarget.innerHTML = CrmUi.renderState('loading', 'Carregando erros', 'Consultando o relatório do lote.');
  try {
    const result = await supabaseListDataSyncErrors(filters);
    const rows = result.rows || [];
    rowsTarget.innerHTML = rows.length ? `<div class="table-wrap data-sync-table-wrap"><table><thead><tr><th>Código</th><th>Área</th><th>Filial/rota</th><th>Problema</th><th>Valor recebido</th><th>Ação</th></tr></thead><tbody>
      ${rows.map((row) => `<tr><td>${escapeHtml(row.product_code || '—')}</td><td>${escapeHtml(row.area || '—')}</td><td>${escapeHtml(row.route || row.branch_code || '—')}</td><td>${escapeHtml([...(row.errors || []), ...(row.warnings || [])].join(', ') || row.skip_reason || '—')}</td><td><pre class="data-sync-json">${escapeHtml(JSON.stringify(row.normalized_data || row.raw_data || {}, null, 2))}</pre></td><td>${escapeHtml(dataSyncErrorAction(row))}</td></tr>`).join('')}
    </tbody></table></div>` : CrmUi.renderState('success', 'Nenhum erro encontrado', 'Os filtros atuais não retornaram linhas rejeitadas.');
  } catch (error) {
    rowsTarget.innerHTML = CrmUi.renderState('error', 'Não foi possível carregar os erros', error.message);
  }
}

function dataSyncErrorAction(row) {
  if (row.skip_reason === 'STALE_SOURCE_EVENT') return 'Ignorado: versão mais nova preservada';
  if (row.skip_reason === 'CONCURRENT_MODIFICATION') return 'Ignorado: alteração concorrente preservada';
  return 'Ignorado';
}

async function renderDataSyncAudit(target) {
  target.innerHTML = CrmUi.renderState('loading', 'Carregando detalhes', 'Consultando as alterações campo a campo.');
  try {
    const result = await supabaseListDataSyncAudit({ limit: 500 });
    const rows = result.rows || [];
    target.innerHTML = `<div class="section-heading"><div><h3>Detalhes das alterações</h3><p>Valor anterior e novo, origem, filial/rota e responsável.</p></div></div>
      ${rows.length ? `<div class="table-wrap data-sync-table-wrap"><table><thead><tr><th>Data</th><th>Produto</th><th>Área</th><th>Campo</th><th>Antes</th><th>Depois</th><th>Filial/rota</th><th>Origem</th><th>Responsável</th></tr></thead><tbody>
        ${rows.map((row) => `<tr><td>${escapeHtml(formatDataSyncDateTime(row.created_at))}</td><td>${escapeHtml(row.product_code)}</td><td>${escapeHtml(row.area)}</td><td>${escapeHtml(row.field_name)}</td><td>${escapeHtml(dataSyncValue(row.old_value))}</td><td>${escapeHtml(dataSyncValue(row.new_value))}</td><td>${escapeHtml(row.route || row.branch_code || '—')}</td><td>${escapeHtml(row.source)}</td><td>${escapeHtml(row.created_by || 'SYSTEM')}</td></tr>`).join('')}
      </tbody></table></div>` : CrmUi.renderState('empty', 'Nenhuma alteração auditada', 'Linhas sem mudança não geram escrita nem auditoria.')}`;
  } catch (error) {
    target.innerHTML = CrmUi.renderState('error', 'Não foi possível carregar os detalhes', error.message);
  }
}

function dataSyncValue(value) {
  if (value == null) return '—';
  if (typeof value === 'object') return JSON.stringify(value);
  return String(value);
}

function formatDataSyncDuration(seconds) {
  const value = Number(seconds);
  if (!Number.isFinite(value)) return '—';
  if (value < 60) return `${Math.round(value)} s`;
  return `${Math.floor(value / 60)} min ${Math.round(value % 60)} s`;
}

function formatDataSyncDateTime(value) {
  if (!value) return '—';
  const date = new Date(value);
  if (Number.isNaN(date.valueOf())) return String(value);
  return date.toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' });
}

function shortDataSyncId(value) {
  const text = String(value || '');
  return text.length > 12 ? `${text.slice(0, 8)}…${text.slice(-4)}` : text || '—';
}
