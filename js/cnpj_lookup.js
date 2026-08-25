const CNPJ_LOOKUP_TIMEOUT_MS = 12000;

function normalizeCnpjDigits(value) {
  return String(value || '').replace(/\D/g, '');
}

function isValidCnpj(value) {
  const digits = normalizeCnpjDigits(value);
  if (digits.length !== 14 || /^(\d)\1{13}$/.test(digits)) return false;
  const calculateDigit = (length) => {
    let factor = length - 7;
    let sum = 0;
    for (let index = 0; index < length; index += 1) {
      sum += Number(digits[index]) * factor;
      factor -= 1;
      if (factor < 2) factor = 9;
    }
    const remainder = sum % 11;
    return remainder < 2 ? 0 : 11 - remainder;
  };
  return calculateDigit(12) === Number(digits[12]) && calculateDigit(13) === Number(digits[13]);
}

async function fetchJsonWithTimeout(url, options = {}) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), CNPJ_LOOKUP_TIMEOUT_MS);
  try {
    const response = await fetch(url, Object.assign({}, options, { signal: controller.signal }));
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(payload.error || payload.message || `Consulta retornou HTTP ${response.status}.`);
    return payload;
  } catch (error) {
    if (error && error.name === 'AbortError') throw new Error('A consulta demorou mais que o esperado.');
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

function normalizeBusinessRegistryData(payload, source) {
  const data = payload && payload.ok && payload.data ? payload.data : payload;
  if (!data || typeof data !== 'object') throw new Error('O serviço retornou dados inválidos.');
  if (data.status === 'ERROR') throw new Error(data.message || 'CNPJ não encontrado.');
  const activity = Array.isArray(data.atividade_principal) && data.atividade_principal[0] ? data.atividade_principal[0] : {};
  const address = [
    [data.descricao_tipo_de_logradouro, data.logradouro].filter(Boolean).join(' '),
    data.numero,
    data.complemento,
    data.bairro,
    data.cep ? `CEP ${String(data.cep).replace(/\D/g, '')}` : ''
  ].filter(Boolean).join(', ');
  return {
    source: data.fonte || source,
    cnpj: normalizeCnpjDigits(data.cnpj || data.cnpj_raiz),
    legal_name: String(data.razao_social || data.nome || '').trim(),
    trade_name: String(data.nome_fantasia || data.fantasia || '').trim(),
    phone: String(data.ddd_telefone_1 || data.telefone || '').trim(),
    email: String(data.email || '').trim().toLowerCase(),
    state: String(data.uf || '').trim().toUpperCase(),
    city: String(data.municipio || '').trim(),
    address,
    status: String(data.descricao_situacao_cadastral || data.situacao || '').trim(),
    main_activity: String(data.cnae_fiscal_descricao || activity.text || '').trim(),
    raw: data.raw || data
  };
}

async function fetchBusinessRegistryByCnpj(value) {
  const cnpj = normalizeCnpjDigits(value);
  if (!isValidCnpj(cnpj)) throw new Error('Informe um CNPJ válido com 14 dígitos.');
  const attempts = [];
  if (typeof SUPABASE_CONFIG !== 'undefined' && SUPABASE_CONFIG.url && SUPABASE_CONFIG.anonKey) {
    attempts.push({
      source: 'Receita Federal via homologação',
      url: `${SUPABASE_CONFIG.url}/functions/v1/consulta-cnpj?cnpj=${encodeURIComponent(cnpj)}`,
      options: { headers: { Accept: 'application/json', apikey: SUPABASE_CONFIG.anonKey, Authorization: `Bearer ${SUPABASE_CONFIG.anonKey}` } }
    });
  }
  attempts.push({
    source: 'BrasilAPI',
    url: `https://brasilapi.com.br/api/cnpj/v1/${encodeURIComponent(cnpj)}`,
    options: { headers: { Accept: 'application/json' } }
  });

  let lastError = null;
  for (const attempt of attempts) {
    try {
      const payload = await fetchJsonWithTimeout(attempt.url, attempt.options);
      return normalizeBusinessRegistryData(payload, attempt.source);
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError || new Error('Consulta gratuita de CNPJ indisponível no momento.');
}
