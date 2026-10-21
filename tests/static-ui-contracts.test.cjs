const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');

const repoRoot = path.resolve(__dirname, '..');
const publicRoot = fs.existsSync(path.join(repoRoot, 'public')) ? path.join(repoRoot, 'public') : repoRoot;
const resolveFile = (file) => {
  const relativeFile = file.replace(/^public\//, '');
  const publicFile = path.join(publicRoot, relativeFile);
  return fs.existsSync(publicFile) ? publicFile : path.join(repoRoot, relativeFile);
};
const read = (file) => fs.readFileSync(resolveFile(file), 'utf8');

function documentStatusHarness(kind, status) {
  const nodes = {
    [`${kind}EditPanel`]: { dataset: { documentStatus: status, statusBusy: 'false' } },
    [`${kind}EditId`]: { value: 'document-test' },
    [`${kind}Results`]: {},
    [`${kind}EditMessage`]: { style: {}, textContent: '' },
    [`${kind}EditStatusDisplay`]: { value: status },
    [`${kind}EditConfirmButton`]: { disabled: false },
    [`${kind}EditCancelDocumentButton`]: { disabled: false }
  };
  const context = vm.createContext({ window: {}, document: { getElementById: (id) => nodes[id] || null } });
  vm.runInContext(read('js/quotes.js'), context);
  let calls = 0;
  context.supabaseUpdateOrderStatus = context.supabaseUpdateQuotationStatus = async ({ status: next }) => {
    calls += 1;
    return { status: next };
  };
  context.loadDocumentReport = async () => {};
  context.syncDocumentStatusActions(kind);
  return { context, nodes, calls: () => calls };
}

test('document status buttons match the SQL transition rules and fail closed', () => {
  const cases = [
    ['pedidos', 'NOVO', true, true], ['pedidos', 'EM_ANALISE', true, true],
    ['pedidos', 'APROVADO', false, true], ['pedidos', 'FATURADO', false, false],
    ['pedidos', 'CANCELADO', false, false], ['cotacoes', 'NOVA', true, true],
    ['cotacoes', 'ENVIADA', true, true], ['cotacoes', 'APROVADA', false, false],
    ['cotacoes', 'CONVERTIDA', false, false], ['cotacoes', 'CANCELADA', false, false],
    ['cotacoes', '', false, false], ['pedidos', 'UNKNOWN', false, false],
    ['unknown', 'NOVO', false, false]
  ];
  for (const [kind, status, confirm, cancel] of cases) {
    const { nodes } = documentStatusHarness(kind, status);
    assert.equal(nodes[`${kind}EditConfirmButton`].disabled, !confirm, `${kind}/${status}/confirm`);
    assert.equal(nodes[`${kind}EditCancelDocumentButton`].disabled, !cancel, `${kind}/${status}/cancel`);
  }
});

test('approving a quotation disables both actions and rejects a subsequent cancellation', async () => {
  const { context, nodes, calls } = documentStatusHarness('cotacoes', 'NOVA');
  await context.updateDocumentStatus('cotacoes', 'document-test', 'APROVADA');
  assert.equal(nodes.cotacoesEditPanel.dataset.documentStatus, 'APROVADA');
  assert.equal(nodes.cotacoesEditConfirmButton.disabled, true);
  assert.equal(nodes.cotacoesEditCancelDocumentButton.disabled, true);
  await context.updateDocumentStatus('cotacoes', 'document-test', 'CANCELADA');
  assert.equal(calls(), 1);
});

test('an approved order still permits cancellation', async () => {
  const { context, nodes, calls } = documentStatusHarness('pedidos', 'APROVADO');
  await context.updateDocumentStatus('pedidos', 'document-test', 'CANCELADO');
  assert.equal(calls(), 1);
  assert.equal(nodes.pedidosEditPanel.dataset.documentStatus, 'CANCELADO');
  assert.equal(nodes.pedidosEditCancelDocumentButton.disabled, true);
});

test('failed status requests restore actions for the unchanged status', async () => {
  const { context, nodes } = documentStatusHarness('cotacoes', 'NOVA');
  context.supabaseUpdateQuotationStatus = async () => { throw new Error('Falha de teste'); };
  await context.updateDocumentStatus('cotacoes', 'document-test', 'APROVADA');
  assert.equal(nodes.cotacoesEditPanel.dataset.documentStatus, 'NOVA');
  assert.equal(nodes.cotacoesEditConfirmButton.disabled, false);
  assert.equal(nodes.cotacoesEditCancelDocumentButton.disabled, false);
  assert.equal(nodes.cotacoesEditMessage.textContent, 'Falha de teste');
});

test('a report refresh failure does not restore actions for a committed quotation', async () => {
  const { context, nodes } = documentStatusHarness('cotacoes', 'NOVA');
  context.loadDocumentReport = async () => { throw new Error('Falha no relatorio'); };
  await context.updateDocumentStatus('cotacoes', 'document-test', 'APROVADA');
  assert.equal(nodes.cotacoesEditPanel.dataset.documentStatus, 'APROVADA');
  assert.equal(nodes.cotacoesEditCancelDocumentButton.disabled, true);
});

test('pending status changes prevent double clicks and ignore responses for a replaced editor', async () => {
  const { context, nodes } = documentStatusHarness('cotacoes', 'NOVA');
  let resolve;
  let calls = 0;
  context.supabaseUpdateQuotationStatus = () => {
    calls += 1;
    return new Promise((done) => { resolve = done; });
  };
  const pending = context.updateDocumentStatus('cotacoes', 'document-test', 'APROVADA');
  context.showDocumentEditForm('cotacoes', { id: 'document-test', status: 'NOVA' });
  assert.equal(nodes.cotacoesEditPanel.dataset.statusBusy, 'true');
  assert.equal(nodes.cotacoesEditConfirmButton.disabled, true);
  assert.equal(nodes.cotacoesEditCancelDocumentButton.disabled, true);
  await context.updateDocumentStatus('cotacoes', 'document-test', 'CANCELADA');
  assert.equal(calls, 1);
  nodes.cotacoesEditId = { value: 'different-document' };
  nodes.cotacoesEditPanel.dataset.documentStatus = 'ENVIADA';
  nodes.cotacoesEditPanel.dataset.statusBusy = 'false';
  context.window.cotacoesLastRows = [{ id: 'document-test', status: 'NOVA' }];
  let refreshes = 0;
  context.loadDocumentReport = async () => { refreshes += 1; };
  context.syncDocumentStatusActions('cotacoes');
  resolve({ status: 'APROVADA' });
  await pending;
  assert.equal(nodes.cotacoesEditPanel.dataset.documentStatus, 'ENVIADA');
  assert.equal(nodes.cotacoesEditCancelDocumentButton.disabled, false);
  assert.equal(context.window.cotacoesLastRows[0].status, 'APROVADA');
  assert.equal(refreshes, 1);
});
function filesIn(directory, extension) {
  const base = fs.existsSync(path.join(publicRoot, directory)) ? publicRoot : repoRoot;
  return fs.readdirSync(path.join(base, directory), { withFileTypes: true }).flatMap((entry) => {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) return entry.name === 'vendor' ? [] : filesIn(file, extension);
    return file.endsWith(extension) ? [file] : [];
  });
}
const htmlFiles = ['index.html', 'app.html', ...filesIn('tests', '.html'), ...filesIn('cadastro-publico', '.html'), ...filesIn('b2b', '.html')];

function inlineScriptBlocks(html) {
  const lower = html.toLowerCase();
  const blocks = [];
  let cursor = 0;
  while (cursor < html.length) {
    const open = lower.indexOf('<script', cursor);
    if (open < 0) break;
    const tagEnd = html.indexOf('>', open + 7);
    if (tagEnd < 0) break;
    const close = lower.indexOf('</script>', tagEnd + 1);
    if (close < 0) break;
    blocks.push({
      attributes: html.slice(open + 7, tagEnd),
      source: html.slice(tagEnd + 1, close)
    });
    cursor = close + 9;
  }
  return blocks;
}

test('application and public registration JavaScript parses without execution', () => {
  for (const file of [...filesIn('js', '.js'), ...filesIn('cadastro-publico/js', '.js'), ...filesIn('b2b/js', '.js')]) {
    assert.doesNotThrow(() => new vm.Script(read(file), { filename: file }), file);
  }
});

test('all HTML inline scripts parse without execution', () => {
  for (const file of htmlFiles) {
    for (const { attributes, source } of inlineScriptBlocks(read(file))) {
      if (/\bsrc\s*=/.test(attributes) || !source.trim()) continue;
      assert.doesNotThrow(() => new vm.Script(source, { filename: file }), file);
    }
  }
});

test('HTML references resolve to existing local scripts and stylesheets', () => {
  for (const file of htmlFiles) {
    const links = read(file).matchAll(/<(?:script|link)\b[^>]*\b(?:src|href)=["']([^"']+)["']/gi);
    for (const [, reference] of links) {
      if (/^(?:https?:)?\/\//.test(reference)) continue;
      const target = path.resolve(path.dirname(resolveFile(file)), reference.split(/[?#]/)[0]);
      const publicLayoutTarget = path.resolve(publicRoot, path.dirname(file), reference.split(/[?#]/)[0]);
      assert.ok(fs.existsSync(target) || fs.existsSync(publicLayoutTarget), `${file}: ${reference}`);
    }
  }
});

test('administrative templates preserve critical control IDs', () => {
  const contracts = {
    'js/users.js': ['userForm', 'userId', 'newUserProfile', 'newUserPassword', 'newUserActive', 'logsFilter', 'logsUser', 'logsAction'],
    'js/cadastros.js': ['cadastroSearch', 'cadastroStatusFilter', 'portalEmailPrincipal', 'portalReportFrom', 'portalReportTo'],
    'js/company_settings.js': ['companySettingsForm', 'companyName', 'companyState', 'companyTimezone', 'companyLanguage', 'companyLogoFile', 'companyLogoPreview'],
    'js/tax_rules.js': ['taxRuleForm', 'taxRuleId', 'taxRuleNcm', 'taxRuleUfOrigem', 'taxRuleUfDestino', 'taxRuleMva',
      'taxRuleResaleMethod', 'taxRuleResaleIcmsSt', 'taxRuleResaleOwnIcms', 'taxRuleEffectiveFrom', 'taxRuleEffectiveTo']
  };
  for (const [file, ids] of Object.entries(contracts)) {
    const source = read(file);
    for (const id of ids) assert.ok(source.includes(`id="${id}"`), `${file}: ${id}`);
  }
});

test('editable registration table controls have accessible names', () => {
  const source = read('js/cadastros.js');
  for (const field of ['codigo-sap', 'status', 'notes']) {
    assert.match(source, new RegExp(`<(?:input|select|textarea) data-cadastro-${field} aria-label="[^"<]+"`));
  }
  assert.match(read('js/tax_rules.js'), /id="taxRuleOpenImportCenter"[^>]*>Abrir Central de Importações<\/button>/);
  assert.match(read('js/tax_rules.js'), /id="taxRuleChangeReason"[^>]*required/);
  assert.match(read('js/tax_rules.js'), /data-tax-history=/);
  assert.match(read('js/tax_rules.js'), /data-tax-version=/);
  assert.match(read('js/supabase_store.js'), /create_fiscal_tax_rule_version/);
  assert.match(read('js/supabase_store.js'), /transition_fiscal_tax_rule/);
  assert.match(read('js/supabase_store.js'), /list_fiscal_tax_rule_versions/);
});

test('administrative smoke never loads a live persistence client', () => {
  const source = read('tests/ui-mobile-admin-smoke.html');
  assert.doesNotMatch(source, /<script[^>]+src=["'][^"']*(?:supabase|auth|store)/i);
  assert.doesNotMatch(source, /\b(?:fetch|XMLHttpRequest|createClient)\s*\(/);
  for (const adapter of ['supabaseSaveCompanySettings', 'supabaseSaveUser', 'supabaseUpdateCadastroCliente',
    'supabaseSavePortalCadastroSettings', 'supabaseSaveBusinessClientFromCadastro', 'supabaseSaveFiscalTaxRule', 'supabaseDeleteFiscalTaxRule']) {
    assert.ok(source.includes(`${adapter} = denyMutation`), adapter);
  }
});

test('login retains browser credential autofill and labeled inputs', () => {
  const source = read('index.html');
  assert.match(source, /id="usuario"[^>]*autocomplete="username"/);
  assert.match(source, /id="senha"[^>]*type="password"[^>]*autocomplete="current-password"/);
  assert.match(source, /id="loginButton"[^>]*type="submit"/);
  assert.match(source, /id="loginMessage"[^>]*role="alert"/);
});

test('login keeps the access card visible in portrait, landscape and desktop layouts', () => {
  const html = read('public/index.html');
  const css = read('public/css/login.css');
  const auth = read('public/js/auth.js');
  assert.match(html, /class="login-brand__lockup"/);
  assert.match(html, /class="login-card__eyebrow">Área restrita/);
  assert.match(html, /class="login-brand__status"/);
  assert.doesNotMatch(html, /class="brand-watermark"/);
  assert.match(css, /grid-template-columns: minmax\(0, 1fr\) minmax\(360px, 420px\)/);
  assert.match(css, /@media \(max-width: 700px\)/);
  assert.match(css, /@media \(min-width: 701px\) and \(max-height: 620px\)/);
  assert.match(css, /@media \(min-width: 701px\) and \(max-width: 860px\)/);
  assert.match(css, /\.customer-portal-link\[hidden\]/);
  assert.match(auth, /cardHeader\.hidden = target !== 'login'/);
  assert.match(auth, /customerPortalLink\.hidden = target !== 'login'/);
});

test('customer access and shared portal buttons keep strong visual contrast', () => {
  const loginCss = read('public/css/login.css');
  const themeCss = read('public/css/theme.css');
  const loginScope = loginCss.match(/\.login-page\s*\{([^}]+)\}/)[1];
  const textColor = loginScope.match(/--primary-strong:\s*(#[0-9a-f]{6})/i)[1];
  const luminance = (hex) => {
    const channels = hex.slice(1).match(/../g).map((part) => parseInt(part, 16) / 255);
    const linear = channels.map((value) => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
    return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722;
  };
  assert.ok((1.05 / (luminance(textColor) + 0.05)) >= 4.5, 'Login text must remain readable when the company secondary color is pale');
  assert.match(loginScope, /color-scheme:\s*light/);
  const placeholder = loginCss.match(/\.login-secondary-form input::placeholder\s*\{([^}]+)\}/)[1];
  const placeholderColor = placeholder.match(/color:\s*(#[0-9a-f]{6})/i)[1];
  assert.ok((luminance('#fbfcfd') + 0.05) / (luminance(placeholderColor) + 0.05) >= 4.5);
  assert.match(placeholder, /opacity:\s*1/);
  assert.match(loginCss, /\.customer-portal-link[\s\S]+min-height: 48px[\s\S]+background: #e5f3f0/);
  assert.match(loginCss, /\.customer-portal-link:hover,[\s\S]+border-color: var\(--primary\)/);
  assert.match(themeCss, /\.btn-secondary[\s\S]+background: #d8ece8[\s\S]+border-color: #84bbb2/);
  assert.match(themeCss, /\.btn-ghost[\s\S]+background: #fff[\s\S]+border-color: var\(--line-strong\)/);
});

test('company identity uses an admin-only image upload instead of an editable logo URL', () => {
  const settings = read('public/js/company_settings.js');
  const migration = read('supabase/migrations/099_company_logo_storage.sql');
  assert.match(settings, /id="companyLogoFile"[^>]+type="file"[^>]+accept="image\/png,image\/jpeg,image\/webp"/);
  assert.doesNotMatch(settings, /id="companyLogoUrl"/);
  assert.match(settings, /COMPANY_LOGO_MAX_BYTES = 2 \* 1024 \* 1024/);
  assert.match(settings, /validateCompanyLogoFile\(file\)/);
  assert.match(settings, /\.from\(COMPANY_LOGO_BUCKET\)[\s\S]+\.upload\(path, file/);
  assert.match(settings, /getPublicUrl\(path\)/);
  assert.match(settings, /removeManagedCompanyLogo\(previousLogoPath\)/);
  assert.match(migration, /'company-assets',[\s\S]+true,[\s\S]+2097152/);
  assert.match(migration, /'image\/jpeg'[\s\S]+'image\/png'[\s\S]+'image\/webp'/);
  assert.match(migration, /for insert[\s\S]+to authenticated[\s\S]+public\.is_admin\(\)/);
  assert.match(migration, /for delete[\s\S]+to authenticated[\s\S]+public\.is_admin\(\)/);
  assert.equal((migration.match(/name like 'identity\/%'/g) || []).length, 2);
  assert.doesNotMatch(migration, /service_role|grant\s+all/i);
});

test('company identity falls back to the approved IPS and Yokomitsu logo', () => {
  const settings = read('public/js/company_settings.js');
  assert.match(settings, /logo_url: 'assets\/logo-ips-yokomitsu\.png'/);
  assert.ok(fs.existsSync(path.join(publicRoot, 'assets/logo-ips-yokomitsu.png')));
});

test('CRM login provides secure email password recovery with a mobile-friendly policy', () => {
  const login = read('public/index.html');
  const auth = read('public/js/auth.js');
  assert.match(login, /id="forgotPasswordButton"/);
  assert.match(login, /id="recoveryRequestForm"/);
  assert.match(login, /id="passwordResetForm"/);
  assert.match(login, /id="newPassword"[^>]+minlength="8"/);
  assert.match(auth, /resetPasswordForEmail\(email, \{ redirectTo \}\)/);
  assert.match(auth, /event === 'PASSWORD_RECOVERY'/);
  assert.match(auth, /supabaseClient\.auth\.getSession\(\)/);
  assert.match(auth, /updateUser\(\{ password \}\)/);
  assert.match(auth, /password\.length < 8/);
  assert.match(auth, /\!\/\[A-Za-z\]\//);
  assert.match(auth, /\!\/\[0-9\]\//);
  assert.match(auth, /supabaseClient\.auth\.signOut\(\{ scope: 'local' \}\)/);
});

test('Data Center is wired without frontend secrets and keeps manual imports', () => {
  const html = read('app.html');
  const app = read('js/app.js');
  const sync = read('js/data_sync.js');
  const store = read('js/supabase_store.js');
  assert.match(html, /data-module="dataCentral"/);
  assert.match(html, /Importação e Integrações/);
  assert.match(html, /src="js\/data_sync\.js/);
  assert.match(app, /dataCentral: \{[^\n]+adminOnly: true/);
  for (const id of ['dataSyncNow', 'dataSyncDetails', 'dataSyncErrors', 'dataSyncHistory', 'dataSyncStatusContent']) {
    assert.ok(sync.includes(`id="${id}"`), id);
  }
  assert.match(store, /functions\.invoke\('excel-sync'/);
  assert.match(store, /refreshDataSyncSession/);
  assert.match(store, /auth\.getSession\(\)/);
  assert.match(store, /Authorization: `Bearer \$\{session\.access_token\}`/);
  assert.match(store, /error\?\.context\?\.status/);
  assert.match(store, /supabaseDataSyncRpc\('list_data_sync_batches'/);
  assert.doesNotMatch(sync + store, /service[_ -]?role|DATA_SYNC_ADAPTER_TOKEN/i);
  assert.match(read('js/imports.js'), /function renderImportCenter/);
  const smoke = read('tests/ui-data-sync-smoke.html');
  assert.doesNotMatch(smoke, /<script[^>]+src=["'][^"']*(?:supabase|auth|store)/i);
  assert.doesNotMatch(smoke, /\b(?:fetch|XMLHttpRequest|createClient)\s*\(/);
});

test('sync report uses batch-scoped audited changes, readable values and escaped content', async () => {
  const target = { innerHTML: '', isConnected: true };
  const button = { disabled: false, isConnected: true };
  let requested;
  const context = vm.createContext({
    document: { getElementById: () => target, querySelector: () => button },
    CrmUi: { renderState: () => '' },
    escapeHtml: (value) => String(value ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'),
    supabaseListDataSyncAudit: async (filters) => {
      requested = filters;
      return { rows: [
        { product_code: '001', field_name: 'stock_qty', area: 'STOCK', old_value: 10, new_value: 0, batch_id: 'batch-1' },
        { product_code: '001', field_name: 'base_price', area: 'BASE_PRICE', old_value: 100, new_value: 90, batch_id: 'batch-1' },
        { product_code: '002', field_name: 'description', area: 'PRODUCT', old_value: null, new_value: '<script>bad</script>', batch_id: 'batch-1' }
      ] };
    }
  });
  vm.runInContext(read('public/js/data_sync.js'), context);
  await vm.runInContext("loadDataSyncAudit({batch_id:'batch-1',area:'',product_code:''})", context);
  assert.equal(requested.batch_id, 'batch-1');
  assert.equal(requested.limit, 2000);
  assert.match(target.innerHTML, /2 produtos · 3 alterações exibidas/);
  assert.match(target.innerHTML, /Estoque/);
  assert.match(target.innerHTML, /Preço-base/);
  assert.match(target.innerHTML, /<td>0<\/td>/);
  assert.match(target.innerHTML, /&lt;script&gt;bad&lt;\/script&gt;/);
  assert.doesNotMatch(target.innerHTML, /<script\b/i);
  assert.equal(button.disabled, false);
  assert.equal(vm.runInContext("dataSyncAuditValue(null, 'stock_qty')", context), '—');
  assert.equal(vm.runInContext("dataSyncAuditField('future_field')", context), 'future_field');
});

test('personal OneDrive runner is server-only, chunked and backup-scoped', () => {
  const workflow = read('.github/workflows/excel-sync.yml');
  const runner = read('scripts/sync_onedrive_personal.py');
  const edge = read('supabase/functions/excel-sync/index.ts');
  assert.match(workflow, /permissions:\s*\n\s*contents: read/);
  assert.match(workflow, /workflow_dispatch:/);
  assert.doesNotMatch(workflow, /pull_request:/);
  assert.doesNotMatch(workflow, /SUPABASE_SERVICE_ROLE_KEY/);
  assert.match(workflow, /vars\.DATA_SYNC_ENABLED == 'true'/);
  assert.match(runner, /offline_access Files\.ReadWrite/);
  assert.match(runner, /BACKUP_FOLDER_NAME = "Backups CRM"/);
  assert.match(runner, /BACKUP_RETENTION = 30/);
  assert.match(runner, /"If-None-Match": "\*"/);
  assert.match(runner, /removed_to_recycle_bin/);
  assert.match(runner, /CHUNK_ROWS = 500/);
  assert.match(runner, /"operation": "prepare"/);
  assert.match(runner, /"operation": "validate"/);
  assert.match(runner, /"operation": "commit"/);
  assert.doesNotMatch(runner, /"operation": "fail"/);
  assert.match(edge, /operation === 'create'/);
  assert.match(edge, /operation === 'stage'/);
  assert.match(edge, /operation === 'validate'/);
  assert.match(edge, /operation === 'commit'/);
  assert.match(edge, /PUSH_EXIGE_SEGREDO_DO_AGENDADOR/);
  assert.match(edge, /DATA_SYNC_GITHUB_TOKEN/);
  assert.match(edge, /actions\/workflows/);
  assert.doesNotMatch(edge, /env\('DATA_SYNC_ADAPTER_URL'\)/);
});

test('quotes read synchronized branch price and stock instead of legacy product fields', () => {
  const store = read('js/supabase_store.js');
  const migration = read('supabase/migrations/065_quote_reads_branch_price_stock.sql');
  assert.match(store, /get_branch_product_availability_v2/);
  assert.match(store, /\$\{branch\}_available_qty/);
  assert.match(store, /\$\{branch\}_price/);
  assert.match(migration, /product_branch_prices/);
  assert.match(migration, /product_branch_stock/);
  assert.match(migration, /create or replace function public\.search_products/);
  assert.doesNotMatch(migration, /then p\.preco_pr else p\.preco_sp/);
});

test('CRM product search uses the current unified branch catalog', () => {
  const store = read('js/supabase_store.js');
  const products = read('js/products.js');
  const migration = read('supabase/migrations/082_current_crm_product_search.sql');
  const paginationMigration = read('supabase/migrations/110_paginate_crm_product_catalog.sql');
  const regression = read('supabase/tests/082_current_crm_product_search_regression.sql');
  assert.match(store, /rpc\('search_products_v2'/);
  assert.match(store, /favorite_codes: favoriteCodes/);
  assert.doesNotMatch(store.slice(store.indexOf('async function supabaseSearchProducts'), store.indexOf('async function enrichProductsWithBranchAvailability')), /return supabaseListProducts/);
  assert.match(products, /PRODUCT_GENERAL_PAGE_SIZE = 200/);
  assert.match(products, /data-product-page="next"/);
  assert.match(products, /runProductGeneralListPage/);
  assert.match(store, /offset: Math\.max\(Number\(params\.offset \|\| 0\), 0\)/);
  assert.match(products, /productSearchRequests\.get\(target\) !== requestId/);
  assert.match(migration, /product_branch_stock/);
  assert.match(migration, /product_branch_prices/);
  assert.match(migration, /product_catalog_metadata/);
  assert.match(migration, /not exists \(\s*select 1 from unnest\(v_tokens\)/);
  assert.match(migration, /sp_source_display_value/);
  assert.match(paginationMigration, /pg_get_functiondef\('public\.search_products_v2\(jsonb\)'::regprocedure\)/);
  assert.match(paginationMigration, /offset v_offset/);
  assert.match(paginationMigration, /CONTRATO_BUSCA_110_PAGINACAO_DIVERGENTE/);
  assert.match(regression, /caixa hilux/);
});

test('mobile CRM keeps document scrolling available on iOS', () => {
  const css = read('css/app.css');
  const app = read('js/app.js');
  const mobile = css.slice(css.indexOf('@media (max-width: 680px)'));
  assert.match(mobile, /\.topbar \{\s*position: static;/);
  assert.match(mobile, /\.product-search-panel \{\s*position: static;/);
  assert.match(mobile, /\.panel,\s*\.product-card \{\s*content-visibility: visible;/);
  assert.match(css, /@media \(max-width: 720px\)[\s\S]*?\.commercial-focus-header \{\s*position: static;/);
  assert.match(app, /window\.addEventListener\('pageshow', \(\) => toggleMobileMenu\(false\)\)/);
  assert.match(app, /matchMedia\('\(min-width: 981px\)'\)/);
  assert.match(app, /aria-expanded/);
});

test('seller portal uses a B2B-inspired mobile shell without changing other roles', () => {
  const html = read('app.html');
  const app = read('js/app.js');
  const dashboard = read('js/dashboard.js');
  const css = read('css/app.css');
  assert.match(html, /data-mobile-module="dashboard" data-seller-only hidden/);
  for (const module of ['dashboard', 'products', 'partners', 'quoteReports', 'ordersReport']) {
    assert.match(html, new RegExp(`data-mobile-module="${module}"`));
  }
  assert.match(app, /classList\.toggle\('seller-portal-mode', isCurrentUserSeller\(\)\)/);
  assert.match(app, /button\.hasAttribute\('data-seller-only'\) && !isCurrentUserSeller\(\)/);
  assert.match(app, /orderCreate: \{ module: 'ordersReport', action: 'create' \}/);
  assert.match(dashboard, /class="seller-welcome"/);
  assert.match(dashboard, /data-dashboard-route="quoteCreate"/);
  assert.match(dashboard, /data-dashboard-route="orderCreate"/);
  assert.match(dashboard, /class="btn seller-welcome-secondary" type="button" data-dashboard-refresh/);
  assert.match(css, /\.seller-portal-mode \.mobile-nav \{[\s\S]*?grid-template-columns: repeat\(5/);
  assert.match(css, /\.seller-portal-mode \.sidebar,[\s\S]*?display: none !important/);
});

test('product detail opens in an isolated full-screen sheet without moving the catalog', () => {
  const products = read('js/products.js');
  const css = read('css/app.css');
  const detail = products.slice(products.indexOf('function renderProductDetail'), products.indexOf('function detailItem'));
  assert.match(products, /id="productDetailModal" role="dialog" aria-modal="true"/);
  assert.match(products, /id="productDetailClose"/);
  assert.match(products, /function showProductDetailModal/);
  assert.match(products, /document\.body\.classList\.add\('product-detail-open'\)/);
  assert.match(products, /document\.body\.classList\.remove\('product-detail-open'\)/);
  assert.doesNotMatch(products, /<aside class="panel product-detail-panel" id="productDetail">/);
  assert.match(css, /\.product-detail-modal \{\s*position: fixed;\s*inset: 0;/);
  assert.match(css, /height: 100dvh;/);
  assert.match(css, /\.product-detail-dialog-body \{[\s\S]*?overflow-y: auto;/);
  for (const commercialField of ['Marca', 'Linha', 'Grupo', 'Montadora', 'OEM', 'Similares', 'Aplicacoes', 'Estoque', 'Preco SP', 'Preco PR']) {
    assert.ok(detail.includes(`detailItem('${commercialField}'`), commercialField);
  }
  assert.doesNotMatch(detail, /NCM|CEST|IPI|Origem|Preço por rota|Tributos|motor fiscal/);
  assert.doesNotMatch(products, /supabaseGetProductRoutePrices\(product\.codigo\)/);
});

test('quotation and order creation keep only the essential commercial workflow visible', () => {
  for (const file of ['js/quotes.js', 'js/orders.js']) {
    const source = read(file);
    const createView = source.slice(0, source.indexOf('\nfunction apply'));
    assert.match(createView, /class="commercial-more-fields"/);
    assert.match(createView, /class="commercial-focus-header"/);
    assert.match(createView, /FocusBackButton/);
    assert.match(createView, /Dados complementares/);
    assert.match(createView, /Codigo, nome ou aplicacao/);
    assert.match(createView, /id="(?:quote|order)Usage" type="hidden" value="Revenda"/);
    assert.doesNotMatch(createView, /<option>Consumo<\/option>/);
    assert.match(createView, /type="number" min="1" value="1"/);
    assert.doesNotMatch(createView, /class="commercial-steps"/);
    assert.doesNotMatch(createView, /class="sap-titlebar"/);
    assert.doesNotMatch(createView, /Nenhum cliente selecionado/);
    assert.doesNotMatch(createView, /Impostos calculados automaticamente/);
    assert.match(source, /<th>Produto<\/th><th>Qtde<\/th><th>Preco<\/th>/);
    assert.match(source, /colspan="6" class="sap-empty-row"/);
    assert.match(source, /class="commercial-item-details"/);
    assert.match(source, /renderCommercialTotal/);
    assert.match(source, /customer_type: 'REVENDA'/);
    assert.doesNotMatch(createView, /Status SAP<input/);
    assert.doesNotMatch(createView, /Autorizacao portal<input/);
  }
});

test('commercial pricing prioritizes approved Excel route results and fixes resale context', () => {
  const store = read('js/supabase_store.js');
  const migration = read('supabase/migrations/066_prioritize_excel_route_prices.sql');
  const fallbackGuard = read('supabase/migrations/084_block_unapproved_fiscal_fallback.sql');
  const regression = read('supabase/tests/066_excel_route_price_priority_regression.sql');
  assert.match(store, /customerType = 'REVENDA'/);
  assert.match(store, /customerType \|\| 'REVENDA'/);
  assert.match(migration, /from public\.product_route_prices/);
  assert.match(migration, /'price_source','EXCEL_ROUTE_PRICE'/);
  assert.match(migration, /'customer_type','REVENDA'/);
  assert.match(fallbackGuard, /'price_source','FISCAL_FALLBACK_BLOCKED'/);
  assert.match(fallbackGuard, /PRECO_FISCAL_INDISPONIVEL/);
  assert.match(fallbackGuard, /guard_unapproved_commercial_fiscal_price/);
  assert.match(regression, /'PR','PR',current_date,'CONSUMO'/);
  assert.match(regression, /PRECO_ROTA_EXCEL_NAO_PRIORIZADO/);
  assert.match(regression, /DOCUMENTO_NAO_PRESERVOU_PRECO_EXCEL_REVENDA/);
  assert.match(regression, /PRECO_ROTA_EXCEL_AUSENTE/);
  assert.match(regression, /FALLBACK_FISCAL_NAO_HOMOLOGADO/);
});

test('own ICMS stays informational and never composes the commercial price', () => {
  const migration = read('supabase/migrations/083_exclude_own_icms_from_commercial_price.sql');
  const taxRules = read('js/tax_rules.js');
  assert.match(migration, /coalesce\(v_ipi,0\)\+coalesce\(v_icms_st,0\)/);
  assert.match(migration, /'own_icms_included_in_total',false/);
  assert.match(migration, /fiscal_tax_rules_own_icms_not_in_price/);
  assert.match(taxRules, /ICMS próprio no preço/);
  assert.match(taxRules, /resale_include_own_icms: false/);
});

test('SP orders use imported PR stock for fulfillment when SP has no snapshot', () => {
  const store = read('js/supabase_store.js');
  const orders = read('js/orders.js');
  const migration = read('supabase/migrations/088_sp_orders_pr_fulfillment.sql');
  const regression = read('supabase/tests/067_safe_sp_pr_order_transfers_regression.sql');
  assert.match(store, /function getBranchTransferNotice/);
  assert.match(store, /Sem disponibilidade na Matriz PR para atender o pedido de SP/);
  assert.match(store, /sp_transfer_available_qty/);
  assert.match(store, /pr_transfer_available_qty/);
  assert.match(orders, /commercial-transfer-warning/);
  assert.match(orders, /commercial-transfer-summary/);
  assert.match(orders, /formatOrderTransferWarnings/);
  assert.match(read('js/products.js'), /product-picker-stock/);
  assert.match(migration, /PEDIDO_NAO_EH_SP_SP/);
  assert.match(migration, /ORDER_SP_SHORTAGE_PR_TRANSFER/);
  assert.match(migration, /ORDER_SP_PR_FULFILLMENT/);
  assert.match(migration, /source_stock\.available_qty/);
  assert.doesNotMatch(migration, /insert into public\.product_branch_stock/i);
  assert.match(regression, /TRANSFERENCIA_SP_PR_NAO_CRIADA/);
  assert.match(regression, /ATENDIMENTO_PR_SEM_SNAPSHOT_SP_NAO_CRIADO/);
});

test('commercial creation uses a focused shell and supports standalone mobile launch', () => {
  const app = read('js/app.js');
  const html = read('app.html');
  const css = read('css/app.css');
  assert.match(app, /function setCommercialFocusMode\(enabled\)/);
  assert.match(app, /setCommercialFocusMode\(false\)/);
  assert.match(app, /topbar\.hidden = active/);
  assert.match(app, /element\.hidden = active/);
  assert.match(app, /shell\.style\.display = active \? 'block' : ''/);
  assert.match(read('js/quotes.js'), /setCommercialFocusMode\(true\)/);
  assert.match(read('js/orders.js'), /setCommercialFocusMode\(true\)/);
  assert.match(css, /body\.commercial-focus-mode \.topbar/);
  assert.match(css, /body\.commercial-focus-mode \.mobile-nav/);
  assert.match(html, /apple-mobile-web-app-capable" content="yes"/);
  assert.match(html, /rel="manifest" href="manifest\.webmanifest/);
  assert.ok(JSON.parse(read('manifest.webmanifest')).display === 'standalone');
});

test('B2B portal isolates customers and exposes only scoped RPCs', () => {
  const identity = read('supabase/migrations/069_b2b_customer_identity_and_isolation.sql');
  const documents = read('supabase/migrations/070_b2b_catalog_and_documents.sql');
  const internalLink = read('supabase/migrations/071_link_internal_documents_to_b2b_clients.sql');
  const catalogFix = read('supabase/migrations/072_fix_b2b_catalog_variable_ambiguity.sql');
  const usernameAccess = read('supabase/migrations/073_b2b_username_password_access.sql');
  const catalogSearch = read('supabase/migrations/074_improve_b2b_catalog_search.sql');
  const catalogAlignment = read('supabase/migrations/075_align_b2b_search_with_catalog.sql');
  const catalogMetadata = read('supabase/migrations/076_yokomitsu_catalog_metadata.sql');
  const catalogMetadataServerAccess = read('supabase/migrations/077_allow_server_catalog_metadata_sync.sql');
  const clientDiscount = read('supabase/migrations/078_client_commercial_discount.sql');
  const hiddenB2BDiscount = read('supabase/migrations/079_hide_b2b_discount_and_improve_access_feedback.sql');
  const detailedCatalog = read('supabase/migrations/080_b2b_detailed_catalog_and_vehicle_snapshots.sql');
  const portal = read('b2b/js/app.js');
  const internalProducts = read('js/products.js');
  const admin = read('supabase/functions/b2b-admin/index.ts');
  assert.match(identity, /customer_portal_accounts/);
  assert.match(identity, /where a\.user_id = auth\.uid\(\)/);
  assert.match(identity, /create policy clients_read[\s\S]+public\.is_internal_user\(\)/);
  assert.match(identity, /create policy logs_insert[\s\S]+public\.is_internal_user\(\)/);
  assert.match(documents, /public\.b2b_search_catalog/);
  assert.match(documents, /public\.b2b_create_document/);
  assert.match(documents, /portal_idempotency_key/);
  assert.match(documents, /source_channel='B2B_PORTAL'/);
  assert.match(documents, /ESTOQUE_B2B_NAO_IMPORTADO/);
  assert.match(documents, /B2B_ORDER_SP_SHORTAGE_PR_TRANSFER/);
  assert.match(internalLink, /link_commercial_document_client/);
  assert.match(internalLink, /admin_review_b2b_profile_change/);
  assert.match(internalLink, /for update/);
  assert.match(internalLink, /APROVAR_ALTERACAO_CADASTRAL_B2B/);
  assert.match(catalogFix, /v_origin_code/);
  assert.doesNotMatch(catalogFix, /when origin_code=/);
  assert.match(usernameAccess, /login_mode in \('EMAIL','USERNAME'\)/);
  assert.match(usernameAccess, /complete_b2b_password_change/);
  assert.match(usernameAccess, /must_change_password/);
  assert.match(catalogSearch, /regexp_split_to_array/);
  assert.match(catalogSearch, /matched_terms/);
  assert.match(catalogSearch, /join public\.product_route_prices rp/);
  assert.match(catalogSearch, /application_terms\*25/);
  assert.doesNotMatch(catalogSearch, /limit least\(greatest\(limit_count,1\)\*5,250\)/);
  assert.match(catalogAlignment, /score\.matched_terms=cardinality\(v_tokens\)/);
  assert.match(catalogAlignment, /b2b_list_catalog_lines/);
  assert.match(catalogAlignment, /line_filter text/);
  assert.match(catalogMetadata, /create table if not exists public\.product_catalog_metadata/);
  assert.match(catalogMetadata, /sync_yokomitsu_catalog_metadata/);
  assert.match(catalogMetadata, /left join public\.product_catalog_metadata m/);
  assert.match(catalogMetadata, /m\.official_image_url/);
  assert.match(catalogMetadata, /revoke all on function public\.sync_yokomitsu_catalog_metadata/);
  assert.match(catalogMetadataServerAccess, /grant execute[\s\S]+to service_role/);
  assert.doesNotMatch(catalogMetadataServerAccess, /to authenticated/);
  assert.match(clientDiscount, /commercial_discount_percent numeric\(5,2\)/);
  assert.match(clientDiscount, /public\.max_discount_percent\(\)/);
  assert.match(clientDiscount, /APENAS_ADMIN_ALTERA_DESCONTO_CLIENTE/);
  assert.match(clientDiscount, /round\(rp\.final_price\*\(1-v_discount\/100\),4\)/);
  assert.match(clientDiscount, /price_row\.final_price,discount_percent,discounted_unit/);
  assert.match(clientDiscount, /desconto_total=round\(subtotal_value-total_value,2\)/);
  assert.match(portal, /get_b2b_session/);
  assert.match(portal, /b2b_search_catalog/);
  assert.match(portal, /b2b_list_catalog_lines/);
  assert.match(portal, /line_filter:/);
  assert.match(portal, /www\.yokomitsu\.com\.br\/uploads\/products/);
  assert.match(portal, /data-open-product-image/);
  assert.match(portal, /dialog\.showModal/);
  assert.doesNotMatch(portal, /commercial_discount_percent|% de desconto/);
  assert.doesNotMatch(hiddenB2BDiscount, /'commercial_discount_percent'/);
  assert.match(hiddenB2BDiscount, /create or replace function public\.get_b2b_session/);
  assert.match(detailedCatalog, /catalog_details jsonb/);
  assert.match(detailedCatalog, /public\.b2b_get_catalog_product_detail/);
  assert.match(detailedCatalog, /snapshot_b2b_item_application/);
  assert.match(detailedCatalog, /coalesce\(nullif\(m\.applications,''\),i\.aplicacao\)/);
  assert.match(read('js/partners.js'), /partnerClientDiscount/);
  assert.match(read('js/supabase_store.js'), /commercial_discount_percent/);
  assert.match(internalProducts, /getYokomitsuProductImage/);
  assert.match(internalProducts, /data-yokomitsu-image/);
  assert.match(portal, /b2b_create_document/);
  assert.match(portal, /b2b_get_catalog_product_detail/);
  assert.match(portal, /Veículo \/ ano/);
  assert.match(portal, /pendingSubmission/);
  assert.match(portal, /requestFingerprint/);
  assert.match(portal, /technicalLoginDomain/);
  assert.match(portal, /loginIdentifierToEmail/);
  assert.doesNotMatch(read('b2b/js/config.js') + portal, /service[_ -]?role|SUPABASE_SERVICE_ROLE_KEY/i);
  assert.match(admin, /SUPABASE_SERVICE_ROLE_KEY/);
  assert.match(admin, /caller\.perfil !== 'ADMIN'/);
  assert.match(admin, /inviteUserByEmail/);
  assert.match(admin, /create_credentials/);
  assert.match(admin, /technicalLoginEmail/);
  assert.match(read('js/supabase_store.js'), /readB2BFunctionError/);
  assert.match(read('js/partners.js'), /isValidB2BInitialPassword/);
  assert.doesNotMatch(admin, /dados_novos:\s*\{[^}]*\bpassword\s*:/i);
  assert.match(admin, /admin_review_b2b_profile_change/);
  assert.match(read('js/partners.js'), /data-b2b-client/);
  assert.match(read('js/partners.js'), /data-b2b-review/);
});

test('security hardening keeps secrets server-side and minimizes anonymous access', () => {
  const pages = ['index.html', 'app.html', 'b2b/index.html', 'cadastro-publico/index.html'];
  for (const file of pages) {
    const html = read(file);
    assert.match(html, /Content-Security-Policy/);
    assert.match(html, /supabase-js@2\.116\.0\/dist\/umd\/supabase\.js/);
    assert.match(html, /integrity="sha384-/);
    assert.doesNotMatch(html, /supabase-js@2["']/);
  }
  const publicFrontend = [
    ...filesIn('js', '.js'), ...filesIn('b2b/js', '.js'), ...filesIn('cadastro-publico/js', '.js')
  ].map(read).join('\n');
  assert.doesNotMatch(publicFrontend, /SUPABASE_SERVICE_ROLE_KEY|DATA_SYNC_SCHEDULER_SECRET|GRAPH_REFRESH_TOKEN/);
  assert.doesNotMatch(read('js/auth.js'), /sessionStorage\.setItem/);
  assert.match(read('js/auth.js'), /let inMemorySession = null/);

  const hardening = read('supabase/migrations/081_security_hardening.sql');
  assert.match(hardening, /revoke all privileges on all tables in schema public from public, anon/);
  assert.match(hardening, /grant execute on function public\.resolve_login_email\(text\) to anon/);
  assert.match(hardening, /complete_b2b_password_change_for_user/);
  assert.match(hardening, /consume_public_endpoint_rate_limit/);
  assert.match(hardening, /public\.is_internal_user\(\)/);

  const b2bPassword = read('supabase/functions/b2b-change-password/index.ts');
  assert.match(b2bPassword, /updateUserById/);
  assert.match(b2bPassword, /complete_b2b_password_change_for_user/);
  assert.match(b2bPassword, /length >= 12/);
  assert.doesNotMatch(read('b2b/js/app.js'), /rpc\('complete_b2b_password_change'/);

  const cadastro = read('supabase/functions/cadastro-cliente/index.ts');
  assert.match(cadastro, /sanitizeCadastroPayload/);
  assert.match(cadastro, /strictEmail/);
  assert.match(cadastro, /consumeRateLimit/);
  assert.match(cadastro, /content\.length \* 3 \/ 4/);
  assert.doesNotMatch(read('cadastro-publico/js/portal.js'), /\.from\('cadastros_clientes'\)/);
});

test('manual Excel parsing uses the patched, vendored SheetJS build', () => {
  const libraryPath = resolveFile('js/vendor/xlsx.full.min.js');
  const library = fs.readFileSync(libraryPath);
  const normalizedLibrary = library.toString('utf8').replace(/\r\n/g, '\n');
  const hash = crypto.createHash('sha256').update(normalizedLibrary, 'utf8').digest('hex');
  assert.match(library.toString('utf8'), /version="0\.20\.3"/);
  assert.equal(hash, 'cc015130aa8521e7f088f88898eba949ccdcbfb38df0bd129b44b7273c3a6f41');
  assert.match(read('app.html'), /xlsx\.full\.min\.js\?v=0\.20\.3/);
});

test('seller CRM is portfolio-scoped and keeps anonymous quotations separate from orders', () => {
  const migration = read('supabase/migrations/087_crm_seller_portfolio.sql');
  const app = read('js/app.js');
  const partners = read('js/partners.js');
  const quotes = read('js/quotes.js');
  const store = read('js/supabase_store.js');

  assert.match(migration, /assigned_seller_id uuid references public\.profiles/);
  assert.match(migration, /not public\.is_crm_seller\(\) or assigned_seller_id=auth\.uid\(\)/);
  assert.match(migration, /submit_client_registration_request/);
  assert.match(migration, /SEM_PERMISSAO_TRANSFERENCIAS/);
  assert.match(migration, /CLIENTE OBRIGATORIO PARA CONVERSAO|CLIENTE_OBRIGATORIO_PARA_CONVERSAO/);
  assert.match(app, /deniedRoles: \['VENDEDOR'\]/);
  assert.match(partners, /Solicitar cadastro/);
  assert.match(partners, /renderClientsTable\(rows, seller\)/);
  assert.match(quotes, /quoteAnonymousClient/);
  assert.match(store, /list_business_clients_scoped/);
  assert.match(store, /sellerSession \? Promise\.resolve\(\[\]\)/);
});

test('Excel synchronization rejects zero prices but preserves valid zero-tax routes', () => {
  const adapter = read('scripts/build_excel_sync_payload.py');
  const migration = read('supabase/migrations/089_reject_zero_commercial_prices.sql');
  const regression = read('supabase/tests/089_reject_zero_commercial_prices_regression.sql');
  assert.match(adapter, /route_base is None or route_base <= 0 or final is None or final <= 0/);
  assert.match(migration, /PRECO_NAO_POSITIVO:/);
  assert.match(migration, /base_price > 0 and final_price > 0/);
  assert.match(migration, /coalesce\(new\.preco_pr,0\) <= 0/);
  assert.match(regression, /TRIBUTO_ZERO_VALIDO_FOI_REJEITADO/);
});

test('SP commercial orders switch to base plus IPI on 2026-10-01 without mutating Excel prices', () => {
  const migration = read('supabase/migrations/090_sp_ipi_only_from_2026_10_01.sql');
  const regression = read('supabase/tests/090_sp_ipi_only_from_2026_10_01_regression.sql');
  assert.match(migration, /'SP_IPI_ONLY_2026_10_01','SP','SP','IPI_ONLY',date '2026-10-01'/);
  assert.match(migration, /'source_final_price',v_source->'final_price'/);
  assert.match(migration, /'final_price',round\(v_base,2\)\+round\(v_ipi,2\)/);
  assert.match(migration, /'icms_st_amount',0/);
  assert.match(migration, /calculate_product_price_crm_rules/);
  assert.match(migration, /'price_source','CRM_FISCAL_ENGINE_SP_IPI_ONLY'/);
  assert.match(migration, /'validation_source','EXCEL_ROUTE_PRICE'/);
  assert.match(migration, /normalize_document_tax_policy\('pedido'/);
  assert.match(migration, /b2b_create_document_raw_090/);
  assert.doesNotMatch(migration, /update public\.product_route_prices set/);
  assert.match(regression, /POLITICA_SP_ATIVADA_ANTES_DA_VIGENCIA/);
  assert.match(regression, /POLITICA_SP_ALTEROU_OUTRA_ROTA/);
  assert.match(regression, /PLANILHA_VIROU_DEPENDENCIA_OPERACIONAL/);
});

test('first OneDrive sync repairs only the legacy no-op footprint and keeps same-batch stock insertable', () => {
  const timestampRepair = read('supabase/migrations/091_repair_legacy_stock_timestamp_for_first_sync.sql');
  const insertConflictRepair = read('supabase/migrations/092_avoid_same_batch_stock_insert_conflicts.sql');
  assert.match(timestampRepair, /disable trigger product_branch_stock_touch_updated_at/);
  assert.match(timestampRepair, /s\.source_batch_id is null/);
  assert.match(timestampRepair, /s\.source_updated_at is null/);
  assert.match(timestampRepair, /s\.source_system is null/);
  assert.match(timestampRepair, /s\.version=1/);
  assert.match(timestampRepair, /s\.physical_qty=coalesce\(m\.audited_physical_qty,0\)/);
  assert.match(timestampRepair, /enable trigger product_branch_stock_touch_updated_at/);
  assert.match(insertConflictRepair, /new\.sync_batch_id is not null/);
  assert.match(insertConflictRepair, /s\.batch_id=new\.sync_batch_id/);
  assert.match(insertConflictRepair, /s\.sync_area='STOCK'/);
  assert.match(insertConflictRepair, /s\.branch_code=b\.code/);
  assert.match(insertConflictRepair, /s\.status<>'error'/);
});

test('PR-SP uses the versioned PR-SC route result without changing other routes', () => {
  const migration = read('supabase/migrations/093_pr_sp_uses_pr_sc_route.sql');
  const regression = read('supabase/tests/093_pr_sp_uses_pr_sc_route_regression.sql');
  assert.match(migration, /'PR_SP_EQUALS_PR_SC_2026_10_01','PR','SP','PR','SC'/);
  assert.match(migration, /get_product_commercial_price_raw_093/);
  assert.match(migration, /'route_alias_source_route',v_source_route/);
  assert.match(migration, /'price_source','CRM_ROUTE_ALIAS'/);
  assert.match(migration, /ROTA_PR_SP_USA_REGRA_PR_SC/);
  assert.match(regression, /PR_SP_DIVERGIU_DE_PR_SC/);
  assert.match(regression, /ALIAS_PR_SP_ALTEROU_OUTRA_ROTA/);
});

test('SP fiscal policy blocks prices that do not match the Excel reference', () => {
  const migration = read('supabase/migrations/094_block_sp_ipi_without_excel_match.sql');
  assert.match(migration, /validation_status/);
  assert.match(migration, /<>'MATCH'/);
  assert.match(migration, /PRECO_FISCAL_INDISPONIVEL/);
  assert.match(migration, /CRM_FISCAL_ENGINE_BLOCKED/);
  assert.match(migration, /VALIDACAO_FISCAL_PENDENTE/);
  assert.match(migration, /tax_policy_validation_blocked/);
});

test('OneDrive synchronization blocks workbooks with missing search formulas', () => {
  const audit = read('scripts/audit_excel_formula_contract.py');
  const runner = read('scripts/sync_onedrive_personal.py');
  assert.match(audit, /FORMULA_CRITICA_AUSENTE:Pesquisa Marcas!A10/);
  assert.match(audit, /FORMULAS_LISTA_AUSENTES/);
  assert.match(audit, /PORTAL ESTOQUE PR/);
  assert.match(runner, /FORMULAS_INVALIDAS:/);
});

test('one-time OneDrive formula repair is scoped and concurrency-safe', () => {
  const repair = read('scripts/repair_onedrive_search_formula.py');
  assert.match(repair, /SCOPES = "Files\.ReadWrite"/);
  assert.doesNotMatch(repair, /offline_access/);
  assert.match(repair, /"If-Match": str\(item\.get\("eTag"\)/);
  assert.match(repair, /Pesquisa Marcas/);
  assert.match(repair, /A10/);
  assert.match(repair, /INTERVALO_ESTOQUE_DESATUALIZADO/);
});

test('only ADMIN gets the product activity controls', () => {
  let profile = 'VENDEDOR';
  const context = vm.createContext({ getStoredSession: () => ({ perfil: profile }) });
  vm.runInContext(read('js/products.js'), context);
  assert.equal(context.renderProductActivityForm({ ativo: true }), '');
  profile = 'SUPERVISOR';
  assert.equal(context.renderProductActivityForm({ ativo: true }), '');
  profile = 'ADMIN';
  assert.match(context.renderProductActivityForm({ ativo: false }), /Item inativo/);
  assert.doesNotMatch(context.renderProductActivityForm({ ativo: false }), /\bchecked\b/);
  assert.match(context.renderProductActivityForm({ ativo: true }), /\bchecked\b/);
});

function commercialListHarness(responses) {
  const calls = [];
  const context = vm.createContext({ supabaseClient: { rpc: async (name, payload) => {
    calls.push({ name, payload });
    const response = responses.shift();
    if (!response) throw new Error('Unexpected RPC');
    if (response.data && !Object.hasOwn(response.data, 'catalog_revision')) response.data.catalog_revision = '1:2026-10-13';
    return response;
  } } });
  vm.runInContext(read('js/supabase_store.js'), context);
  return { context, calls };
}

test('commercial lists load every page and preserve line filters', async () => {
  const { context, calls } = commercialListHarness([
    { data: { count: 3, rows: [{ product_code: 'A' }, { product_code: 'B' }], has_more: true, next_offset: 2 } },
    { data: { count: 3, rows: [{ product_code: 'C' }], has_more: false, next_offset: 3 } }
  ]);
  const result = await context.supabaseGenerateCommercialList('PR-PR', { line: 'DIRECAO' });
  assert.equal(result.rows.length, 3);
  assert.equal(calls.length, 2);
  assert.equal(calls[0].payload.filters.line, 'DIRECAO');
  assert.equal(calls[1].payload.filters.offset, 2);
  assert.equal(calls[1].payload.filters.expected_revision, '1:2026-10-13');
  assert.equal(calls[0].payload.filters.limit, 200);
});

test('commercial list pages retain every selected line', async () => {
  const { context, calls } = commercialListHarness([
    { data: { count: 2, rows: [{ product_code: 'A' }], has_more: true, next_offset: 1 } },
    { data: { count: 2, rows: [{ product_code: 'B' }], has_more: false, next_offset: 2 } }
  ]);
  await context.supabaseGenerateCommercialList('PR-PR', { lines: ['FAROL', 'RETROVISOR'] });
  for (const call of calls) assert.deepEqual(Array.from(call.payload.filters.lines), ['FAROL', 'RETROVISOR']);
});

test('commercial line options have their own validated RPC, not the SAP product filters', async () => {
  const { context, calls } = commercialListHarness([{ data: { linhas: ['FAROL', 'LANTERNA', 'RETROVISOR'] } }]);
  assert.deepEqual(Array.from(await context.supabaseListCommercialLines()), ['FAROL', 'LANTERNA', 'RETROVISOR']);
  assert.equal(calls[0].name, 'get_commercial_list_lines');
  const invalid = commercialListHarness([{ data: { linhas: [123] } }]);
  await assert.rejects(() => invalid.context.supabaseListCommercialLines(), /Resposta invalida/);
});

test('invalid commercial line selections get friendly messages', async () => {
  for (const [message, expected] of [['EXCESSO_DE_LINHAS', /maximo 100/], ['LINHAS_INVALIDAS', /Selecao de linhas invalida/]]) {
    const { context } = commercialListHarness([{ error: { message } }]);
    await assert.rejects(() => context.supabaseGenerateCommercialList('PR-PR', { lines: [] }), expected);
  }
});

test('vehicle segments are carried in product search and all commercial pages', async () => {
  const { context, calls } = commercialListHarness([{ data: [] }]);
  await context.supabaseSearchProducts({ tipoVeiculo: 'UTILITARIO' });
  assert.equal(calls[0].payload.filters.vehicle_type, 'UTILITARIO');
  const commercial = commercialListHarness([
    { data: { count: 2, rows: [{ product_code: 'A' }], has_more: true, next_offset: 1 } },
    { data: { count: 2, rows: [{ product_code: 'B' }], has_more: false, next_offset: 2 } }
  ]);
  await commercial.context.supabaseGenerateCommercialList('PR-PR', { vehicle_type: 'PESADO' });
  for (const call of commercial.calls) assert.equal(call.payload.filters.vehicle_type, 'PESADO');
});

test('vehicle segment display supports mixed and unknown applications', () => {
  const context = vm.createContext({});
  vm.runInContext(read('js/utils/format.js'), context);
  assert.equal(context.formatVehicleTypes(['LEVE','UTILITARIO']), 'Leve / Utilitario');
  assert.equal(context.formatVehicleTypes(null), 'Nao classificado');
  assert.equal(context.formatVehicleTypes(['INVALIDO']), 'Nao classificado');
});

test('commercial list generation rejects partial, duplicated, oversized and changing results', async () => {
  const cases = [
    [{ data: { count: 2, rows: [{ product_code: 'A' }], has_more: false } }],
    [{ data: { count: 2, rows: [{ product_code: 'A' }, { product_code: 'A' }], has_more: false } }],
    [{ data: { count: 50001, rows: [], has_more: true } }],
    [{ data: { count: 2, rows: [{ product_code: 'A' }], has_more: true, next_offset: 1 } },
      { data: { count: 3, rows: [{ product_code: 'B' }], has_more: false } }],
    [{ data: { count: 2, rows: [], has_more: true, next_offset: 0 } }],
    [{ data: { count: 0, rows: [], has_more: false, catalog_revision: '' } }],
    [{ data: { count: 2, rows: [{ product_code: 'A' }], has_more: true, next_offset: 1, catalog_revision: '1:2026-10-13' } },
      { data: { count: 2, rows: [{ product_code: 'B' }], has_more: false, catalog_revision: '2:2026-10-13' } }],
    [{ error: { message: 'Falha RPC' } }]
  ];
  for (const responses of cases) {
    const { context } = commercialListHarness(responses);
    await assert.rejects(() => context.supabaseGenerateCommercialList('SP-SP'));
  }
});

test('product activity RPC carries optimistic state and invalidates static filters only after success', async () => {
  const { context, calls } = commercialListHarness([{ data: { codigo: 'TEST', ativo: false } }]);
  const cacheWrites = [];
  context.setStaticCache = (key, value) => cacheWrites.push({ key, value });
  const result = await context.supabaseSetProductActive('TEST', false, true);
  assert.equal(result.ativo, false);
  assert.equal(calls[0].name, 'set_product_active');
  assert.equal(calls[0].payload.expected_active, true);
  assert.equal(cacheWrites[0].key, 'productFiltersV4');
  assert.equal(cacheWrites[0].value, null);
});

test('product activity RPC exposes friendly permission/conflict errors and rejects malformed success', async () => {
  for (const response of [
    { error: { message: 'SOMENTE_ADMIN_ALTERA_ATIVIDADE_PRODUTO' } },
    { error: { message: 'PRODUTO_ALTERADO_POR_OUTRO_USUARIO' } },
    { data: { codigo: 'OTHER', ativo: false } }
  ]) {
    const { context } = commercialListHarness([response]);
    let invalidations = 0;
    context.setStaticCache = () => { invalidations += 1; };
    await assert.rejects(() => context.supabaseSetProductActive('TEST', false, true));
    assert.equal(invalidations, 0);
  }
});

test('activity migration protects administrative changes and filters before pagination', () => {
  const migration = read('supabase/migrations/105_product_activity_and_commercial_lists.sql');
  assert.match(migration, /ativo boolean not null default true/);
  assert.match(migration, /before insert or update on public.products/);
  assert.match(migration, /SOMENTE_ADMIN_ALTERA_ATIVIDADE_PRODUTO/);
  assert.match(migration, /ALTERAR_ATIVIDADE_PRODUTO/);
  assert.match(migration, /as restrictive/);
  assert.match(migration, /from enriched e.*e\.ativo/s);
  assert.match(migration, /where p\.ativo/);
  assert.match(migration, /v_patch\.signature='public\.get_top_selling_products\(integer\)'/);
  assert.match(migration, /oi\[\.\]codigo\[\[:space:\]\]\+group by/);
  assert.match(migration, /v_old is null/);
  assert.match(migration, /offset v_offset limit v_limit/);
  assert.doesNotMatch(migration, /grant execute.* to anon/);
  assert.doesNotMatch(migration, /^\s*delete from public\.(products|order_items|quotation_items)\b/m);
});
