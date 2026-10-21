const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const read = (file) => fs.readFileSync(path.join(__dirname, '..', file), 'utf8');

function catalogHarness(profile, modules = []) {
  const context = vm.createContext({
    getStoredSession: () => ({ perfil: profile, modules }),
    APP_CONFIG: { locale: 'pt-BR', currency: 'BRL' },
    document: {}, window: {}
  });
  vm.runInContext(read('js/dashboard.js'), context);
  vm.runInContext(read('js/products.js'), context);
  return context;
}

test('seller catalog layout is not applied to administrative or B2B profiles', () => {
  for (const role of ['ADMIN', 'COMERCIAL', 'CLIENTE', '', undefined]) {
    assert.equal(catalogHarness(role).isSellerProductCatalog(), false);
  }
  assert.equal(catalogHarness('VENDEDOR').isSellerProductCatalog(), true);
});

test('seller catalog shortcuts respect separate create permissions', () => {
  assert.equal(catalogHarness('VENDEDOR', ['produtos']).renderSellerCatalogActions().trim(), '');
  const order = catalogHarness('VENDEDOR', ['novo_pedido']).renderSellerCatalogActions();
  assert.match(order, /orderCreate/);
  assert.doesNotMatch(order, /quoteCreate/);
  const quote = catalogHarness('VENDEDOR', ['nova_cotacao']).renderSellerCatalogActions();
  assert.match(quote, /quoteCreate/);
  assert.doesNotMatch(quote, /orderCreate/);
});

test('seller product rows escape input and preserve zero stock and prices', () => {
  const html = catalogHarness('VENDEDOR').renderSellerProductCard({ codigo: '<img>', descricao: 'Farol <script>', estoque: 0, preco: 0 }, 0);
  assert.match(html, /&lt;img&gt;/);
  assert.match(html, /Farol &lt;script&gt;/);
  assert.match(html, /seller-product-stock">Estoque: 0</);
  assert.match(html, /0,00/);
  assert.match(html, /data-open-product="0"/);
  assert.doesNotMatch(html, /role="button"/);
});

test('changing branch refreshes a previously generated general list', () => {
  const context = catalogHarness('VENDEDOR');
  const events = new Map();
  context.document.getElementById = (id) => ({ addEventListener: (name, callback) => events.set(`${id}:${name}`, callback) });
  const calls = [];
  context.runProductSearch = (options) => calls.push(options);
  context.bindProductSearch();
  vm.runInContext("productState.results = [{ codigo: 'TEST' }];", context);
  events.get('productRegion:change')();
  assert.equal(calls[0].listaGeral, true);
  vm.runInContext('productState.results = [];', context);
  events.get('productRegion:change')();
  assert.equal(calls[1].listaGeral, false);
});

test('seller styling is isolated and commercial focus hides the seller navigation', () => {
  const app = read('js/app.js');
  assert.match(app, /'mobileNav', 'sellerNav'/);
  assert.match(app, /id === 'sellerNav' && !isCurrentUserSeller\(\)/);
  assert.match(app, /isModuleBlockedForCurrentRole\(module\) \|\| !hasModuleAccess\(module, allowed\)/);
  const page = read('app.html');
  assert.match(page, /css\/seller.css\?v=20261021-1/);
  assert.match(page, /js\/products.js\?v=20261021-ips-catalog-1/);
});

test('horizontal navigation respects report-only, create-only and additional module permissions', () => {
  for (const [permission, expected] of [['novo_pedido', 'ordersReport'], ['pedidos', 'ordersReport'], ['nova_cotacao', 'quoteReports'], ['cotacoes', 'quoteReports'], ['produtos', 'products'], ['logs', 'logs']]) {
    const nav = { hidden: true, children: [], replaceChildren() { this.children = []; }, append(node) { this.children.push(node); } };
    const brand = { hidden: true };
    const context = vm.createContext({
      document: {
        addEventListener() {},
        getElementById: (id) => id === 'sellerNav' ? nav : null,
        querySelector: () => brand,
        createElement: () => ({ dataset: {}, addEventListener() {} })
      }
    });
    const source = read('js/app.js');
    for (const match of source.matchAll(/render: (\w+)/g)) context[match[1]] = () => {};
    vm.runInContext(source, context);
    vm.runInContext(`currentSession = { perfil: 'VENDEDOR', modules: ['${permission}'] }; setupSellerNavigation();`, context);
    assert.equal(nav.hidden, false);
    assert.deepEqual(nav.children.map((node) => node.dataset.sellerModule), [expected]);
    vm.runInContext("currentSession = { perfil: 'ADMIN', modules: [] }; setupSellerNavigation();", context);
    assert.equal(nav.hidden, true);
    assert.equal(brand.hidden, true);
    assert.equal(nav.children.length, 0);
  }
});

test('photo enlargement uses the loaded source only and skips missing or failed images', () => {
  const context = catalogHarness('VENDEDOR');
  const listeners = new Map();
  const nodes = new Map();
  let opens = 0;
  const style = { setProperty() {}, getPropertyValue: () => '1' };
  const node = (id) => {
    if (!nodes.has(id)) nodes.set(id, { style, clientWidth: 500, clientHeight: 300, scrollTop: 0, scrollLeft: 0,
      addEventListener: (name, callback) => listeners.set(`${id}:${name}`, callback),
      showModal() { this.open = true; opens += 1; }, close() { this.open = false; }, removeAttribute() {}
    });
    return nodes.get(id);
  };
  context.document.getElementById = node;
  context.bindProductPhotoViewer();
  const click = listeners.get('productDetail:click');
  const eventFor = (source) => ({ target: { closest: () => ({ querySelector: () => source }) } });
  click(eventFor(null));
  click(eventFor({ hidden: true, naturalWidth: 800 }));
  click(eventFor({ hidden: false, naturalWidth: 0 }));
  assert.equal(opens, 0);
  click(eventFor({ hidden: false, naturalWidth: 800, alt: 'Foto', currentSrc: 'https://example.test/fallback.webp', src: 'https://example.test/original.webp' }));
  assert.equal(opens, 1);
  assert.equal(node('productPhotoImage').src, 'https://example.test/fallback.webp');
  assert.equal(node('productPhotoZoom').value, '100');
  assert.equal(node('productPhotoError').hidden, true);
  listeners.get('productPhotoClose:click')();
  assert.equal(node('productPhotoDialog').open, false);
});

test('photo viewer closes with the product sheet and uses a native modal with accessible zoom', () => {
  const source = read('js/products.js');
  assert.match(source, /<dialog class="product-photo-dialog"[^>]*aria-labelledby="productPhotoTitle"/);
  assert.match(source, /type="range"[^>]*aria-label="Zoom da foto"/);
  const context = catalogHarness('VENDEDOR');
  let closed = false;
  const dialog = { open: true, close: () => { closed = true; } };
  context.document.getElementById = (id) => id === 'productPhotoDialog' ? dialog : { hidden: false };
  context.document.body = { classList: { remove() {} } };
  context.closeProductDetail({ restoreFocus: false });
  assert.equal(closed, true);
});

test('installed catalog notes preserve manual details and keep malformed markers visible', () => {
  const context = catalogHarness('VENDEDOR');
  const notes = context.extractInstalledCatalogNotes('OEM manual\n[CATALOGO_IPS_INSTALADO]\nEAN: 123\n[/CATALOGO_IPS_INSTALADO]\nOutro detalhe');
  assert.equal(notes.manual, 'OEM manual\nOutro detalhe');
  assert.equal(notes.catalog, 'EAN: 123');
  const malformed = '[CATALOGO_IPS_INSTALADO] sem fechamento';
  assert.equal(context.extractInstalledCatalogNotes(malformed).manual, malformed);
  assert.equal(context.extractInstalledCatalogNotes(malformed).catalog, '');
});

test('installed catalog information is escaped and does not replace commercial description', () => {
  const context = catalogHarness('VENDEDOR');
  context.formatVehicleTypes = () => 'Leve';
  const html = context.renderProductDetail({ codigo: 'TEST', descricao: 'Descricao SAP', detalhes: '[CATALOGO_IPS_INSTALADO]\n<script>nao executar</script>\n[/CATALOGO_IPS_INSTALADO]' }, { prices: [], stock: [] });
  assert.match(html, /Descricao SAP/);
  assert.match(html, /Informações do catálogo IPS/);
  assert.match(html, /&lt;script&gt;nao executar&lt;\/script&gt;/);
  assert.doesNotMatch(html, /<script\b/i);
});
