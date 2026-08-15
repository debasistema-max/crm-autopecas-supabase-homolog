const DEFAULT_COMPANY_SETTINGS = {
  company_name: 'Nova Empresa',
  trade_name: '',
  cnpj: '',
  address: '',
  city: '',
  state: '',
  zip_code: '',
  phone: '',
  whatsapp: '',
  email: '',
  website: '',
  logo_url: 'assets/logo-neutral.svg',
  primary_color: '#0d6b5f',
  secondary_color: '#17212b',
  currency: 'BRL',
  timezone: 'America/Sao_Paulo',
  language: 'pt-BR'
};

let cachedCompanySettings = null;
let cachedFullCompanySettings = null;

async function loadCompanySettings() {
  if (cachedCompanySettings) return cachedCompanySettings;
  const settings = await fetchCompanySettings();
  cachedCompanySettings = settings;
  applyCompanyIdentity(settings);
  return settings;
}

async function fetchCompanySettings() {
  if (!isSupabaseReady()) return Object.assign({}, DEFAULT_COMPANY_SETTINGS);
  const { data, error } = await supabaseClient.rpc('get_public_company_identity');
  if (error) {
    console.warn('Company settings unavailable.', error);
    return Object.assign({}, DEFAULT_COMPANY_SETTINGS);
  }
  return normalizeCompanySettings(data || {});
}

async function fetchFullCompanySettings() {
  if (!isSupabaseReady()) return Object.assign({}, DEFAULT_COMPANY_SETTINGS);
  const { data, error } = await supabaseClient
    .from('company_settings')
    .select('company_name, trade_name, cnpj, address, city, state, zip_code, phone, whatsapp, email, website, logo_url, primary_color, secondary_color, currency, timezone, language, created_at, updated_at')
    .eq('id', true)
    .maybeSingle();
  if (error) throw error;
  return normalizeCompanySettings(data || {});
}

function normalizeCompanySettings(settings = {}) {
  return Object.assign({}, DEFAULT_COMPANY_SETTINGS, settings, {
    company_name: String(settings.company_name || DEFAULT_COMPANY_SETTINGS.company_name).trim(),
    logo_url: String(settings.logo_url || DEFAULT_COMPANY_SETTINGS.logo_url).trim(),
    primary_color: normalizeHexColor(settings.primary_color, DEFAULT_COMPANY_SETTINGS.primary_color),
    secondary_color: normalizeHexColor(settings.secondary_color, DEFAULT_COMPANY_SETTINGS.secondary_color),
    currency: String(settings.currency || DEFAULT_COMPANY_SETTINGS.currency).trim().toUpperCase(),
    timezone: String(settings.timezone || DEFAULT_COMPANY_SETTINGS.timezone).trim(),
    language: String(settings.language || DEFAULT_COMPANY_SETTINGS.language).trim()
  });
}

function normalizeHexColor(value, fallback) {
  const color = String(value || '').trim();
  return /^#[0-9A-Fa-f]{6}$/.test(color) ? color : fallback;
}

function applyCompanyIdentity(settings = DEFAULT_COMPANY_SETTINGS) {
  const identity = normalizeCompanySettings(settings);
  const displayName = getCompanyDisplayName(identity);
  document.documentElement.style.setProperty('--primary', identity.primary_color);
  document.documentElement.style.setProperty('--primary-strong', identity.secondary_color);
  document.documentElement.lang = identity.language || 'pt-BR';
  document.title = document.body && document.body.classList.contains('login-page')
    ? `${displayName} | Login`
    : `${displayName} | CRM`;

  document.querySelectorAll('[data-company-name]').forEach((node) => {
    node.textContent = displayName;
  });
  document.querySelectorAll('[data-company-legal-name]').forEach((node) => {
    node.textContent = identity.company_name;
  });
  document.querySelectorAll('[data-company-logo]').forEach((node) => {
    applyCompanyLogo(node, identity.logo_url, displayName);
  });
  document.querySelectorAll('[data-company-logo-watermark]').forEach((node) => {
    applyCompanyLogo(node, identity.logo_url, displayName);
  });
  document.querySelectorAll('[data-company-kicker]').forEach((node) => {
    node.textContent = displayName;
  });
}

async function supabaseGetCompanySettings() {
  if (cachedFullCompanySettings) return cachedFullCompanySettings;
  try {
    cachedFullCompanySettings = await fetchFullCompanySettings();
    cachedCompanySettings = cachedFullCompanySettings;
    applyCompanyIdentity(cachedFullCompanySettings);
    return cachedFullCompanySettings;
  } catch (error) {
    console.warn('Full company settings unavailable.', error);
    return loadCompanySettings();
  }
}

function applyCompanyLogo(node, logoUrl, displayName) {
  const fallback = DEFAULT_COMPANY_SETTINGS.logo_url;
  node.onerror = () => {
    if (node.dataset.logoFallbackApplied === 'true') return;
    node.dataset.logoFallbackApplied = 'true';
    node.src = fallback;
  };
  node.dataset.logoFallbackApplied = 'false';
  node.src = logoUrl || fallback;
  node.alt = displayName || DEFAULT_COMPANY_SETTINGS.company_name;
}

function getCompanyDisplayName(settings = DEFAULT_COMPANY_SETTINGS) {
  return settings.trade_name || settings.company_name || DEFAULT_COMPANY_SETTINGS.company_name;
}

function formatCompanyLocation(settings = DEFAULT_COMPANY_SETTINGS) {
  return [settings.city, settings.state].filter(Boolean).join('/');
}

function formatCompanyAddress(settings = DEFAULT_COMPANY_SETTINGS) {
  return [
    settings.address,
    formatCompanyLocation(settings),
    settings.zip_code ? 'CEP ' + settings.zip_code : ''
  ].filter(Boolean).join(' - ');
}

function formatCompanyBranchLabel(settings = DEFAULT_COMPANY_SETTINGS) {
  const name = getCompanyDisplayName(settings);
  const location = formatCompanyLocation(settings);
  return [name, location].filter(Boolean).join(' - ') || DEFAULT_COMPANY_SETTINGS.company_name;
}

function renderCompanyInstitutionalSummary(settings = DEFAULT_COMPANY_SETTINGS) {
  return [
    getCompanyDisplayName(settings),
    settings.company_name && settings.company_name !== getCompanyDisplayName(settings) ? settings.company_name : '',
    settings.cnpj ? 'CNPJ ' + settings.cnpj : '',
    formatCompanyAddress(settings),
    settings.phone ? 'Tel. ' + settings.phone : '',
    settings.whatsapp ? 'WhatsApp ' + settings.whatsapp : '',
    settings.email || '',
    settings.website || ''
  ].filter(Boolean).join(' | ');
}

async function supabaseSaveCompanySettings(payload = {}) {
  const settings = normalizeCompanySettings(payload);
  const normalizedState = stringOrNull(settings.state);
  const record = {
    id: true,
    company_name: settings.company_name,
    trade_name: stringOrNull(settings.trade_name),
    cnpj: onlyDigits(settings.cnpj) || null,
    address: stringOrNull(settings.address),
    city: stringOrNull(settings.city),
    state: normalizedState ? normalizedState.toUpperCase() : null,
    zip_code: onlyDigits(settings.zip_code) || null,
    phone: stringOrNull(settings.phone),
    whatsapp: stringOrNull(settings.whatsapp),
    email: stringOrNull(settings.email),
    website: stringOrNull(settings.website),
    logo_url: stringOrNull(payload.logo_url),
    primary_color: settings.primary_color,
    secondary_color: settings.secondary_color,
    currency: settings.currency,
    timezone: settings.timezone,
    language: settings.language
  };
  if (!record.company_name) throw new Error('Informe o nome da empresa.');
  if (record.email && !isValidEmail(record.email)) throw new Error('Informe um email valido.');
  const { data, error } = await supabaseClient
    .from('company_settings')
    .upsert(record, { onConflict: 'id' })
    .select('company_name, trade_name, cnpj, address, city, state, zip_code, phone, whatsapp, email, website, logo_url, primary_color, secondary_color, currency, timezone, language, created_at, updated_at')
    .single();
  if (error) throw error;
  cachedCompanySettings = normalizeCompanySettings(data || record);
  cachedFullCompanySettings = cachedCompanySettings;
  applyCompanyIdentity(cachedCompanySettings);
  if (typeof supabaseLog === 'function') {
    await supabaseLog('ATUALIZAR_CONFIG_EMPRESA', 'company_settings', 'singleton', Object.assign({}, cachedCompanySettings, { cnpj: record.cnpj }));
  }
  return cachedCompanySettings;
}

function stringOrNull(value) {
  const text = String(value || '').trim();
  return text || null;
}

async function renderCompanySettings(container) {
  container.innerHTML = '<div class="empty-state">Carregando configuracoes da empresa...</div>';
  try {
    const settings = await supabaseGetCompanySettings();
    container.innerHTML = `
      <section class="panel">
        <div class="panel-header">
          <div><h2>Configuracoes da Empresa</h2><p>Identidade institucional usada pelo CRM.</p></div>
        </div>
        <form id="companySettingsForm" class="field-grid">
          <label class="span-4">Nome da empresa<input id="companyName" required></label>
          <label class="span-4">Nome fantasia<input id="companyTradeName"></label>
          <label class="span-4">CNPJ<input id="companyCnpj" inputmode="numeric"></label>
          <label class="span-6">Endereco<input id="companyAddress"></label>
          <label class="span-3">Cidade<input id="companyCity"></label>
          <label class="span-1">UF<input id="companyState" maxlength="2"></label>
          <label class="span-2">CEP<input id="companyZipCode" inputmode="numeric"></label>
          <label class="span-3">Telefone<input id="companyPhone"></label>
          <label class="span-3">WhatsApp<input id="companyWhatsapp"></label>
          <label class="span-3">E-mail<input id="companyEmail" type="email"></label>
          <label class="span-3">Site<input id="companyWebsite" type="url"></label>
          <label class="span-6">Logotipo URL<input id="companyLogoUrl"></label>
          <label class="span-2">Cor principal<input id="companyPrimaryColor" type="color"></label>
          <label class="span-2">Cor secundaria<input id="companySecondaryColor" type="color"></label>
          <label class="span-2">Moeda<input id="companyCurrency" maxlength="3"></label>
          <label class="span-3">Timezone<input id="companyTimezone"></label>
          <label class="span-3">Idioma<input id="companyLanguage"></label>
          <div class="span-12 company-settings-preview">
            <img data-company-logo src="${escapeHtml(settings.logo_url)}" alt="">
            <div>
              <strong data-company-name>${escapeHtml(settings.trade_name || settings.company_name)}</strong>
              <span data-company-legal-name>${escapeHtml(settings.company_name)}</span>
              <small>Criado em ${escapeHtml(formatCompanySettingsDate(settings.created_at))} - Atualizado em ${escapeHtml(formatCompanySettingsDate(settings.updated_at))}</small>
            </div>
          </div>
          <div class="span-12 actions-row">
            <button class="btn btn-primary" type="submit">Salvar configuracoes</button>
            <p id="companySettingsMessage" class="form-message"></p>
          </div>
        </form>
      </section>
    `;
    fillCompanySettingsForm(settings);
    document.getElementById('companySettingsForm').addEventListener('submit', saveCompanySettingsFromForm);
  } catch (error) {
    container.innerHTML = `<div class="empty-state">${escapeHtml(error.message)}</div>`;
  }
}

function fillCompanySettingsForm(settings) {
  document.getElementById('companyName').value = settings.company_name || '';
  document.getElementById('companyTradeName').value = settings.trade_name || '';
  document.getElementById('companyCnpj').value = settings.cnpj || '';
  document.getElementById('companyAddress').value = settings.address || '';
  document.getElementById('companyCity').value = settings.city || '';
  document.getElementById('companyState').value = settings.state || '';
  document.getElementById('companyZipCode').value = settings.zip_code || '';
  document.getElementById('companyPhone').value = settings.phone || '';
  document.getElementById('companyWhatsapp').value = settings.whatsapp || '';
  document.getElementById('companyEmail').value = settings.email || '';
  document.getElementById('companyWebsite').value = settings.website || '';
  document.getElementById('companyLogoUrl').value = settings.logo_url || '';
  document.getElementById('companyPrimaryColor').value = settings.primary_color || DEFAULT_COMPANY_SETTINGS.primary_color;
  document.getElementById('companySecondaryColor').value = settings.secondary_color || DEFAULT_COMPANY_SETTINGS.secondary_color;
  document.getElementById('companyCurrency').value = settings.currency || 'BRL';
  document.getElementById('companyTimezone').value = settings.timezone || 'America/Sao_Paulo';
  document.getElementById('companyLanguage').value = settings.language || 'pt-BR';
}

function formatCompanySettingsDate(value) {
  if (!value) return 'pendente';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  return date.toLocaleString('pt-BR');
}

async function saveCompanySettingsFromForm(event) {
  event.preventDefault();
  const button = event.submitter || document.querySelector('#companySettingsForm button[type="submit"]');
  const message = document.getElementById('companySettingsMessage');
  message.style.color = 'var(--muted)';
  message.textContent = 'Salvando configuracoes...';
  if (button) button.disabled = true;
  try {
    await supabaseSaveCompanySettings({
      company_name: document.getElementById('companyName').value,
      trade_name: document.getElementById('companyTradeName').value,
      cnpj: document.getElementById('companyCnpj').value,
      address: document.getElementById('companyAddress').value,
      city: document.getElementById('companyCity').value,
      state: document.getElementById('companyState').value,
      zip_code: document.getElementById('companyZipCode').value,
      phone: document.getElementById('companyPhone').value,
      whatsapp: document.getElementById('companyWhatsapp').value,
      email: document.getElementById('companyEmail').value,
      website: document.getElementById('companyWebsite').value,
      logo_url: document.getElementById('companyLogoUrl').value,
      primary_color: document.getElementById('companyPrimaryColor').value,
      secondary_color: document.getElementById('companySecondaryColor').value,
      currency: document.getElementById('companyCurrency').value,
      timezone: document.getElementById('companyTimezone').value,
      language: document.getElementById('companyLanguage').value
    });
    message.style.color = 'var(--success)';
    message.textContent = 'Configuracoes salvas.';
  } catch (error) {
    message.style.color = 'var(--accent)';
    message.textContent = error.message;
  } finally {
    if (button) button.disabled = false;
  }
}

document.addEventListener('DOMContentLoaded', () => {
  loadCompanySettings().catch((error) => console.warn(error));
});
