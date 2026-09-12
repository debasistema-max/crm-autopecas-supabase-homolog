import { createClient } from 'npm:@supabase/supabase-js@2';

function requiredEnv(name: string) {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`CONFIGURACAO_AUSENTE:${name}`);
  return value;
}

function allowedOrigins() {
  return (Deno.env.get('B2B_ALLOWED_ORIGINS') ||
    'https://debasistema-max.github.io,http://localhost:8000,http://127.0.0.1:8000')
    .split(',').map((value) => value.trim()).filter(Boolean);
}

function corsHeaders(request: Request) {
  const origin = request.headers.get('origin') || '';
  const allowed = allowedOrigins();
  const selected = allowed.includes(origin) ? origin : allowed[0];
  return {
    'Access-Control-Allow-Origin': selected,
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Content-Type': 'application/json; charset=utf-8',
    'Vary': 'Origin'
  };
}

function json(request: Request, status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders(request) });
}

function uuid(value: unknown) {
  const text = String(value || '').trim();
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(text) ? text : '';
}

function email(value: unknown) {
  const text = String(value || '').trim().toLowerCase();
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(text) ? text : '';
}

async function findUserByEmail(admin: ReturnType<typeof createClient>, targetEmail: string) {
  for (let page = 1; page <= 20; page += 1) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 100 });
    if (error) throw error;
    const found = data.users.find((user) => user.email?.toLowerCase() === targetEmail);
    if (found) return found;
    if (data.users.length < 100) break;
  }
  return null;
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(request) });
  if (request.method !== 'POST') return json(request, 405, { error: 'METODO_NAO_PERMITIDO' });
  const origin = request.headers.get('origin') || '';
  if (origin && !allowedOrigins().includes(origin)) return json(request, 403, { error: 'ORIGEM_NAO_AUTORIZADA' });

  try {
    const supabaseUrl = requiredEnv('SUPABASE_URL');
    const anonKey = requiredEnv('SUPABASE_ANON_KEY');
    const serviceKey = requiredEnv('SUPABASE_SERVICE_ROLE_KEY');
    const authorization = request.headers.get('authorization') || '';
    if (!authorization.startsWith('Bearer ')) return json(request, 401, { error: 'AUTENTICACAO_OBRIGATORIA' });

    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false }
    });
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false }
    });
    const { data: authData, error: authError } = await callerClient.auth.getUser();
    if (authError || !authData.user) return json(request, 401, { error: 'SESSAO_INVALIDA' });
    const { data: caller } = await admin.from('profiles')
      .select('id,usuario,nome,perfil,ativo').eq('id', authData.user.id).eq('ativo', true).maybeSingle();
    if (!caller || caller.perfil !== 'ADMIN') return json(request, 403, { error: 'APENAS_ADMIN' });

    const body = await request.json().catch(() => ({}));
    const action = String(body.action || '').trim().toLowerCase();
    const clientId = uuid(body.client_id);
    if (!clientId) return json(request, 400, { error: 'CLIENTE_INVALIDO' });
    const { data: client } = await admin.from('clients')
      .select('id,nome,nome_fantasia,email,ativo').eq('id', clientId).maybeSingle();
    if (!client) return json(request, 404, { error: 'CLIENTE_NAO_ENCONTRADO' });

    if (action === 'list') {
      const [accountsResult, requestsResult] = await Promise.all([
        admin.from('customer_portal_accounts')
          .select('user_id,client_id,email,contact_name,active,can_create_quotations,can_create_orders,can_view_stock,can_view_prices,owner_profile_id,invited_at,last_login_at,created_at')
          .eq('client_id', clientId).order('created_at', { ascending: false }),
        admin.from('customer_portal_change_requests')
          .select('id,client_id,requested_by,requested_data,status,reviewed_by,reviewed_at,review_notes,created_at')
          .eq('client_id', clientId).order('created_at', { ascending: false }).limit(20)
      ]);
      if (accountsResult.error) throw accountsResult.error;
      if (requestsResult.error) throw requestsResult.error;
      return json(request, 200, {
        client,
        accounts: accountsResult.data || [],
        change_requests: requestsResult.data || []
      });
    }

    if (action === 'invite') {
      if (client.ativo === false) return json(request, 409, { error: 'CLIENTE_INATIVO' });
      const targetEmail = email(body.email || client.email);
      if (!targetEmail) return json(request, 400, { error: 'EMAIL_INVALIDO' });
      const redirectTo = Deno.env.get('B2B_REDIRECT_URL')?.trim() ||
        'https://debasistema-max.github.io/crm-autopecas-supabase-homolog/b2b/';
      let targetUser = await findUserByEmail(admin, targetEmail);
      let emailSent = false;

      if (!targetUser) {
        const { data, error } = await admin.auth.admin.inviteUserByEmail(targetEmail, {
          redirectTo,
          data: { account_type: 'b2b', client_id: clientId, client_name: client.nome }
        });
        if (error) throw error;
        targetUser = data.user;
        emailSent = true;
      } else {
        const { data: internalProfile } = await admin.from('profiles').select('id').eq('id', targetUser.id).maybeSingle();
        if (internalProfile) return json(request, 409, { error: 'EMAIL_PERTENCE_A_USUARIO_INTERNO' });
      }
      if (!targetUser) throw new Error('USUARIO_B2B_NAO_CRIADO');

      const requestedOwner = uuid(body.owner_profile_id) || caller.id;
      const { data: owner } = await admin.from('profiles').select('id').eq('id', requestedOwner).eq('ativo', true).maybeSingle();
      if (!owner) return json(request, 400, { error: 'RESPONSAVEL_INTERNO_INVALIDO' });

      const { error: metadataError } = await admin.auth.admin.updateUserById(targetUser.id, {
        app_metadata: { ...(targetUser.app_metadata || {}), account_type: 'b2b', client_id: clientId }
      });
      if (metadataError) throw metadataError;
      const { data: account, error: accountError } = await admin.from('customer_portal_accounts').upsert({
        user_id: targetUser.id,
        client_id: clientId,
        email: targetEmail,
        contact_name: String(body.contact_name || '').trim() || null,
        active: true,
        can_create_quotations: body.can_create_quotations !== false,
        can_create_orders: body.can_create_orders !== false,
        can_view_stock: body.can_view_stock !== false,
        can_view_prices: body.can_view_prices !== false,
        owner_profile_id: owner.id,
        invited_by: caller.id,
        invited_at: new Date().toISOString(),
        updated_at: new Date().toISOString()
      }, { onConflict: 'user_id' }).select().single();
      if (accountError) throw accountError;

      if (!emailSent) {
        const { error } = await admin.auth.resetPasswordForEmail(targetEmail, { redirectTo });
        if (error) throw error;
        emailSent = true;
      }
      await admin.from('logs').insert({
        user_id: caller.id, usuario: caller.usuario, acao: 'CONCEDER_ACESSO_B2B', entidade: 'customer_portal_accounts',
        id_entidade: targetUser.id, dados_novos: { client_id: clientId, email: targetEmail, owner_profile_id: owner.id }
      });
      return json(request, 200, { account, email_sent: emailSent });
    }

    if (action === 'set_active') {
      const userId = uuid(body.user_id);
      if (!userId) return json(request, 400, { error: 'USUARIO_INVALIDO' });
      const { data, error } = await admin.from('customer_portal_accounts').update({
        active: body.active === true,
        updated_at: new Date().toISOString()
      }).eq('user_id', userId).eq('client_id', clientId).select().maybeSingle();
      if (error) throw error;
      if (!data) return json(request, 404, { error: 'ACESSO_B2B_NAO_ENCONTRADO' });
      await admin.from('logs').insert({
        user_id: caller.id, usuario: caller.usuario,
        acao: body.active === true ? 'REATIVAR_ACESSO_B2B' : 'REVOGAR_ACESSO_B2B',
        entidade: 'customer_portal_accounts', id_entidade: userId,
        dados_novos: { client_id: clientId, active: body.active === true }
      });
      return json(request, 200, { account: data });
    }

    if (action === 'review_change') {
      const requestId = uuid(body.request_id);
      const decision = String(body.decision || '').trim().toUpperCase();
      const reviewNotes = String(body.review_notes || '').trim().slice(0, 500) || null;
      if (!requestId) return json(request, 400, { error: 'SOLICITACAO_INVALIDA' });
      if (!['APPROVED', 'REJECTED'].includes(decision)) {
        return json(request, 400, { error: 'DECISAO_INVALIDA' });
      }
      const { data: reviewed, error: reviewError } = await admin.rpc('admin_review_b2b_profile_change', {
        p_request_id: requestId,
        p_client_id: clientId,
        p_reviewer: caller.id,
        p_decision: decision,
        p_notes: reviewNotes
      });
      if (reviewError) throw reviewError;
      return json(request, 200, { request: reviewed, client_updated: decision === 'APPROVED' });
    }

    return json(request, 400, { error: 'ACAO_INVALIDA' });
  } catch (error) {
    console.error('b2b-admin', error);
    const message = error instanceof Error ? error.message : 'ERRO_INTERNO';
    return json(request, 500, { error: message.replace(/[^A-Za-z0-9_:\-. ]/g, '').slice(0, 180) });
  }
});
