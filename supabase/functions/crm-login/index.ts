import { createClient } from 'npm:@supabase/supabase-js@2.116.0';

const origins = () => (Deno.env.get('CRM_ALLOWED_ORIGINS') || 'https://debasistema-max.github.io,http://localhost:8000,http://127.0.0.1:8000')
  .split(',').map((value) => value.trim()).filter(Boolean);
const invalidLogin = 'Usuario ou senha invalidos.';

async function readLoginBody(request: Request) {
  if (Number(request.headers.get('content-length') || 0) > 4096 || !request.body) throw new Error('CORPO_INVALIDO');
  const reader = request.body.getReader();
  const decoder = new TextDecoder();
  let bytes = 0;
  let text = '';
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > 4096) { await reader.cancel(); throw new Error('CORPO_INVALIDO'); }
      text += decoder.decode(value, { stream: true });
    }
    return JSON.parse(text + decoder.decode());
  } finally { reader.releaseLock(); }
}

function reply(request: Request, status: number, body: Record<string, unknown>) {
  const origin = request.headers.get('origin') || '';
  return new Response(JSON.stringify(body), { status, headers: {
    ...(origins().includes(origin) ? { 'Access-Control-Allow-Origin': origin } : {}),
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Cache-Control': 'no-store', 'Content-Type': 'application/json; charset=utf-8',
    'X-Content-Type-Options': 'nosniff', 'Vary': 'Origin'
  } });
}

Deno.serve(async (request) => {
  const origin = request.headers.get('origin') || '';
  if (origin && !origins().includes(origin)) return reply(request, 403, { error: 'ORIGEM_NAO_AUTORIZADA' });
  if (request.method === 'OPTIONS') return reply(request, 200, { ok: true });
  if (request.method !== 'POST') return reply(request, 405, { error: 'METODO_NAO_PERMITIDO' });
  try {
    const body = await readLoginBody(request);
    const login = typeof body.login === 'string' ? body.login.trim() : '';
    const password = typeof body.password === 'string' ? body.password : '';
    if (!login || login.length > 254 || !password || password.length > 256) return reply(request, 401, { error: invalidLogin });
    const url = Deno.env.get('SUPABASE_URL') || '';
    const publicKey = Deno.env.get('SUPABASE_ANON_KEY') || '';
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
    if (!url || !publicKey || !serviceKey) return reply(request, 503, { error: 'Login temporariamente indisponivel.' });
    const options = { auth: { persistSession: false, autoRefreshToken: false } };
    const admin = createClient(url, serviceKey, options);
    const auth = createClient(url, publicKey, options);
    const ip = (request.headers.get('x-forwarded-for') || request.headers.get('cf-connecting-ip') || 'unknown').split(',')[0].trim().slice(0, 80);
    const salt = Deno.env.get('PUBLIC_RATE_LIMIT_SALT') || serviceKey;
    const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${salt}:crm-login:${ip}`));
    const subjectHash = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
    const { data: permitted, error: rateError } = await admin.rpc('consume_public_endpoint_rate_limit', {
      p_endpoint: 'crm-login', p_subject_hash: subjectHash, p_window_seconds: 900, p_max_requests: 30
    });
    if (rateError) return reply(request, 503, { error: 'Login temporariamente indisponivel.' });
    if (permitted !== true) return reply(request, 429, { error: 'Muitas tentativas. Aguarde alguns minutos.' });
    let email: string | null = login.includes('@') ? login.toLowerCase() : null;
    if (!email) {
      const { data: resolvedEmail, error: lookupError } = await admin.rpc('resolve_login_email', { login_text: login });
      if (lookupError) return reply(request, 503, { error: 'Login temporariamente indisponivel.' });
      email = resolvedEmail;
    }
    // Unknown identifiers still pass through Auth with an unusable identity.
    const effectiveEmail = email || `${crypto.randomUUID()}@invalid.example`;
    const { data, error } = await auth.auth.signInWithPassword({ email: effectiveEmail, password });
    if (error || !data.user || !data.session || !email) return reply(request, 401, { error: invalidLogin });
    const { data: profile, error: profileError } = await admin.from('profiles').select('id,ativo')
      .eq('id', data.user.id).eq('ativo', true).maybeSingle();
    if (profileError || !profile) {
      await auth.auth.signOut({ scope: 'local' });
      return reply(request, 401, { error: invalidLogin });
    }
    return reply(request, 200, { session: {
      access_token: data.session.access_token, refresh_token: data.session.refresh_token
    } });
  } catch {
    // Never log identifiers, passwords or returned tokens.
    return reply(request, 401, { error: invalidLogin });
  }
});
