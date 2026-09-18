import { createClient } from 'npm:@supabase/supabase-js@2.116.0';

const allowedOrigins = () => (Deno.env.get('PUBLIC_PORTAL_ALLOWED_ORIGINS') ||
  'https://debasistema-max.github.io,http://localhost:8000,http://127.0.0.1:8000')
  .split(',').map((value) => value.trim()).filter(Boolean);

function corsHeaders(req: Request) {
  const origin = req.headers.get('origin') || '';
  return {
    ...(origin && allowedOrigins().includes(origin) ? { 'Access-Control-Allow-Origin': origin } : {}),
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Vary': 'Origin'
  };
}
const EMAIL_TIMEOUT_MS = Number(Deno.env.get('CADASTRO_EMAIL_TIMEOUT_MS') || '18000');
const SMTP_STEP_TIMEOUT_MS = Number(Deno.env.get('CADASTRO_SMTP_STEP_TIMEOUT_MS') || '8000');

Deno.serve(async (req) => {
  const origin = req.headers.get('origin') || '';
  if (origin && !allowedOrigins().includes(origin)) return json(req, { ok: false, error: 'Origem nao autorizada.' }, 403);
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(req) });
  if (req.method !== 'POST') return json(req, { ok: false, error: 'Metodo nao permitido.' }, 405);
  const contentLength = Number(req.headers.get('content-length') || 0);
  if (contentLength > 22 * 1024 * 1024) return json(req, { ok: false, error: 'Envio acima do limite permitido.' }, 413);

  try {
    const payload = await req.json();
    const cnpj = onlyDigits(payload.cnpj);
    if (cnpj.length !== 14) return json(req, { ok: false, error: 'CNPJ invalido.' }, 400);
    if (!payload.razao_social || !payload.email_compras) {
      return json(req, { ok: false, error: 'Razao social e email de compras sao obrigatorios.' }, 400);
    }
    const supabase = getSupabaseConfig();
    if (!await consumeRateLimit(req, supabase, 'cadastro-ip', 3600, 5) ||
        !await consumeRateLimit(req, supabase, `cadastro-cnpj-${cnpj}`, 3600, 2)) {
      return json(req, { ok: false, error: 'Limite temporario de cadastros atingido. Tente mais tarde.' }, 429);
    }
    const anexos = normalizeAttachments(payload.anexos || []);
    ensureEmailConfigured();

    const recent = await supabaseFetch(
      supabase,
      `/rest/v1/cadastros_clientes?select=id&cnpj=eq.${encodeURIComponent(cnpj)}&created_at=gte.${encodeURIComponent(new Date(Date.now() - 15 * 60 * 1000).toISOString())}&limit=1`
    );
    if ((recent || []).length) {
      return json(req, { ok: false, error: 'Ja existe um cadastro recente para este CNPJ.' }, 429);
    }

    const cadastroPayload = sanitizeCadastroPayload(payload, cnpj);

    const rows = await supabaseFetch(
      supabase,
      '/rest/v1/cadastros_clientes?select=protocolo,razao_social,cnpj,cidade,estado,email_compras,vendedor',
      {
        method: 'POST',
        headers: { Prefer: 'return=representation' },
        body: JSON.stringify(cadastroPayload)
      }
    );
    const data = Array.isArray(rows) ? rows[0] : rows;
    if (!data) throw new Error('Cadastro nao retornou protocolo.');

    const attachments = await uploadAttachments(supabase, data.protocolo, anexos);
    if (attachments.length) {
      await supabaseFetch(
        supabase,
        `/rest/v1/cadastros_clientes?protocolo=eq.${encodeURIComponent(data.protocolo)}`,
        {
          method: 'PATCH',
          headers: { Prefer: 'return=minimal' },
          body: JSON.stringify({ anexos: attachments })
        }
      );
    }

    const emailResult = await sendEmails(supabase, data, payload, anexos);
    return json(req, { ok: true, data: Object.assign({}, data, { anexos: attachments, email: emailResult }) });
  } catch (error) {
    console.error('cadastro-cliente', error);
    return json(req, { ok: false, error: publicError(error) }, 500);
  }
});

async function sendEmails(
  config: { url: string; key: string },
  row: Record<string, string>,
  payload: Record<string, string>,
  attachments: CadastroAttachment[]
) {
  const from = getEmailFrom();
  const to = await getPortalCadastroEmailTo(config);
  const errors: string[] = [];

  const subject = `Novo cadastro ${row.protocolo} - ${row.razao_social || row.cnpj}`;
  const text = [
    `Protocolo: ${row.protocolo}`,
    `Empresa: ${row.razao_social || ''}`,
    `CNPJ: ${row.cnpj || ''}`,
    `Cidade/UF: ${row.cidade || ''}/${row.estado || ''}`,
    `Contato: ${payload.responsavel_compras || ''}`,
    `Telefone: ${payload.telefone || ''}`,
    `WhatsApp: ${payload.whatsapp || ''}`,
    `Email compras: ${payload.email_compras || ''}`,
    `Vendedor: ${payload.vendedor || ''}`,
    `Situacao cadastral: ${payload.situacao_cadastral || ''}`,
    `CNAE: ${payload.cnae || ''}`,
    `Regime especial: ${payload.possui_regime_especial ? 'Sim' : 'Nao'}`,
    `Descricao regime: ${payload.descricao_regime || ''}`,
    `Anexos recebidos: ${attachments.length}`
  ].join('\n');

  const internalEmail = await sendEmailSafe({
    from,
    to,
    subject,
    text,
    attachments
  });
  if (!internalEmail.ok) {
    console.error('Falha ao enviar email ao financeiro', internalEmail.error);
    errors.push(`Falha ao enviar email ao financeiro: ${internalEmail.error || 'erro desconhecido'}`);
    if (attachments.length) {
      const fallbackEmail = await sendEmailSafe({
        from,
        to,
        subject: `[SEM ANEXOS] ${subject}`,
        text: [
          text,
          '',
          'Atencao: o envio com anexos falhou ou expirou.',
          'O cadastro foi salvo no CRM e os documentos devem ser consultados na tela Portal Clientes/Cadastros.'
        ].join('\n')
      }, Math.max(8000, Math.floor(EMAIL_TIMEOUT_MS / 2)));
      if (!fallbackEmail.ok) {
        console.error('Falha ao enviar fallback sem anexos', fallbackEmail.error);
        errors.push(`Falha ao enviar aviso sem anexos: ${fallbackEmail.error || 'erro desconhecido'}`);
      }
    }
  }

  const customerRecipients = Array.from(new Set([
    strictEmail(payload.email_compras),
    payload.email_financeiro ? strictEmail(payload.email_financeiro) : ''
  ].filter(Boolean)));

  for (const customerTo of customerRecipients) {
    const customerEmail = await sendEmailSafe({
      from,
      to: customerTo,
      subject: `Recebemos seu cadastro - ${row.protocolo}`,
      text: `Recebemos seu cadastro. Protocolo: ${row.protocolo}. Nossa equipe ira analisar e entrar em contato.`
    }, Math.max(8000, Math.floor(EMAIL_TIMEOUT_MS / 2)));
    if (!customerEmail.ok) {
      console.error('Falha ao enviar email ao cliente', customerEmail.error);
      errors.push(`Falha ao enviar confirmacao para ${customerTo}.`);
    }
  }

  return {
    ok: errors.length === 0,
    errors
  };
}

async function getPortalCadastroEmailTo(config: { url: string; key: string }) {
  const fallback = String(Deno.env.get('CADASTRO_EMAIL_TO') || '').trim();
  try {
    const rows = await supabaseFetch(
      config,
      '/rest/v1/settings?select=value&key=eq.portal_cadastros&limit=1'
    );
    const value = Array.isArray(rows) && rows[0] ? rows[0].value : null;
    const email = String(value?.email_principal || '').trim();
    if (email) return email;
  } catch (error) {
    console.error('Falha ao ler email principal do portal', error.message || error);
  }
  if (fallback) return fallback;
  throw new Error('CADASTRO_EMAIL_TO nao configurado.');
}

function ensureEmailConfigured() {
  if (!isGmailConfigured() && !Deno.env.get('RESEND_API_KEY')) {
    throw new Error('Envio de email nao configurado no Supabase.');
  }
}

type EmailAttachment = {
  name?: string;
  type?: string;
  content?: string;
};

type CadastroAttachment = EmailAttachment & {
  field?: unknown;
  label?: unknown;
  size?: number;
};

type EmailMessage = {
  from: string;
  to: string;
  subject: string;
  text: string;
  attachments?: EmailAttachment[];
};

async function sendEmail(message: EmailMessage) {
  if (isGmailConfigured()) return sendEmailWithGmail(message);
  return sendEmailWithResend(message);
}

async function sendEmailSafe(message: EmailMessage, timeoutMs = EMAIL_TIMEOUT_MS) {
  return await withTimeout(
    sendEmail(message),
    timeoutMs,
    `Tempo limite ao enviar email para ${message.to}.`
  ).catch((error) => ({ ok: false, error: error.message || 'Erro ao enviar email.' }));
}

async function sendEmailWithGmail(message: EmailMessage) {
  const hostname = Deno.env.get('GMAIL_SMTP_HOST') || 'smtp.gmail.com';
  const port = Number(Deno.env.get('GMAIL_SMTP_PORT') || '465');
  const username = Deno.env.get('GMAIL_SMTP_USER') || '';
  const password = Deno.env.get('GMAIL_SMTP_APP_PASSWORD') || '';
  const conn = await withTimeout(
    Deno.connectTls({ hostname, port }),
    SMTP_STEP_TIMEOUT_MS,
    'Tempo limite ao conectar no SMTP Gmail.'
  );
  try {
    await readSmtp(conn);
    await smtp(conn, `EHLO ${hostname}`);
    await smtp(conn, 'AUTH LOGIN', 334);
    await smtp(conn, base64(username), 334);
    await smtp(conn, base64(password), 235);
    await smtp(conn, `MAIL FROM:<${extractEmailAddress(message.from)}>`);
    await smtp(conn, `RCPT TO:<${strictEmail(message.to)}>`);
    await smtp(conn, 'DATA', 354);
    await smtp(conn, buildMimeMessage(message), 250);
    await smtp(conn, 'QUIT', 221).catch(() => undefined);
    return { ok: true };
  } catch (error) {
    return { ok: false, error: error.message || 'Erro SMTP Gmail.' };
  } finally {
    try {
      conn.close();
    } catch (_error) {
      // Ignora falha ao fechar a conexao SMTP.
    }
  }
}

async function sendEmailWithResend(message: EmailMessage) {
  const resendKey = Deno.env.get('RESEND_API_KEY');
  if (!resendKey) return { ok: false, error: 'RESEND_API_KEY nao configurado.' };
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), EMAIL_TIMEOUT_MS);
  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${resendKey}`,
      'Content-Type': 'application/json'
    },
    signal: controller.signal,
    body: JSON.stringify({
      from: message.from,
      to: strictEmail(message.to),
      subject: message.subject,
      text: message.text,
      attachments: (message.attachments || []).map((attachment) => ({
        filename: sanitizeFileName(String(attachment.name || 'documento')),
        content: attachment.content,
        content_type: attachment.type || 'application/octet-stream'
      }))
    })
  }).finally(() => clearTimeout(timer));
  if (response.ok) return { ok: true };
  return {
    ok: false,
    error: `${response.status} ${await response.text().catch(() => '')}`.trim()
  };
}

function isGmailConfigured() {
  return Boolean(Deno.env.get('GMAIL_SMTP_USER') && Deno.env.get('GMAIL_SMTP_APP_PASSWORD'));
}

function getEmailFrom() {
  const from = String(Deno.env.get('CADASTRO_EMAIL_FROM') || Deno.env.get('GMAIL_SMTP_USER') || '').trim();
  if (!from) throw new Error('CADASTRO_EMAIL_FROM ou GMAIL_SMTP_USER nao configurado.');
  return from;
}

function getSupabaseConfig() {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) throw new Error('Supabase nao configurado.');
  return { url, key };
}

async function consumeRateLimit(
  req: Request,
  config: { url: string; key: string },
  endpoint: string,
  windowSeconds: number,
  maxRequests: number
) {
  const client = createClient(config.url, config.key, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await client.rpc('consume_public_endpoint_rate_limit', {
    p_endpoint: endpoint.startsWith('cadastro-cnpj-') ? 'cadastro-cnpj' : endpoint,
    p_subject_hash: await requestSubjectHash(req, endpoint),
    p_window_seconds: windowSeconds,
    p_max_requests: maxRequests
  });
  if (error) throw error;
  return data === true;
}

async function requestSubjectHash(req: Request, discriminator: string) {
  const ip = (req.headers.get('x-forwarded-for') || req.headers.get('cf-connecting-ip') || 'unknown')
    .split(',')[0].trim().slice(0, 80);
  const salt = Deno.env.get('PUBLIC_RATE_LIMIT_SALT') || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  const bytes = new TextEncoder().encode(`${salt}:${discriminator}:${ip}`);
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)))
    .map((value) => value.toString(16).padStart(2, '0')).join('');
}

function sanitizeCadastroPayload(payload: Record<string, unknown>, cnpj: string) {
  const text = (key: string, max = 250) => cleanText(payload[key], max);
  const estado = text('estado', 2).toUpperCase();
  if (estado && !/^[A-Z]{2}$/.test(estado)) throw new Error('UF_INVALIDA');
  return {
    cnpj,
    razao_social: text('razao_social', 180),
    nome_fantasia: text('nome_fantasia', 180),
    ie: text('ie', 40), telefone: text('telefone', 40), whatsapp: text('whatsapp', 40),
    email_compras: strictEmail(payload.email_compras),
    email_financeiro: payload.email_financeiro ? strictEmail(payload.email_financeiro) : null,
    responsavel_compras: text('responsavel_compras', 120),
    responsavel_financeiro: text('responsavel_financeiro', 120),
    cep: onlyDigits(payload.cep).slice(0,8), endereco: text('endereco', 220), numero: text('numero', 30),
    bairro: text('bairro', 120), complemento: text('complemento', 120), cidade: text('cidade', 120), estado,
    site: text('site', 300), instagram: text('instagram', 120),
    como_conheceu: text('como_conheceu', 120), segmento: text('segmento', 120),
    transportadora: text('transportadora', 180), vendedor: text('vendedor', 120),
    prazo_desejado: text('prazo_desejado', 120), volume_estimado: text('volume_estimado', 120),
    observacoes: text('observacoes', 1500), atividade_principal: text('atividade_principal', 300),
    cnae: text('cnae', 30), situacao_cadastral: text('situacao_cadastral', 80),
    possui_regime_especial: payload.possui_regime_especial === true,
    descricao_regime: text('descricao_regime', 1000), estados_regime: text('estados_regime', 120),
    origem: 'portal_publico', anexos: [],
    dados_api_cnpj: sanitizeCnpjSnapshot(payload.dados_api_cnpj)
  };
}

function sanitizeCnpjSnapshot(value: unknown) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const input = value as Record<string, unknown>;
  const keys = ['fonte','razao_social','nome_fantasia','cnae_fiscal','cnae_fiscal_descricao',
    'descricao_situacao_cadastral','cep','logradouro','numero','complemento','bairro','municipio','uf'];
  return Object.fromEntries(keys.map((key) => [key, cleanText(input[key], 300)]));
}

function cleanText(value: unknown, max: number) {
  return String(value || '').replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0,max);
}

function strictEmail(value: unknown) {
  const email = String(value || '').trim().toLowerCase();
  if (email.length>254 || /[\r\n\0]/.test(email) || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    throw new Error('EMAIL_INVALIDO');
  }
  return email;
}

function normalizeAttachments(input: unknown[]) {
  if (!Array.isArray(input)) throw new Error('Lista de anexos invalida.');
  if (input.length > 5) throw new Error('Envie no maximo 5 arquivos.');
  let totalBytes = 0;
  const attachments: CadastroAttachment[] = [];
  for (const attachment of input as Array<Record<string, unknown>>) {
    const declaredSize = Number(attachment.size || 0);
    const type = String(attachment.type || '');
    const content = String(attachment.content || '').replace(/\s/g, '');
    const name = sanitizeFileName(String(attachment.name || 'documento'));
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(content) || content.length % 4 !== 0) {
      throw new Error(`Arquivo ${name} com conteudo invalido.`);
    }
    const padding = content.endsWith('==') ? 2 : content.endsWith('=') ? 1 : 0;
    const size = Math.max(0, Math.floor(content.length * 3 / 4) - padding);
    if (declaredSize && Math.abs(declaredSize-size)>2) throw new Error(`Arquivo ${name} com tamanho invalido.`);
    totalBytes += size;
    if (size > 5 * 1024 * 1024) throw new Error(`Arquivo ${name} ultrapassa 5 MB.`);
    if (totalBytes > 15 * 1024 * 1024) throw new Error('O total dos arquivos nao pode ultrapassar 15 MB.');
    if (!['application/pdf', 'image/jpeg', 'image/png', 'image/webp'].includes(type)) {
      throw new Error(`Arquivo ${name} deve ser PDF, JPG, PNG ou WEBP.`);
    }
    if (!content) {
      throw new Error(`Arquivo ${name} sem conteudo.`);
    }
    attachments.push({
      field: attachment.field,
      label: attachment.label,
      name,
      type,
      size,
      content
    });
  }
  return attachments;
}

async function uploadAttachments(
  config: { url: string; key: string },
  protocolo: string,
  attachments: CadastroAttachment[]
) {
  const uploaded = [];
  for (const attachment of attachments) {
    const fileName = sanitizeFileName(String(attachment.name || 'documento'));
    const storagePath = `${protocolo}/${crypto.randomUUID()}-${fileName}`;
    const bytes = base64ToBytes(String(attachment.content || ''));
    const response = await fetch(`${config.url}/storage/v1/object/cadastros-clientes/${storagePath}`, {
      method: 'PUT',
      headers: {
        apikey: config.key,
        Authorization: `Bearer ${config.key}`,
        'Content-Type': String(attachment.type || 'application/octet-stream'),
        'x-upsert': 'false'
      },
      body: bytes
    });
    if (!response.ok) {
      const body = await response.text().catch(() => '');
      throw new Error(`Falha ao salvar anexo ${fileName}: ${body || response.status}`);
    }
    uploaded.push({
      field: attachment.field,
      label: attachment.label,
      name: fileName,
      type: attachment.type,
      size: attachment.size,
      bucket: 'cadastros-clientes',
      path: storagePath
    });
  }
  return uploaded;
}

function sanitizeFileName(name: string) {
  return name
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-zA-Z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 120) || 'documento';
}

function base64ToBytes(value: string) {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

async function supabaseFetch(
  config: { url: string; key: string },
  path: string,
  options: RequestInit = {}
) {
  const response = await fetch(`${config.url}${path}`, {
    ...options,
    headers: Object.assign({
      apikey: config.key,
      Authorization: `Bearer ${config.key}`,
      'Content-Type': 'application/json'
    }, options.headers || {})
  });
  const text = await response.text();
  const body = text ? JSON.parse(text) : null;
  if (!response.ok) {
    throw new Error(body?.message || body?.error || 'Erro no banco de dados.');
  }
  return body;
}

async function smtp(conn: Deno.TlsConn, command: string, expected = 250) {
  await conn.write(new TextEncoder().encode(command + '\r\n'));
  const response = await readSmtp(conn);
  if (!response.startsWith(String(expected))) {
    throw new Error(`SMTP ${response.trim()}`);
  }
  return response;
}

async function readSmtp(conn: Deno.TlsConn) {
  const decoder = new TextDecoder();
  const buffer = new Uint8Array(4096);
  let text = '';
  while (true) {
    const count = await withTimeout(
      conn.read(buffer),
      SMTP_STEP_TIMEOUT_MS,
      'Tempo limite aguardando resposta SMTP.'
    );
    if (count === null) throw new Error('Conexao SMTP encerrada.');
    text += decoder.decode(buffer.subarray(0, count));
    const lines = text.split(/\r?\n/).filter(Boolean);
    const last = lines[lines.length - 1] || '';
    if (/^\d{3} /.test(last)) return text;
  }
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number, message: string): Promise<T> {
  let timer: number | undefined;
  const timeout = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => reject(new Error(message)), timeoutMs);
  });
  return Promise.race([promise, timeout]).finally(() => {
    if (timer !== undefined) clearTimeout(timer);
  });
}

function buildMimeMessage(message: EmailMessage) {
  const safeFrom = cleanHeader(message.from, 254);
  const safeTo = strictEmail(message.to);
  const safeSubject = cleanHeader(message.subject, 180);
  const attachments = message.attachments || [];
  if (!attachments.length) {
    return [
      `From: ${safeFrom}`,
      `To: ${safeTo}`,
      `Subject: ${safeSubject}`,
      'MIME-Version: 1.0',
      'Content-Type: text/plain; charset=UTF-8',
      'Content-Transfer-Encoding: 8bit',
      '',
      dotStuff(message.text),
      '.'
    ].join('\r\n');
  }

  const boundary = `crm-${crypto.randomUUID()}`;
  const parts = [
    `From: ${safeFrom}`,
    `To: ${safeTo}`,
    `Subject: ${safeSubject}`,
    'MIME-Version: 1.0',
    `Content-Type: multipart/mixed; boundary="${boundary}"`,
    '',
    `--${boundary}`,
    'Content-Type: text/plain; charset=UTF-8',
    'Content-Transfer-Encoding: 8bit',
    '',
    dotStuff(message.text)
  ];

  for (const attachment of attachments) {
    const fileName = sanitizeFileName(String(attachment.name || 'documento'));
    parts.push(
      `--${boundary}`,
      `Content-Type: ${attachment.type || 'application/octet-stream'}; name="${fileName}"`,
      'Content-Transfer-Encoding: base64',
      `Content-Disposition: attachment; filename="${fileName}"`,
      '',
      wrapBase64(String(attachment.content || ''))
    );
  }

  parts.push(
    `--${boundary}--`,
    '.'
  );

  return parts.join('\r\n');
}

function extractEmailAddress(value: string) {
  const match = value.match(/<([^>]+)>/);
  return strictEmail((match ? match[1] : value).trim());
}

function cleanHeader(value: unknown, max: number) {
  return String(value || '').replace(/[\r\n\0]+/g, ' ').trim().slice(0,max);
}

function base64(value: string) {
  return btoa(value);
}

function wrapBase64(value: string) {
  return value.replace(/\s/g, '').replace(/(.{1,76})/g, '$1\r\n').trim();
}

function dotStuff(value: string) {
  return value.replace(/^\./gm, '..');
}

function publicError(error: unknown) {
  const message = error instanceof Error ? error.message : '';
  const known = ['EMAIL_INVALIDO','UF_INVALIDA'];
  return known.includes(message) ? 'Dados invalidos. Revise os campos informados.' : 'Nao foi possivel concluir o cadastro.';
}

function json(req: Request, body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: Object.assign({ 'Content-Type': 'application/json; charset=utf-8' }, corsHeaders(req))
  });
}

function onlyDigits(value: unknown) {
  return String(value || '').replace(/\D/g, '');
}
