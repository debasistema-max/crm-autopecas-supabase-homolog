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
  logo_url: 'assets/logo-ips-yokomitsu.png',
  primary_color: '#0d6b5f',
  secondary_color: '#17212b',
  currency: 'BRL',
  timezone: 'America/Sao_Paulo',
  language: 'pt-BR'
};

const COMPANY_LOGO_BUCKET = 'company-assets';
const COMPANY_LOGO_MAX_BYTES = 2 * 1024 * 1024;
const COMPANY_LOGO_ALLOWED_TYPES = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp'
};

let cachedCompanySettings = null;
let cachedFullCompanySettings = null;
let companyLogoPreviewObjectUrl = '';

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
    : `${displayName} | Portal Comercial`;

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
  releaseCompanyLogoPreview();
  container.innerHTML = '<div class="empty-state">Carregando configuracoes da empresa...</div>';
  try {
    const settings = await supabaseGetCompanySettings();
    container.innerHTML = `
      <section class="panel admin-panel">
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
          <div class="span-6 company-logo-upload">
            <label for="companyLogoFile">Logotipo da empresa</label>
            <input id="companyLogoFile" type="file" accept="image/png,image/jpeg,image/webp">
            <small>Envie uma imagem PNG, JPG ou WebP de ate 2 MB. O logo atual sera mantido ate salvar.</small>
            <span id="companyLogoFileName" class="company-logo-file-name">Nenhuma nova imagem selecionada.</span>
          </div>
          <label class="span-2">Cor principal<input id="companyPrimaryColor" type="color"></label>
          <label class="span-2">Cor secundaria<input id="companySecondaryColor" type="color"></label>
          <label class="span-2">Moeda<input id="companyCurrency" maxlength="3"></label>
          <label class="span-3">Timezone<input id="companyTimezone"></label>
          <label class="span-3">Idioma<input id="companyLanguage"></label>
          <div class="span-12 company-settings-preview">
            <img id="companyLogoPreview" data-company-logo src="${escapeHtml(settings.logo_url)}" alt="">
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
    const form = document.getElementById('companySettingsForm');
    form.dataset.currentLogoUrl = settings.logo_url || '';
    document.getElementById('companyLogoFile').addEventListener('change', previewSelectedCompanyLogo);
    form.addEventListener('submit', saveCompanySettingsFromForm);
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
  document.getElementById('companyPrimaryColor').value = settings.primary_color || DEFAULT_COMPANY_SETTINGS.primary_color;
  document.getElementById('companySecondaryColor').value = settings.secondary_color || DEFAULT_COMPANY_SETTINGS.secondary_color;
  document.getElementById('companyCurrency').value = settings.currency || 'BRL';
  document.getElementById('companyTimezone').value = settings.timezone || 'America/Sao_Paulo';
  document.getElementById('companyLanguage').value = settings.language || 'pt-BR';
}

function releaseCompanyLogoPreview() {
  if (!companyLogoPreviewObjectUrl) return;
  URL.revokeObjectURL(companyLogoPreviewObjectUrl);
  companyLogoPreviewObjectUrl = '';
}

async function validateCompanyLogoFile(file) {
  if (!file) throw new Error('Selecione uma imagem para o logotipo.');
  if (!COMPANY_LOGO_ALLOWED_TYPES[file.type]) {
    throw new Error('Formato nao permitido. Use PNG, JPG ou WebP.');
  }
  if (file.size > COMPANY_LOGO_MAX_BYTES) {
    throw new Error('O logotipo deve ter no maximo 2 MB.');
  }
  const dimensions = await readCompanyLogoDimensions(file);
  if (!dimensions.width || !dimensions.height || dimensions.width > 4096 || dimensions.height > 4096) {
    throw new Error('A imagem deve ter dimensoes validas de ate 4096 x 4096 pixels.');
  }
}

function readCompanyLogoDimensions(file) {
  return new Promise((resolve, reject) => {
    const objectUrl = URL.createObjectURL(file);
    const image = new Image();
    image.onload = () => {
      URL.revokeObjectURL(objectUrl);
      resolve({ width: image.naturalWidth, height: image.naturalHeight });
    };
    image.onerror = () => {
      URL.revokeObjectURL(objectUrl);
      reject(new Error('O arquivo selecionado nao e uma imagem valida.'));
    };
    image.src = objectUrl;
  });
}

async function previewSelectedCompanyLogo(event) {
  const input = event.currentTarget;
  const file = input.files && input.files[0];
  const form = document.getElementById('companySettingsForm');
  const preview = document.getElementById('companyLogoPreview');
  const fileName = document.getElementById('companyLogoFileName');
  const message = document.getElementById('companySettingsMessage');
  releaseCompanyLogoPreview();
  if (!file) {
    applyCompanyLogo(preview, form.dataset.currentLogoUrl, getCompanyDisplayName(cachedFullCompanySettings || DEFAULT_COMPANY_SETTINGS));
    fileName.textContent = 'Nenhuma nova imagem selecionada.';
    return;
  }
  try {
    await validateCompanyLogoFile(file);
    if (!input.files || input.files[0] !== file) return;
    companyLogoPreviewObjectUrl = URL.createObjectURL(file);
    preview.src = companyLogoPreviewObjectUrl;
    preview.alt = `Previa do arquivo ${file.name}`;
    fileName.textContent = file.name;
    message.textContent = 'Previa carregada. Clique em Salvar configuracoes para enviar o novo logo.';
    message.style.color = 'var(--muted)';
  } catch (error) {
    input.value = '';
    applyCompanyLogo(preview, form.dataset.currentLogoUrl, getCompanyDisplayName(cachedFullCompanySettings || DEFAULT_COMPANY_SETTINGS));
    fileName.textContent = 'Nenhuma nova imagem selecionada.';
    message.textContent = error.message;
    message.style.color = 'var(--accent)';
  }
}

async function uploadCompanyLogo(file) {
  await validateCompanyLogoFile(file);
  const extension = COMPANY_LOGO_ALLOWED_TYPES[file.type];
  const uniqueId = typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function'
    ? crypto.randomUUID()
    : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const path = `identity/logo-${uniqueId}.${extension}`;
  const { error } = await supabaseClient.storage
    .from(COMPANY_LOGO_BUCKET)
    .upload(path, file, {
      cacheControl: '3600',
      contentType: file.type,
      upsert: false
    });
  if (error) throw error;
  const { data } = supabaseClient.storage.from(COMPANY_LOGO_BUCKET).getPublicUrl(path);
  if (!data || !data.publicUrl) throw new Error('Nao foi possivel obter o endereco do logotipo enviado.');
  return { path, publicUrl: `${data.publicUrl}?v=${Date.now()}` };
}

function getManagedCompanyLogoPath(logoUrl) {
  const value = String(logoUrl || '').trim();
  if (!value || typeof location === 'undefined') return '';
  try {
    const parsed = new URL(value, location.href);
    const expectedOrigin = new URL(SUPABASE_CONFIG.url).origin;
    if (parsed.origin !== expectedOrigin) return '';
    const marker = `/storage/v1/object/public/${COMPANY_LOGO_BUCKET}/`;
    const markerIndex = parsed.pathname.indexOf(marker);
    if (markerIndex < 0) return '';
    const path = decodeURIComponent(parsed.pathname.slice(markerIndex + marker.length));
    return path.startsWith('identity/') && !path.includes('..') ? path : '';
  } catch (error) {
    return '';
  }
}

async function removeManagedCompanyLogo(path) {
  if (!path) return;
  const { error } = await supabaseClient.storage.from(COMPANY_LOGO_BUCKET).remove([path]);
  if (error) throw error;
}

function formatCompanySettingsDate(value) {
  if (!value) return 'pendente';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  return date.toLocaleString('pt-BR');
}

async function saveCompanySettingsFromForm(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const button = event.submitter || document.querySelector('#companySettingsForm button[type="submit"]');
  const message = document.getElementById('companySettingsMessage');
  message.style.color = 'var(--muted)';
  message.textContent = 'Salvando configuracoes...';
  if (button) button.disabled = true;
  try {
    const logoInput = document.getElementById('companyLogoFile');
    const logoFile = logoInput.files && logoInput.files[0];
    const previousLogoUrl = form.dataset.currentLogoUrl || '';
    let uploadedLogo = null;
    if (logoFile) {
      message.textContent = 'Enviando logotipo...';
      uploadedLogo = await uploadCompanyLogo(logoFile);
    }
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
      logo_url: uploadedLogo ? uploadedLogo.publicUrl : previousLogoUrl,
      primary_color: document.getElementById('companyPrimaryColor').value,
      secondary_color: document.getElementById('companySecondaryColor').value,
      currency: document.getElementById('companyCurrency').value,
      timezone: document.getElementById('companyTimezone').value,
      language: document.getElementById('companyLanguage').value
    });
    if (uploadedLogo) {
      const previousLogoPath = getManagedCompanyLogoPath(previousLogoUrl);
      form.dataset.currentLogoUrl = uploadedLogo.publicUrl;
      logoInput.value = '';
      document.getElementById('companyLogoFileName').textContent = 'Nenhuma nova imagem selecionada.';
      releaseCompanyLogoPreview();
      if (previousLogoPath && previousLogoPath !== uploadedLogo.path) {
        removeManagedCompanyLogo(previousLogoPath).catch((error) => console.warn('Logo anterior nao removido.', error));
      }
    }
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
