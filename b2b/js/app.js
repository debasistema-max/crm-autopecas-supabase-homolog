const b2b = window.supabase.createClient(B2B_CONFIG.supabaseUrl, B2B_CONFIG.anonKey, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
});

const state = {
  session: null,
  context: null,
  catalog: [],
  cart: [],
  documentType: 'cotacao',
  pendingSubmission: null,
  currentView: 'home'
};

const money = (value) => new Intl.NumberFormat(B2B_CONFIG.locale, {
  style: 'currency', currency: B2B_CONFIG.currency
}).format(Number(value || 0));
const number = (value) => new Intl.NumberFormat(B2B_CONFIG.locale, { maximumFractionDigits: 3 }).format(Number(value || 0));
const dateTime = (value) => value ? new Date(value).toLocaleString(B2B_CONFIG.locale) : '—';
const escapeHtml = (value) => String(value ?? '').replace(/[&<>'"]/g, (char) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
}[char]));
const technicalLoginDomain = '@login.b2b.ipsdobrasil.com.br';
const yokomitsuImageBase = 'https://www.yokomitsu.com.br/uploads/products';

function officialProductImage(code) {
  const normalized = String(code || '').trim();
  if (!/^\d{6,20}$/.test(normalized)) return '';
  return `${yokomitsuImageBase}/${normalized}/site/${normalized}.webp`;
}

function productImageMarkup(product) {
  const stored = String(product.image_url || '').trim();
  const official = officialProductImage(product.product_code);
  const source = stored || official;
  if (!source) return '<span>Sem foto</span>';
  const fallback = stored && official && stored !== official ? official : '';
  const label = `Ampliar foto de ${product.description || product.product_code}`;
  return `<button class="product-image-button" type="button" data-open-product-image aria-label="${escapeHtml(label)}"><img src="${escapeHtml(source)}" data-product-image data-fallback-src="${escapeHtml(fallback)}" alt="${escapeHtml(product.description || product.product_code)}" loading="lazy" referrerpolicy="no-referrer"><span data-image-placeholder hidden>Sem foto</span></button>`;
}

function bindProductImages(target) {
  target.querySelectorAll('[data-product-image]').forEach((img) => {
    const handleError = () => {
      const fallback = img.dataset.fallbackSrc || '';
      if (fallback) {
        img.dataset.fallbackSrc = '';
        img.src = fallback;
        return;
      }
      img.hidden = true;
      const placeholder = img.parentElement?.querySelector('[data-image-placeholder]');
      if (placeholder) placeholder.hidden = false;
      if (img.parentElement) img.parentElement.disabled = true;
    };
    img.addEventListener('error', handleError);
    if (img.complete && img.naturalWidth === 0) handleError();
    img.closest('[data-open-product-image]')?.addEventListener('click', () => openProductImage(img));
  });
}

function openProductImage(img) {
  if (!img || img.hidden || !img.src) return;
  const dialog = document.getElementById('imageDialog');
  const enlarged = document.getElementById('imageDialogImage');
  const caption = document.getElementById('imageDialogCaption');
  enlarged.src = img.currentSrc || img.src;
  enlarged.alt = img.alt;
  caption.textContent = img.alt;
  dialog.showModal();
}

function normalizeLoginName(value) {
  return String(value || '').trim().toLowerCase().normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '').replace(/[^a-z0-9._-]+/g, '');
}

function loginIdentifierToEmail(value) {
  const identifier = String(value || '').trim().toLowerCase();
  return identifier.includes('@') ? identifier : normalizeLoginName(identifier) + technicalLoginDomain;
}

document.addEventListener('DOMContentLoaded', init);

async function init() {
  bindAuth();
  bindPortal();
  const inviteFlow = /(?:^|[&#])type=(invite|recovery)(?:&|$)/.test(location.hash + '&' + location.search.slice(1));
  const { data } = await b2b.auth.getSession();
  if (inviteFlow && data.session) showPasswordForm();
  else if (data.session) await openPortal(data.session);
  else showAuth();

  b2b.auth.onAuthStateChange((event, session) => {
    if (event === 'PASSWORD_RECOVERY') showPasswordForm();
    if (event === 'SIGNED_OUT') showAuth();
    state.session = session;
  });
}

function bindAuth() {
  document.getElementById('loginForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    const message = document.getElementById('loginMessage');
    setMessage(message, 'Entrando...', '');
    const { data, error } = await b2b.auth.signInWithPassword({
      email: loginIdentifierToEmail(document.getElementById('loginIdentifier').value),
      password: document.getElementById('loginPassword').value
    });
    if (error) return setMessage(message, translateError(error), 'error');
    await openPortal(data.session);
  });

  document.getElementById('forgotPassword').addEventListener('click', async () => {
    const identifier = document.getElementById('loginIdentifier').value.trim();
    const message = document.getElementById('loginMessage');
    if (!identifier) return setMessage(message, 'Informe seu usuário, CNPJ ou e-mail primeiro.', 'error');
    if (!identifier.includes('@')) {
      return setMessage(message, 'Peça ao seu representante ou administrador da IPS uma nova senha inicial.', 'error');
    }
    const email = identifier.toLowerCase();
    const { error } = await b2b.auth.resetPasswordForEmail(email, { redirectTo: location.origin + location.pathname });
    setMessage(message, error ? translateError(error) : 'Enviamos o link de recuperação para o seu e-mail.', error ? 'error' : 'success');
  });

  document.getElementById('passwordForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    const password = document.getElementById('newPassword').value;
    const confirmation = document.getElementById('confirmPassword').value;
    const message = document.getElementById('passwordMessage');
    if (password.length < 8) return setMessage(message, 'Use pelo menos 8 caracteres.', 'error');
    if (password !== confirmation) return setMessage(message, 'As senhas não conferem.', 'error');
    const { error } = await b2b.auth.updateUser({ password });
    if (error) return setMessage(message, translateError(error), 'error');
    if (state.context?.account?.must_change_password) {
      try {
        await rpc('complete_b2b_password_change');
        state.context.account.must_change_password = false;
      } catch (completionError) {
        return setMessage(message, translateError(completionError), 'error');
      }
    }
    history.replaceState({}, '', location.pathname);
    const { data } = await b2b.auth.getSession();
    await openPortal(data.session);
  });
}

function bindPortal() {
  document.querySelectorAll('[data-view]').forEach((button) => button.addEventListener('click', () => navigate(button.dataset.view)));
  document.getElementById('logoutButton').addEventListener('click', () => b2b.auth.signOut());
  document.getElementById('cartButton').addEventListener('click', openCart);
  document.getElementById('cartDialog').addEventListener('click', closeDialogOnBackdrop);
  document.getElementById('documentDialog').addEventListener('click', closeDialogOnBackdrop);
  document.getElementById('imageDialog').addEventListener('click', closeDialogOnBackdrop);
  document.getElementById('imageDialogClose').addEventListener('click', () => document.getElementById('imageDialog').close());
}

async function rpc(name, args = {}) {
  const { data, error } = await b2b.rpc(name, args);
  if (error) throw error;
  return data;
}

async function openPortal(session) {
  if (!session) return showAuth();
  state.session = session;
  try {
    state.context = await rpc('get_b2b_session');
  } catch (error) {
    await b2b.auth.signOut();
    showAuth();
    setMessage(document.getElementById('loginMessage'), 'Este e-mail ainda não está vinculado a um cliente ativo. Fale com seu representante.', 'error');
    return;
  }
  if (state.context.account?.must_change_password) {
    showPasswordForm();
    document.getElementById('passwordHelp').textContent = 'Por segurança, troque a senha inicial entregue pela IPS antes de acessar seus dados.';
    setMessage(document.getElementById('passwordMessage'), 'Troque a senha inicial antes de acessar o portal.', '');
    return;
  }
  document.getElementById('authView').hidden = true;
  document.getElementById('portalView').hidden = false;
  const client = state.context.client || {};
  document.getElementById('companyName').textContent = client.nome_fantasia || client.nome || '';
  document.getElementById('routeBadge').textContent = state.context.route || 'Rota pendente';
  await navigate('home');
}

function showAuth() {
  document.getElementById('authView').hidden = false;
  document.getElementById('portalView').hidden = true;
  document.getElementById('loginForm').hidden = false;
  document.getElementById('passwordForm').hidden = true;
}

function showPasswordForm() {
  document.getElementById('authView').hidden = false;
  document.getElementById('portalView').hidden = true;
  document.getElementById('loginForm').hidden = true;
  document.getElementById('passwordForm').hidden = false;
}

async function navigate(view) {
  state.currentView = view;
  document.querySelectorAll('[data-view]').forEach((button) => button.classList.toggle('active', button.dataset.view === view));
  document.querySelectorAll('.view').forEach((section) => { section.hidden = section.id !== view + 'View'; });
  if (view === 'home') await renderHome();
  if (view === 'catalog') await renderCatalogShell();
  if (view === 'quotes') await renderDocuments('cotacao');
  if (view === 'orders') await renderDocuments('pedido');
  if (view === 'profile') renderProfile();
}

async function renderHome() {
  const target = document.getElementById('homeView');
  target.innerHTML = '<div class="loading">Carregando seu resumo...</div>';
  try {
    const [quotes, orders] = await Promise.all([
      rpc('b2b_list_documents', { document_type: 'cotacao', limit_count: 5 }),
      rpc('b2b_list_documents', { document_type: 'pedido', limit_count: 5 })
    ]);
    const client = state.context.client || {};
    target.innerHTML = `
      <section class="welcome"><div><p class="eyebrow">${escapeHtml(state.context.route || '')}</p><h1>Olá, ${escapeHtml(state.context.account.contact_name || client.nome_fantasia || client.nome)}</h1><p>Preços finais e estoque atualizados pela central de dados.</p></div><button class="button primary" data-home-catalog>Consultar produtos</button></section>
      ${state.context.route_supported ? '' : '<div class="alert error">Sua UF ainda não possui uma rota comercial B2B configurada. Entre em contato com seu representante.</div>'}
      <div class="metrics"><article><span>Cotações recentes</span><strong>${quotes.length}</strong></article><article><span>Pedidos recentes</span><strong>${orders.length}</strong></article><article><span>Rota comercial</span><strong>${escapeHtml(state.context.route || 'Pendente')}</strong></article></div>
      <div class="two-columns"><section class="panel"><div class="section-title"><h2>Últimas cotações</h2><button class="link-button" data-home-view="quotes">Ver todas</button></div>${documentRows(quotes,'cotacao')}</section><section class="panel"><div class="section-title"><h2>Últimos pedidos</h2><button class="link-button" data-home-view="orders">Ver todos</button></div>${documentRows(orders,'pedido')}</section></div>`;
    target.querySelector('[data-home-catalog]')?.addEventListener('click', () => navigate('catalog'));
    target.querySelectorAll('[data-home-view]').forEach((button) => button.addEventListener('click', () => navigate(button.dataset.homeView)));
    bindDocumentRows(target);
  } catch (error) {
    target.innerHTML = `<div class="alert error">${escapeHtml(translateError(error))}</div>`;
  }
}

async function renderCatalogShell() {
  const target = document.getElementById('catalogView');
  target.innerHTML = `
    <div class="page-heading"><div><p class="eyebrow">Catálogo ${escapeHtml(state.context.route || '')}</p><h1>Produtos</h1><p>Digite peça + veículo + ano no mesmo campo, como no catálogo Yokomitsu.</p></div></div>
    <form id="catalogSearch" class="searchbar">
      <label class="catalog-keyword">Palavra-chave<input id="catalogTerm" type="search" placeholder="Ex.: caixa Hilux, amortecedor Corolla, bomba S10" autocomplete="off"></label>
      <label>Linha<select id="catalogLine"><option value="">Todas as linhas</option></select></label>
      <label class="catalog-available"><input id="catalogAvailable" type="checkbox"> Somente disponíveis</label>
      <button class="button primary" type="submit">Pesquisar</button>
    </form>
    <div id="catalogResults" class="product-grid"><div class="empty">Digite uma busca para consultar o catálogo.</div></div>`;
  document.getElementById('catalogSearch').addEventListener('submit', searchCatalog);
  try {
    const lines = await rpc('b2b_list_catalog_lines');
    const select = document.getElementById('catalogLine');
    if (!(lines || []).length) {
      select.innerHTML = '<option value="">Nenhuma linha sincronizada</option>';
      select.disabled = true;
    } else {
      lines.forEach((line) => select.insertAdjacentHTML('beforeend', `<option value="${escapeHtml(line.value)}">${escapeHtml(line.label)}</option>`));
    }
  } catch (error) {
    document.getElementById('catalogLine').innerHTML = '<option value="">Linhas indisponíveis</option>';
    document.getElementById('catalogLine').disabled = true;
  }
}

async function searchCatalog(event) {
  event.preventDefault();
  const target = document.getElementById('catalogResults');
  target.innerHTML = '<div class="loading">Consultando preços e estoque...</div>';
  try {
    state.catalog = await rpc('b2b_search_catalog', {
      search_term: document.getElementById('catalogTerm').value,
      line_filter: document.getElementById('catalogLine').value,
      only_available: document.getElementById('catalogAvailable').checked,
      limit_count: 50
    });
    if (!state.catalog.length) return target.innerHTML = '<div class="empty">Nenhum produto encontrado nessa rota.</div>';
    target.innerHTML = state.catalog.map((product, index) => productCard(product, index)).join('');
    bindProductImages(target);
    target.querySelectorAll('[data-add]').forEach((button) => button.addEventListener('click', () => addToCart(state.catalog[Number(button.dataset.add)])));
  } catch (error) {
    target.innerHTML = `<div class="alert error">${escapeHtml(translateError(error))}</div>`;
  }
}

function productCard(product, index) {
  const availability = availabilityLabel(product);
  return `<article class="product-card">
    <div class="product-image">${productImageMarkup(product)}</div>
    <div class="product-info"><small>${escapeHtml(product.product_code)} · ${escapeHtml(product.brand || '')}</small><h2>${escapeHtml(product.description || '')}</h2><p>${escapeHtml(product.application || '')}</p><div class="stock ${escapeHtml(availability.className)}">${escapeHtml(availability.text)}</div></div>
    <div class="product-buy"><strong>${money(product.final_price)}</strong><small>Preço final · ${escapeHtml(product.route)}</small><button class="button primary" type="button" data-add="${index}" ${availability.disabled ? 'disabled' : ''}>Adicionar</button></div>
  </article>`;
}

function availabilityLabel(product) {
  if (product.availability === 'NAO_IMPORTADO') return { text: 'Estoque não importado', className: 'unknown', disabled: false };
  if (product.availability === 'TRANSFERENCIA_PR') return { text: `Disponível via PR: ${number(product.pr_transfer_available_qty)}`, className: 'transfer', disabled: false };
  if (product.availability === 'INDISPONIVEL') return { text: 'Indisponível', className: 'out', disabled: false };
  return { text: `Disponível: ${product.source_display_value || number(product.available_qty)}`, className: 'available', disabled: false };
}

function addToCart(product) {
  const existing = state.cart.find((item) => item.product_code === product.product_code);
  if (existing) existing.quantity += 1;
  else state.cart.push({ ...product, quantity: 1 });
  updateCartButton();
}

function updateCartButton() {
  const count = state.cart.reduce((sum, item) => sum + Number(item.quantity || 0), 0);
  document.getElementById('cartCount').textContent = number(count);
  document.getElementById('cartButton').hidden = count === 0;
}

function openCart() {
  renderCart();
  document.getElementById('cartDialog').showModal();
}

function renderCart() {
  const target = document.getElementById('cartContent');
  const total = state.cart.reduce((sum, item) => sum + item.final_price * item.quantity, 0);
  target.innerHTML = `<div class="dialog-heading"><div><p class="eyebrow">Sua seleção</p><h2>Finalizar documento</h2></div><button class="icon-button" data-close type="button" aria-label="Fechar">×</button></div>
    <div class="type-toggle"><button class="${state.documentType === 'cotacao' ? 'active' : ''}" data-type="cotacao" type="button">Cotação</button><button class="${state.documentType === 'pedido' ? 'active' : ''}" data-type="pedido" type="button">Pedido</button></div>
    <div class="cart-list">${state.cart.map((item, index) => `<article><div><strong>${escapeHtml(item.product_code)}</strong><span>${escapeHtml(item.description)}</span></div><label>Qtd.<input type="number" min="1" step="1" value="${item.quantity}" data-qty="${index}"></label><strong>${money(item.final_price * item.quantity)}</strong><button class="icon-button" data-remove="${index}" type="button" aria-label="Remover">×</button></article>`).join('')}</div>
    <label>Observação<textarea id="cartNote" maxlength="1000" placeholder="Informações para o atendimento"></textarea></label>
    <div class="cart-total"><span>Total</span><strong>${money(total)}</strong></div>
    <button id="submitDocument" class="button primary full" type="button">${state.documentType === 'pedido' ? 'Enviar pedido' : 'Gerar cotação'}</button><p id="cartMessage" class="message" aria-live="polite"></p>`;
  target.querySelector('[data-close]').addEventListener('click', () => document.getElementById('cartDialog').close());
  target.querySelectorAll('[data-type]').forEach((button) => button.addEventListener('click', () => { state.documentType = button.dataset.type; renderCart(); }));
  target.querySelectorAll('[data-qty]').forEach((input) => input.addEventListener('change', () => { state.cart[Number(input.dataset.qty)].quantity = Math.max(1, Number(input.value || 1)); renderCart(); updateCartButton(); }));
  target.querySelectorAll('[data-remove]').forEach((button) => button.addEventListener('click', () => { state.cart.splice(Number(button.dataset.remove), 1); if (!state.cart.length) document.getElementById('cartDialog').close(); else renderCart(); updateCartButton(); }));
  document.getElementById('submitDocument').addEventListener('click', submitDocument);
}

async function submitDocument() {
  const button = document.getElementById('submitDocument');
  const message = document.getElementById('cartMessage');
  button.disabled = true;
  setMessage(message, 'Validando preço e estoque...', '');
  try {
    const requestPayload = {
      observacao: document.getElementById('cartNote').value,
      items: state.cart.map((item) => ({ codigo: item.product_code, quantidade: item.quantity }))
    };
    const requestFingerprint = JSON.stringify({ document_type: state.documentType, ...requestPayload });
    if (!state.pendingSubmission || state.pendingSubmission.fingerprint !== requestFingerprint) {
      state.pendingSubmission = { fingerprint: requestFingerprint, idempotencyKey: crypto.randomUUID() };
    }
    const result = await rpc('b2b_create_document', {
      document_type: state.documentType,
      payload: {
        idempotency_key: state.pendingSubmission.idempotencyKey,
        ...requestPayload
      }
    });
    const numberText = result.numero_pedido || result.numero_cotacao;
    setMessage(message, `${state.documentType === 'pedido' ? 'Pedido' : 'Cotação'} ${numberText} criado com sucesso.`, 'success');
    state.pendingSubmission = null;
    state.cart = [];
    updateCartButton();
    setTimeout(() => { document.getElementById('cartDialog').close(); navigate(state.documentType === 'pedido' ? 'orders' : 'quotes'); }, 900);
  } catch (error) {
    button.disabled = false;
    setMessage(message, translateError(error), 'error');
  }
}

async function renderDocuments(type) {
  const target = document.getElementById(type === 'pedido' ? 'ordersView' : 'quotesView');
  target.innerHTML = '<div class="loading">Carregando documentos...</div>';
  try {
    const rows = await rpc('b2b_list_documents', { document_type: type, limit_count: 100 });
    target.innerHTML = `<div class="page-heading"><div><p class="eyebrow">Histórico da empresa</p><h1>${type === 'pedido' ? 'Pedidos' : 'Cotações'}</h1></div><button class="button primary" data-new-document type="button">Novo</button></div><section class="panel">${documentRows(rows,type)}</section>`;
    target.querySelector('[data-new-document]').addEventListener('click', () => navigate('catalog'));
    bindDocumentRows(target);
  } catch (error) {
    target.innerHTML = `<div class="alert error">${escapeHtml(translateError(error))}</div>`;
  }
}

function documentRows(rows, type) {
  if (!rows.length) return '<div class="empty">Nenhum documento encontrado.</div>';
  return `<div class="document-list">${rows.map((row) => `<button type="button" data-document-id="${escapeHtml(row.id)}" data-document-type="${type}"><span><small>${dateTime(row.created_at)}</small><strong>${type === 'pedido' ? 'Pedido' : 'Cotação'} ${escapeHtml(row.numero)}</strong></span><span><small>${escapeHtml(statusLabel(row.status))}</small><strong>${money(row.total)}</strong></span></button>`).join('')}</div>`;
}

function bindDocumentRows(target) {
  target.querySelectorAll('[data-document-id]').forEach((button) => button.addEventListener('click', () => openDocument(button.dataset.documentType, button.dataset.documentId)));
}

async function openDocument(type, id) {
  const dialog = document.getElementById('documentDialog');
  const target = document.getElementById('documentContent');
  target.innerHTML = '<div class="loading">Carregando documento...</div>';
  dialog.showModal();
  try {
    const doc = await rpc('b2b_get_document', { document_type: type, target_id: id });
    target.innerHTML = `<div class="dialog-heading"><div><p class="eyebrow">${type === 'pedido' ? 'Pedido' : 'Cotação'}</p><h2>${escapeHtml(doc.numero)}</h2><p>${dateTime(doc.created_at)} · ${escapeHtml(statusLabel(doc.status))}</p></div><button class="icon-button" data-close type="button">×</button></div><div class="document-items">${doc.items.map((item) => `<article><div><strong>${escapeHtml(item.codigo)}</strong><span>${escapeHtml(item.descricao)}</span></div><span>${number(item.quantidade)} × ${money(item.preco_unitario)}</span><strong>${money(item.total_item)}</strong></article>`).join('')}</div><div class="cart-total"><span>Total</span><strong>${money(doc.total)}</strong></div>${doc.observacao ? `<div class="note"><strong>Observação</strong><p>${escapeHtml(doc.observacao)}</p></div>` : ''}`;
    target.querySelector('[data-close]').addEventListener('click', () => dialog.close());
  } catch (error) {
    target.innerHTML = `<div class="alert error">${escapeHtml(translateError(error))}</div><button class="button" data-close>Fechar</button>`;
    target.querySelector('[data-close]').addEventListener('click', () => dialog.close());
  }
}

function renderProfile() {
  const client = state.context.client || {};
  const target = document.getElementById('profileView');
  const fields = [['Razão social',client.nome],['Nome fantasia',client.nome_fantasia],['Código SAP',client.codigo_sap_cliente],['CNPJ',client.cnpj],['Telefone',client.telefone],['E-mail',client.email],['Cidade / UF',[client.cidade,client.estado].filter(Boolean).join(' / ')],['Endereço',client.endereco]];
  target.innerHTML = `<div class="page-heading"><div><p class="eyebrow">Cadastro vinculado</p><h1>Minha empresa</h1><p>Alterações passam por validação da equipe comercial.</p></div></div><section class="panel profile-grid">${fields.map(([label,value]) => `<article><span>${escapeHtml(label)}</span><strong>${escapeHtml(value || '—')}</strong></article>`).join('')}</section><section class="panel"><div class="section-title"><h2>Solicitar alteração</h2></div><form id="profileChangeForm" class="profile-form"><label>Telefone<input name="telefone" value="${escapeHtml(client.telefone || '')}"></label><label>E-mail<input name="email" type="email" value="${escapeHtml(client.email || '')}"></label><label class="wide">Endereço<input name="endereco" value="${escapeHtml(client.endereco || '')}"></label><label>Cidade<input name="cidade" value="${escapeHtml(client.cidade || '')}"></label><label>UF<input name="estado" maxlength="2" value="${escapeHtml(client.estado || '')}"></label><button class="button primary" type="submit">Enviar para análise</button><p id="profileMessage" class="message"></p></form></section>`;
  document.getElementById('profileChangeForm').addEventListener('submit', submitProfileChange);
}

async function submitProfileChange(event) {
  event.preventDefault();
  const form = new FormData(event.currentTarget);
  const message = document.getElementById('profileMessage');
  try {
    await rpc('submit_b2b_profile_change', { requested_data: Object.fromEntries(form.entries()) });
    setMessage(message, 'Solicitação enviada. A equipe comercial fará a validação.', 'success');
  } catch (error) {
    setMessage(message, translateError(error), 'error');
  }
}

function statusLabel(status) {
  return String(status || '').replaceAll('_',' ').toLowerCase().replace(/(^|\s)\S/g, (letter) => letter.toUpperCase());
}

function closeDialogOnBackdrop(event) {
  if (event.target === event.currentTarget) event.currentTarget.close();
}

function setMessage(node, text, type) {
  node.textContent = text;
  node.className = 'message' + (type ? ' ' + type : '');
}

function translateError(error) {
  const message = String(error?.message || error || 'Erro inesperado');
  const known = {
    'Invalid login credentials': 'E-mail ou senha inválidos.',
    'Email not confirmed': 'Confirme seu e-mail antes de entrar.',
    'ROTA_B2B_NAO_CONFIGURADA': 'Sua UF ainda não possui uma rota B2B configurada.',
    'ESTOQUE_B2B_NAO_IMPORTADO': 'O estoque desta filial ainda não foi confirmado. Gere uma cotação ou fale com seu representante.',
    'ESTOQUE_B2B_INSUFICIENTE': 'Estoque insuficiente para concluir este pedido.',
    'ESTOQUE_B2B_INSUFICIENTE_SP_PR': 'A soma dos estoques de SP e PR não atende este pedido.',
    'ESTOQUE_PR_NAO_IMPORTADO': 'O saldo de transferência do PR ainda não foi confirmado.',
    'PRECO_B2B_INDISPONIVEL': 'Um dos produtos está sem preço final aprovado para sua rota.',
    'ALTERACAO_JA_PENDENTE': 'Já existe uma solicitação de alteração em análise.'
  };
  const key = Object.keys(known).find((code) => message.includes(code));
  return key ? known[key] : message;
}
