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
const htmlFiles = ['index.html', 'app.html', ...filesIn('tests', '.html'), ...filesIn('cadastro-publico', '.html')];

test('application and public registration JavaScript parses without execution', () => {
  for (const file of [...filesIn('js', '.js'), ...filesIn('cadastro-publico/js', '.js')]) {
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
