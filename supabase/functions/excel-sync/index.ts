import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.116.0';

const allowedOrigins = () => (Deno.env.get('DATA_SYNC_ALLOWED_ORIGIN') ||
  'https://debasistema-max.github.io,http://localhost:8000,http://127.0.0.1:8000')
  .split(',').map((value) => value.trim()).filter(Boolean);

function corsHeaders(request: Request) {
  const origin = request.headers.get('origin') || '';
  return {
    ...(origin && allowedOrigins().includes(origin) ? { 'Access-Control-Allow-Origin': origin } : {}),
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-sync-secret',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Vary': 'Origin'
  };
}

function response(request: Request, status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders(request) });
}

function env(name: string, required = true) {
  const value = Deno.env.get(name)?.trim();
  if (required && !value) throw new Error(`CONFIGURACAO_AUSENTE:${name}`);
  return value || '';
}

async function rpc(client: SupabaseClient, name: string, args: Record<string, unknown>) {
  const { data, error } = await client.rpc(name, args);
  if (error) throw new Error(`${name}:${error.message}`);
  return data;
}

async function finalizeBatch(client: SupabaseClient, batchId: string) {
  const validated = await rpc(client, 'validate_data_sync_batch', { target_batch_id: batchId });
  if (validated.status === 'failed') {
    const failed = await rpc(client, 'mark_data_sync_failure', {
      target_batch_id: batchId,
      error_message: 'LOTE_SEM_LINHAS_VALIDAS'
    });
    return { failed: true, batch: failed };
  }
  return { failed: false, batch: await rpc(client, 'commit_data_sync_batch', { target_batch_id: batchId }) };
}

async function dispatchGithubSync() {
  const token = env('DATA_SYNC_GITHUB_TOKEN');
  const repository = env('DATA_SYNC_GITHUB_REPOSITORY');
  const workflow = Deno.env.get('DATA_SYNC_GITHUB_WORKFLOW')?.trim() || 'excel-sync.yml';
  const ref = Deno.env.get('DATA_SYNC_GITHUB_REF')?.trim() || 'main';
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository)) {
    throw new Error('CONFIGURACAO_INVALIDA:DATA_SYNC_GITHUB_REPOSITORY');
  }

  const endpoint = `https://api.github.com/repos/${repository}/actions/workflows/${encodeURIComponent(workflow)}/dispatches`;
  const githubResponse = await fetch(endpoint, {
    method: 'POST',
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'ips-crm-data-sync'
    },
    body: JSON.stringify({ ref })
  });
  if (!githubResponse.ok) {
    throw new Error(`GITHUB_DISPATCH_HTTP_${githubResponse.status}`);
  }
  return {
    queued: true,
    queued_at: new Date().toISOString(),
    message: 'Sincronização colocada na fila.'
  };
}

Deno.serve(async (request) => {
  const origin = request.headers.get('origin') || '';
  if (origin && !allowedOrigins().includes(origin)) return response(request,403,{ error:'ORIGEM_NAO_AUTORIZADA' });
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(request) });
  if (request.method !== 'POST') return response(request,405, { error: 'METODO_NAO_PERMITIDO' });

  const supabaseUrl = env('SUPABASE_URL');
  const anonKey = env('SUPABASE_ANON_KEY');
  const schedulerSecret = Deno.env.get('DATA_SYNC_SCHEDULER_SECRET') || '';
  const requestSecret = request.headers.get('x-sync-secret') || '';
  const scheduled = Boolean(schedulerSecret && requestSecret && requestSecret === schedulerSecret);
  const authorization = request.headers.get('Authorization') || '';
  if (!scheduled && !authorization.startsWith('Bearer ')) {
    return response(request,401, { error: 'AUTENTICACAO_OBRIGATORIA' });
  }

  const key = scheduled ? env('SUPABASE_SERVICE_ROLE_KEY') : anonKey;
  const client = createClient(supabaseUrl, key, {
    global: scheduled ? {} : { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false }
  });

  if (!scheduled) {
    const { data: authData, error: authError } = await client.auth.getUser();
    if (authError || !authData.user) return response(request,401, { error: 'SESSAO_INVALIDA' });
    const canManage = await rpc(client, 'can_manage_data_sync', {});
    if (canManage !== true) return response(request,403, { error: 'SEM_PERMISSAO_SINCRONIZAR' });
  }

  let batchId = '';
  let integrationSource = 'EXCEL_API';
  let operation = '';
  try {
    const requestBody = await request.json().catch(() => ({}));
    const source = String(requestBody.source || 'EXCEL_API').trim().toUpperCase();
    if (source !== 'EXCEL_API') return response(request,400, { error: 'FONTE_NAO_SUPORTADA_NESTE_ADAPTER' });
    integrationSource = source;

    // A cloud runner sends small, authenticated chunks. This keeps the XLSX and
    // service-role key out of the browser and avoids a single oversized request.
    operation = String(requestBody.operation || '').trim().toLowerCase();
    if (operation) {
      if (!scheduled) return response(request,403, { error: 'PUSH_EXIGE_SEGREDO_DO_AGENDADOR' });
      if (operation === 'create') {
        const metadata = requestBody.metadata;
        if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) {
          return response(request,400, { error: 'METADADOS_INVALIDOS' });
        }
        const created = await rpc(client, 'create_data_sync_batch', { payload: { ...metadata, source } });
        return response(request,200, created);
      }

      batchId = String(requestBody.batch_id || '').trim();
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(batchId)) {
        return response(request,400, { error: 'LOTE_INVALIDO' });
      }
      if (operation === 'stage') {
        const records = requestBody.records;
        if (!Array.isArray(records) || records.length < 1 || records.length > 500) {
          return response(request,400, { error: 'BLOCO_INVALIDO' });
        }
        return response(request,200, await rpc(client, 'stage_data_sync_rows', {
          target_batch_id: batchId,
          rows: records
        }));
      }
      if (operation === 'prepare') {
        return response(request,200, await rpc(client, 'prepare_data_sync_batch_retry', {
          target_batch_id: batchId
        }));
      }
      if (operation === 'status') {
        return response(request,200, { batch: await rpc(client, 'get_data_sync_batch', {
          target_batch_id: batchId
        }) });
      }
      if (operation === 'validate') {
        return response(request,200, await rpc(client, 'validate_data_sync_batch_chunk', {
          target_batch_id: batchId,
          chunk_size: 500
        }));
      }
      if (operation === 'commit') {
        return response(request,200, await rpc(client, 'commit_data_sync_batch_chunk', {
          target_batch_id: batchId,
          chunk_size: 500
        }));
      }
      if (operation === 'finalize') {
        const result = await finalizeBatch(client, batchId);
        return response(request,result.failed ? 422 : 200, result.failed
          ? { error: 'LOTE_SEM_LINHAS_VALIDAS', batch: result.batch }
          : { batch: result.batch });
      }
      if (operation === 'fail') {
        const suppliedMessage = String(requestBody.message || 'FALHA_NO_EXECUTOR_EXTERNO').trim();
        const safeFailure = suppliedMessage.replace(/[^A-Z0-9_:-]/gi, '_').slice(0, 160);
        return response(request,200, { batch: await rpc(client, 'mark_data_sync_failure', {
          target_batch_id: batchId,
          error_message: safeFailure || 'FALHA_NO_EXECUTOR_EXTERNO'
        }) });
      }
      return response(request,400, { error: 'OPERACAO_INVALIDA' });
    }

    return response(request,202, await dispatchGithubSync());
  } catch (error) {
    const message = error instanceof Error ? error.message : 'FALHA_NAO_DETALHADA';
    const resumableOperation = ['stage', 'prepare', 'status', 'validate', 'commit'].includes(operation);
    if (batchId && !resumableOperation) {
      await rpc(client, 'mark_data_sync_failure', { target_batch_id: batchId, error_message: message }).catch(() => null);
    } else if (!batchId) {
      await rpc(client, 'mark_data_sync_source_failure', {
        target_source: integrationSource,
        error_message: message
      }).catch(() => null);
    }
    const safeScheduledMessage = message.replace(/[^A-Za-z0-9_:. -]/g, '_').slice(0, 240);
    const safeMessage = message.startsWith('CONFIGURACAO_AUSENTE:')
      ? message
      : scheduled ? safeScheduledMessage : 'Não foi possível concluir a sincronização.';
    return response(request,message.startsWith('CONFIGURACAO_AUSENTE:') ? 503 : 500, {
      error: safeMessage,
      batch_id: batchId || null,
      resumable: resumableOperation
    });
  }
});
