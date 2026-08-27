async function renderStockTransfers(container) {
  const today = new Date();
  const from = new Date(today);
  from.setDate(from.getDate() - 30);
  container.innerHTML = `
    <div class="module-page transfer-workspace">
      ${CrmUi.renderPageHeader(
        'Transferencias',
        'Acompanhe solicitacoes entre filiais vinculadas aos pedidos comerciais.',
        '',
        'Operacao'
      )}
      <section class="panel transfer-filter-panel">
        <div class="section-heading">
          <div><h3>Pesquisa operacional</h3><p>Filtre por pedido, cliente, produto, periodo ou situacao da movimentacao.</p></div>
        </div>
        <div class="field-grid transfer-filters">
          <label class="span-4">Pesquisar
            <input id="transferSearch" type="search" placeholder="Pedido, cliente, CNPJ, codigo ou produto">
          </label>
          <label class="span-2">De
            <input id="transferFrom" type="date" value="${formatDateInput(from)}">
          </label>
          <label class="span-2">Ate
            <input id="transferTo" type="date" value="${formatDateInput(today)}">
          </label>
          <label class="span-2">Status
            <select id="transferStatus">
              <option value="">Todos</option>
              ${stockTransferStatuses().map((status) => `<option value="${escapeHtml(status)}">${escapeHtml(formatStockTransferStatus(status))}</option>`).join('')}
            </select>
          </label>
          <div class="span-2 actions-row align-end">
            <button class="btn btn-primary" id="transferFilterButton" type="button">Filtrar</button>
          </div>
        </div>
        <p id="transferMessage" class="form-message" aria-live="polite"></p>
      </section>
      <section class="panel transfer-results" id="transferResults" aria-live="polite">${CrmUi.renderState('loading', 'Carregando transferencias', 'Consultando as solicitacoes do periodo selecionado.')}</section>
    </div>
  `;

  document.getElementById('transferFilterButton').addEventListener('click', loadStockTransfers);
  document.getElementById('transferSearch').addEventListener('keydown', (event) => {
    if (event.key === 'Enter') loadStockTransfers();
  });
  await loadStockTransfers();
}

async function loadStockTransfers() {
  const target = document.getElementById('transferResults');
  target.innerHTML = CrmUi.renderState('loading', 'Carregando transferencias', 'Consultando as solicitacoes do periodo selecionado.');
  try {
    const rows = await supabaseListStockTransferRequests(getStockTransferFilters());
    target.innerHTML = renderStockTransferResults(rows);
    bindStockTransferActions(rows);
  } catch (error) {
    target.innerHTML = CrmUi.renderState('error', 'Nao foi possivel carregar as transferencias', error.message);
  }
}

function getStockTransferFilters() {
  const from = document.getElementById('transferFrom').value;
  const to = document.getElementById('transferTo').value;
  return {
    term: document.getElementById('transferSearch').value.trim(),
    status: document.getElementById('transferStatus').value,
    from: from ? new Date(from + 'T00:00:00').toISOString() : null,
    to: to ? new Date(new Date(to + 'T00:00:00').getTime() + 24 * 60 * 60 * 1000).toISOString() : null
  };
}

function renderStockTransferResults(rows) {
  if (!rows.length) return CrmUi.renderState('empty', 'Nenhuma solicitacao encontrada', 'Ajuste o periodo, o status ou o termo pesquisado.');
  const pending = rows.filter((row) => row.status === 'PENDING').length;
  const totalQty = rows.reduce((sum, row) => sum + Number(row.requested_qty || 0), 0);
  return `
    <div class="cards transfer-metrics">
      <article class="metric-card"><span>Solicitacoes</span><strong>${rows.length}</strong></article>
      <article class="metric-card"><span>Pendentes</span><strong>${pending}</strong></article>
      <article class="metric-card"><span>Quantidade</span><strong>${formatTransferQty(totalQty)}</strong></article>
      <article class="metric-card"><span>Ultima</span><strong>${escapeHtml(rows[0].numero_pedido || '')}</strong></article>
    </div>
    <div class="section-heading transfer-result-heading">
      <div><h3>Solicitacoes encontradas</h3><p>${rows.length} ${rows.length === 1 ? 'movimentacao' : 'movimentacoes'} no periodo selecionado.</p></div>
    </div>
    <div class="table-wrap transfer-table-wrap">
      <table class="transfer-table">
        <thead>
          <tr>
            <th>Pedido</th><th>Cliente</th><th>Produto</th><th>Origem</th><th>Destino</th><th>Qtd.</th><th>Status</th><th>Observacao</th><th></th>
          </tr>
        </thead>
        <tbody>
          ${rows.map((row, index) => `
            <tr>
              <td><strong>${escapeHtml(row.numero_pedido || '')}</strong><small>${escapeHtml(formatDateTime(row.created_at))}</small></td>
              <td>${escapeHtml(row.cliente || '')}<small>${escapeHtml(formatCnpj(row.cnpj || ''))}</small></td>
              <td><strong>${escapeHtml(row.product_code || '')}</strong><small>${escapeHtml([row.product_description, row.product_brand].filter(Boolean).join(' | '))}</small></td>
              <td>${escapeHtml(row.source_branch_code || '')}<small>${escapeHtml(formatTransferQty(row.source_available_qty))} disp.</small></td>
              <td>${escapeHtml(row.target_branch_code || '')}<small>${escapeHtml(formatTransferQty(row.target_available_qty))} disp.</small></td>
              <td>${escapeHtml(formatTransferQty(row.requested_qty))}</td>
              <td><span class="status-pill">${escapeHtml(formatStockTransferStatus(row.status))}</span><small>${escapeHtml(formatDateTime(row.updated_at))}</small></td>
              <td><textarea data-transfer-notes="${index}" maxlength="500" placeholder="Ex.: aprovado com prioridade">${escapeHtml(row.notes || '')}</textarea></td>
              <td>
                <div class="actions-row compact-actions">
                  <select data-transfer-status="${index}">
                    ${stockTransferStatuses().map((status) => `<option value="${escapeHtml(status)}" ${status === row.status ? 'selected' : ''}>${escapeHtml(formatStockTransferStatus(status))}</option>`).join('')}
                  </select>
                  <button class="btn btn-secondary" type="button" data-transfer-save="${index}">Salvar</button>
                </div>
              </td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  `;
}

function bindStockTransferActions(rows) {
  document.querySelectorAll('[data-transfer-save]').forEach((button) => {
    button.addEventListener('click', async () => {
      const index = Number(button.dataset.transferSave);
      const row = rows[index];
      const select = document.querySelector(`[data-transfer-status="${index}"]`);
      const notes = document.querySelector(`[data-transfer-notes="${index}"]`);
      const message = document.getElementById('transferMessage');
      button.disabled = true;
      message.textContent = '';
      try {
        await supabaseUpdateStockTransferStatus(row.id, select.value, notes ? notes.value.trim() : null);
        message.style.color = 'var(--success)';
        message.textContent = 'Status atualizado.';
        await loadStockTransfers();
      } catch (error) {
        message.style.color = 'var(--accent)';
        message.textContent = error.message;
      } finally {
        button.disabled = false;
      }
    });
  });
}

function stockTransferStatuses() {
  return ['PENDING', 'APPROVED', 'IN_TRANSIT', 'RECEIVED', 'CANCELLED'];
}

function formatStockTransferStatus(status) {
  const labels = {
    PENDING: 'Pendente',
    APPROVED: 'Aprovada',
    IN_TRANSIT: 'Em transferencia',
    RECEIVED: 'Recebida',
    CANCELLED: 'Cancelada'
  };
  return labels[status] || status || '';
}

function formatTransferQty(value) {
  return Number(value || 0).toLocaleString('pt-BR', { maximumFractionDigits: 3 });
}
