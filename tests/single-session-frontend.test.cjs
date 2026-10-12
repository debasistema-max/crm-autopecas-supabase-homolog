const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const root = path.resolve(__dirname, '..');

function harness() {
  const calls = [];
  const warnings = [];
  const listeners = {};
  const nodes = new Map();
  const node = (id) => {
    if (!nodes.has(id)) nodes.set(id, { value: '', hidden: false, textContent: '',
      addEventListener(event, callback) { this[event] = callback; } });
    return nodes.get(id);
  };
  let active = true;
  let rpcError = null;
  let logError = null;
  let signInError = null;
  let restoredSession = null;
  let authCallback;
  const deferred = [];
  let interval;
  const client = {
    functions: {
      async invoke(name, options) {
        assert.equal(name, 'crm-login');
        assert.equal(options.body.login, 'mock@example.invalid');
        assert.ok(options.body.password);
        calls.push('crm-login');
        return { data: { session: { access_token: 'mock-access', refresh_token: 'mock-refresh' } }, error: signInError };
      }
    },
    auth: {
      async signInWithPassword() { calls.push('signIn'); return { data: { user: { id: 'own-id' }, session: {} }, error: signInError }; },
      async setSession(session) {
        assert.equal(session.access_token, 'mock-access');
        calls.push('setSession');
        return { data: { user: { id: 'own-id' } } };
      },
      async getUser() { return { data: { user: { id: 'own-id' } } }; },
      async getSession() { return { data: { session: restoredSession } }; },
      onAuthStateChange(callback) { authCallback = callback; },
      async signOut(options) { calls.push(['signOut', options.scope]); return {}; }
    },
    async rpc(name) { calls.push(name); return { data: { active }, error: rpcError }; },
    from(table) {
      assert.equal(table, 'logs');
      return { async insert(row) { calls.push(row); return { error: logError }; } };
    }
  };
  const context = vm.createContext({ console: { warn: (...args) => warnings.push(args) },
    URLSearchParams,
    setTimeout(callback) { deferred.push(callback); },
    setInterval(callback, delay) { assert.equal(delay, 15000); interval = callback; return 1; },
    clearInterval() { interval = null; },
    addEventListener(event, callback) { listeners[event] = callback; },
    removeEventListener(event) { delete listeners[event]; },
    document: { visibilityState: 'visible', addEventListener(event, callback) { listeners[event] = callback; },
      removeEventListener(event) { delete listeners[event]; }, getElementById: node, querySelectorAll: () => [] },
    supabaseClient: client, isSupabaseReady: () => true, getStoredSession: () => ({ sessionId: 'not-trusted' }),
    clearStoredSession() {}, sessionStorage: { setItem() {} }, location: { href: '', hash: '', search: '', pathname: '/b2b/' },
    history: { replaceState() { context.location.hash = ''; context.location.search = ''; } },
    B2B_CONFIG: { locale: 'pt-BR', currency: 'BRL' } });
  context.window = context;
  context.supabase = { createClient: () => client };
  function load(file) {
    const canonical = path.join(root, file);
    const mirrored = path.join(root, file.replace(/^public\//, ''));
    vm.runInContext(fs.readFileSync(fs.existsSync(canonical) ? canonical : mirrored, 'utf8'), context);
  }
  load('public/js/session_guard.js');
  return { context, client, calls, warnings, listeners, node, load,
    poll: () => interval(), setActive: (value) => { active = value; },
    setRpcError: (value) => { rpcError = value; }, setLogError: (value) => { logError = value; },
    setRestoredSession: (value) => { restoredSession = value; },
    emitAuth: (event, session) => authCallback(event, session),
    async flushAuth() { while (deferred.length) await deferred.shift()(); },
    setSignInError: (value) => { signInError = value; } };
}

test('restore, interval, focus and visibility validate without claiming; start is idempotent', async () => {
  const h = harness();
  const guard = h.context.AppSessionGuard.create(h.client, () => assert.fail('unexpected disconnect'));
  await guard.validate();
  guard.start(); guard.start();
  await h.poll(); await h.listeners.focus();
  h.listeners.visibilitychange();
  await new Promise(setImmediate);
  assert.ok(h.calls.length >= 4);
  assert.ok(h.calls.every((call) => call === 'get_app_session_status'));
});

test('inactive session signs out locally once and reports the friendly message', async () => {
  const h = harness();
  const messages = [];
  const guard = h.context.AppSessionGuard.create(h.client, (message) => messages.push(message));
  guard.start(); h.setActive(false);
  await Promise.all([guard.validate().catch((error) => assert.equal(error.code, 'APP_SESSION_REPLACED')), h.poll()]);
  assert.equal(h.calls.filter(Array.isArray).length, 1);
  assert.equal(h.calls.find(Array.isArray)[1], 'local');
  assert.deepEqual(messages, [h.context.AppSessionGuard.message]);
  assert.ok(!h.calls.includes('claim_app_session'));
  assert.ok(!h.calls.includes('release_app_session'));
  assert.equal(h.listeners.focus, undefined);
});

test('temporary status errors do not disconnect or claim', async () => {
  const h = harness();
  const guard = h.context.AppSessionGuard.create(h.client, () => assert.fail('unexpected disconnect'));
  guard.start(); h.setRpcError(new Error('offline'));
  await h.poll();
  assert.deepEqual(h.calls, ['get_app_session_status']);
  assert.equal(h.warnings.length, 1);
});

test('CRM explicit login claims once, restore and polls never reclaim, login audit failure is nonfatal', async () => {
  const h = harness(); h.load('public/js/supabase_store.js');
  vm.runInContext(`supabaseCurrentProfile = async () => ({ usuario: 'mock', perfil: 'VENDEDOR' });
    supabaseModules = async () => [];`, h.context);
  h.setLogError(new Error('audit rejected'));
  // Mock auth ignores credentials; no passwords or real accounts are used.
  await h.context.supabaseLogin('mock@example.invalid', {});
  await h.context.supabaseValidateSession(); await h.poll();
  assert.equal(h.calls.filter((call) => call === 'claim_app_session').length, 1);
  assert.equal(h.calls[0], 'crm-login'); assert.equal(h.calls[1], 'setSession');
  assert.equal(h.calls[2], 'claim_app_session');
  assert.ok(!h.calls.includes('signIn'));
  assert.ok(!h.calls.includes('resolve_login_email'));
  assert.equal(h.warnings.length, 1);
  assert.equal(h.calls.find((call) => call.acao === 'LOGIN').user_id, 'own-id');
});

test('failed explicit login never claims and audit uses authenticated own ID, propagating errors', async () => {
  const h = harness(); h.load('public/js/supabase_store.js');
  h.setSignInError(new Error('invalid'));
  await assert.rejects(h.context.supabaseLogin('mock@example.invalid', {}), /Usuario ou senha invalidos/);
  assert.ok(!h.calls.includes('claim_app_session'));
  assert.ok(!h.calls.includes('setSession'));
  await h.context.supabaseLog('UPDATE', 'profiles', 'other-id', {});
  assert.equal(h.calls.find((call) => call.acao === 'UPDATE').user_id, 'own-id');
  h.setLogError(new Error('audit rejected'));
  await assert.rejects(h.context.supabaseLog('UPDATE', 'profiles', 'other-id', {}), /audit rejected/);
});

test('CRM rejects malformed Edge sessions and setSession errors generically without claims', async () => {
  const h = harness(); h.load('public/js/supabase_store.js');
  h.client.functions.invoke = async () => ({ data: { session: {} } });
  await assert.rejects(h.context.supabaseLogin('mock@example.invalid', {}), /Usuario ou senha invalidos/);
  h.client.functions.invoke = async () => ({ data: { session: { access_token: 'mock-access', refresh_token: 'mock-refresh' } } });
  h.client.auth.setSession = async () => ({ error: new Error('internal auth detail') });
  await assert.rejects(h.context.supabaseLogin('mock@example.invalid', {}), /^Error: Usuario ou senha invalidos\.$/);
  assert.equal(h.calls.length, 0);
});

test('CRM inactive session after Edge login preserves replacement message and never writes LOGIN', async () => {
  const h = harness(); h.load('public/js/supabase_store.js'); h.setActive(false);
  await assert.rejects(h.context.supabaseLogin('mock@example.invalid', {}), (error) => {
    assert.equal(error.message, h.context.AppSessionGuard.message);
    return error.code === 'APP_SESSION_REPLACED';
  });
  assert.equal(h.calls.filter((call) => call.acao === 'LOGIN').length, 0);
  assert.equal(h.calls.find(Array.isArray)[1], 'local');
});

test('B2B explicit login claims before first-password context; restore never claims', async () => {
  const h = harness(); h.load('public/b2b/js/app.js');
  vm.runInContext(`rpc = async () => ({ account: { must_change_password: true } }); bindAuth();`, h.context);
  await h.node('loginForm').submit({ preventDefault() {} });
  assert.equal(h.calls.filter((call) => call === 'claim_app_session').length, 1);
  assert.equal(h.node('passwordForm').hidden, false);
  await h.context.openPortal({}); await h.poll();
  assert.equal(h.calls.filter((call) => call === 'claim_app_session').length, 1);
  h.setActive(false); await h.poll();
  assert.equal(h.node('loginMessage').textContent, h.context.AppSessionGuard.message);
  assert.equal(h.node('portalView').hidden, true);
  assert.equal(h.calls.find(Array.isArray)[1], 'local');
});

test('explicit logout releases then signs out locally even when release fails', async () => {
  const h = harness();
  const guard = h.context.AppSessionGuard.create(h.client, () => {});
  h.setRpcError(new Error('release rejected'));
  await guard.logout();
  assert.equal(h.calls[0], 'release_app_session');
  assert.equal(h.calls[1][1], 'local');
});

test('overlapping polls share one request; stale inactive response cannot disconnect a new login', async () => {
  const h = harness();
  const originalRpc = h.client.rpc;
  let finish;
  h.client.rpc = (name) => {
    h.calls.push(name);
    return new Promise((resolve) => { finish = resolve; });
  };
  const guard = h.context.AppSessionGuard.create(h.client, () => assert.fail('stale disconnect'));
  const first = guard.validate();
  const second = guard.validate();
  assert.equal(h.calls.length, 1);
  const login = guard.claimAfterSignIn();
  h.client.rpc = originalRpc;
  finish({ data: { active: false } });
  assert.equal(await first, false); assert.equal(await second, false);
  await login;
  assert.equal(h.calls.filter((call) => call === 'claim_app_session').length, 1);
  assert.equal(h.calls.filter(Array.isArray).length, 0);
});

test('failed claim and failed post-claim validation clean up locally, never releasing the winner', async () => {
  for (const failurePoint of ['claim_app_session', 'get_app_session_status']) {
    const h = harness();
    const guard = h.context.AppSessionGuard.create(h.client, () => assert.fail('not a replacement'));
    h.client.rpc = async (name) => {
      h.calls.push(name);
      if (name === failurePoint) throw new Error('offline');
      return { data: { active: true } };
    };
    await assert.rejects(guard.claimAfterSignIn(), /offline/);
    assert.equal(h.calls.filter(Array.isArray).length, 1);
    assert.equal(h.calls.find(Array.isArray)[1], 'local');
    assert.ok(!h.calls.includes('release_app_session'));
  }
});

test('claim refusal maps SESSAO_SUBSTITUIDA to the friendly error and signs out once locally', async () => {
  const h = harness(); h.setRpcError({ message: 'SESSAO_SUBSTITUIDA', code: 'PT401' });
  const guard = h.context.AppSessionGuard.create(h.client, () => {});
  await assert.rejects(guard.claimAfterSignIn(), (error) => error.code === 'APP_SESSION_REPLACED'
    && error.message === h.context.AppSessionGuard.message);
  assert.equal(h.calls.filter(Array.isArray).length, 1);
  assert.equal(h.calls.find(Array.isArray)[1], 'local');
  assert.ok(!h.calls.includes('release_app_session'));
});

test('foundation accepts advisory claim active=false when authoritative status is active', async () => {
  const h = harness();
  h.client.rpc = async (name) => {
    h.calls.push(name);
    return { data: { active: name !== 'claim_app_session' } };
  };
  const guard = h.context.AppSessionGuard.create(h.client, () => assert.fail('unexpected disconnect'));
  await guard.claimAfterSignIn();
  assert.deepEqual(h.calls, ['claim_app_session', 'get_app_session_status']);
});

test('seed101 active restore and forged recovery type do not claim', async () => {
  const h = harness(); h.context.location.hash = '#type=recovery';
  h.setRestoredSession({ access_token: 'mock-restored' });
  h.load('public/b2b/js/app.js');
  vm.runInContext(`rpc = async () => ({ account: { must_change_password: true } });`, h.context);
  await h.context.init();
  h.emitAuth('INITIAL_SESSION', { access_token: 'mock-restored' });
  h.emitAuth('TOKEN_REFRESHED', { access_token: 'mock-refreshed' });
  await h.flushAuth(); await h.poll();
  assert.ok(!h.calls.includes('claim_app_session'));
  assert.ok(!h.calls.some(Array.isArray));
});

test('fresh invite/recovery link claims once before password form, consumes URL and loads activation context', async () => {
  for (const type of ['invite', 'recovery']) {
    const h = harness();
    h.context.location.hash = `#type=${type}&access_token=mock-link&refresh_token=mock-link-refresh`;
    const session = { access_token: 'mock-link' };
    h.setRestoredSession(session); h.load('public/b2b/js/app.js');
    vm.runInContext(`rpc = async () => ({ account: { activation_pending: true } });`, h.context);
    await h.context.init();
    h.emitAuth(type === 'recovery' ? 'PASSWORD_RECOVERY' : 'SIGNED_IN', session);
    await h.flushAuth();
    assert.equal(h.calls.filter((call) => call === 'claim_app_session').length, 1);
    assert.equal(h.node('passwordForm').hidden, false);
    assert.equal(h.context.location.hash, '');
    assert.equal(vm.runInContext('state.context.account.activation_pending', h.context), true);
    h.emitAuth('TOKEN_REFRESHED', { access_token: 'mock-refreshed' });
    await h.flushAuth(); await h.poll();
    assert.equal(h.calls.filter((call) => call === 'claim_app_session').length, 1);

    const reload = harness();
    reload.context.location.hash = h.context.location.hash;
    reload.setRestoredSession(session); reload.load('public/b2b/js/app.js');
    vm.runInContext(`rpc = async () => ({ account: { activation_pending: true } });`, reload.context);
    await reload.context.init();
    assert.ok(!reload.calls.includes('claim_app_session'));
    assert.equal(reload.node('passwordForm').hidden, false);
  }
});

test('PASSWORD_RECOVERY is deferred outside auth callback and claims once without a URL', async () => {
  const h = harness(); h.load('public/b2b/js/app.js');
  vm.runInContext(`rpc = async () => ({ account: {} });`, h.context);
  await h.context.init();
  h.emitAuth('PASSWORD_RECOVERY', { access_token: 'mock-recovery' });
  assert.equal(h.calls.length, 0);
  await h.flushAuth();
  assert.equal(h.calls.filter((call) => call === 'claim_app_session').length, 1);
  assert.equal(h.node('passwordForm').hidden, false);
});
