import { createClient } from 'npm:@supabase/supabase-js@2.116.0';

const allowedOrigins = () => (Deno.env.get('B2B_ALLOWED_ORIGINS') ||
  'https://debasistema-max.github.io,http://localhost:8000,http://127.0.0.1:8000')
  .split(',').map((value) => value.trim()).filter(Boolean);

function headers(request: Request) {
  const origin = request.headers.get('origin') || '';
  return {
    ...(origin && allowedOrigins().includes(origin) ? { 'Access-Control-Allow-Origin': origin } : {}),
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Vary': 'Origin'
  };
}

const reply = (request: Request, status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: headers(request) });

function env(name: string) {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`CONFIGURACAO_AUSENTE:${name}`);
  return value;
}

function validPassword(value: unknown) {
  const password = String(value || '');
  return password.length >= 12 && password.length <= 72 &&
    /[a-z]/.test(password) && /[A-Z]/.test(password) && /[0-9]/.test(password)
    ? password : '';
}

Deno.serve(async (request) => {
  const origin = request.headers.get('origin') || '';
  if (origin && !allowedOrigins().includes(origin)) return reply(request, 403, { error: 'ORIGEM_NAO_AUTORIZADA' });
  if (request.method === 'OPTIONS') return new Response('ok', { headers: headers(request) });
  if (request.method !== 'POST') return reply(request, 405, { error: 'METODO_NAO_PERMITIDO' });
  const authorization = request.headers.get('authorization') || '';
  if (!authorization.startsWith('Bearer ')) return reply(request, 401, { error: 'AUTENTICACAO_OBRIGATORIA' });

  try {
    const body = await request.json().catch(() => ({}));
    const password = validPassword(body.password);
    if (!password) return reply(request, 400, { error: 'SENHA_FRACA' });

    const url = env('SUPABASE_URL');
    const anonKey = env('SUPABASE_ANON_KEY');
    const serviceKey = env('SUPABASE_SERVICE_ROLE_KEY');
    const caller = createClient(url, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false }
    });
    const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: authData, error: authError } = await caller.auth.getUser();
    if (authError || !authData.user) return reply(request, 401, { error: 'SESSAO_INVALIDA' });

    const { data: account, error: accountError } = await admin.from('customer_portal_accounts')
      .select('user_id,client_id,email,username,must_change_password,activation_pending')
      .eq('user_id', authData.user.id).maybeSingle();
    if (accountError) throw accountError;
    if (!account) return reply(request, 403, { error: 'ACESSO_B2B_NAO_AUTORIZADO' });
    if (!account.must_change_password && !account.activation_pending) {
      return reply(request, 409, { error: 'TROCA_INICIAL_JA_CONCLUIDA' });
    }

    const { error: passwordError } = await admin.auth.admin.updateUserById(authData.user.id, { password });
    if (passwordError) throw passwordError;
    const { error: activationError } = await admin.rpc('complete_b2b_password_change_for_user', {
      p_user_id: authData.user.id
    });
    if (activationError) throw activationError;
    await admin.from('logs').insert({
      user_id: null,
      usuario: `B2B:${account.username || account.email}`,
      acao: 'ALTERAR_SENHA_B2B',
      entidade: 'customer_portal_accounts',
      id_entidade: authData.user.id,
      dados_novos: { client_id: account.client_id, atomic_server_change: true }
    });
    return reply(request, 200, { ok: true });
  } catch (error) {
    console.error('b2b-change-password failed');
    return reply(request, 500, { error: 'NAO_FOI_POSSIVEL_TROCAR_SENHA' });
  }
});
