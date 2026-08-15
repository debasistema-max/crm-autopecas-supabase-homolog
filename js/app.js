const MODULES = {
  dashboard: { title: 'Inicio', domain: 'dashboard', permission: 'dashboard', render: renderDashboard },
  products: { title: 'Produtos', domain: 'products', permission: 'produtos', render: renderProducts },
  ordersReport: { title: 'Pedidos', domain: 'orders', permission: ['pedidos', 'novo_pedido'], render: renderOrdersReport },
  quoteReports: { title: 'Cotacoes', domain: 'quotes', permission: ['cotacoes', 'nova_cotacao'], render: renderQuotationsReport },
  partners: { title: 'Parceiros de Negocios', domain: 'customers', permission: 'parceiros', render: renderBusinessPartners },
  sap: { title: 'Importacao SAP', domain: 'imports', permission: 'alimentacao', render: renderSapImport },
  cadastros: { title: 'Cadastros', domain: 'customers', permission: 'cadastros', render: renderCadastrosClientes },
  portalCadastros: { title: 'Portal Clientes', domain: 'customers', permission: 'usuarios', adminOnly: true, render: renderPortalCadastrosControle },
  companySettings: { title: 'Configuracoes da Empresa', domain: 'settings', permission: ['configuracoes_empresa', 'configuracoes'], adminOnly: true, render: renderCompanySettings },
  users: { title: 'Usuarios', domain: 'users', permission: 'usuarios', render: renderUsers },
  logs: { title: 'Logs', domain: 'reports', permission: 'logs', render: renderLogs }
};

const MODULE_ALIASES = {
  customers: { module: 'partners' },
  imports: { module: 'sap' },
  orders: { module: 'ordersReport' },
  quotes: { module: 'quoteReports' },
  quoteCreate: { module: 'quoteReports', action: 'create' },
  reports: { module: 'quoteReports' },
  settings: { module: 'companySettings' }
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
  const initialHash = location.hash.replace('#', '') || 'dashboard';
  const initial = getModuleRoute(initialHash);
  openModule(MODULES[initial.module] ? initialHash : 'dashboard');
}

function applySessionToShell() {
  document.getElementById('userName').textContent = currentSession.nome || currentSession.usuario || 'Usuario';
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
  applyMobileNavigationVisibility();
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
    content.innerHTML = '<div class="empty-state">Voce nao tem permissao para acessar este modulo.</div>';
    content.focus();
    return;
  }

  if (!hasModuleAccess(module, allowed)) {
    content.innerHTML = '<div class="empty-state">Voce nao tem permissao para acessar este modulo.</div>';
    content.focus();
    return;
  }

  document.querySelectorAll('.nav-item').forEach((item) => item.classList.toggle('is-active', item.dataset.module === moduleName));
  document.querySelectorAll('[data-mobile-module]').forEach((item) => item.classList.toggle('is-active', item.dataset.mobileModule === moduleName));
  document.getElementById('pageTitle').textContent = module.title;
  if (location.hash !== `#${moduleName}`) {
    history.replaceState(null, '', `#${moduleName}`);
  }

  await module.render(content, { action: route.action });
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
