let orderItems = [];
let orderClientSearchTimer = null;
let orderSelectedProduct = null;
let orderImportPreviewItems = [];
let orderCreateSaved = false;

async function renderOrders(container) {
  orderItems = [];
  orderSelectedProduct = null;
  orderCreateSaved = false;
  const companySettings = await loadCompanySettings();
  const branchLabel = formatCompanyBranchLabel(companySettings);
  container.innerHTML = `
    <section class="sap-document">
      <div class="sap-titlebar">
        <div class="sap-title"><span class="sap-title-icon">#</span><h2>Pedido de venda</h2></div>
        <strong>No. Novo</strong>
      </div>
      <div class="sap-window">
        <section class="sap-section">
          <h3>Dados gerais</h3>
          <div class="sap-form-grid">
            <div class="sap-form-left">
              <label>Filial
                <select id="orderBranch"><option>${escapeHtml(branchLabel)}</option></select>
              </label>
              <div class="sap-inline-fields">
                <label>Cliente | CPF/CNPJ
                  <input id="orderClientSapCode" type="text" placeholder="Codigo SAP">
                </label>
                <button class="sap-mini-button" id="orderCadastroSearchButton" type="button" title="Buscar cliente">&#128269;</button>
                <label>
                  <input id="orderCnpj" type="text" placeholder="CNPJ">
                </label>
              </div>
              <label>Nome cliente<input id="orderClient" type="text"></label>
              <label>Buscar cliente
                <span class="sap-search-field">
                  <input id="orderCadastroSearch" type="search" placeholder="Codigo SAP, CNPJ, protocolo ou empresa">
                  <button class="sap-search-button" id="orderCadastroSearchSubmitButton" type="button" title="Buscar cliente">&#128269;</button>
                </span>
              </label>
              <label>Pessoa de contato<input id="orderPhone" type="text"></label>
              <label>No Ref.Cli.<input id="orderClientRef" type="text"></label>
              <label>Vendedor<input id="orderSellerDisplay" type="text" value="${escapeHtml((getStoredSession() || {}).nome || '')}"></label>
              <label>Utilizacao principal<select id="orderUsage"><option>Revenda</option><option>Consumo</option></select></label>
              <label>Deposito<select id="orderRegion"><option value="SP">02 - FILIAL - SP</option><option value="PR">01 - MATRIZ - PR</option></select></label>
              <label>Endereco<input id="orderAddress" type="text"></label>
            </div>
            <div class="sap-form-right">
              <label>Status SAP<input type="text" value="Aberto" readonly></label>
              <label>Dt.Pedido<input type="text" value="${formatDateInput(new Date())}" readonly></label>
              <label>Valido ate<input type="date" id="orderValidUntil"></label>
              <label>Autorizacao SAP<input type="text" value="Sem status" readonly></label>
              <label>Autorizacao portal<input type="text" value="Sem status" readonly></label>
            </div>
          </div>
          <div id="orderCadastroResults" class="sap-search-results">
            <div class="empty-state compact-state">Clientes e cadastros aprovados aparecem aqui para preencher o pedido.</div>
          </div>
        </section>

        <section class="sap-section sap-tabs-section">
          <div class="sap-tabs">
            <button class="is-active" type="button" data-sap-tab="items">Itens</button>
            <button type="button" data-sap-tab="freight">Frete / Pagamento</button>
          </div>
          <div class="sap-tab-panel" data-sap-panel="items">
            <div class="sap-tab-tools">
              <label class="sap-checkbox"><input type="checkbox" checked> Simular impostos</label>
              <span id="cartCount">0 itens</span>
            </div>
            <div id="cartItems" class="sap-items-wrap"></div>
            <div class="sap-bottom-grid">
              <div class="sap-add-item">
                <form id="orderProductSearch" class="sap-add-form">
                  <label>Cod.Item / EAN
                    <input id="orderProductTerm" type="search">
                  </label>
                  <label>Nome item
                    <input id="orderProductNamePreview" type="text">
                  </label>
                  <label>Grupo
                    <select id="orderProductGroupPreview"><option value=""></option></select>
                  </label>
                  <div class="actions-row sap-item-search-actions">
                    <button class="btn btn-primary" type="submit">Buscar</button>
                    <button class="btn btn-ghost" id="orderImportItemsButton" type="button">Importar itens</button>
                  </div>
                  <div class="sap-stock-line" id="orderProductStockLine" hidden>Disp. Venda: <strong>-</strong> / Pr.Unit.: <strong>-</strong></div>
                  <label id="orderQuantityLabel" hidden>Quantidade
                    <input id="orderAddQuantity" type="number" min="0" value="0">
                  </label>
                  <div class="actions-row sap-add-controls" id="orderAddControls" hidden>
                    <button class="btn btn-primary" id="orderAddSelectedProductButton" type="button">Adicionar</button>
                    <button class="btn btn-ghost" id="orderClearProductButton" type="button">Limpar</button>
                  </div>
                </form>
                <div id="orderSearchResults" class="sap-product-results"><div class="empty-state compact-state">Pesquise para adicionar itens ao pedido.</div></div>
              </div>
              <div class="sap-totals" id="cartTotals"></div>
            </div>
          </div>
          <div class="sap-import-modal" id="orderItemsImportModal" hidden>
            <div class="sap-import-dialog">
              <div class="panel-header">
                <div><h2>Importar itens</h2><p>Cole codigos com quantidade ou carregue um arquivo CSV/TXT.</p></div>
                <button class="btn btn-ghost" id="orderCloseImportItemsButton" type="button">Fechar</button>
              </div>
              <label>Codigos e quantidades
                <textarea id="orderImportItemsText" placeholder="7175526020;2&#10;711032201;4"></textarea>
              </label>
              <div class="actions-row">
                <button class="btn btn-secondary" id="orderLoadImportItemsFileButton" type="button">Carregar arquivo</button>
                <button class="btn btn-primary" id="orderPreviewImportItemsButton" type="button">Verificar codigos</button>
                <button class="btn btn-primary" id="orderApplyImportItemsButton" type="button" disabled>Importar quantidades</button>
                <input id="orderImportItemsFile" type="file" accept=".csv,.txt" hidden>
              </div>
              <div id="orderImportItemsPreview" class="sap-product-results">
                <div class="empty-state compact-state">A lista verificada aparece aqui.</div>
              </div>
            </div>
          </div>
          <div class="sap-tab-panel" data-sap-panel="freight" hidden>
            <div class="sap-freight-grid">
              <label>Tipo de envio
                <select id="orderShippingType">
                  <option>PAGO DESTINATARIO</option>
                  <option>PAGO REMETENTE</option>
                  <option>RETIRA</option>
                </select>
              </label>
              <label>Codigo transportadora
                <span class="sap-search-field">
                  <input id="orderCarrierSearch" type="search">
                  <button class="sap-search-button" id="orderCarrierCodeSearchButton" type="button">...</button>
                </span>
              </label>
              <label>Nome transportadora
                <span class="sap-search-field">
                  <input id="orderCarrier" type="text">
                  <button class="sap-search-button" id="orderCarrierNameSearchButton" type="button">...</button>
                </span>
              </label>
              <label>Cond. de pagamento
                <select id="orderTerm">
                  <option>30/40/50/60/70/80</option>
                  <option>28/35/42</option>
                  <option>30/60/90</option>
                  <option>A vista</option>
                </select>
              </label>
            </div>
            <input id="orderCarrierCnpj" type="hidden">
            <input id="orderCarrierAddress" type="hidden">
            <input id="orderNotes" type="hidden">
            <div id="orderCarrierResults" class="sap-search-results">
              <div class="empty-state compact-state">Transportadoras cadastradas aparecem aqui.</div>
            </div>
          </div>
        </section>
      </div>
      <div class="sap-footer-actions">
        <button class="btn btn-primary" id="saveOrderButton" type="button">Salvar</button>
        <button class="btn btn-ghost" id="closeOrderButton" type="button">Fechar</button>
        <p id="orderMessage" class="form-message"></p>
      </div>
    </section>
  `;

  bindSapTabs(container);
  document.getElementById('orderCadastroSearchButton').addEventListener('click', searchCadastrosForOrder);
  document.getElementById('orderCadastroSearchSubmitButton').addEventListener('click', () => searchCadastrosForOrder({
    term: document.getElementById('orderCadastroSearch').value
  }));
  document.getElementById('orderCadastroSearch').addEventListener('keydown', async (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      await searchCadastrosForOrder({ term: event.target.value });
    }
  });
  ['orderCadastroSearch', 'orderClientSapCode', 'orderCnpj', 'orderClient'].forEach((id) => {
    document.getElementById(id).addEventListener('input', scheduleOrderClientAutoSearch);
  });
  document.getElementById('orderCarrierCodeSearchButton').addEventListener('click', searchCarriersForOrder);
  document.getElementById('orderCarrierNameSearchButton').addEventListener('click', searchCarriersForOrder);
  document.getElementById('orderCarrierSearch').addEventListener('keydown', async (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      await searchCarriersForOrder();
    }
  });
  document.getElementById('orderCarrier').addEventListener('keydown', async (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      await searchCarriersForOrder();
    }
  });

  document.getElementById('orderProductSearch').addEventListener('submit', async (event) => {
    event.preventDefault();
    orderSelectedProduct = null;
    updateOrderProductSelection(null);
    await searchProductsInto(document.getElementById('orderSearchResults'), {
      termo: getOrderProductSearchTerm(),
      grupo: document.getElementById('orderProductGroupPreview').value,
      regiao: document.getElementById('orderRegion').value
    }, selectProductForOrder);
  });

  document.getElementById('orderRegion').addEventListener('change', () => {
    orderItems = [];
    renderCart();
    document.getElementById('orderSearchResults').innerHTML = '<div class="empty-state">Pesquise novamente para obter precos do estado selecionado.</div>';
  });

  document.getElementById('saveOrderButton').addEventListener('click', saveCurrentOrder);
  document.getElementById('closeOrderButton').addEventListener('click', () => {
    if (hasUnsavedOrderDraft() && !window.confirm('Existem alteracoes nao salvas. Deseja sair?')) return;
    openModule('ordersReport');
  });
  document.getElementById('orderAddSelectedProductButton').addEventListener('click', () => {
    if (!orderSelectedProduct) return;
    addProductToOrder(orderSelectedProduct);
    clearOrderProductSelection();
  });
  document.getElementById('orderClearProductButton').addEventListener('click', () => {
    clearOrderProductSelection();
  });
  document.getElementById('orderImportItemsButton').addEventListener('click', () => {
    openOrderItemsImportModal();
  });
  document.getElementById('orderCloseImportItemsButton').addEventListener('click', closeOrderItemsImportModal);
  document.getElementById('orderLoadImportItemsFileButton').addEventListener('click', () => {
    document.getElementById('orderImportItemsFile').click();
  });
  document.getElementById('orderPreviewImportItemsButton').addEventListener('click', previewOrderImportItems);
  document.getElementById('orderApplyImportItemsButton').addEventListener('click', applyOrderImportItems);
  document.getElementById('orderImportItemsFile').addEventListener('change', loadOrderItemsImportFile);
  renderCart();
}

function applyOrderDraft(draft) {
  if (!draft) return;
  document.getElementById('orderRegion').value = draft.regiao || 'SP';
  document.getElementById('orderClientSapCode').value = draft.codigo_sap_cliente || '';
  document.getElementById('orderCnpj').value = formatCnpj(draft.cnpj || '');
  document.getElementById('orderClient').value = draft.cliente || '';
  document.getElementById('orderPhone').value = draft.telefone || '';
  document.getElementById('orderAddress').value = draft.endereco || '';
  document.getElementById('orderTerm').value = draft.prazo || document.getElementById('orderTerm').value;
  document.getElementById('orderCarrier').value = draft.transportadora || '';
  document.getElementById('orderCarrierCnpj').value = draft.transportadora_cnpj || '';
  document.getElementById('orderCarrierAddress').value = draft.transportadora_endereco || '';
  document.getElementById('orderNotes').value = draft.observacao || '';
  orderItems = (draft.items || []).map((item) => Object.assign({}, item));
  orderCreateSaved = false;
  renderCart();
  const message = document.getElementById('orderMessage');
  if (message) {
    message.style.color = 'var(--success)';
    message.textContent = 'Rascunho carregado. Revise e salve para gerar um novo pedido.';
  }
}

function bindSapTabs(scope) {
  const root = scope || document;
  root.querySelectorAll('[data-sap-tab]').forEach((button) => {
    button.addEventListener('click', () => {
      const tab = button.dataset.sapTab;
      const tabRoot = button.closest('.sap-tabs-section');
      tabRoot.querySelectorAll('[data-sap-tab]').forEach((item) => {
        item.classList.toggle('is-active', item.dataset.sapTab === tab);
      });
      tabRoot.querySelectorAll('[data-sap-panel]').forEach((panel) => {
        panel.hidden = panel.dataset.sapPanel !== tab;
      });
    });
  });
}

function getOrderProductSearchTerm() {
  return [
    document.getElementById('orderProductTerm').value,
    document.getElementById('orderProductNamePreview').value
  ].filter(Boolean).join(' ').trim();
}

function setOrderProductGroup(value) {
  const select = document.getElementById('orderProductGroupPreview');
  const group = value || '';
  select.innerHTML = group
    ? `<option value="${escapeHtml(group)}">${escapeHtml(group)}</option>`
    : '<option value=""></option>';
  select.value = group;
}

function updateOrderProductSelection(product) {
  const hasProduct = Boolean(product);
  document.getElementById('orderProductStockLine').hidden = !hasProduct;
  document.getElementById('orderQuantityLabel').hidden = !hasProduct;
  document.getElementById('orderAddControls').hidden = !hasProduct;
  if (!hasProduct) {
    document.getElementById('orderProductStockLine').innerHTML = 'Disp. Venda: <strong>-</strong> / Pr.Unit.: <strong>-</strong>';
    return;
  }
  document.getElementById('orderProductTerm').value = product.codigo || '';
  document.getElementById('orderProductNamePreview').value = product.descricao || '';
  setOrderProductGroup(product.grupo || product.linha || product.categoria || '');
  document.getElementById('orderProductStockLine').innerHTML = 'Disp. Venda: <strong>' + escapeHtml(product.estoque || '0') + '</strong> / Pr.Unit.: <strong>' + money(Number(product.preco || 0)) + '</strong>';
  document.getElementById('orderAddQuantity').value = 0;
}

function selectProductForOrder(product) {
  orderSelectedProduct = product;
  updateOrderProductSelection(product);
}

function clearOrderProductSelection() {
  orderSelectedProduct = null;
  document.getElementById('orderProductTerm').value = '';
  document.getElementById('orderProductNamePreview').value = '';
  setOrderProductGroup('');
  document.getElementById('orderSearchResults').innerHTML = '<div class="empty-state compact-state">Pesquise para adicionar itens ao pedido.</div>';
  updateOrderProductSelection(null);
}

function addProductToOrder(product, forcedQuantity = null) {
  orderCreateSaved = false;
  const existing = orderItems.find((item) => item.codigo === product.codigo);
  const qtyInput = document.getElementById('orderAddQuantity');
  const quantity = Number(forcedQuantity !== null ? forcedQuantity : (qtyInput ? qtyInput.value || 0 : 0));
  if (quantity <= 0) {
    if (qtyInput) qtyInput.focus();
    const message = document.getElementById('orderMessage');
    if (message) {
      message.style.color = 'var(--accent)';
      message.textContent = 'Informe uma quantidade maior que zero.';
    }
    return;
  }
  if (existing) {
    existing.quantidade += quantity;
  } else {
    orderItems.push({
      codigo: product.codigo,
      descricao: product.descricao,
      marca: product.marca,
      aplicacao: product.aplicacao,
      preco: Number(product.preco || 0),
      quantidade: quantity,
      desconto_percentual: 0
    });
  }
  renderCart();
}

function openOrderItemsImportModal() {
  document.getElementById('orderItemsImportModal').hidden = false;
}

function closeOrderItemsImportModal() {
  document.getElementById('orderItemsImportModal').hidden = true;
}

function parseImportItemsText(text) {
  return String(text || '').split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const parts = line.split(/[;\t,]/).map((part) => part.trim());
      return {
        code: parts[0],
        quantity: Math.max(1, Number(String(parts[1] || '1').replace(',', '.')) || 1)
      };
    })
    .filter((item) => item.code && !/^cod/i.test(item.code));
}

async function loadOrderItemsImportFile(event) {
  const file = event.target.files && event.target.files[0];
  event.target.value = '';
  if (!file) return;
  document.getElementById('orderImportItemsText').value = await file.text();
  await previewOrderImportItems();
}

async function previewOrderImportItems() {
  const target = document.getElementById('orderImportItemsPreview');
  const applyButton = document.getElementById('orderApplyImportItemsButton');
  const parsed = parseImportItemsText(document.getElementById('orderImportItemsText').value);
  orderImportPreviewItems = [];
  applyButton.disabled = true;
  if (!parsed.length) {
    target.innerHTML = '<div class="empty-state compact-state">Informe ao menos um codigo.</div>';
    return;
  }
  target.innerHTML = '<div class="empty-state compact-state">Verificando codigos...</div>';
  try {
    for (const item of parsed) {
      const code = item.code;
      const products = await supabaseSearchProducts({ termo: code, regiao: document.getElementById('orderRegion').value, limite: 10 });
      const product = products.find((item) => String(item.codigo) === code) || products[0];
      orderImportPreviewItems.push({ code, quantity: item.quantity, product });
    }
    target.innerHTML = renderOrderImportItemsPreview();
    bindOrderImportPreviewEvents();
    applyButton.disabled = !orderImportPreviewItems.some((item) => item.product);
  } catch (error) {
    target.innerHTML = `<div class="empty-state compact-state">${escapeHtml(error.message)}</div>`;
  }
}

function bindOrderImportPreviewEvents() {
  const target = document.getElementById('orderImportItemsPreview');
  target.querySelectorAll('[data-order-import-qty]').forEach((input) => {
    input.addEventListener('change', () => {
      orderImportPreviewItems[Number(input.dataset.orderImportQty)].quantity = Math.max(1, Number(input.value || 1));
      target.innerHTML = renderOrderImportItemsPreview();
      bindOrderImportPreviewEvents();
    });
  });
  target.querySelectorAll('[data-order-import-remove]').forEach((button) => {
    button.addEventListener('click', () => {
      orderImportPreviewItems.splice(Number(button.dataset.orderImportRemove), 1);
      target.innerHTML = renderOrderImportItemsPreview();
      bindOrderImportPreviewEvents();
      document.getElementById('orderApplyImportItemsButton').disabled = !orderImportPreviewItems.some((item) => item.product);
    });
  });
}

function renderOrderImportItemsPreview() {
  const found = orderImportPreviewItems.filter((item) => item.product);
  const missing = orderImportPreviewItems.length - found.length;
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
          ${orderImportPreviewItems.map((item, index) => `
            <tr>
              <td>${item.product ? 'OK' : 'Nao encontrado'}</td>
              <td>${escapeHtml(item.code)}</td>
              <td>${item.product ? escapeHtml(item.product.descricao || '') : '<strong>Nao encontrado</strong>'}</td>
              <td>${item.product ? escapeHtml(item.product.estoque || '0') : '-'}</td>
              <td>${item.product ? money(Number(item.product.preco || 0)) : '-'}</td>
              <td><input type="number" min="1" value="${escapeHtml(item.quantity)}" data-order-import-qty="${index}" ${item.product ? '' : 'disabled'}></td>
              <td><button class="sap-remove-button" type="button" data-order-import-remove="${index}" title="Remover">-</button></td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  `;
}

function applyOrderImportItems() {
  let added = 0;
  orderImportPreviewItems.forEach((item) => {
    if (!item.product) return;
    addProductToOrder(item.product, item.quantity);
    added += 1;
  });
  document.getElementById('orderSearchResults').innerHTML = '<div class="empty-state compact-state">' + added + ' itens importados para o pedido.</div>';
  closeOrderItemsImportModal();
}

function renderCart() {
  const list = document.getElementById('cartItems');
  const count = document.getElementById('cartCount');
  const totals = document.getElementById('cartTotals');
  count.textContent = orderItems.length + (orderItems.length === 1 ? ' item' : ' itens');
  const subtotal = orderItems.reduce((sum, item) => sum + item.preco * item.quantidade, 0);
  const total = orderItems.reduce((sum, item) => sum + item.preco * item.quantidade * (1 - item.desconto_percentual / 100), 0);
  const discount = subtotal - total;
  if (!orderItems.length) {
    list.className = 'sap-items-wrap';
    list.innerHTML = renderSapOrderItemsTable([]);
    totals.innerHTML = renderSapTotals(0, 0, 0);
    return;
  }
  list.className = 'sap-items-wrap';
  list.innerHTML = renderSapOrderItemsTable(orderItems);
  list.querySelectorAll('[data-cart-qty]').forEach((input) => {
    input.addEventListener('change', () => {
      orderItems[Number(input.dataset.cartQty)].quantidade = Math.max(1, Number(input.value || 1));
      renderCart();
    });
  });
  list.querySelectorAll('[data-cart-discount]').forEach((input) => {
    input.addEventListener('change', () => {
      orderItems[Number(input.dataset.cartDiscount)].desconto_percentual = Math.max(0, Number(input.value || 0));
      renderCart();
    });
  });
  list.querySelectorAll('[data-cart-remove]').forEach((button) => {
    button.addEventListener('click', () => {
      orderItems.splice(Number(button.dataset.cartRemove), 1);
      renderCart();
    });
  });
  totals.innerHTML = renderSapTotals(subtotal, discount, total);
}

function renderSapOrderItemsTable(items) {
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
        <td>${escapeHtml(item.descricao || '')}</td>
        <td>${escapeHtml(item.marca || '')}</td>
        <td>${escapeHtml(item.aplicacao || '')}</td>
        <td>UN</td>
        <td><input type="number" min="1" value="${escapeHtml(item.quantidade)}" data-cart-qty="${index}"></td>
        <td>${money(item.preco)}</td>
        <td><input type="number" min="0" step="0.01" value="${escapeHtml(item.desconto_percentual)}" data-cart-discount="${index}"></td>
        <td>${money(finalUnit)}</td>
        <td>${money(rowTotal)}</td>
        <td>${money(rowTotal)}</td>
        <td><button class="sap-remove-button" type="button" data-cart-remove="${index}" title="Remover">-</button></td>
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

function renderSapTotals(subtotal, discount, total) {
  return `
    <div><span>Sub-total:</span><strong>${money(subtotal)}</strong></div>
    <div><span>Desconto:</span><strong>${money(discount)}</strong></div>
    <div><span>Sub-total c/desc.:</span><strong>${money(total)}</strong></div>
    <div class="sap-grand-total"><span>Total geral:</span><strong>${money(total)}</strong></div>
  `;
}

function validateCommercialDocument(payload, label) {
  const docLabel = label || 'documento';
  if (!String(payload.cliente || '').trim()) {
    throw new Error('Informe o cliente antes de salvar ' + docLabel + '.');
  }
  if (!Array.isArray(payload.items) || !payload.items.length) {
    throw new Error('Adicione pelo menos 1 item antes de salvar ' + docLabel + '.');
  }
  payload.items.forEach((item, index) => {
    const prefix = 'Item ' + (index + 1) + ': ';
    if (!String(item.codigo || '').trim()) throw new Error(prefix + 'codigo do produto ausente.');
    if (Number(item.quantidade || 0) <= 0) throw new Error(prefix + 'quantidade deve ser maior que zero.');
    if (Number(item.preco || 0) <= 0) throw new Error(prefix + 'preco invalido.');
  });
}

async function saveCurrentOrder() {
  const message = document.getElementById('orderMessage');
  const button = document.getElementById('saveOrderButton');
  message.textContent = '';
  button.disabled = true;
  button.textContent = 'Salvando...';
  try {
    const payload = {
      sessionId: getSessionId(),
      regiao: document.getElementById('orderRegion').value,
      codigo_sap_cliente: document.getElementById('orderClientSapCode').value,
      cliente: document.getElementById('orderClient').value,
      cnpj: document.getElementById('orderCnpj').value,
      telefone: document.getElementById('orderPhone').value,
      endereco: document.getElementById('orderAddress').value,
      prazo: document.getElementById('orderTerm').value,
      transportadora: document.getElementById('orderCarrier').value,
      transportadora_cnpj: document.getElementById('orderCarrierCnpj').value,
      transportadora_endereco: document.getElementById('orderCarrierAddress').value,
      observacao: document.getElementById('orderNotes').value,
      generateDocuments: false,
      items: orderItems
    };
    validateCommercialDocument(payload, 'o pedido');
    const subtotal = orderItems.reduce((sum, item) => sum + item.preco * item.quantidade, 0);
    const total = orderItems.reduce((sum, item) => sum + item.preco * item.quantidade * (1 - item.desconto_percentual / 100), 0);
    payload.subtotal = subtotal;
    payload.desconto_total = subtotal - total;
    payload.total = total;
    const data = await supabaseCreateOrder(payload);
    orderItems = [];
    orderCreateSaved = true;
    renderCart();
    message.style.color = 'var(--success)';
    message.textContent = 'Pedido ' + data.numero_pedido + ' salvo com sucesso. Documentos podem ser gerados em uma etapa separada.';
  } catch (error) {
    message.style.color = 'var(--accent)';
    message.textContent = error.message;
  } finally {
    button.disabled = false;
    button.textContent = 'Salvar';
  }
}

function hasUnsavedOrderDraft() {
  if (orderCreateSaved) return false;
  const fields = [
    'orderClientSapCode',
    'orderCnpj',
    'orderClient',
    'orderCadastroSearch',
    'orderPhone',
    'orderClientRef',
    'orderAddress',
    'orderCarrierSearch',
    'orderCarrier',
    'orderNotes'
  ];
  return orderItems.length > 0 || fields.some((id) => {
    const field = document.getElementById(id);
    return field && String(field.value || '').trim();
  });
}

function clientSearchDigits(value) {
  return String(value || '').replace(/\D/g, '');
}

function normalizeClientLookup(value) {
  return String(value || '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
}

function isClientLookupReady(term) {
  const value = String(term || '').trim();
  const digits = clientSearchDigits(value);
  return digits.length >= 8 || value.length >= 3;
}

function findExactClientMatch(rows, term) {
  const raw = String(term || '').trim();
  const digits = clientSearchDigits(raw);
  const normalized = normalizeClientLookup(raw);
  return (rows || []).find((row) => {
    const rowCnpj = clientSearchDigits(row.cnpj || '');
    const rowSap = normalizeClientLookup(row.codigo_sap_cliente || '');
    const rowProtocol = normalizeClientLookup(row.protocolo || '');
    const rowRazao = normalizeClientLookup(row.razao_social || '');
    const rowFantasia = normalizeClientLookup(row.nome_fantasia || '');
    if (digits.length >= 8 && rowCnpj && rowCnpj === digits) return true;
    if (normalized && rowSap && rowSap === normalized) return true;
    if (normalized && rowProtocol && rowProtocol === normalized) return true;
    return Boolean(normalized && (rowRazao === normalized || rowFantasia === normalized));
  }) || null;
}

function getOrderClientSearchTerm(sourceId) {
  if (sourceId) return (document.getElementById(sourceId) || {}).value || '';
  return [
    'orderCadastroSearch',
    'orderClientSapCode',
    'orderCnpj',
    'orderClient'
  ].map((id) => (document.getElementById(id) || {}).value || '').find((value) => String(value).trim()) || '';
}

function scheduleOrderClientAutoSearch(event) {
  const term = getOrderClientSearchTerm(event.target.id);
  window.clearTimeout(orderClientSearchTimer);
  if (!isClientLookupReady(term)) return;
  orderClientSearchTimer = window.setTimeout(() => {
    searchCadastrosForOrder({ term, auto: true });
  }, 450);
}

async function searchCadastrosForOrder(options = {}) {
  const target = document.getElementById('orderCadastroResults');
  const term = options.term !== undefined ? options.term : getOrderClientSearchTerm();
  if (!isClientLookupReady(term)) {
    target.innerHTML = '<div class="empty-state compact-state">Digite pelo menos 3 caracteres ou CNPJ/codigo para buscar.</div>';
    return;
  }
  target.innerHTML = '<div class="empty-state compact-state">Buscando clientes...</div>';
  try {
    const rows = await supabaseSearchOrderClients(term);
    const exact = findExactClientMatch(rows, term);
    if (exact) {
      applyCadastroToOrder(exact);
      target.innerHTML = '<div class="empty-state compact-state">Cliente encontrado e carregado automaticamente.</div>';
      return;
    }
    target.innerHTML = renderOrderCadastrosResults(rows);
    target.querySelectorAll('[data-use-cadastro]').forEach((button) => {
      button.addEventListener('click', () => applyCadastroToOrder(rows[Number(button.dataset.useCadastro)]));
    });
  } catch (error) {
    target.innerHTML = `<div class="empty-state compact-state">${escapeHtml(error.message)}</div>`;
  }
}

function renderOrderCadastrosResults(rows) {
  if (!rows.length) return '<div class="empty-state compact-state">Nenhum cliente encontrado.</div>';
  return `
    <div class="table-wrap compact-table">
      <table>
        <thead>
          <tr>
            <th>Empresa</th>
            <th>CNPJ</th>
            <th>Codigo SAP</th>
            <th>Origem</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          ${rows.map((row, index) => `
            <tr>
              <td>
                <strong>${escapeHtml(row.razao_social || row.nome_fantasia || '')}</strong>
                <small>${escapeHtml([row.protocolo, row.cidade, row.estado].filter(Boolean).join(' | '))}</small>
              </td>
              <td>${escapeHtml(formatCnpj(row.cnpj || ''))}</td>
              <td>${escapeHtml(row.codigo_sap_cliente || '')}</td>
              <td>${escapeHtml(row.origem === 'cliente' ? 'CRM' : 'Portal')}</td>
              <td><button class="btn btn-secondary" type="button" data-use-cadastro="${index}">Usar</button></td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  `;
}

function applyCadastroToOrder(row) {
  document.getElementById('orderClientSapCode').value = row.codigo_sap_cliente || '';
  document.getElementById('orderClient').value = row.razao_social || row.nome_fantasia || '';
  document.getElementById('orderCnpj').value = formatCnpj(row.cnpj || '');
  document.getElementById('orderPhone').value = row.whatsapp || row.telefone || '';
  document.getElementById('orderAddress').value = formatCadastroAddress(row);
  document.getElementById('orderTerm').value = row.prazo_desejado || '';
  document.getElementById('orderCarrier').value = row.transportadora || '';
  const message = document.getElementById('orderMessage');
  message.style.color = 'var(--success)';
  message.textContent = 'Cadastro ' + (row.protocolo || '') + ' carregado no pedido.';
}

async function searchCarriersForOrder() {
  const target = document.getElementById('orderCarrierResults');
  target.innerHTML = '<div class="empty-state compact-state">Buscando transportadoras...</div>';
  try {
    const term = document.getElementById('orderCarrierSearch').value || document.getElementById('orderCarrier').value;
    const rows = await supabaseSearchOrderCarriers(term);
    target.innerHTML = renderOrderCarriersResults(rows);
    target.querySelectorAll('[data-use-carrier]').forEach((button) => {
      button.addEventListener('click', () => applyCarrierToOrder(rows[Number(button.dataset.useCarrier)]));
    });
  } catch (error) {
    target.innerHTML = `<div class="empty-state compact-state">${escapeHtml(error.message)}</div>`;
  }
}

function renderOrderCarriersResults(rows) {
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
              <td><button class="btn btn-secondary" type="button" data-use-carrier="${index}">Usar</button></td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  `;
}

function applyCarrierToOrder(row) {
  document.getElementById('orderCarrier').value = row.nome || '';
  document.getElementById('orderCarrierCnpj').value = formatCnpj(row.cnpj || '');
  document.getElementById('orderCarrierAddress').value = formatCarrierAddress(row);
  const message = document.getElementById('orderMessage');
  message.style.color = 'var(--success)';
  message.textContent = 'Transportadora carregada no pedido.';
}

function formatCarrierAddress(row) {
  return [
    row.endereco,
    [row.cidade, row.estado].filter(Boolean).join('/')
  ].filter(Boolean).join(' - ');
}

function formatCadastroAddress(row) {
  return [
    [row.endereco, row.numero].filter(Boolean).join(', '),
    row.bairro,
    row.complemento,
    [row.cidade, row.estado].filter(Boolean).join('/')
  ].filter(Boolean).join(' - ');
}

async function renderSapImport(container) {
  let currentImportPlan = null;
  let importAnalyzeTimer = null;
  container.innerHTML = `
    <section class="panel">
      <div class="panel-header">
        <div><h2>Importacao SAP</h2><p>Cole a tabela do Excel ou envie um CSV/TSV. O sistema detecta as colunas automaticamente.</p></div>
      </div>
      <div class="field-grid">
        <label class="span-4">O que atualizar?
          <select id="importType">
            <option value="CRISTIANO" selected>Cadastro produtos</option>
            <option value="PORTAL_ESTOQUE">Estoque</option>
            <option value="PRECO_SP">Preco SP</option>
            <option value="PRECO_PR">Preco PR</option>
            <option value="CATALOGO_PESQUISA">Catalogo pesquisa</option>
          </select>
        </label>
        <label class="span-8">Arquivo
          <input id="importFile" type="file" accept=".csv,.tsv,.txt,text/csv,text/tab-separated-values">
        </label>
        <label class="span-12">Tabela colada
          <textarea id="importText" placeholder="CODIGO IPS;DESCRICAO;MARCA;APLICACAO;ANO;IPI;PRECO S/IMP;PRECO C/IMP;ESTOQUE"></textarea>
        </label>
      </div>
      <div class="actions-row">
        <button class="btn btn-primary" id="previewImportButton" type="button">Verificar dados</button>
        <button class="btn btn-secondary" id="applyImportButton" type="button" disabled>Importar</button>
        <button class="btn btn-ghost" id="saveImportTemplateButton" type="button">Salvar padrão</button>
        <button class="btn btn-ghost" id="resetImportTemplateButton" type="button">Resetar modelo</button>
        <button class="btn btn-ghost" id="clearImportButton" type="button">Limpar</button>
        <p id="importMessage" class="form-message"></p>
      </div>
    </section>
    <section class="panel">
      <details class="import-help">
        <summary>Ver modelos aceitos</summary>
        <div id="importTemplate"></div>
      </details>
      <details class="import-help" id="importMappingDetails">
        <summary>Ajustar colunas detectadas</summary>
        <div id="importMapping">
          <div class="empty-state">Cole ou selecione um arquivo para mapear as colunas.</div>
        </div>
      </details>
    </section>
    <section class="panel" id="importPreview">
      <div class="empty-state">Envie um arquivo ou cole uma tabela para analisar automaticamente.</div>
    </section>
  `;

  const refreshImportTemplate = () => {
    document.getElementById('importTemplate').innerHTML = renderImportTemplate(document.getElementById('importType').value);
    const copyButton = document.getElementById('copyImportTemplate');
    const fillButton = document.getElementById('fillImportTemplate');
    copyButton.addEventListener('click', async () => {
      await navigator.clipboard.writeText(getImportTemplate(document.getElementById('importType').value).sample);
      document.getElementById('importMessage').style.color = 'var(--success)';
      document.getElementById('importMessage').textContent = 'Modelo copiado.';
    });
    fillButton.addEventListener('click', () => {
      document.getElementById('importText').value = getImportTemplate(document.getElementById('importType').value).sample;
      currentImportPlan = null;
      document.getElementById('applyImportButton').disabled = true;
      document.getElementById('importPreview').innerHTML = '<div class="empty-state">Modelo carregado. Analisando automaticamente...</div>';
      analyzeImportAutomatically({ detectType: false });
    });
  };
  refreshImportTemplate();

  const refreshImportMapping = () => {
    currentImportPlan = null;
    document.getElementById('applyImportButton').disabled = true;
    const target = document.getElementById('importMapping');
    const text = document.getElementById('importText').value;
    try {
      const plan = getImportColumnPlan(text, document.getElementById('importType').value);
      target.innerHTML = renderImportMapping(plan);
    } catch (error) {
      target.innerHTML = `<div class="empty-state">${escapeHtml(error.message)}</div>`;
    }
  };

  const analyzeImportAutomatically = async ({ detectType = false, forceTemplate = false, reason = 'auto' } = {}) => {
    const text = document.getElementById('importText').value.trim();
    const message = document.getElementById('importMessage');
    const preview = document.getElementById('importPreview');
    const applyButton = document.getElementById('applyImportButton');
    if (!text) return;
    currentImportPlan = null;
    applyButton.disabled = true;
    message.style.color = 'var(--muted)';
    message.textContent = reason === 'file' ? 'Arquivo recebido. Analisando colunas...' : 'Analisando tabela...';
    preview.innerHTML = '<div class="empty-state">Organizando a planilha para importacao...</div>';
    try {
      const analysis = getImportAutoAnalysis(text, document.getElementById('importType').value);
      if (detectType && analysis.suggestedType) {
        document.getElementById('importType').value = analysis.suggestedType;
        refreshImportTemplate();
      }
      const typedAnalysis = getImportColumnPlan(text, document.getElementById('importType').value);
      const templateMatch = applySavedImportTemplate(
        typedAnalysis,
        loadImportMappingTemplate(document.getElementById('importType').value),
        forceTemplate
      );
      const finalAnalysis = templateMatch.useTemplate ? templateMatch.analysis : typedAnalysis;
      document.getElementById('importMapping').innerHTML = renderImportMapping(finalAnalysis, templateMatch);
      currentImportPlan = await supabasePreviewImportProducts({
        tipo: document.getElementById('importType').value,
        texto: text,
        mapping: getCurrentImportMapping()
      });
      preview.innerHTML = renderImportPreview(currentImportPlan, { automatic: true, templateMatch });
      message.style.color = 'var(--success)';
      message.textContent = templateMatch.useTemplate
        ? 'Modelo aprendido aplicado. Confira a previa e clique em Importar.'
        : 'Analise pronta. Confira a previa reorganizada e clique em Importar.';
      applyButton.disabled = false;
    } catch (error) {
      currentImportPlan = null;
      preview.innerHTML = `<div class="empty-state">${escapeHtml(error.message)}</div>`;
      message.style.color = 'var(--accent)';
      message.textContent = error.message;
    }
  };

  const scheduleImportAnalysis = () => {
    window.clearTimeout(importAnalyzeTimer);
    importAnalyzeTimer = window.setTimeout(() => analyzeImportAutomatically({ detectType: true }), 800);
  };

  const previewWithCurrentMapping = async ({ automatic = false, messageText = 'Dados verificados. Pode importar.' } = {}) => {
    const message = document.getElementById('importMessage');
    const preview = document.getElementById('importPreview');
    const applyButton = document.getElementById('applyImportButton');
    const text = document.getElementById('importText').value;
    currentImportPlan = await supabasePreviewImportProducts({
      tipo: document.getElementById('importType').value,
      texto: text,
      mapping: getCurrentImportMapping()
    });
    preview.innerHTML = renderImportPreview(currentImportPlan, { automatic });
    message.style.color = 'var(--success)';
    message.textContent = messageText;
    applyButton.disabled = false;
  };

  document.getElementById('importFile').addEventListener('change', async (event) => {
    const file = event.target.files && event.target.files[0];
    if (!file) return;
    document.getElementById('importText').value = await file.text();
    currentImportPlan = null;
    document.getElementById('applyImportButton').disabled = true;
    await analyzeImportAutomatically({ detectType: true, reason: 'file' });
  });

  document.getElementById('importText').addEventListener('input', () => {
    currentImportPlan = null;
    document.getElementById('applyImportButton').disabled = true;
    document.getElementById('importPreview').innerHTML = '<div class="empty-state">Aguardando a analise automatica...</div>';
    scheduleImportAnalysis();
  });

  document.getElementById('importType').addEventListener('change', () => {
    currentImportPlan = null;
    document.getElementById('applyImportButton').disabled = true;
    refreshImportTemplate();
    refreshImportMapping();
    document.getElementById('importPreview').innerHTML = '<div class="empty-state">Tipo alterado. Recalculando previa...</div>';
    scheduleImportAnalysis();
  });

  document.getElementById('importMapping').addEventListener('change', (event) => {
    if (!event.target.matches('[data-import-map]')) return;
    currentImportPlan = null;
    document.getElementById('applyImportButton').disabled = true;
    document.getElementById('importPreview').innerHTML = '<div class="empty-state">Mapeamento alterado. Reorganizando previa...</div>';
    window.clearTimeout(importAnalyzeTimer);
    importAnalyzeTimer = window.setTimeout(async () => {
      try {
        await previewWithCurrentMapping({
          automatic: true,
          messageText: 'Mapeamento manual aplicado. Salve como novo padrao se quiser reutilizar.'
        });
      } catch (error) {
        currentImportPlan = null;
        document.getElementById('importPreview').innerHTML = `<div class="empty-state">${escapeHtml(error.message)}</div>`;
        document.getElementById('importMessage').style.color = 'var(--accent)';
        document.getElementById('importMessage').textContent = error.message;
      }
    }, 300);
  });

  document.getElementById('importPreview').addEventListener('click', async (event) => {
    const action = event.target.dataset.importTemplateAction;
    if (!action) return;
    if (action === 'review') {
      document.getElementById('importMappingDetails').open = true;
      document.getElementById('importMappingDetails').scrollIntoView({ behavior: 'smooth', block: 'start' });
      return;
    }
    if (action === 'use') {
      await analyzeImportAutomatically({ detectType: false, forceTemplate: true, reason: 'template' });
      return;
    }
    if (action === 'reset') {
      resetImportMappingTemplate(document.getElementById('importType').value);
      await analyzeImportAutomatically({ detectType: false, reason: 'reset' });
    }
  });

  document.getElementById('saveImportTemplateButton').addEventListener('click', () => {
    const message = document.getElementById('importMessage');
    try {
      const template = saveCurrentImportMappingTemplate();
      message.style.color = 'var(--success)';
      message.textContent = 'Modelo salvo para ' + getImportTypeLabel(template.tipo) + '.';
    } catch (error) {
      message.style.color = 'var(--accent)';
      message.textContent = error.message;
    }
  });

  document.getElementById('resetImportTemplateButton').addEventListener('click', async () => {
    const message = document.getElementById('importMessage');
    resetImportMappingTemplate(document.getElementById('importType').value);
    message.style.color = 'var(--success)';
    message.textContent = 'Modelo desta importacao resetado.';
    await analyzeImportAutomatically({ detectType: false, reason: 'reset' });
  });

  document.getElementById('clearImportButton').addEventListener('click', () => {
    currentImportPlan = null;
    document.getElementById('importText').value = '';
    document.getElementById('importFile').value = '';
    document.getElementById('applyImportButton').disabled = true;
    document.getElementById('importMessage').textContent = '';
    document.getElementById('importMapping').innerHTML = '<div class="empty-state">Cole ou selecione um arquivo para mapear as colunas.</div>';
    document.getElementById('importPreview').innerHTML = '<div class="empty-state">Envie um arquivo ou cole uma tabela para analisar automaticamente.</div>';
  });

  document.getElementById('previewImportButton').addEventListener('click', async () => {
    const message = document.getElementById('importMessage');
    const preview = document.getElementById('importPreview');
    const previewButton = document.getElementById('previewImportButton');
    message.style.color = 'var(--muted)';
    message.textContent = 'Verificando dados...';
    preview.innerHTML = '<div class="empty-state">Lendo dados e comparando com o Supabase...</div>';
    document.getElementById('applyImportButton').disabled = true;
    previewButton.disabled = true;
    try {
      if (!document.querySelector('[data-import-map]')) refreshImportMapping();
      await previewWithCurrentMapping();
    } catch (error) {
      currentImportPlan = null;
      preview.innerHTML = `<div class="empty-state">${escapeHtml(error.message)}</div>`;
      message.style.color = 'var(--accent)';
      message.textContent = error.message;
    } finally {
      previewButton.disabled = false;
    }
  });

  document.getElementById('applyImportButton').addEventListener('click', async () => {
    const message = document.getElementById('importMessage');
    const preview = document.getElementById('importPreview');
    const button = document.getElementById('applyImportButton');
    if (!currentImportPlan) {
      message.style.color = 'var(--accent)';
      message.textContent = 'Gere a previa antes de aplicar.';
      return;
    }
    button.disabled = true;
    message.style.color = 'var(--muted)';
    message.textContent = 'Importando 0 de ' + currentImportPlan.validRows + ' produtos...';
    try {
      const file = document.getElementById('importFile').files && document.getElementById('importFile').files[0];
      saveCurrentImportMappingTemplate();
      const data = await supabaseImportProducts({
        tipo: document.getElementById('importType').value,
        texto: document.getElementById('importText').value,
        fileName: file ? file.name : null,
        mapping: getCurrentImportMapping(),
        onProgress: (progress) => {
          message.textContent = 'Importando lote ' + progress.batch + ' de ' + progress.batches + ' - ' + progress.done + ' de ' + progress.total + ' produtos...';
        }
      });
      message.style.color = 'var(--success)';
      message.textContent = 'Importacao aplicada com sucesso.';
      preview.innerHTML = renderImportResult(data.summary);
      currentImportPlan = null;
    } catch (error) {
      message.style.color = 'var(--accent)';
      message.textContent = error.message;
      button.disabled = false;
    }
  });
}

function getImportFieldOptions() {
  return [
    ['', 'Ignorar'],
    ['codigo', 'Codigo'],
    ['descricao', 'Descricao'],
    ['marca', 'Marca'],
    ['aplicacao', 'Aplicacao'],
    ['ano', 'Ano'],
    ['ipi', 'IPI'],
    ['preco_sem_imposto', 'Preco s/ imposto'],
    ['preco_referencia', 'Preco c/ imposto ref.'],
    ['preco_sp', 'Preco SP'],
    ['preco_pr', 'Preco PR'],
    ['estoque', 'Estoque'],
    ['status_estoque', 'Status estoque'],
    ['grupo', 'Grupo'],
    ['categoria', 'Categoria'],
    ['montadora', 'Montadora'],
    ['detalhes', 'Detalhes/palavras-chave'],
    ['oem', 'OEM'],
    ['similar', 'Similar']
  ];
}

function getImportTemplateType(type) {
  return normalizeImportType(type || 'CRISTIANO');
}

function getImportTypeLabel(type) {
  const labels = {
    CADASTRO_COMPLETO: 'Cadastro produtos',
    PORTAL_ESTOQUE: 'Estoque',
    PRECO_SP: 'Preco SP',
    PRECO_PR: 'Preco PR',
    CATALOGO_PESQUISA: 'Catalogo pesquisa'
  };
  return labels[getImportTemplateType(type)] || type;
}

function getImportTemplateStorageKey(type) {
  return 'import_mapping_template_' + getImportTemplateType(type);
}

function loadImportMappingTemplate(type) {
  try {
    const raw = localStorage.getItem(getImportTemplateStorageKey(type));
    return raw ? JSON.parse(raw) : null;
  } catch (error) {
    return null;
  }
}

function resetImportMappingTemplate(type) {
  localStorage.removeItem(getImportTemplateStorageKey(type));
}

function saveImportMappingTemplate(type, headers, mapping) {
  const template = {
    tipo: getImportTemplateType(type),
    headers: headers.slice(),
    normalizedHeaders: headers.map(normalizeHeader),
    mapping: Object.assign({}, mapping),
    updatedAt: new Date().toISOString()
  };
  localStorage.setItem(getImportTemplateStorageKey(type), JSON.stringify(template));
  return template;
}

function saveCurrentImportMappingTemplate() {
  const text = document.getElementById('importText').value.trim();
  if (!text) throw new Error('Cole ou selecione uma planilha antes de salvar o modelo.');
  const type = document.getElementById('importType').value;
  const plan = getImportColumnPlan(text, type);
  const mapping = getCurrentImportMapping();
  if (!Object.values(mapping).includes('codigo')) {
    throw new Error('O modelo precisa ter uma coluna mapeada como Codigo.');
  }
  return saveImportMappingTemplate(type, plan.headers, mapping);
}

function applySavedImportTemplate(plan, template, force = false) {
  const empty = {
    hasTemplate: false,
    useTemplate: false,
    compatible: false,
    similarity: 0,
    changed: false,
    analysis: plan,
    template: null
  };
  if (!template || !template.normalizedHeaders || !template.mapping) return empty;

  const currentNormalized = plan.headers.map(normalizeHeader);
  const savedSet = new Set(template.normalizedHeaders);
  const matchedHeaders = currentNormalized.filter((header) => savedSet.has(header));
  const similarity = currentNormalized.length ? matchedHeaders.length / currentNormalized.length : 0;
  const savedMappingByNormalized = {};
  template.headers.forEach((header) => {
    savedMappingByNormalized[normalizeHeader(header)] = template.mapping[header] || '';
  });
  const savedMappingByIndex = template.headers.map((header) => template.mapping[header] || '');

  const mapped = {};
  plan.headers.forEach((header, index) => {
    const normalized = normalizeHeader(header);
    mapped[header] = savedMappingByNormalized[normalized] || (force ? savedMappingByIndex[index] : '') || plan.mapping[header] || '';
  });

  const hasCodigo = Object.values(mapped).includes('codigo');
  const compatible = hasCodigo && similarity >= 0.5;
  const useTemplate = force || compatible;
  return {
    hasTemplate: true,
    useTemplate,
    compatible,
    similarity,
    changed: !compatible,
    analysis: Object.assign({}, plan, { mapping: useTemplate ? mapped : plan.mapping }),
    template
  };
}

function renderImportMapping(plan, templateMatch = null) {
  if (!plan.headers.length) return '<div class="empty-state">Nenhum cabecalho encontrado.</div>';
  const templateInfo = templateMatch && templateMatch.hasTemplate
    ? `<p class="mapping-note">${templateMatch.useTemplate ? 'Modelo aprendido aplicado.' : 'Modelo salvo encontrado, mas a estrutura mudou.'} Compatibilidade: ${Math.round(templateMatch.similarity * 100)}%.</p>`
    : '<p class="mapping-note">Nenhum modelo salvo para este tipo. Ajuste uma vez e salve como padrao.</p>';
  return `
    <div class="panel-header">
      <div><h2>Mapeamento de colunas</h2><p>Confirme para onde cada coluna da sua tabela deve ir.</p></div>
    </div>
    ${templateInfo}
    <div class="mapping-grid">
      ${plan.headers.map((header) => renderMappingRow(header, plan.mapping[header], plan.sampleRows)).join('')}
    </div>
  `;
}

function renderMappingRow(header, selected, sampleRows) {
  const normalized = normalizeHeader(header);
  const sample = sampleRows.map((row) => row[normalized]).filter(Boolean).slice(0, 2).join(' | ');
  return `
    <label class="mapping-row">
      <span>
        <strong>${escapeHtml(header)}</strong>
        <small>${escapeHtml(sample)}</small>
      </span>
      <select data-import-map="${escapeHtml(header)}">
        ${getImportFieldOptions().map(([value, label]) => `
          <option value="${escapeHtml(value)}"${value === selected ? ' selected' : ''}>${escapeHtml(label)}</option>
        `).join('')}
      </select>
    </label>
  `;
}

function getCurrentImportMapping() {
  return Object.fromEntries(
    Array.from(document.querySelectorAll('[data-import-map]')).map((select) => [
      select.dataset.importMap,
      select.value
    ])
  );
}

function getImportTemplate(type) {
  const templates = {
    PORTAL_ESTOQUE: {
      title: 'Lista de estoque',
      required: ['codigo', 'estoque'],
      optional: ['status estoque'],
      sample: 'codigo;estoque;status estoque\n7146505811;50+;DISPONIVEL\n6111032201;0;SEM ESTOQUE',
      notes: [
        'Atualiza somente estoque e status de estoque.',
        'Nao altera descricao, marca nem precos.'
      ]
    },
    PRECO_SP: {
      title: 'Tabela de preco SP',
      required: ['codigo', 'preco'],
      optional: ['codigo ips', 'preco c/imp', 'valor', 'pr.unit.(c/i)', 'pr apos desc'],
      sample: 'CODIGO IPS;PRECO C/IMP\n7146505811;522,49\n6111032201;184,90',
      notes: [
        'Atualiza somente o preco SP.',
        'Aceita cabecalhos como PRECO C/IMP, VALOR ou PR.UNIT.(C/I).',
        'Use virgula ou ponto para decimais.'
      ]
    },
    PRECO_PR: {
      title: 'Tabela de preco PR',
      required: ['codigo', 'preco'],
      optional: ['codigo ips', 'preco c/imp', 'valor', 'pr.unit.(c/i)', 'pr apos desc'],
      sample: 'CODIGO IPS;PRECO C/IMP\n7146505811;522,49\n6111032201;179,90',
      notes: [
        'Atualiza somente o preco PR.',
        'Aceita cabecalhos como PRECO C/IMP, VALOR ou PR.UNIT.(C/I).',
        'Use virgula ou ponto para decimais.'
      ]
    },
    CATALOGO_PESQUISA: {
      title: 'Catalogo de pesquisa',
      required: ['codigo'],
      optional: ['linha', 'grupo', 'veiculos', 'detalhes', 'similares'],
      sample: 'CODIGO;LINHA;GRUPO;VEICULOS;DETALHES;SIMILARES\n7146505811;DIRECAO;BOMBA;PALIO E-TORQ 11/20;BOMBA DIR.HIDRAULICA;7146505810',
      notes: [
        'Enriquece a busca e a listagem de produtos com linha, grupo, veiculos, detalhes e similares.',
        'Nao altera estoque nem valor. Esses campos continuam vindo das importacoes de estoque e preco.'
      ]
    },
    CRISTIANO: {
      title: 'Cadastro completo de produtos',
      required: ['codigo ou codigo ips'],
      optional: ['descricao', 'marca', 'aplicacao', 'ano', 'ipi', 'preco s/imp', 'preco c/imp', 'estoque', 'grupo', 'categoria', 'montadora', 'oem', 'similar'],
      sample: 'CODIGO IPS;DESCRICAO;MARCA;APLICACAO;ANO;IPI;PRECO S/IMP;PRECO C/IMP;ESTOQUE\n7146505811;BOMBA DIR.HIDRAULICA;FIAT;PALIO E-TORQ;11/20;0;395,00;522,49;50+',
      notes: [
        'Esse formato aceita a planilha com CODIGO IPS, DESCRICAO, MARCA, APLICACAO, ANO, IPI, PRECO S/IMP, PRECO C/IMP e ESTOQUE.',
        'PRECO C/IMP fica apenas como referencia visual nessa importacao e nao altera SP nem PR.',
        'Para atualizar preco estadual, use os tipos Preco SP ou Preco PR separadamente.',
        'Ideal para carga completa ou revisao geral.'
      ]
    }
  };
  return templates[type] || templates.CATALOGO_PESQUISA;
}

function renderImportTemplate(type) {
  const template = getImportTemplate(type);
  return `
    <div class="panel-header">
      <div><h2>Formato esperado</h2><p>${escapeHtml(template.title)}</p></div>
      <div class="actions-row">
        <button class="btn btn-secondary" id="copyImportTemplate" type="button">Copiar modelo</button>
        <button class="btn btn-ghost" id="fillImportTemplate" type="button">Usar exemplo</button>
      </div>
    </div>
    <div class="import-format">
      <div>
        <span>Obrigatorias</span>
        <strong>${template.required.map(escapeHtml).join(', ')}</strong>
      </div>
      <div>
        <span>Aceitas</span>
        <strong>${template.optional.map(escapeHtml).join(', ')}</strong>
      </div>
    </div>
    <pre class="import-sample"><code>${escapeHtml(template.sample)}</code></pre>
    <ul class="import-notes">
      ${template.notes.map((note) => `<li>${escapeHtml(note)}</li>`).join('')}
    </ul>
  `;
}

function renderImportPreview(plan, options = {}) {
  const invalid = plan.invalidRows.length
    ? `<div class="import-warnings"><strong>${plan.invalidRows.length} linhas ignoradas</strong><span>${plan.invalidRows.slice(0, 5).map((row) => `Linha ${row.linha}: ${escapeHtml(row.motivo)}`).join(' | ')}</span></div>`
    : '';
  const duplicates = plan.duplicates
    ? `<div class="import-warnings"><strong>${plan.duplicates} codigos repetidos</strong><span>O sistema junta as linhas do mesmo codigo: o ultimo valor preenchido vence e campos vazios nao apagam dados anteriores. ${escapeHtml((plan.duplicateCodes || []).slice(0, 8).join(', '))}</span></div>`
    : '';
  const fields = plan.fieldsUpdated && plan.fieldsUpdated.length
    ? `<div class="import-warnings"><strong>Campos atualizados</strong><span>${plan.fieldsUpdated.map(escapeHtml).join(', ')}</span></div>`
    : '';
  const auto = options.automatic
    ? '<div class="import-warnings"><strong>Planilha reorganizada</strong><span>As colunas foram convertidas para o formato interno do CRM. Confira a amostra abaixo antes de importar.</span></div>'
    : '';
  const templateAlert = options.templateMatch && options.templateMatch.hasTemplate && options.templateMatch.changed
    ? `
      <div class="import-template-alert">
        <strong>A estrutura desta planilha parece diferente do modelo salvo. Deseja revisar o mapeamento?</strong>
        <span>Compatibilidade com o modelo: ${Math.round(options.templateMatch.similarity * 100)}%.</span>
        <div class="actions-row">
          <button class="btn btn-secondary" type="button" data-import-template-action="review">Revisar mapeamento</button>
          <button class="btn btn-primary" type="button" data-import-template-action="use">Usar mesmo assim</button>
          <button class="btn btn-ghost" type="button" data-import-template-action="reset">Resetar modelo</button>
        </div>
      </div>
    `
    : '';
  return `
    <div class="import-summary">
      <article><span>Linhas</span><strong>${plan.totalRows}</strong></article>
      <article><span>Validas</span><strong>${plan.validRows}</strong></article>
      <article><span>Unicos</span><strong>${plan.uniqueRows}</strong></article>
      <article><span>Novos</span><strong>${plan.newCount}</strong></article>
      <article><span>Atualizacoes</span><strong>${plan.existingCount}</strong></article>
      <article><span>Duplicados</span><strong>${plan.duplicates}</strong></article>
    </div>
    ${templateAlert}
    ${auto}
    ${fields}
    ${duplicates}
    ${invalid}
    ${renderImportTable(plan.preview)}
  `;
}

function renderImportResult(summary) {
  return `
    <div class="import-summary">
      <article><span>Recebidos</span><strong>${summary.total_recebido}</strong></article>
      <article><span>Novos</span><strong>${summary.novos}</strong></article>
      <article><span>Atualizados</span><strong>${summary.atualizados}</strong></article>
      <article><span>Ignorados</span><strong>${summary.erros}</strong></article>
    </div>
  `;
}

function renderImportTable(products) {
  if (!products.length) return '<div class="empty-state">Nenhum item para exibir.</div>';
  return `
    <div class="table-wrap import-table">
      <table>
        <thead><tr><th>Codigo</th><th>Descricao</th><th>Estoque</th><th>SP</th><th>PR</th><th>Marca</th></tr></thead>
        <tbody>
          ${products.map((product) => `
            <tr>
              <td>${escapeHtml(product.codigo)}</td>
              <td>${escapeHtml(product.descricao)}</td>
              <td>${escapeHtml(product.estoque)}</td>
              <td>${product.preco_sp == null ? '' : money(product.preco_sp)}</td>
              <td>${product.preco_pr == null ? '' : money(product.preco_pr)}</td>
              <td>${escapeHtml(product.marca)}</td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  `;
}
