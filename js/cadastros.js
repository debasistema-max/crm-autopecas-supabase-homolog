async function renderCadastrosClientes(container) {
  const admin = isAdminSession();
  container.innerHTML = `
    ${admin ? renderPortalCadastrosAdminPanel() : ''}
    <section class="panel admin-panel">
      <div class="panel-header">
        <div>
          <h2>Cadastros de Clientes</h2>
          <p>Solicitacoes recebidas pelo portal publico.</p>
        </div>
      </div>
      <div class="field-grid">
        <label class="span-6">Pesquisar
          <input id="cadastroSearch" placeholder="Protocolo, codigo SAP, CNPJ, razao social ou cidade">
        </label>
        <label class="span-3">Status
          <select id="cadastroStatusFilter">
            <option value="">Todos</option>
            ${cadastroStatusOptions().map((status) => `<option value="${escapeHtml(status)}">${escapeHtml(status)}</option>`).join('')}
          </select>
        </label>
        <div class="span-3 actions-row align-end">
          <button class="btn btn-primary" id="cadastroFilterButton" type="button">Filtrar</button>
        </div>
      </div>
      <p id="cadastroMessage" class="form-message"></p>
    </section>
    <section class="panel admin-panel" id="cadastrosList">
      <div class="empty-state">Carregando cadastros...</div>
    </section>
  `;

  const load = async () => {
    const message = document.getElementById('cadastroMessage');
    const list = document.getElementById('cadastrosList');
    message.textContent = '';
    list.innerHTML = '<div class="empty-state">Carregando cadastros...</div>';
    try {
      const rows = await supabaseListCadastrosClientes({
        termo: document.getElementById('cadastroSearch').value.trim(),
        status: document.getElementById('cadastroStatusFilter').value
      });
      list.innerHTML = renderCadastrosTable(rows);
      bindCadastroRows(load);
    } catch (error) {
      list.innerHTML = `<div class="empty-state">${escapeHtml(error.message)}</div>`;
    }
  };

  document.getElementById('cadastroFilterButton').addEventListener('click', load);
  document.getElementById('cadastroSearch').addEventListener('keydown', (event) => {
    if (event.key === 'Enter') load();
  });
  if (admin) {
    bindPortalCadastrosAdminPanel();
    await loadPortalCadastrosReport();
  }
  await load();
}

async function renderPortalCadastrosControle(container) {
  if (!isAdminSession()) {
    container.innerHTML = '<div class="empty-state">Voce nao tem permissao para acessar este modulo.</div>';
    return;
  }
  container.innerHTML = renderPortalCadastrosAdminPanel();
  bindPortalCadastrosAdminPanel();
  await loadPortalCadastrosReport();
}

function renderPortalCadastrosAdminPanel() {
  const today = new Date();
  const from = new Date(today);
  from.setDate(from.getDate() - 30);
  return `
    <section class="panel admin-panel">
      <div class="panel-header">
        <div>
          <h2>Controle do portal de cadastros</h2>
          <p>Configuracao de envio automatico e relatorio dos cadastros recebidos.</p>
        </div>
      </div>
      <div class="field-grid">
        <label class="span-6">Email principal do envio automatico
          <input id="portalEmailPrincipal" type="email" placeholder="financeiro@empresa.com.br">
        </label>
        <label class="span-3">De
          <input id="portalReportFrom" type="date" value="${formatDateInput(from)}">
        </label>
        <label class="span-3">Ate
          <input id="portalReportTo" type="date" value="${formatDateInput(today)}">
        </label>
        <div class="span-12 actions-row">
          <button class="btn btn-primary" id="savePortalSettingsButton" type="button">Salvar configuracao</button>
          <button class="btn btn-secondary" id="refreshPortalReportButton" type="button">Atualizar relatorio</button>
          <button class="btn btn-ghost" id="exportPortalReportButton" type="button">Baixar CSV</button>
          <p id="portalAdminMessage" class="form-message"></p>
        </div>
      </div>
      <div id="portalReportContent" style="margin-top: 16px;">
        <div class="empty-state compact-state">Carregando relatorio...</div>
      </div>
    </section>
  `;
}

function bindPortalCadastrosAdminPanel() {
  document.getElementById('savePortalSettingsButton').addEventListener('click', savePortalCadastrosSettings);
  document.getElementById('refreshPortalReportButton').addEventListener('click', loadPortalCadastrosReport);
  document.getElementById('exportPortalReportButton').addEventListener('click', exportPortalCadastrosReport);
}

async function savePortalCadastrosSettings() {
  const button = document.getElementById('savePortalSettingsButton');
  const message = document.getElementById('portalAdminMessage');
  button.disabled = true;
  message.style.color = 'var(--muted)';
  message.textContent = 'Salvando configuracao...';
  try {
    const settings = await supabaseSavePortalCadastroSettings({
      email_principal: document.getElementById('portalEmailPrincipal').value
    });
    document.getElementById('portalEmailPrincipal').value = settings.email_principal || '';
    message.style.color = 'var(--success)';
    message.textContent = 'Configuracao salva.';
  } catch (error) {
    message.style.color = 'var(--accent)';
    message.textContent = error.message;
  } finally {
    button.disabled = false;
  }
}

async function loadPortalCadastrosReport() {
  const target = document.getElementById('portalReportContent');
  const message = document.getElementById('portalAdminMessage');
  target.innerHTML = '<div class="empty-state compact-state">Carregando relatorio...</div>';
  try {
    const report = await supabaseGetCadastrosPortalReport(getPortalReportFilters());
    window.portalCadastrosLastReport = report;
    document.getElementById('portalEmailPrincipal').value = report.settings.email_principal || '';
    target.innerHTML = renderPortalCadastrosReport(report);
    bindPortalCadastroPartnerButtons(report.recent || []);
    bindCadastroAttachmentButtons();
    if (message && !message.textContent) message.textContent = '';
  } catch (error) {
    target.innerHTML = `<div class="empty-state compact-state">${escapeHtml(error.message)}</div>`;
  }
}

function renderPortalCadastrosReport(report) {
  return `
    <div class="cards">
      <article class="metric-card">
        <span>Total enviados</span>
        <strong>${Number(report.total || 0)}</strong>
      </article>
      ${report.byStatus.map((item) => `
        <article class="metric-card">
          <span>${escapeHtml(item.status)}</span>
          <strong>${Number(item.count || 0)}</strong>
        </article>
      `).join('')}
    </div>
    <div class="table-wrap" style="margin-top: 16px;">
      ${renderPortalCadastrosReportRows(report.recent || [])}
    </div>
  `;
}

function renderPortalCadastrosReportRows(rows) {
  if (!rows.length) return '<div class="empty-state compact-state">Nenhum cadastro enviado no periodo.</div>';
  return `
    <table>
      <thead>
        <tr>
          <th>Data</th>
          <th>Protocolo</th>
          <th>Empresa</th>
          <th>CNPJ</th>
          <th>Cidade/UF</th>
          <th>Status</th>
          <th>Codigo SAP</th>
          <th>Email</th>
          <th>Vendedor</th>
          <th>Anexos</th>
          <th>Acoes</th>
        </tr>
      </thead>
      <tbody>
        ${rows.map((row, index) => `
          <tr>
            <td>${escapeHtml(formatDateTime(row.created_at))}</td>
            <td><strong>${escapeHtml(row.protocolo || '')}</strong></td>
            <td>${escapeHtml(row.razao_social || row.nome_fantasia || '')}</td>
            <td>${escapeHtml(formatCnpj(row.cnpj || ''))}</td>
            <td>${escapeHtml([row.cidade, row.estado].filter(Boolean).join('/'))}</td>
            <td>${escapeHtml(row.status || '')}</td>
            <td>${escapeHtml(row.codigo_sap_cliente || '')}</td>
            <td>${escapeHtml(row.email_compras || '')}</td>
            <td>${escapeHtml(row.vendedor || '')}</td>
            <td>${renderCadastroAnexos(row.anexos)}</td>
            <td><button class="btn btn-secondary" type="button" data-send-cadastro-partner="${index}">Enviar para Parceiros</button></td>
          </tr>
        `).join('')}
      </tbody>
    </table>
  `;
}

function bindPortalCadastroPartnerButtons(rows) {
  document.querySelectorAll('[data-send-cadastro-partner]').forEach((button) => {
    button.addEventListener('click', async () => {
      const row = rows[Number(button.dataset.sendCadastroPartner)];
      const message = document.getElementById('portalAdminMessage');
      button.disabled = true;
      message.style.color = 'var(--muted)';
      message.textContent = 'Enviando cadastro para Parceiros...';
      try {
        const client = await supabaseSaveBusinessClientFromCadastro(row);
        message.style.color = 'var(--success)';
        message.textContent = `Cliente ${client.nome || ''} salvo em Parceiros.`;
      } catch (error) {
        message.style.color = 'var(--accent)';
        message.textContent = error.message;
      } finally {
        button.disabled = false;
      }
    });
  });
}

function exportPortalCadastrosReport() {
  const report = window.portalCadastrosLastReport;
  if (!report || !Array.isArray(report.recent) || !report.recent.length) {
    const message = document.getElementById('portalAdminMessage');
    message.style.color = 'var(--accent)';
    message.textContent = 'Nao ha dados para exportar.';
    return;
  }
  const rows = report.recent.map((row) => ({
    data: formatDateTime(row.created_at),
    protocolo: row.protocolo || '',
    empresa: row.razao_social || row.nome_fantasia || '',
    cnpj: row.cnpj || '',
    cidade: row.cidade || '',
    estado: row.estado || '',
    status: row.status || '',
    codigo_sap_cliente: row.codigo_sap_cliente || '',
    email_compras: row.email_compras || '',
    vendedor: row.vendedor || '',
    anexos: getCadastroAnexos(row.anexos).map((item) => item.name || item.path || '').join(' | ')
  }));
  downloadCsv(`relatorio-cadastros-${formatDateInput(new Date())}.csv`, rows);
}

function getPortalReportFilters() {
  return {
    from: dateInputToIsoStart(document.getElementById('portalReportFrom').value),
    to: dateInputToIsoEnd(document.getElementById('portalReportTo').value)
  };
}

function renderCadastrosTable(rows) {
  if (!rows.length) return '<div class="empty-state">Nenhum cadastro encontrado.</div>';
  return `
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Protocolo</th>
            <th>Empresa</th>
            <th>CNPJ</th>
            <th>Cidade/UF</th>
            <th>Contato</th>
            <th>Codigo SAP</th>
            <th>Anexos</th>
            <th>Status</th>
            <th>Observacoes internas</th>
            <th>Acoes</th>
          </tr>
        </thead>
        <tbody>
          ${rows.map(renderCadastroRow).join('')}
        </tbody>
      </table>
    </div>
  `;
}

function renderCadastroRow(row) {
  return `
    <tr data-cadastro-id="${escapeHtml(row.id)}">
      <td>
        <strong>${escapeHtml(row.protocolo || '')}</strong>
        <small>${escapeHtml(formatDateTime(row.created_at))}</small>
      </td>
      <td>
        <strong>${escapeHtml(row.razao_social || row.nome_fantasia || '')}</strong>
        <small>${escapeHtml(row.segmento || '')}</small>
      </td>
      <td>${escapeHtml(formatCnpj(row.cnpj || ''))}</td>
      <td>${escapeHtml([row.cidade, row.estado].filter(Boolean).join('/'))}</td>
      <td>
        <strong>${escapeHtml(row.whatsapp || row.telefone || '')}</strong>
        <small>${escapeHtml(row.email_compras || '')}</small>
      </td>
      <td>
        <input data-cadastro-codigo-sap aria-label="Codigo SAP de ${escapeHtml(row.protocolo || row.razao_social || 'cadastro')}" value="${escapeHtml(row.codigo_sap_cliente || '')}" placeholder="Codigo SAP">
      </td>
      <td>${renderCadastroAnexos(row.anexos)}</td>
      <td>
        <select data-cadastro-status aria-label="Status de ${escapeHtml(row.protocolo || row.razao_social || 'cadastro')}">
          ${cadastroStatusOptions().map((status) => `<option value="${escapeHtml(status)}"${status === row.status ? ' selected' : ''}>${escapeHtml(status)}</option>`).join('')}
        </select>
      </td>
      <td><textarea data-cadastro-notes aria-label="Observacoes internas de ${escapeHtml(row.protocolo || row.razao_social || 'cadastro')}">${escapeHtml(row.observacoes_internas || '')}</textarea></td>
      <td><button class="btn btn-secondary" type="button" data-save-cadastro>Salvar</button></td>
    </tr>
  `;
}

function bindCadastroRows(reload) {
  document.querySelectorAll('[data-save-cadastro]').forEach((button) => {
    button.addEventListener('click', async () => {
      const row = button.closest('[data-cadastro-id]');
      const message = document.getElementById('cadastroMessage');
      button.disabled = true;
      message.style.color = 'var(--muted)';
      message.textContent = 'Salvando cadastro...';
      try {
        await supabaseUpdateCadastroCliente({
          id: row.dataset.cadastroId,
          status: row.querySelector('[data-cadastro-status]').value,
          codigo_sap_cliente: row.querySelector('[data-cadastro-codigo-sap]').value,
          observacoes_internas: row.querySelector('[data-cadastro-notes]').value
        });
        message.style.color = 'var(--success)';
        message.textContent = 'Cadastro atualizado.';
        await reload();
      } catch (error) {
        message.style.color = 'var(--accent)';
        message.textContent = error.message;
      } finally {
        button.disabled = false;
      }
    });
  });
  bindCadastroAttachmentButtons();
}

function getCadastroAnexos(anexos) {
  return Array.isArray(anexos) ? anexos : [];
}

function renderCadastroAnexos(anexos) {
  const files = getCadastroAnexos(anexos);
  if (!files.length) return '<small>Nenhum anexo</small>';
  return `
    <div class="attachment-list">
      ${files.map((file) => `
        <button class="link-button" type="button" data-open-cadastro-attachment="${escapeHtml(file.path || '')}">
          ${escapeHtml(file.label || file.name || 'Anexo')}
        </button>
      `).join('')}
    </div>
  `;
}

function bindCadastroAttachmentButtons() {
  document.querySelectorAll('[data-open-cadastro-attachment]').forEach((button) => {
    if (button.dataset.boundAttachment === 'true') return;
    button.dataset.boundAttachment = 'true';
    button.addEventListener('click', async () => {
      const originalText = button.textContent;
      button.disabled = true;
      button.textContent = 'Abrindo...';
      try {
        const url = await supabaseCreateCadastroAttachmentSignedUrl(button.dataset.openCadastroAttachment);
        window.open(url, '_blank', 'noopener');
      } catch (error) {
        const message = document.getElementById('cadastroMessage') || document.getElementById('portalAdminMessage');
        if (message) {
          message.style.color = 'var(--accent)';
          message.textContent = error.message;
        }
      } finally {
        button.disabled = false;
        button.textContent = originalText;
      }
    });
  });
}

function cadastroStatusOptions() {
  return ['Novo', 'Em analise', 'Pendente', 'Aprovado', 'Reprovado', 'Finalizado SAP'];
}

function isAdminSession() {
  const session = typeof currentSession !== 'undefined' && currentSession ? currentSession : getStoredSession();
  return String(session && session.perfil || '').toUpperCase() === 'ADMIN';
}

function formatDateInput(value) {
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) return '';
  const offset = date.getTimezoneOffset() * 60000;
  return new Date(date.getTime() - offset).toISOString().slice(0, 10);
}

function dateInputToIsoStart(value) {
  if (!value) return '';
  return new Date(`${value}T00:00:00`).toISOString();
}

function dateInputToIsoEnd(value) {
  if (!value) return '';
  const date = new Date(`${value}T00:00:00`);
  date.setDate(date.getDate() + 1);
  return date.toISOString();
}

function formatCnpj(value) {
  const digits = String(value || '').replace(/\D/g, '').slice(0, 14);
  return digits
    .replace(/^(\d{2})(\d)/, '$1.$2')
    .replace(/^(\d{2})\.(\d{3})(\d)/, '$1.$2.$3')
    .replace(/\.(\d{3})(\d)/, '.$1/$2')
    .replace(/(\d{4})(\d)/, '$1-$2');
}

function formatDateTime(value) {
  if (!value) return '';
  return new Intl.DateTimeFormat(APP_CONFIG.locale, {
    dateStyle: 'short',
    timeStyle: 'short'
  }).format(new Date(value));
}
