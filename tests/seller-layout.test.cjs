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
  assert.match(page, /js\/products.js\?v=20261021-seller-1/);
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
