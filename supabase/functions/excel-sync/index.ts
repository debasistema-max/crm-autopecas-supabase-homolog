import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';

const allowedOrigin = Deno.env.get('DATA_SYNC_ALLOWED_ORIGIN') || '*';
const corsHeaders = {
  'Access-Control-Allow-Origin': allowedOrigin,
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-sync-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Content-Type': 'application/json; charset=utf-8'
};

function response(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
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

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (request.method !== 'POST') return response(405, { error: 'METODO_NAO_PERMITIDO' });

  const supabaseUrl = env('SUPABASE_URL');
  const anonKey = env('SUPABASE_ANON_KEY');
  const schedulerSecret = Deno.env.get('DATA_SYNC_SCHEDULER_SECRET') || '';
  const requestSecret = request.headers.get('x-sync-secret') || '';
  const scheduled = Boolean(schedulerSecret && requestSecret && requestSecret === schedulerSecret);
  const authorization = request.headers.get('Authorization') || '';
  if (!scheduled && !authorization.startsWith('Bearer ')) {
    return response(401, { error: 'AUTENTICACAO_OBRIGATORIA' });
  }

  const key = scheduled ? env('SUPABASE_SERVICE_ROLE_KEY') : anonKey;
  const client = createClient(supabaseUrl, key, {
    global: scheduled ? {} : { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false }
  });

  if (!scheduled) {
    const { data: authData, error: authError } = await client.auth.getUser();
    if (authError || !authData.user) return response(401, { error: 'SESSAO_INVALIDA' });
    const canManage = await rpc(client, 'can_manage_data_sync', {});
    if (canManage !== true) return response(403, { error: 'SEM_PERMISSAO_SINCRONIZAR' });
  }

  let batchId = '';
  let integrationSource = 'EXCEL_API';
  let operation = '';
  try {
    const requestBody = await request.json().catch(() => ({}));
    const source = String(requestBody.source || 'EXCEL_API').trim().toUpperCase();
    if (source !== 'EXCEL_API') return response(400, { error: 'FONTE_NAO_SUPORTADA_NESTE_ADAPTER' });
    integrationSource = source;

    // A cloud runner sends small, authenticated chunks. This keeps the XLSX and
    // service-role key out of the browser and avoids a single oversized request.
    operation = String(requestBody.operation || '').trim().toLowerCase();
    if (operation) {
      if (!scheduled) return response(403, { error: 'PUSH_EXIGE_SEGREDO_DO_AGENDADOR' });
      if (operation === 'create') {
        const metadata = requestBody.metadata;
        if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) {
          return response(400, { error: 'METADADOS_INVALIDOS' });
        }
        const created = await rpc(client, 'create_data_sync_batch', { payload: { ...metadata, source } });
        return response(200, created);
      }

      batchId = String(requestBody.batch_id || '').trim();
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(batchId)) {
        return response(400, { error: 'LOTE_INVALIDO' });
      }
      if (operation === 'stage') {
        const records = requestBody.records;
        if (!Array.isArray(records) || records.length < 1 || records.length > 500) {
          return response(400, { error: 'BLOCO_INVALIDO' });
        }
        return response(200, await rpc(client, 'stage_data_sync_rows', {
          target_batch_id: batchId,
          rows: records
        }));
      }
      if (operation === 'prepare') {
        return response(200, await rpc(client, 'prepare_data_sync_batch_retry', {
          target_batch_id: batchId
        }));
      }
      if (operation === 'status') {
        return response(200, { batch: await rpc(client, 'get_data_sync_batch', {
          target_batch_id: batchId
        }) });
      }
      if (operation === 'validate') {
        return response(200, await rpc(client, 'validate_data_sync_batch_chunk', {
          target_batch_id: batchId,
          chunk_size: 500
        }));
      }
      if (operation === 'commit') {
        return response(200, await rpc(client, 'commit_data_sync_batch_chunk', {
          target_batch_id: batchId,
          chunk_size: 500
        }));
      }
      if (operation === 'finalize') {
        const result = await finalizeBatch(client, batchId);
        return response(result.failed ? 422 : 200, result.failed
          ? { error: 'LOTE_SEM_LINHAS_VALIDAS', batch: result.batch }
          : { batch: result.batch });
      }
      if (operation === 'fail') {
        const suppliedMessage = String(requestBody.message || 'FALHA_NO_EXECUTOR_EXTERNO').trim();
        const safeFailure = suppliedMessage.replace(/[^A-Z0-9_:-]/gi, '_').slice(0, 160);
        return response(200, { batch: await rpc(client, 'mark_data_sync_failure', {
          target_batch_id: batchId,
          error_message: safeFailure || 'FALHA_NO_EXECUTOR_EXTERNO'
        }) });
      }
      return response(400, { error: 'OPERACAO_INVALIDA' });
    }

    const adapterUrl = env('DATA_SYNC_ADAPTER_URL');
    const adapterToken = env('DATA_SYNC_ADAPTER_TOKEN');
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 90_000);
    let adapterResponse: Response;
    try {
      adapterResponse = await fetch(adapterUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${adapterToken}` },
        body: JSON.stringify({ source, requested_at: new Date().toISOString() }),
        signal: controller.signal
      });
    } finally {
      clearTimeout(timeout);
    }
    if (!adapterResponse.ok) throw new Error(`ADAPTER_HTTP_${adapterResponse.status}`);
    const payload = await adapterResponse.json();
    if (!Array.isArray(payload.records)) throw new Error('ADAPTER_CONTRATO_INVALIDO:records');
    if (payload.records.length > 50_000) throw new Error('ADAPTER_LIMITE_EXCEDIDO');

    const created = await rpc(client, 'create_data_sync_batch', {
      payload: {
        source,
        source_name: payload.source_name || 'Excel Mestre',
        source_version: payload.source_version,
        source_updated_at: payload.source_updated_at,
        file_hash: payload.file_hash,
        original_filename: payload.original_filename,
        file_size: payload.file_size,
        next_sync_at: payload.next_sync_at || null
      }
    });
    batchId = String(created.batch_id || '');
    if (created.duplicate) {
      return response(200, { duplicate: true, batch: await rpc(client, 'get_data_sync_batch', { target_batch_id: batchId }) });
    }

    for (let index = 0; index < payload.records.length; index += 500) {
      await rpc(client, 'stage_data_sync_rows', {
        target_batch_id: batchId,
        rows: payload.records.slice(index, index + 500)
      });
    }
    const result = await finalizeBatch(client, batchId);
    return response(result.failed ? 422 : 200, result.failed
      ? { error: 'LOTE_SEM_LINHAS_VALIDAS', batch: result.batch }
      : { batch: result.batch });
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
    return response(message.startsWith('CONFIGURACAO_AUSENTE:') ? 503 : 500, {
      error: safeMessage,
      batch_id: batchId || null,
      resumable: resumableOperation
    });
  }
});
