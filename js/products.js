const productState = {
  searchTimer: null,
  results: [],
  favorites: new Set(),
  recent: [],
  topSelling: [],
  selected: null
};

async function renderProducts(container) {
  container.innerHTML = `
    <section class="product-shell">
      <section class="panel product-search-panel">
        <div class="panel-header">
          <div>
            <h2>Produtos</h2>
            <p>Busca rapida por codigo, OEM, similares, aplicacoes, montadoras, marca, linha e grupo.</p>
          </div>
        </div>
        <form id="productSearchForm" class="product-search-grid">
          <label class="product-search-main">Pesquisa inteligente
            <input id="productTerm" type="search" placeholder="Codigo, OEM, similar, veiculo, marca ou aplicacao" autocomplete="off">
          </label>
          <label>Estado
            <select id="productRegion"><option>SP</option><option>PR</option></select>
          </label>
          <label>Linha
            <select id="productLineFilter"><option value="">Todas</option></select>
          </label>
          <label>Grupo
            <select id="productGroupFilter"><option value="">Todos</option></select>
          </label>
          <label>Montadora
            <select id="productMakerFilter"><option value="">Todas</option></select>
          </label>
          <label class="product-toggle"><input id="productAvailableFilter" type="checkbox"> Disponiveis</label>
          <label class="product-toggle"><input id="productOemFilter" type="checkbox"> Com OEM</label>
          <label class="product-toggle"><input id="productPhotoFilter" type="checkbox"> Com foto</label>
          <label class="product-toggle"><input id="productFavoritesFilter" type="checkbox"> Favoritos</label>
          <div class="product-search-actions">
            <button class="btn btn-primary" type="submit">Pesquisar</button>
            <button class="btn btn-secondary" id="productGeneralListButton" type="button">Lista geral</button>
            <button class="btn btn-ghost" id="productClearFiltersButton" type="button">Limpar</button>
            <p id="productMessage" class="form-message"></p>
          </div>
        </form>
      </section>

      <section class="product-insights-grid">
        <section class="panel">
          <div class="panel-header"><div><h2>Recentemente consultados</h2><p>Ultimos produtos abertos neste usuario.</p></div></div>
          <div id="productRecentList" class="product-mini-list"><div class="empty-state compact-state">Carregando recentes...</div></div>
        </section>
        <section class="panel">
          <div class="panel-header"><div><h2>Mais vendidos</h2><p>Ranking calculado por itens de pedidos.</p></div></div>
          <div id="productTopList" class="product-mini-list"><div class="empty-state compact-state">Carregando ranking...</div></div>
        </section>
      </section>

      <section class="product-layout">
        <section class="panel" id="productResults">
          <div class="empty-state">Digite para pesquisar ou gere uma lista geral.</div>
        </section>
        <aside class="panel product-detail-panel" id="productDetail">
          <div class="empty-state compact-state">Selecione um produto para ver foto, OEM, similares, aplicacoes e historicos.</div>
        </aside>
      </section>
    </section>
  `;

  await Promise.all([
    loadProductFilterOptions(),
    loadProductSideData()
  ]);

  bindProductSearch();
}

function bindProductSearch() {
  const form = document.getElementById('productSearchForm');
  const term = document.getElementById('productTerm');
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    await runProductSearch();
  });
  term.addEventListener('input', () => {
    window.clearTimeout(productState.searchTimer);
    productState.searchTimer = window.setTimeout(() => runProductSearch({ silentEmpty: true }), 180);
  });
  [
    'productRegion',
    'productLineFilter',
    'productGroupFilter',
    'productMakerFilter',
    'productAvailableFilter',
    'productOemFilter',
    'productPhotoFilter',
    'productFavoritesFilter'
  ].forEach((id) => {
    document.getElementById(id).addEventListener('change', () => runProductSearch({ silentEmpty: true }));
  });
  document.getElementById('productGeneralListButton').addEventListener('click', () => runProductSearch({ listaGeral: true }));
  document.getElementById('productClearFiltersButton').addEventListener('click', clearProductFilters);
}

async function runProductSearch(options = {}) {
  await searchProductsInto(document.getElementById('productResults'), getProductSearchParams(options));
}

function getProductSearchParams(options = {}) {
  return {
    termo: document.getElementById('productTerm').value,
    regiao: document.getElementById('productRegion').value,
    linha: document.getElementById('productLineFilter').value,
    grupo: document.getElementById('productGroupFilter').value,
    montadora: document.getElementById('productMakerFilter').value,
    disponiveis: document.getElementById('productAvailableFilter').checked,
    comOem: document.getElementById('productOemFilter').checked,
    comFoto: document.getElementById('productPhotoFilter').checked,
    favoritos: document.getElementById('productFavoritesFilter').checked,
    listaGeral: options.listaGeral === true,
    silentEmpty: options.silentEmpty === true,
    limite: options.listaGeral ? 5000 : 600
  };
}

function clearProductFilters() {
  document.getElementById('productTerm').value = '';
  document.getElementById('productLineFilter').value = '';
  document.getElementById('productGroupFilter').value = '';
  document.getElementById('productMakerFilter').value = '';
  document.getElementById('productAvailableFilter').checked = false;
  document.getElementById('productOemFilter').checked = false;
  document.getElementById('productPhotoFilter').checked = false;
  document.getElementById('productFavoritesFilter').checked = false;
  document.getElementById('productResults').innerHTML = '<div class="empty-state">Digite para pesquisar ou gere uma lista geral.</div>';
  document.getElementById('productDetail').innerHTML = '<div class="empty-state compact-state">Selecione um produto para ver foto, OEM, similares, aplicacoes e historicos.</div>';
  document.getElementById('productMessage').textContent = '';
  productState.results = [];
  productState.selected = null;
}

async function searchProductsInto(target, params, onAdd) {
  const hasQuery = String(params.termo || '').trim() || params.listaGeral || params.linha || params.grupo || params.montadora || params.disponiveis || params.comOem || params.comFoto || params.favoritos;
  if (!hasQuery) {
    if (!params.silentEmpty) target.innerHTML = '<div class="empty-state">Digite um termo para pesquisar.</div>';
    return;
  }
  target.innerHTML = '<div class="empty-state">Pesquisando produtos...</div>';
  try {
    const products = await supabaseSearchProducts(Object.assign({}, params, { context: onAdd ? 'pedido' : 'produtos' }));
    if (!products.length) {
      target.innerHTML = '<div class="empty-state">Nenhum produto encontrado.</div>';
      return;
    }
    if (onAdd) {
      renderProductPickerResults(target, products, onAdd);
      return;
    }
    productState.results = products;
    target.innerHTML = renderProductCatalog(products, params);
    bindProductCatalog(products, params);
  } catch (error) {
    target.innerHTML = `<div class="empty-state">${escapeHtml(error.message)}</div>`;
  }
}

function renderProductPickerResults(target, products, onAdd) {
  target.innerHTML = `
    <div class="table-wrap">
      <table>
        <thead><tr><th>Codigo</th><th>Descricao</th><th>Marca</th><th>Aplicacao</th><th>Estoque</th><th>Preco</th><th></th></tr></thead>
        <tbody>
          ${products.map((p, index) => `
            <tr>
              <td>${escapeHtml(p.codigo)}</td>
              <td>${escapeHtml(p.descricao)}</td>
              <td>${escapeHtml(p.marca)}</td>
              <td>${escapeHtml(p.aplicacao)}</td>
              <td>${escapeHtml(p.estoque)}</td>
              <td>${money(p.preco)}</td>
              <td><button class="btn btn-secondary" type="button" data-add-product="${index}">Selecionar</button></td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  `;
  target.querySelectorAll('[data-add-product]').forEach((button) => {
    button.addEventListener('click', () => onAdd(products[Number(button.dataset.addProduct)]));
  });
}

function renderProductCatalog(products, params) {
  const filters = renderProductFilterSummary(params);
  return `
    <div class="panel-header product-results-header">
      <div><h2>${products.length} produtos</h2><p>${escapeHtml(filters || 'Resultado da pesquisa')}</p></div>
      <button class="btn btn-secondary" type="button" data-export-products>Baixar CSV</button>
    </div>
    <div class="product-card-grid">
      ${products.map((product, index) => renderProductCard(product, index)).join('')}
    </div>
  `;
}

function renderProductCard(product, index) {
  const favorite = productState.favorites.has(product.codigo);
  return `
    <article class="product-card" data-open-product="${index}">
      <button class="product-favorite ${favorite ? 'is-active' : ''}" type="button" data-favorite-product="${index}" aria-label="Favorito">${favorite ? '*' : '+'}</button>
      <div class="product-image">${product.url_imagem ? `<img src="${escapeHtml(product.url_imagem)}" alt="${escapeHtml(product.descricao || product.codigo)}" loading="lazy">` : '<span>Sem foto</span>'}</div>
      <div class="product-card-body">
        <div class="product-code">${escapeHtml(product.codigo)}</div>
        <h3>${escapeHtml(product.descricao || 'Produto sem descricao')}</h3>
        <p>${escapeHtml([product.marca, product.montadora, product.linha || product.categoria].filter(Boolean).join(' - '))}</p>
        <div class="product-tags">
          ${renderTag('OEM', product.oem)}
          ${renderTag('Similar', product.similar)}
          ${renderTag('Aplicacao', product.aplicacao)}
        </div>
        <div class="product-card-footer">
          <span>${escapeHtml(product.estoque || 'Estoque nao informado')}</span>
          <strong>${money(product.preco)}</strong>
        </div>
      </div>
    </article>
  `;
}

function bindProductCatalog(products, params) {
  document.querySelectorAll('[data-open-product]').forEach((card) => {
    card.addEventListener('click', () => openProductDetail(products[Number(card.dataset.openProduct)], params));
  });
  document.querySelectorAll('[data-favorite-product]').forEach((button) => {
    button.addEventListener('click', async (event) => {
      event.stopPropagation();
      const product = products[Number(button.dataset.favoriteProduct)];
      const next = !productState.favorites.has(product.codigo);
      const favorites = await supabaseToggleProductFavorite(product.codigo, next);
      productState.favorites = new Set(favorites);
      button.classList.toggle('is-active', next);
      button.textContent = next ? '*' : '+';
      await refreshProductSideData();
    });
  });
  const exportButton = document.querySelector('[data-export-products]');
  if (exportButton) exportButton.addEventListener('click', () => exportProductsCsv(products, params));
}

async function openProductDetail(product, params = {}) {
  if (!product) return;
  productState.selected = product;
  await supabaseRegisterProductView(product.codigo);
  const history = await supabaseGetProductHistory(product.codigo);
  document.getElementById('productDetail').innerHTML = renderProductDetail(product, params, history);
  await refreshProductSideData();
}

function renderProductDetail(product, params, history) {
  return `
    <div class="product-detail">
      <div class="product-detail-image">${product.url_imagem ? `<img src="${escapeHtml(product.url_imagem)}" alt="${escapeHtml(product.descricao || product.codigo)}">` : '<span>Sem foto cadastrada</span>'}</div>
      <div class="product-detail-title">
        <span>${escapeHtml(product.codigo)}</span>
        <h2>${escapeHtml(product.descricao || 'Produto sem descricao')}</h2>
        <strong>${money(product.preco)}</strong>
      </div>
      <dl class="product-detail-grid">
        ${detailItem('Marca', product.marca)}
        ${detailItem('NCM', formatProductNcm(product.ncm))}
        ${detailItem('Linha', product.linha || product.categoria)}
        ${detailItem('Grupo', product.grupo)}
        ${detailItem('Montadora', product.montadora)}
        ${detailItem('OEM', product.oem)}
        ${detailItem('Similares', product.similar)}
        ${detailItem('Aplicacoes', product.aplicacao)}
        ${detailItem('Detalhes consulta', product.detalhes)}
        ${detailItem('Estoque', product.estoque)}
        ${detailItem('Qtd. estoque', product.estoque_quantidade)}
        ${detailItem('Preco SP', money(product.preco_sp))}
        ${detailItem('Preco PR', money(product.preco_pr))}
      </dl>
      <div class="product-history-grid">
        ${renderHistoryBlock('Historico de precos', history.prices)}
        ${renderHistoryBlock('Historico de estoque', history.stock)}
      </div>
    </div>
  `;
}

function detailItem(label, value) {
  return `<div><dt>${escapeHtml(label)}</dt><dd>${escapeHtml(value || '-')}</dd></div>`;
}

function formatProductNcm(value) {
  const digits = String(value || '').replace(/\D/g, '');
  return digits.length === 8 ? `${digits.slice(0, 4)}.${digits.slice(4, 6)}.${digits.slice(6)}` : digits;
}

function renderHistoryBlock(title, rows) {
  return `
    <section>
      <h3>${escapeHtml(title)}</h3>
      ${(rows || []).length ? `
        <ul>
          ${rows.map((row) => `<li><span>${escapeHtml(formatProductDate(row.changed_at))}</span><strong>${escapeHtml(row.field || '')}</strong><small>${escapeHtml(historyValue(row.old_value))} -> ${escapeHtml(historyValue(row.new_value))}</small></li>`).join('')}
        </ul>
      ` : '<div class="empty-state compact-state">Sem historico registrado.</div>'}
    </section>
  `;
}

async function loadProductFilterOptions() {
  const message = document.getElementById('productMessage');
  try {
    const filters = await supabaseListProductFilters();
    fillProductSelect(document.getElementById('productLineFilter'), filters.linhas, 'Todas');
    fillProductSelect(document.getElementById('productGroupFilter'), filters.grupos, 'Todos');
    fillProductSelect(document.getElementById('productMakerFilter'), filters.montadoras, 'Todas');
  } catch (error) {
    message.style.color = 'var(--accent)';
    message.textContent = 'Nao foi possivel carregar filtros.';
  }
}

async function loadProductSideData() {
  const [favorites, recent, topSelling] = await Promise.all([
    supabaseListProductFavorites(),
    supabaseListRecentProducts(6),
    supabaseGetTopSellingProducts(6)
  ]);
  productState.favorites = new Set(favorites);
  productState.recent = recent;
  productState.topSelling = topSelling;
  renderProductSideLists();
}

async function refreshProductSideData() {
  const [recent, topSelling] = await Promise.all([
    supabaseListRecentProducts(6),
    supabaseGetTopSellingProducts(6)
  ]);
  productState.recent = recent;
  productState.topSelling = topSelling;
  renderProductSideLists();
}

function renderProductSideLists() {
  const recent = document.getElementById('productRecentList');
  const top = document.getElementById('productTopList');
  if (recent) recent.innerHTML = renderProductMiniList(productState.recent, 'Nenhum produto consultado.');
  if (top) top.innerHTML = renderProductMiniList(productState.topSelling, 'Sem vendas registradas.');
  document.querySelectorAll('[data-mini-product]').forEach((button) => {
    button.addEventListener('click', async () => {
      const code = button.dataset.miniProduct;
      const product = productState.results.find((item) => item.codigo === code)
        || productState.recent.find((item) => item.codigo === code)
        || productState.topSelling.find((item) => item.codigo === code);
      await openProductDetail(Object.assign({ preco: product && product.preco_sp }, product), {
        regiao: document.getElementById('productRegion') ? document.getElementById('productRegion').value : 'SP'
      });
    });
  });
}

function renderProductMiniList(products, emptyText) {
  if (!products || !products.length) return `<div class="empty-state compact-state">${escapeHtml(emptyText)}</div>`;
  return products.map((product) => `
    <button class="product-mini-item" type="button" data-mini-product="${escapeHtml(product.codigo)}">
      <span>${escapeHtml(product.codigo)}</span>
      <strong>${escapeHtml(product.descricao || product.marca || 'Produto')}</strong>
      <small>${escapeHtml(product.quantidade_vendida ? `${product.quantidade_vendida} vendidos` : product.montadora || product.marca || '')}</small>
    </button>
  `).join('');
}

function fillProductSelect(select, values, emptyLabel) {
  select.innerHTML = `<option value="">${escapeHtml(emptyLabel)}</option>` + (values || [])
    .map((value) => `<option value="${escapeHtml(value)}">${escapeHtml(value)}</option>`)
    .join('');
}

function renderTag(label, value) {
  return value ? `<span>${escapeHtml(label)}: ${escapeHtml(value)}</span>` : '';
}

function renderProductFilterSummary(params) {
  return [
    params.listaGeral ? 'lista geral' : '',
    params.linha ? 'linha: ' + params.linha : '',
    params.grupo ? 'grupo: ' + params.grupo : '',
    params.montadora ? 'montadora: ' + params.montadora : '',
    params.disponiveis ? 'disponiveis' : '',
    params.comOem ? 'com OEM' : '',
    params.comFoto ? 'com foto' : '',
    params.favoritos ? 'favoritos' : '',
    params.termo ? 'busca: ' + params.termo : ''
  ].filter(Boolean).join(' | ');
}

function historyValue(value) {
  if (value == null) return '-';
  if (typeof value === 'object') return JSON.stringify(value);
  return String(value);
}

function formatProductDate(value) {
  if (!value) return '';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  return date.toLocaleString(APP_CONFIG.locale || 'pt-BR');
}

function exportProductsCsv(products, params) {
  const headers = ['codigo', 'linha', 'grupo', 'montadora', 'oem', 'similares', 'aplicacoes', 'estoque', 'preco'];
  const lines = [
    headers.join(';'),
    ...products.map((product) => headers.map((field) => {
      if (field === 'preco') return csvCell(product.preco);
      if (field === 'linha') return csvCell(product.linha || product.categoria);
      if (field === 'similares') return csvCell(product.similar);
      if (field === 'aplicacoes') return csvCell(product.aplicacao);
      return csvCell(product[field]);
    }).join(';'))
  ];
  const blob = new Blob([lines.join('\n')], { type: 'text/csv;charset=utf-8' });
  const link = document.createElement('a');
  link.href = URL.createObjectURL(blob);
  link.download = 'lista-produtos-' + (params.regiao || 'SP').toLowerCase() + '.csv';
  link.click();
  URL.revokeObjectURL(link.href);
}
