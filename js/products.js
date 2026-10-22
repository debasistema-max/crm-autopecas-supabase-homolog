const productState = {
  searchTimer: null,
  results: [],
  favorites: new Set(),
  recent: [],
  topSelling: [],
  selected: null,
  activitySelection: new Map(),
  activityBusy: false
};
const PRODUCT_GENERAL_PAGE_SIZE = 200;
const PRODUCT_XLSX_BATCH_SIZE = 500;
const PRODUCT_XLSX_MAX_OFFSET = 50000;
let productSearchRequestSequence = 0;
const productSearchRequests = new WeakMap();
let productDetailReturnFocus = null;
let productDetailRequestSequence = 0;

function canManageProductActivity() {
  return getStoredSession()?.perfil === 'ADMIN';
}

function isSellerProductCatalog() {
  return String(getStoredSession()?.perfil || '').toUpperCase() === 'VENDEDOR';
}

function renderSellerCatalogActions() {
  const modules = getStoredSession()?.modules || [];
  return `${modules.includes('nova_cotacao') ? '<button class="btn btn-secondary" type="button" data-seller-create="quoteCreate">Nova cotação</button>' : ''}
    ${modules.includes('novo_pedido') ? '<button class="btn btn-primary" type="button" data-seller-create="orderCreate">Novo pedido</button>' : ''}`;
}

async function renderProducts(container) {
  productState.results = [];
  productState.selected = null;
  productState.activitySelection.clear();
  container.innerHTML = `
    <section class="module-page product-shell">
      ${CrmUi.renderPageHeader(
        isSellerProductCatalog() ? 'Produtos' : 'Catalogo de produtos',
        isSellerProductCatalog() ? '' : 'Localize itens, confira disponibilidade, preco por filial e dados comerciais.',
        isSellerProductCatalog() ? renderSellerCatalogActions() : '',
        'Catalogo'
      )}
      <section class="panel product-search-panel">
        <div class="section-heading"><div><h3>Pesquisa e filtros</h3><p>Busque por codigo, OEM, similar, aplicacao, montadora, marca, linha ou grupo.</p></div></div>
        <form id="productSearchForm" class="product-search-grid">
          <label class="product-search-main">Pesquisa inteligente
            <input id="productTerm" type="search" placeholder="Codigo, OEM, similar, veiculo, marca ou aplicacao" autocomplete="off">
          </label>
          <label>Filial de origem
            <select id="productRegion"><option value="SP">Filial SP</option><option value="PR">Matriz PR</option></select>
          </label>
          <label>Estado de destino
            <select id="productDestination">${['SP','PR','AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA','PB','PE','PI','RJ','RN','RS','RO','RR','SC','SE','TO'].map((uf) => `<option value="${uf}">${uf}</option>`).join('')}</select>
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
          <label>Tipo de veiculo
            <select id="productVehicleTypeFilter"><option value="">Todos</option><option value="LEVE">Leve</option><option value="UTILITARIO">Utilitario</option><option value="PESADO">Pesado</option><option value="NAO_CLASSIFICADO">Nao classificado</option></select>
          </label>
          <label class="product-toggle"><input id="productAvailableFilter" type="checkbox"> Disponiveis</label>
          <label class="product-toggle"><input id="productOemFilter" type="checkbox"> Com OEM</label>
          <label class="product-toggle"><input id="productPhotoFilter" type="checkbox"> Com foto</label>
          <label class="product-toggle"><input id="productFavoritesFilter" type="checkbox"> Favoritos</label>
          ${canManageProductActivity() ? '<label class="product-toggle"><input id="productInactiveFilter" type="checkbox"> Gerenciar inativos</label>' : ''}
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
          <div id="productRecentList" class="product-mini-list">${CrmUi.renderState('loading', 'Carregando recentes', 'Consultando seu historico.')}</div>
        </section>
        <section class="panel">
          <div class="panel-header"><div><h2>Mais vendidos</h2><p>Ranking calculado por itens de pedidos.</p></div></div>
          <div id="productTopList" class="product-mini-list">${CrmUi.renderState('loading', 'Carregando ranking', 'Consolidando os itens mais vendidos.')}</div>
        </section>
      </section>

      <section class="product-layout">
        <section class="panel" id="productResults">
          ${CrmUi.renderState('empty', 'Comece uma pesquisa', 'Digite um termo, escolha filtros ou gere a lista geral.')}
        </section>
      </section>

      <div class="product-detail-modal" id="productDetailModal" role="dialog" aria-modal="true" aria-labelledby="productDetailModalTitle" hidden>
        <section class="product-detail-dialog">
          <header class="product-detail-dialog-header">
            <div>
              <span>Ficha do produto</span>
              <strong id="productDetailModalTitle">Detalhes</strong>
            </div>
            <button class="btn btn-secondary product-detail-close" id="productDetailClose" type="button" aria-label="Fechar ficha do produto">Voltar</button>
          </header>
          <div class="product-detail-dialog-body" id="productDetail">
            ${CrmUi.renderState('empty', 'Carregando ficha', 'Aguarde um instante.')}
          </div>
        </section>
      </div>
      <dialog class="product-photo-dialog" id="productPhotoDialog" aria-labelledby="productPhotoTitle">
        <header class="product-photo-header">
          <strong id="productPhotoTitle">Foto do produto</strong>
          <button class="btn btn-secondary" id="productPhotoClose" type="button">Fechar foto</button>
        </header>
        <label class="product-photo-zoom">Zoom <output id="productPhotoZoomValue">100%</output>
          <input id="productPhotoZoom" type="range" min="100" max="300" step="25" value="100" aria-label="Zoom da foto">
        </label>
        <div class="product-photo-viewport" id="productPhotoViewport">
          <div class="product-photo-canvas"><img id="productPhotoImage" alt="" referrerpolicy="no-referrer"></div>
        </div>
        <p id="productPhotoError" role="status" hidden>Não foi possível carregar a foto ampliada.</p>
      </dialog>
    </section>
  `;

  if (isSellerProductCatalog()) arrangeSellerCatalog(container);
  bindProductDetailModal();
  await Promise.all([
    loadProductFilterOptions(),
    loadProductSideData()
  ]);

  bindProductSearch();
}

function arrangeSellerCatalog(container) {
  const form = container.querySelector('#productSearchForm');
  const details = document.createElement('details');
  details.className = 'seller-extra-filters';
  const summary = document.createElement('summary');
  summary.textContent = 'Mais filtros';
  const fields = document.createElement('div');
  fields.className = 'seller-extra-filter-grid';
  ['productLineFilter', 'productMakerFilter', 'productVehicleTypeFilter', 'productOemFilter', 'productPhotoFilter', 'productFavoritesFilter'].forEach((id) => {
    fields.append(container.querySelector(`#${id}`).closest('label'));
  });
  details.append(summary, fields);
  form.append(details);
  form.classList.add('seller-catalog-search');
  container.querySelector('.product-search-main').firstChild.textContent = 'Buscar produto';
  const region = container.querySelector('#productRegion');
  region.previousSibling.textContent = 'Filial de origem';
  // Preserve the branch values used by the existing product queries.
  region.options[0].value = 'SP';
  region.options[0].textContent = 'Filial SP';
  region.options[1].value = 'PR';
  region.options[1].textContent = 'Matriz PR';
  container.querySelector('.product-search-panel .section-heading').remove();
  const insights = container.querySelector('.product-insights-grid');
  const history = document.createElement('details');
  history.className = 'seller-catalog-history';
  const historyTitle = document.createElement('summary');
  historyTitle.textContent = 'Recentemente consultados e mais vendidos';
  insights.before(history);
  history.append(historyTitle, insights);
  container.querySelector('.product-layout').after(history);
  container.querySelectorAll('[data-seller-create]').forEach((button) => {
    button.addEventListener('click', () => openModule(button.dataset.sellerCreate));
  });
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
    'productDestination',
    'productLineFilter',
    'productGroupFilter',
    'productMakerFilter',
    'productAvailableFilter',
    'productOemFilter',
    'productPhotoFilter',
    'productFavoritesFilter',
    'productVehicleTypeFilter'
  ].forEach((id) => {
    document.getElementById(id).addEventListener('change', () => runProductSearch({
      silentEmpty: true,
      listaGeral: ['productRegion', 'productDestination'].includes(id) && productState.results.length > 0
    }));
  });
  document.getElementById('productGeneralListButton').addEventListener('click', () => runProductSearch({ listaGeral: true }));
  document.getElementById('productInactiveFilter')?.addEventListener('change', () => runProductSearch({ listaGeral: true }));
  document.getElementById('productClearFiltersButton').addEventListener('click', clearProductFilters);
}

async function runProductSearch(options = {}) {
  if (productState.activityBusy) return;
  await searchProductsInto(document.getElementById('productResults'), getProductSearchParams(options));
}

function getProductSearchParams(options = {}) {
  const generalList = options.listaGeral === true;
  const offset = generalList ? Math.max(Number(options.offset || 0), 0) : 0;
  return {
    termo: document.getElementById('productTerm').value,
    regiao: document.getElementById('productRegion').value,
    destinoUf: document.getElementById('productDestination').value,
    catalogPricing: true,
    linha: document.getElementById('productLineFilter').value,
    grupo: document.getElementById('productGroupFilter').value,
    montadora: document.getElementById('productMakerFilter').value,
    tipoVeiculo: document.getElementById('productVehicleTypeFilter').value,
    disponiveis: document.getElementById('productAvailableFilter').checked,
    comOem: document.getElementById('productOemFilter').checked,
    comFoto: document.getElementById('productPhotoFilter').checked,
    favoritos: document.getElementById('productFavoritesFilter').checked,
    incluirInativos: canManageProductActivity() && document.getElementById('productInactiveFilter')?.checked === true,
    listaGeral: generalList,
    silentEmpty: options.silentEmpty === true,
    offset,
    pageSize: generalList ? PRODUCT_GENERAL_PAGE_SIZE : 120,
    limite: generalList ? PRODUCT_GENERAL_PAGE_SIZE + 1 : 120
  };
}

function clearProductFilters() {
  if (productState.activityBusy) return;
  productState.activitySelection.clear();
  const inactive = document.getElementById('productInactiveFilter');
  if (inactive) inactive.checked = false;
  document.getElementById('productTerm').value = '';
  document.getElementById('productLineFilter').value = '';
  document.getElementById('productGroupFilter').value = '';
  document.getElementById('productMakerFilter').value = '';
  document.getElementById('productVehicleTypeFilter').value = '';
  document.getElementById('productAvailableFilter').checked = false;
  document.getElementById('productOemFilter').checked = false;
  document.getElementById('productPhotoFilter').checked = false;
  document.getElementById('productFavoritesFilter').checked = false;
  document.getElementById('productResults').innerHTML = CrmUi.renderState('empty', 'Comece uma pesquisa', 'Digite um termo, escolha filtros ou gere a lista geral.');
  closeProductDetail();
  document.getElementById('productMessage').textContent = '';
  productState.results = [];
  productState.selected = null;
}

async function searchProductsInto(target, params, onAdd) {
  if (!onAdd && target.id === 'productResults') {
    productState.activitySelection.clear();
    productState.results = [];
  }
  const requestId = ++productSearchRequestSequence;
  productSearchRequests.set(target, requestId);
  const hasQuery = String(params.termo || '').trim() || params.listaGeral || params.linha || params.grupo || params.montadora || params.tipoVeiculo || params.disponiveis || params.comOem || params.comFoto || params.favoritos;
  if (!hasQuery) {
    if (!params.silentEmpty) target.innerHTML = CrmUi.renderState('empty', 'Informe o que deseja localizar', 'Pesquise por codigo, OEM, marca, veiculo ou aplicacao.');
    return;
  }
  target.innerHTML = CrmUi.renderState('loading', 'Pesquisando produtos', 'Aplicando os filtros comerciais selecionados.');
  try {
    const products = await supabaseSearchProducts(Object.assign({}, params, { context: onAdd ? 'pedido' : 'produtos' }));
    if (productSearchRequests.get(target) !== requestId) return;
    const pageSize = Math.max(Number(params.pageSize || params.limite || 1), 1);
    const hasMore = params.listaGeral === true && products.length > pageSize;
    const visibleProducts = hasMore ? products.slice(0, pageSize) : products;
    if (!visibleProducts.length) {
      target.innerHTML = CrmUi.renderState('empty', 'Nenhum produto encontrado', 'Revise o termo ou remova alguns filtros.');
      return;
    }
    if (onAdd) {
      renderProductPickerResults(target, visibleProducts, onAdd, params);
      return;
    }
    const renderedParams = Object.assign({}, params, { hasMore });
    productState.results = visibleProducts;
    target.innerHTML = renderProductCatalog(visibleProducts, renderedParams);
    bindProductCatalog(visibleProducts, renderedParams);
  } catch (error) {
    if (productSearchRequests.get(target) !== requestId) return;
    target.innerHTML = CrmUi.renderState('error', 'Nao foi possivel pesquisar os produtos', error.message);
  }
}

function renderProductPickerResults(target, products, onAdd, params = {}) {
  const region = String(params.regiao || 'PR').trim().toUpperCase();
  target.innerHTML = `
    <div class="table-wrap">
      <table>
        <thead><tr><th>Codigo</th><th>Descricao</th><th>Marca</th><th>Aplicacao</th><th>Estoque</th><th>Preco</th><th></th></tr></thead>
        <tbody>
          ${products.map((p, index) => {
            const branchInfo = formatBranchAvailability(p, region, 1);
            const stockDisplay = p.estoque === null || p.estoque === undefined || p.estoque === '' ? 'Nao importado' : p.estoque;
            return `
              <tr>
                <td>${escapeHtml(p.codigo)}</td>
                <td>${escapeHtml(p.descricao)}</td>
                <td>${escapeHtml(p.marca)}</td>
                <td>${escapeHtml(p.aplicacao)}</td>
                <td class="product-picker-stock"><strong>${escapeHtml(stockDisplay)}</strong><small>${escapeHtml(branchInfo)}</small></td>
                <td>${money(p.preco)}</td>
                <td><button class="btn btn-secondary" type="button" data-add-product="${index}">Selecionar</button></td>
              </tr>
            `;
          }).join('')}
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
  const offset = Math.max(Number(params.offset || 0), 0);
  const pageSize = Math.max(Number(params.pageSize || products.length || 1), 1);
  const pageNumber = Math.floor(offset / pageSize) + 1;
  const rangeLabel = params.listaGeral
    ? `${offset + 1}-${offset + products.length} produtos`
    : `${products.length} ${products.length === 1 ? 'produto' : 'produtos'}`;
  return `
    <div class="panel-header product-results-header">
      <div><h2>${rangeLabel}</h2><p>${escapeHtml(filters || 'Resultado da pesquisa')}${params.listaGeral && params.hasMore ? ' · há mais produtos' : ''}</p></div>
      <div class="actions-row">
        ${canManageProductActivity() ? `<label class="product-toggle"><input type="checkbox" id="productSelectDisplayed"> Selecionar exibidos</label>
          <span id="productSelectionCount" role="status">0 selecionados</span>
          <button class="btn btn-secondary" id="productDeactivateSelected" type="button" disabled>Inativar selecionados</button>` : ''}
        <button class="btn btn-secondary" type="button" data-export-products>Baixar XLSX</button>
      </div>
    </div>
    ${params.listaGeral ? `<div class="actions-row product-results-pagination" aria-label="Paginação da lista geral">
      <button class="btn btn-secondary" type="button" data-product-page="previous" ${offset === 0 ? 'disabled' : ''}>Anterior</button>
      <span>Página ${pageNumber}</span>
      <button class="btn btn-secondary" type="button" data-product-page="next" ${params.hasMore ? '' : 'disabled'}>Próxima</button>
    </div>` : ''}
    ${canManageProductActivity() ? '<p class="form-message" id="productBulkMessage" role="status" aria-live="polite"></p>' : ''}
    <div class="product-card-grid">
      ${products.map((product, index) => {
        const card = isSellerProductCatalog() ? renderSellerProductCard(product, index) : renderProductCard(product, index);
        return canManageProductActivity() ? `<div class="product-selectable-entry">
          <label class="product-toggle product-select-label"><input type="checkbox" data-product-select="${index}" aria-label="Selecionar produto ${escapeHtml(product.codigo)}" ${product.ativo === true ? '' : 'disabled'}>Selecionar</label>${card}</div>` : card;
      }).join('')}
    </div>
  `;
}

function getYokomitsuProductImage(code) {
  const normalized = String(code || '').trim();
  if (!/^\d{6,20}$/.test(normalized)) return '';
  return `https://www.yokomitsu.com.br/uploads/products/${normalized}/site/${normalized}.webp`;
}

function renderProductPhoto(product, emptyLabel, lazy = false) {
  const stored = String(product.url_imagem || '').trim();
  const official = getYokomitsuProductImage(product.codigo);
  const source = stored || official;
  if (!source) return `<span>${escapeHtml(emptyLabel)}</span>`;
  const fallback = stored && official && stored !== official ? official : '';
  return `<img src="${escapeHtml(source)}" data-yokomitsu-image data-fallback-src="${escapeHtml(fallback)}" alt="${escapeHtml(product.descricao || product.codigo)}"${lazy ? ' loading="lazy"' : ''} referrerpolicy="no-referrer"><span data-image-placeholder hidden>${escapeHtml(emptyLabel)}</span>`;
}

function bindYokomitsuProductImages(target) {
  if (!target) return;
  target.querySelectorAll('[data-yokomitsu-image]').forEach((image) => {
    const trigger = image.closest('[data-expand-product-photo]');
    const updateTrigger = () => {
      if (trigger) trigger.disabled = image.hidden || image.naturalWidth === 0;
    };
    const handleError = () => {
      if (trigger) trigger.disabled = true;
      const fallback = image.dataset.fallbackSrc || '';
      if (fallback) {
        image.dataset.fallbackSrc = '';
        image.src = fallback;
        return;
      }
      image.hidden = true;
      const placeholder = image.parentElement?.querySelector('[data-image-placeholder]');
      if (placeholder) placeholder.hidden = false;
    };
    image.addEventListener('error', handleError);
    image.addEventListener('load', updateTrigger);
    if (image.complete && image.naturalWidth === 0) handleError();
    else updateTrigger();
  });
}

function productPriceNumber(value) {
  if (!['string', 'number'].includes(typeof value) || (typeof value === 'string' && !value.trim())) return null;
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : null;
}

function getProductRoutePrice(product) {
  const fiscal = product.fiscal;
  if (!fiscal) return { base: productPriceNumber(product.preco), taxes: null, final: null, status: 'SEM_CONTEXTO_FISCAL', origin: '', destination: '' };
  const base = productPriceNumber(fiscal.base_price);
  const taxes = productPriceNumber(fiscal.total_taxes);
  const final = productPriceNumber(fiscal.final_price);
  const valid = /^OK/.test(String(fiscal.status)) && base > 0 && taxes !== null && final > 0;
  return { base, taxes: valid ? taxes : null, final: valid ? final : null,
    status: valid ? fiscal.status : fiscal.status || 'PRECO_FISCAL_INDISPONIVEL', origin: fiscal.origin, destination: fiscal.destination };
}

function renderProductRoutePrice(product) {
  const price = getProductRoutePrice(product);
  const display = (value) => value === null ? 'Indisponível' : money(value);
  return `<div class="product-route-price">
    ${price.origin && price.destination ? `<small>${escapeHtml(price.origin)} → ${escapeHtml(price.destination)}</small>` : ''}
    <dl><div><dt>Base sem impostos</dt><dd>${display(price.base)}</dd></div>
    <div><dt>Impostos</dt><dd>${display(price.taxes)}</dd></div>
    <div><dt>Final com impostos</dt><dd><strong>${display(price.final)}</strong></dd></div></dl>
    ${price.final === null ? '<small>Preço fiscal pendente</small>' : ''}
  </div>`;
}

function renderProductCard(product, index) {
  const favorite = productState.favorites.has(product.codigo);
  return `
    <article class="product-card" data-open-product="${index}" role="button" tabindex="0" aria-label="Abrir ficha do produto ${escapeHtml(product.codigo)}">
      <button class="product-favorite ${favorite ? 'is-active' : ''}" type="button" data-favorite-product="${index}" aria-label="Favorito">${favorite ? '*' : '+'}</button>
      <div class="product-image">${renderProductPhoto(product, 'Sem foto', true)}</div>
      <div class="product-card-body">
        <div class="product-code">${escapeHtml(product.codigo)}</div>
        ${product.ativo === false ? '<span class="status-pill">Inativo</span>' : ''}
        <h3>${escapeHtml(product.descricao || 'Produto sem descricao')}</h3>
        <p>${escapeHtml([product.marca, product.montadora, product.linha || product.categoria].filter(Boolean).join(' - '))}</p>
        <div class="product-tags">
          ${renderTag('OEM', product.oem)}
          ${renderTag('Similar', product.similar)}
          ${renderTag('Aplicacao', product.aplicacao)}
        </div>
        <div class="product-card-footer">
          <span>${escapeHtml(product.estoque ?? 'Estoque nao informado')}</span>
          ${renderProductRoutePrice(product)}
        </div>
      </div>
    </article>
  `;
}

function renderSellerProductCard(product, index) {
  const favorite = productState.favorites.has(product.codigo);
  return `
    <article class="product-card seller-product-row">
      <div class="product-image">${renderProductPhoto(product, 'Sem foto', true)}</div>
      <div class="product-card-body">
        <div class="product-code">${escapeHtml(product.codigo)}${product.linha || product.categoria ? ` · ${escapeHtml(product.linha || product.categoria)}` : ''}</div>
        <h3>${escapeHtml(product.descricao || 'Produto sem descrição')}</h3>
        <p>${escapeHtml([product.marca, product.montadora, product.aplicacao].filter(Boolean).join(' · '))}</p>
        <span class="seller-product-stock">Estoque: ${escapeHtml(product.estoque ?? 'não informado')}</span>
      </div>
      <div class="seller-product-buy">
        ${renderProductRoutePrice(product)}
        <button class="btn btn-secondary" type="button" data-open-product="${index}">Ver detalhes</button>
      </div>
      <button class="product-favorite ${favorite ? 'is-active' : ''}" type="button" data-favorite-product="${index}" aria-label="${favorite ? 'Remover dos favoritos' : 'Adicionar aos favoritos'}" aria-pressed="${favorite}">${favorite ? '*' : '+'}</button>
    </article>`;
}

function bindProductCatalog(products, params) {
  bindProductActivitySelection();
  bindYokomitsuProductImages(document.getElementById('productResults'));
  document.querySelectorAll('[data-open-product]').forEach((card) => {
    card.addEventListener('click', () => {
      if (!productState.activityBusy) openProductDetail(products[Number(card.dataset.openProduct)], params);
    });
    if (card.tagName === 'BUTTON') return;
    card.addEventListener('keydown', (event) => {
      if (productState.activityBusy || event.target !== card || !['Enter', ' '].includes(event.key)) return;
      event.preventDefault();
      openProductDetail(products[Number(card.dataset.openProduct)], params);
    });
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
      button.setAttribute('aria-pressed', String(next));
      button.setAttribute('aria-label', next ? 'Remover dos favoritos' : 'Adicionar aos favoritos');
      await refreshProductSideData();
    });
  });
  const exportButton = document.querySelector('[data-export-products]');
  if (exportButton) exportButton.addEventListener('click', () => exportProductsXlsx(products, params, exportButton));
  document.querySelector('[data-product-page="previous"]')?.addEventListener('click', () => {
    runProductGeneralListPage(params, Math.max(Number(params.offset || 0) - Number(params.pageSize || PRODUCT_GENERAL_PAGE_SIZE), 0));
  });
  document.querySelector('[data-product-page="next"]')?.addEventListener('click', () => {
    runProductGeneralListPage(params, Number(params.offset || 0) + Number(params.pageSize || PRODUCT_GENERAL_PAGE_SIZE));
  });
}

async function runProductGeneralListPage(params, offset) {
  if (productState.activityBusy) return;
  const target = document.getElementById('productResults');
  await searchProductsInto(target, Object.assign({}, params, {
    listaGeral: true,
    offset: Math.max(Number(offset || 0), 0),
    limite: PRODUCT_GENERAL_PAGE_SIZE + 1,
    pageSize: PRODUCT_GENERAL_PAGE_SIZE
  }));
  target.scrollIntoView({ block: 'start', behavior: 'smooth' });
}

function getProductActivitySelection() {
  if (!canManageProductActivity()) return [];
  return productState.results.filter((product) => product.ativo === true && productState.activitySelection.has(product.codigo))
    .map((product) => ({ codigo: product.codigo, expected_active: productState.activitySelection.get(product.codigo) }));
}

function updateProductActivitySelectionControls() {
  const selected = getProductActivitySelection();
  const eligible = productState.results.filter((product) => product.ativo === true);
  const count = document.getElementById('productSelectionCount');
  const all = document.getElementById('productSelectDisplayed');
  const button = document.getElementById('productDeactivateSelected');
  if (!count || !all || !button) return;
  count.textContent = `${selected.length} ${selected.length === 1 ? 'selecionado' : 'selecionados'}`;
  all.disabled = productState.activityBusy || !eligible.length;
  all.checked = eligible.length > 0 && selected.length === eligible.length;
  all.indeterminate = selected.length > 0 && selected.length < eligible.length;
  button.disabled = productState.activityBusy || !selected.length || selected.length > 200;
  document.querySelectorAll('[data-product-select]').forEach((control) => {
    const product = productState.results[Number(control.dataset.productSelect)];
    control.disabled = productState.activityBusy || product?.ativo !== true;
    control.checked = Boolean(product && productState.activitySelection.has(product.codigo));
  });
}

function bindProductActivitySelection() {
  if (!canManageProductActivity()) return;
  document.querySelectorAll('[data-product-select]').forEach((control) => {
    control.addEventListener('change', () => {
      const product = productState.results[Number(control.dataset.productSelect)];
      if (!productState.activityBusy && product?.ativo === true) {
        if (control.checked) productState.activitySelection.set(product.codigo, product.ativo);
        else productState.activitySelection.delete(product.codigo);
      }
      updateProductActivitySelectionControls();
    });
  });
  document.getElementById('productSelectDisplayed')?.addEventListener('change', (event) => {
    if (productState.activityBusy) return;
    productState.activitySelection.clear();
    if (event.target.checked) productState.results.filter((product) => product.ativo === true)
      .forEach((product) => productState.activitySelection.set(product.codigo, product.ativo));
    updateProductActivitySelectionControls();
  });
  document.getElementById('productDeactivateSelected')?.addEventListener('click', deactivateSelectedProducts);
  updateProductActivitySelectionControls();
}

async function deactivateSelectedProducts() {
  const items = getProductActivitySelection();
  if (productState.activityBusy || !items.length || items.length > 200) return;
  if (!window.confirm(`Inativar ${items.length} itens selecionados?`)) return;
  const target = document.getElementById('productResults');
  const message = document.getElementById('productBulkMessage');
  const form = document.getElementById('productSearchForm');
  if (!target || !message) return;
  const controls = Array.from(form?.elements || []).map((control) => ({ control, disabled: control.disabled }));
  productState.activityBusy = true;
  controls.forEach(({ control }) => { control.disabled = true; });
  updateProductActivitySelectionControls();
  message.textContent = 'Inativando itens selecionados...';
  let result;
  try {
    result = await supabaseDeactivateProducts(items);
    productState.activitySelection.clear();
  } catch (error) {
    message.textContent = error.message || 'Não foi possível confirmar a inativação. Atualize a pesquisa.';
  } finally {
    productState.activityBusy = false;
    controls.forEach(({ control, disabled }) => { control.disabled = disabled; });
    updateProductActivitySelectionControls();
  }
  if (result && document.getElementById('productResults') === target) {
    const notice = document.getElementById('productMessage');
    if (notice) {
      notice.style.color = 'var(--success)';
      notice.textContent = `${result.changed} ${result.changed === 1 ? 'item inativado' : 'itens inativados'} com sucesso.`;
    }
    await Promise.all([runProductSearch({ listaGeral: true }), refreshProductSideData(), loadProductFilterOptions()]).catch(() => {
      if (notice && document.getElementById('productMessage') === notice) {
        notice.style.color = 'var(--muted)';
        notice.textContent = 'Itens inativados. Atualize a pesquisa para conferir.';
      }
    });
  }
}

function getProductActivitySelection() {
  if (!canManageProductActivity()) return [];
  return productState.results.filter((product) => product.ativo === true && productState.activitySelection.has(product.codigo))
    .map((product) => ({ codigo: product.codigo, expected_active: productState.activitySelection.get(product.codigo) }));
}

function updateProductActivitySelectionControls() {
  const selected = getProductActivitySelection();
  const eligible = productState.results.filter((product) => product.ativo === true);
  const count = document.getElementById('productSelectionCount');
  const all = document.getElementById('productSelectDisplayed');
  const button = document.getElementById('productDeactivateSelected');
  if (!count || !all || !button) return;
  count.textContent = `${selected.length} ${selected.length === 1 ? 'selecionado' : 'selecionados'}`;
  all.disabled = productState.activityBusy || !eligible.length;
  all.checked = eligible.length > 0 && selected.length === eligible.length;
  all.indeterminate = selected.length > 0 && selected.length < eligible.length;
  button.disabled = productState.activityBusy || !selected.length || selected.length > 200;
  document.querySelectorAll('[data-product-select]').forEach((control) => {
    const product = productState.results[Number(control.dataset.productSelect)];
    control.disabled = productState.activityBusy || product?.ativo !== true;
    control.checked = Boolean(product && productState.activitySelection.has(product.codigo));
  });
}

function bindProductActivitySelection() {
  if (!canManageProductActivity()) return;
  document.querySelectorAll('[data-product-select]').forEach((control) => {
    control.addEventListener('change', () => {
      const product = productState.results[Number(control.dataset.productSelect)];
      if (!productState.activityBusy && product?.ativo === true) {
        if (control.checked) productState.activitySelection.set(product.codigo, product.ativo);
        else productState.activitySelection.delete(product.codigo);
      }
      updateProductActivitySelectionControls();
    });
  });
  document.getElementById('productSelectDisplayed')?.addEventListener('change', (event) => {
    if (productState.activityBusy) return;
    productState.activitySelection.clear();
    if (event.target.checked) productState.results.filter((product) => product.ativo === true)
      .forEach((product) => productState.activitySelection.set(product.codigo, product.ativo));
    updateProductActivitySelectionControls();
  });
  document.getElementById('productDeactivateSelected')?.addEventListener('click', deactivateSelectedProducts);
  updateProductActivitySelectionControls();
}

async function deactivateSelectedProducts() {
  const items = getProductActivitySelection();
  if (productState.activityBusy || !items.length || items.length > 200) return;
  if (!window.confirm(`Inativar ${items.length} itens selecionados?`)) return;
  const target = document.getElementById('productResults');
  const message = document.getElementById('productBulkMessage');
  const form = document.getElementById('productSearchForm');
  if (!target || !message) return;
  const controls = Array.from(form?.elements || []).map((control) => ({ control, disabled: control.disabled }));
  productState.activityBusy = true;
  controls.forEach(({ control }) => { control.disabled = true; });
  updateProductActivitySelectionControls();
  message.textContent = 'Inativando itens selecionados...';
  let result;
  try {
    result = await supabaseDeactivateProducts(items);
    productState.activitySelection.clear();
  } catch (error) {
    message.textContent = error.message || 'Não foi possível confirmar a inativação. Atualize a pesquisa.';
  } finally {
    productState.activityBusy = false;
    controls.forEach(({ control, disabled }) => { control.disabled = disabled; });
    updateProductActivitySelectionControls();
  }
  if (result && document.getElementById('productResults') === target) {
    const notice = document.getElementById('productMessage');
    if (notice) {
      notice.style.color = 'var(--success)';
      notice.textContent = `${result.changed} ${result.changed === 1 ? 'item inativado' : 'itens inativados'} com sucesso.`;
    }
    await Promise.all([runProductSearch({ listaGeral: true }), refreshProductSideData(), loadProductFilterOptions()]).catch(() => {
      if (notice && document.getElementById('productMessage') === notice) {
        notice.style.color = 'var(--muted)';
        notice.textContent = 'Itens inativados. Atualize a pesquisa para conferir.';
      }
    });
  }
}

async function openProductDetail(product) {
  if (!product) return;
  const requestId = ++productDetailRequestSequence;
  const origin = document.getElementById('productRegion')?.value || 'SP';
  const destination = document.getElementById('productDestination')?.value || 'SP';
  productState.selected = product;
  showProductDetailModal(product);
  const detail = document.getElementById('productDetail');
  const isCurrent = () => requestId === productDetailRequestSequence
    && document.getElementById('productDetail') === detail
    && productState.selected?.codigo === product.codigo
    && (document.getElementById('productRegion')?.value || 'SP') === origin
    && (document.getElementById('productDestination')?.value || 'SP') === destination;
  detail.innerHTML = CrmUi.renderState('loading', 'Carregando ficha do produto', 'Consultando estoque, preços e histórico.');
  try {
    const rows = await supabaseSearchProducts({ termo: product.codigo, limite: 10, incluirInativos: canManageProductActivity(),
      regiao: origin, destinoUf: destination, catalogPricing: true });
    if (!isCurrent()) return;
    const current = rows.find((row) => row.codigo === product.codigo);
    if (!current || (current.ativo === false && !canManageProductActivity())) {
      throw new Error('Produto inativo ou indisponivel. Atualize a pesquisa.');
    }
    product = current;
    productState.selected = current;
    await supabaseRegisterProductView(product.codigo).catch(() => null);
    if (!isCurrent()) return;
    const history = await supabaseGetProductHistory(product.codigo).catch(() => ({ prices: [], stock: [] }));
    if (!isCurrent() || !document.getElementById('productDetailModal')) return;
    detail.innerHTML = renderProductDetail(product, history);
    bindProductActivityForm(product, detail);
    bindYokomitsuProductImages(detail);
    await refreshProductSideData().catch(() => null);
  } catch (error) {
    if (isCurrent()) detail.innerHTML = CrmUi.renderState('error', 'Não foi possível abrir a ficha', error.message || 'Tente novamente em instantes.');
  }
}

function bindProductDetailModal() {
  const modal = document.getElementById('productDetailModal');
  const closeButton = document.getElementById('productDetailClose');
  if (!modal || !closeButton) return;
  bindProductPhotoViewer();
  closeButton.addEventListener('click', () => closeProductDetail());
  modal.addEventListener('click', (event) => {
    if (event.target === modal) closeProductDetail();
  });
  modal.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') closeProductDetail();
  });
}

function bindProductPhotoViewer() {
  const dialog = document.getElementById('productPhotoDialog');
  if (!dialog) return;
  const photo = document.getElementById('productPhotoImage');
  const viewport = document.getElementById('productPhotoViewport');
  const zoom = document.getElementById('productPhotoZoom');
  const error = document.getElementById('productPhotoError');
  document.getElementById('productDetail').addEventListener('click', (event) => {
    const trigger = event.target.closest('[data-expand-product-photo]');
    const source = trigger?.querySelector('img');
    if (!source || source.hidden || source.naturalWidth === 0 || dialog.open) return;
    photo.alt = source.alt;
    photo.src = source.currentSrc || source.src;
    photo.hidden = false;
    error.hidden = true;
    zoom.value = '100';
    document.getElementById('productPhotoZoomValue').textContent = '100%';
    viewport.style.setProperty('--photo-scale', '1');
    document.getElementById('productPhotoTitle').textContent = `Foto · ${productState.selected?.codigo || 'Produto'}`;
    dialog.showModal();
    viewport.scrollTop = viewport.scrollLeft = 0;
  });
  document.getElementById('productPhotoClose').addEventListener('click', () => dialog.close());
  dialog.addEventListener('click', (event) => {
    if (event.target === dialog) dialog.close();
  });
  dialog.addEventListener('close', () => {
    photo.removeAttribute('src');
    photo.alt = '';
  });
  photo.addEventListener('error', () => {
    photo.hidden = true;
    error.hidden = false;
  });
  zoom.addEventListener('input', () => {
    const previous = Number(viewport.style.getPropertyValue('--photo-scale')) || 1;
    const next = Number(zoom.value) / 100;
    const left = (viewport.scrollLeft + viewport.clientWidth / 2) * next / previous - viewport.clientWidth / 2;
    const top = (viewport.scrollTop + viewport.clientHeight / 2) * next / previous - viewport.clientHeight / 2;
    viewport.style.setProperty('--photo-scale', String(next));
    viewport.scrollLeft = left;
    viewport.scrollTop = top;
    document.getElementById('productPhotoZoomValue').textContent = `${zoom.value}%`;
  });
}

function showProductDetailModal(product) {
  const modal = document.getElementById('productDetailModal');
  if (!modal) return;
  if (modal.hidden) productDetailReturnFocus = document.activeElement;
  const title = document.getElementById('productDetailModalTitle');
  if (title) title.textContent = `${product.codigo} - ${product.descricao || 'Produto'}`;
  modal.hidden = false;
  document.body.classList.add('product-detail-open');
  document.getElementById('productDetailClose')?.focus({ preventScroll: true });
}

function closeProductDetail(options = {}) {
  productDetailRequestSequence += 1;
  const photoDialog = document.getElementById('productPhotoDialog');
  if (photoDialog?.open) photoDialog.close();
  const modal = document.getElementById('productDetailModal');
  if (modal) modal.hidden = true;
  document.body.classList.remove('product-detail-open');
  if (options.restoreFocus === false) return;
  if (productDetailReturnFocus?.isConnected) productDetailReturnFocus.focus({ preventScroll: true });
  productDetailReturnFocus = null;
}

function extractInstalledCatalogNotes(value) {
  const original = String(value || '');
  const start = '[CATALOGO_IPS_INSTALADO]';
  const end = '[/CATALOGO_IPS_INSTALADO]';
  const first = original.indexOf(start);
  const last = original.indexOf(end);
  if (first < 0 || last < first || original.indexOf(start, first + start.length) >= 0 || original.indexOf(end, last + end.length) >= 0) {
    return { manual: original, catalog: '' };
  }
  return {
    manual: [original.slice(0, first).trim(), original.slice(last + end.length).trim()].filter(Boolean).join('\n'),
    catalog: original.slice(first + start.length, last).trim()
  };
}

function renderProductDetail(product, history) {
  const notes = extractInstalledCatalogNotes(product.detalhes);
  return `
    <div class="product-detail">
      <button class="product-detail-image product-photo-trigger" type="button" data-expand-product-photo disabled aria-label="Ampliar foto do produto">
        ${renderProductPhoto(product, 'Sem foto cadastrada')}
        <span class="product-photo-caption" aria-hidden="true">Ampliar foto</span>
      </button>
      <div class="product-detail-title">
        <span>${escapeHtml(product.codigo)}</span>
        <h2>${escapeHtml(product.descricao || 'Produto sem descricao')}</h2>
        ${renderProductRoutePrice(product)}
      </div>
      <dl class="product-detail-grid">
        ${detailItem('Marca', product.marca)}
        ${detailItem('Linha', product.linha || product.categoria)}
        ${detailItem('Tipo de veiculo', formatVehicleTypes(product.vehicle_types))}
        ${detailItem('Grupo', product.grupo)}
        ${detailItem('Montadora', product.montadora)}
        ${detailItem('OEM', product.oem)}
        ${detailItem('Similares', product.similar)}
        ${detailItem('Aplicacoes', product.aplicacao)}
        ${detailItem('Detalhes consulta', notes.manual)}
        ${detailItem('Estoque', product.estoque)}
        ${detailItem('Qtd. estoque', product.estoque_quantidade)}
      </dl>
      ${renderProductActivityForm(product)}
      ${notes.catalog ? `<details class="product-catalog-notes"><summary>Informações do catálogo IPS</summary><p>${escapeHtml(notes.catalog)}</p></details>` : ''}
      <div class="product-history-grid">
        ${renderHistoryBlock('Historico de precos', history.prices)}
        ${renderHistoryBlock('Historico de estoque', history.stock)}
      </div>
    </div>
  `;
}

function renderProductActivityForm(product) {
  if (!canManageProductActivity()) return '';
  return `<form id="productActivityForm" class="actions-row">
    <label class="product-toggle"><input type="checkbox" id="productActivityStatus" ${product.ativo !== false ? 'checked' : ''}><span id="productActivityLabel">${product.ativo === false ? 'Item inativo' : 'Item ativo'}</span></label>
    <button class="btn btn-primary" type="submit" id="productActivitySave">Salvar situacao</button>
    <p class="form-message" id="productActivityMessage" role="status" aria-live="polite"></p>
  </form>`;
}

function bindProductActivityForm(product, detail) {
  const form = detail.querySelector('#productActivityForm');
  if (!form) return;
  let busy = false;
  const control = form.querySelector('#productActivityStatus');
  control.addEventListener('change', () => {
    form.querySelector('#productActivityLabel').textContent = control.checked ? 'Item ativo' : 'Item inativo';
    form.querySelector('#productActivityMessage').textContent = '';
  });
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (busy || !canManageProductActivity()) return;
    const button = form.querySelector('#productActivitySave');
    const message = form.querySelector('#productActivityMessage');
    const isActive = control.checked;
    if (typeof product.ativo !== 'boolean') {
      message.textContent = 'Atualize o banco com a migration 105 e pesquise o item novamente.';
      return;
    }
    busy = true;
    control.disabled = button.disabled = true;
    message.style.color = 'var(--muted)';
    message.textContent = 'Salvando situacao...';
    try {
      const data = await supabaseSetProductActive(product.codigo, isActive, product.ativo);
      product.ativo = data.ativo;
      message.style.color = 'var(--success)';
      message.textContent = 'Item ' + (data.ativo ? 'ativado' : 'inativado') + ' com sucesso.';
      await Promise.all([runProductSearch({ listaGeral: true }), refreshProductSideData(), loadProductFilterOptions()]).catch(() => {
        message.style.color = 'var(--muted)';
        message.textContent = 'Situacao salva. Atualize a pesquisa para conferir os resultados.';
      });
    } catch (error) {
      message.style.color = 'var(--accent)';
      message.textContent = error.message || 'Nao foi possivel salvar a situacao.';
    } finally {
      busy = false;
      control.disabled = button.disabled = false;
    }
  });
}

function detailItem(label, value) {
  return `<div><dt>${escapeHtml(label)}</dt><dd>${escapeHtml(value || '-')}</dd></div>`;
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
      await openProductDetail(product);
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
    `${params.regiao || 'SP'} → ${params.destinoUf || params.regiao || 'SP'}`,
    params.listaGeral ? 'lista geral' : '',
    params.linha ? 'linha: ' + params.linha : '',
    params.grupo ? 'grupo: ' + params.grupo : '',
    params.montadora ? 'montadora: ' + params.montadora : '',
    params.tipoVeiculo ? 'veiculo: ' + formatVehicleTypes([params.tipoVeiculo]) : '',
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

async function loadAllProductsForXlsx(params, onProgress) {
  const products = [];
  let offset = 0;
  while (offset <= PRODUCT_XLSX_MAX_OFFSET) {
    const page = await supabaseSearchProducts(Object.assign({}, params, {
      offset,
      limite: PRODUCT_XLSX_BATCH_SIZE,
      pageSize: PRODUCT_XLSX_BATCH_SIZE,
      context: 'produtos'
    }));
    if (!page.length) break;
    products.push(...page);
    if (typeof onProgress === 'function') onProgress(products.length);
    if (page.length < PRODUCT_XLSX_BATCH_SIZE) break;
    if (offset === PRODUCT_XLSX_MAX_OFFSET) {
      throw new Error('A lista ultrapassa o limite de 50.500 produtos por arquivo. Refine os filtros e tente novamente.');
    }
    offset = Math.min(offset + PRODUCT_XLSX_BATCH_SIZE, PRODUCT_XLSX_MAX_OFFSET);
  }
  return products;
}

function buildProductXlsxRows(products) {
  return [
    ['Código', 'Linha', 'Grupo', 'Tipo de veículo', 'Montadora', 'OEM', 'Aplicações', 'Estoque', 'Origem', 'Destino', 'Base sem impostos', 'Impostos', 'Final com impostos', 'Status fiscal'],
    ...products.map((product) => {
      const price = getProductRoutePrice(product);
      return [
      String(product.codigo || ''),
      product.linha || product.categoria || '',
      product.grupo || product.material_group || product.fiscal_group || '',
      formatVehicleTypes(product.vehicle_types),
      Array.isArray(product.vehicle_makers) ? product.vehicle_makers.join(' / ') : '',
      product.oem || '',
      product.aplicacao || '',
      product.estoque ?? '',
      price.origin, price.destination, price.base ?? '', price.taxes ?? '', price.final ?? '', price.status
    ]; })
  ];
}

function downloadProductsXlsx(products, params) {
  if (typeof XLSX === 'undefined') throw new Error('Gerador XLSX não carregado. Atualize a página e tente novamente.');
  const rows = buildProductXlsxRows(products);
  const worksheet = XLSX.utils.aoa_to_sheet(rows);
  worksheet['!cols'] = [
    { wch: 16 }, { wch: 24 }, { wch: 12 }, { wch: 22 }, { wch: 28 },
    { wch: 28 }, { wch: 55 }, { wch: 18 }, { wch: 10 }, { wch: 10 },
    { wch: 20 }, { wch: 18 }, { wch: 22 }, { wch: 34 }
  ];
  for (let row = 1; row < rows.length; row += 1) {
    for (const column of [10, 11, 12]) {
      const priceCell = worksheet[XLSX.utils.encode_cell({ r: row, c: column })];
      if (priceCell && priceCell.t === 'n') priceCell.z = '[$R$-pt-BR] #,##0.00';
    }
  }
  const workbook = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(workbook, worksheet, 'Produtos');
  XLSX.writeFile(workbook, 'lista-produtos-' + (params.regiao || 'SP').toLowerCase() + '-' + (params.destinoUf || params.regiao || 'SP').toLowerCase() + '.xlsx', { compression: true });
}

async function exportProductsXlsx(products, params, button) {
  if (!button || button.disabled) return;
  const originalLabel = button.textContent;
  const notice = document.getElementById('productMessage');
  button.disabled = true;
  button.setAttribute('aria-busy', 'true');
  button.textContent = params.listaGeral ? 'Preparando XLSX...' : 'Gerando XLSX...';
  if (notice) notice.textContent = params.listaGeral ? 'Buscando todos os produtos para o XLSX...' : '';
  try {
    const exportRows = params.listaGeral
      ? await loadAllProductsForXlsx(params, (count) => {
        button.textContent = `Preparando XLSX (${count})`;
        if (notice) notice.textContent = `${count} produtos preparados para exportacao...`;
      })
      : products;
    downloadProductsXlsx(exportRows, params);
    if (notice) notice.textContent = `XLSX gerado com ${exportRows.length} ${exportRows.length === 1 ? 'produto' : 'produtos'}.`;
  } catch (error) {
    if (notice) notice.textContent = error.message || 'Nao foi possivel gerar o XLSX.';
  } finally {
    button.disabled = false;
    button.removeAttribute('aria-busy');
    button.textContent = originalLabel;
  }
}
