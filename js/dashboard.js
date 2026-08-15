function money(value) {
  return new Intl.NumberFormat(APP_CONFIG.locale, {
    style: 'currency',
    currency: APP_CONFIG.currency
  }).format(Number(value || 0));
}

function escapeHtml(value) {
  return String(value == null ? '' : value).replace(/[&<>"']/g, (char) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#039;'
  }[char]));
}

function dashboardIsoDate(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

function dashboardPeriodDates(period) {
  const today = new Date();
  const end = new Date(today.getFullYear(), today.getMonth(), today.getDate());
  let start = new Date(end);

  if (period === '7d') start.setDate(start.getDate() - 6);
  if (period === '30d') start.setDate(start.getDate() - 29);
  if (period === 'month') start = new Date(end.getFullYear(), end.getMonth(), 1);
  if (period === 'previous') {
    start = new Date(end.getFullYear(), end.getMonth() - 1, 1);
    end.setDate(0);
  }

  return { dateFrom: dashboardIsoDate(start), dateTo: dashboardIsoDate(end) };
}

async function renderDashboard(container) {
  const initialDates = dashboardPeriodDates('month');
  const state = {
    period: 'month',
    dateFrom: initialDates.dateFrom,
    dateTo: initialDates.dateTo,
    region: '',
    sellerId: ''
  };

  container.innerHTML = renderCommercialDashboardShell(state);
  bindCommercialDashboardEvents(container, state);
  await loadCommercialDashboard(container, state);
}

function renderCommercialDashboardShell(state) {
  return `
    <section class="panel commercial-dashboard">
      <div class="panel-header dashboard-header">
        <div>
          <h2>Inicio Comercial</h2>
          <p data-dashboard-scope>Indicadores do periodo selecionado.</p>
        </div>
        <button class="btn btn-secondary" type="button" data-dashboard-refresh>Atualizar</button>
      </div>
      <div class="dashboard-periods" role="group" aria-label="Periodo do dashboard">
        ${renderDashboardPeriodButton('today', 'Hoje', state.period)}
        ${renderDashboardPeriodButton('7d', '7 dias', state.period)}
        ${renderDashboardPeriodButton('30d', '30 dias', state.period)}
        ${renderDashboardPeriodButton('month', 'Mes atual', state.period)}
        ${renderDashboardPeriodButton('previous', 'Mes anterior', state.period)}
        ${renderDashboardPeriodButton('custom', 'Personalizado', state.period)}
      </div>
      <form class="dashboard-filters" data-dashboard-filters>
        <label>
          <span>Data inicial</span>
          <input type="date" name="dateFrom" value="${escapeHtml(state.dateFrom)}" required>
        </label>
        <label>
          <span>Data final</span>
          <input type="date" name="dateTo" value="${escapeHtml(state.dateTo)}" required>
        </label>
        <label>
          <span>Filial</span>
          <select name="region">
            <option value="">Todas</option>
            <option value="SP">SP</option>
            <option value="PR">PR</option>
          </select>
        </label>
        <label data-seller-filter hidden>
          <span>Vendedor</span>
          <select name="sellerId">
            <option value="">Todos</option>
          </select>
        </label>
      </form>
    </section>
    <div data-dashboard-result aria-live="polite">
      <div class="empty-state">Carregando inicio...</div>
    </div>
  `;
}

function renderDashboardPeriodButton(value, label, current) {
  const active = value === current;
  return `<button class="dashboard-period-button${active ? ' is-active' : ''}" type="button" data-dashboard-period="${value}" aria-pressed="${active}">${label}</button>`;
}

function bindCommercialDashboardEvents(container, state) {
  const form = container.querySelector('[data-dashboard-filters]');
  const refreshButton = container.querySelector('[data-dashboard-refresh]');

  const updateFromForm = () => {
    state.dateFrom = form.elements.dateFrom.value;
    state.dateTo = form.elements.dateTo.value;
    state.region = form.elements.region.value;
    state.sellerId = form.elements.sellerId ? form.elements.sellerId.value : '';
  };

  container.querySelectorAll('[data-dashboard-period]').forEach((button) => {
    button.addEventListener('click', async () => {
      state.period = button.dataset.dashboardPeriod;
      if (state.period !== 'custom') {
        const dates = dashboardPeriodDates(state.period);
        state.dateFrom = dates.dateFrom;
        state.dateTo = dates.dateTo;
        form.elements.dateFrom.value = state.dateFrom;
        form.elements.dateTo.value = state.dateTo;
      }
      syncDashboardPeriodButtons(container, state.period);
      if (state.period !== 'custom') await loadCommercialDashboard(container, state);
    });
  });

  form.addEventListener('change', async (event) => {
    updateFromForm();
    if (event.target.name === 'dateFrom' || event.target.name === 'dateTo') {
      state.period = 'custom';
      syncDashboardPeriodButtons(container, state.period);
    }
    await loadCommercialDashboard(container, state);
  });

  refreshButton.addEventListener('click', async () => {
    updateFromForm();
    await loadCommercialDashboard(container, state);
  });

  container.addEventListener('click', (event) => {
    const shortcut = event.target.closest('[data-dashboard-route]');
    if (shortcut) openModule(shortcut.dataset.dashboardRoute);
  });
}

function syncDashboardPeriodButtons(container, period) {
  container.querySelectorAll('[data-dashboard-period]').forEach((button) => {
    const active = button.dataset.dashboardPeriod === period;
    button.classList.toggle('is-active', active);
    button.setAttribute('aria-pressed', String(active));
  });
}

async function loadCommercialDashboard(container, state) {
  const result = container.querySelector('[data-dashboard-result]');
  const refreshButton = container.querySelector('[data-dashboard-refresh]');
  refreshButton.disabled = true;
  refreshButton.textContent = 'Atualizando...';
  result.innerHTML = '<div class="empty-state">Carregando inicio...</div>';

  try {
    validateDashboardPeriod(state.dateFrom, state.dateTo);
    const response = await supabaseGetCommercialDashboardSummary(state);
    const data = normalizeCommercialDashboardPayload(response);
    syncSellerFilter(container, data, state);
    syncDashboardScope(container, data);
    result.innerHTML = renderCommercialDashboard(data);
  } catch (error) {
    result.innerHTML = `
      <section class="panel">
        <div class="empty-state dashboard-error-state">
          <strong>${escapeHtml(error.message || 'Nao foi possivel carregar o dashboard.')}</strong>
          <button class="btn btn-secondary" type="button" data-dashboard-retry>Tentar novamente</button>
        </div>
      </section>
    `;
    result.querySelector('[data-dashboard-retry]').addEventListener('click', () => loadCommercialDashboard(container, state));
  } finally {
    refreshButton.disabled = false;
    refreshButton.textContent = 'Atualizar';
  }
}

function validateDashboardPeriod(dateFrom, dateTo) {
  if (!dateFrom || !dateTo) throw new Error('Informe a data inicial e a data final.');
  const start = new Date(`${dateFrom}T00:00:00`);
  const end = new Date(`${dateTo}T00:00:00`);
  if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) throw new Error('Informe datas validas.');
  if (start > end) throw new Error('A data final precisa ser maior ou igual a data inicial.');
  const days = Math.round((end - start) / 86400000);
  if (days > 370) throw new Error('O periodo maximo do dashboard e de 370 dias.');
}

function normalizeCommercialDashboardPayload(data = {}) {
  if (data.kpis) return data;

  const legacyAccess = data.access || { scope: 'own' };
  const orderRows = (data.orders && data.orders.by_status) || [];
  const quoteRows = (data.quotations && data.quotations.by_status) || [];
  const orderCount = Number(data.orders && data.orders.count || 0);
  const orderValue = Number(data.orders && data.orders.total_value || 0);
  const quotationCount = quoteRows.reduce((sum, row) => sum + Number(row.count || 0), 0);
  const quotationValue = quoteRows.reduce((sum, row) => sum + Number(row.total_value || 0), 0);

  return {
    meta: Object.assign({ fallback: true, version: '2.1' }, data.meta || {}),
    filters: data.filters || {},
    access: Object.assign({}, legacyAccess, {
      can_view_seller_ranking: false,
      can_view_stock: legacyAccess.scope === 'all' && !!legacyAccess.can_view_products,
      can_view_imports: legacyAccess.scope === 'all' && !!legacyAccess.can_view_imports
    }),
    sellers: data.sellers || [],
    kpis: {
      orders_count: orderCount,
      orders_value: orderValue,
      quotations_count: quotationCount,
      quotations_value: quotationValue,
      pending_quotations: Number(data.quotations && data.quotations.pending_count || 0),
      approved_quotations: 0,
      conversion_rate: 0,
      average_ticket: orderCount ? orderValue / orderCount : 0,
      active_clients: 0,
      products_sold: 0
    },
    orders: { by_status: orderRows },
    quotations: { by_status: quoteRows },
    rankings: { sellers: [], products: [], clients: [] },
    abc_curve: [],
    series: [],
    stock: {
      total_products: 0,
      out_of_stock: Number(data.products && data.products.out_of_stock_count || 0),
      without_price: 0,
      without_image: 0
    },
    imports: data.imports || {}
  };
}

function syncSellerFilter(container, data, state) {
  const holder = container.querySelector('[data-seller-filter]');
  const select = holder && holder.querySelector('select');
  if (!holder || !select) return;
  const sellers = Array.isArray(data.sellers) ? data.sellers : [];
  const canFilterSeller = !!(data.access && data.access.can_filter_seller);
  holder.hidden = !canFilterSeller;

  if (!canFilterSeller) {
    select.innerHTML = '<option value="">Todos</option>';
    state.sellerId = '';
    return;
  }

  select.innerHTML = `
    <option value="">Todos</option>
    ${sellers.map((seller) => `
      <option value="${escapeHtml(seller.id)}"${seller.id === state.sellerId ? ' selected' : ''}>${escapeHtml(seller.nome || seller.usuario || 'Usuario')}</option>
    `).join('')}
  `;
}

function syncDashboardScope(container, data) {
  const scopeText = container.querySelector('[data-dashboard-scope]');
  if (!scopeText) return;
  const access = data.access || {};
  scopeText.textContent = access.scope === 'all'
    ? 'Visao geral da empresa no periodo selecionado.'
    : access.scope === 'filtered'
      ? 'Indicadores do vendedor selecionado.'
      : 'Seus resultados no periodo selecionado.';
}

function renderCommercialDashboard(data) {
  const kpis = data.kpis || {};
  const access = data.access || {};
  const rankings = data.rankings || {};
  const fallback = !!(data.meta && data.meta.fallback);

  return `
    ${fallback ? '<div class="dashboard-notice" role="status">Resumo basico ativo. Os indicadores avancados estarao disponiveis apos a migration 026.</div>' : ''}
    <section class="cards dashboard-kpis" aria-label="Indicadores principais">
      ${renderMetricCard('Pedidos validos', kpis.orders_count, 'Exclui cancelados')}
      ${renderMetricCard('Valor realizado', money(kpis.orders_value), 'Pedidos aprovados e faturados')}
      ${renderMetricCard('Cotacoes elegiveis', kpis.quotations_count, 'Enviadas, aprovadas e convertidas')}
      ${renderMetricCard('Valor em cotacoes', money(kpis.quotations_value), 'Exclui novas e canceladas')}
      ${renderMetricCard('Conversao', `${dashboardNumber(kpis.conversion_rate, 2)}%`, `${kpis.converted_quotations || 0} cotacoes convertidas`)}
      ${renderMetricCard('Ticket medio', money(kpis.average_ticket), 'Pedidos realizados')}
    </section>
    <section class="dashboard-secondary-metrics" aria-label="Indicadores complementares">
      <div><span>Cotacoes pendentes</span><strong>${dashboardInteger(kpis.pending_quotations)}</strong></div>
      <div><span>Cotacoes aprovadas</span><strong>${dashboardInteger(kpis.approved_quotations)}</strong></div>
      <div><span>Clientes movimentados</span><strong>${dashboardInteger(kpis.active_clients)}</strong></div>
      <div><span>Produtos vendidos</span><strong>${dashboardInteger(kpis.products_sold)}</strong></div>
    </section>
    <section class="panel dashboard-chart-panel">
      <div class="panel-header">
        <div><h2>Vendas por periodo</h2><p>Pedidos aprovados e faturados.</p></div>
      </div>
      ${renderSalesChart(data.series || [])}
    </section>
    <section class="dashboard-grid">
      <article class="panel">
        <div class="panel-header"><div><h2>Pedidos por status</h2><p>Todos os documentos do periodo.</p></div></div>
        ${renderStatusRows(data.orders && data.orders.by_status, true)}
      </article>
      <article class="panel">
        <div class="panel-header"><div><h2>Cotacoes por status</h2><p>Quantidade e valor por situacao.</p></div></div>
        ${renderStatusRows(data.quotations && data.quotations.by_status, true)}
      </article>
    </section>
    <section class="dashboard-rankings">
      ${access.can_view_seller_ranking ? renderRankingPanel('Vendedores', rankings.sellers, 'nome', 'pedidos', 'total') : ''}
      ${renderRankingPanel('Produtos mais vendidos', rankings.products, 'descricao', 'quantidade', 'total')}
      ${renderRankingPanel('Clientes com maior movimentacao', rankings.clients, 'nome', 'pedidos', 'total')}
    </section>
    ${renderAbcPanel(data.abc_curve || [])}
    ${access.can_view_stock ? renderStockPanel(data.stock || {}) : ''}
    ${access.can_view_imports ? renderImportPanel(data.imports || {}) : ''}
    <section class="dashboard-shortcuts" aria-label="Atalhos">
      <button class="btn btn-secondary" type="button" data-dashboard-route="ordersReport">Ver pedidos</button>
      <button class="btn btn-secondary" type="button" data-dashboard-route="quoteReports">Ver cotacoes</button>
      <button class="btn btn-secondary" type="button" data-dashboard-route="products">Consultar produtos</button>
    </section>
  `;
}

function renderMetricCard(label, value, detail) {
  return `<article class="metric-card"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong><small>${escapeHtml(detail)}</small></article>`;
}

function renderStatusRows(rows = [], showValue = false) {
  if (!Array.isArray(rows) || !rows.length) return '<div class="empty-state">Nenhum registro no periodo.</div>';
  return `
    <div class="table-wrap compact-table">
      <table>
        <thead><tr><th>Status</th><th>Qtd</th>${showValue ? '<th>Valor</th>' : ''}</tr></thead>
        <tbody>
          ${rows.map((row) => `
            <tr>
              <td><span class="status-pill">${escapeHtml(row.status)}</span></td>
              <td>${dashboardInteger(row.count)}</td>
              ${showValue ? `<td>${escapeHtml(money(row.total_value))}</td>` : ''}
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  `;
}

function renderSalesChart(points) {
  if (!Array.isArray(points) || !points.length) return '<div class="empty-state">Nenhuma venda realizada no periodo.</div>';
  const maxValue = Math.max(...points.map((point) => Number(point.orders_value || 0)), 0);
  const total = points.reduce((sum, point) => sum + Number(point.orders_value || 0), 0);
  if (maxValue <= 0) return '<div class="empty-state">Nenhuma venda realizada no periodo.</div>';

  return `
    <div class="dashboard-chart" role="img" aria-label="Vendas no periodo, total ${escapeHtml(money(total))}">
      ${points.map((point, index) => {
        const value = Number(point.orders_value || 0);
        const height = Math.max(3, Math.round((value / maxValue) * 100));
        const showLabel = points.length <= 16 || index === 0 || index === points.length - 1 || index % Math.ceil(points.length / 8) === 0;
        return `
          <div class="dashboard-chart-column" title="${escapeHtml(point.label || point.period)}: ${escapeHtml(money(value))}">
            <span class="dashboard-chart-value">${value ? escapeHtml(dashboardCompactMoney(value)) : ''}</span>
            <i style="height:${height}%"></i>
            <small>${showLabel ? escapeHtml(point.label || point.period || '') : ''}</small>
          </div>
        `;
      }).join('')}
    </div>
  `;
}

function renderRankingPanel(title, rows = [], nameKey, countKey, valueKey) {
  return `
    <article class="panel dashboard-ranking-panel">
      <div class="panel-header"><div><h2>${escapeHtml(title)}</h2><p>Top 10 no periodo.</p></div></div>
      ${Array.isArray(rows) && rows.length ? `
        <ol class="dashboard-ranking-list">
          ${rows.map((row) => `
            <li>
              <span>${escapeHtml(row[nameKey] || '-')}</span>
              <strong>${dashboardNumber(row[countKey], countKey === 'quantidade' ? 3 : 0)}</strong>
              <small>${escapeHtml(money(row[valueKey]))}</small>
            </li>
          `).join('')}
        </ol>
      ` : '<div class="empty-state">Sem dados suficientes no periodo.</div>'}
    </article>
  `;
}

function renderAbcPanel(rows) {
  return `
    <section class="panel dashboard-abc-panel">
      <div class="panel-header"><div><h2>Curva ABC de produtos</h2><p>Classificacao pelo valor realizado dos pedidos.</p></div></div>
      ${Array.isArray(rows) && rows.length ? `
        <div class="dashboard-abc-grid">
          ${rows.map((row) => `
            <div><span>Curva ${escapeHtml(row.curve)}</span><strong>${dashboardInteger(row.products)} produtos</strong><small>${escapeHtml(money(row.total_value))}</small></div>
          `).join('')}
        </div>
      ` : '<div class="empty-state">Sem vendas para classificar no periodo.</div>'}
    </section>
  `;
}

function renderStockPanel(stock) {
  return `
    <section class="panel dashboard-admin-panel">
      <div class="panel-header"><div><h2>Estoque</h2><p>Indicadores administrativos do cadastro atual.</p></div></div>
      <div class="dashboard-admin-metrics">
        <div><span>Produtos cadastrados</span><strong>${dashboardInteger(stock.total_products)}</strong></div>
        <div><span>Estoque zerado</span><strong>${dashboardInteger(stock.out_of_stock)}</strong></div>
        <div><span>Sem preco</span><strong>${dashboardInteger(stock.without_price)}</strong></div>
        <div><span>Sem imagem</span><strong>${dashboardInteger(stock.without_image)}</strong></div>
      </div>
    </section>
  `;
}

function renderImportPanel(imports) {
  const batch = imports.last_batch || imports.last_import || {};
  return `
    <section class="panel dashboard-admin-panel">
      <div class="panel-header"><div><h2>Importacao SAP</h2><p>Ultimo lote e falhas no periodo.</p></div></div>
      ${batch.id ? `
        <div class="dashboard-detail-list">
          <span>Status</span><strong>${escapeHtml(batch.status || '-')}</strong>
          <span>Arquivo</span><strong>${escapeHtml(batch.source_name || '-')}</strong>
          <span>Itens validos</span><strong>${dashboardInteger(batch.valid_rows)}</strong>
          <span>Data</span><strong>${escapeHtml(formatDateTime(batch.imported_at || batch.created_at))}</strong>
          <span>Falhas recentes</span><strong>${dashboardInteger(imports.recent_failures)}</strong>
        </div>
      ` : '<div class="empty-state">Nenhum lote de importacao encontrado.</div>'}
    </section>
  `;
}

function dashboardInteger(value) {
  return new Intl.NumberFormat(APP_CONFIG.locale, { maximumFractionDigits: 0 }).format(Number(value || 0));
}

function dashboardNumber(value, digits) {
  return new Intl.NumberFormat(APP_CONFIG.locale, { maximumFractionDigits: digits }).format(Number(value || 0));
}

function dashboardCompactMoney(value) {
  return new Intl.NumberFormat(APP_CONFIG.locale, {
    notation: 'compact',
    maximumFractionDigits: 1
  }).format(Number(value || 0));
}

function formatDateTime(value) {
  if (!value) return '-';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '-';
  return new Intl.DateTimeFormat(APP_CONFIG.locale, {
    dateStyle: 'short',
    timeStyle: 'short'
  }).format(date);
}

