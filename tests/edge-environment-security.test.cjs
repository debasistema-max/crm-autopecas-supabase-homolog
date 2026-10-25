const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');
const read = (file) => fs.readFileSync(path.join(__dirname, '..', file), 'utf8');

function harness(overrides = {}, behavior = {}) {
  const env = { SUPABASE_URL: 'https://mtwvxyvpnbgwgltelozw.supabase.co', SUPABASE_ANON_KEY: 'test-public',
    SUPABASE_SERVICE_ROLE_KEY: 'test-server', DATA_SYNC_TARGET: 'homologacao', DATA_SYNC_GITHUB_TOKEN: 'test-token',
    DATA_SYNC_GITHUB_REPOSITORY: 'debasistema-max/ips-crm-excel-sync-private', DATA_SYNC_SCHEDULER_SECRET: 'test-scheduler', ...overrides };
  let handler;
  const fetches = [], calls = [];
  const client = {
    auth: { getUser: async () => ({ data: { user: behavior.invalidUser ? null : { id: 'fixture' } } }) },
    rpc: async (name) => {
      calls.push(name);
      if (name === 'get_app_session_status') return { data: { active: behavior.active !== false }, error: behavior.sessionError || null };
      if (name === 'can_manage_data_sync') return { data: behavior.allowed !== false };
      return { data: {} };
    }
  };
  const source = read('supabase/functions/excel-sync/index.ts').replace(/^import[^\n]+\n/, '');
  const context = vm.createContext({ Request, Response, AbortSignal, Map, Date,
    createClient: () => client, Deno: { env: { get: (key) => env[key] }, serve: (fn) => { handler = fn; } },
    fetch: async (url, options) => { fetches.push({ url, options });return new Response(null, { status: 204 }); } });
  vm.runInContext(stripTypeScriptTypes(source, { mode: 'transform' }), context);
  const request = (body = {}, headers = {}) => handler(new Request('https://example.invalid/excel-sync', {
    method: 'POST', headers: { Origin: 'https://debasistema-max.github.io', Authorization: 'Bearer fixture', ...headers }, body: JSON.stringify(body)
  }));
  return { request, fetches, calls };
}

test('sync rejects replaced sessions and session lookup failures before dispatch', async () => {
  for (const behavior of [{ active: false }, { sessionError: { message: 'unavailable' } }]) {
    const h = harness({}, behavior), response = await h.request();
    assert.equal(response.status, 401);assert.equal(h.fetches.length, 0);
    assert.equal(h.calls.includes('can_manage_data_sync'), false);
  }
});
test('sync rejects unauthorized users and foreign origins', async () => {
  const h = harness({}, { allowed: false });assert.equal((await h.request()).status, 403);
  assert.equal((await h.request({}, { Origin: 'https://evil.invalid' })).status, 403);assert.equal(h.fetches.length, 0);
});
test('sync dispatch is pinned to the current project in both environments', async () => {
  for (const [url, target] of [['https://mtwvxyvpnbgwgltelozw.supabase.co', 'homologacao'], ['https://doenvnjzrecrtvwooaai.supabase.co', 'producao']]) {
    const h = harness({ SUPABASE_URL: url, DATA_SYNC_TARGET: target });assert.equal((await h.request()).status, 202);
    assert.deepEqual(JSON.parse(h.fetches[0].options.body), { ref: 'main', inputs: { mode: 'synchronize', target } });
    assert.ok(h.fetches[0].options.signal);assert.equal(h.fetches.length, 1);
  }
});
test('sync fails closed on cross-environment or unknown project configuration', async () => {
  for (const env of [{ DATA_SYNC_TARGET: 'producao' }, { SUPABASE_URL: 'https://unknown.supabase.co' }]) {
    const h = harness(env);assert.equal((await h.request()).status, 503);assert.equal(h.fetches.length, 0);
    assert.equal(h.calls.some((name) => /^(create|stage|commit)_/.test(name)), false);
  }
});
test('sync cannot send the GitHub credential to a different repository or workflow', async () => {
  for (const env of [{ DATA_SYNC_GITHUB_REPOSITORY: 'attacker/repo' }, { DATA_SYNC_GITHUB_WORKFLOW: 'other.yml' }, { DATA_SYNC_GITHUB_REF: 'other' }]) {
    const h = harness(env);assert.equal((await h.request()).status, 503);assert.equal(h.fetches.length, 0);
  }
});
test('a regular user cannot invoke scheduler operations', async () => {
  const h = harness();assert.equal((await h.request({ operation: 'create', metadata: {} })).status, 403);
  assert.equal(h.calls.includes('create_data_sync_batch'), false);
});
test('scheduler uses its secret and does not require an interactive user session', async () => {
  const h = harness({}, { active: false });
  const r = await h.request({ operation: 'status', batch_id: '00000000-0000-4000-8000-000000000115' }, { 'x-sync-secret': 'test-scheduler' });
  assert.equal(r.status, 200);assert.equal(h.calls.includes('get_app_session_status'), false);assert.ok(h.calls.includes('get_data_sync_batch'));
});
test('B2B administrative and password functions reject replaced sessions; login keeps rate limiting', () => {
  for (const file of ['b2b-admin', 'b2b-change-password']) {
    const source = read(`supabase/functions/${file}/index.ts`);
    assert.match(source, /rpc\('get_app_session_status'\)/);assert.match(source, /sessionStatus\?\.active !== true/);
  }
  const login = read('supabase/functions/crm-login/index.ts');
  assert.match(login, /consume_public_endpoint_rate_limit/);assert.match(login, /Never log identifiers, passwords or returned tokens/);
});
