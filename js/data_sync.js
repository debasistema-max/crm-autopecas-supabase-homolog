const DATA_SYNC_STATUS_LABELS = {
  pending: 'Pendente', processing: 'Processando', completed: 'Concluído',
  completed_with_errors: 'Concluído com erros', failed: 'Falhou'
};

const dataSyncUiState = {
  status: null,
  batches: [],
  activePanel: 'history',
  syncRequest: null,
  pollTimer: null
};

const DATA_SYNC_TERMINAL_STATUSES = new Set(['completed', 'completed_with_errors', 'failed']);

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
        <div class="data-sync-notice" id="dataSyncMessage" role="status" aria-live="polite"></div>
      </section>
      <section class="panel data-sync-result-panel" id="dataSyncResult" aria-live="polite">
        ${CrmUi.renderState('loading', 'Carregando histórico', 'Consultando os lotes mais recentes.')}
      </section>
    </div>`;
  document.getElementById('dataSyncRefresh').addEventListener('click', () => loadDataSyncOverview());
  document.getElementById('dataSyncNow').addEventListener('click', triggerDataSyncFromUi);
  document.getElementById('dataSyncDetails').addEventListener('click', () => renderDataSyncPanel('details'));
  document.getElementById('dataSyncErrors').addEventListener('click', () => renderDataSyncPanel('errors'));
  document.getElementById('dataSyncHistory').addEventListener('click', () => renderDataSyncPanel('history'));
  await loadDataSyncOverview();
}

async function loadDataSyncOverview(options = {}) {
  const refreshPanel = options.refreshPanel !== false;
  const statusTarget = document.getElementById('dataSyncStatusContent');
  const resultTarget = document.getElementById('dataSyncResult');
  if (!statusTarget || !resultTarget) return null;
  statusTarget.innerHTML = CrmUi.renderState('loading', 'Consultando sincronização', 'Carregando a última execução e o estado do adapter.');
  try {
    const [status, history] = await Promise.all([
      supabaseGetDataSyncStatus({ source: 'EXCEL_API' }),
      supabaseListDataSyncBatches({ source: 'EXCEL_API', limit: 100 })
    ]);
    dataSyncUiState.status = status;
    dataSyncUiState.batches = history.rows || [];
    statusTarget.innerHTML = renderDataSyncStatus(status);
    if (refreshPanel) await renderDataSyncPanel(dataSyncUiState.activePanel);
    return status;
  } catch (error) {
    statusTarget.innerHTML = CrmUi.renderState('error', 'Status indisponível', error.message || 'Não foi possível consultar a integração.');
    if (refreshPanel) resultTarget.innerHTML = CrmUi.renderState('error', 'Dados indisponíveis', 'A última versão válida do CRM não foi alterada.');
    return null;
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
  const lastSuccessfulSync = source.last_success_at || batch.finished_at;
  return `
    <div class="data-sync-health">
      <article><span>Excel/API</span><strong><i class="data-sync-dot ${connectionClass}"></i>${connectionLabel}</strong><small>${escapeHtml(source.connection_status || 'UNKNOWN')}</small></article>
      <article><span>Última sincronização</span><strong>${lastSuccessfulSync ? escapeHtml(formatDataSyncDateTime(lastSuccessfulSync)) : 'Ainda não executada'}</strong><small>${batch.source_updated_at ? `Origem: ${escapeHtml(formatDataSyncDateTime(batch.source_updated_at))}` : 'Sem versão recebida'}</small></article>
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
  if (!button || dataSyncUiState.syncRequest) return;
  button.disabled = true;
  renderDataSyncNotice('checking', 'Validando acesso', 'Conferindo sua sessão e preparando a solicitação segura.');
  let keepDisabled = false;
  try {
    const result = await supabaseTriggerDataSync();
    if (result.queued) {
      const status = dataSyncUiState.status || {};
      const source = status.source || {};
      const batch = status.last_batch || {};
      const queuedAt = dataSyncDateMillis(result.queued_at) || Date.now();
      dataSyncUiState.syncRequest = {
        queuedAt,
        baselineBatchId: batch.id || '',
        baselineSuccessAt: dataSyncDateMillis(source.last_success_at || batch.finished_at),
        attempts: 0
      };
      keepDisabled = true;
      renderDataSyncNotice(
        'queued',
        'Solicitação enviada',
        'Aguardando o executor seguro buscar e validar a planilha do OneDrive.',
        { meta: `Enviada às ${formatDataSyncTime(queuedAt)}` }
      );
      scheduleDataSyncPoll(5000);
      return;
    }
    const batch = result.batch || {};
    renderDataSyncCompletion(batch, result.duplicate === true);
    await loadDataSyncOverview();
  } catch (error) {
    renderDataSyncNotice(
      'error',
      'Não foi possível iniciar',
      `${error.message || 'Não foi possível sincronizar.'} A última versão válida permanece disponível no CRM.`
    );
  } finally {
    button.disabled = keepDisabled;
  }
}

function scheduleDataSyncPoll(delay = 10000) {
  if (dataSyncUiState.pollTimer) clearTimeout(dataSyncUiState.pollTimer);
  dataSyncUiState.pollTimer = setTimeout(pollDataSyncRequest, delay);
}

async function pollDataSyncRequest() {
  dataSyncUiState.pollTimer = null;
  const request = dataSyncUiState.syncRequest;
  if (!request || !document.getElementById('dataSyncMessage')) return stopDataSyncPolling();
  request.attempts += 1;

  const status = await loadDataSyncOverview({ refreshPanel: false });
  if (!status) {
    renderDataSyncNotice(
      'warning',
      'Acompanhamento temporariamente indisponível',
      'A execução continua no backend. O CRM tentará consultar o resultado novamente.',
      { meta: `Tentativa ${request.attempts}` }
    );
    return scheduleDataSyncPoll(15000);
  }

  const source = status.source || {};
  const batch = status.last_batch || {};
  const sourceErrorAt = dataSyncDateMillis(source.last_error_at);
  const sourceSuccessAt = dataSyncDateMillis(source.last_success_at || batch.finished_at);
  const batchChanged = Boolean(batch.id && batch.id !== request.baselineBatchId);
  const successAdvanced = sourceSuccessAt > Math.max(request.baselineSuccessAt || 0, request.queuedAt - 2000);
  const elapsed = Date.now() - request.queuedAt;

  if (source.last_error && sourceErrorAt >= request.queuedAt - 2000) {
    renderDataSyncNotice(
      'error',
      'Sincronização não concluída',
      `${source.last_error} A última versão válida permanece disponível no CRM.`,
      { meta: `Falha registrada às ${formatDataSyncTime(sourceErrorAt)}` }
    );
    return stopDataSyncPolling();
  }

  if (batchChanged && batch.status === 'failed') {
    renderDataSyncNotice(
      'error',
      'Sincronização não concluída',
      'O processamento foi encerrado com erro. Consulte Visualizar erros; a última versão válida não foi alterada.',
      { meta: batch.id ? `Lote ${shortDataSyncId(batch.id)}` : '' }
    );
    return stopDataSyncPolling();
  }

  if (successAdvanced && (!batchChanged || DATA_SYNC_TERMINAL_STATUSES.has(batch.status))) {
    await loadDataSyncOverview();
    renderDataSyncCompletion(batch, !batchChanged);
    return stopDataSyncPolling();
  }

  if (batchChanged) {
    renderDataSyncNotice(
      'processing',
      'Planilha em processamento',
      'O arquivo foi localizado. Os dados estão sendo validados e gravados com segurança no Supabase.',
      { meta: batch.id ? `Lote ${shortDataSyncId(batch.id)}` : '' }
    );
  } else if (elapsed > 120000) {
    renderDataSyncNotice(
      'warning',
      'Ainda aguardando o processamento',
      'O GitHub pode demorar alguns minutos para liberar o executor. Você pode continuar usando o CRM normalmente.',
      { meta: `Solicitada às ${formatDataSyncTime(request.queuedAt)}` }
    );
  }

  if (elapsed >= 10 * 60 * 1000) {
    renderDataSyncNotice(
      'warning',
      'A execução está demorando mais que o normal',
      'Use Atualizar para consultar novamente. A última versão válida continua disponível no CRM.',
      { meta: `Solicitada às ${formatDataSyncTime(request.queuedAt)}` }
    );
    return stopDataSyncPolling();
  }
  scheduleDataSyncPoll(request.attempts < 3 ? 8000 : 15000);
}

function stopDataSyncPolling() {
  if (dataSyncUiState.pollTimer) clearTimeout(dataSyncUiState.pollTimer);
  dataSyncUiState.pollTimer = null;
  dataSyncUiState.syncRequest = null;
  const button = document.getElementById('dataSyncNow');
  if (button) button.disabled = false;
}

function renderDataSyncCompletion(batch, duplicate) {
  if (duplicate) {
    renderDataSyncNotice(
      'success',
      'CRM já estava atualizado',
      'A planilha foi conferida e nenhuma versão nova foi encontrada. Nenhum registro foi duplicado.',
      { meta: batch.id ? `Último lote ${shortDataSyncId(batch.id)}` : '' }
    );
    return;
  }
  const errors = Number(batch.error_count || 0);
  const summary = [
    `${Number(batch.updated_rows || 0).toLocaleString('pt-BR')} alterados`,
    `${Number(batch.inserted_rows || 0).toLocaleString('pt-BR')} novos`,
    `${errors.toLocaleString('pt-BR')} erros`
  ].join(' · ');
  renderDataSyncNotice(
    errors ? 'warning' : 'success',
    errors ? 'Sincronização concluída com avisos' : 'Sincronização concluída',
    summary,
    { meta: batch.id ? `Lote ${shortDataSyncId(batch.id)}` : '', complete: true }
  );
}

function renderDataSyncNotice(kind, title, description, options = {}) {
  const target = document.getElementById('dataSyncMessage');
  if (!target) return;
  const stage = options.stage ?? ({ checking: 0, queued: 1, processing: 1, success: 2, warning: 1, error: 1 }[kind] ?? 0);
  const complete = kind === 'success' || options.complete === true;
  const steps = ['Solicitação', 'Leitura e validação', 'Resultado'];
  target.className = `data-sync-notice is-${kind}`;
  target.innerHTML = `
    <div class="data-sync-notice-mark" aria-hidden="true"></div>
    <div class="data-sync-notice-body">
      <strong>${escapeHtml(title)}</strong>
      <p>${escapeHtml(description)}</p>
      <ol class="data-sync-progress" aria-label="Andamento da sincronização">
        ${steps.map((label, index) => {
          const stepClass = complete || index < stage ? 'is-complete' : (index === stage ? (kind === 'error' ? 'is-error' : 'is-active') : '');
          return `<li class="${stepClass}"><i aria-hidden="true"></i><span>${escapeHtml(label)}</span></li>`;
        }).join('')}
      </ol>
      ${options.meta ? `<small>${escapeHtml(options.meta)}</small>` : ''}
    </div>`;
}

function dataSyncDateMillis(value) {
  if (!value) return 0;
  const result = new Date(value).valueOf();
  return Number.isFinite(result) ? result : 0;
}

function formatDataSyncTime(value) {
  const milliseconds = typeof value === 'number' ? value : dataSyncDateMillis(value);
  if (!milliseconds) return '—';
  return new Date(milliseconds).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });
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
