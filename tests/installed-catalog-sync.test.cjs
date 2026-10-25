const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const worker = require('../scripts/installed_catalog_worker.cjs');
const { prepare } = require('../scripts/prepare_installed_catalog_worker.cjs');
const read = (file) => fs.readFileSync(path.join(__dirname, '..', file), 'utf8');

function harness() {
  const nodes = {
    installedCatalogSyncNow: { disabled: false },
    installedCatalogMessage: { textContent: '' },
    installedCatalogHistory: { innerHTML: '' }
  };
  const context = vm.createContext({ document: { getElementById: (id) => nodes[id] },
    setTimeout: () => 1, clearTimeout: () => {}, escapeHtml: (v) => String(v).replaceAll('<', '&lt;'),
    Date, console });
  vm.runInContext(read('js/data_sync.js'), context);
  return { context, nodes };
}

test('installed Windows package is pinned and keeps credentials separate', () => {
  const os = require('node:os');
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'ips-package-unit-'));
  try {
    const location = path.join(folder, 'WindowsApps', 'Catalog_1.5.35');
    fs.mkdirSync(path.join(location, 'data'), { recursive: true });
    fs.writeFileSync(path.join(location, 'data', 'catalog.db'), 'fixture');
    fs.writeFileSync(path.join(location, 'manifest.json'), '{}');
    const info = { PackageFamilyName: worker.CATALOG_PACKAGE, InstallLocation: location };
    const files = worker.catalogPackagePaths(info, folder);
    assert.equal(files.database, fs.realpathSync.native(path.join(location, 'data', 'catalog.db')));
    assert.throws(() => worker.catalogPackagePaths({ ...info, PackageFamilyName: 'foreign' }, folder));
    assert.throws(() => worker.catalogPackagePaths({ ...info, InstallLocation: folder }, folder));
    const legacy = { password: 'fixture' };assert.equal(worker.resolveCatalogConfig(legacy), legacy);
    assert.throws(() => worker.resolveCatalogConfig({ catalogPackageFamily: 'foreign' }));
    assert.deepEqual(Object.keys(files).sort(), ['database', 'manifest']);
  } finally { fs.rmSync(folder, { recursive: true, force: true }); }
});

test('catalog action does not invoke Excel and double clicks are blocked', async () => {
  const { context, nodes } = harness();
  let finish;
  let requests = 0;
  context.supabaseRequestInstalledCatalogSync = () => { requests++; return new Promise((resolve) => { finish = resolve; }); };
  context.supabaseListInstalledCatalogSync = async () => ({ rows: [] });
  const first = context.triggerInstalledCatalogSync();
  await context.triggerInstalledCatalogSync();
  assert.equal(requests, 1);
  assert.equal(nodes.installedCatalogSyncNow.disabled, true);
  finish();
  await first;
  assert.equal(nodes.installedCatalogSyncNow.disabled, false);
});

test('catalog pending state expires and history never exposes a claim token', async () => {
  const { context, nodes } = harness();
  assert.equal(context.installedCatalogRequestPending({ status: 'queued', requested_at: new Date().toISOString() }), true);
  assert.equal(context.installedCatalogRequestPending({ status: 'running', lease_until: '2020-01-01' }), false);
  context.supabaseListInstalledCatalogSync = async () => ({ rows: [{ status: 'completed', usuario: '<script onclick=bad>', requested_at: new Date().toISOString(), summary: { updated: 2 } }] });
  await context.loadInstalledCatalogSync();
  assert.doesNotMatch(nodes.installedCatalogHistory.innerHTML, /<script\b/i);
  assert.match(nodes.installedCatalogHistory.innerHTML, /&lt;script/);
});

test('catalog failure does not touch Excel controls', async () => {
  const { context, nodes } = harness();
  context.supabaseListInstalledCatalogSync = async () => { throw new Error('private server details'); };
  await context.loadInstalledCatalogSync();
  assert.equal(nodes.installedCatalogSyncNow.disabled, true);
  assert.doesNotMatch(nodes.installedCatalogMessage.textContent, /private server/);
});

test('worker pins homolog, custom database role and full TLS verification', () => {
  const absolute = path.resolve(__dirname, 'fixture');
  const config = { project: worker.PROJECT, user: 'ips_catalog_worker.' + worker.PROJECT,
    host: 'aws-1-us-east-2.pooler.supabase.com', port: 5432, password: 'fixture',
    database: path.join(absolute, 'catalog.db'), manifest: path.join(absolute, 'manifest.json'),
    python: absolute, ca: absolute, evidence: absolute };
  assert.equal(worker.validateConfig(config), config);
  assert.equal(worker.PROJECT, 'mtwvxyvpnbgwgltelozw');
  for (const replacement of [{ project: 'doenvnjzrecrtvwooaai' }, { user: 'postgres.' + worker.PROJECT },
    { host: 'example.test' }, { port: 6543 }, { database: 'https://example.test/catalog.db' }]) {
    assert.throws(() => worker.validateConfig({ ...config, ...replacement }));
  }
  assert.match(read('scripts/installed_catalog_worker.cjs'), /rejectUnauthorized: true/);
  assert.doesNotMatch(read('scripts/installed_catalog_worker.cjs'), /process\.env\.PGPASSWORD/);
});

test('worker snapshot pages through a restricted RPC instead of direct table access', async () => {
  let calls = 0;
  const client = { query: async (sql, params) => {
    assert.match(sql, /snapshot_installed_catalog_sync/);
    assert.equal(params[0], 'job');
    return { rows: [{ rows: calls++ === 0 ? [{ codigo: '001' }] : [] }] };
  } };
  assert.deepEqual(await worker.snapshot(client, { id: 'job', claim_token: 'secret' }), [{ codigo: '001' }]);
  assert.equal(calls, 2);
});

test('setup preserves credentials and uses physical paths for the scheduler', () => {
  const os = require('node:os');
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'ips-config-unit-'));
  try {
    const files = { database: 'catalog.db', manifest: 'manifest.json', python: 'python.exe', ca: 'ca.crt' };
    for (const name of Object.keys(files)) {
      files[name] = path.join(folder, files[name]);
      fs.writeFileSync(files[name], 'fixture');
    }
    const config = { project: worker.PROJECT, user: 'ips_catalog_worker.' + worker.PROJECT,
      host: 'aws-1-us-east-2.pooler.supabase.com', port: 5432, password: 'unit-test-not-a-real-secret',
      ...files, evidence: path.join(folder, 'old-evidence') };
    const file = path.join(folder, 'config.json');
    fs.writeFileSync(file, JSON.stringify(config));
    const physical = prepare(file);
    const prepared = JSON.parse(fs.readFileSync(physical, 'utf8'));
    assert.equal(physical, fs.realpathSync.native(file));
    assert.equal(prepared.password, config.password);
    assert.equal(prepared.evidence, path.join(path.dirname(physical), 'evidence'));
    for (const name of Object.keys(files)) assert.equal(prepared[name], fs.realpathSync.native(files[name]));
    assert.match(read('scripts/register_installed_catalog_worker.ps1'), /prepare_installed_catalog_worker/);
  } finally {
    assert.ok(path.resolve(folder).startsWith(path.resolve(os.tmpdir()) + path.sep));
    assert.ok(path.basename(folder).startsWith('ips-config-unit-'));
    fs.rmSync(folder, { recursive: true });
  }
});

test('SQL queue fails closed, has no direct client grants and updates only technical fields', () => {
  const sql = read('supabase/migrations/108_installed_catalog_queue.sql');
  assert.match(sql, /enable row level security/i);
  assert.match(sql, /not public\.is_app_session_active\(\) or not public\.is_admin\(\)/);
  assert.match(sql, /unique index installed_catalog_one_pending/);
  assert.match(sql, /PRODUTO_ALTERADO_REVALIDAR/);
  assert.match(sql, /NOTAS_MANUAIS_PROTEGIDAS/);
  assert.match(sql, /product_catalog_metadata_audit/);
  const update = sql.match(/update public\.products set[\s\S]+?where codigo=item->>'codigo';/i)[0];
  assert.doesNotMatch(update, /\b(preco|estoque|ano|ncm|ativo|updated_at|descricao)\s*=/i);
  const browserHistory = sql.slice(sql.indexOf('create function public.list_installed_catalog_sync'), sql.indexOf('create function public.claim_installed_catalog_sync'));
  assert.doesNotMatch(browserHistory, /claim_token/);
  assert.match(read('app.html'), /data_sync\.js\?v=20261021-local-catalog-sync-1/);
});
