const steps = ['Empresa', 'Contato', 'Comercial', 'Fiscal', 'Documentos'];
let currentStep = 0;
let lastCnpjData = null;
const MAX_UPLOAD_BYTES = 5 * 1024 * 1024;
const MAX_TOTAL_UPLOAD_BYTES = 15 * 1024 * 1024;
const MAX_UPLOAD_FILES = 5;
const ALLOWED_UPLOAD_TYPES = ['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];
const DEFAULT_PORTAL_IDENTITY = {
  company_name: 'Nova Empresa',
  trade_name: '',
  logo_url: '../assets/logo-neutral.svg',
  primary_color: '#0b7063',
  secondary_color: '#064f47',
  email: '',
  phone: '',
  whatsapp: '',
  website: '',
  language: 'pt-BR'
};

document.addEventListener('DOMContentLoaded', () => {
  loadPortalCompanyIdentity().catch((error) => console.warn('Company identity unavailable.', error));
  restoreDraft();
  bindEvents();
  updateStep();
});

async function loadPortalCompanyIdentity() {
  const identity = await fetchPortalCompanyIdentity();
  applyPortalCompanyIdentity(identity);
  return identity;
}

async function fetchPortalCompanyIdentity() {
  if (!isPortalSupabaseReady()) return Object.assign({}, DEFAULT_PORTAL_IDENTITY);
  const { data, error } = await portalSupabase.rpc('get_public_company_identity');
  if (error) {
    console.warn('Public company identity unavailable.', error);
    return Object.assign({}, DEFAULT_PORTAL_IDENTITY);
  }
  return normalizePortalCompanyIdentity(data || {});
}

function normalizePortalCompanyIdentity(identity = {}) {
  return Object.assign({}, DEFAULT_PORTAL_IDENTITY, identity, {
    company_name: String(identity.company_name || DEFAULT_PORTAL_IDENTITY.company_name).trim(),
    logo_url: String(identity.logo_url || DEFAULT_PORTAL_IDENTITY.logo_url).trim(),
    primary_color: normalizePortalColor(identity.primary_color, DEFAULT_PORTAL_IDENTITY.primary_color),
    secondary_color: normalizePortalColor(identity.secondary_color, DEFAULT_PORTAL_IDENTITY.secondary_color),
    language: String(identity.language || DEFAULT_PORTAL_IDENTITY.language).trim()
  });
}

function normalizePortalColor(value, fallback) {
  const color = String(value || '').trim();
  return /^#[0-9A-Fa-f]{6}$/.test(color) ? color : fallback;
}

function applyPortalCompanyIdentity(identity) {
  const settings = normalizePortalCompanyIdentity(identity);
  const displayName = settings.trade_name || settings.company_name || DEFAULT_PORTAL_IDENTITY.company_name;
  document.documentElement.style.setProperty('--primary', settings.primary_color);
  document.documentElement.style.setProperty('--primary-strong', settings.secondary_color);
  document.documentElement.lang = settings.language || 'pt-BR';
  document.title = displayName + ' | Cadastro de Cliente';
  document.querySelectorAll('[data-company-kicker]').forEach((node) => {
    node.textContent = displayName;
  });
  document.querySelectorAll('[data-company-logo]').forEach((node) => {
    applyPortalCompanyLogo(node, settings.logo_url, displayName);
  });
  document.querySelectorAll('[data-company-contact]').forEach((node) => {
    node.textContent = [settings.whatsapp || settings.phone, settings.email, settings.website].filter(Boolean).join(' | ');
  });
}

function applyPortalCompanyLogo(node, logoUrl, displayName) {
  const fallback = DEFAULT_PORTAL_IDENTITY.logo_url;
  node.onerror = () => {
    if (node.dataset.logoFallbackApplied === 'true') return;
    node.dataset.logoFallbackApplied = 'true';
    node.src = fallback;
  };
  node.dataset.logoFallbackApplied = 'false';
  node.src = resolvePortalLogoUrl(logoUrl || fallback);
  node.alt = displayName || DEFAULT_PORTAL_IDENTITY.company_name;
}

function resolvePortalLogoUrl(logoUrl) {
  const value = String(logoUrl || '').trim();
  if (!value) return DEFAULT_PORTAL_IDENTITY.logo_url;
  if (/^(https?:|data:|blob:|\/)/i.test(value) || value.startsWith('../')) return value;
  if (value.startsWith('assets/')) return '../' + value;
  return value;
}

function bindEvents() {
  document.getElementById('nextStep').addEventListener('click', nextStep);
  document.getElementById('prevStep').addEventListener('click', previousStep);
  document.getElementById('consultarCnpj').addEventListener('click', consultCnpj);
  document.getElementById('cadastroForm').addEventListener('submit', submitCadastro);
  document.getElementById('newFormButton').addEventListener('click', resetForm);
  document.getElementById('cadastroForm').addEventListener('input', () => {
    applyMasks();
    saveDraft();
  });
  document.querySelectorAll('input[type="file"]').forEach((input) => {
    input.addEventListener('change', updateDocumentLabel);
  });
  document.querySelectorAll('input[name="possui_regime_especial"]').forEach((input) => {
    input.addEventListener('change', toggleRegimeFields);
  });
}

function updateStep() {
  document.querySelectorAll('.form-step').forEach((step, index) => {
    step.classList.toggle('is-active', index === currentStep);
  });
  document.getElementById('stepLabel').textContent = steps[currentStep];
  document.getElementById('stepCount').textContent = 'Etapa ' + (currentStep + 1) + ' de ' + steps.length;
  document.getElementById('progressBar').style.width = (((currentStep + 1) / steps.length) * 100) + '%';
  document.getElementById('prevStep').disabled = currentStep === 0;
  document.getElementById('nextStep').hidden = currentStep === steps.length - 1;
  document.getElementById('submitForm').hidden = currentStep !== steps.length - 1;
  setMessage('');
}

function nextStep() {
  if (!validateCurrentStep()) return;
  currentStep = Math.min(currentStep + 1, steps.length - 1);
  updateStep();
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

function previousStep() {
  currentStep = Math.max(currentStep - 1, 0);
  updateStep();
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

function validateCurrentStep() {
  const active = document.querySelector('.form-step.is-active');
  const required = Array.from(active.querySelectorAll('[required]'));
  const invalid = required.find((input) => !String(input.value || '').trim());
  if (invalid) {
    invalid.focus();
    setMessage('Preencha os campos obrigatorios antes de continuar.');
    return false;
  }
  if (currentStep === 0 && onlyDigits(field('cnpj').value).length !== 14) {
    field('cnpj').focus();
    setMessage('Informe um CNPJ valido com 14 digitos.');
    return false;
  }
  return true;
}

async function consultCnpj() {
  const cnpj = onlyDigits(field('cnpj').value);
  if (cnpj.length !== 14) {
    setMessage('Informe um CNPJ valido para consultar.');
    return;
  }
  const button = document.getElementById('consultarCnpj');
  button.disabled = true;
  setMessage('Consultando CNPJ...', 'muted');
  try {
    const data = await fetchCnpjData(cnpj);
    lastCnpjData = data;
    fillCompanyData(data);
    saveDraft();
    setMessage('Dados encontrados. Confira e ajuste se necessario.', 'success');
  } catch (error) {
    setMessage('Nao foi possivel consultar agora. Voce pode preencher manualmente.');
  } finally {
    button.disabled = false;
  }
}

async function fetchCnpjData(cnpj) {
  if (PORTAL_CONFIG.cnpjFunctionUrl) {
    const response = await fetch(PORTAL_CONFIG.cnpjFunctionUrl + '?cnpj=' + encodeURIComponent(cnpj), {
      headers: getFunctionHeaders({ Accept: 'application/json' })
    });
    const result = await response.json();
    if (!response.ok || !result.ok) throw new Error(result.error || 'Consulta indisponivel.');
    return result.data;
  }

  const attempts = [
    {
      url: PORTAL_CONFIG.cnpjApi + cnpj,
      source: 'brasilapi'
    },
    {
      url: PORTAL_CONFIG.cnpjFallbackApi + cnpj,
      source: 'receitaws'
    }
  ];

  let lastError = null;
  for (const attempt of attempts) {
    try {
      const response = await fetch(attempt.url, { headers: { Accept: 'application/json' } });
      if (!response.ok) throw new Error('HTTP ' + response.status);
      const data = await response.json();
      if (data.status === 'ERROR') throw new Error(data.message || 'CNPJ nao encontrado.');
      return normalizeCnpjData(data, attempt.source);
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError || new Error('Consulta indisponivel.');
}

function normalizeCnpjData(data, source) {
  if (source === 'receitaws') {
    const atividade = Array.isArray(data.atividade_principal) && data.atividade_principal[0]
      ? data.atividade_principal[0]
      : {};
    return {
      fonte: source,
      razao_social: data.nome,
      nome_fantasia: data.fantasia,
      cnae_fiscal: atividade.code,
      cnae_fiscal_descricao: atividade.text,
      descricao_situacao_cadastral: data.situacao,
      cep: data.cep,
      descricao_tipo_de_logradouro: '',
      logradouro: data.logradouro,
      numero: data.numero,
      complemento: data.complemento,
      bairro: data.bairro,
      municipio: data.municipio,
      uf: data.uf,
      ddd_telefone_1: data.telefone,
      email: data.email,
      raw: data
    };
  }
  return Object.assign({ fonte: source, raw: data }, data);
}

function fillCompanyData(data) {
  setField('razao_social', data.razao_social);
  setField('nome_fantasia', data.nome_fantasia);
  setField('cnae', data.cnae_fiscal);
  setField('atividade_principal', data.cnae_fiscal_descricao);
  setField('situacao_cadastral', data.descricao_situacao_cadastral || data.situacao_cadastral);
  setField('cep', formatCep(data.cep));
  setField('endereco', [data.descricao_tipo_de_logradouro, data.logradouro].filter(Boolean).join(' '));
  setField('numero', data.numero);
  setField('complemento', data.complemento);
  setField('bairro', data.bairro);
  setField('cidade', data.municipio);
  setField('estado', data.uf);
  setField('telefone', data.ddd_telefone_1);
  setField('email_compras', data.email);
}

async function submitCadastro(event) {
  event.preventDefault();
  if (!validateCurrentStep()) return;
  if (!isPortalSupabaseReady()) {
    setMessage('Supabase nao configurado para envio.');
    return;
  }
  const button = document.getElementById('submitForm');
  button.disabled = true;
  setMessage('Preparando documentos...', 'muted');
  try {
    const payload = await buildPayload();
    setMessage('Enviando cadastro...', 'muted');
    const data = await saveCadastro(payload);
    localStorage.removeItem(PORTAL_CONFIG.draftKey);
    document.getElementById('cadastroForm').hidden = true;
    document.querySelector('.progress-card').hidden = true;
    document.getElementById('protocolTitle').textContent = data && data.protocolo ? data.protocolo : 'Cadastro recebido';
    document.getElementById('successCard').hidden = false;
  } catch (error) {
    setMessage(error.message || 'Nao foi possivel enviar o cadastro.');
  } finally {
    button.disabled = false;
  }
}

async function saveCadastro(payload) {
  if (PORTAL_CONFIG.cadastroFunctionUrl) {
    let response;
    try {
      response = await fetch(PORTAL_CONFIG.cadastroFunctionUrl, {
        method: 'POST',
        headers: getFunctionHeaders({ 'Content-Type': 'application/json' }),
        body: JSON.stringify(payload)
      });
    } catch (error) {
      throw new Error('Servico de envio ainda nao esta publicado no Supabase. Avise o setor de cadastro.');
    }
    const result = await response.json();
    if (!response.ok || !result.ok) throw new Error(result.error || 'Nao foi possivel enviar o cadastro.');
    return result.data;
  }
  const { data, error } = await portalSupabase
    .from('cadastros_clientes')
    .insert(payload)
    .select('protocolo')
    .single();
  if (error) throw error;
  return data;
}

function getFunctionHeaders(extraHeaders) {
  const anonKey = PORTAL_SUPABASE_CONFIG && PORTAL_SUPABASE_CONFIG.anonKey;
  if (!anonKey) return extraHeaders || {};
  return Object.assign({
    apikey: anonKey,
    Authorization: 'Bearer ' + anonKey
  }, extraHeaders || {});
}

async function buildPayload() {
  const data = getFormData();
  return {
    cnpj: onlyDigits(data.cnpj),
    razao_social: data.razao_social,
    nome_fantasia: data.nome_fantasia,
    ie: data.ie,
    telefone: data.telefone,
    whatsapp: data.whatsapp,
    email_compras: data.email_compras,
    email_financeiro: data.email_financeiro,
    responsavel_compras: data.responsavel_compras,
    responsavel_financeiro: data.responsavel_financeiro,
    cep: onlyDigits(data.cep),
    endereco: data.endereco,
    numero: data.numero,
    bairro: data.bairro,
    complemento: data.complemento,
    cidade: data.cidade,
    estado: String(data.estado || '').toUpperCase(),
    site: data.site,
    instagram: data.instagram,
    como_conheceu: data.origem_conhecimento,
    segmento: data.segmento,
    transportadora: data.transportadora,
    vendedor: data.vendedor,
    prazo_desejado: data.prazo_desejado,
    volume_estimado: data.volume_estimado,
    observacoes: data.observacoes,
    atividade_principal: data.atividade_principal,
    cnae: data.cnae,
    situacao_cadastral: data.situacao_cadastral,
    possui_regime_especial: data.possui_regime_especial === 'true',
    descricao_regime: data.descricao_regime,
    estados_regime: data.estados_regime,
    anexos: await readAttachments(),
    origem: PORTAL_CONFIG.source,
    dados_api_cnpj: lastCnpjData
  };
}

function getFormData() {
  const data = {};
  new FormData(document.getElementById('cadastroForm')).forEach((value, key) => {
    if (value instanceof File) return;
    data[key] = String(value || '').trim();
  });
  return data;
}

async function readAttachments() {
  const attachments = [];
  let totalBytes = 0;
  const inputs = Array.from(document.querySelectorAll('input[type="file"]'));
  for (const input of inputs) {
    const label = input.dataset.docLabel || input.name;
    for (const file of Array.from(input.files || [])) {
      if (attachments.length >= MAX_UPLOAD_FILES) {
        throw new Error('Envie no maximo ' + MAX_UPLOAD_FILES + ' arquivos.');
      }
      validateAttachment(file);
      totalBytes += file.size;
      if (totalBytes > MAX_TOTAL_UPLOAD_BYTES) {
        throw new Error('O total dos arquivos nao pode ultrapassar 15 MB.');
      }
      attachments.push({
        field: input.name,
        label,
        name: file.name,
        type: file.type || 'application/octet-stream',
        size: file.size,
        content: await fileToBase64(file)
      });
    }
  }
  return attachments;
}

function validateAttachment(file) {
  if (file.size > MAX_UPLOAD_BYTES) {
    throw new Error('O arquivo ' + file.name + ' ultrapassa 5 MB.');
  }
  if (!ALLOWED_UPLOAD_TYPES.includes(file.type)) {
    throw new Error('O arquivo ' + file.name + ' deve ser PDF, JPG, PNG ou WEBP.');
  }
}

function fileToBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result || '').split(',')[1] || '');
    reader.onerror = () => reject(new Error('Nao foi possivel ler o arquivo ' + file.name + '.'));
    reader.readAsDataURL(file);
  });
}

function updateDocumentLabel(event) {
  const input = event.currentTarget;
  const output = input.parentElement.querySelector('span');
  const files = Array.from(input.files || []);
  if (!output) return;
  output.textContent = files.length
    ? files.map((file) => file.name).join(', ')
    : 'Nenhum arquivo selecionado';
}

function saveDraft() {
  localStorage.setItem(PORTAL_CONFIG.draftKey, JSON.stringify({
    step: currentStep,
    data: getFormData(),
    cnpjApi: lastCnpjData
  }));
}

function restoreDraft() {
  try {
    const draft = JSON.parse(localStorage.getItem(PORTAL_CONFIG.draftKey) || '{}');
    if (!draft.data) return;
    Object.entries(draft.data).forEach(([name, value]) => setField(name, value));
    lastCnpjData = draft.cnpjApi || null;
    currentStep = Math.max(0, Math.min(Number(draft.step || 0), steps.length - 1));
    toggleRegimeFields();
  } catch (error) {
    localStorage.removeItem(PORTAL_CONFIG.draftKey);
  }
}

function resetForm() {
  localStorage.removeItem(PORTAL_CONFIG.draftKey);
  window.location.reload();
}

function toggleRegimeFields() {
  const enabled = document.querySelector('input[name="possui_regime_especial"]:checked').value === 'true';
  document.getElementById('regimeFields').hidden = !enabled;
}

function applyMasks() {
  field('cnpj').value = formatCnpj(field('cnpj').value);
  field('cep').value = formatCep(field('cep').value);
  field('estado').value = String(field('estado').value || '').toUpperCase().slice(0, 2);
}

function field(name) {
  return document.querySelector('[name="' + name + '"]');
}

function setField(name, value) {
  const input = field(name);
  if (!input || value == null) return;
  if (input.type === 'radio') {
    const radio = document.querySelector('[name="' + name + '"][value="' + value + '"]');
    if (radio) radio.checked = true;
    return;
  }
  input.value = value;
}

function setMessage(text, type) {
  const message = document.getElementById('formMessage');
  message.textContent = text || '';
  if (type === 'success') message.style.color = 'var(--success)';
  else if (type === 'muted') message.style.color = 'var(--muted)';
  else message.style.color = 'var(--accent)';
}

function onlyDigits(value) {
  return String(value || '').replace(/\D/g, '');
}

function formatCnpj(value) {
  const digits = onlyDigits(value).slice(0, 14);
  return digits
    .replace(/^(\d{2})(\d)/, '$1.$2')
    .replace(/^(\d{2})\.(\d{3})(\d)/, '$1.$2.$3')
    .replace(/\.(\d{3})(\d)/, '.$1/$2')
    .replace(/(\d{4})(\d)/, '$1-$2');
}

function formatCep(value) {
  const digits = onlyDigits(value).slice(0, 8);
  return digits.replace(/^(\d{5})(\d)/, '$1-$2');
}
