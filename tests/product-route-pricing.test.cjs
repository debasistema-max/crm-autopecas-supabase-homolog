const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const read = (file) => fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
function harness() {
  const c = vm.createContext({ APP_CONFIG: {}, document: {}, window: {}, getStoredSession: () => ({ perfil: 'ADMIN' }),
    money: (n) => `R$ ${Number(n).toFixed(2)}`, escapeHtml: (s) => String(s).replaceAll('<', '&lt;'), formatVehicleTypes: () => '',
    formatVehicleMakers: (values) => values?.join(' / ') || 'Não informada' });
  vm.runInContext(read('js/products.js'), c);
  return c;
}
test('catalog cards and export keep branch, destination and all fiscal amounts', () => {
  const c = harness();
  const product = { codigo: 'A', preco: 999, fiscal: { origin: 'PR', destination: 'RJ', base_price: 100, total_taxes: 24, final_price: 124, status: 'OK' } };
  assert.match(c.renderProductRoutePrice(product), /PR → RJ/);
  assert.match(c.renderProductRoutePrice(product), /Base sem impostos/);
  const row = c.buildProductXlsxRows([product])[1];
  assert.deepEqual(Array.from(row.slice(8)), ['PR', 'RJ', 100, 24, 124, 'OK']);
  assert.equal(c.getProductRoutePrice(product).final, 124);
});
test('blocked or incomplete tax prices never use stale branch price or false zero tax', () => {
  const c = harness();
  for (const fiscal of [undefined, { status: 'MISMATCH', base_price: 100, total_taxes: 5, final_price: 105 },
    { status: 'OK', base_price: 100, total_taxes: null, final_price: 100 },
    { status: 'OK', base_price: 100, total_taxes: -1, final_price: 99 }]) {
    const product = { preco: 999, fiscal };
    assert.equal(c.getProductRoutePrice(product).final, null);
    assert.match(c.renderProductRoutePrice(product), /Indisponível/);
    assert.equal(c.buildProductXlsxRows([product])[1][12], '');
  }
  assert.equal(c.getProductRoutePrice({ fiscal: { status: 'OK', base_price: 100, total_taxes: 0, final_price: 100 } }).taxes, 0);
  for (const v of ['', ' ', null, undefined, false, [], {}, -1, Infinity, 'NaN']) assert.equal(c.productPriceNumber(v), null);
});
test('legacy picker stays on search RPC; catalog opts into route RPC and validates response route', async () => {
  const c = vm.createContext({ console });
  const calls = [];
  c.supabaseClient = { rpc: async (name, payload) => { calls.push({ name, payload }); return { data: name === 'search_products_v2' ? [] : [{ fiscal: { origin: 'PR', destination: 'RJ' } }] }; } };
  vm.runInContext(read('js/supabase_store.js'), c);
  await c.supabaseSearchProducts({ regiao: 'PR' });
  await c.supabaseSearchProducts({ regiao: 'PR', destinoUf: 'RJ', catalogPricing: true });
  assert.equal(calls[0].name, 'search_products_v2');
  assert.equal(calls[1].name, 'search_product_catalog_pricing');
  assert.equal(calls[1].payload.filters.destination_uf, 'RJ');
  await assert.rejects(() => c.supabaseSearchProducts({ regiao: 'SP', destinoUf: 'RJ', catalogPricing: true }), /incompatível/);
  c.supabaseClient.rpc = async () => ({ error: { code: 'PGRST202' } });
  await assert.rejects(() => c.supabaseSearchProducts({ catalogPricing: true }), /migration 113/);
});
test('all XLSX pages retain the original selected origin and destination', async () => {
  const c = harness();let calls = 0;
  c.supabaseSearchProducts = async (params) => {
    assert.equal(params.regiao, 'PR');assert.equal(params.destinoUf, 'SC');assert.equal(params.catalogPricing, true);
    return calls++ === 0 ? Array.from({ length: 500 }, (_, i) => ({ codigo: String(i) })) : [];
  };
  assert.equal((await c.loadAllProductsForXlsx({ regiao: 'PR', destinoUf: 'SC', catalogPricing: true })).length, 500);
});
test('SQL delegates fiscal rules, rejects anonymous callers and does not write canonical data', () => {
  const sql = read('supabase/migrations/113_product_catalog_route_pricing.sql');
  assert.match(sql, /not public.is_app_session_active/);
  assert.match(sql, /public.has_module\('produtos'\)/);
  assert.match(sql, /public.get_product_commercial_price/);
  assert.match(sql, /public.commercial_business_date/);
  assert.match(sql, /v_taxes:=null;v_final:=null/);
  assert.doesNotMatch(sql, /update public\.|insert into public\.|delete from public\./i);
});

function detailHarness() {
  const c = harness();
  const nodes = { productRegion: { value: 'SP' }, productDestination: { value: 'SP' },
    productDetail: { innerHTML: '' }, productDetailModal: { hidden: true } };
  c.document.getElementById = (id) => nodes[id];
  c.document.body = { classList: { remove() {} } };
  c.CrmUi = { renderState: (state) => state };
  c.showProductDetailModal = () => { nodes.productDetailModal.hidden = false; };
  c.renderProductDetail = (p) => p.fiscal.route;
  c.bindProductActivityForm = c.bindYokomitsuProductImages = () => {};
  c.refreshProductSideData = c.supabaseRegisterProductView = async () => {};
  c.supabaseGetProductHistory = async () => ({ prices: [], stock: [] });
  return { c, nodes };
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
for (const outcome of ['success', 'error']) test(`old detail lookup ${outcome} cannot replace reopened same-code route`, async () => {
  const { c, nodes } = detailHarness();const old = deferred();let calls = 0;
  c.supabaseSearchProducts = async (params) => calls++ === 0 ? old.promise
    : [{ codigo: 'A', ativo: true, fiscal: { route: params.regiao + '-' + params.destinoUf } }];
  const first = c.openProductDetail({ codigo: 'A' });
  c.closeProductDetail({ restoreFocus: false });nodes.productDestination.value = 'RJ';
  await c.openProductDetail({ codigo: 'A' });
  assert.equal(nodes.productDetail.innerHTML, 'SP-RJ');
  if (outcome === 'success') old.resolve([{ codigo: 'A', ativo: true, fiscal: { route: 'SP-SP' } }]);
  else old.reject(new Error('old lookup failed'));
  await first;assert.equal(nodes.productDetail.innerHTML, 'SP-RJ');
});
test('old history cannot replace reopened same-code route', async () => {
  const { c, nodes } = detailHarness();const old = deferred(), started = deferred();let calls = 0;
  c.supabaseSearchProducts = async (params) => [{ codigo: 'A', ativo: true, fiscal: { route: params.regiao + '-' + params.destinoUf } }];
  c.supabaseGetProductHistory = async () => {
    if (calls++ === 0) { started.resolve();return old.promise; }
    return { prices: [], stock: [] };
  };
  const first = c.openProductDetail({ codigo: 'A' });await started.promise;
  c.closeProductDetail({ restoreFocus: false });nodes.productDestination.value = 'RJ';
  await c.openProductDetail({ codigo: 'A' });
  old.resolve({ prices: [], stock: [] });await first;
  assert.equal(nodes.productDetail.innerHTML, 'SP-RJ');
});
