const PRODUCT_IMPORT_LOOKUP_CHUNK_SIZE = 100;

async function supabaseLogin(usuario, senha) {
  if (!isSupabaseReady()) throw new Error('Supabase nao configurado.');
  const login = String(usuario || '').trim();
  if (!login || !senha) throw new Error('Usuario ou senha invalidos.');
  try {
    const email = await supabaseResolveLoginEmail(login);
    if (!email) throw new Error('INVALID_LOGIN');
    const { data, error } = await supabaseClient.auth.signInWithPassword({ email, password: senha });
    if (error) throw error;
    const profile = await supabaseCurrentProfile(data.user.id);
    await supabaseClient.from('logs').insert({
      user_id: data.user.id,
      usuario: profile.usuario,
      acao: 'LOGIN',
      entidade: 'auth',
      id_entidade: data.user.id,
      dados_novos: { email: data.user.email, ip: null }
    });
    return supabaseSessionFromProfile(data.user, profile);
  } catch (error) {
    throw new Error('Usuario ou senha invalidos.');
  }
}

async function supabaseResolveLoginEmail(login) {
  if (String(login || '').includes('@')) return String(login || '').trim();
  const { data, error } = await supabaseClient.rpc('resolve_login_email', { login_text: login });
  if (error) throw error;
  return data || null;
}

async function supabaseLogout() {
  if (!isSupabaseReady()) return;
  try {
    await supabaseLog('LOGOUT', 'auth', getSessionId(), { ip: null });
  } catch (error) {
    console.warn(error);
  }
  await supabaseClient.auth.signOut();
}

async function supabaseValidateSession() {
  if (!isSupabaseReady()) return null;
  const { data, error } = await supabaseClient.auth.getUser();
  if (error || !data.user) return null;
  const profile = await supabaseCurrentProfile(data.user.id);
  return supabaseSessionFromProfile(data.user, profile);
}

async function supabaseCurrentProfile(userId) {
  const { data, error } = await supabaseClient
    .from('profiles')
    .select('id, usuario, nome, email, perfil, ativo')
    .eq('id', userId)
    .single();
  if (error) throw error;
  if (!data || data.ativo === false) throw new Error('Usuario inativo.');
  return data;
}

async function supabaseModules(perfil) {
  const { data, error } = await supabaseClient
    .from('role_permissions')
    .select('modulo')
    .eq('perfil', perfil)
    .eq('permitido', true);
  if (error) throw error;
  return (data || []).map((row) => row.modulo);
}

async function supabaseSessionFromProfile(user, profile) {
  return {
    sessionId: user.id,
    usuario: profile.usuario,
    nome: profile.nome,
    email: profile.email || user.email,
    perfil: profile.perfil,
    modules: await supabaseModules(profile.perfil)
  };
}

async function supabaseGetDashboard() {
  const { data, error } = await supabaseClient.rpc('get_dashboard_summary');
  if (error) throw error;
  return data || {};
}

let commercialDashboardV2CAvailability = null;

async function supabaseGetCommercialDashboardSummary(filters = {}) {
  const normalizedFilters = normalizeCommercialDashboardFilters(filters);

  if (commercialDashboardV2CAvailability !== false) {
    const { data, error } = await supabaseClient.rpc('get_dashboard_summary', {
      filters: normalizedFilters
    });

    if (!error) {
      commercialDashboardV2CAvailability = true;
      return data || {};
    }

    if (!isMissingCommercialDashboardRpc(error)) {
      throw formatCommercialDashboardError(error);
    }

    commercialDashboardV2CAvailability = false;
  }

  const { data, error } = await supabaseClient.rpc('get_commercial_dashboard_summary', {
    filters: normalizedFilters
  });
  if (error) throw formatCommercialDashboardError(error);
  return Object.assign({}, data || {}, {
    meta: { fallback: true, version: '2.1' }
  });
}

function normalizeCommercialDashboardFilters(filters = {}) {
  return {
    date_from: filters.dateFrom || filters.date_from || '',
    date_to: filters.dateTo || filters.date_to || '',
    region: filters.region || '',
    seller_id: filters.sellerId || filters.seller_id || ''
  };
}

function isMissingCommercialDashboardRpc(error) {
  const message = String(error?.message || '').toLowerCase();
  return error?.code === 'PGRST202'
    || (message.includes('get_dashboard_summary') && message.includes('could not find'));
}

function formatCommercialDashboardError(error) {
  const message = String(error?.message || '');
  console.error('Erro no Dashboard Comercial:', {
    message: error?.message,
    code: error?.code,
    details: error?.details,
    hint: error?.hint
  });
  if (message.toLowerCase().includes('could not find the function')) {
    return new Error('O resumo do Dashboard Comercial nao esta disponivel no Supabase.');
  }
  if (message.includes('SEM_PERMISSAO')) {
    return new Error('Voce nao tem permissao para carregar o Dashboard Comercial.');
  }
  if (message.includes('PERIODO_INVALIDO')) {
    return new Error('A data final precisa ser maior ou igual a data inicial.');
  }
  if (message.includes('DATA_INVALIDA')) {
    return new Error('Informe datas validas para carregar o dashboard.');
  }
  if (message.includes('PERIODO_MUITO_LONGO')) {
    return new Error('Selecione um periodo menor para carregar o dashboard.');
  }
  if (message.includes('REGIAO_INVALIDA')) {
    return new Error('Regiao invalida. Use SP ou PR.');
  }
  if (message.includes('VENDEDOR_INVALIDO')) {
    return new Error('Vendedor invalido para o filtro informado.');
  }
  if (message.includes('FILTROS_INVALIDOS')) {
    return new Error('Os filtros informados para o dashboard sao invalidos.');
  }
  if (message.includes('FILTRO_VENDEDOR_NAO_PERMITIDO')) {
    return new Error('Seu perfil nao pode consultar indicadores de outro usuario.');
  }
  return new Error('Nao foi possivel carregar o Dashboard Comercial.');
}

async function supabaseListImportBatchesReport(filters = {}) {
  const { data, error } = await supabaseClient.rpc('get_products_import_batches_report', {
    filters: normalizeImportBatchFilters(filters)
  });
  if (error) throw formatImportBatchReportError(error);
  return data || { summary: {}, pagination: {}, rows: [] };
}

async function supabaseGetImportBatchDetails(batchId, params = {}) {
  if (!batchId) throw new Error('Lote nao informado.');
  const { data, error } = await supabaseClient.rpc('get_products_import_batch_details', {
    batch_id: batchId,
    page: Number(params.page || 1),
    page_size: Number(params.pageSize || 25)
  });
  if (error) throw formatImportBatchReportError(error);
  return data || { batch: {}, items: [], itemsPagination: {}, audit: [] };
}

function normalizeImportBatchFilters(filters = {}) {
  const allowedPageSizes = [25, 50, 100];
  const pageSize = Number(filters.pageSize || filters.page_size || 25);
  return {
    page: Number(filters.page || 1),
    page_size: allowedPageSizes.includes(pageSize) ? pageSize : 25,
    date_from: filters.dateFrom || filters.date_from || '',
    date_to: filters.dateTo || filters.date_to || '',
    status: filters.status || '',
    region: filters.region || '',
    user: filters.user || '',
    search: filters.search || '',
    source_name: filters.sourceName || filters.source_name || '',
    error_only: filters.errorOnly === true,
    imported_only: filters.importedOnly === true,
    pending_only: filters.pendingOnly === true
  };
}

function formatImportBatchReportError(error) {
  const message = String(error?.message || '');
  console.error('Erro no relatorio de lotes de importacao:', {
    message: error?.message,
    code: error?.code,
    details: error?.details,
    hint: error?.hint
  });
  if (message.includes('SEM_PERMISSAO_VISUALIZAR_LOTES')) {
    return new Error('Voce nao tem permissao para visualizar os lotes de importacao.');
  }
  if (message.toLowerCase().includes('could not find the function')) {
    return new Error('RPC de relatorio de lotes nao encontrada. Rode a migration 021 no Supabase.');
  }
  return new Error('Nao foi possivel carregar os lotes de importacao.');
}

async function supabaseSearchProducts(params) {
  if (
    params.context === 'produtos'
    || params.listaGeral
    || params.grupo
    || params.linha
    || params.marca
    || params.montadora
    || params.disponibilidade
    || params.comFoto
    || params.semFoto
    || params.favoritos
  ) {
    return supabaseListProducts(params);
  }
  const { data, error } = await supabaseClient.rpc('search_products', {
    term: params.termo || params.q || '',
    region: params.regiao || 'SP',
    only_available: params.disponiveis === true,
    limit_count: Number(params.limite || 40)
  });
  if (error) throw error;
  return data || [];
}

async function supabaseListProductFilters() {
  const cached = getStaticCache('productFiltersV2', 10 * 60 * 1000);
  if (cached && cached.marcas && cached.montadoras) return cached;
  const { data, error } = await supabaseClient.rpc('get_product_filters');
  if (error) throw error;
  const filters = data || { grupos: [], linhas: [], marcas: [], montadoras: [] };
  if (!filters.marcas || !filters.montadoras) {
    const { data: products, error: productError } = await supabaseClient
      .from('products')
      .select('marca, montadora')
      .limit(2000);
    if (!productError) {
      filters.marcas = uniqueSorted((products || []).map((product) => product.marca));
      filters.montadoras = uniqueSorted((products || []).map((product) => product.montadora));
    }
  }
  setStaticCache('productFiltersV2', filters);
  return filters;
}

async function supabaseListProducts(params = {}) {
  const region = params.regiao || 'SP';
  const limit = Math.min(Math.max(Number(params.limite || params.pageSize || 60), 1), 200);
  const offset = Math.max(Number(params.offset || 0), 0);
  let query = supabaseClient
    .from('products')
    .select('codigo, descricao, marca, aplicacao, ano, estoque, estoque_quantidade, preco_sp, preco_pr, status_estoque, status_cadastro, url_imagem, grupo, categoria, montadora, detalhes, oem, similar')
    .order('codigo', { ascending: true })
    .range(offset, offset + limit - 1);

  const term = String(params.termo || params.q || '').trim();
  if (term) {
    const pattern = `%${escapePostgrestFilter(term)}%`;
    query = query.or([
      `codigo.ilike.${pattern}`,
      `descricao.ilike.${pattern}`,
      `marca.ilike.${pattern}`,
      `aplicacao.ilike.${pattern}`,
      `grupo.ilike.${pattern}`,
      `categoria.ilike.${pattern}`,
      `montadora.ilike.${pattern}`,
      `oem.ilike.${pattern}`,
      `similar.ilike.${pattern}`,
      `detalhes.ilike.${pattern}`,
      `ano.ilike.${pattern}`
    ].join(','));
  }
  if (params.marca) query = query.eq('marca', params.marca);
  if (params.grupo) query = query.eq('grupo', params.grupo);
  if (params.linha) query = query.eq('categoria', params.linha);
  if (params.montadora) query = query.eq('montadora', params.montadora);
  if (params.disponiveis === true || params.disponibilidade === 'disponivel') query = query.gt('estoque_quantidade', 0);
  if (params.disponibilidade === 'zerado') query = query.or('estoque_quantidade.eq.0,estoque_quantidade.is.null');
  if (params.disponibilidade === 'baixo') query = query.gt('estoque_quantidade', 0).lte('estoque_quantidade', 5);
  if (params.disponibilidade === 'alto') query = query.gt('estoque_quantidade', 20);
  if (params.comOem === true) query = query.not('oem', 'is', null).neq('oem', '');
  if (params.comFoto === true) query = query.not('url_imagem', 'is', null).neq('url_imagem', '');
  if (params.semFoto === true) query = query.or('url_imagem.is.null,url_imagem.eq.');

  if (params.favoritos === true) {
    const favoriteCodes = await supabaseListProductFavorites();
    if (!favoriteCodes.length) return [];
    query = query.in('codigo', favoriteCodes.slice(0, 500));
  }

  const { data, error } = await query;
  if (error) throw error;
  return (data || []).map((product) => Object.assign({}, product, {
    linha: product.categoria,
    preco: region === 'PR' ? product.preco_pr : product.preco_sp
  }));
}

const productExperienceAvailability = {
  favorites: null,
  recent: null,
  history: null,
  topSelling: null,
  warned: new Set()
};

async function supabaseListProductFavorites() {
  if (productExperienceAvailability.favorites === false) return getLocalProductFavorites();
  try {
    const { data, error } = await supabaseClient
      .from('product_favorites')
      .select('codigo')
      .order('created_at', { ascending: false });
    if (error) throw error;
    productExperienceAvailability.favorites = true;
    return (data || []).map((row) => row.codigo).filter(Boolean);
  } catch (error) {
    if (isMissingSupabaseResource(error)) {
      markProductExperienceUnavailable('favorites');
      return getLocalProductFavorites();
    }
    throw error;
  }
}

async function supabaseToggleProductFavorite(codigo, enabled) {
  const code = String(codigo || '').trim();
  if (!code) return supabaseListProductFavorites();
  if (productExperienceAvailability.favorites === false) {
    return setLocalProductFavorite(code, enabled);
  }
  try {
    if (enabled) {
      const { error } = await supabaseClient
        .from('product_favorites')
        .insert({ user_id: getSessionId(), codigo: code });
      if (error && error.code !== '23505') throw error;
    } else {
      const { error } = await supabaseClient
        .from('product_favorites')
        .delete()
        .eq('codigo', code)
        .eq('user_id', getSessionId());
      if (error) throw error;
    }
    productExperienceAvailability.favorites = true;
    return supabaseListProductFavorites();
  } catch (error) {
    if (isMissingSupabaseResource(error)) {
      markProductExperienceUnavailable('favorites');
      return setLocalProductFavorite(code, enabled);
    }
    throw error;
  }
}

async function supabaseRegisterProductView(codigo) {
  const code = String(codigo || '').trim();
  if (!code) return;
  pushLocalProductRecent(code);
  if (productExperienceAvailability.recent === false) return;
  try {
    const { error } = await supabaseClient.rpc('record_product_recent_view', {
      product_code: code,
      max_items: 30
    });
    if (error) throw error;
    productExperienceAvailability.recent = true;
  } catch (error) {
    if (isMissingSupabaseResource(error)) {
      markProductExperienceUnavailable('recent');
      return;
    }
    throw error;
  }
}

async function supabaseListRecentProducts(limitCount = 6) {
  if (productExperienceAvailability.recent === false) return supabaseProductsByCodes(getLocalProductRecent().slice(0, limitCount));
  try {
    const { data, error } = await supabaseClient
      .from('product_recent_views')
      .select('codigo, viewed_at, view_count, products(codigo, descricao, marca, aplicacao, montadora, oem, similar, url_imagem, estoque, estoque_quantidade, preco_sp, preco_pr)')
      .order('viewed_at', { ascending: false })
      .limit(Math.min(Math.max(Number(limitCount || 6), 1), 30));
    if (error) throw error;
    productExperienceAvailability.recent = true;
    return (data || []).map((row) => Object.assign({}, row.products || {}, {
      viewed_at: row.viewed_at,
      view_count: row.view_count
    })).filter((product) => product.codigo);
  } catch (error) {
    if (isMissingSupabaseResource(error)) {
      markProductExperienceUnavailable('recent');
      return supabaseProductsByCodes(getLocalProductRecent().slice(0, limitCount));
    }
    throw error;
  }
}

async function supabaseProductsByCodes(codes) {
  const cleanCodes = Array.from(new Set((codes || []).map((code) => String(code || '').trim()).filter(Boolean)));
  if (!cleanCodes.length) return [];
  const { data, error } = await supabaseClient
    .from('products')
    .select('codigo, descricao, marca, aplicacao, montadora, oem, similar, url_imagem, estoque, estoque_quantidade, preco_sp, preco_pr')
    .in('codigo', cleanCodes);
  if (error) return [];
  const byCode = new Map((data || []).map((product) => [product.codigo, product]));
  return cleanCodes.map((code) => byCode.get(code)).filter(Boolean);
}

async function supabaseGetProductHistory(codigo) {
  const empty = { prices: [], stock: [] };
  if (productExperienceAvailability.history === false) return empty;
  try {
    const [pricesResult, stockResult] = await Promise.all([
      supabaseClient.rpc('get_product_price_history', { product_code: codigo, limit_count: 12 }),
      supabaseClient.rpc('get_product_stock_history', { product_code: codigo, limit_count: 12 })
    ]);
    if (pricesResult.error) throw pricesResult.error;
    if (stockResult.error) throw stockResult.error;
    productExperienceAvailability.history = true;
    return {
      prices: Array.isArray(pricesResult.data) ? pricesResult.data : [],
      stock: Array.isArray(stockResult.data) ? stockResult.data : []
    };
  } catch (error) {
    if (isMissingSupabaseResource(error)) {
      markProductExperienceUnavailable('history');
      return empty;
    }
    throw error;
  }
}

async function supabaseGetTopSellingProducts(limitCount = 6) {
  if (productExperienceAvailability.topSelling === false) return [];
  try {
    const { data, error } = await supabaseClient.rpc('get_top_selling_products', {
      limit_count: Math.min(Math.max(Number(limitCount || 6), 1), 20)
    });
    if (error) throw error;
    productExperienceAvailability.topSelling = true;
    return data || [];
  } catch (error) {
    if (isMissingSupabaseResource(error)) {
      markProductExperienceUnavailable('topSelling');
      return [];
    }
    throw error;
  }
}

function isMissingSupabaseResource(error) {
  const message = String(error?.message || error?.details || '');
  return error?.status === 404
    || error?.code === 'PGRST202'
    || error?.code === 'PGRST205'
    || message.toLowerCase().includes('could not find')
    || message.toLowerCase().includes('schema cache');
}

function markProductExperienceUnavailable(feature) {
  productExperienceAvailability[feature] = false;
  if (productExperienceAvailability.warned.has(feature)) return;
  productExperienceAvailability.warned.add(feature);
  console.info('Modulo Produtos: recurso complementar indisponivel ate aplicar a migration 024:', feature);
}

function getLocalProductFavorites() {
  try {
    return JSON.parse(localStorage.getItem(localProductKey('favorites')) || '[]');
  } catch (error) {
    return [];
  }
}

function setLocalProductFavorite(codigo, enabled) {
  const favorites = new Set(getLocalProductFavorites());
  if (enabled) favorites.add(codigo);
  else favorites.delete(codigo);
  const next = Array.from(favorites).slice(0, 200);
  localStorage.setItem(localProductKey('favorites'), JSON.stringify(next));
  return next;
}

function getLocalProductRecent() {
  try {
    return JSON.parse(localStorage.getItem(localProductKey('recent')) || '[]');
  } catch (error) {
    return [];
  }
}

function pushLocalProductRecent(codigo) {
  const next = [codigo].concat(getLocalProductRecent().filter((code) => code !== codigo)).slice(0, 30);
  localStorage.setItem(localProductKey('recent'), JSON.stringify(next));
}

function localProductKey(type) {
  return 'crmProductExperience:' + type + ':' + (getSessionId() || 'anon');
}

function uniqueSorted(values) {
  return Array.from(new Set((values || []).map((value) => String(value || '').trim()).filter(Boolean)))
    .sort((a, b) => a.localeCompare(b, 'pt-BR'));
}

function escapePostgrestFilter(value) {
  return String(value || '').replace(/[(),]/g, ' ');
}

function getStaticCache(key, maxAgeMs) {
  try {
    const raw = localStorage.getItem('crmStaticCache:' + key);
    if (!raw) return null;
    const cached = JSON.parse(raw);
    if (!cached || Date.now() - Number(cached.createdAt || 0) > maxAgeMs) return null;
    return cached.value;
  } catch (error) {
    return null;
  }
}

function setStaticCache(key, value) {
  try {
    localStorage.setItem('crmStaticCache:' + key, JSON.stringify({
      createdAt: Date.now(),
      value
    }));
  } catch (error) {
    console.warn(error);
  }
}

function clearStaticCache(key) {
  try {
    localStorage.removeItem('crmStaticCache:' + key);
  } catch (error) {
    console.warn(error);
  }
}

function onlyDigits(value) {
  return String(value || '').replace(/\D/g, '');
}

const commercialFlowAvailability = {
  enhanced: null,
  warned: false
};

async function callCommercialRpc(name, args, fallbackName, fallbackArgs) {
  if (commercialFlowAvailability.enhanced === false) {
    if (!fallbackName) throw new Error('Recurso disponivel apos a aplicacao da migration 025.');
    const fallback = await supabaseClient.rpc(fallbackName, fallbackArgs || args);
    if (fallback.error) throw fallback.error;
    return fallback.data;
  }

  const result = await supabaseClient.rpc(name, args);
  if (!result.error) {
    commercialFlowAvailability.enhanced = true;
    return result.data;
  }
  if (!isMissingSupabaseResource(result.error)) throw result.error;

  commercialFlowAvailability.enhanced = false;
  if (!commercialFlowAvailability.warned) {
    commercialFlowAvailability.warned = true;
    console.info('Fluxo Comercial: recursos complementares indisponiveis ate aplicar a migration 025.');
  }
  if (!fallbackName) throw new Error('Recurso disponivel apos a aplicacao da migration 025.');
  const fallback = await supabaseClient.rpc(fallbackName, fallbackArgs || args);
  if (fallback.error) throw fallback.error;
  return fallback.data;
}

async function supabaseCreateOrder(payload) {
  return (await callCommercialRpc('commercial_create_order', { payload }, 'create_order', { payload })) || {};
}

async function supabaseCreateQuotation(payload) {
  return (await callCommercialRpc('commercial_create_quotation', { payload }, 'create_quotation', { payload })) || {};
}

async function supabaseListOrdersReport(filters = {}) {
  let query = supabaseClient
    .from('orders')
    .select('id, numero_pedido, data_hora, created_at, regiao, vendedor, codigo_sap_cliente, cliente, cnpj, telefone, endereco, prazo, transportadora, transportadora_cnpj, transportadora_endereco, observacao, subtotal, desconto_total, total, status, order_items(id, item, codigo, descricao, marca, aplicacao, quantidade, preco_unitario, desconto_percentual, preco_final_unitario, total_item)')
    .order('created_at', { ascending: false })
    .limit(300);
  if (filters.from) query = query.gte('created_at', filters.from);
  if (filters.to) query = query.lt('created_at', filters.to);
  if (filters.status) query = query.eq('status', filters.status);
  if (filters.termo) {
    const term = `%${escapePostgrestFilter(filters.termo)}%`;
    query = query.or(`numero_pedido.ilike.${term},codigo_sap_cliente.ilike.${term},cliente.ilike.${term},cnpj.ilike.${term},vendedor.ilike.${term}`);
  }
  const { data, error } = await query;
  if (error) throw error;
  return data || [];
}

async function supabaseListQuotationsReport(filters = {}) {
  let query = supabaseClient
    .from('quotations')
    .select('id, numero_cotacao, data_hora, created_at, regiao, vendedor, codigo_sap_cliente, cliente, cnpj, telefone, endereco, prazo, transportadora, transportadora_cnpj, transportadora_endereco, observacao, subtotal, desconto_total, total, status, quotation_items(id, item, codigo, descricao, marca, aplicacao, quantidade, preco_unitario, desconto_percentual, preco_final_unitario, total_item)')
    .order('created_at', { ascending: false })
    .limit(300);
  if (filters.from) query = query.gte('created_at', filters.from);
  if (filters.to) query = query.lt('created_at', filters.to);
  if (filters.status) query = query.eq('status', filters.status);
  if (filters.termo) {
    const term = `%${escapePostgrestFilter(filters.termo)}%`;
    query = query.or(`numero_cotacao.ilike.${term},codigo_sap_cliente.ilike.${term},cliente.ilike.${term},cnpj.ilike.${term},vendedor.ilike.${term}`);
  }
  const { data, error } = await query;
  if (error) throw error;
  return data || [];
}

async function supabaseUpdateOrderReport(payload = {}) {
  const cleanPayload = sanitizeDocumentItemsUpdate(payload);
  return (await callCommercialRpc('commercial_update_order_items', { payload: cleanPayload }, 'update_order_items', { payload: cleanPayload })) || {};
}

async function supabaseUpdateQuotationReport(payload = {}) {
  const cleanPayload = sanitizeDocumentItemsUpdate(payload);
  return (await callCommercialRpc('commercial_update_quotation_items', { payload: cleanPayload }, 'update_quotation_items', { payload: cleanPayload })) || {};
}

async function supabaseUpdateOrderStatus(payload = {}) {
  if (!payload.id) throw new Error('Pedido nao informado.');
  if (!payload.status) throw new Error('Status nao informado.');
  return (await callCommercialRpc(
    'commercial_update_order_status',
    { target_id: payload.id, target_status: payload.status },
    'update_document_status',
    { payload: { type: 'pedido', id: payload.id, status: payload.status } }
  )) || {};
}

async function supabaseUpdateQuotationStatus(payload = {}) {
  if (!payload.id) throw new Error('Cotacao nao informada.');
  if (!payload.status) throw new Error('Status nao informado.');
  return (await callCommercialRpc(
    'commercial_update_quotation_status',
    { target_id: payload.id, target_status: payload.status },
    'update_document_status',
    { payload: { type: 'cotacao', id: payload.id, status: payload.status } }
  )) || {};
}

async function supabaseGetCustomerCommercialProfile(clientId) {
  if (!clientId) throw new Error('Cliente nao informado.');
  return (await callCommercialRpc('get_customer_commercial_profile', { target_client_id: clientId })) || {};
}

async function supabaseAddCustomerNote(clientId, note) {
  if (!clientId) throw new Error('Cliente nao informado.');
  const cleanNote = String(note || '').trim();
  if (!cleanNote || cleanNote.length > 2000) throw new Error('A observacao deve ter entre 1 e 2000 caracteres.');
  return (await callCommercialRpc('add_customer_note', { target_client_id: clientId, note_text: cleanNote })) || {};
}

async function supabaseToggleCustomerFavorite(clientId, favorite) {
  if (!clientId) throw new Error('Cliente nao informado.');
  return (await callCommercialRpc('toggle_customer_favorite', { target_client_id: clientId, favorite: Boolean(favorite) })) === true;
}

async function supabaseConvertQuotationToOrder(quotationId) {
  if (!quotationId) throw new Error('Cotacao nao informada.');
  return (await callCommercialRpc('convert_quotation_to_order', { target_quotation_id: quotationId })) || {};
}

function sanitizeDocumentItemsUpdate(payload = {}) {
  if (!payload.id) throw new Error('Registro nao informado.');
  const items = Array.isArray(payload.items) ? payload.items : [];
  if (!items.length) throw new Error('Informe ao menos um item.');
  return {
    id: payload.id,
    items: items.map((item) => ({
      codigo: String(item.codigo || '').trim(),
      quantidade: Number(item.quantidade || 0),
      desconto_percentual: Math.max(0, Number(item.desconto_percentual || 0))
    })).filter((item, index) => {
      if (!item.codigo) throw new Error('Item ' + (index + 1) + ': codigo do produto ausente.');
      if (Number(item.quantidade || 0) <= 0) throw new Error('Item ' + (index + 1) + ': quantidade deve ser maior que zero.');
      return true;
    })
  };
}

async function supabaseListBusinessClients(filters = {}) {
  let query = supabaseClient
    .from('clients')
    .select('id, codigo_sap_cliente, nome, nome_fantasia, cnpj, telefone, email, endereco, cidade, estado, ativo, observacoes, created_at, updated_at')
    .order('nome', { ascending: true })
    .limit(300);
  if (filters.ativos === true) query = query.eq('ativo', true);
  if (filters.termo) {
    const term = `%${escapePostgrestFilter(filters.termo)}%`;
    query = query.or(`codigo_sap_cliente.ilike.${term},nome.ilike.${term},nome_fantasia.ilike.${term},cnpj.ilike.${term},cidade.ilike.${term}`);
  }
  const { data, error } = await query;
  if (error) throw error;
  return data || [];
}

async function supabaseSaveBusinessClient(payload = {}) {
  const client = {
    codigo_sap_cliente: String(payload.codigo_sap_cliente || '').trim() || null,
    nome: String(payload.nome || '').trim(),
    nome_fantasia: String(payload.nome_fantasia || '').trim() || null,
    cnpj: onlyDigits(payload.cnpj || '') || null,
    telefone: String(payload.telefone || '').trim() || null,
    email: String(payload.email || '').trim() || null,
    endereco: String(payload.endereco || '').trim() || null,
    cidade: String(payload.cidade || '').trim() || null,
    estado: String(payload.estado || '').trim().toUpperCase() || null,
    ativo: payload.ativo !== false,
    observacoes: String(payload.observacoes || '').trim() || null
  };
  if (!client.nome) throw new Error('Informe a razao social/nome do cliente.');
  if (client.email && !isValidEmail(client.email)) throw new Error('Informe um email valido para o cliente.');
  const record = payload.id ? Object.assign({ id: payload.id }, client) : client;
  const { data, error } = await supabaseClient
    .from('clients')
    .upsert(record, { onConflict: 'id' })
    .select('id, codigo_sap_cliente, nome, nome_fantasia, cnpj, telefone, email, endereco, cidade, estado, ativo, observacoes')
    .single();
  if (error) throw error;
  await supabaseLog('SALVAR_CLIENTE', 'clients', data.id, client);
  return data;
}

async function supabaseSaveBusinessClientFromCadastro(cadastro = {}) {
  const codigo = String(cadastro.codigo_sap_cliente || '').trim();
  const cnpj = onlyDigits(cadastro.cnpj || '');
  let existing = null;
  if (codigo) existing = await supabaseFindBusinessClient('codigo_sap_cliente', codigo);
  if (!existing && cnpj) existing = await supabaseFindBusinessClient('cnpj', cnpj);
  return supabaseSaveBusinessClient({
    id: existing && existing.id,
    codigo_sap_cliente: codigo,
    nome: cadastro.razao_social || cadastro.nome_fantasia || '',
    nome_fantasia: cadastro.nome_fantasia || '',
    cnpj,
    telefone: cadastro.whatsapp || cadastro.telefone || '',
    email: cadastro.email_compras || '',
    endereco: formatCadastroClientAddress(cadastro),
    cidade: cadastro.cidade || '',
    estado: cadastro.estado || '',
    ativo: true,
    observacoes: [
      cadastro.protocolo ? `Origem portal: ${cadastro.protocolo}` : '',
      cadastro.observacoes || ''
    ].filter(Boolean).join('\n')
  });
}

async function supabaseFindBusinessClient(field, value) {
  const { data, error } = await supabaseClient
    .from('clients')
    .select('id')
    .eq(field, value)
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  return data || null;
}

function formatCadastroClientAddress(cadastro) {
  return [
    [cadastro.endereco, cadastro.numero].filter(Boolean).join(', '),
    cadastro.bairro,
    cadastro.complemento,
    [cadastro.cidade, cadastro.estado].filter(Boolean).join('/')
  ].filter(Boolean).join(' - ');
}

async function supabaseListBusinessCarriers(filters = {}) {
  let query = supabaseClient
    .from('carriers')
    .select('id, cnpj, nome, telefone, email, endereco, cidade, estado, ativo, observacoes, created_at')
    .order('nome', { ascending: true })
    .limit(300);
  if (filters.ativos === true) query = query.eq('ativo', true);
  if (filters.termo) {
    const term = `%${escapePostgrestFilter(filters.termo)}%`;
    query = query.or(`nome.ilike.${term},cnpj.ilike.${term},cidade.ilike.${term}`);
  }
  const { data, error } = await query;
  if (error) throw error;
  return data || [];
}

async function supabaseSaveBusinessCarrier(payload = {}) {
  const carrier = {
    nome: String(payload.nome || '').trim(),
    cnpj: onlyDigits(payload.cnpj || '') || null,
    telefone: String(payload.telefone || '').trim() || null,
    email: String(payload.email || '').trim() || null,
    endereco: String(payload.endereco || '').trim() || null,
    cidade: String(payload.cidade || '').trim() || null,
    estado: String(payload.estado || '').trim().toUpperCase() || null,
    ativo: payload.ativo !== false,
    observacoes: String(payload.observacoes || '').trim() || null
  };
  if (!carrier.nome) throw new Error('Informe o nome da transportadora.');
  if (carrier.email && !isValidEmail(carrier.email)) throw new Error('Informe um email valido para a transportadora.');
  const record = payload.id ? Object.assign({ id: payload.id }, carrier) : carrier;
  const { data, error } = await supabaseClient
    .from('carriers')
    .upsert(record, { onConflict: 'id' })
    .select('id, cnpj, nome, telefone, email, endereco, cidade, estado, ativo, observacoes')
    .single();
  if (error) throw error;
  await supabaseLog('SALVAR_TRANSPORTADORA', 'carriers', data.id, carrier);
  return data;
}

async function supabaseSearchOrderClients(term = '') {
  const [clients, cadastros] = await Promise.all([
    supabaseListBusinessClients({ termo: term, ativos: true }),
    supabaseSearchCadastrosClientesForOrder(term)
  ]);
  const rows = clients.map((client) => ({
    origem: 'cliente',
    id: client.id,
    codigo_sap_cliente: client.codigo_sap_cliente,
    razao_social: client.nome,
    nome_fantasia: client.nome_fantasia,
    cnpj: client.cnpj,
    telefone: client.telefone,
    email_compras: client.email,
    endereco: client.endereco,
    cidade: client.cidade,
    estado: client.estado,
    status: client.ativo ? 'Ativo' : 'Inativo'
  }));
  const portalRows = cadastros.map((row) => Object.assign({ origem: 'portal' }, row));
  return rows.concat(portalRows).slice(0, 60);
}

async function supabaseSearchOrderCarriers(term = '') {
  return supabaseListBusinessCarriers({ termo: term, ativos: true });
}

async function supabaseGetLogs(filters) {
  let query = supabaseClient
    .from('logs')
    .select('data_hora, usuario, acao, entidade, id_entidade')
    .order('data_hora', { ascending: false })
    .limit(100);
  if (filters && filters.usuario) query = query.ilike('usuario', `%${filters.usuario}%`);
  if (filters && filters.acao) query = query.ilike('acao', `%${filters.acao}%`);
  const { data, error } = await query;
  if (error) throw error;
  return data || [];
}

async function supabaseListCadastrosClientes(filters = {}) {
  let query = supabaseClient
    .from('cadastros_clientes')
    .select('id, protocolo, status, codigo_sap_cliente, cnpj, razao_social, nome_fantasia, ie, telefone, whatsapp, email_compras, cidade, estado, endereco, numero, bairro, complemento, segmento, transportadora, prazo_desejado, vendedor, situacao_cadastral, cnae, possui_regime_especial, descricao_regime, observacoes, observacoes_internas, anexos, created_at')
    .order('created_at', { ascending: false })
    .limit(150);
  if (filters.status) query = query.eq('status', filters.status);
  if (filters.termo) {
    const term = `%${escapePostgrestFilter(filters.termo)}%`;
    query = query.or(`protocolo.ilike.${term},codigo_sap_cliente.ilike.${term},cnpj.ilike.${term},razao_social.ilike.${term},nome_fantasia.ilike.${term},cidade.ilike.${term}`);
  }
  const { data, error } = await query;
  if (error) throw error;
  return data || [];
}

async function supabaseCreateCadastroAttachmentSignedUrl(path) {
  const cleanPath = String(path || '').trim();
  if (!cleanPath) throw new Error('Anexo sem caminho no Storage.');
  const { data, error } = await supabaseClient
    .storage
    .from('cadastros-clientes')
    .createSignedUrl(cleanPath, 60 * 5);
  if (error) throw error;
  if (!data || !data.signedUrl) throw new Error('Nao foi possivel gerar o link do anexo.');
  return data.signedUrl;
}

async function supabaseGetPortalCadastroSettings() {
  const { data, error } = await supabaseClient
    .from('settings')
    .select('value')
    .eq('key', 'portal_cadastros')
    .maybeSingle();
  if (error) throw error;
  return Object.assign({ email_principal: '' }, data && data.value ? data.value : {});
}

async function supabaseSavePortalCadastroSettings(payload = {}) {
  const email = String(payload.email_principal || '').trim();
  if (!isValidEmail(email)) throw new Error('Informe um email principal valido.');
  const value = {
    email_principal: email,
    updated_at: new Date().toISOString()
  };
  const { data, error } = await supabaseClient
    .from('settings')
    .upsert({ key: 'portal_cadastros', value }, { onConflict: 'key' })
    .select('key, value')
    .single();
  if (error) throw error;
  await supabaseLog('ATUALIZAR_CONFIG_PORTAL_CADASTROS', 'settings', 'portal_cadastros', value);
  return data.value || value;
}

async function supabaseGetCadastrosPortalReport(filters = {}) {
  const statuses = cadastroPortalStatuses();
  const totalPromise = buildCadastrosPortalQuery('id', { count: 'exact', head: true }, filters);
  const statusPromises = statuses.map((status) => buildCadastrosPortalQuery('id', { count: 'exact', head: true }, filters).eq('status', status));
  const recentPromise = buildCadastrosPortalQuery(
    'id, protocolo, status, codigo_sap_cliente, cnpj, razao_social, nome_fantasia, telefone, whatsapp, email_compras, cidade, estado, endereco, numero, bairro, complemento, observacoes, vendedor, anexos, created_at',
    {},
    filters
  )
    .order('created_at', { ascending: false })
    .limit(200);

  const [settingsResult, totalResult, recentResult, ...statusResults] = await Promise.all([
    supabaseGetPortalCadastroSettings(),
    totalPromise,
    recentPromise,
    ...statusPromises
  ]);

  const firstError = [totalResult, recentResult, ...statusResults].find((result) => result.error);
  if (firstError) throw firstError.error;

  return {
    settings: settingsResult,
    total: totalResult.count || 0,
    byStatus: statuses.map((status, index) => ({ status, count: statusResults[index].count || 0 })),
    recent: recentResult.data || []
  };
}

function buildCadastrosPortalQuery(select, options, filters) {
  let query = supabaseClient
    .from('cadastros_clientes')
    .select(select, options);
  if (filters.status) query = query.eq('status', filters.status);
  if (filters.from) query = query.gte('created_at', filters.from);
  if (filters.to) query = query.lt('created_at', filters.to);
  return query;
}

function cadastroPortalStatuses() {
  return ['Novo', 'Em analise', 'Pendente', 'Aprovado', 'Reprovado', 'Finalizado SAP'];
}

function isValidEmail(value) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(value || '').trim());
}

async function supabaseUpdateCadastroCliente(payload) {
  const updates = {
    status: payload.status,
    codigo_sap_cliente: String(payload.codigo_sap_cliente || '').trim() || null,
    observacoes_internas: payload.observacoes_internas || null
  };
  const { data, error } = await supabaseClient
    .from('cadastros_clientes')
    .update(updates)
    .eq('id', payload.id)
    .select('id, protocolo, status, codigo_sap_cliente, observacoes_internas')
    .single();
  if (error) throw error;
  await supabaseLog('ATUALIZAR_CADASTRO_CLIENTE', 'cadastros_clientes', payload.id, updates);
  return data;
}

async function supabaseSearchCadastrosClientesForOrder(term = '') {
  const search = String(term || '').trim();
  let query = supabaseClient
    .from('cadastros_clientes')
    .select('id, protocolo, status, codigo_sap_cliente, cnpj, razao_social, nome_fantasia, telefone, whatsapp, email_compras, cidade, estado, endereco, numero, bairro, complemento, transportadora, prazo_desejado, vendedor, created_at')
    .in('status', ['Aprovado', 'Finalizado SAP'])
    .order('created_at', { ascending: false })
    .limit(30);

  if (search) {
    const pattern = `%${escapePostgrestFilter(search)}%`;
    query = query.or([
      `protocolo.ilike.${pattern}`,
      `codigo_sap_cliente.ilike.${pattern}`,
      `cnpj.ilike.${pattern}`,
      `razao_social.ilike.${pattern}`,
      `nome_fantasia.ilike.${pattern}`,
      `cidade.ilike.${pattern}`
    ].join(','));
  }

  const { data, error } = await query;
  if (error) throw error;
  return data || [];
}

async function supabaseListUsers() {
  const { data, error } = await supabaseClient
    .from('profiles')
    .select('id, usuario, nome, email, perfil, ativo, ultimo_login')
    .order('nome', { ascending: true });
  if (error) throw error;
  return data || [];
}

async function supabaseSaveUser(payload) {
  const profile = {
    usuario: String(payload.usuario || '').trim(),
    nome: String(payload.nome || '').trim(),
    email: String(payload.email || '').trim(),
    perfil: payload.perfil || 'VENDEDOR',
    ativo: payload.ativo !== false
  };
  if (!profile.usuario || !profile.nome || !profile.email) {
    throw new Error('Usuario, nome e email sao obrigatorios.');
  }

  let userId = payload.id_usuario || payload.id || '';
  const [{ data: sameUser, error: sameUserError }, { data: sameEmail, error: sameEmailError }] = await Promise.all([
    supabaseClient.from('profiles').select('id').eq('usuario', profile.usuario).maybeSingle(),
    supabaseClient.from('profiles').select('id').eq('email', profile.email).maybeSingle()
  ]);
  if (sameUserError) throw sameUserError;
  if (sameEmailError) throw sameEmailError;
  if (sameUser && sameUser.id !== userId) throw new Error('Ja existe um usuario com este login.');
  if (sameEmail && sameEmail.id !== userId) throw new Error('Ja existe um usuario com este email.');

  if (!userId) {
    if (!payload.senha) throw new Error('Informe uma senha inicial para novo usuario.');
    const previousSession = await supabaseClient.auth.getSession();
    const { data: signupData, error: signupError } = await supabaseClient.auth.signUp({
      email: profile.email,
      password: payload.senha,
      options: { data: { usuario: profile.usuario, nome: profile.nome } }
    });
    if (previousSession.data.session) {
      await supabaseClient.auth.setSession({
        access_token: previousSession.data.session.access_token,
        refresh_token: previousSession.data.session.refresh_token
      });
    }
    if (signupError) throw signupError;
    userId = signupData.user && signupData.user.id;
    if (!userId) throw new Error('Usuario Auth nao foi criado no Supabase.');
  }

  const { data, error } = await supabaseClient
    .from('profiles')
    .upsert(Object.assign({ id: userId }, profile), { onConflict: 'id' })
    .select('id, usuario, nome, email, perfil, ativo, ultimo_login')
    .single();
  if (error) throw error;
  await supabaseLog('SALVAR_USUARIO', 'profiles', userId, profile);
  return data;
}

async function supabaseImportProducts(payload) {
  const batchId = payload.batchId || payload.batch_id;
  if (!batchId) throw new Error('Gere a previa antes de importar.');
  if (typeof payload.onProgress === 'function') {
    payload.onProgress({ done: 0, total: 1, batch: 1, batches: 1 });
  }
  const { data, error } = await supabaseClient.rpc('commit_products_import_batch', { batch_id: batchId });
  if (error) throw formatImportRpcError(error);
  clearStaticCache('productFiltersV2');
  if (typeof payload.onProgress === 'function') {
    payload.onProgress({ done: 1, total: 1, batch: 1, batches: 1 });
  }
  return normalizeStagedImportPreview(data);
}

async function supabaseApproveProductsImport(payload) {
  const batchId = payload.batchId || payload.batch_id;
  if (!batchId) throw new Error('Gere a previa antes de aprovar.');
  const { data, error } = await supabaseClient.rpc('approve_products_import_batch', { batch_id: batchId });
  if (error) throw formatImportRpcError(error);
  return normalizeStagedImportPreview(data);
}

async function supabasePreviewImportProducts(payload) {
  const tipo = normalizeImportType(payload.tipo);
  const table = parseDelimitedTable(payload.texto || '');
  validateImportRequiredColumns(table.headers, payload.mapping, tipo);
  const rows = applyImportMapping(table.rows, payload.mapping);
  if (!rows.length) throw new Error('Cole ou selecione um CSV/TSV com cabecalho.');

  const products = rows.map((row, index) => (
    Object.assign({ row_number: index + 2 }, filterProductFields(mapImportProduct(row, tipo)))
  ));

  if (!products.length) throw new Error('Nenhum produto valido encontrado na importacao.');

  const fileHash = await hashImportText([tipo, payload.fileName || '', payload.texto || ''].join('\n'));
  const { data, error } = await supabaseClient.rpc('create_products_import_batch', {
    payload: {
      import_type: tipo,
      region: payload.region || payload.filial || null,
      source_name: payload.fileName || null,
      file_hash: fileHash,
      products
    }
  });
  if (error) throw formatImportRpcError(error);
  const plan = normalizeStagedImportPreview(data);
  plan.totalRows = rows.length;
  plan.validRows = Math.max(0, rows.length - Number(plan.errorCount || 0));
  plan.portalWarnings = payload.portalTexto ? buildPortalImportWarnings(payload.portalTexto, products, tipo) : [];
  return plan;
}

function normalizeStagedImportPreview(data = {}) {
  const summary = data.summary || {};
  const errors = Array.isArray(data.errors) ? data.errors : [];
  const warnings = Array.isArray(data.warnings) ? data.warnings : [];
  const preview = Array.isArray(data.preview) ? data.preview : [];
  const differences = Array.isArray(data.differences) ? data.differences : [];
  const duplicateCodes = errors
    .filter((row) => JSON.stringify(row.errors || []).includes('duplicado'))
    .map((row) => row.codigo)
    .filter(Boolean);
  return {
    batchId: data.batch_id || summary.batchId,
    status: data.status || summary.status || 'draft',
    tipo: summary.importType,
    fieldsUpdated: getImportUpdatedFields(summary.importType),
    totalRows: Number(summary.totalRows || 0),
    validRows: Number(summary.validRows || 0),
    uniqueRows: Number(summary.validRows || 0),
    ignoredCount: Number(summary.ignoredCount || summary.invalidRows || 0),
    invalidRows: errors.map((row) => ({
      linha: row.row_number,
      motivo: jsonArrayToText(row.errors)
    })),
    warningRows: warnings.map((row) => ({
      linha: row.row_number,
      codigo: row.codigo,
      motivo: jsonArrayToText(row.warnings)
    })),
    differences,
    duplicateCodes,
    duplicates: duplicateCodes.length,
    existingCount: Number(summary.updatedCount || 0),
    newCount: Number(summary.newCount || 0),
    warningCount: Number(summary.warningCount || 0),
    errorCount: Number(summary.errorCount || 0),
    priceChanged: Number(summary.priceChanged || 0),
    stockChanged: Number(summary.stockChanged || 0),
    descriptionChanged: Number(summary.descriptionChanged || 0),
    preview,
    summary
  };
}

async function hashImportText(value) {
  const text = String(value || '');
  if (!window.crypto || !window.crypto.subtle) return String(text.length) + ':' + text.slice(0, 64);
  const bytes = new TextEncoder().encode(text);
  const digest = await window.crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest)).map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

function formatImportRpcError(error) {
  const message = String(error?.message || '');
  console.error('Erro na RPC de importacao:', {
    message: error?.message,
    code: error?.code,
    details: error?.details,
    hint: error?.hint
  });
  if (message.includes('ARQUIVO_JA_IMPORTADO')) return new Error('Arquivo ja importado anteriormente.');
  if (message.includes('IMPORTACAO_BLOQUEADA_COM_ERROS')) return new Error('Importacao bloqueada: existem erros que precisam ser corrigidos.');
  if (message.includes('SEM_PERMISSAO_APROVAR_IMPORTACAO')) return new Error('Usuario sem permissao para aprovar/importar produtos.');
  if (message.includes('IMPORTACAO_NAO_APROVADA')) return new Error('Importacao precisa estar validada/aprovada antes de gravar.');
  if (message.includes('SEM_PERMISSAO')) return new Error('Usuario sem permissao para importar produtos.');
  if (message.includes('IMPORTACAO_SEM_PRODUTOS')) return new Error('Nenhum produto valido encontrado na importacao.');
  if (message.toLowerCase().includes('could not find the function')) {
    return new Error('RPC de importacao nao encontrada. Rode as migrations 018, 019 e 020 no Supabase.');
  }
  return new Error([
    'Erro na importacao SAP.',
    error?.message ? `Mensagem: ${error.message}` : '',
    error?.code ? `Codigo: ${error.code}` : '',
    error?.details ? `Detalhes: ${error.details}` : '',
    error?.hint ? `Dica: ${error.hint}` : ''
  ].filter(Boolean).join(' '));
}

function jsonArrayToText(value) {
  if (Array.isArray(value)) return value.join(', ');
  if (value == null) return '';
  return String(value);
}

function buildPortalImportWarnings(portalText, sapProducts, tipo) {
  try {
    const portalPlan = getImportAutoAnalysis(portalText, tipo);
    const portalRows = applyImportMapping(parseDelimitedTable(portalText).rows, portalPlan.mapping)
      .map((row) => filterProductFields(mapImportProduct(row, tipo)))
      .filter((product) => product.codigo);
    const sapByCode = new Map((sapProducts || []).map((product) => [product.codigo, product]));
    const portalByCode = new Map(portalRows.map((product) => [product.codigo, product]));
    const warnings = [];

    sapByCode.forEach((sapProduct, code) => {
      const portalProduct = portalByCode.get(code);
      if (!portalProduct) {
        warnings.push(`Codigo ${code} esta no SAP e ausente no Portal`);
        return;
      }
      const sapPrice = Number(sapProduct.preco_sp ?? sapProduct.preco_pr ?? 0);
      const portalPrice = Number(portalProduct.preco_sp ?? portalProduct.preco_pr ?? 0);
      if (sapPrice > 0 && portalPrice > 0 && Math.abs(sapPrice - portalPrice) / sapPrice > 0.02) {
        warnings.push(`Codigo ${code}: preco SAP x Portal diferente acima de 2%`);
      }
      const sapStock = Number(sapProduct.estoque_quantidade ?? 0);
      const portalStock = Number(portalProduct.estoque_quantidade ?? 0);
      if (Number.isFinite(sapStock) && Number.isFinite(portalStock) && sapStock !== portalStock) {
        warnings.push(`Codigo ${code}: estoque SAP x Portal diferente`);
      }
      if (textDistanceRatio(sapProduct.descricao, portalProduct.descricao) > 0.45) {
        warnings.push(`Codigo ${code}: descricao SAP x Portal muito diferente`);
      }
    });

    portalByCode.forEach((_portalProduct, code) => {
      if (!sapByCode.has(code)) warnings.push(`Codigo ${code} esta no Portal e ausente no SAP`);
    });

    return warnings;
  } catch (error) {
    return ['Nao foi possivel comparar o texto do Portal: ' + (error.message || 'formato invalido')];
  }
}

function textDistanceRatio(a, b) {
  const left = String(a || '').toLowerCase().trim();
  const right = String(b || '').toLowerCase().trim();
  if (!left || !right) return 0;
  const common = left.split(/\s+/).filter((word) => right.includes(word)).join(' ').length;
  return 1 - common / Math.max(left.length, right.length, 1);
}

function getImportColumnPlan(text, tipo) {
  const normalizedType = normalizeImportType(tipo);
  const table = parseDelimitedTable(text || '');
  return {
    headers: table.headers,
    sampleRows: table.rows.slice(0, 3),
    mapping: Object.fromEntries(table.headers.map((header) => [header, suggestImportField(header, normalizedType)]))
  };
}

function getImportAutoAnalysis(text, currentType) {
  const firstPlan = getImportColumnPlan(text, currentType);
  const suggestedType = inferImportTypeFromMapping(firstPlan.mapping, currentType);
  if (suggestedType === currentType || normalizeImportType(suggestedType) === normalizeImportType(currentType)) {
    return Object.assign({ suggestedType }, firstPlan);
  }
  return Object.assign({ suggestedType }, getImportColumnPlan(text, suggestedType));
}

function inferImportTypeFromMapping(mapping, currentType) {
  const fields = Object.values(mapping || {}).filter(Boolean);
  const has = (field) => fields.includes(field);
  const descriptiveCount = ['descricao', 'marca', 'aplicacao', 'ano', 'ipi', 'preco_sem_imposto', 'grupo', 'categoria', 'montadora', 'oem', 'similar']
    .filter(has).length;
  const hasOnlyStock = has('estoque') && descriptiveCount === 0 && !has('preco_sp') && !has('preco_pr') && !has('preco_referencia');
  if (has('preco_sp') && descriptiveCount === 0) return 'PRECO_SP';
  if (has('preco_pr') && descriptiveCount === 0) return 'PRECO_PR';
  if (hasOnlyStock) return 'PORTAL_ESTOQUE';
  if (descriptiveCount >= 2 || has('preco_sem_imposto') || has('preco_referencia')) return 'CRISTIANO';
  return currentType || 'CRISTIANO';
}

async function supabaseLog(acao, entidade, idEntidade, dadosNovos) {
  const session = getStoredSession() || {};
  await supabaseClient.from('logs').insert({
    usuario: session.usuario || null,
    acao,
    entidade,
    id_entidade: idEntidade == null ? null : String(idEntidade),
    dados_novos: dadosNovos || null
  });
}

const allowedProductFields = [
  'codigo',
  'descricao',
  'marca',
  'aplicacao',
  'ano',
  'ipi',
  'preco_sem_imposto',
  'estoque',
  'estoque_quantidade',
  'preco_sp',
  'preco_pr',
  'status_estoque',
  'status_cadastro',
  'url_imagem',
  'grupo',
  'categoria',
  'montadora',
  'detalhes',
  'oem',
  'similar'
];

function normalizeImportType(tipo) {
  if (tipo === 'CRISTIANO') return 'CADASTRO_COMPLETO';
  return tipo || 'CATALOGO_PESQUISA';
}

function filterProductFields(product) {
  const clean = {};
  allowedProductFields.forEach((field) => {
    if (!Object.prototype.hasOwnProperty.call(product, field)) return;
    const value = product[field];
    if (value === '' || value == null) return;
    clean[field] = value;
  });
  return clean;
}

function mergeImportProduct(previous, incoming) {
  const merged = Object.assign({}, previous);
  Object.entries(incoming).forEach(([field, value]) => {
    if (field === 'codigo') {
      merged.codigo = value;
      return;
    }
    if (value === '' || value == null) return;
    merged[field] = value;
  });
  return merged;
}

function consolidateImportProducts(products) {
  const byCode = new Map();
  const duplicateCodes = new Set();
  products.forEach((product) => {
    if (byCode.has(product.codigo)) {
      duplicateCodes.add(product.codigo);
      byCode.set(product.codigo, mergeImportProduct(byCode.get(product.codigo), product));
      return;
    }
    byCode.set(product.codigo, product);
  });
  return {
    productsUnique: Array.from(byCode.values()).map(filterProductFields),
    duplicateCodes: Array.from(duplicateCodes)
  };
}

function getImportUpdatedFields(tipo) {
  if (tipo === 'PORTAL_ESTOQUE') return ['codigo', 'estoque', 'estoque_quantidade', 'status_estoque'];
  if (tipo === 'PRECO_SP') return ['codigo', 'preco_sp'];
  if (tipo === 'PRECO_PR') return ['codigo', 'preco_pr'];
  if (tipo === 'CATALOGO_PESQUISA') {
    return ['codigo', 'descricao', 'marca', 'aplicacao', 'ano', 'grupo', 'categoria', 'montadora', 'detalhes', 'oem', 'similar'];
  }
  return [
    'codigo',
    'descricao',
    'marca',
    'aplicacao',
    'ano',
    'ipi',
    'preco_sem_imposto',
    'estoque',
    'estoque_quantidade',
    'status_estoque',
    'status_cadastro',
    'url_imagem',
    'grupo',
    'categoria',
    'montadora',
    'detalhes',
    'oem',
    'similar'
  ];
}

function getImportRequiredFields(tipo) {
  if (tipo === 'PORTAL_ESTOQUE') return ['codigo', 'estoque'];
  if (tipo === 'PRECO_SP') return ['codigo', 'preco_sp'];
  if (tipo === 'PRECO_PR') return ['codigo', 'preco_pr'];
  if (tipo === 'CATALOGO_PESQUISA') return ['codigo'];
  return ['codigo', 'descricao'];
}

function validateImportRequiredColumns(headers, mapping, tipo) {
  if (!headers.length) throw new Error('Cole ou selecione um CSV/TSV com cabecalho.');
  const mappedFields = new Set(Object.values(mapping || {}).filter(Boolean));
  const missing = getImportRequiredFields(tipo).filter((field) => !mappedFields.has(field));
  if (!missing.length) return;
  throw new Error(
    'Colunas obrigatorias nao encontradas no mapeamento: '
    + missing.map(getImportFieldLabel).join(', ')
    + '. Ajuste as colunas detectadas antes de verificar.'
  );
}

function getImportFieldLabel(field) {
  const labels = {
    codigo: 'codigo',
    descricao: 'descricao',
    estoque: 'estoque',
    preco_sp: 'preco SP',
    preco_pr: 'preco PR'
  };
  return labels[field] || field;
}

function parseDelimitedTable(text) {
  const source = String(text || '').trim();
  if (!source) return { headers: [], rows: [] };
  const delimiter = source.includes('\t') ? '\t' : detectCsvDelimiter(source);
  const rows = [];
  let row = [];
  let value = '';
  let quoted = false;
  for (let i = 0; i < source.length; i += 1) {
    const char = source[i];
    const next = source[i + 1];
    if (char === '"' && quoted && next === '"') {
      value += '"';
      i += 1;
    } else if (char === '"') {
      quoted = !quoted;
    } else if (char === delimiter && !quoted) {
      row.push(value);
      value = '';
    } else if ((char === '\n' || char === '\r') && !quoted) {
      if (char === '\r' && next === '\n') i += 1;
      row.push(value);
      if (row.some((cell) => String(cell).trim())) rows.push(row);
      row = [];
      value = '';
    } else {
      value += char;
    }
  }
  row.push(value);
  if (row.some((cell) => String(cell).trim())) rows.push(row);
  const originalHeaders = rows.shift() || [];
  const headers = originalHeaders.map(normalizeHeader);
  return {
    headers: originalHeaders.map((header) => String(header || '').trim()),
    rows: rows.map((cells) => {
    const item = {};
    headers.forEach((header, index) => {
      if (header) item[header] = String(cells[index] || '').trim();
    });
    return item;
    })
  };
}

function parseDelimitedText(text) {
  return parseDelimitedTable(text).rows;
}

function applyImportMapping(rows, mapping) {
  if (!mapping || !Object.values(mapping).some(Boolean)) return rows;
  return rows.map((row) => {
    const mapped = {};
    Object.entries(mapping).forEach(([header, field]) => {
      if (!field) return;
      const sourceKey = normalizeHeader(header);
      if (Object.prototype.hasOwnProperty.call(row, sourceKey)) mapped[field] = row[sourceKey];
    });
    return mapped;
  });
}

function suggestImportField(header, tipo) {
  const key = normalizeHeader(header);
  const exact = {
    codigoips: 'codigo',
    codigo: 'codigo',
    cod: 'codigo',
    codproduto: 'codigo',
    codigoproduto: 'codigo',
    codigofabricante: 'codigo',
    sku: 'codigo',
    descricao: 'descricao',
    descr: 'descricao',
    descricaoproduto: 'descricao',
    marca: 'marca',
    aplicacao: 'aplicacao',
    aplica: 'aplicacao',
    veiculo: 'aplicacao',
    veiculos: 'aplicacao',
    veiculoaplicacao: 'aplicacao',
    veiculosaplicacao: 'aplicacao',
    ano: 'ano',
    ipi: 'ipi',
    precosimp: 'preco_sem_imposto',
    precosemimposto: 'preco_sem_imposto',
    precosemimp: 'preco_sem_imposto',
    estoque: 'estoque',
    dispgeral: 'estoque',
    dispvenda: 'estoque',
    quantidade: 'estoque',
    qtd: 'estoque',
    qtde: 'estoque',
    grupo: 'grupo',
    linha: 'categoria',
    linhas: 'categoria',
    categoria: 'categoria',
    montadora: 'montadora',
    oem: 'oem',
    similar: 'similar',
    similares: 'similar'
  };
  if (exact[key]) return exact[key];
  if (['precocimp', 'precocomimposto', 'valor', 'prunitci', 'totalcimp', 'praposdesc'].includes(key)) {
    if (tipo === 'PRECO_SP') return 'preco_sp';
    if (tipo === 'PRECO_PR') return 'preco_pr';
    return 'preco_referencia';
  }
  if (key.includes('precosp')) return 'preco_sp';
  if (key.includes('precopr')) return 'preco_pr';
  if (key.includes('preco') && key.includes('imp')) {
    if (tipo === 'PRECO_SP') return 'preco_sp';
    if (tipo === 'PRECO_PR') return 'preco_pr';
    return 'preco_referencia';
  }
  return '';
}

function detectCsvDelimiter(text) {
  const firstLine = String(text || '').split(/\r?\n/)[0] || '';
  return (firstLine.match(/;/g) || []).length > (firstLine.match(/,/g) || []).length ? ';' : ',';
}

function normalizeHeader(value) {
  return String(value || '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '');
}

function pickImport(row, aliases) {
  for (const alias of aliases) {
    const key = normalizeHeader(alias);
    if (Object.prototype.hasOwnProperty.call(row, alias) && row[alias] !== '') return row[alias];
    if (Object.prototype.hasOwnProperty.call(row, key) && row[key] !== '') return row[key];
  }
  return '';
}

function importNumber(value) {
  let text = String(value || '').trim();
  if (!text) return null;
  text = text.replace(/[^\d,.-]/g, '');
  if (text.includes(',') && text.includes('.')) text = text.replace(/\./g, '').replace(',', '.');
  else if (text.includes(',')) text = text.replace(',', '.');
  const parsed = Number(text);
  return Number.isFinite(parsed) ? parsed : null;
}

async function supabaseCheckExistingProductCodes(codes) {
  const cleanCodes = Array.from(new Set((codes || []).map(normalizeImportCode).filter(Boolean)));
  const existing = new Set();
  for (const chunk of chunkArray(cleanCodes, PRODUCT_IMPORT_LOOKUP_CHUNK_SIZE)) {
    const { data, error } = await supabaseClient.rpc('check_existing_product_codes', { codes: chunk });
    if (error) throw formatProductImportLookupError(error, chunk);
    (data || []).forEach((item) => {
      const code = normalizeImportCode(item && item.codigo);
      if (code) existing.add(code);
    });
  }
  return existing;
}

function normalizeImportCode(value) {
  return String(value || '')
    .replace(/[\r\n\t]+/g, ' ')
    .trim();
}

function normalizeProductCode(value) {
  let text = normalizeImportCode(value);
  if (!text) return '';
  text = text.replace(/\s+/g, '');
  if (/^\d+\.0+$/.test(text)) return text.replace(/\.0+$/, '');
  if (/^\d+(?:[.,]\d+)?e\+\d+$/i.test(text)) {
    const parsed = Number(text.replace(',', '.'));
    if (Number.isFinite(parsed)) return parsed.toLocaleString('en-US', { useGrouping: false, maximumFractionDigits: 0 });
  }
  return text;
}

function mapImportProduct(row, tipo) {
  const importType = normalizeImportType(tipo);
  const codigo = normalizeProductCode(pickImport(row, ['codigo', 'codigo ips', 'cod', 'cod.', 'sku']));
  const estoque = pickImport(row, ['estoque', 'disp geral', 'disp. geral', 'disp venda', 'disp. venda', 'qtde']);
  const precoSemImposto = importNumber(pickImport(row, [
    'preco s/imp', 'preco s imp', 'preco sem imposto', 'preco_sem_imposto', 'pr.unit.', 'pr unit'
  ]));
  const base = { codigo };
  const descriptive = {
    descricao: pickImport(row, ['descricao', 'descr']),
    marca: pickImport(row, ['marca']),
    aplicacao: pickImport(row, ['aplicacao']),
    ano: pickImport(row, ['ano']),
    ipi: importNumber(pickImport(row, ['ipi'])),
    preco_sem_imposto: precoSemImposto,
    status_cadastro: pickImport(row, ['status cadastro', 'status_cadastro']),
    url_imagem: pickImport(row, ['url imagem', 'url_imagem', 'imagem']),
    grupo: pickImport(row, ['grupo']),
    categoria: pickImport(row, ['categoria', 'linha']),
    montadora: pickImport(row, ['montadora']),
    detalhes: pickImport(row, ['detalhes', 'palavras chave', 'palavras-chave']),
    oem: pickImport(row, ['oem']),
    similar: pickImport(row, ['similar', 'similares'])
  };
  const stock = {
    estoque,
    estoque_quantidade: importNumber(estoque),
    status_estoque: pickImport(row, ['status estoque', 'status_estoque'])
  };
  const price = importNumber(pickImport(row, [
    'preco_sp', 'preco_pr', 'preco_referencia', 'preco c/imp', 'preco c imp', 'preco com imposto', 'preco', 'valor',
    'prunitci', 'pr.unit.(c/i)', 'pr unit c/i', 'total c imp', 'total c/ imp',
    'pr apos desc', 'pr.apos desc'
  ]));

  if (importType === 'PORTAL_ESTOQUE') {
    Object.assign(base, stock);
  } else if (importType === 'PRECO_PR') {
    if (price != null) base.preco_pr = price;
  } else if (importType === 'PRECO_SP') {
    if (price != null) base.preco_sp = price;
  } else if (importType === 'CATALOGO_PESQUISA') {
    Object.assign(base, descriptive);
  } else {
    Object.assign(base, descriptive, stock);
    const precoSp = importNumber(pickImport(row, ['preco_sp', 'preco sp', 'preco c/imp sp', 'preco c imp sp']));
    const precoPr = importNumber(pickImport(row, ['preco_pr', 'preco pr', 'preco c/imp pr', 'preco c imp pr']));
    if (precoSp != null) base.preco_sp = precoSp;
    if (precoPr != null) base.preco_pr = precoPr;
  }

  return Object.fromEntries(Object.entries(base).filter(([, value]) => value !== ''));
}

function chunkArray(items, size) {
  const out = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

function formatProductImportLookupError(error, chunk = []) {
  const message = String(error?.message || '');
  console.error('Erro ao consultar codigos existentes:', {
    message: error?.message,
    code: error?.code,
    details: error?.details,
    hint: error?.hint,
    chunkSize: chunk.length,
    sampleCodes: chunk.slice(0, 10)
  });

  if (
    error?.code === 'PGRST202'
    || message.includes('check_existing_product_codes')
    || message.toLowerCase().includes('could not find the function')
  ) {
    return new Error('RPC check_existing_product_codes nao encontrada. Rode a migration 017 no Supabase.');
  }

  return new Error([
    'Nao foi possivel comparar os codigos com o Supabase.',
    error?.message ? `Mensagem: ${error.message}` : '',
    error?.code ? `Codigo: ${error.code}` : '',
    error?.details ? `Detalhes: ${error.details}` : '',
    error?.hint ? `Dica: ${error.hint}` : ''
  ].filter(Boolean).join(' '));
}
