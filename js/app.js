const MODULES = {
  dashboard: { title: 'Início', section: 'Comercial', domain: 'dashboard', permission: 'dashboard', render: renderDashboard },
  products: { title: 'Produtos', section: 'Catálogo', domain: 'products', permission: 'produtos', render: renderProducts },
  ordersReport: { title: 'Pedidos', section: 'Comercial', domain: 'orders', permission: ['pedidos', 'novo_pedido'], render: renderOrdersReport },
  stockTransfers: { title: 'Transferências', section: 'Operação', domain: 'orders', permission: 'pedidos', render: renderStockTransfers },
  quoteReports: { title: 'Cotações', section: 'Comercial', domain: 'quotes', permission: ['cotacoes', 'nova_cotacao'], render: renderQuotationsReport },
  partners: { title: 'Parceiros de negócios', section: 'Comercial', domain: 'customers', permission: 'parceiros', render: renderBusinessPartners },
  sap: { title: 'Importações', section: 'Operação', domain: 'imports', permission: ['alimentacao', 'importar_estoque_preco'], render: renderImportCenter },
  cadastros: { title: 'Cadastros', section: 'Operação', domain: 'customers', permission: 'cadastros', render: renderCadastrosClientes },
  portalCadastros: { title: 'Portal de clientes', section: 'Operação', domain: 'customers', permission: 'usuarios', adminOnly: true, render: renderPortalCadastrosControle },
  companySettings: { title: 'Configurações da empresa', section: 'Sistema', domain: 'settings', permission: ['configuracoes_empresa', 'configuracoes'], adminOnly: true, render: renderCompanySettings },
  taxRules: { title: 'Fiscal', section: 'Sistema', domain: 'settings', permission: ['configuracoes_empresa', 'configuracoes'], adminOnly: true, render: renderFiscalTaxRules },
  users: { title: 'Usuários', section: 'Gestão', domain: 'users', permission: 'usuarios', render: renderUsers },
  logs: { title: 'Logs', section: 'Gestão', domain: 'reports', permission: 'logs', render: renderLogs }
};

const SIDEBAR_PREFERENCE_KEY = 'crm.sidebar.collapsed.v1';

const MODULE_ALIASES = {
  customers: { module: 'partners' },
  imports: { module: 'sap' },
  orders: { module: 'ordersReport' },
  transfers: { module: 'stockTransfers' },
  quotes: { module: 'quoteReports' },
  quoteCreate: { module: 'quoteReports', action: 'create' },
  reports: { module: 'quoteReports' },
  settings: { module: 'companySettings' },
  impostos: { module: 'taxRules' },
  fiscal: { module: 'taxRules' }
};

let currentSession = null;

document.addEventListener('DOMContentLoaded', async () => {
  currentSession = getStoredSession();
  if (!currentSession || !getSessionId()) {
    window.location.href = 'index.html';
    return;
  }

  validateCurrentSession()
    .then((session) => {
      if (!session) throw new Error('Sessao expirada.');
      currentSession = session;
      bootstrapAppShell();
    })
    .catch(() => {
      clearStoredSession();
      window.location.href = 'index.html';
    });
});

function bootstrapAppShell() {
  applySessionToShell();
  setupSidebarCollapse();
  document.getElementById('logoutButton').addEventListener('click', logoutCurrentUser);
  document.getElementById('menuButton').addEventListener('click', () => {
    toggleMobileMenu();
  });
  const sidebarBackdrop = document.getElementById('sidebarBackdrop');
  if (sidebarBackdrop) {
    sidebarBackdrop.addEventListener('click', () => toggleMobileMenu(false));
  }
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') toggleMobileMenu(false);
  });
  window.addEventListener('hashchange', () => {
    const requested = location.hash.replace('#', '') || 'dashboard';
    const route = getModuleRoute(requested);
    if (MODULES[route.module]) openModule(requested);
  });

  setupNavigation();
  setupMobileNavigation();
  CrmUi.observeResponsiveTables(document.getElementById('content'));
  const initialHash = location.hash.replace('#', '') || 'dashboard';
  const initial = getModuleRoute(initialHash);
  openModule(MODULES[initial.module] ? initialHash : 'dashboard');
}

function applySessionToShell() {
  document.getElementById('userName').textContent = currentSession.nome || currentSession.usuario || 'Usuario';
  const role = document.getElementById('userRole');
  if (role) role.textContent = String(currentSession.perfil || 'Usuário').toUpperCase();
  loadCompanySettings().catch((error) => console.warn(error));
}

function setupNavigation() {
  applyNavigationVisibility();
  document.querySelectorAll('.nav-item').forEach((button) => {
    button.addEventListener('click', () => openModule(button.dataset.module));
  });
}

function setupMobileNavigation() {
  document.querySelectorAll('[data-mobile-module]').forEach((button) => {
    button.addEventListener('click', () => openModule(button.dataset.mobileModule));
  });
  applyMobileNavigationVisibility();
}

function applyNavigationVisibility() {
  const allowed = getCurrentSessionModules();
  document.querySelectorAll('.nav-item').forEach((button) => {
    const module = MODULES[button.dataset.module];
    const blockedByPermission = !!(module && !hasModuleAccess(module, allowed));
    const blockedByAdmin = !!(module && module.adminOnly && !isCurrentUserAdmin());
    button.hidden = blockedByPermission || blockedByAdmin;
  });
  document.querySelectorAll('[data-nav-group]').forEach((group) => {
    group.hidden = !Array.from(group.querySelectorAll('.nav-item')).some((button) => !button.hidden);
  });
  applyMobileNavigationVisibility();
}

function setupSidebarCollapse() {
  const button = document.getElementById('sidebarCollapseButton');
  if (!button) return;
  let collapsed = false;
  try {
    collapsed = localStorage.getItem(SIDEBAR_PREFERENCE_KEY) === 'true';
  } catch (error) {
    console.warn('Preferência do menu não pôde ser restaurada.', error);
  }
  setSidebarCollapsed(collapsed);
  button.addEventListener('click', () => setSidebarCollapsed(!document.body.classList.contains('sidebar-collapsed'), true));
}

function setSidebarCollapsed(collapsed, persist = false) {
  document.body.classList.toggle('sidebar-collapsed', collapsed);
  const button = document.getElementById('sidebarCollapseButton');
  if (button) {
    button.setAttribute('aria-pressed', String(collapsed));
    button.setAttribute('aria-label', collapsed ? 'Expandir menu' : 'Recolher menu');
    const label = button.querySelector('.sidebar-collapse-label');
    const icon = button.querySelector('.sidebar-collapse-icon');
    if (label) label.textContent = collapsed ? 'Expandir menu' : 'Recolher menu';
    if (icon) icon.textContent = collapsed ? '›' : '‹';
  }
  if (!persist) return;
  try {
    localStorage.setItem(SIDEBAR_PREFERENCE_KEY, String(collapsed));
  } catch (error) {
    console.warn('Preferência do menu não pôde ser salva.', error);
  }
}

function applyMobileNavigationVisibility() {
  const allowed = getCurrentSessionModules();
  document.querySelectorAll('[data-mobile-module]').forEach((button) => {
    const module = MODULES[button.dataset.mobileModule];
    const blockedByPermission = !!(module && !hasModuleAccess(module, allowed));
    const blockedByAdmin = !!(module && module.adminOnly && !isCurrentUserAdmin());
    button.hidden = blockedByPermission || blockedByAdmin;
  });
}

function toggleMobileMenu(force) {
  const sidebar = document.getElementById('sidebar');
  const next = typeof force === 'boolean' ? force : !sidebar.classList.contains('is-open');
  sidebar.classList.toggle('is-open', next);
  document.body.classList.toggle('menu-open', next);
}

async function openModule(name) {
  const route = getModuleRoute(name);
  const moduleName = route.module;
  const module = MODULES[moduleName] || MODULES.dashboard;
  const allowed = getCurrentSessionModules();
  const content = document.getElementById('content');
  toggleMobileMenu(false);

  if (module.adminOnly && !isCurrentUserAdmin()) {
    content.innerHTML = CrmUi.renderState('error', 'Acesso não permitido', 'Seu perfil não possui permissão para acessar este módulo.');
    content.focus();
    return;
  }

  if (!hasModuleAccess(module, allowed)) {
    content.innerHTML = CrmUi.renderState('error', 'Acesso não permitido', 'Seu perfil não possui permissão para acessar este módulo.');
    content.focus();
    return;
  }

  document.querySelectorAll('.nav-item').forEach((item) => {
    const active = item.dataset.module === moduleName;
    item.classList.toggle('is-active', active);
    if (active) item.setAttribute('aria-current', 'page');
    else item.removeAttribute('aria-current');
  });
  document.querySelectorAll('[data-mobile-module]').forEach((item) => item.classList.toggle('is-active', item.dataset.mobileModule === moduleName));
  document.getElementById('pageTitle').textContent = module.title;
  const context = document.getElementById('pageContext');
  if (context) context.textContent = module.section || 'CRM Comercial';
  if (location.hash !== `#${moduleName}`) {
    history.replaceState(null, '', `#${moduleName}`);
  }

  try {
    await module.render(content, { action: route.action });
    CrmUi.enhanceResponsiveTables(content);
  } catch (error) {
    console.error(`Falha ao carregar o módulo ${moduleName}.`, error);
    content.innerHTML = CrmUi.renderState('error', 'Não foi possível carregar esta área', error.message || 'Tente novamente em instantes.');
  }
  content.focus();
}

async function logoutCurrentUser() {
  try {
    await supabaseLogout();
  } catch (error) {
    console.warn(error);
  } finally {
    clearStoredSession();
    window.location.href = 'index.html';
  }
}

function isCurrentUserAdmin() {
  return String(currentSession && currentSession.perfil || '').toUpperCase() === 'ADMIN';
}

function hasModuleAccess(module, allowed) {
  if (isCurrentUserAdmin()) return true;
  if (!allowed.length) return false;
  const permissions = Array.isArray(module.permission) ? module.permission : [module.permission];
  return permissions.some((permission) => allowed.includes(permission));
}

function getCurrentSessionModules() {
  return Array.isArray(currentSession && currentSession.modules) ? currentSession.modules : [];
}

function getModuleRoute(name) {
  const alias = MODULE_ALIASES[name];
  if (!alias) return { module: name };
  if (typeof alias === 'string') return { module: alias };
  return alias;
}
