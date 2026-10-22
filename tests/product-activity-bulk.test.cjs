const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const read = (file) => fs.readFileSync(path.join(__dirname, '..', file), 'utf8');

function harness(role = 'ADMIN') {
  const nodes = { productResults: {}, productBulkMessage: {}, productSelectionCount: {},
    productSelectDisplayed: {}, productDeactivateSelected: {}, productSearchForm: { elements: [] }, productMessage: { style: {} } };
  const context = vm.createContext({ document: { getElementById: (id) => nodes[id], querySelectorAll: () => [] },
    getStoredSession: () => ({ perfil: role }), window: { confirm: () => true }, money: (value) => String(value || 0),
    escapeHtml: (value) => String(value || '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('"', '&quot;') });
  vm.runInContext(read('js/products.js'), context);
  context.runProductSearch = context.refreshProductSideData = context.loadProductFilterOptions = async () => {};
  vm.runInContext("productState.results=[{codigo:'A',ativo:true},{codigo:'B',ativo:false}];productState.activitySelection.set('A',true);productState.activitySelection.set('B',false);productState.activitySelection.set('OLD_PAGE',true);", context);
  return { context, nodes };
}

test('bulk selection is ADMIN-only and excludes inactive or stale result codes', () => {
  const { context } = harness();
  assert.equal(JSON.stringify(context.getProductActivitySelection()), '[{"codigo":"A","expected_active":true}]');
  assert.equal(harness('VENDEDOR').context.getProductActivitySelection().length, 0);
  const source = read('js/products.js');
  assert.match(source, /activitySelection\.clear\(\)/);
  assert.match(source, /Selecionar exibidos/);
});

test('ADMIN cards have independent checkboxes; seller cards have none', () => {
  const row = { codigo: '<X>', ativo: true, preco: 1 };
  assert.match(harness().context.renderProductCatalog([row], {}), /data-product-select="0"/);
  const seller = harness('VENDEDOR').context.renderProductCatalog([row], {});
  assert.doesNotMatch(seller, /data-product-select|productDeactivateSelected/);
});

test('confirmation cancellation does not call RPC', async () => {
  const { context } = harness();
  context.window.confirm = () => false;
  context.supabaseDeactivateProducts = async () => { throw new Error('UNEXPECTED_RPC'); };
  await context.deactivateSelectedProducts();
  assert.equal(context.getProductActivitySelection().length, 1);
});

test('bulk request blocks double clicks and clears selection only after success', async () => {
  const { context, nodes } = harness();
  let resolve;
  let calls = 0;
  context.supabaseDeactivateProducts = async (items) => {
    calls++;
    assert.equal(items.length, 1);
    return new Promise((done) => { resolve = done; });
  };
  const first = context.deactivateSelectedProducts();
  await context.deactivateSelectedProducts();
  assert.equal(calls, 1);
  assert.equal(nodes.productDeactivateSelected.disabled, true);
  resolve({ changed: 1 });
  await first;
  assert.equal(context.getProductActivitySelection().length, 0);
  assert.match(nodes.productMessage.textContent, /1 item inativado/);
});

test('failed bulk request preserves selection and unlocks retry', async () => {
  const { context, nodes } = harness();
  context.supabaseDeactivateProducts = async () => { throw new Error('Conflito: pesquise novamente.'); };
  await context.deactivateSelectedProducts();
  assert.match(nodes.productBulkMessage.textContent, /Conflito/);
  assert.equal(context.getProductActivitySelection().length, 1);
  assert.equal(nodes.productDeactivateSelected.disabled, false);
});

function storeHarness(response) {
  let calls = 0;
  let invalidations = 0;
  const context = vm.createContext({ supabaseClient: { rpc: async (name) => {
    assert.equal(name, 'deactivate_products'); calls++; return response;
  } } });
  vm.runInContext(read('js/supabase_store.js'), context);
  context.setStaticCache = () => { invalidations++; };
  return { context, calls: () => calls, invalidations: () => invalidations };
}

test('bulk store validates inputs, response completeness and friendly conflicts', async () => {
  for (const input of [[], [null], [{ codigo: 'A' }], [{ codigo: ' A ', expected_active: true }],
    [{ codigo: 'A', expected_active: true }, { codigo: 'A', expected_active: true }], Array(201).fill({ codigo: 'A', expected_active: true })]) {
    const h = storeHarness({});
    await assert.rejects(() => h.context.supabaseDeactivateProducts(input));
    assert.equal(h.calls(), 0);
  }
  for (const response of [{ error: { message: 'PRODUTO_ALTERADO_POR_OUTRO_USUARIO' } },
    { data: { count: 1, changed: 1, rows: [] } }, { data: { count: 1, changed: 1, rows: [null] } },
    { data: { count: 1, changed: 1, rows: [{ codigo: 'OTHER', ativo: false }] } }]) {
    const h = storeHarness(response);
    await assert.rejects(() => h.context.supabaseDeactivateProducts([{ codigo: 'A', expected_active: true }]));
    assert.equal(h.invalidations(), 0);
  }
  const h = storeHarness({ data: { count: 1, changed: 1, rows: [{ codigo: 'A', ativo: false }] } });
  await h.context.supabaseDeactivateProducts([{ codigo: 'A', expected_active: true }]);
  assert.equal(h.invalidations(), 1);
});

test('109 guards every update using persistent decisions and keeps bulk transaction bounded', () => {
  const sql = read('supabase/migrations/109_persistent_product_activity.sql');
  assert.match(sql, /product_activity_overrides/);
  assert.match(sql, /new\.ativo:=v_override/);
  assert.match(sql, /new\.ativo:=old\.ativo/);
  assert.match(sql, /between 1 and 200/);
  assert.match(sql, /for update of p/);
  assert.match(sql, /expected_active/);
  assert.match(sql, /ALTERAR_ATIVIDADE_PRODUTO/);
  assert.doesNotMatch(sql, /disable trigger|truncate|delete from public\.products/i);
});

test('112 permanently excludes the exact requested product denylist across future syncs', () => {
  const sql = read('supabase/migrations/112_permanent_product_exclusions.sql');
  const codesMatch = sql.match(/\$codes\$(\[[\s\S]*?\])\$codes\$/);
  assert.ok(codesMatch);
  const codes = JSON.parse(codesMatch[1]);
  assert.equal(codes.length, 74);
  assert.equal(new Set(codes.map((code) => code.trim().toUpperCase())).size, 74);
  for (const code of ['8769382300', 'BAN001', 'IMOB-25', 'PIS_CONFINS', 'X6115542222']) assert.ok(codes.includes(code));
  assert.match(sql, /product_catalog_exclusions/);
  assert.match(sql, /new\.ativo:=false/);
  assert.match(sql, /PRODUTO_EXCLUIDO_PERMANENTEMENTE/);
  assert.match(sql, /not exists\(select 1 from public\.product_catalog_exclusions/);
  assert.match(sql, /update public\.products p set ativo=false/);
  assert.doesNotMatch(sql, /delete from public\.products|truncate/i);
});
