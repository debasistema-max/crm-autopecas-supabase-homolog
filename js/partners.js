let partnersState = {
  tab: 'clientes',
  clients: [],
  carriers: [],
  currentClientProfile: null,
  currentB2BClient: null,
  maxDiscountPercent: 10
};

async function renderBusinessPartners(container) {
  container.innerHTML = `
    <div class="module-page partner-workspace">
      ${CrmUi.renderPageHeader(
        'Clientes e transportadoras',
        'Consulte, cadastre e mantenha os parceiros usados em cotacoes e pedidos.',
        '',
        'Comercial'
      )}
      <section class="panel partner-panel">
        <nav class="partner-tabs" role="tablist" aria-label="Tipo de parceiro">
          <button class="partner-tab is-active" type="button" role="tab" aria-selected="true" data-partner-tab="clientes">Clientes</button>
          <button class="partner-tab" type="button" role="tab" aria-selected="false" data-partner-tab="transportadoras">Transportadoras</button>
        </nav>
        <div id="partnersContent" role="tabpanel" aria-live="polite">${CrmUi.renderState('loading', 'Carregando parceiros', 'Consultando cadastros autorizados para seu perfil.')}</div>
      </section>
    </div>
  `;
  document.querySelectorAll('[data-partner-tab]').forEach((button) => {
    button.addEventListener('click', async () => {
      partnersState.tab = button.dataset.partnerTab;
      await renderPartnerTab();
    });
  });
  await renderPartnerTab();
}

async function renderPartnerTab() {
  const target = document.getElementById('partnersContent');
  if (!target) return;
  target.innerHTML = CrmUi.renderState('loading', 'Carregando cadastro', 'Aguarde enquanto os dados sao consultados.');
  document.querySelectorAll('[data-partner-tab]').forEach((button) => {
    const active = button.dataset.partnerTab === partnersState.tab;
    button.classList.toggle('is-active', active);
    button.setAttribute('aria-selected', String(active));
  });
  if (partnersState.tab === 'transportadoras') {
    await renderCarriersTab(target);
  } else {
    await renderClientsTab(target);
  }
}

async function renderClientsTab(target) {
  try {
    const [rows, maxDiscountPercent] = await Promise.all([
      supabaseListBusinessClients({
        termo: document.getElementById('partnerClientSearch') ? document.getElementById('partnerClientSearch').value : ''
      }),
      supabaseGetCommercialDiscountLimit()
    ]);
    partnersState.clients = rows;
    partnersState.maxDiscountPercent = maxDiscountPercent;
    target.innerHTML = `
      <section class="partner-editor" aria-labelledby="partnerClientEditorTitle">
        <div class="section-heading"><div><h3 id="partnerClientEditorTitle">Cadastro de cliente</h3><p>Consulte o CNPJ gratuitamente ou preencha os dados manualmente.</p></div></div>
        ${renderClientForm()}
      </section>
      <div class="partner-toolbar">
        <label class="partner-search-field">Pesquisar cliente<input id="partnerClientSearch" type="search" placeholder="Codigo SAP, CNPJ, razao social ou cidade"></label>
        <button class="btn btn-secondary" id="partnerClientSearchButton" type="button">Pesquisar</button>
      </div>
      <section id="clientCommercialProfile" class="commercial-profile" hidden></section>
      <section id="clientB2BAccess" class="commercial-profile" hidden></section>
      <div class="section-heading partner-list-heading"><div><h3>Clientes cadastrados</h3><p>${rows.length} registro${rows.length === 1 ? '' : 's'} encontrado${rows.length === 1 ? '' : 's'}.</p></div></div>
      ${renderClientsTable(rows)}
    `;
    document.getElementById('partnerClientForm').addEventListener('submit', savePartnerClient);
    document.getElementById('partnerClientClearButton').addEventListener('click', clearPartnerClientForm);
    document.getElementById('partnerClientCnpjLookup').addEventListener('click', () => lookupPartnerCnpj('client'));
    document.getElementById('partnerClientCnpj').addEventListener('blur', formatPartnerCnpjInput);
    document.getElementById('partnerClientSearchButton').addEventListener('click', () => renderClientsTab(target));
    document.getElementById('partnerClientSearch').addEventListener('keydown', (event) => {
      if (event.key === 'Enter') renderClientsTab(target);
    });
    bindClientButtons();
  } catch (error) {
    target.innerHTML = CrmUi.renderState('error', 'Nao foi possivel carregar os clientes', error.message);
  }
}

function renderClientForm() {
  const canEditDiscount = getStoredSession()?.perfil === 'ADMIN';
  return `
    <form id="partnerClientForm" class="field-grid">
      <input id="partnerClientId" type="hidden">
      <label class="span-3">Codigo SAP<input id="partnerClientSap"></label>
      <label class="span-5">Razao social / Nome<input id="partnerClientName" required></label>
      <label class="span-4">Nome fantasia<input id="partnerClientFantasy"></label>
      <label class="span-4">CNPJ
        <span class="cnpj-lookup-control"><input id="partnerClientCnpj" inputmode="numeric" autocomplete="off" placeholder="00.000.000/0000-00"><button class="btn btn-secondary" id="partnerClientCnpjLookup" type="button">Consultar</button></span>
      </label>
      <label class="span-3">Telefone<input id="partnerClientPhone"></label>
      <label class="span-3">Email<input id="partnerClientEmail" type="email"></label>
      <label class="span-2">UF<input id="partnerClientState" maxlength="2"></label>
      <label class="span-4">Cidade<input id="partnerClientCity"></label>
      <label class="span-8">Endereco<input id="partnerClientAddress"></label>
      <label class="span-2">Ativo
        <select id="partnerClientActive"><option value="true">Sim</option><option value="false">Nao</option></select>
      </label>
      <label class="span-3">Desconto comercial (%)
        <input id="partnerClientDiscount" type="number" min="0" max="${escapeHtml(partnersState.maxDiscountPercent)}" step="0.01" value="0" ${canEditDiscount ? '' : 'disabled'}>
        <small>${canEditDiscount ? `Aplicado no B2B. Limite geral: ${escapeHtml(partnersState.maxDiscountPercent)}%.` : 'Somente ADMIN pode alterar.'}</small>
      </label>
      <label class="span-12">Observacoes<textarea id="partnerClientNotes"></textarea></label>
      <div class="span-12 actions-row">
        <button class="btn btn-primary" type="submit">Salvar cliente</button>
        <button class="btn btn-ghost" id="partnerClientClearButton" type="button">Novo</button>
        <p id="partnerClientMessage" class="form-message"></p>
      </div>
    </form>
  `;
}

function renderClientsTable(rows) {
  if (!rows.length) return CrmUi.renderState('empty', 'Nenhum cliente encontrado', 'Ajuste a pesquisa ou cadastre o primeiro cliente.');
  return `
    <div class="table-wrap compact-table">
      <table>
        <thead><tr><th>Cliente</th><th>CNPJ</th><th>Codigo SAP</th><th>Cidade/UF</th><th>Desc. B2B</th><th>Contato</th><th>Status</th><th></th></tr></thead>
        <tbody>
          ${rows.map((row, index) => `
            <tr>
              <td><strong>${escapeHtml(row.nome || '')}</strong><small>${escapeHtml(row.nome_fantasia || '')}</small></td>
              <td>${escapeHtml(formatCnpj(row.cnpj || ''))}</td>
              <td>${escapeHtml(row.codigo_sap_cliente || '')}</td>
              <td>${escapeHtml([row.cidade, row.estado].filter(Boolean).join('/'))}</td>
              <td>${escapeHtml(Number(row.commercial_discount_percent || 0).toLocaleString('pt-BR', { maximumFractionDigits: 2 }))}%</td>
              <td>${escapeHtml(row.telefone || '')}<small>${escapeHtml(row.email || '')}</small></td>
              <td><span class="status-pill ${row.ativo ? 'ok' : 'warn'}">${row.ativo ? 'Ativo' : 'Inativo'}</span></td>
              <td>
                <div class="actions-row compact-actions">
                  <button class="btn btn-secondary" type="button" data-open-client="${index}">Historico</button>
                  ${getStoredSession()?.perfil === 'ADMIN' ? `<button class="btn btn-secondary" type="button" data-b2b-client="${index}">Acesso B2B</button>` : ''}
                  <button class="btn btn-ghost" type="button" data-edit-client="${index}">Editar</button>
                </div>
              </td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  `;
}

function bindClientButtons() {
  document.querySelectorAll('[data-edit-client]').forEach((button) => {
    button.addEventListener('click', () => fillPartnerClientForm(partnersState.clients[Number(button.dataset.editClient)]));
  });
  document.querySelectorAll('[data-open-client]').forEach((button) => {
    button.addEventListener('click', () => openClientCommercialProfile(partnersState.clients[Number(button.dataset.openClient)]));
  });
  document.querySelectorAll('[data-b2b-client]').forEach((button) => {
    button.addEventListener('click', () => openClientB2BAccess(partnersState.clients[Number(button.dataset.b2bClient)]));
  });
}

async function openClientB2BAccess(client) {
  const target = document.getElementById('clientB2BAccess');
  if (!target || !client) return;
  partnersState.currentB2BClient = client;
  target.hidden = false;
  target.innerHTML = '<div class="empty-state compact-state">Consultando acessos B2B...</div>';
  target.scrollIntoView({ behavior: 'smooth', block: 'start' });
  try {
    const result = await supabaseManageB2BAccess('list', { client_id: client.id });
    target.innerHTML = renderClientB2BAccess(client, result.accounts || [], result.change_requests || []);
    bindClientB2BAccess(client);
  } catch (error) {
    target.innerHTML = `<div class="empty-state compact-state">${escapeHtml(error.message)}</div>`;
  }
}

function b2bChangeFieldLabel(field) {
  return ({ telefone: 'Telefone', email: 'E-mail', endereco: 'Endereço', cidade: 'Cidade', estado: 'UF' })[field] || field;
}

function normalizeB2BUsername(value) {
  return String(value || '').trim().toLowerCase().normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '').replace(/[^a-z0-9._-]+/g, '').slice(0, 50);
}

function isValidB2BUsername(value) {
  return /^[a-z0-9][a-z0-9._-]{2,48}[a-z0-9]$/.test(String(value || ''));
}

function isValidB2BInitialPassword(value) {
  const password = String(value || '');
  return password.length >= 12 && password.length <= 72 && /[a-z]/.test(password) && /[A-Z]/.test(password) && /[0-9]/.test(password);
}

function defaultB2BUsername(client) {
  return normalizeB2BUsername(client.cnpj || client.codigo_sap_cliente || client.nome_fantasia || client.nome || '');
}

function generateB2BInitialPassword() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%';
  const bytes = crypto.getRandomValues(new Uint8Array(12));
  return `Ip9!${Array.from(bytes, (value) => alphabet[value % alphabet.length]).join('')}`;
}

function renderClientB2BAccess(client, accounts, changeRequests = []) {
  const pendingRequests = changeRequests.filter((request) => request.status === 'PENDING');
  return `
    <div class="panel-header">
      <div><p class="eyebrow">Portal exclusivo</p><h2>Acesso B2B — ${escapeHtml(client.nome_fantasia || client.nome || '')}</h2><p>O usuário verá somente este cadastro, seus documentos e o catálogo da sua rota.</p></div>
      <div class="actions-row"><a class="btn btn-secondary" href="b2b/" target="_blank" rel="noopener">Abrir portal</a><button class="btn btn-ghost" id="clientB2BClose" type="button">Fechar</button></div>
    </div>
    <section class="b2b-credentials-panel">
      <div><p class="eyebrow">Recomendado</p><h3>Acesso sem e-mail</h3><p>Crie usuário e senha inicial. O cliente será obrigado a trocar a senha ao entrar.</p></div>
      <form id="clientB2BCredentialsForm" class="b2b-access-form">
        <label>Nome do contato<input id="clientB2BCredentialContact" autocomplete="name"></label>
        <label>Usuário de acesso<input id="clientB2BUsername" autocomplete="off" autocapitalize="none" spellcheck="false" minlength="4" maxlength="50" pattern="[a-z0-9][a-z0-9._-]{2,48}[a-z0-9]" value="${escapeHtml(defaultB2BUsername(client))}" required><small>Pode ser CNPJ ou um nome exclusivo, como compras.cliente.</small></label>
        <label>Senha inicial<input id="clientB2BInitialPassword" type="text" autocomplete="off" minlength="12" maxlength="72" required><small>Mínimo de 12 caracteres, com maiúscula, minúscula e número.</small></label>
        <button class="btn btn-secondary" id="clientB2BGeneratePassword" type="button">Gerar senha</button>
        <button class="btn btn-primary" type="submit">Criar ou redefinir acesso</button>
        <p id="clientB2BCredentialMessage" class="form-message"></p>
      </form>
    </section>
    <details class="b2b-email-invite"><summary>Usar convite por e-mail (opcional)</summary>
      <form id="clientB2BInviteForm" class="b2b-access-form">
        <label>Nome do contato<input id="clientB2BContact" autocomplete="name"></label>
        <label>E-mail de acesso<input id="clientB2BEmail" type="email" autocomplete="email" value="${escapeHtml(client.email || '')}" required></label>
        <button class="btn btn-primary" type="submit">Enviar convite seguro</button>
        <p id="clientB2BMessage" class="form-message"></p>
      </form>
    </details>
    <div class="section-heading"><div><h3>Usuários vinculados</h3><p>${accounts.length} acesso${accounts.length === 1 ? '' : 's'} configurado${accounts.length === 1 ? '' : 's'}.</p></div></div>
    ${accounts.length ? `<div class="b2b-account-list">${accounts.map((account) => `
      <article><div><strong>${escapeHtml(account.contact_name || account.username || account.email)}</strong><span>${escapeHtml(account.login_mode === 'USERNAME' ? `Usuário: ${account.username}` : account.email)}</span><small>${account.must_change_password ? 'Aguardando troca da senha inicial · ' : ''}Último acesso: ${escapeHtml(account.last_login_at ? formatDateTime(account.last_login_at) : 'ainda não acessou')}</small></div><span class="status-pill ${account.active ? 'ok' : 'warn'}">${account.activation_pending ? 'Aguardando senha' : account.active ? 'Ativo' : 'Revogado'}</span>${account.must_change_password && !account.activation_pending ? '<button class="btn btn-secondary" type="button" disabled title="Crie uma nova senha inicial acima">Redefinir acima</button>' : `<button class="btn ${account.active ? 'btn-ghost' : 'btn-secondary'}" data-b2b-user="${escapeHtml(account.user_id)}" data-b2b-active="${account.activation_pending || account.active ? 'false' : 'true'}" type="button">${account.activation_pending ? 'Cancelar acesso' : account.active ? 'Revogar' : 'Reativar'}</button>`}</article>
    `).join('')}</div>` : '<div class="empty-state compact-state">Nenhum usuário B2B vinculado.</div>'}
    <div class="section-heading b2b-change-heading"><div><h3>Alterações cadastrais solicitadas</h3><p>${pendingRequests.length ? `${pendingRequests.length} aguardando análise.` : 'Nenhuma solicitação pendente.'}</p></div></div>
    ${pendingRequests.length ? `<div class="b2b-change-list">${pendingRequests.map((request) => `
      <article>
        <div><strong>Solicitação de ${escapeHtml(formatDateTime(request.created_at))}</strong>${Object.entries(request.requested_data || {}).map(([field, value]) => `<span><b>${escapeHtml(b2bChangeFieldLabel(field))}:</b> ${escapeHtml(String(value))}</span>`).join('')}</div>
        <label>Observação da análise<input data-b2b-review-note="${escapeHtml(request.id)}" maxlength="500" placeholder="Opcional"></label>
        <div class="actions-row"><button class="btn btn-primary" data-b2b-review="${escapeHtml(request.id)}" data-b2b-decision="APPROVED" type="button">Aprovar</button><button class="btn btn-ghost" data-b2b-review="${escapeHtml(request.id)}" data-b2b-decision="REJECTED" type="button">Rejeitar</button></div>
      </article>
    `).join('')}</div>` : ''}
  `;
}

function bindClientB2BAccess(client) {
  document.getElementById('clientB2BClose')?.addEventListener('click', () => {
    document.getElementById('clientB2BAccess').hidden = true;
  });
  const initialPassword = document.getElementById('clientB2BInitialPassword');
  const generatePassword = () => {
    if (!initialPassword) return;
    initialPassword.value = generateB2BInitialPassword();
    initialPassword.focus();
    initialPassword.select();
  };
  document.getElementById('clientB2BGeneratePassword')?.addEventListener('click', generatePassword);
  if (initialPassword && !initialPassword.value) generatePassword();
  document.getElementById('clientB2BCredentialsForm')?.addEventListener('submit', async (event) => {
    event.preventDefault();
    const message = document.getElementById('clientB2BCredentialMessage');
    const usernameInput = document.getElementById('clientB2BUsername');
    const submitButton = event.currentTarget.querySelector('button[type="submit"]');
    const username = normalizeB2BUsername(usernameInput.value);
    usernameInput.value = username;
    if (!isValidB2BUsername(username)) {
      message.style.color = 'var(--accent)';
      message.textContent = 'Use de 4 a 50 caracteres: letras minúsculas, números, ponto, hífen ou sublinhado.';
      usernameInput.focus();
      return;
    }
    if (!isValidB2BInitialPassword(initialPassword.value)) {
      message.style.color = 'var(--accent)';
      message.textContent = 'A senha precisa ter de 12 a 72 caracteres, com maiúscula, minúscula e número.';
      initialPassword.focus();
      return;
    }
    message.style.color = 'var(--muted)';
    message.textContent = 'Criando credencial segura...';
    submitButton.disabled = true;
    try {
      await supabaseManageB2BAccess('create_credentials', {
        client_id: client.id,
        username,
        password: initialPassword.value,
        contact_name: document.getElementById('clientB2BCredentialContact').value
      });
      message.style.color = 'var(--success)';
      message.textContent = `Acesso pronto. Entregue o usuário “${username}” e a senha acima por um canal seguro.`;
    } catch (error) {
      message.style.color = 'var(--accent)';
      message.textContent = error.message;
    } finally {
      submitButton.disabled = false;
    }
  });
  document.getElementById('clientB2BInviteForm')?.addEventListener('submit', async (event) => {
    event.preventDefault();
    const message = document.getElementById('clientB2BMessage');
    message.style.color = 'var(--muted)';
    message.textContent = 'Criando vínculo e enviando convite...';
    try {
      await supabaseManageB2BAccess('invite', {
        client_id: client.id,
        email: document.getElementById('clientB2BEmail').value,
        contact_name: document.getElementById('clientB2BContact').value
      });
      message.style.color = 'var(--success)';
      message.textContent = 'Convite enviado. O cliente definirá a própria senha.';
      setTimeout(() => openClientB2BAccess(client), 700);
    } catch (error) {
      message.style.color = 'var(--accent)';
      message.textContent = error.message;
    }
  });
  document.querySelectorAll('[data-b2b-user]').forEach((button) => {
    button.addEventListener('click', async () => {
      button.disabled = true;
      try {
        await supabaseManageB2BAccess('set_active', {
          client_id: client.id,
          user_id: button.dataset.b2bUser,
          active: button.dataset.b2bActive === 'true'
        });
        await openClientB2BAccess(client);
      } catch (error) {
        button.disabled = false;
        window.alert(error.message);
      }
    });
  });
  document.querySelectorAll('[data-b2b-review]').forEach((button) => {
    button.addEventListener('click', async () => {
      button.disabled = true;
      const requestId = button.dataset.b2bReview;
      try {
        await supabaseManageB2BAccess('review_change', {
          client_id: client.id,
          request_id: requestId,
          decision: button.dataset.b2bDecision,
          review_notes: document.querySelector(`[data-b2b-review-note="${requestId}"]`)?.value || ''
        });
        await openClientB2BAccess(client);
      } catch (error) {
        button.disabled = false;
        window.alert(error.message);
      }
    });
  });
}

function fillPartnerClientForm(row) {
  document.getElementById('partnerClientId').value = row.id || '';
  document.getElementById('partnerClientSap').value = row.codigo_sap_cliente || '';
  document.getElementById('partnerClientName').value = row.nome || '';
  document.getElementById('partnerClientFantasy').value = row.nome_fantasia || '';
  document.getElementById('partnerClientCnpj').value = formatCnpj(row.cnpj || '');
  document.getElementById('partnerClientPhone').value = row.telefone || '';
  document.getElementById('partnerClientEmail').value = row.email || '';
  document.getElementById('partnerClientState').value = row.estado || '';
  document.getElementById('partnerClientCity').value = row.cidade || '';
  document.getElementById('partnerClientAddress').value = row.endereco || '';
  document.getElementById('partnerClientActive').value = row.ativo === false ? 'false' : 'true';
  document.getElementById('partnerClientDiscount').value = Number(row.commercial_discount_percent || 0);
  document.getElementById('partnerClientNotes').value = row.observacoes || '';
  document.getElementById('partnerClientName').focus();
}

function clearPartnerClientForm() {
  document.getElementById('partnerClientForm').reset();
  document.getElementById('partnerClientId').value = '';
  document.getElementById('partnerClientActive').value = 'true';
  document.getElementById('partnerClientDiscount').value = '0';
  document.getElementById('partnerClientMessage').textContent = '';
}

async function savePartnerClient(event) {
  event.preventDefault();
  const message = document.getElementById('partnerClientMessage');
  message.style.color = 'var(--muted)';
  message.textContent = 'Salvando cliente...';
  try {
    await supabaseSaveBusinessClient({
      id: document.getElementById('partnerClientId').value,
      codigo_sap_cliente: document.getElementById('partnerClientSap').value,
      nome: document.getElementById('partnerClientName').value,
      nome_fantasia: document.getElementById('partnerClientFantasy').value,
      cnpj: document.getElementById('partnerClientCnpj').value,
      telefone: document.getElementById('partnerClientPhone').value,
      email: document.getElementById('partnerClientEmail').value,
      estado: document.getElementById('partnerClientState').value,
      cidade: document.getElementById('partnerClientCity').value,
      endereco: document.getElementById('partnerClientAddress').value,
      ativo: document.getElementById('partnerClientActive').value === 'true',
      commercial_discount_percent: Number(document.getElementById('partnerClientDiscount').value || 0),
      observacoes: document.getElementById('partnerClientNotes').value
    });
    message.style.color = 'var(--success)';
    message.textContent = 'Cliente salvo.';
    await renderClientsTab(document.getElementById('partnersContent'));
  } catch (error) {
    message.style.color = 'var(--accent)';
    message.textContent = error.message;
  }
}

async function openClientCommercialProfile(client) {
  const target = document.getElementById('clientCommercialProfile');
  if (!target || !client) return;
  target.hidden = false;
  target.innerHTML = '<div class="empty-state compact-state">Carregando historico comercial...</div>';
  target.scrollIntoView({ behavior: 'smooth', block: 'start' });
  try {
    const profile = await supabaseGetCustomerCommercialProfile(client.id);
    partnersState.currentClientProfile = profile;
    target.innerHTML = renderClientCommercialProfile(profile);
    bindClientCommercialProfile(profile);
  } catch (error) {
    target.innerHTML = `<div class="empty-state compact-state">${escapeHtml(error.message)}</div>`;
  }
}

function renderClientCommercialProfile(profile) {
  const client = profile.client || {};
  const metrics = profile.metrics || {};
  return `
    <div class="panel-header">
      <div>
        <h2>${escapeHtml(client.nome || '')}</h2>
        <p>${escapeHtml([client.codigo_sap_cliente, formatCnpj(client.cnpj || ''), client.cidade, client.estado].filter(Boolean).join(' - '))}</p>
      </div>
      <div class="actions-row">
        <button class="btn ${profile.favorite ? 'btn-primary' : 'btn-secondary'}" id="clientFavoriteButton" type="button">${profile.favorite ? 'Favorito' : 'Marcar favorito'}</button>
        <button class="btn btn-ghost" id="clientProfileCloseButton" type="button">Fechar</button>
      </div>
    </div>
    <div class="commercial-metrics">
      <article><span>Valor comprado</span><strong>${money(metrics.purchased_value || 0)}</strong></article>
      <article><span>Ticket medio</span><strong>${money(metrics.average_ticket || 0)}</strong></article>
      <article><span>Pedidos</span><strong>${Number(metrics.total_orders || 0)}</strong></article>
      <article><span>Cotacoes</span><strong>${Number(metrics.total_quotations || 0)}</strong></article>
      <article><span>Conversao</span><strong>${Number(metrics.conversion_rate || 0).toFixed(2)}%</strong></article>
    </div>
    <div class="commercial-grid">
      <section class="commercial-block">
        <div class="panel-header"><div><h3>Ultimos pedidos</h3></div></div>
        ${renderCommercialDocumentList('pedidos', profile.orders || [])}
      </section>
      <section class="commercial-block">
        <div class="panel-header"><div><h3>Ultimas cotacoes</h3></div></div>
        ${renderCommercialDocumentList('cotacoes', profile.quotations || [])}
      </section>
      <section class="commercial-block">
        <div class="panel-header"><div><h3>Observacoes comerciais</h3></div></div>
        <form id="clientNoteForm" class="commercial-note-form">
          <textarea id="clientCommercialNote" placeholder="Nova observacao comercial"></textarea>
          <button class="btn btn-primary" type="submit">Salvar observacao</button>
          <p id="clientCommercialMessage" class="form-message"></p>
        </form>
        ${renderClientNotes(profile.notes || [])}
      </section>
      <section class="commercial-block">
        <div class="panel-header"><div><h3>Timeline do cliente</h3></div></div>
        ${renderClientTimeline(profile.timeline || [])}
      </section>
    </div>
  `;
}

function renderCommercialDocumentList(kind, rows) {
  if (!rows.length) return '<div class="empty-state compact-state">Nenhum registro.</div>';
  const numberKey = kind === 'pedidos' ? 'numero_pedido' : 'numero_cotacao';
  return `
    <div class="commercial-list">
      ${rows.map((row) => `
        <article>
          <span>${escapeHtml(formatDateTime(row.created_at))}</span>
          <strong>${escapeHtml(row[numberKey] || '')}</strong>
          <small>${escapeHtml(formatDocumentStatus(kind, row.status))} - ${money(row.total || 0)}</small>
        </article>
      `).join('')}
    </div>
  `;
}

function renderClientNotes(rows) {
  if (!rows.length) return '<div class="empty-state compact-state">Nenhuma observacao registrada.</div>';
  return `
    <div class="commercial-list note-list">
      ${rows.map((row) => `
        <article>
          <span>${escapeHtml(formatDateTime(row.created_at))}</span>
          <strong>${escapeHtml(row.usuario || 'Usuario')}</strong>
          <small>${escapeHtml(row.note || '')}</small>
        </article>
      `).join('')}
    </div>
  `;
}

function renderClientTimeline(rows) {
  if (!rows.length) return '<div class="empty-state compact-state">Sem historico comercial.</div>';
  return `
    <ol class="commercial-timeline">
      ${rows
        .slice()
        .sort((a, b) => new Date(b.event_at || 0) - new Date(a.event_at || 0))
        .map((row) => `
          <li>
            <span>${escapeHtml(formatDateTime(row.event_at))}</span>
            <strong>${escapeHtml(row.title || row.event_type || '')}</strong>
            <small>${escapeHtml(row.description || '')}${row.amount ? ' - ' + money(row.amount) : ''}</small>
          </li>
        `).join('')}
    </ol>
  `;
}

function bindClientCommercialProfile(profile) {
  const client = profile.client || {};
  document.getElementById('clientProfileCloseButton').addEventListener('click', () => {
    const target = document.getElementById('clientCommercialProfile');
    target.hidden = true;
    target.innerHTML = '';
  });
  document.getElementById('clientFavoriteButton').addEventListener('click', async () => {
    const button = document.getElementById('clientFavoriteButton');
    const next = !button.classList.contains('btn-primary');
    button.disabled = true;
    try {
      const favorite = await supabaseToggleCustomerFavorite(client.id, next);
      button.className = favorite ? 'btn btn-primary' : 'btn btn-secondary';
      button.textContent = favorite ? 'Favorito' : 'Marcar favorito';
    } catch (error) {
      const message = document.getElementById('clientCommercialMessage');
      if (message) {
        message.style.color = 'var(--accent)';
        message.textContent = error.message;
      }
    } finally {
      button.disabled = false;
    }
  });
  document.getElementById('clientNoteForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    const note = document.getElementById('clientCommercialNote').value;
    const message = document.getElementById('clientCommercialMessage');
    message.style.color = 'var(--muted)';
    message.textContent = 'Salvando observacao...';
    try {
      await supabaseAddCustomerNote(client.id, note);
      message.style.color = 'var(--success)';
      message.textContent = 'Observacao salva.';
      await openClientCommercialProfile(client);
    } catch (error) {
      message.style.color = 'var(--accent)';
      message.textContent = error.message;
    }
  });
}

async function renderCarriersTab(target) {
  try {
    const rows = await supabaseListBusinessCarriers({
      termo: document.getElementById('partnerCarrierSearch') ? document.getElementById('partnerCarrierSearch').value : ''
    });
    partnersState.carriers = rows;
    target.innerHTML = `
      <section class="partner-editor" aria-labelledby="partnerCarrierEditorTitle">
        <div class="section-heading"><div><h3 id="partnerCarrierEditorTitle">Cadastro de transportadora</h3><p>Consulte o CNPJ gratuitamente ou preencha os dados manualmente.</p></div></div>
        ${renderCarrierForm()}
      </section>
      <div class="partner-toolbar">
        <label class="partner-search-field">Pesquisar transportadora<input id="partnerCarrierSearch" type="search" placeholder="Nome, CNPJ ou cidade"></label>
        <button class="btn btn-secondary" id="partnerCarrierSearchButton" type="button">Pesquisar</button>
      </div>
      <div class="section-heading partner-list-heading"><div><h3>Transportadoras cadastradas</h3><p>${rows.length} registro${rows.length === 1 ? '' : 's'} encontrado${rows.length === 1 ? '' : 's'}.</p></div></div>
      ${renderCarriersTable(rows)}
    `;
    document.getElementById('partnerCarrierForm').addEventListener('submit', savePartnerCarrier);
    document.getElementById('partnerCarrierClearButton').addEventListener('click', clearPartnerCarrierForm);
    document.getElementById('partnerCarrierCnpjLookup').addEventListener('click', () => lookupPartnerCnpj('carrier'));
    document.getElementById('partnerCarrierCnpj').addEventListener('blur', formatPartnerCnpjInput);
    document.getElementById('partnerCarrierSearchButton').addEventListener('click', () => renderCarriersTab(target));
    bindCarrierEditButtons();
  } catch (error) {
    target.innerHTML = CrmUi.renderState('error', 'Nao foi possivel carregar as transportadoras', error.message);
  }
}

function renderCarrierForm() {
  return `
    <form id="partnerCarrierForm" class="field-grid">
      <input id="partnerCarrierId" type="hidden">
      <label class="span-5">Transportadora<input id="partnerCarrierName" required></label>
      <label class="span-4">CNPJ
        <span class="cnpj-lookup-control"><input id="partnerCarrierCnpj" inputmode="numeric" autocomplete="off" placeholder="00.000.000/0000-00"><button class="btn btn-secondary" id="partnerCarrierCnpjLookup" type="button">Consultar</button></span>
      </label>
      <label class="span-3">Telefone<input id="partnerCarrierPhone"></label>
      <label class="span-3">Email<input id="partnerCarrierEmail" type="email"></label>
      <label class="span-2">UF<input id="partnerCarrierState" maxlength="2"></label>
      <label class="span-4">Cidade<input id="partnerCarrierCity"></label>
      <label class="span-8">Endereco<input id="partnerCarrierAddress"></label>
      <label class="span-2">Ativo
        <select id="partnerCarrierActive"><option value="true">Sim</option><option value="false">Nao</option></select>
      </label>
      <label class="span-12">Observacoes<textarea id="partnerCarrierNotes"></textarea></label>
      <div class="span-12 actions-row">
        <button class="btn btn-primary" type="submit">Salvar transportadora</button>
        <button class="btn btn-ghost" id="partnerCarrierClearButton" type="button">Nova</button>
        <p id="partnerCarrierMessage" class="form-message"></p>
      </div>
    </form>
  `;
}

function renderCarriersTable(rows) {
  if (!rows.length) return CrmUi.renderState('empty', 'Nenhuma transportadora encontrada', 'Ajuste a pesquisa ou cadastre a primeira transportadora.');
  return `
    <div class="table-wrap compact-table">
      <table>
        <thead><tr><th>Transportadora</th><th>CNPJ</th><th>Cidade/UF</th><th>Contato</th><th>Status</th><th></th></tr></thead>
        <tbody>
          ${rows.map((row, index) => `
            <tr>
              <td><strong>${escapeHtml(row.nome || '')}</strong><small>${escapeHtml(row.endereco || '')}</small></td>
              <td>${escapeHtml(formatCnpj(row.cnpj || ''))}</td>
              <td>${escapeHtml([row.cidade, row.estado].filter(Boolean).join('/'))}</td>
              <td>${escapeHtml(row.telefone || '')}<small>${escapeHtml(row.email || '')}</small></td>
              <td><span class="status-pill ${row.ativo ? 'ok' : 'warn'}">${row.ativo ? 'Ativa' : 'Inativa'}</span></td>
              <td><button class="btn btn-secondary" type="button" data-edit-carrier="${index}">Editar</button></td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  `;
}

function bindCarrierEditButtons() {
  document.querySelectorAll('[data-edit-carrier]').forEach((button) => {
    button.addEventListener('click', () => fillPartnerCarrierForm(partnersState.carriers[Number(button.dataset.editCarrier)]));
  });
}

function fillPartnerCarrierForm(row) {
  document.getElementById('partnerCarrierId').value = row.id || '';
  document.getElementById('partnerCarrierName').value = row.nome || '';
  document.getElementById('partnerCarrierCnpj').value = formatCnpj(row.cnpj || '');
  document.getElementById('partnerCarrierPhone').value = row.telefone || '';
  document.getElementById('partnerCarrierEmail').value = row.email || '';
  document.getElementById('partnerCarrierState').value = row.estado || '';
  document.getElementById('partnerCarrierCity').value = row.cidade || '';
  document.getElementById('partnerCarrierAddress').value = row.endereco || '';
  document.getElementById('partnerCarrierActive').value = row.ativo === false ? 'false' : 'true';
  document.getElementById('partnerCarrierNotes').value = row.observacoes || '';
  document.getElementById('partnerCarrierName').focus();
}

function clearPartnerCarrierForm() {
  document.getElementById('partnerCarrierForm').reset();
  document.getElementById('partnerCarrierId').value = '';
  document.getElementById('partnerCarrierActive').value = 'true';
  document.getElementById('partnerCarrierMessage').textContent = '';
}

async function savePartnerCarrier(event) {
  event.preventDefault();
  const message = document.getElementById('partnerCarrierMessage');
  message.style.color = 'var(--muted)';
  message.textContent = 'Salvando transportadora...';
  try {
    await supabaseSaveBusinessCarrier({
      id: document.getElementById('partnerCarrierId').value,
      nome: document.getElementById('partnerCarrierName').value,
      cnpj: document.getElementById('partnerCarrierCnpj').value,
      telefone: document.getElementById('partnerCarrierPhone').value,
      email: document.getElementById('partnerCarrierEmail').value,
      estado: document.getElementById('partnerCarrierState').value,
      cidade: document.getElementById('partnerCarrierCity').value,
      endereco: document.getElementById('partnerCarrierAddress').value,
      ativo: document.getElementById('partnerCarrierActive').value === 'true',
      observacoes: document.getElementById('partnerCarrierNotes').value
    });
    message.style.color = 'var(--success)';
    message.textContent = 'Transportadora salva.';
    await renderCarriersTab(document.getElementById('partnersContent'));
  } catch (error) {
    message.style.color = 'var(--accent)';
    message.textContent = error.message;
  }
}

function formatPartnerCnpjInput(event) {
  event.target.value = formatCnpj(event.target.value);
}

function setPartnerLookupField(id, value) {
  const element = document.getElementById(id);
  if (element && value) element.value = value;
}

async function lookupPartnerCnpj(kind) {
  const isClient = kind === 'client';
  const prefix = isClient ? 'partnerClient' : 'partnerCarrier';
  const button = document.getElementById(`${prefix}CnpjLookup`);
  const input = document.getElementById(`${prefix}Cnpj`);
  const message = document.getElementById(`${prefix}Message`);
  button.disabled = true;
  message.style.color = 'var(--muted)';
  message.textContent = 'Consultando CNPJ gratuitamente...';
  try {
    const company = await fetchBusinessRegistryByCnpj(input.value);
    input.value = formatCnpj(company.cnpj || input.value);
    setPartnerLookupField(`${prefix}Name`, company.legal_name);
    if (isClient) setPartnerLookupField('partnerClientFantasy', company.trade_name);
    setPartnerLookupField(`${prefix}Phone`, company.phone);
    setPartnerLookupField(`${prefix}Email`, company.email);
    setPartnerLookupField(`${prefix}State`, company.state);
    setPartnerLookupField(`${prefix}City`, company.city);
    setPartnerLookupField(`${prefix}Address`, company.address);
    message.style.color = 'var(--success)';
    message.textContent = `Dados encontrados via ${company.source || 'consulta pública'}. Confira antes de salvar.`;
  } catch (error) {
    message.style.color = 'var(--accent)';
    message.textContent = `${error.message || 'Não foi possível consultar o CNPJ.'} O preenchimento manual continua disponível.`;
  } finally {
    button.disabled = false;
  }
}
