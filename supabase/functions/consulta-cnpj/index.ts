import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'npm:@supabase/supabase-js@2.116.0';

const allowedOrigins = () => (Deno.env.get('PUBLIC_PORTAL_ALLOWED_ORIGINS') ||
  'https://debasistema-max.github.io,http://localhost:8000,http://127.0.0.1:8000')
  .split(',').map((value) => value.trim()).filter(Boolean);

function responseHeaders(req: Request) {
  const origin = req.headers.get('origin') || '';
  return {
    ...(origin && allowedOrigins().includes(origin) ? { 'Access-Control-Allow-Origin': origin } : {}),
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Vary': 'Origin'
  };
}

serve(async (req) => {
  const origin = req.headers.get('origin') || '';
  if (origin && !allowedOrigins().includes(origin)) return json(req, { ok: false, error: 'Origem nao autorizada.' }, 403);
  if (req.method === 'OPTIONS') return new Response('ok', { headers: responseHeaders(req) });
  if (!['GET','POST'].includes(req.method)) return json(req, { ok: false, error: 'Metodo nao permitido.' }, 405);

  try {
    const cnpj = await readCnpj(req);
    if (cnpj.length !== 14) return json(req, { ok: false, error: 'CNPJ invalido.' }, 400);
    if (!await consumeRateLimit(req, 'consulta-cnpj', 900, 30)) {
      return json(req, { ok: false, error: 'Muitas consultas. Aguarde alguns minutos.' }, 429);
    }
    const data = await fetchCnpjData(cnpj);
    return json(req, { ok: true, data });
  } catch (error) {
    console.error('consulta-cnpj', error);
    return json(req, { ok: false, error: 'Nao foi possivel consultar o CNPJ.' }, 500);
  }
});

async function readCnpj(req: Request) {
  if (req.method === 'GET') return onlyDigits(new URL(req.url).searchParams.get('cnpj'));
  const length = Number(req.headers.get('content-length') || 0);
  if (length > 4096) throw new Error('CORPO_EXCEDIDO');
  const body = await req.json().catch(() => ({}));
  return onlyDigits(body.cnpj);
}

async function consumeRateLimit(req: Request, endpoint: string, windowSeconds: number, maxRequests: number) {
  const url = Deno.env.get('SUPABASE_URL')?.trim();
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')?.trim();
  if (!url || !key) throw new Error('RATE_LIMIT_NAO_CONFIGURADO');
  const client = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await client.rpc('consume_public_endpoint_rate_limit', {
    p_endpoint: endpoint,
    p_subject_hash: await requestSubjectHash(req, endpoint),
    p_window_seconds: windowSeconds,
    p_max_requests: maxRequests
  });
  if (error) throw error;
  return data === true;
}

async function requestSubjectHash(req: Request, endpoint: string) {
  const ip = (req.headers.get('x-forwarded-for') || req.headers.get('cf-connecting-ip') || 'unknown')
    .split(',')[0].trim().slice(0, 80);
  const salt = Deno.env.get('PUBLIC_RATE_LIMIT_SALT') || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  const bytes = new TextEncoder().encode(`${salt}:${endpoint}:${ip}`);
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)))
    .map((value) => value.toString(16).padStart(2, '0')).join('');
}

async function fetchCnpjData(cnpj: string) {
  const attempts = [
    { url: `https://brasilapi.com.br/api/cnpj/v1/${cnpj}`, source: 'brasilapi' },
    { url: `https://www.receitaws.com.br/v1/cnpj/${cnpj}`, source: 'receitaws' }
  ];
  let lastError: Error | null = null;
  for (const attempt of attempts) {
    try {
      const response = await fetch(attempt.url, {
        headers: { Accept: 'application/json', 'User-Agent': 'crm-autopecas-supabase' },
        signal: AbortSignal.timeout(8000)
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const payload = await response.json();
      if (payload.status === 'ERROR') throw new Error('CNPJ_NAO_ENCONTRADO');
      return normalizeCnpjData(payload, attempt.source);
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
    }
  }
  throw lastError || new Error('CONSULTA_INDISPONIVEL');
}

function normalizeCnpjData(data: Record<string, unknown>, source: string) {
  if (source === 'receitaws') {
    const atividades = Array.isArray(data.atividade_principal) ? data.atividade_principal : [];
    const atividade = (atividades[0] || {}) as Record<string, unknown>;
    return {
      fonte: source, razao_social: data.nome, nome_fantasia: data.fantasia,
      cnae_fiscal: atividade.code, cnae_fiscal_descricao: atividade.text,
      descricao_situacao_cadastral: data.situacao, cep: data.cep,
      descricao_tipo_de_logradouro: '', logradouro: data.logradouro, numero: data.numero,
      complemento: data.complemento, bairro: data.bairro, municipio: data.municipio,
      uf: data.uf, ddd_telefone_1: data.telefone, email: data.email
    };
  }
  const allowed = [
    'razao_social','nome_fantasia','cnae_fiscal','cnae_fiscal_descricao',
    'descricao_situacao_cadastral','cep','descricao_tipo_de_logradouro','logradouro',
    'numero','complemento','bairro','municipio','uf','ddd_telefone_1','email'
  ];
  return Object.fromEntries([['fonte',source],...allowed.map((key) => [key,data[key]])]);
}

function json(req: Request, body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: responseHeaders(req) });
}

function onlyDigits(value: unknown) {
  return String(value || '').replace(/\D/g, '');
}
