const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
function filesIn(directory, extension) {
  return fs.readdirSync(path.join(root, directory), { withFileTypes: true }).flatMap((entry) => {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) return entry.name === 'vendor' ? [] : filesIn(file, extension);
    return file.endsWith(extension) ? [file] : [];
  });
}
const htmlFiles = ['index.html', 'app.html', ...filesIn('tests', '.html'), ...filesIn('cadastro-publico', '.html'), ...filesIn('b2b', '.html')];

test('application and public registration JavaScript parses without execution', () => {
  for (const file of [...filesIn('js', '.js'), ...filesIn('cadastro-publico/js', '.js'), ...filesIn('b2b/js', '.js')]) {
    assert.doesNotThrow(() => new vm.Script(read(file), { filename: file }), file);
  }
});

test('all HTML inline scripts parse without execution', () => {
  for (const file of htmlFiles) {
    const blocks = read(file).matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi);
    for (const [block, attributes, source] of blocks) {
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
      const target = path.resolve(root, path.dirname(file), reference.split(/[?#]/)[0]);
      assert.ok(fs.existsSync(target), `${file}: ${reference}`);
    }
  }
});

test('administrative templates preserve critical control IDs', () => {
  const contracts = {
    'js/users.js': ['userForm', 'userId', 'newUserProfile', 'newUserPassword', 'newUserActive', 'logsFilter', 'logsUser', 'logsAction'],
    'js/cadastros.js': ['cadastroSearch', 'cadastroStatusFilter', 'portalEmailPrincipal', 'portalReportFrom', 'portalReportTo'],
    'js/company_settings.js': ['companySettingsForm', 'companyName', 'companyState', 'companyTimezone', 'companyLanguage'],
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
  assert.doesNotMatch(sync + store, /service[_ -]?role|DATA_SYNC_ADAPTER_TOKEN/i);
  assert.match(read('js/imports.js'), /function renderImportCenter/);
  const smoke = read('tests/ui-data-sync-smoke.html');
  assert.doesNotMatch(smoke, /<script[^>]+src=["'][^"']*(?:supabase|auth|store)/i);
  assert.doesNotMatch(smoke, /\b(?:fetch|XMLHttpRequest|createClient)\s*\(/);
});

test('personal OneDrive runner is server-only, chunked and least-privileged', () => {
  const workflow = read('.github/workflows/excel-sync.yml');
  const runner = read('scripts/sync_onedrive_personal.py');
  const edge = read('supabase/functions/excel-sync/index.ts');
  assert.match(workflow, /permissions:\s*\n\s*contents: read/);
  assert.match(workflow, /workflow_dispatch:/);
  assert.doesNotMatch(workflow, /pull_request:/);
  assert.doesNotMatch(workflow, /SUPABASE_SERVICE_ROLE_KEY/);
  assert.match(workflow, /vars\.DATA_SYNC_ENABLED == 'true'/);
  assert.match(runner, /offline_access Files\.Read/);
  assert.doesNotMatch(runner, /Files\.ReadWrite/);
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
  const regression = read('supabase/tests/066_excel_route_price_priority_regression.sql');
  assert.match(store, /customerType = 'REVENDA'/);
  assert.match(store, /customerType \|\| 'REVENDA'/);
  assert.match(migration, /from public\.product_route_prices/);
  assert.match(migration, /'price_source','EXCEL_ROUTE_PRICE'/);
  assert.match(migration, /'price_source','SUPABASE_FISCAL_FALLBACK'/);
  assert.match(migration, /'customer_type','REVENDA'/);
  assert.match(regression, /'PR','PR',current_date,'CONSUMO'/);
  assert.match(regression, /PRECO_ROTA_EXCEL_NAO_PRIORIZADO/);
  assert.match(regression, /DOCUMENTO_NAO_PRESERVOU_PRECO_EXCEL_REVENDA/);
  assert.match(regression, /PRECO_ROTA_EXCEL_AUSENTE/);
});

test('SP orders warn and create safe PR transfer requests without inventing stock zero', () => {
  const store = read('js/supabase_store.js');
  const orders = read('js/orders.js');
  const migration = read('supabase/migrations/067_safe_sp_pr_order_transfers.sql');
  const regression = read('supabase/tests/067_safe_sp_pr_order_transfers_regression.sql');
  assert.match(store, /function getBranchTransferNotice/);
  assert.match(store, /ESTOQUE_SP_NAO_IMPORTADO/);
  assert.match(store, /sp_transfer_available_qty/);
  assert.match(store, /pr_transfer_available_qty/);
  assert.match(orders, /commercial-transfer-warning/);
  assert.match(orders, /commercial-transfer-summary/);
  assert.match(orders, /formatOrderTransferWarnings/);
  assert.match(read('js/products.js'), /product-picker-stock/);
  assert.match(migration, /PEDIDO_NAO_EH_SP_SP/);
  assert.match(migration, /ORDER_SP_SHORTAGE_PR_TRANSFER/);
  assert.match(migration, /source_stock\.available_qty/);
  assert.doesNotMatch(migration, /insert into public\.product_branch_stock/i);
  assert.match(regression, /TRANSFERENCIA_SP_PR_NAO_CRIADA/);
  assert.match(regression, /SNAPSHOT_SP_AUSENTE_FOI_TRATADO_COMO_ZERO/);
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
  const portal = read('b2b/js/app.js');
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
  assert.match(portal, /get_b2b_session/);
  assert.match(portal, /b2b_search_catalog/);
  assert.match(portal, /b2b_create_document/);
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
  assert.doesNotMatch(admin, /dados_novos:\s*\{[^}]*\bpassword\s*:/i);
  assert.match(admin, /admin_review_b2b_profile_change/);
  assert.match(read('js/partners.js'), /data-b2b-client/);
  assert.match(read('js/partners.js'), /data-b2b-review/);
});
