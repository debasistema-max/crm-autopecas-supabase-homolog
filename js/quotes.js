let quoteItems = [];
let quoteClientSearchTimer = null;
let quoteSelectedProduct = null;
let quoteImportPreviewItems = [];
let quoteCreateSaved = false;

async function renderCreateQuotation(container) {
  quoteItems = [];
  quoteSelectedProduct = null;
  quoteCreateSaved = false;
  const companySettings = await loadCompanySettings();
  const branchLabel = formatCompanyBranchLabel(companySettings);
  container.innerHTML = `
    <section class="sap-document">
      <div class="sap-titlebar">
        <div class="sap-title"><span class="sap-title-icon">#</span><h2>Cotacao de venda</h2></div>
        <strong>No. Novo</strong>
      </div>
      <div class="sap-window">
        <section class="sap-section">
          <h3>Dados gerais</h3>
          <div class="sap-form-grid">
            <div class="sap-form-left">
              <label>Filial
                <select id="quoteBranch"><option>${escapeHtml(branchLabel)}</option></select>
              </label>
              <div class="sap-inline-fields">
                <label>Cliente | CPF/CNPJ
                  <input id="quoteClientSapCode" type="text" placeholder="Codigo SAP">
                </label>
                <button class="sap-mini-button" id="quoteClientSearchButton" type="button" title="Buscar cliente">&#128269;</button>
                <label>
                  <input id="quoteCnpj" type="text" placeholder="CNPJ">
                </label>
              </div>
              <label>Nome cliente<input id="quoteClient" type="text"></label>
              <label>Buscar cliente
                <span class="sap-search-field">
                  <input id="quoteClientSearch" type="search" placeholder="Codigo SAP, CNPJ, protocolo ou empresa">
                  <button class="sap-search-button" id="quoteClientSearchSubmitButton" type="button" title="Buscar cliente">&#128269;</button>
                </span>
              </label>
              <label>Pessoa de contato<input id="quotePhone" type="text"></label>
              <label>No Ref.Cli.<input id="quoteClientRef" type="text"></label>
              <label>Vendedor<input id="quoteSellerDisplay" type="text" value="${escapeHtml((getStoredSession() || {}).nome || '')}"></label>
              <label>Utilizacao principal<select id="quoteUsage"><option>Revenda</option><option>Consumo</option></select></label>
              <label>Faturamento<select id="quoteRegion"><option value="PR">01 - MATRIZ - PR</option><option value="SP">02 - FILIAL - SP</option></select></label>
              <input id="quoteBillingState" type="hidden">
              <label>Endereco<input id="quoteAddress" type="text"></label>
            </div>
            <div class="sap-form-right">
              <label>Status SAP<input type="text" value="Aberto" readonly></label>
              <label>Dt.Cotacao<input type="text" value="${formatDateInput(new Date())}" readonly></label>
              <label>Valido ate<input type="date" id="quoteValidUntil"></label>
              <label>Autorizacao SAP<input type="text" value="Sem status" readonly></label>
              <label>Autorizacao portal<input type="text" value="Sem status" readonly></label>
            </div>
          </div>
          <div id="quoteClientResults" class="sap-search-results">
            <div class="empty-state compact-state">Clientes aparecem aqui para preencher a cotacao.</div>
          </div>
        </section>

        <section class="sap-section sap-tabs-section">
          <div class="sap-tabs">
            <button class="is-active" type="button" data-sap-tab="items">Itens</button>
            <button type="button" data-sap-tab="freight">Frete / Pagamento</button>
          </div>
          <div class="sap-tab-panel" data-sap-panel="items">
            <div class="sap-tab-tools">
              <span class="fiscal-auto-indicator"><strong>✓</strong> Impostos calculados automaticamente pela rota</span>
              <span id="quoteCount">0 itens</span>
            </div>
            <div id="quoteItems" class="sap-items-wrap"></div>
            <div class="sap-bottom-grid">
              <div class="sap-add-item">
                <form id="quoteProductSearch" class="sap-add-form">
                  <label>Cod.Item / EAN
                    <input id="quoteProductTerm" type="search">
                  </label>
                  <label>Nome item
                    <input id="quoteProductNamePreview" type="text">
                  </label>
                  <label>Grupo
                    <select id="quoteProductGroupPreview"><option value=""></option></select>
                  </label>
                  <div class="actions-row sap-item-search-actions">
                    <button class="btn btn-primary" type="submit">Buscar</button>
                    <button class="btn btn-ghost" id="quoteImportItemsButton" type="button">Importar itens</button>
                  </div>
                  <div class="sap-stock-line" id="quoteProductStockLine" hidden>Disp. Venda: <strong>-</strong> / Pr.Unit.: <strong>-</strong></div>
                  <label id="quoteQuantityLabel" hidden>Quantidade
                    <input id="quoteAddQuantity" type="number" min="0" value="0">
                  </label>
                  <div class="actions-row sap-add-controls" id="quoteAddControls" hidden>
                    <button class="btn btn-primary" id="quoteAddSelectedProductButton" type="button">Adicionar</button>
                    <button class="btn btn-ghost" id="quoteClearProductButton" type="button">Limpar</button>
                  </div>
                </form>
                <div id="quoteSearchResults" class="sap-product-results"><div class="empty-state compact-state">Pesquise para adicionar itens a cotacao.</div></div>
              </div>
              <div class="sap-totals" id="quoteTotals"></div>
            </div>
          </div>
          <div class="sap-import-modal" id="quoteItemsImportModal" hidden>
            <div class="sap-import-dialog">
              <div class="panel-header">
                <div><h2>Importar itens</h2><p>Cole codigos com quantidade ou carregue um arquivo CSV/TXT.</p></div>
                <button class="btn btn-ghost" id="quoteCloseImportItemsButton" type="button">Fechar</button>
              </div>
              <label>Codigos e quantidades
                <textarea id="quoteImportItemsText" placeholder="7175526020;2&#10;711032201;4"></textarea>
              </label>
              <div class="actions-row">
                <button class="btn btn-secondary" id="quoteLoadImportItemsFileButton" type="button">Carregar arquivo</button>
                <button class="btn btn-primary" id="quotePreviewImportItemsButton" type="button">Verificar codigos</button>
                <button class="btn btn-primary" id="quoteApplyImportItemsButton" type="button" disabled>Importar quantidades</button>
                <input id="quoteImportItemsFile" type="file" accept=".csv,.txt" hidden>
              </div>
              <div id="quoteImportItemsPreview" class="sap-product-results">
                <div class="empty-state compact-state">A lista verificada aparece aqui.</div>
              </div>
            </div>
          </div>
          <div class="sap-tab-panel" data-sap-panel="freight" hidden>
            <div class="sap-freight-grid">
              <label>Tipo de envio
                <select id="quoteShippingType">
                  <option>PAGO DESTINATARIO</option>
                  <option>PAGO REMETENTE</option>
                  <option>RETIRA</option>
                </select>
              </label>
              <label>Codigo transportadora
                <span class="sap-search-field">
                  <input id="quoteCarrierSearch" type="search">
                  <button class="sap-search-button" id="quoteCarrierCodeSearchButton" type="button">...</button>
                </span>
              </label>
              <label>Nome transportadora
                <span class="sap-search-field">
                  <input id="quoteCarrier" type="text">
                  <button class="sap-search-button" id="quoteCarrierNameSearchButton" type="button">...</button>
                </span>
              </label>
              <label>Cond. de pagamento
                <select id="quoteTerm">
                  <option>30/40/50/60/70/80</option>
                  <option>28/35/42</option>
                  <option>30/60/90</option>
                  <option>A vista</option>
                </select>
              </label>
            </div>
            <input id="quoteCarrierCnpj" type="hidden">
            <input id="quoteCarrierAddress" type="hidden">
            <input id="quoteNotes" type="hidden">
            <div id="quoteCarrierResults" class="sap-search-results">
              <div class="empty-state compact-state">Transportadoras cadastradas aparecem aqui.</div>
            </div>
          </div>
        </section>
      </div>
      <div class="sap-footer-actions">
        <button class="btn btn-primary" id="saveQuoteButton" type="button">Salvar</button>
        <button class="btn btn-ghost" id="closeQuoteButton" type="button">Fechar</button>
        <p id="quoteMessage" class="form-message"></p>
      </div>
    </section>
  `;

  bindSapTabs(container);
  document.getElementById('quoteClientSearchButton').addEventListener('click', searchClientsForQuote);
  document.getElementById('quoteClientSearchSubmitButton').addEventListener('click', () => searchClientsForQuote({
    term: document.getElementById('quoteClientSearch').value
  }));
  document.getElementById('quoteClientSearch').addEventListener('keydown', async (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      await searchClientsForQuote({ term: event.target.value });
    }
  });
  ['quoteClientSearch', 'quoteClientSapCode', 'quoteCnpj', 'quoteClient'].forEach((id) => {
    document.getElementById(id).addEventListener('input', scheduleQuoteClientAutoSearch);
  });
  document.getElementById('quoteCarrierCodeSearchButton').addEventListener('click', searchCarriersForQuote);
  document.getElementById('quoteCarrierNameSearchButton').addEventListener('click', searchCarriersForQuote);
  document.getElementById('quoteCarrierSearch').addEventListener('keydown', async (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      await searchCarriersForQuote();
    }
  });
  document.getElementById('quoteCarrier').addEventListener('keydown', async (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      await searchCarriersForQuote();
    }
  });
  document.getElementById('quoteProductSearch').addEventListener('submit', async (event) => {
    event.preventDefault();
    quoteSelectedProduct = null;
    updateQuoteProductSelection(null);
    await searchProductsInto(document.getElementById('quoteSearchResults'), {
      termo: getQuoteProductSearchTerm(),
      grupo: document.getElementById('quoteProductGroupPreview').value,
      regiao: document.getElementById('quoteRegion').value
    }, selectProductForQuote);
  });
  document.getElementById('quoteRegion').addEventListener('change', () => {
    quoteItems = [];
    renderQuoteCart();
    document.getElementById('quoteSearchResults').innerHTML = '<div class="empty-state">Pesquise novamente para obter precos do estado selecionado.</div>';
  });
  document.getElementById('quoteUsage').addEventListener('change', () => {
    quoteItems = [];
    renderQuoteCart();
    document.getElementById('quoteSearchResults').innerHTML = '<div class="empty-state">Pesquise novamente para recalcular os impostos conforme a utilizacao.</div>';
  });
  document.getElementById('saveQuoteButton').addEventListener('click', saveCurrentQuote);
  document.getElementById('closeQuoteButton').addEventListener('click', () => {
    if (hasUnsavedQuoteDraft() && !window.confirm('Existem alteracoes nao salvas. Deseja sair?')) return;
    openModule('quoteReports');
  });
  document.getElementById('quoteAddSelectedProductButton').addEventListener('click', () => {
    if (!quoteSelectedProduct) return;
    addProductToQuote(quoteSelectedProduct);
    clearQuoteProductSelection();
  });
  document.getElementById('quoteClearProductButton').addEventListener('click', () => {
    clearQuoteProductSelection();
  });
  document.getElementById('quoteImportItemsButton').addEventListener('click', () => {
    openQuoteItemsImportModal();
  });
  document.getElementById('quoteCloseImportItemsButton').addEventListener('click', closeQuoteItemsImportModal);
  document.getElementById('quoteLoadImportItemsFileButton').addEventListener('click', () => {
    document.getElementById('quoteImportItemsFile').click();
  });
  document.getElementById('quotePreviewImportItemsButton').addEventListener('click', previewQuoteImportItems);
  document.getElementById('quoteApplyImportItemsButton').addEventListener('click', applyQuoteImportItems);
  document.getElementById('quoteImportItemsFile').addEventListener('change', loadQuoteItemsImportFile);
  renderQuoteCart();
}

function applyQuoteDraft(draft) {
  if (!draft) return;
  document.getElementById('quoteRegion').value = draft.regiao || 'PR';
  document.getElementById('quoteUsage').value = /^consumo$/i.test(draft.customer_type || draft.tipo_cliente || '') ? 'Consumo' : 'Revenda';
  document.getElementById('quoteBillingState').value = draft.estado || '';
  document.getElementById('quoteClientSapCode').value = draft.codigo_sap_cliente || '';
  document.getElementById('quoteCnpj').value = formatCnpj(draft.cnpj || '');
  document.getElementById('quoteClient').value = draft.cliente || '';
  document.getElementById('quotePhone').value = draft.telefone || '';
  document.getElementById('quoteAddress').value = draft.endereco || '';
  document.getElementById('quoteTerm').value = draft.prazo || document.getElementById('quoteTerm').value;
  document.getElementById('quoteCarrier').value = draft.transportadora || '';
  document.getElementById('quoteCarrierCnpj').value = draft.transportadora_cnpj || '';
  document.getElementById('quoteCarrierAddress').value = draft.transportadora_endereco || '';
  document.getElementById('quoteNotes').value = draft.observacao || '';
  quoteItems = (draft.items || []).map((item) => Object.assign({}, item));
  quoteCreateSaved = false;
  renderQuoteCart();
  const message = document.getElementById('quoteMessage');
  if (message) {
    message.style.color = 'var(--success)';
    message.textContent = 'Rascunho carregado. Revise e salve para gerar uma nova cotacao.';
  }
}

function getQuoteProductSearchTerm() {
  return [
    document.getElementById('quoteProductTerm').value,
    document.getElementById('quoteProductNamePreview').value
  ].filter(Boolean).join(' ').trim();
}

function setQuoteProductGroup(value) {
  const select = document.getElementById('quoteProductGroupPreview');
  const group = value || '';
  select.innerHTML = group
    ? `<option value="${escapeHtml(group)}">${escapeHtml(group)}</option>`
    : '<option value=""></option>';
  select.value = group;
}

function updateQuoteProductSelection(product) {
  const hasProduct = Boolean(product);
  document.getElementById('quoteProductStockLine').hidden = !hasProduct;
  document.getElementById('quoteQuantityLabel').hidden = !hasProduct;
  document.getElementById('quoteAddControls').hidden = !hasProduct;
  if (!hasProduct) {
    document.getElementById('quoteProductStockLine').innerHTML = 'Disp. Venda: <strong>-</strong> / Pr.Unit.: <strong>-</strong>';
    return;
  }
  document.getElementById('quoteProductTerm').value = product.codigo || '';
  document.getElementById('quoteProductNamePreview').value = product.descricao || '';
  setQuoteProductGroup(product.grupo || product.linha || product.categoria || '');
  document.getElementById('quoteProductStockLine').innerHTML = 'Disp. Venda: <strong>' + escapeHtml(product.estoque || '0') + '</strong> / Pr.Unit.: <strong>' + money(Number(product.preco || 0)) + '</strong>';
  document.getElementById('quoteAddQuantity').value = 0;
}

function selectProductForQuote(product) {
  quoteSelectedProduct = product;
  updateQuoteProductSelection(product);
}

function clearQuoteProductSelection() {
  quoteSelectedProduct = null;
  document.getElementById('quoteProductTerm').value = '';
  document.getElementById('quoteProductNamePreview').value = '';
  setQuoteProductGroup('');
  document.getElementById('quoteSearchResults').innerHTML = '<div class="empty-state compact-state">Pesquise para adicionar itens a cotacao.</div>';
  updateQuoteProductSelection(null);
}

function addProductToQuote(product, forcedQuantity = null) {
  quoteCreateSaved = false;
  const existing = quoteItems.find((item) => item.codigo === product.codigo);
  const qtyInput = document.getElementById('quoteAddQuantity');
  const quantity = Number(forcedQuantity !== null ? forcedQuantity : (qtyInput ? qtyInput.value || 0 : 0));
  if (quantity <= 0) {
    if (qtyInput) qtyInput.focus();
    const message = document.getElementById('quoteMessage');
    if (message) {
      message.style.color = 'var(--accent)';
      message.textContent = 'Informe uma quantidade maior que zero.';
    }
    return;
  }
  if (existing) {
    existing.quantidade += quantity;
  } else {
    const item = {
      codigo: product.codigo,
      descricao: product.descricao,
      marca: product.marca,
      aplicacao: product.aplicacao,
      ncm: product.ncm || '',
      preco_sem_imposto: Number(product.preco_sem_imposto || 0),
      preco: Number(product.preco || 0),
      quantidade: quantity,
      desconto_percentual: 0,
      fiscal_status: 'CALCULANDO'
    };
    quoteItems.push(item);
    hydrateQuoteItemCommercialPrice(item);
  }
  renderQuoteCart();
}

async function hydrateQuoteItemCommercialPrice(item) {
  try {
    const origin = document.getElementById('quoteRegion')?.value || 'PR';
    const destination = document.getElementById('quoteBillingState')?.value || origin;
    const customerType = document.getElementById('quoteUsage')?.value || 'Revenda';
    const result = await supabaseGetProductCommercialPrice(item.codigo, origin, destination, customerType);
    item.fiscal_status = result.status;
    item.preco_sem_imposto = Number(result.base_price || 0);
    item.tributos = Number(result.total_taxes || 0) + Number(result.total_expenses || 0);
    if (result.final_price != null) item.preco = Number(result.final_price);
    item.fiscal_details = result;
    item.commercial_availability = result.availability;
    item.commercial_available_qty = result.source_display_value || result.available_qty;
    item.fiscal_warnings = result.warnings || [];
  } catch (error) {
    item.fiscal_status = 'FALHA_CALCULO'; item.fiscal_warnings = [error.message || 'Falha no motor fiscal'];
  }
  renderQuoteCart();
}

function openQuoteItemsImportModal() {
  document.getElementById('quoteItemsImportModal').hidden = false;
}

function closeQuoteItemsImportModal() {
  document.getElementById('quoteItemsImportModal').hidden = true;
}

async function loadQuoteItemsImportFile(event) {
  const file = event.target.files && event.target.files[0];
  event.target.value = '';
  if (!file) return;
  document.getElementById('quoteImportItemsText').value = await file.text();
  await previewQuoteImportItems();
}

async function previewQuoteImportItems() {
  const target = document.getElementById('quoteImportItemsPreview');
  const applyButton = document.getElementById('quoteApplyImportItemsButton');
  const parsed = parseImportItemsText(document.getElementById('quoteImportItemsText').value);
  quoteImportPreviewItems = [];
  applyButton.disabled = true;
  if (!parsed.length) {
    target.innerHTML = '<div class="empty-state compact-state">Informe ao menos um codigo.</div>';
    return;
  }
  target.innerHTML = '<div class="empty-state compact-state">Verificando codigos...</div>';
  try {
    for (const item of parsed) {
      const code = item.code;
      const products = await supabaseSearchProducts({ termo: code, regiao: document.getElementById('quoteRegion').value, limite: 10 });
      const product = products.find((item) => String(item.codigo) === code) || products[0];
      quoteImportPreviewItems.push({ code, quantity: item.quantity, product });
    }
    target.innerHTML = renderQuoteImportItemsPreview();
    bindQuoteImportPreviewEvents();
    applyButton.disabled = !quoteImportPreviewItems.some((item) => item.product);
  } catch (error) {
    target.innerHTML = `<div class="empty-state compact-state">${escapeHtml(error.message)}</div>`;
  }
}

function bindQuoteImportPreviewEvents() {
  const target = document.getElementById('quoteImportItemsPreview');
  target.querySelectorAll('[data-quote-import-qty]').forEach((input) => {
    input.addEventListener('change', () => {
      quoteImportPreviewItems[Number(input.dataset.quoteImportQty)].quantity = Math.max(1, Number(input.value || 1));
      target.innerHTML = renderQuoteImportItemsPreview();
      bindQuoteImportPreviewEvents();
    });
  });
  target.querySelectorAll('[data-quote-import-remove]').forEach((button) => {
    button.addEventListener('click', () => {
      quoteImportPreviewItems.splice(Number(button.dataset.quoteImportRemove), 1);
      target.innerHTML = renderQuoteImportItemsPreview();
      bindQuoteImportPreviewEvents();
      document.getElementById('quoteApplyImportItemsButton').disabled = !quoteImportPreviewItems.some((item) => item.product);
    });
  });
}

function renderQuoteImportItemsPreview() {
  const found = quoteImportPreviewItems.filter((item) => item.product);
  const missing = quoteImportPreviewItems.length - found.length;
  const totalQty = found.reduce((sum, item) => sum + Number(item.quantity || 0), 0);
  const subtotal = found.reduce((sum, item) => sum + Number(item.quantity || 0) * Number(item.product.preco || 0), 0);
  return `
    <div class="import-summary">
      <article><span>Encontrados</span><strong>${found.length}</strong></article>
      <article><span>Nao encontrados</span><strong>${missing}</strong></article>
      <article><span>Quantidade</span><strong>${totalQty}</strong></article>
      <article><span>Subtotal previsto</span><strong>${money(subtotal)}</strong></article>
    </div>
    <div class="table-wrap compact-table">
      <table>
        <thead><tr><th>Status</th><th>Codigo</th><th>Produto encontrado</th><th>Estoque</th><th>Preco</th><th>Quantidade</th><th></th></tr></thead>
        <tbody>
          ${quoteImportPreviewItems.map((item, index) => `
            <tr>
              <td>${item.product ? 'OK' : 'Nao encontrado'}</td>
              <td>${escapeHtml(item.code)}</td>
              <td>${item.product ? escapeHtml(item.product.descricao || '') : '<strong>Nao encontrado</strong>'}</td>
              <td>${item.product ? escapeHtml(item.product.estoque || '0') : '-'}</td>
              <td>${item.product ? money(Number(item.product.preco || 0)) : '-'}</td>
              <td><input type="number" min="1" value="${escapeHtml(item.quantity)}" data-quote-import-qty="${index}" ${item.product ? '' : 'disabled'}></td>
              <td><button class="sap-remove-button" type="button" data-quote-import-remove="${index}" title="Remover">-</button></td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  `;
}

function applyQuoteImportItems() {
  let added = 0;
  quoteImportPreviewItems.forEach((item) => {
    if (!item.product) return;
    addProductToQuote(item.product, item.quantity);
    added += 1;
  });
  document.getElementById('quoteSearchResults').innerHTML = '<div class="empty-state compact-state">' + added + ' itens importados para a cotacao.</div>';
  closeQuoteItemsImportModal();
}

function renderQuoteCart() {
  const list = document.getElementById('quoteItems');
  const count = document.getElementById('quoteCount');
  const totals = document.getElementById('quoteTotals');
  count.textContent = quoteItems.length + (quoteItems.length === 1 ? ' item' : ' itens');
  const subtotal = quoteItems.reduce((sum, item) => sum + item.preco * item.quantidade, 0);
  const total = quoteItems.reduce((sum, item) => sum + item.preco * item.quantidade * (1 - item.desconto_percentual / 100), 0);
  const discount = subtotal - total;
  if (!quoteItems.length) {
    list.className = 'sap-items-wrap';
    list.innerHTML = renderSapQuoteItemsTable([]);
    totals.innerHTML = renderSapTotals(0, 0, 0);
    return;
  }
  list.className = 'sap-items-wrap';
  list.innerHTML = renderSapQuoteItemsTable(quoteItems);
  list.querySelectorAll('[data-quote-qty]').forEach((input) => {
    input.addEventListener('change', () => {
      quoteItems[Number(input.dataset.quoteQty)].quantidade = Math.max(1, Number(input.value || 1));
      renderQuoteCart();
    });
  });
  list.querySelectorAll('[data-quote-discount]').forEach((input) => {
    input.addEventListener('change', () => {
      quoteItems[Number(input.dataset.quoteDiscount)].desconto_percentual = Math.max(0, Number(input.value || 0));
      renderQuoteCart();
    });
  });
  list.querySelectorAll('[data-quote-remove]').forEach((button) => {
    button.addEventListener('click', () => {
      quoteItems.splice(Number(button.dataset.quoteRemove), 1);
      renderQuoteCart();
    });
  });
  totals.innerHTML = renderSapTotals(subtotal, discount, total);
}

function renderSapQuoteItemsTable(items) {
  const totalQty = items.reduce((sum, item) => sum + Number(item.quantidade || 0), 0);
  const subtotal = items.reduce((sum, item) => sum + item.preco * item.quantidade, 0);
  const total = items.reduce((sum, item) => sum + item.preco * item.quantidade * (1 - item.desconto_percentual / 100), 0);
  const rows = items.length ? items.map((item, index) => {
    const finalUnit = item.preco * (1 - item.desconto_percentual / 100);
    const rowTotal = finalUnit * item.quantidade;
    return `
      <tr>
        <td>${index + 1}</td>
        <td class="sap-code">${escapeHtml(item.codigo)}</td>
        <td>${escapeHtml(item.descricao || '')}
          <small>Base: ${money(item.preco_sem_imposto || 0)} · Tributos: ${money(item.tributos || 0)} · Estoque: ${escapeHtml(item.commercial_availability || '—')} ${escapeHtml(item.commercial_available_qty || '')}</small>
          <small class="fiscal-breakdown">${escapeHtml(formatFiscalBreakdown(item.fiscal_details))}</small>
          <small class="fiscal-inline-status">${escapeHtml(formatFiscalStatus(item.fiscal_status))}</small>
          ${item.fiscal_warnings?.length ? `<small class="fiscal-warning">${escapeHtml(formatFiscalWarnings(item.fiscal_warnings))}</small>` : ''}</td>
        <td>${escapeHtml(item.marca || '')}</td>
        <td>${escapeHtml(item.aplicacao || '')}</td>
        <td>UN</td>
        <td><input type="number" min="1" value="${escapeHtml(item.quantidade)}" data-quote-qty="${index}"></td>
        <td>${money(item.preco)}</td>
        <td><input type="number" min="0" step="0.01" value="${escapeHtml(item.desconto_percentual)}" data-quote-discount="${index}"></td>
        <td>${money(finalUnit)}</td>
        <td>${money(rowTotal)}</td>
        <td>${money(rowTotal)}</td>
        <td><button class="sap-remove-button" type="button" data-quote-remove="${index}" title="Remover">-</button></td>
      </tr>
    `;
  }).join('') : '<tr><td colspan="13" class="sap-empty-row">Nenhum item adicionado.</td></tr>';
  return `
    <table class="sap-items-table">
      <thead>
        <tr>
          <th>#</th><th>Cod.</th><th>Descricao</th><th>Marca</th><th>Aplicacao</th><th>UM</th><th>Qtde</th>
          <th>Pr.Unit.</th><th>% do desc.</th><th>Pr.Apos Desc.</th><th>Total Apos Desc.</th><th>Total c/ Imp.</th><th></th>
        </tr>
      </thead>
      <tbody>${rows}</tbody>
      <tfoot>
        <tr>
          <td colspan="6">Totais:</td><td>${totalQty}</td><td></td><td></td><td></td><td>${money(total)}</td><td>${money(subtotal)}</td><td></td>
        </tr>
      </tfoot>
    </table>
  `;
}

async function saveCurrentQuote() {
  const message = document.getElementById('quoteMessage');
  const button = document.getElementById('saveQuoteButton');
  message.textContent = '';
  button.disabled = true;
  button.textContent = 'Salvando...';
  try {
    const payload = {
      sessionId: getSessionId(),
      regiao: document.getElementById('quoteRegion').value,
      cliente_estado: document.getElementById('quoteBillingState').value,
      customer_type: document.getElementById('quoteUsage').value.toUpperCase(),
      codigo_sap_cliente: document.getElementById('quoteClientSapCode').value,
      cliente: document.getElementById('quoteClient').value,
      cnpj: document.getElementById('quoteCnpj').value,
      telefone: document.getElementById('quotePhone').value,
      endereco: document.getElementById('quoteAddress').value,
      prazo: document.getElementById('quoteTerm').value,
      transportadora: document.getElementById('quoteCarrier').value,
      transportadora_cnpj: document.getElementById('quoteCarrierCnpj').value,
      transportadora_endereco: document.getElementById('quoteCarrierAddress').value,
      observacao: document.getElementById('quoteNotes').value,
      items: quoteItems
    };
    validateCommercialDocument(payload, 'a cotacao');
    const data = await supabaseCreateQuotation(payload);
    quoteItems = [];
    quoteCreateSaved = true;
    renderQuoteCart();
    message.style.color = 'var(--success)';
    message.textContent = 'Cotacao ' + data.numero_cotacao + ' salva com sucesso.' + formatFiscalSaveSummary(data.fiscal);
  } catch (error) {
    message.style.color = 'var(--accent)';
    message.textContent = error.message;
  } finally {
    button.disabled = false;
    button.textContent = 'Salvar';
  }
}

function hasUnsavedQuoteDraft() {
  if (quoteCreateSaved) return false;
  const fields = [
    'quoteClientSapCode',
    'quoteCnpj',
    'quoteClient',
    'quoteClientSearch',
    'quotePhone',
    'quoteClientRef',
    'quoteAddress',
    'quoteCarrierSearch',
    'quoteCarrier',
    'quoteNotes'
  ];
  return quoteItems.length > 0 || fields.some((id) => {
    const field = document.getElementById(id);
    return field && String(field.value || '').trim();
  });
}

function getQuoteClientSearchTerm(sourceId) {
  if (sourceId) return (document.getElementById(sourceId) || {}).value || '';
  return [
    'quoteClientSearch',
    'quoteClientSapCode',
    'quoteCnpj',
    'quoteClient'
  ].map((id) => (document.getElementById(id) || {}).value || '').find((value) => String(value).trim()) || '';
}

function scheduleQuoteClientAutoSearch(event) {
  const term = getQuoteClientSearchTerm(event.target.id);
  window.clearTimeout(quoteClientSearchTimer);
  if (!isClientLookupReady(term)) return;
  quoteClientSearchTimer = window.setTimeout(() => {
    searchClientsForQuote({ term, auto: true });
  }, 450);
}

async function searchClientsForQuote(options = {}) {
  const target = document.getElementById('quoteClientResults');
  const term = options.term !== undefined ? options.term : getQuoteClientSearchTerm();
  if (!isClientLookupReady(term)) {
    target.innerHTML = '<div class="empty-state compact-state">Digite pelo menos 3 caracteres ou CNPJ/codigo para buscar.</div>';
    return;
  }
  target.innerHTML = '<div class="empty-state compact-state">Buscando clientes...</div>';
  try {
    const rows = await supabaseSearchOrderClients(term);
    const exact = findExactClientMatch(rows, term);
    if (exact) {
      applyClientToQuote(exact);
      target.innerHTML = '<div class="empty-state compact-state">Cliente encontrado e carregado automaticamente.</div>';
      return;
    }
    target.innerHTML = renderQuoteClientsResults(rows);
    target.querySelectorAll('[data-use-quote-client]').forEach((button) => {
      button.addEventListener('click', () => applyClientToQuote(rows[Number(button.dataset.useQuoteClient)]));
    });
  } catch (error) {
    target.innerHTML = `<div class="empty-state compact-state">${escapeHtml(error.message)}</div>`;
  }
}

function renderQuoteClientsResults(rows) {
  if (!rows.length) return '<div class="empty-state compact-state">Nenhum cliente encontrado.</div>';
  return `
    <div class="table-wrap compact-table">
      <table>
        <thead><tr><th>Empresa</th><th>CNPJ</th><th>Codigo SAP</th><th>Origem</th><th></th></tr></thead>
        <tbody>
          ${rows.map((row, index) => `
            <tr>
              <td><strong>${escapeHtml(row.razao_social || row.nome_fantasia || '')}</strong><small>${escapeHtml([row.protocolo, row.cidade, row.estado].filter(Boolean).join(' | '))}</small></td>
              <td>${escapeHtml(formatCnpj(row.cnpj || ''))}</td>
              <td>${escapeHtml(row.codigo_sap_cliente || '')}</td>
              <td>${escapeHtml(row.origem === 'cliente' ? 'CRM' : 'Portal')}</td>
              <td><button class="btn btn-secondary" type="button" data-use-quote-client="${index}">Usar</button></td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  `;
}

function applyClientToQuote(row) {
  document.getElementById('quoteClientSapCode').value = row.codigo_sap_cliente || '';
  document.getElementById('quoteClient').value = row.razao_social || row.nome_fantasia || '';
  document.getElementById('quoteCnpj').value = formatCnpj(row.cnpj || '');
  document.getElementById('quotePhone').value = row.whatsapp || row.telefone || '';
  document.getElementById('quoteAddress').value = formatCadastroAddress(row);
  document.getElementById('quoteTerm').value = row.prazo_desejado || '';
  const billingChanged = applyBillingRegionToQuote(row.estado);
  const message = document.getElementById('quoteMessage');
  message.style.color = 'var(--success)';
  message.textContent = 'Cliente carregado na cotacao. Faturamento: ' + getBillingBranchLabel(document.getElementById('quoteRegion').value) + '.' + (billingChanged ? ' Itens removidos para recalcular valores.' : '');
}

function applyBillingRegionToQuote(uf) {
  const regionSelect = document.getElementById('quoteRegion');
  const stateInput = document.getElementById('quoteBillingState');
  const nextRegion = getBillingRegionForUf(uf, regionSelect.value);
  const changed = regionSelect.value !== nextRegion;
  stateInput.value = normalizeBillingUf(uf);
  regionSelect.value = nextRegion;
  if (changed && quoteItems.length) {
    quoteItems = [];
    renderQuoteCart();
  }
  return changed;
}

async function searchCarriersForQuote() {
  const target = document.getElementById('quoteCarrierResults');
  target.innerHTML = '<div class="empty-state compact-state">Buscando transportadoras...</div>';
  try {
    const term = document.getElementById('quoteCarrierSearch').value || document.getElementById('quoteCarrier').value;
    const rows = await supabaseSearchOrderCarriers(term);
    target.innerHTML = renderQuoteCarriersResults(rows);
    target.querySelectorAll('[data-use-quote-carrier]').forEach((button) => {
      button.addEventListener('click', () => applyCarrierToQuote(rows[Number(button.dataset.useQuoteCarrier)]));
    });
  } catch (error) {
    target.innerHTML = `<div class="empty-state compact-state">${escapeHtml(error.message)}</div>`;
  }
}

function renderQuoteCarriersResults(rows) {
  if (!rows.length) return '<div class="empty-state compact-state">Nenhuma transportadora encontrada.</div>';
  return `
    <div class="table-wrap compact-table">
      <table>
        <thead><tr><th>Transportadora</th><th>CNPJ</th><th>Cidade/UF</th><th></th></tr></thead>
        <tbody>
          ${rows.map((row, index) => `
            <tr>
              <td><strong>${escapeHtml(row.nome || '')}</strong><small>${escapeHtml(row.endereco || '')}</small></td>
              <td>${escapeHtml(formatCnpj(row.cnpj || ''))}</td>
              <td>${escapeHtml([row.cidade, row.estado].filter(Boolean).join('/'))}</td>
              <td><button class="btn btn-secondary" type="button" data-use-quote-carrier="${index}">Usar</button></td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  `;
}

function applyCarrierToQuote(row) {
  document.getElementById('quoteCarrier').value = row.nome || '';
  document.getElementById('quoteCarrierCnpj').value = formatCnpj(row.cnpj || '');
  document.getElementById('quoteCarrierAddress').value = formatCarrierAddress(row);
  const message = document.getElementById('quoteMessage');
  message.style.color = 'var(--success)';
  message.textContent = 'Transportadora carregada na cotacao.';
}

async function renderQuotationsReport(container, options = {}) {
  container.innerHTML = renderDocumentReportShell('cotacoes');
  bindDocumentReport('cotacoes');
  if (options.action === 'create') {
    await openDocumentCreateScreen('cotacoes');
    return;
  }
  await loadDocumentReport('cotacoes');
}

async function renderOrdersReport(container, options = {}) {
  container.innerHTML = renderDocumentReportShell('pedidos');
  bindDocumentReport('pedidos');
  if (options.action === 'create') {
    await openDocumentCreateScreen('pedidos');
    return;
  }
  await loadDocumentReport('pedidos');
}

function renderDocumentReportShell(kind) {
  const title = kind === 'pedidos' ? 'Pedidos' : 'Cotacoes';
  const numberLabel = kind === 'pedidos' ? 'Pedido' : 'Cotacao';
  const createPermission = kind === 'pedidos' ? 'novo_pedido' : 'nova_cotacao';
  const reportPermission = kind === 'pedidos' ? 'pedidos' : 'cotacoes';
  const createLabel = kind === 'pedidos' ? 'Novo pedido' : 'Nova cotacao';
  const canCreate = userHasModulePermission(createPermission);
  const canReport = userHasModulePermission(reportPermission);
  const today = new Date();
  const from = new Date(today);
  from.setDate(from.getDate() - 30);
  return `
    <section class="panel">
      <div class="panel-header">
        <div>
          <h2>${title}</h2>
          <p>Relatorio de ${title.toLowerCase()} por periodo, cliente, vendedor e status.</p>
        </div>
        ${canCreate ? `<button class="btn btn-primary" id="${kind}NewButton" type="button">${createLabel}</button>` : ''}
      </div>
      ${canReport ? `<div class="field-grid">
        <label class="span-4">Pesquisar
          <input id="${kind}Search" placeholder="${numberLabel}, cliente, CNPJ, SAP ou vendedor">
        </label>
        <label class="span-2">De
          <input id="${kind}From" type="date" value="${formatDateInput(from)}">
        </label>
        <label class="span-2">Ate
          <input id="${kind}To" type="date" value="${formatDateInput(today)}">
        </label>
        <label class="span-2">Status
          <select id="${kind}Status">
            <option value="">Todos</option>
            ${documentStatusOptions(kind).map((status) => `<option value="${escapeHtml(status)}">${escapeHtml(status)}</option>`).join('')}
          </select>
        </label>
        <div class="span-2 actions-row align-end">
          <button class="btn btn-primary" id="${kind}FilterButton" type="button">Filtrar</button>
        </div>
      </div>
      <div class="actions-row" style="margin-top: 12px;">
        <button class="btn btn-secondary" id="${kind}ExportButton" type="button">Baixar CSV</button>
        <p id="${kind}Message" class="form-message"></p>
      </div>` : `<p id="${kind}Message" class="form-message">Use o botao ${createLabel} para criar um novo documento.</p>`}
    </section>
    <section class="panel" id="${kind}EditPanel" hidden></section>
    <section class="panel" id="${kind}Results">${canReport ? `<div class="empty-state">Carregando ${title.toLowerCase()}...</div>` : `<div class="empty-state">Voce nao tem permissao para consultar o relatorio de ${title.toLowerCase()}.</div>`}</section>
  `;
}

function bindDocumentReport(kind) {
  const newButton = document.getElementById(`${kind}NewButton`);
  if (newButton) {
    newButton.addEventListener('click', () => openDocumentCreateScreen(kind));
  }
  const filterButton = document.getElementById(`${kind}FilterButton`);
  const exportButton = document.getElementById(`${kind}ExportButton`);
  const searchInput = document.getElementById(`${kind}Search`);
  if (filterButton) filterButton.addEventListener('click', () => loadDocumentReport(kind));
  if (exportButton) exportButton.addEventListener('click', () => exportDocumentReport(kind));
  if (searchInput) {
    searchInput.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') loadDocumentReport(kind);
    });
  }
}

function userHasModulePermission(permission) {
  const session = getStoredSession() || {};
  if (String(session.perfil || '').toUpperCase() === 'ADMIN') return true;
  const modules = Array.isArray(session.modules) ? session.modules : [];
  return modules.includes(permission);
}

async function openDocumentCreateScreen(kind) {
  const content = document.getElementById('content');
  document.getElementById('pageTitle').textContent = kind === 'pedidos' ? 'Novo Pedido' : 'Nova Cotacao';
  if (kind === 'pedidos') {
    await renderOrders(content);
    applyOrderDraft(window.pendingOrderDraft || null);
    window.pendingOrderDraft = null;
  } else {
    await renderCreateQuotation(content);
    applyQuoteDraft(window.pendingQuoteDraft || null);
    window.pendingQuoteDraft = null;
  }
  content.focus();
}

async function loadDocumentReport(kind) {
  const target = document.getElementById(`${kind}Results`);
  const reportPermission = kind === 'pedidos' ? 'pedidos' : 'cotacoes';
  if (!userHasModulePermission(reportPermission)) {
    target.innerHTML = `<div class="empty-state">Voce nao tem permissao para consultar este relatorio.</div>`;
    return;
  }
  target.innerHTML = '<div class="empty-state">Carregando relatorio...</div>';
  try {
    const filters = getDocumentFilters(kind);
    const rows = kind === 'pedidos'
      ? await supabaseListOrdersReport(filters)
      : await supabaseListQuotationsReport(filters);
    window[`${kind}LastRows`] = rows;
    target.innerHTML = renderDocumentReport(kind, rows);
    bindDocumentEditButtons(kind, rows);
  } catch (error) {
    target.innerHTML = `<div class="empty-state">${escapeHtml(error.message)}</div>`;
  }
}

function renderDocumentReport(kind, rows) {
  if (!rows.length) return '<div class="empty-state">Nenhum registro encontrado.</div>';
  const numberKey = kind === 'pedidos' ? 'numero_pedido' : 'numero_cotacao';
  const total = rows.reduce((sum, row) => sum + Number(row.total || 0), 0);
  return `
    <div class="cards" style="margin-bottom: 16px;">
      <article class="metric-card"><span>Registros</span><strong>${rows.length}</strong></article>
      <article class="metric-card"><span>Total</span><strong>${money(total)}</strong></article>
      <article class="metric-card"><span>Ticket medio</span><strong>${money(total / rows.length)}</strong></article>
      <article class="metric-card"><span>Ultimo</span><strong>${escapeHtml(rows[0][numberKey] || '')}</strong></article>
    </div>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Numero</th><th>Data</th><th>Cliente</th><th>SAP</th><th>Vendedor</th><th>Status</th>${kind === 'pedidos' ? '<th>Transferencia</th>' : ''}<th>Total</th><th></th>
          </tr>
        </thead>
        <tbody>
          ${rows.map((row, index) => `
            <tr>
              <td><strong>${escapeHtml(row[numberKey] || '')}</strong><small>${escapeHtml(row.regiao || '')}</small></td>
              <td>${escapeHtml(formatDateTime(row.created_at || row.data_hora))}</td>
              <td>${escapeHtml(row.cliente || '')}<small>${escapeHtml(formatCnpj(row.cnpj || ''))}</small></td>
              <td>${escapeHtml(row.codigo_sap_cliente || '')}</td>
              <td>${escapeHtml(row.vendedor || '')}</td>
              <td><span class="status-pill">${escapeHtml(formatDocumentStatus(kind, row.status))}</span></td>
              ${kind === 'pedidos' ? `<td>${renderOrderTransferBadge(row.transfer_summary)}</td>` : ''}
              <td>${money(row.total)}</td>
              <td>
                <div class="actions-row compact-actions">
                  <button class="btn btn-secondary" type="button" data-edit-document="${index}">Abrir</button>
                  <button class="btn btn-ghost" type="button" data-duplicate-document="${index}">Duplicar</button>
                  ${kind === 'cotacoes' ? `<button class="btn btn-primary" type="button" data-convert-quotation="${index}">Converter</button>` : ''}
                </div>
              </td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  `;
}

function renderOrderTransferBadge(summary) {
  if (!summary || !Number(summary.total || 0)) return '<span class="muted">-</span>';
  const pending = Number(summary.pending || 0);
  const inTransit = Number(summary.in_transit || 0);
  const received = Number(summary.received || 0);
  let label = `${Number(summary.total || 0)} solic.`;
  if (pending) label = `${pending} pend.`;
  else if (inTransit) label = `${inTransit} em trans.`;
  else if (received) label = `${received} receb.`;
  return `<span class="status-pill">${escapeHtml(label)}</span>`;
}

function bindDocumentEditButtons(kind, rows) {
  document.querySelectorAll('[data-edit-document]').forEach((button) => {
    button.addEventListener('click', () => showDocumentEditForm(kind, rows[Number(button.dataset.editDocument)]));
  });
  document.querySelectorAll('[data-duplicate-document]').forEach((button) => {
    button.addEventListener('click', () => duplicateCommercialDocument(kind, rows[Number(button.dataset.duplicateDocument)]));
  });
  document.querySelectorAll('[data-convert-quotation]').forEach((button) => {
    button.addEventListener('click', () => convertQuotationFromReport(rows[Number(button.dataset.convertQuotation)], button));
  });
}

async function duplicateCommercialDocument(kind, row) {
  const draft = buildDocumentDraft(kind, row);
  if (kind === 'pedidos') {
    window.pendingOrderDraft = draft;
    await openDocumentCreateScreen('pedidos');
  } else {
    window.pendingQuoteDraft = draft;
    await openDocumentCreateScreen('cotacoes');
  }
}

async function convertQuotationFromReport(row, button) {
  if (!row || !row.id) return;
  if (row.status === 'CONVERTIDA') {
    const message = document.getElementById('cotacoesMessage');
    if (message) {
      message.style.color = 'var(--accent)';
      message.textContent = 'Esta cotacao ja foi convertida.';
    }
    return;
  }
  const message = document.getElementById('cotacoesMessage');
  if (button) button.disabled = true;
  if (message) {
    message.style.color = 'var(--muted)';
    message.textContent = 'Convertendo cotacao em pedido...';
  }
  try {
    const data = await supabaseConvertQuotationToOrder(row.id);
    if (message) {
      message.style.color = 'var(--success)';
      message.textContent = 'Cotacao convertida no pedido ' + (data.numero_pedido || '') + '.';
    }
    await loadDocumentReport('cotacoes');
  } catch (error) {
    if (message) {
      message.style.color = 'var(--accent)';
      message.textContent = error.message;
    }
  } finally {
    if (button) button.disabled = false;
  }
}

function buildDocumentDraft(kind, row) {
  const itemsKey = kind === 'pedidos' ? 'order_items' : 'quotation_items';
  return {
    regiao: row.regiao || 'SP',
    codigo_sap_cliente: row.codigo_sap_cliente || '',
    cliente: row.cliente || '',
    cnpj: row.cnpj || '',
    telefone: row.telefone || '',
    endereco: row.endereco || '',
    prazo: row.prazo || '',
    transportadora: row.transportadora || '',
    transportadora_cnpj: row.transportadora_cnpj || '',
    transportadora_endereco: row.transportadora_endereco || '',
    observacao: row.observacao || '',
    items: normalizeDocumentItems(row[itemsKey] || [])
  };
}

function showDocumentEditForm(kind, row) {
  const panel = document.getElementById(`${kind}EditPanel`);
  const numberKey = kind === 'pedidos' ? 'numero_pedido' : 'numero_cotacao';
  const itemsKey = kind === 'pedidos' ? 'order_items' : 'quotation_items';
  const title = kind === 'pedidos' ? 'Pedido de venda' : 'Cotacao de venda';
  const dateLabel = kind === 'pedidos' ? 'Dt.Pedido' : 'Dt.Cotacao';
  const regionValue = row.regiao === 'PR' ? '01 - MATRIZ - PR' : '02 - FILIAL - SP';
  const companySettings = cachedCompanySettings || DEFAULT_COMPANY_SETTINGS;
  const branchLabel = formatCompanyBranchLabel(companySettings);
  window[`${kind}EditingItems`] = normalizeDocumentItems(row[itemsKey] || []);
  window[`${kind}EditDirty`] = false;
  panel.hidden = false;
  panel.innerHTML = `
    <section class="sap-document">
      <div class="sap-titlebar">
        <div class="sap-title"><span class="sap-title-icon">#</span><h2>${title}</h2></div>
        <strong>No. ${escapeHtml(row[numberKey] || '')}</strong>
      </div>
      <div class="sap-window">
        <section class="sap-section">
          <h3>Dados gerais</h3>
          <div class="sap-form-grid">
            <div class="sap-form-left">
              <label>Filial<input type="text" value="${escapeHtml(branchLabel)}" readonly></label>
              <div class="sap-inline-fields">
                <label>Cliente | CPF/CNPJ
                  <input type="text" value="${escapeHtml(row.codigo_sap_cliente || '')}" readonly>
                </label>
                <label>
                  <input type="text" value="${escapeHtml(formatCnpj(row.cnpj || ''))}" readonly>
                </label>
              </div>
              <label>Nome cliente<input type="text" value="${escapeHtml(row.cliente || '')}" readonly></label>
              <label>Pessoa de contato<input type="text" value="${escapeHtml(row.telefone || '')}" readonly></label>
              <label>No Ref.Cli.<input type="text" value="" readonly></label>
              <label>Vendedor<input type="text" value="${escapeHtml(row.vendedor || '')}" readonly></label>
              <label>Utilizacao principal<input type="text" value="Revenda" readonly></label>
              <label>Deposito<input type="text" value="${escapeHtml(regionValue)}" readonly></label>
              <label>Endereco<input type="text" value="${escapeHtml(row.endereco || '')}" readonly></label>
            </div>
            <div class="sap-form-right">
              <label>Status SAP<input type="text" id="${kind}EditStatusDisplay" value="${escapeHtml(formatDocumentStatus(kind, row.status))}" readonly></label>
              <label>${dateLabel}<input type="text" value="${escapeHtml(formatDateTime(row.created_at || row.data_hora))}" readonly></label>
              <label>Valido ate<input type="text" value="" readonly></label>
              <label>Autorizacao SAP<input type="text" value="${escapeHtml(formatDocumentStatus(kind, row.status))}" readonly></label>
              <label>Autorizacao portal<input type="text" value="Sem status" readonly></label>
            </div>
          </div>
        </section>
        ${kind === 'pedidos' ? `<section class="sap-section" id="${kind}TransferPanel"><h3>Transferencias</h3><div class="empty-state compact-state">Carregando transferencias vinculadas...</div></section>` : ''}
        <section class="sap-section">
          <h3>Fiscal</h3>
          ${renderDocumentFiscalPanel(window[`${kind}EditingItems`] || [])}
        </section>
        <section class="sap-section sap-tabs-section">
          <div class="sap-tabs">
            <button class="is-active" type="button" data-sap-tab="edit-items">Itens</button>
            <button type="button" data-sap-tab="edit-freight">Frete / Pagamento</button>
          </div>
          <div class="sap-tab-panel" data-sap-panel="edit-items">
            <div class="sap-tab-tools">
              <span class="fiscal-auto-indicator"><strong>✓</strong> Impostos preservados no documento</span>
              <span id="${kind}EditCount">0 itens</span>
            </div>
            <div id="${kind}EditItems" class="sap-items-wrap"></div>
            <div class="sap-bottom-grid">
              <div class="sap-add-item">
                <div class="sap-add-form">
                  <label>Cod.Item / EAN
                    <input id="${kind}EditProductTerm" type="search">
                  </label>
                  <label>Nome item
                    <input id="${kind}EditProductNamePreview" type="text">
                  </label>
                  <label>Grupo
                    <input id="${kind}EditProductGroupPreview" type="text" readonly>
                  </label>
                  <div class="actions-row sap-item-search-actions">
                    <button class="btn btn-primary" id="${kind}EditProductSearchButton" type="button">Buscar</button>
                  </div>
                </div>
                <div id="${kind}EditProductResults" class="sap-product-results">
                  <div class="empty-state compact-state">Pesquise para adicionar novos itens.</div>
                </div>
              </div>
              <div class="sap-totals" id="${kind}EditTotals"></div>
            </div>
          </div>
          <div class="sap-tab-panel" data-sap-panel="edit-freight" hidden>
            <div class="sap-freight-grid">
              <label>Tipo de envio<input type="text" value="PAGO DESTINATARIO" readonly></label>
              <label>Codigo transportadora<input type="text" value="${escapeHtml(row.transportadora_cnpj || '')}" readonly></label>
              <label>Nome transportadora<input type="text" value="${escapeHtml(row.transportadora || '')}" readonly></label>
              <label>Cond. de pagamento<input type="text" value="${escapeHtml(row.prazo || '')}" readonly></label>
            </div>
          </div>
        </section>
      </div>
      <div class="sap-footer-actions">
        <input id="${kind}EditId" type="hidden" value="${escapeHtml(row.id || '')}">
        <button class="btn btn-primary" id="${kind}EditSaveButton" type="button">Salvar itens</button>
        <button class="btn btn-secondary" id="${kind}EditConfirmButton" type="button">${kind === 'pedidos' ? 'Efetivar pedido' : 'Efetivar cotacao'}</button>
        <button class="btn btn-ghost" id="${kind}EditCancelDocumentButton" type="button">${kind === 'pedidos' ? 'Cancelar pedido' : 'Cancelar cotacao'}</button>
        <button class="btn btn-ghost" id="${kind}EditCloseButton" type="button">Fechar</button>
        <p id="${kind}EditMessage" class="form-message"></p>
      </div>
    </section>
  `;
  bindSapTabs(panel);
  renderDocumentEditItems(kind);
  if (kind === 'pedidos') loadOrderTransferPanel(row.id, `${kind}TransferPanel`);
  const searchButton = document.getElementById(`${kind}EditProductSearchButton`);
  const searchInput = document.getElementById(`${kind}EditProductTerm`);
  searchButton.addEventListener('click', () => searchProductsForDocumentEdit(kind, row.regiao || 'SP'));
  searchInput.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      searchProductsForDocumentEdit(kind, row.regiao || 'SP');
    }
  });
  document.getElementById(`${kind}EditSaveButton`).addEventListener('click', () => saveDocumentEdit(kind));
  document.getElementById(`${kind}EditConfirmButton`).addEventListener('click', () => updateDocumentStatus(kind, row.id, getDocumentConfirmedStatus(kind)));
  document.getElementById(`${kind}EditCancelDocumentButton`).addEventListener('click', () => updateDocumentStatus(kind, row.id, getDocumentCanceledStatus(kind)));
  document.getElementById(`${kind}EditCloseButton`).addEventListener('click', () => {
    if (window[`${kind}EditDirty`] && !window.confirm('Existem alteracoes nao salvas. Deseja sair?')) return;
    panel.hidden = true;
    panel.innerHTML = '';
  });
  panel.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

async function loadOrderTransferPanel(orderId, panelId) {
  const panel = document.getElementById(panelId);
  if (!panel) return;
  try {
    const rows = await supabaseListOrderTransferRequests(orderId);
    panel.innerHTML = '<h3>Transferencias</h3>' + renderOrderTransferPanelRows(rows);
  } catch (error) {
    panel.innerHTML = `<h3>Transferencias</h3><div class="empty-state compact-state">${escapeHtml(error.message)}</div>`;
  }
}

function renderOrderTransferPanelRows(rows) {
  if (!rows.length) return '<div class="empty-state compact-state">Nenhuma transferencia vinculada a este pedido.</div>';
  return `
    <div class="table-wrap compact-table">
      <table>
        <thead><tr><th>Produto</th><th>Origem</th><th>Destino</th><th>Qtd.</th><th>Status</th><th>Observacao</th><th>Atualizada</th></tr></thead>
        <tbody>
          ${rows.map((row) => `
            <tr>
              <td><strong>${escapeHtml(row.product_code || '')}</strong><small>${escapeHtml([row.product_description, row.product_brand].filter(Boolean).join(' | '))}</small></td>
              <td>${escapeHtml(row.source_branch_code || '')}<small>${escapeHtml(formatTransferQty(row.source_available_qty))} disp.</small></td>
              <td>${escapeHtml(row.target_branch_code || '')}<small>${escapeHtml(formatTransferQty(row.target_available_qty))} disp.</small></td>
              <td>${escapeHtml(formatTransferQty(row.requested_qty))}</td>
              <td><span class="status-pill">${escapeHtml(formatStockTransferStatus(row.status))}</span></td>
              <td>${row.notes ? `<small>${escapeHtml(row.notes)}</small>` : '<small>-</small>'}</td>
              <td>${escapeHtml(formatDateTime(row.updated_at || row.created_at))}</td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  `;
}

function normalizeDocumentItems(items) {
  return (items || [])
    .slice()
    .sort((a, b) => Number(a.item || 0) - Number(b.item || 0))
    .map((item) => ({
      codigo: item.codigo,
      descricao: item.descricao,
      marca: item.marca,
      aplicacao: item.aplicacao,
      preco: Number(item.preco_unitario || 0),
      quantidade: Number(item.quantidade || 1),
      desconto_percentual: Number(item.desconto_percentual || 0),
      preco_sem_imposto_unitario: item.preco_sem_imposto_unitario == null ? null : Number(item.preco_sem_imposto_unitario),
      imposto_unitario: item.imposto_unitario == null ? null : Number(item.imposto_unitario),
      fiscal_tax_rule_id: item.fiscal_tax_rule_id || '',
      fiscal_status: item.fiscal_status || '',
      fiscal_details: item.fiscal_details || null
    }));
}

function renderDocumentFiscalPanel(items) {
  const rows = Array.isArray(items) ? items : [];
  if (!rows.length) return '<div class="empty-state compact-state">Nenhum item para analise fiscal.</div>';
  const calculated = rows.filter((item) => item.fiscal_status === 'CALCULATED').length;
  const missingNcm = rows.filter((item) => item.fiscal_status === 'MISSING_NCM').length;
  const missingRule = rows.filter((item) => item.fiscal_status === 'MISSING_RULE').length;
  return `
    <div class="import-summary">
      <article><span>Calculados</span><strong>${calculated}</strong></article>
      <article><span>Sem NCM</span><strong>${missingNcm}</strong></article>
      <article><span>Sem regra</span><strong>${missingRule}</strong></article>
      <article><span>Preco legado</span><strong>${rows.filter((item) => !['CALCULATED', 'MISSING_NCM', 'MISSING_RULE'].includes(item.fiscal_status)).length}</strong></article>
    </div>
    <div class="table-wrap compact-table">
      <table>
        <thead>
          <tr><th>Produto</th><th>NCM</th><th>Status</th><th>Base s/ imp.</th><th>Imposto un.</th><th>Preco final</th><th>Regra</th></tr>
        </thead>
        <tbody>
          ${rows.map((item) => renderDocumentFiscalRow(item)).join('')}
        </tbody>
      </table>
    </div>
  `;
}

function renderDocumentFiscalRow(item) {
  const details = item.fiscal_details || {};
  const status = formatFiscalStatus(item.fiscal_status);
  const ncm = details.ncm || '-';
  const rule = item.fiscal_tax_rule_id
    ? [details.origin_state || details.uf_origem, details.destination_state || details.uf_destino, details.customer_type].filter(Boolean).join(' -> ')
    : '-';
  return `
    <tr>
      <td><strong>${escapeHtml(item.codigo || '')}</strong><small>${escapeHtml(item.descricao || '')}</small></td>
      <td>${escapeHtml(formatFiscalNcm(ncm))}</td>
      <td><span class="status-pill">${escapeHtml(status)}</span></td>
      <td>${item.preco_sem_imposto_unitario == null ? '-' : money(item.preco_sem_imposto_unitario)}</td>
      <td>${item.imposto_unitario == null ? '-' : money(item.imposto_unitario)}</td>
      <td>${money(item.preco)}</td>
      <td>${escapeHtml(rule)}${item.fiscal_tax_rule_id ? `<small>${escapeHtml(item.fiscal_tax_rule_id)}</small>` : ''}</td>
    </tr>
  `;
}

function formatFiscalStatus(status) {
  const labels = {
    CALCULATED: 'Calculado',
    MISSING_NCM: 'Sem NCM',
    MISSING_RULE: 'Sem regra',
    LEGACY_PRICE: 'Preço legado',
    OK: 'OK',
    OK_SEM_ST: 'OK - SEM ST',
    NCM_AUSENTE: 'NCM ausente',
    PRECO_AUSENTE: 'Preço ausente',
    REGRA_FISCAL_AUSENTE: 'Regra fiscal ausente',
    REGRA_FISCAL_INCOMPLETA: 'Regra fiscal incompleta',
    PRODUTO_NAO_LOCALIZADO: 'Produto não localizado',
    ESTOQUE_NAO_IMPORTADO: 'Estoque não importado',
    CALCULANDO: 'Calculando...'
  };
  return labels[status] || status || 'Preco legado';
}

function formatFiscalWarnings(warnings) {
  const labels = {
    PIS_NAO_DEFINIDO: 'PIS sem alíquota na fonte SAP (não incluído)',
    COFINS_NAO_DEFINIDO: 'COFINS sem alíquota na fonte SAP (não incluído)',
    FCP_NAO_DEFINIDO: 'FCP sem alíquota na fonte SAP (não incluído)',
    IPI_AUSENTE: 'IPI ausente',
    CEST_AUSENTE: 'CEST ausente',
    ICMS_INTERESTADUAL_AUSENTE: 'ICMS interestadual ausente',
    ICMS_INTERNO_AUSENTE: 'ICMS interno ausente',
    MVA_AUSENTE: 'MVA ausente',
    ESTOQUE_NAO_IMPORTADO: 'Estoque da filial não importado'
  };
  return (Array.isArray(warnings) ? warnings : [])
    .map((warning) => labels[warning] || warning)
    .join(' · ');
}

function formatFiscalBreakdown(details) {
  if (!details || typeof details !== 'object' || !details.route) return 'Memória fiscal aguardando cálculo.';
  const legacyResale = details.calculation_profile === 'LEGACY_REVENDA';
  const parts = [
    legacyResale ? 'Perfil Revenda (portal atual)' : null,
    `Rota ${String(details.route).replace('-', '→')}`,
    `IPI ${details.ipi_amount == null ? 'não definido' : money(Number(details.ipi_amount))}`,
    `ICMS próprio ${details.own_icms_amount == null ? 'não definido' : money(Number(details.own_icms_amount))}${details.own_icms_included_in_total === false ? ' (referência, não somado)' : ''}`,
    `ICMS-ST ${details.icms_st_amount == null ? 'não definido' : money(Number(details.icms_st_amount))}`
  ].filter(Boolean);
  if (details.pis_amount != null) parts.push(`PIS ${money(Number(details.pis_amount))}`);
  if (details.cofins_amount != null) parts.push(`COFINS ${money(Number(details.cofins_amount))}`);
  if (details.fcp_amount != null) parts.push(`FCP ${money(Number(details.fcp_amount))}`);
  return parts.join(' · ');
}

function formatFiscalNcm(value) {
  const digits = String(value || '').replace(/\D/g, '');
  return digits.length === 8 ? `${digits.slice(0, 4)}.${digits.slice(4, 6)}.${digits.slice(6)}` : String(value || '-');
}

function renderDocumentEditItems(kind) {
  const target = document.getElementById(`${kind}EditItems`);
  const count = document.getElementById(`${kind}EditCount`);
  const totals = document.getElementById(`${kind}EditTotals`);
  const items = window[`${kind}EditingItems`] || [];
  if (count) count.textContent = items.length + (items.length === 1 ? ' item' : ' itens');
  if (!items.length) {
    target.innerHTML = renderDocumentSapItemsTable(kind, []);
    if (totals) totals.innerHTML = renderSapTotals(0, 0, 0);
    return;
  }
  const subtotal = items.reduce((sum, item) => sum + Number(item.preco || 0) * Number(item.quantidade || 0), 0);
  const total = items.reduce((sum, item) => sum + Number(item.preco || 0) * Number(item.quantidade || 0) * (1 - Number(item.desconto_percentual || 0) / 100), 0);
  target.innerHTML = renderDocumentSapItemsTable(kind, items);
  if (totals) totals.innerHTML = renderSapTotals(subtotal, subtotal - total, total);
  target.querySelectorAll('[data-document-edit-qty]').forEach((input) => {
    input.addEventListener('input', () => {
      const item = items[Number(input.dataset.documentEditQty)];
      if (!item) return;
      item.quantidade = Math.max(1, Number(input.value || 1));
      window[`${kind}EditDirty`] = true;
    });
    input.addEventListener('change', () => {
      items[Number(input.dataset.documentEditQty)].quantidade = Math.max(1, Number(input.value || 1));
      window[`${kind}EditDirty`] = true;
      renderDocumentEditItems(kind);
    });
  });
  target.querySelectorAll('[data-document-edit-discount]').forEach((input) => {
    input.addEventListener('input', () => {
      const item = items[Number(input.dataset.documentEditDiscount)];
      if (!item) return;
      item.desconto_percentual = Math.max(0, Number(input.value || 0));
      window[`${kind}EditDirty`] = true;
    });
    input.addEventListener('change', () => {
      items[Number(input.dataset.documentEditDiscount)].desconto_percentual = Math.max(0, Number(input.value || 0));
      window[`${kind}EditDirty`] = true;
      renderDocumentEditItems(kind);
    });
  });
  target.querySelectorAll('[data-document-edit-remove]').forEach((button) => {
    button.addEventListener('click', () => {
      items.splice(Number(button.dataset.documentEditRemove), 1);
      window[`${kind}EditDirty`] = true;
      renderDocumentEditItems(kind);
    });
  });
}

function renderDocumentSapItemsTable(kind, items) {
  const totalQty = items.reduce((sum, item) => sum + Number(item.quantidade || 0), 0);
  const subtotal = items.reduce((sum, item) => sum + Number(item.preco || 0) * Number(item.quantidade || 0), 0);
  const total = items.reduce((sum, item) => sum + Number(item.preco || 0) * Number(item.quantidade || 0) * (1 - Number(item.desconto_percentual || 0) / 100), 0);
  const rows = items.length ? items.map((item, index) => {
    const finalUnit = Number(item.preco || 0) * (1 - Number(item.desconto_percentual || 0) / 100);
    const rowTotal = finalUnit * Number(item.quantidade || 0);
    return `
      <tr>
        <td>${index + 1}</td>
        <td class="sap-code">${escapeHtml(item.codigo || '')}</td>
        <td>${escapeHtml(item.descricao || '')}</td>
        <td>${escapeHtml(item.marca || '')}</td>
        <td>${escapeHtml(item.aplicacao || '')}</td>
        <td>UN</td>
        <td><input type="number" min="1" value="${escapeHtml(item.quantidade)}" data-document-edit-qty="${index}"></td>
        <td>${money(item.preco)}</td>
        <td><input type="number" min="0" step="0.01" value="${escapeHtml(item.desconto_percentual)}" data-document-edit-discount="${index}"></td>
        <td>${money(finalUnit)}</td>
        <td>${money(rowTotal)}</td>
        <td>${money(rowTotal)}</td>
        <td><button class="sap-remove-button" type="button" data-document-edit-remove="${index}" title="Remover">-</button></td>
      </tr>
    `;
  }).join('') : '<tr><td colspan="13" class="sap-empty-row">Nenhum item no documento.</td></tr>';
  return `
    <table class="sap-items-table">
      <thead>
        <tr>
          <th>#</th><th>Cod.</th><th>Descricao</th><th>Marca</th><th>Aplicacao</th><th>UM</th><th>Qtde</th>
          <th>Pr.Unit.</th><th>% do desc.</th><th>Pr.Apos Desc.</th><th>Total Apos Desc.</th><th>Total c/ Imp.</th><th></th>
        </tr>
      </thead>
      <tbody>${rows}</tbody>
      <tfoot>
        <tr>
          <td colspan="6">Totais:</td><td>${totalQty}</td><td></td><td></td><td></td><td>${money(total)}</td><td>${money(subtotal)}</td><td></td>
        </tr>
      </tfoot>
    </table>
  `;
}

async function searchProductsForDocumentEdit(kind, regiao) {
  const target = document.getElementById(`${kind}EditProductResults`);
  await searchProductsInto(target, {
    termo: document.getElementById(`${kind}EditProductTerm`).value,
    regiao
  }, (product) => addProductToDocumentEdit(kind, product));
}

function addProductToDocumentEdit(kind, product) {
  const items = window[`${kind}EditingItems`] || [];
  const existing = items.find((item) => item.codigo === product.codigo);
  if (existing) {
    existing.quantidade += 1;
  } else {
    items.push({
      codigo: product.codigo,
      descricao: product.descricao,
      marca: product.marca,
      aplicacao: product.aplicacao,
      preco: Number(product.preco || 0),
      quantidade: 1,
      desconto_percentual: 0
    });
  }
  window[`${kind}EditingItems`] = items;
  window[`${kind}EditDirty`] = true;
  const namePreview = document.getElementById(`${kind}EditProductNamePreview`);
  const groupPreview = document.getElementById(`${kind}EditProductGroupPreview`);
  if (namePreview) namePreview.value = product.descricao || '';
  if (groupPreview) groupPreview.value = product.grupo || product.linha || product.categoria || '';
  renderDocumentEditItems(kind);
}

async function saveDocumentEdit(kind) {
  const message = document.getElementById(`${kind}EditMessage`);
  const button = document.getElementById(`${kind}EditSaveButton`);
  message.style.color = 'var(--muted)';
  message.textContent = 'Salvando alteracoes...';
  button.disabled = true;
  button.textContent = 'Salvando...';
  try {
    syncDocumentEditInputs(kind);
    const payload = {
      id: document.getElementById(`${kind}EditId`).value,
      items: window[`${kind}EditingItems`] || []
    };
    if (kind === 'pedidos') {
      await supabaseUpdateOrderReport(payload);
    } else {
      await supabaseUpdateQuotationReport(payload);
    }
    message.style.color = 'var(--success)';
    message.textContent = 'Alteracoes salvas.';
    window[`${kind}EditDirty`] = false;
    await loadDocumentReport(kind);
  } catch (error) {
    message.style.color = 'var(--accent)';
    message.textContent = error.message;
  } finally {
    button.disabled = false;
    button.textContent = 'Salvar itens';
  }
}

function syncDocumentEditInputs(kind) {
  const items = window[`${kind}EditingItems`] || [];
  document.querySelectorAll(`#${kind}EditItems [data-document-edit-qty]`).forEach((input) => {
    const item = items[Number(input.dataset.documentEditQty)];
    if (item) item.quantidade = Math.max(1, Number(input.value || 1));
  });
  document.querySelectorAll(`#${kind}EditItems [data-document-edit-discount]`).forEach((input) => {
    const item = items[Number(input.dataset.documentEditDiscount)];
    if (item) item.desconto_percentual = Math.max(0, Number(input.value || 0));
  });
}

async function updateDocumentStatus(kind, id, status) {
  const message = document.getElementById(`${kind}EditMessage`);
  const confirmButton = document.getElementById(`${kind}EditConfirmButton`);
  const cancelButton = document.getElementById(`${kind}EditCancelDocumentButton`);
  message.style.color = 'var(--muted)';
  message.textContent = 'Atualizando status...';
  if (confirmButton) confirmButton.disabled = true;
  if (cancelButton) cancelButton.disabled = true;
  try {
    const data = kind === 'pedidos'
      ? await supabaseUpdateOrderStatus({ id, status })
      : await supabaseUpdateQuotationStatus({ id, status });
    const display = document.getElementById(`${kind}EditStatusDisplay`);
    if (display) display.value = formatDocumentStatus(kind, data.status || status);
    message.style.color = 'var(--success)';
    message.textContent = 'Status atualizado para ' + formatDocumentStatus(kind, data.status || status) + '.';
    await loadDocumentReport(kind);
  } catch (error) {
    message.style.color = 'var(--accent)';
    message.textContent = error.message;
  } finally {
    if (confirmButton) confirmButton.disabled = false;
    if (cancelButton) cancelButton.disabled = false;
  }
}

function exportDocumentReport(kind) {
  const rows = window[`${kind}LastRows`] || [];
  const message = document.getElementById(`${kind}Message`);
  if (!rows.length) {
    message.style.color = 'var(--accent)';
    message.textContent = 'Nao ha dados para exportar.';
    return;
  }
  const numberKey = kind === 'pedidos' ? 'numero_pedido' : 'numero_cotacao';
  downloadCsv(`${kind}-${formatDateInput(new Date())}.csv`, rows.map((row) => ({
    numero: row[numberKey] || '',
    data: formatDateTime(row.created_at || row.data_hora),
    cliente: row.cliente || '',
    codigo_sap_cliente: row.codigo_sap_cliente || '',
    cnpj: row.cnpj || '',
    vendedor: row.vendedor || '',
    status: row.status || '',
    total: Number(row.total || 0).toFixed(2)
  })));
}

function getDocumentFilters(kind) {
  return {
    termo: document.getElementById(`${kind}Search`).value.trim(),
    from: dateInputToIsoStart(document.getElementById(`${kind}From`).value),
    to: dateInputToIsoEnd(document.getElementById(`${kind}To`).value),
    status: document.getElementById(`${kind}Status`).value
  };
}

function documentStatusOptions(kind) {
  return kind === 'pedidos'
    ? ['NOVO', 'EM_ANALISE', 'APROVADO', 'CANCELADO', 'FATURADO']
    : ['NOVA', 'ENVIADA', 'APROVADA', 'CANCELADA', 'CONVERTIDA'];
}

function getDocumentConfirmedStatus(kind) {
  return kind === 'pedidos' ? 'APROVADO' : 'APROVADA';
}

function getDocumentCanceledStatus(kind) {
  return kind === 'pedidos' ? 'CANCELADO' : 'CANCELADA';
}

function formatDocumentStatus(kind, status) {
  const labels = {
    NOVO: 'Aberto',
    NOVA: 'Aberta',
    EM_ANALISE: 'Em analise',
    ENVIADA: 'Enviada',
    APROVADO: 'Efetivado',
    APROVADA: 'Efetivada',
    CANCELADO: 'Cancelado',
    CANCELADA: 'Cancelada',
    FATURADO: 'Faturado',
    CONVERTIDA: 'Convertida'
  };
  return labels[status] || status || (kind === 'pedidos' ? 'Aberto' : 'Aberta');
}
