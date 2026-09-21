const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');

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
  assert.match(store, /refreshDataSyncSession/);
  assert.match(store, /supabaseDataSyncRpc\('list_data_sync_batches'/);
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
  const regression = read('supabase/tests/082_current_crm_product_search_regression.sql');
  assert.match(store, /rpc\('search_products_v2'/);
  assert.match(store, /favorite_codes: favoriteCodes/);
  assert.doesNotMatch(store.slice(store.indexOf('async function supabaseSearchProducts'), store.indexOf('async function enrichProductsWithBranchAvailability')), /return supabaseListProducts/);
  assert.match(products, /limite: options\.listaGeral \? 200 : 120/);
  assert.match(products, /productSearchRequests\.get\(target\) !== requestId/);
  assert.match(migration, /product_branch_stock/);
  assert.match(migration, /product_branch_prices/);
  assert.match(migration, /product_catalog_metadata/);
  assert.match(migration, /not exists \(\s*select 1 from unnest\(v_tokens\)/);
  assert.match(migration, /sp_source_display_value/);
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
  const libraryPath = path.join(root, 'js/vendor/xlsx.full.min.js');
  const library = fs.readFileSync(libraryPath);
  const hash = crypto.createHash('sha256').update(library).digest('hex');
  assert.match(library.toString('utf8'), /version="0\.20\.3"/);
  assert.equal(hash, 'cc015130aa8521e7f088f88898eba949ccdcbfb38df0bd129b44b7273c3a6f41');
  assert.match(read('app.html'), /xlsx\.full\.min\.js\?v=0\.20\.3/);
});
