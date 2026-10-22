const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const read = (file) => fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
function harness() {
  const c = vm.createContext({ APP_CONFIG: { currency: 'BRL' }, getStoredSession: () => ({ perfil: 'ADMIN' }) });
  vm.runInContext(read('js/utils/format.js'), c);
  return c;
}
test('maker labels distinguish unknown and universal without showing supplier codes', () => {
  const c = harness();
  assert.equal(c.vehicleMakerLabel('__SEM_MONTADORA__'), 'Não informada');
  assert.equal(c.formatVehicleMakers(['UNIVERSAL']), 'Aplicação universal');
  assert.equal(c.formatVehicleMakers([]), 'Não informada');
  assert.equal(c.formatVehicleMakers(['TOYOTA', 'FORD', 'TOYOTA']), 'TOYOTA / FORD');
  vm.runInContext(read('js/products.js'), c);
  const html = c.renderProductCard({ codigo: 'A', marca: 'ISAKA', montadora: '01 FT', vehicle_makers: ['TOYOTA', 'FORD'] }, 0);
  assert.match(html, /TOYOTA \/ FORD/);assert.doesNotMatch(html, /01 FT/);
});
test('vehicle maker and legacy manufacturer filters use separate API fields', async () => {
  const c = harness();let payload;
  vm.runInContext(read('js/supabase_store.js'), c);
  c.supabaseClient = { rpc: async (_, p) => { payload = p;return { data: [] }; } };
  await c.supabaseSearchProducts({ vehicleMaker: 'VOLKSWAGEN' });
  assert.equal(payload.filters.vehicle_maker, 'VOLKSWAGEN');assert.equal(payload.filters.maker, '');
  await c.supabaseSearchProducts({ montadora: '01 FT' });
  assert.equal(payload.filters.maker, '01 FT');assert.equal(payload.filters.vehicle_maker, '');
});
test('options use versioned cache and never fall back to scanning SAP manufacturers', async () => {
  const c = harness();const writes = [];
  vm.runInContext(read('js/supabase_store.js'), c);
  c.getStaticCache = (key) => { assert.equal(key, 'productFiltersV5');return null; };
  c.setStaticCache = (key, value) => writes.push({ key, value });
  c.supabaseClient = { from: () => { throw new Error('must not scan products'); }, rpc: async (name) => {
    assert.equal(name, 'get_catalog_filter_options');return { data: { grupos: [], linhas: [], marcas: [], montadoras: ['TOYOTA'] } };
  } };
  assert.equal((await c.supabaseListProductFilters()).montadoras[0], 'TOYOTA');
  assert.equal(writes[0].key, 'productFiltersV5');
  c.supabaseClient.rpc = async () => ({ data: { montadoras: [] } });
  await assert.rejects(() => c.supabaseListProductFilters(), /Filtros do catálogo/);
  assert.equal(writes.length, 1);
});
test('all commercial list pages preserve vehicle maker selection and export its names', async () => {
  const c = harness();let calls = 0;
  vm.runInContext(read('js/supabase_store.js'), c);
  c.supabaseClient = { rpc: async (_, p) => {
    assert.equal(p.filters.vehicle_maker, 'VOLKSWAGEN');
    return { data: { rows: [{ product_code: calls++ === 0 ? 'A' : 'B', vehicle_makers: ['VOLKSWAGEN'] }],
      count: 2, has_more: calls === 1, next_offset: calls, catalog_revision: '123:2026-10-22' } };
  } };
  const result = await c.supabaseGenerateCommercialList('PR-PR', { vehicle_maker: 'VOLKSWAGEN' });
  assert.equal(result.rows.length, 2);
  vm.runInContext(read('js/imports.js'), c);
  c.rows = result.rows;vm.runInContext('sapImportState.listRows=rows;', c);
  assert.equal(c.commercialExportRows()[0].MONTADORAS, 'VOLKSWAGEN');
});
test('SQL applies vehicle filters before pagination and never rewrites SAP manufacturers', () => {
  const sql = read('supabase/migrations/114_catalog_vehicle_makers.sql');
  assert.match(sql, /matches_product_vehicle_maker\(filters->>''vehicle_maker''/);
  assert.match(sql, /get_catalog_filter_options/);
  assert.doesNotMatch(sql, /update public\.products|set montadora|grant execute.*canonical_vehicle_maker/i);
});
test('changing maker preserves general-list pagination instead of truncating its export', () => {
  const c = harness();const events = new Map(), calls = [];
  c.document = { getElementById: (id) => ({ addEventListener: (name, callback) => events.set(id + ':' + name, callback) }) };
  vm.runInContext(read('js/products.js'), c);
  c.runProductSearch = (params) => calls.push(params);
  c.bindProductSearch();vm.runInContext('productState.generalList=true;', c);
  events.get('productMakerFilter:change')();
  assert.equal(calls[0].listaGeral, true);
});
