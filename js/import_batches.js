const IMPORT_BATCH_STATUS_LABELS = {
  validating: 'Validando',
  validated: 'Validado',
  failed: 'Erro',
  approved: 'Aprovado',
  imported: 'Importado',
  committed: 'Importado'
};

let importBatchState = {
  page: 1,
  pageSize: 25,
  filters: {},
  rows: [],
  pagination: {},
  selectedBatchId: null,
  detailPage: 1,
  detailPageSize: 25,
  details: null,
  requestSeq: 0,
  lastOpenButton: null
};

async function renderImportBatches(container) {
  importBatchState = {
    page: 1,
    pageSize: 25,
    filters: {},
    rows: [],
    pagination: {},
    selectedBatchId: null,
    detailPage: 1,
    detailPageSize: 25,
    details: null,
    requestSeq: 0,
    lastOpenButton: null
  };

  container.innerHTML = `
    <section class="panel">
      <div class="panel-header">
        <div>
          <h2>Lotes de Importacao</h2>
          <p>Consulte validacoes, aprovacoes, importacoes definitivas e auditoria dos lotes SAP.</p>
        </div>
        <button class="btn btn-secondary" id="importBatchesRefreshButton" type="button">Atualizar</button>
      </div>
      <form id="importBatchesFilters" class="field-grid">
        <label class="span-2">Periodo inicial
          <input id="batchDateFrom" type="date">
        </label>
        <label class="span-2">Periodo final
          <input id="batchDateTo" type="date">
        </label>
        <label class="span-2">Status
          <select id="batchStatus">
            <option value="">Todos</option>
            <option value="validating">validating</option>
            <option value="validated">validated</option>
            <option value="failed">failed</option>
            <option value="approved">approved</option>
            <option value="imported">imported</option>
            <option value="committed">committed</option>
          </select>
        </label>
        <label class="span-2">Estado
          <select id="batchRegion">
            <option value="">Todos</option>
            <option value="SP">SP</option>
            <option value="PR">PR</option>
          </select>
        </label>
        <label class="span-2">Usuario
          <input id="batchUser" type="search" placeholder="Usuario">
        </label>
        <label class="span-2">Lote/arquivo
          <input id="batchSearch" type="search" placeholder="ID, arquivo ou hash">
        </label>
        <label class="span-3">Nome do arquivo
          <input id="batchSourceName" type="search" placeholder="Arquivo importado">
        </label>
        <label class="span-3">Itens por pagina
          <select id="batchPageSize">
            <option value="25">25</option>
            <option value="50">50</option>
            <option value="100">100</option>
          </select>
        </label>
        <label class="span-2 checkbox-line">
          <input id="batchErrorOnly" type="checkbox"> Com erros
        </label>
        <label class="span-2 checkbox-line">
          <input id="batchImportedOnly" type="checkbox"> Importados
        </label>
        <label class="span-2 checkbox-line">
          <input id="batchPendingOnly" type="checkbox"> Pendentes
        </label>
        <div class="span-12 actions-row">
          <button class="btn btn-primary" id="importBatchesFilterButton" type="submit">Filtrar</button>
          <button class="btn btn-ghost" id="importBatchesClearButton" type="button">Limpar filtros</button>
          <button class="btn btn-secondary" id="importBatchesExportButton" type="button" disabled>Exportar CSV</button>
          <p id="importBatchesMessage" class="form-message"></p>
        </div>
      </form>
    </section>
    <section id="importBatchesSummary"></section>
    <section class="panel" id="importBatchesList">
      <div class="empty-state">Carregando lotes de importacao...</div>
    </section>
    <section class="panel" id="importBatchDetails" hidden></section>
  `;

  document.getElementById('importBatchesFilters').addEventListener('submit', async (event) => {
    event.preventDefault();
    importBatchState.page = 1;
    await loadImportBatches();
  });

  document.getElementById('importBatchesRefreshButton').addEventListener('click', () => loadImportBatches());
  document.getElementById('importBatchesClearButton').addEventListener('click', async () => {
    document.getElementById('importBatchesFilters').reset();
    document.getElementById('batchPageSize').value = '25';
    importBatchState.page = 1;
    importBatchState.pageSize = 25;
    await loadImportBatches();
  });
  document.getElementById('importBatchesExportButton').addEventListener('click', exportImportBatchesCsv);

  document.getElementById('importBatchesList').addEventListener('click', async (event) => {
    const openId = event.target.dataset.openImportBatch;
    const pageAction = event.target.dataset.importBatchPage;
    if (openId) {
      importBatchState.selectedBatchId = openId;
      importBatchState.detailPage = 1;
      importBatchState.lastOpenButton = event.target;
      await loadImportBatchDetails(openId);
      return;
    }
    if (pageAction === 'previous' && importBatchState.pagination.hasPrevious) {
      importBatchState.page -= 1;
      await loadImportBatches();
    }
    if (pageAction === 'next' && importBatchState.pagination.hasNext) {
      importBatchState.page += 1;
      await loadImportBatches();
    }
  });

  document.getElementById('importBatchDetails').addEventListener('click', async (event) => {
    const action = event.target.dataset.importBatchDetailAction;
    if (action === 'close') {
      closeImportBatchDetails();
      return;
    }
    if (action === 'export-items') {
      exportImportBatchItemsCsv();
      return;
    }
    if (action === 'previous' && importBatchState.details?.itemsPagination?.hasPrevious) {
      importBatchState.detailPage -= 1;
      await loadImportBatchDetails(importBatchState.selectedBatchId);
      return;
    }
    if (action === 'next' && importBatchState.details?.itemsPagination?.hasNext) {
      importBatchState.detailPage += 1;
      await loadImportBatchDetails(importBatchState.selectedBatchId);
    }
  });

  document.removeEventListener('keydown', handleImportBatchEscape);
  document.addEventListener('keydown', handleImportBatchEscape);
  await loadImportBatches();
}

async function loadImportBatches() {
  const message = document.getElementById('importBatchesMessage');
  const list = document.getElementById('importBatchesList');
  const exportButton = document.getElementById('importBatchesExportButton');
  const refreshButton = document.getElementById('importBatchesRefreshButton');
  const filterButton = document.getElementById('importBatchesFilterButton');
  const clearButton = document.getElementById('importBatchesClearButton');
  const requestId = importBatchState.requestSeq + 1;
  importBatchState.requestSeq = requestId;
  const filters = readImportBatchFilters();
  importBatchState.filters = filters;
  importBatchState.pageSize = filters.pageSize;
  message.textContent = 'Carregando lotes...';
  message.style.color = 'var(--muted)';
  list.innerHTML = '<div class="empty-state">Carregando lotes de importacao...</div>';
  exportButton.disabled = true;
  refreshButton.disabled = true;
  filterButton.disabled = true;
  clearButton.disabled = true;
  try {
    const data = await supabaseListImportBatchesReport(Object.assign({}, filters, {
      page: importBatchState.page,
      pageSize: importBatchState.pageSize
    }));
    if (requestId !== importBatchState.requestSeq) return;
    importBatchState.rows = data.rows || [];
    importBatchState.pagination = data.pagination || {};
    renderImportBatchSummary(data.summary || {});
    list.innerHTML = renderImportBatchTable(importBatchState.rows, importBatchState.pagination);
    exportButton.disabled = !importBatchState.rows.length;
    message.textContent = importBatchState.rows.length ? 'Lotes carregados.' : 'Nenhum lote encontrado.';
    message.style.color = importBatchState.rows.length ? 'var(--success)' : 'var(--muted)';
  } catch (error) {
    if (requestId !== importBatchState.requestSeq) return;
    console.error(error);
    renderImportBatchSummary({});
    list.innerHTML = `<div class="empty-state">${escapeHtml(error.message)}</div>`;
    message.textContent = error.message;
    message.style.color = 'var(--accent)';
  } finally {
    if (requestId === importBatchState.requestSeq) {
      refreshButton.disabled = false;
      filterButton.disabled = false;
      clearButton.disabled = false;
      exportButton.disabled = !(importBatchState.rows || []).length;
    }
  }
}

function readImportBatchFilters() {
  const allowedPageSizes = [25, 50, 100];
  const pageSize = Number(document.getElementById('batchPageSize').value || 25);
  return {
    dateFrom: document.getElementById('batchDateFrom').value,
    dateTo: document.getElementById('batchDateTo').value,
    status: document.getElementById('batchStatus').value,
    region: document.getElementById('batchRegion').value,
    user: document.getElementById('batchUser').value,
    search: document.getElementById('batchSearch').value,
    sourceName: document.getElementById('batchSourceName').value,
    pageSize: allowedPageSizes.includes(pageSize) ? pageSize : 25,
    errorOnly: document.getElementById('batchErrorOnly').checked,
    importedOnly: document.getElementById('batchImportedOnly').checked,
    pendingOnly: document.getElementById('batchPendingOnly').checked
  };
}

function renderImportBatchSummary(summary) {
  document.getElementById('importBatchesSummary').innerHTML = `
    <div class="cards import-batch-metrics">
      ${metricCard('Total de lotes', summary.total_batches || 0)}
      ${metricCard('Importados', summary.imported_batches || 0)}
      ${metricCard('Com erro', summary.error_batches || 0)}
      ${metricCard('Pendentes', summary.pending_batches || 0)}
      ${metricCard('Produtos processados', summary.total_products || 0)}
      ${metricCard('Produtos importados', summary.imported_products || 0)}
      ${metricCard('Sucesso medio', `${Number(summary.success_percent || 0).toFixed(2)}%`)}
    </div>
  `;
}

function metricCard(label, value) {
  return `<article class="metric-card"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></article>`;
}

function renderImportBatchTable(rows, pagination) {
  if (!rows.length) return '<div class="empty-state">Nenhum lote encontrado para os filtros informados.</div>';
  return `
    <div class="panel-header">
      <div>
        <h2>${Number(pagination.total || rows.length)} lotes</h2>
        <p>Pagina ${pagination.page || 1} com ${rows.length} registro(s).</p>
      </div>
      ${renderImportBatchPager(pagination)}
    </div>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>ID / Arquivo</th>
            <th>Data</th>
            <th>Estado</th>
            <th>Usuario</th>
            <th>Status</th>
            <th>Total</th>
            <th>Validas</th>
            <th>Avisos</th>
            <th>Erros</th>
            <th>Aprovadas</th>
            <th>Importadas</th>
            <th>Aprovacao</th>
            <th>Importacao</th>
            <th>Duracao</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          ${rows.map((row) => `
            <tr>
              <td><strong>${escapeHtml(shortId(row.id))}</strong><small>${escapeHtml(row.source_name || 'Arquivo nao informado')}</small></td>
              <td>${formatDateTime(row.created_at)}</td>
              <td>${escapeHtml(row.region || '-')}</td>
              <td>${escapeHtml(row.created_by || '-')}</td>
              <td>${renderImportBatchStatus(row.status)}</td>
              <td>${numberText(row.total_rows)}</td>
              <td>${numberText(row.valid_rows)}</td>
              <td>${numberText(row.warning_count)}</td>
              <td>${numberText(row.error_count)}</td>
              <td>${numberText(row.approved_rows)}</td>
              <td>${numberText(row.imported_rows)}</td>
              <td>${formatDateTime(row.approved_at)}<small>${escapeHtml(row.approved_by || '')}</small></td>
              <td>${formatDateTime(row.imported_at)}</td>
              <td>${formatDuration(row.duration_seconds)}</td>
              <td><button class="btn btn-secondary" type="button" data-open-import-batch="${escapeHtml(row.id)}">Abrir</button></td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
    ${renderImportBatchPager(pagination)}
  `;
}

function renderImportBatchPager(pagination = {}) {
  return `
    <div class="actions-row">
      <button class="btn btn-ghost" type="button" data-import-batch-page="previous"${pagination.hasPrevious ? '' : ' disabled'}>Anterior</button>
      <button class="btn btn-ghost" type="button" data-import-batch-page="next"${pagination.hasNext ? '' : ' disabled'}>Proxima</button>
    </div>
  `;
}

async function loadImportBatchDetails(batchId) {
  const detailsPanel = document.getElementById('importBatchDetails');
  detailsPanel.hidden = false;
  detailsPanel.innerHTML = '<div class="empty-state">Carregando detalhes do lote...</div>';
  try {
    const data = await supabaseGetImportBatchDetails(batchId, {
      page: importBatchState.detailPage,
      pageSize: importBatchState.detailPageSize
    });
    importBatchState.details = data;
    detailsPanel.innerHTML = renderImportBatchDetails(data);
    detailsPanel.scrollIntoView({ behavior: 'smooth', block: 'start' });
  } catch (error) {
    console.error(error);
    detailsPanel.innerHTML = `<div class="empty-state">${escapeHtml(error.message)}</div>`;
  }
}

function renderImportBatchDetails(data) {
  const batch = data.batch || {};
  if (!batch.id) {
    return `
      <div class="panel-header">
        <div><h2>Lote nao encontrado</h2><p>O lote solicitado nao esta disponivel ou voce nao tem permissao para visualiza-lo.</p></div>
        <button class="btn btn-ghost" type="button" data-import-batch-detail-action="close">Fechar</button>
      </div>
    `;
  }
  const items = data.items || [];
  const audit = data.audit || [];
  return `
    <div class="panel-header">
      <div>
        <h2>Detalhes do lote ${escapeHtml(shortId(batch.id))}</h2>
        <p>${escapeHtml(batch.source_name || 'Arquivo nao informado')}</p>
      </div>
      <div class="actions-row">
        <button class="btn btn-secondary" type="button" data-import-batch-detail-action="export-items"${items.length ? '' : ' disabled'}>Exportar itens</button>
        <button class="btn btn-ghost" type="button" data-import-batch-detail-action="close">Fechar</button>
      </div>
    </div>
    <div class="import-batch-detail-grid">
      <article><span>Status</span><strong>${renderImportBatchStatus(batch.status)}</strong></article>
      <article><span>Responsavel</span><strong>${escapeHtml(batch.created_by || '-')}</strong></article>
      <article><span>Estado</span><strong>${escapeHtml(batch.region || '-')}</strong></article>
      <article><span>Criado em</span><strong>${formatDateTime(batch.created_at)}</strong></article>
      <article><span>Aprovado por</span><strong>${escapeHtml(batch.approved_by || '-')}</strong></article>
      <article><span>Aprovacao</span><strong>${formatDateTime(batch.approved_at)}</strong></article>
      <article><span>Importacao</span><strong>${formatDateTime(batch.imported_at)}</strong></article>
      <article><span>Duracao</span><strong>${formatDuration(batch.duration_seconds)}</strong></article>
    </div>
    <div class="import-summary">
      <article><span>Total</span><strong>${numberText(batch.total_rows)}</strong></article>
      <article><span>Validas</span><strong>${numberText(batch.valid_rows)}</strong></article>
      <article><span>Avisos</span><strong>${numberText(batch.warning_count)}</strong></article>
      <article><span>Erros</span><strong>${numberText(batch.error_count)}</strong></article>
    </div>
    <div class="panel-header compact-header">
      <div><h2>Itens</h2><p>Produtos processados neste lote.</p></div>
      ${renderImportBatchDetailPager(data.itemsPagination || {})}
    </div>
    ${renderImportBatchItems(items)}
    <div class="panel-header compact-header">
      <div><h2>Auditoria</h2><p>Alteracoes registradas pelo lote.</p></div>
    </div>
    ${renderImportBatchAudit(audit)}
  `;
}

function renderImportBatchDetailPager(pagination = {}) {
  return `
    <div class="actions-row">
      <button class="btn btn-ghost" type="button" data-import-batch-detail-action="previous"${pagination.hasPrevious ? '' : ' disabled'}>Anterior</button>
      <button class="btn btn-ghost" type="button" data-import-batch-detail-action="next"${pagination.hasNext ? '' : ' disabled'}>Proxima</button>
    </div>
  `;
}

function renderImportBatchItems(items) {
  if (!items.length) return '<div class="empty-state">Este lote nao possui itens disponiveis.</div>';
  return `
    <div class="table-wrap">
      <table>
        <thead><tr><th>Linha</th><th>Codigo</th><th>Descricao</th><th>Marca</th><th>Preco</th><th>Estoque</th><th>Resultado</th><th>Avisos</th><th>Erros</th><th>Acao</th><th>Situacao final</th></tr></thead>
        <tbody>
          ${items.map((item) => {
            const normalized = item.normalized_data || {};
            return `
              <tr>
                <td>${numberText(item.row_number)}</td>
                <td>${escapeHtml(item.codigo || '')}</td>
                <td>${escapeHtml(item.descricao_base || normalized.descricao || '')}</td>
                <td>${escapeHtml(item.marca || normalized.marca || '')}</td>
                <td>${moneyOrBlank(item.preco_sp ?? item.preco_pr ?? normalized.preco_sp ?? normalized.preco_pr)}</td>
                <td>${escapeHtml(normalized.estoque_quantidade ?? item.estoque_sp ?? item.estoque_pr ?? '')}</td>
                <td>${renderImportBatchStatus(item.status)}</td>
                <td>${jsonListText(item.warnings)}</td>
                <td>${jsonListText(item.errors)}</td>
                <td>${escapeHtml(item.action || '-')}</td>
                <td>${renderImportBatchStatus((importBatchState.details?.batch || {}).status)}</td>
              </tr>
            `;
          }).join('')}
        </tbody>
      </table>
    </div>
  `;
}

function renderImportBatchAudit(audit) {
  if (!audit.length) return '<div class="empty-state">Este lote ainda nao possui auditoria registrada.</div>';
  return `
    <div class="table-wrap">
      <table>
        <thead><tr><th>Data</th><th>Usuario</th><th>Acao</th><th>Produto</th><th>Campo</th><th>Anterior</th><th>Novo</th></tr></thead>
        <tbody>
          ${audit.map((row) => `
            <tr>
              <td>${formatDateTime(row.created_at)}</td>
              <td>${escapeHtml(row.created_by || '')}</td>
              <td>${escapeHtml(row.action || '')}</td>
              <td>${escapeHtml(row.codigo || '')}</td>
              <td>${escapeHtml(row.field_name || '')}</td>
              <td>${escapeHtml(formatAuditValue(row.old_value))}</td>
              <td>${escapeHtml(formatAuditValue(row.new_value))}</td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  `;
}

function closeImportBatchDetails() {
  importBatchState.selectedBatchId = null;
  importBatchState.details = null;
  const detailsPanel = document.getElementById('importBatchDetails');
  detailsPanel.hidden = true;
  detailsPanel.innerHTML = '';
  if (importBatchState.lastOpenButton && document.body.contains(importBatchState.lastOpenButton)) {
    importBatchState.lastOpenButton.focus();
  }
}

function handleImportBatchEscape(event) {
  if (event.key === 'Escape' && importBatchState.selectedBatchId) {
    closeImportBatchDetails();
  }
}

async function exportImportBatchesCsv() {
  const message = document.getElementById('importBatchesMessage');
  message.textContent = 'Gerando CSV...';
  message.style.color = 'var(--muted)';
  try {
    const data = await supabaseListImportBatchesReport(Object.assign({}, importBatchState.filters, {
      page: 1,
      pageSize: 100
    }));
    const rows = data.rows || [];
    const headers = ['id', 'data', 'estado', 'usuario', 'arquivo', 'status', 'total', 'validos', 'avisos', 'erros', 'aprovados', 'importados', 'aprovado_em', 'aprovado_por', 'importado_em'];
    const lines = [
      headers.join(';'),
      ...rows.map((row) => [
        row.id,
        row.created_at,
        row.region,
        row.created_by,
        row.source_name,
        row.status,
        row.total_rows,
        row.valid_rows,
        row.warning_count,
        row.error_count,
        row.approved_rows,
        row.imported_rows,
        row.approved_at,
        row.approved_by,
        row.imported_at
      ].map(importBatchCsvCell).join(';'))
    ];
    downloadImportBatchCsv(lines, `lotes-importacao-${importBatchDateStamp()}.csv`);
    const total = Number(data.pagination?.total || rows.length);
    message.textContent = total > rows.length ? `CSV gerado com os primeiros ${rows.length} lotes filtrados.` : 'CSV gerado.';
    message.style.color = 'var(--success)';
  } catch (error) {
    console.error(error);
    message.textContent = error.message;
    message.style.color = 'var(--accent)';
  }
}

function exportImportBatchItemsCsv() {
  const details = importBatchState.details || {};
  const items = details.items || [];
  const headers = ['linha', 'codigo', 'descricao', 'marca', 'preco_sp', 'preco_pr', 'estoque', 'status', 'avisos', 'erros', 'acao'];
  const lines = [
    headers.join(';'),
    ...items.map((item) => {
      const normalized = item.normalized_data || {};
      return [
        item.row_number,
        item.codigo,
        item.descricao_base || normalized.descricao,
        item.marca || normalized.marca,
        item.preco_sp ?? normalized.preco_sp,
        item.preco_pr ?? normalized.preco_pr,
        normalized.estoque_quantidade ?? item.estoque_sp ?? item.estoque_pr,
        item.status,
        jsonListText(item.warnings),
        jsonListText(item.errors),
        item.action
      ].map(importBatchCsvCell).join(';');
    })
  ];
  downloadImportBatchCsv(lines, `itens-lote-${shortId(details.batch?.id || 'importacao')}-${importBatchDateStamp()}.csv`);
}

function downloadImportBatchCsv(lines, filename) {
  const blob = new Blob([`\uFEFF${lines.join('\n')}`], { type: 'text/csv;charset=utf-8' });
  const link = document.createElement('a');
  link.href = URL.createObjectURL(blob);
  link.download = filename;
  link.click();
  URL.revokeObjectURL(link.href);
}

function importBatchCsvCell(value) {
  let text = String(value == null ? '' : value).replace(/"/g, '""');
  if (/^[=+\-@]/.test(text)) text = `'${text}`;
  return /[;"\n\r]/.test(text) ? `"${text}"` : text;
}

function importBatchDateStamp() {
  return new Date().toISOString().slice(0, 19).replace(/[-:T]/g, '');
}

function renderImportBatchStatus(status) {
  const value = String(status || '-');
  const normalized = value.toLowerCase();
  const css = normalized === 'imported' || normalized === 'committed' || normalized === 'approved' ? 'ok'
    : normalized === 'failed' || normalized === 'error' ? 'warn'
      : '';
  return `<span class="status-pill ${css}">${escapeHtml(IMPORT_BATCH_STATUS_LABELS[normalized] || value)}</span>`;
}

function shortId(value) {
  const text = String(value || '');
  return text.length > 12 ? text.slice(0, 8) : text;
}

function numberText(value) {
  return Number(value || 0).toLocaleString('pt-BR');
}

function formatDateTime(value) {
  if (!value) return '-';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '-';
  return date.toLocaleString('pt-BR');
}

function formatDuration(seconds) {
  const total = Number(seconds || 0);
  if (!total) return '-';
  if (total < 60) return `${total}s`;
  const minutes = Math.floor(total / 60);
  const rest = total % 60;
  return `${minutes}m ${rest}s`;
}

function moneyOrBlank(value) {
  if (value == null || value === '') return '';
  return money(value);
}

function jsonListText(value) {
  if (Array.isArray(value)) return value.join(', ');
  if (value == null) return '';
  return String(value).replace(/^\[|\]$/g, '');
}

function formatAuditValue(value) {
  if (value == null) return '';
  if (typeof value === 'object') return JSON.stringify(value);
  return String(value);
}
