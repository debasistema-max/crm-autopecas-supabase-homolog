let partnersState = {
  tab: 'clientes',
  clients: [],
  carriers: [],
  currentClientProfile: null
};

async function renderBusinessPartners(container) {
  container.innerHTML = `
    <section class="panel">
      <div class="panel-header">
        <div>
          <h2>Parceiros de Negocios</h2>
          <p>Cadastre e edite clientes e transportadoras usados nos pedidos.</p>
        </div>
      </div>
      <div class="actions-row" style="margin-bottom: 16px;">
        <button class="btn btn-primary" type="button" data-partner-tab="clientes">Clientes</button>
        <button class="btn btn-secondary" type="button" data-partner-tab="transportadoras">Transportadoras</button>
      </div>
      <div id="partnersContent"><div class="empty-state">Carregando parceiros...</div></div>
    </section>
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
  target.innerHTML = '<div class="empty-state compact-state">Carregando...</div>';
  document.querySelectorAll('[data-partner-tab]').forEach((button) => {
    const active = button.dataset.partnerTab === partnersState.tab;
    button.className = active ? 'btn btn-primary' : 'btn btn-secondary';
  });
  if (partnersState.tab === 'transportadoras') {
    await renderCarriersTab(target);
  } else {
    await renderClientsTab(target);
  }
}

async function renderClientsTab(target) {
  try {
    const rows = await supabaseListBusinessClients({
      termo: document.getElementById('partnerClientSearch') ? document.getElementById('partnerClientSearch').value : ''
    });
    partnersState.clients = rows;
    target.innerHTML = `
      ${renderClientForm()}
      <div class="actions-row" style="margin: 16px 0;">
        <label>Pesquisar cliente<input id="partnerClientSearch" placeholder="Codigo SAP, CNPJ, razao social ou cidade"></label>
        <button class="btn btn-secondary" id="partnerClientSearchButton" type="button">Pesquisar</button>
      </div>
      <section id="clientCommercialProfile" class="commercial-profile" hidden></section>
      ${renderClientsTable(rows)}
    `;
    document.getElementById('partnerClientForm').addEventListener('submit', savePartnerClient);
    document.getElementById('partnerClientClearButton').addEventListener('click', clearPartnerClientForm);
    document.getElementById('partnerClientSearchButton').addEventListener('click', () => renderClientsTab(target));
    document.getElementById('partnerClientSearch').addEventListener('keydown', (event) => {
      if (event.key === 'Enter') renderClientsTab(target);
    });
    bindClientButtons();
  } catch (error) {
    target.innerHTML = `<div class="empty-state">${escapeHtml(error.message)}</div>`;
  }
}

function renderClientForm() {
  return `
    <form id="partnerClientForm" class="field-grid">
      <input id="partnerClientId" type="hidden">
      <label class="span-3">Codigo SAP<input id="partnerClientSap"></label>
      <label class="span-5">Razao social / Nome<input id="partnerClientName" required></label>
      <label class="span-4">Nome fantasia<input id="partnerClientFantasy"></label>
      <label class="span-3">CNPJ<input id="partnerClientCnpj"></label>
      <label class="span-3">Telefone<input id="partnerClientPhone"></label>
      <label class="span-3">Email<input id="partnerClientEmail" type="email"></label>
      <label class="span-2">UF<input id="partnerClientState" maxlength="2"></label>
      <label class="span-4">Cidade<input id="partnerClientCity"></label>
      <label class="span-8">Endereco<input id="partnerClientAddress"></label>
      <label class="span-2">Ativo
        <select id="partnerClientActive"><option value="true">Sim</option><option value="false">Nao</option></select>
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
  if (!rows.length) return '<div class="empty-state compact-state">Nenhum cliente encontrado.</div>';
  return `
    <div class="table-wrap compact-table">
      <table>
        <thead><tr><th>Cliente</th><th>CNPJ</th><th>Codigo SAP</th><th>Cidade/UF</th><th>Contato</th><th>Status</th><th></th></tr></thead>
        <tbody>
          ${rows.map((row, index) => `
            <tr>
              <td><strong>${escapeHtml(row.nome || '')}</strong><small>${escapeHtml(row.nome_fantasia || '')}</small></td>
              <td>${escapeHtml(formatCnpj(row.cnpj || ''))}</td>
              <td>${escapeHtml(row.codigo_sap_cliente || '')}</td>
              <td>${escapeHtml([row.cidade, row.estado].filter(Boolean).join('/'))}</td>
              <td>${escapeHtml(row.telefone || '')}<small>${escapeHtml(row.email || '')}</small></td>
              <td><span class="status-pill ${row.ativo ? 'ok' : 'warn'}">${row.ativo ? 'Ativo' : 'Inativo'}</span></td>
              <td>
                <div class="actions-row compact-actions">
                  <button class="btn btn-secondary" type="button" data-open-client="${index}">Historico</button>
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
  document.getElementById('partnerClientNotes').value = row.observacoes || '';
  document.getElementById('partnerClientName').focus();
}

function clearPartnerClientForm() {
  document.getElementById('partnerClientForm').reset();
  document.getElementById('partnerClientId').value = '';
  document.getElementById('partnerClientActive').value = 'true';
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
      ${renderCarrierForm()}
      <div class="actions-row" style="margin: 16px 0;">
        <label>Pesquisar transportadora<input id="partnerCarrierSearch" placeholder="Nome, CNPJ ou cidade"></label>
        <button class="btn btn-secondary" id="partnerCarrierSearchButton" type="button">Pesquisar</button>
      </div>
      ${renderCarriersTable(rows)}
    `;
    document.getElementById('partnerCarrierForm').addEventListener('submit', savePartnerCarrier);
    document.getElementById('partnerCarrierClearButton').addEventListener('click', clearPartnerCarrierForm);
    document.getElementById('partnerCarrierSearchButton').addEventListener('click', () => renderCarriersTab(target));
    bindCarrierEditButtons();
  } catch (error) {
    target.innerHTML = `<div class="empty-state">${escapeHtml(error.message)}</div>`;
  }
}

function renderCarrierForm() {
  return `
    <form id="partnerCarrierForm" class="field-grid">
      <input id="partnerCarrierId" type="hidden">
      <label class="span-5">Transportadora<input id="partnerCarrierName" required></label>
      <label class="span-3">CNPJ<input id="partnerCarrierCnpj"></label>
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
  if (!rows.length) return '<div class="empty-state compact-state">Nenhuma transportadora encontrada.</div>';
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
