async function renderFiscalTaxRules(container) {
  container.innerHTML = `
    <section class="panel">
      <div class="panel-header">
        <div>
          <h2>Impostos</h2>
          <p>Regras fiscais por NCM, origem, destino e vigencia.</p>
        </div>
      </div>
      <div class="field-grid">
        <label class="span-3">NCM
          <input id="taxRuleFilterNcm" inputmode="numeric" maxlength="8" placeholder="Ex.: 87089990">
        </label>
        <label class="span-2">UF destino
          <input id="taxRuleFilterUf" maxlength="2" placeholder="SP">
        </label>
        <label class="span-2">Status
          <select id="taxRuleFilterActive">
            <option value="">Todos</option>
            <option value="true">Ativos</option>
            <option value="false">Inativos</option>
          </select>
        </label>
        <div class="span-5 actions-row align-end">
          <button class="btn btn-primary" id="taxRuleFilterButton" type="button">Filtrar</button>
          <button class="btn btn-secondary" id="taxRuleNewButton" type="button">Nova regra</button>
        </div>
      </div>
      <p id="taxRuleMessage" class="form-message"></p>
    </section>
    <section class="panel" id="taxRuleEditor" hidden></section>
    <section class="panel">
      <div class="panel-header">
        <div><h2>Importar relacao</h2><p>Cole CSV/TSV com cabecalho para cadastrar varias regras.</p></div>
      </div>
      <textarea id="taxRuleImportText" placeholder="ncm;uf_origem;uf_destino;icms;ipi;pis;cofins;fcp;mva_st;icms_st;tipo_cliente;vigencia_inicio"></textarea>
      <div class="actions-row" style="margin-top: 10px;">
        <button class="btn btn-secondary" id="taxRuleImportButton" type="button">Importar texto</button>
      </div>
    </section>
    <section class="panel" id="taxRuleResults"><div class="empty-state">Carregando regras fiscais...</div></section>
  `;

  document.getElementById('taxRuleFilterButton').addEventListener('click', loadFiscalTaxRules);
  document.getElementById('taxRuleNewButton').addEventListener('click', () => showFiscalTaxRuleEditor());
  document.getElementById('taxRuleImportButton').addEventListener('click', importFiscalTaxRulesFromText);
  await loadFiscalTaxRules();
}

async function loadFiscalTaxRules() {
  const target = document.getElementById('taxRuleResults');
  target.innerHTML = '<div class="empty-state">Carregando regras fiscais...</div>';
  try {
    const rows = await supabaseListFiscalTaxRules(getFiscalTaxRuleFilters());
    target.innerHTML = renderFiscalTaxRuleResults(rows);
    bindFiscalTaxRuleActions(rows);
  } catch (error) {
    target.innerHTML = `<div class="empty-state">${escapeHtml(error.message)}</div>`;
  }
}

function getFiscalTaxRuleFilters() {
  return {
    ncm: document.getElementById('taxRuleFilterNcm').value.trim(),
    uf_destino: document.getElementById('taxRuleFilterUf').value.trim().toUpperCase(),
    active: document.getElementById('taxRuleFilterActive').value
  };
}

function renderFiscalTaxRuleResults(rows) {
  if (!rows.length) return '<div class="empty-state">Nenhuma regra fiscal cadastrada.</div>';
  return `
    <div class="cards" style="margin-bottom: 16px;">
      <article class="metric-card"><span>Regras</span><strong>${rows.length}</strong></article>
      <article class="metric-card"><span>Ativas</span><strong>${rows.filter((row) => row.active).length}</strong></article>
      <article class="metric-card"><span>NCMs</span><strong>${new Set(rows.map((row) => row.ncm)).size}</strong></article>
      <article class="metric-card"><span>UF destino</span><strong>${new Set(rows.map((row) => row.uf_destino)).size}</strong></article>
    </div>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>NCM</th><th>Origem</th><th>Destino</th><th>ICMS</th><th>IPI</th><th>PIS</th><th>COFINS</th><th>ST/MVA</th><th>Vigencia</th><th>Status</th><th></th>
          </tr>
        </thead>
        <tbody>
          ${rows.map((row, index) => `
            <tr>
              <td><strong>${escapeHtml(formatNcm(row.ncm))}</strong><small>${escapeHtml(row.customer_type || 'GERAL')}</small></td>
              <td>${escapeHtml(row.uf_origem || '')}</td>
              <td>${escapeHtml(row.uf_destino || '')}</td>
              <td>${formatPercent(row.icms_percent)}</td>
              <td>${formatPercent(row.ipi_percent)}</td>
              <td>${formatPercent(row.pis_percent)}</td>
              <td>${formatPercent(row.cofins_percent)}</td>
              <td>${row.has_st ? formatPercent(row.icms_st_percent) : 'SEM ST'}<small>MVA ${formatPercent(row.mva_percent)}</small><small>Revenda: ${escapeHtml(formatResaleCalculationProfile(row))}</small></td>
              <td>${escapeHtml(formatDateOnly(row.effective_from))}<small>${escapeHtml(row.effective_to ? 'ate ' + formatDateOnly(row.effective_to) : 'sem fim')}</small></td>
              <td><span class="status-pill ${row.active ? 'ok' : 'warn'}">${row.active ? 'Ativa' : 'Inativa'}</span></td>
              <td>
                <div class="actions-row compact-actions">
                  <button class="btn btn-secondary" type="button" data-tax-edit="${index}">Editar</button>
                  <button class="btn btn-ghost" type="button" data-tax-delete="${index}">Excluir</button>
                </div>
              </td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  `;
}

function bindFiscalTaxRuleActions(rows) {
  document.querySelectorAll('[data-tax-edit]').forEach((button) => {
    button.addEventListener('click', () => showFiscalTaxRuleEditor(rows[Number(button.dataset.taxEdit)]));
  });
  document.querySelectorAll('[data-tax-delete]').forEach((button) => {
    button.addEventListener('click', async () => {
      const row = rows[Number(button.dataset.taxDelete)];
      if (!window.confirm('Excluir esta regra fiscal?')) return;
      await runFiscalTaxRuleAction(button, async () => {
        await supabaseDeleteFiscalTaxRule(row.id);
        showFiscalTaxRuleMessage('Regra fiscal excluida.', true);
        await loadFiscalTaxRules();
      });
    });
  });
}

function showFiscalTaxRuleEditor(row = {}) {
  const editor = document.getElementById('taxRuleEditor');
  editor.hidden = false;
  editor.innerHTML = `
    <div class="panel-header">
      <div><h2>${row.id ? 'Editar regra fiscal' : 'Nova regra fiscal'}</h2><p>Cadastro administrativo para calculo fiscal futuro.</p></div>
    </div>
    <form id="taxRuleForm" class="field-grid">
      <input type="hidden" id="taxRuleId" value="${escapeHtml(row.id || '')}">
      <label class="span-2">NCM<input id="taxRuleNcm" inputmode="numeric" maxlength="8" required value="${escapeHtml(row.ncm || '')}"></label>
      <label class="span-1">Origem<input id="taxRuleUfOrigem" maxlength="2" required value="${escapeHtml(row.uf_origem || 'PR')}"></label>
      <label class="span-1">Destino<input id="taxRuleUfDestino" maxlength="2" required value="${escapeHtml(row.uf_destino || 'SP')}"></label>
      <label class="span-2">Operacao<input id="taxRuleOperationType" value="${escapeHtml(row.operation_type || 'VENDA')}"></label>
      <label class="span-2">Tipo cliente<input id="taxRuleCustomerType" value="${escapeHtml(row.customer_type || 'GERAL')}"></label>
      <label class="span-1">ICMS %<input id="taxRuleIcms" type="number" min="0" step="0.0001" value="${escapeHtml(row.icms_percent || 0)}"></label>
      <label class="span-1">IPI %<input id="taxRuleIpi" type="number" min="0" step="0.0001" value="${escapeHtml(row.ipi_percent || 0)}"></label>
      <label class="span-1">PIS %<input id="taxRulePis" type="number" min="0" step="0.0001" value="${escapeHtml(row.pis_percent || 0)}"></label>
      <label class="span-1">COFINS %<input id="taxRuleCofins" type="number" min="0" step="0.0001" value="${escapeHtml(row.cofins_percent || 0)}"></label>
      <label class="span-1">FCP %<input id="taxRuleFcp" type="number" min="0" step="0.0001" value="${escapeHtml(row.fcp_percent || 0)}"></label>
      <label class="span-1">ICMS-ST %<input id="taxRuleIcmsSt" type="number" min="0" step="0.0001" value="${escapeHtml(row.icms_st_percent || 0)}"></label>
      <label class="span-1">MVA %<input id="taxRuleMva" type="number" min="0" step="0.0001" value="${escapeHtml(row.mva_percent || 0)}"></label>
      <label class="span-1">ST<select id="taxRuleHasSt"><option value="true"${row.has_st !== false ? ' selected' : ''}>Com ST</option><option value="false"${row.has_st === false ? ' selected' : ''}>Sem ST</option></select></label>
      <label class="span-3">Cálculo para Revenda
        <select id="taxRuleResaleMethod">
          <option value="MVA_ST"${row.resale_calculation_method !== 'RATE_DIFFERENCE' ? ' selected' : ''}>Lista fiscal (MVA/ST)</option>
          <option value="RATE_DIFFERENCE"${row.resale_calculation_method === 'RATE_DIFFERENCE' ? ' selected' : ''}>Compatível com portal atual</option>
        </select>
      </label>
      <label class="span-2">ICMS-ST efetivo Revenda %<input id="taxRuleResaleIcmsSt" type="number" min="0" max="100" step="0.000001" placeholder="Automático" value="${row.resale_icms_st_rate == null ? '' : escapeHtml(Number(row.resale_icms_st_rate) * 100)}"></label>
      <label class="span-2">Somar ICMS próprio na Revenda<select id="taxRuleResaleOwnIcms"><option value="false"${row.resale_include_own_icms !== true ? ' selected' : ''}>Não</option><option value="true"${row.resale_include_own_icms === true ? ' selected' : ''}>Sim</option></select></label>
      <label class="span-2">CEST<input id="taxRuleCest" maxlength="10" value="${escapeHtml(row.cest || '')}"></label>
      <label class="span-1">CFOP<input id="taxRuleCfop" maxlength="6" value="${escapeHtml(row.cfop || '')}"></label>
      <label class="span-1">CST/CSOSN<input id="taxRuleCst" maxlength="8" value="${escapeHtml(row.cst_code || '')}"></label>
      <label class="span-2">Inicio<input id="taxRuleEffectiveFrom" type="date" required value="${escapeHtml(row.effective_from || todayDateInput())}"></label>
      <label class="span-2">Fim<input id="taxRuleEffectiveTo" type="date" value="${escapeHtml(row.effective_to || '')}"></label>
      <label class="span-2">Status
        <select id="taxRuleActive">
          <option value="true"${row.active !== false ? ' selected' : ''}>Ativa</option>
          <option value="false"${row.active === false ? ' selected' : ''}>Inativa</option>
        </select>
      </label>
      <label class="span-12">Observacao<textarea id="taxRuleNotes" maxlength="500">${escapeHtml(row.notes || '')}</textarea></label>
      <div class="span-12 actions-row">
        <button class="btn btn-primary" type="submit">Salvar regra</button>
        <button class="btn btn-secondary" id="taxRuleCancelButton" type="button">Cancelar</button>
      </div>
    </form>
  `;
  document.getElementById('taxRuleForm').addEventListener('submit', saveFiscalTaxRuleFromForm);
  document.getElementById('taxRuleCancelButton').addEventListener('click', () => {
    editor.hidden = true;
    editor.innerHTML = '';
  });
  editor.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

async function saveFiscalTaxRuleFromForm(event) {
  event.preventDefault();
  await runFiscalTaxRuleAction(event.submitter, async () => {
    await supabaseSaveFiscalTaxRule(readFiscalTaxRuleForm());
    showFiscalTaxRuleMessage('Regra fiscal salva.', true);
    document.getElementById('taxRuleEditor').hidden = true;
    await loadFiscalTaxRules();
  });
}

function readFiscalTaxRuleForm() {
  return {
    id: document.getElementById('taxRuleId').value,
    ncm: document.getElementById('taxRuleNcm').value,
    uf_origem: document.getElementById('taxRuleUfOrigem').value,
    uf_destino: document.getElementById('taxRuleUfDestino').value,
    operation_type: document.getElementById('taxRuleOperationType').value,
    customer_type: document.getElementById('taxRuleCustomerType').value,
    icms_percent: document.getElementById('taxRuleIcms').value,
    ipi_percent: document.getElementById('taxRuleIpi').value,
    pis_percent: document.getElementById('taxRulePis').value,
    cofins_percent: document.getElementById('taxRuleCofins').value,
    fcp_percent: document.getElementById('taxRuleFcp').value,
    icms_st_percent: document.getElementById('taxRuleIcmsSt').value,
    mva_percent: document.getElementById('taxRuleMva').value,
    has_st: document.getElementById('taxRuleHasSt').value === 'true',
    resale_calculation_method: document.getElementById('taxRuleResaleMethod').value,
    resale_icms_st_percent: document.getElementById('taxRuleResaleIcmsSt').value,
    resale_include_own_icms: document.getElementById('taxRuleResaleOwnIcms').value === 'true',
    cest: document.getElementById('taxRuleCest').value,
    cfop: document.getElementById('taxRuleCfop').value,
    cst_code: document.getElementById('taxRuleCst').value,
    effective_from: document.getElementById('taxRuleEffectiveFrom').value,
    effective_to: document.getElementById('taxRuleEffectiveTo').value,
    active: document.getElementById('taxRuleActive').value === 'true',
    notes: document.getElementById('taxRuleNotes').value
  };
}

function formatResaleCalculationProfile(row) {
  if (row.resale_calculation_method !== 'RATE_DIFFERENCE') return 'lista MVA/ST';
  const rate = row.resale_icms_st_rate == null ? 'diferença de alíquotas' : formatPercent(Number(row.resale_icms_st_rate) * 100);
  return `portal atual (${rate}${row.resale_include_own_icms ? ', soma ICMS próprio' : ', sem somar ICMS próprio'})`;
}

async function importFiscalTaxRulesFromText(event) {
  const text = document.getElementById('taxRuleImportText').value.trim();
  if (!text) {
    showFiscalTaxRuleMessage('Cole a relacao de impostos antes de importar.', false);
    return;
  }
  const rows = parseFiscalTaxRuleImport(text);
  if (!rows.length) {
    showFiscalTaxRuleMessage('Nenhuma linha valida encontrada.', false);
    return;
  }
  await runFiscalTaxRuleAction(event.target, async () => {
    for (const row of rows) await supabaseSaveFiscalTaxRule(row);
    showFiscalTaxRuleMessage(`${rows.length} regra${rows.length === 1 ? '' : 's'} importada${rows.length === 1 ? '' : 's'}.`, true);
    document.getElementById('taxRuleImportText').value = '';
    await loadFiscalTaxRules();
  });
}

function parseFiscalTaxRuleImport(text) {
  const lines = text.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  if (lines.length < 2) return [];
  const delimiter = lines[0].includes('\t') ? '\t' : ';';
  const headers = lines[0].split(delimiter).map(normalizeFiscalHeader);
  return lines.slice(1).map((line) => {
    const values = line.split(delimiter);
    const record = {};
    headers.forEach((header, index) => {
      if (header) record[header] = values[index] == null ? '' : values[index].trim();
    });
    return normalizeFiscalImportRecord(record);
  }).filter((row) => row.ncm && row.uf_origem && row.uf_destino);
}

function normalizeFiscalImportRecord(row) {
  return {
    ncm: row.ncm,
    uf_origem: row.uf_origem || row.origem,
    uf_destino: row.uf_destino || row.uf || row.destino,
    operation_type: row.operation_type || row.operacao || 'VENDA',
    customer_type: row.customer_type || row.tipo_cliente || 'GERAL',
    icms_percent: row.icms_percent || row.icms || 0,
    ipi_percent: row.ipi_percent || row.ipi || 0,
    pis_percent: row.pis_percent || row.pis || 0,
    cofins_percent: row.cofins_percent || row.cofins || 0,
    fcp_percent: row.fcp_percent || row.fcp || 0,
    icms_st_percent: row.icms_st_percent || row.icms_st || row.st || 0,
    mva_percent: row.mva_percent || row.mva_st || row.mva || 0,
    effective_from: row.effective_from || row.vigencia_inicio || todayDateInput(),
    effective_to: row.effective_to || row.vigencia_fim || '',
    active: String(row.active || row.ativo || 'true').toLowerCase() !== 'false',
    notes: row.notes || row.observacao || ''
  };
}

function normalizeFiscalHeader(value) {
  return String(value || '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_|_$/g, '');
}

async function runFiscalTaxRuleAction(button, callback) {
  if (button) button.disabled = true;
  try {
    await callback();
  } catch (error) {
    showFiscalTaxRuleMessage(error.message || 'Erro ao processar regra fiscal.', false);
  } finally {
    if (button) button.disabled = false;
  }
}

function showFiscalTaxRuleMessage(message, success) {
  const target = document.getElementById('taxRuleMessage');
  if (!target) return;
  target.style.color = success ? 'var(--success)' : 'var(--accent)';
  target.textContent = message;
}

function formatNcm(value) {
  const digits = String(value || '').replace(/\D/g, '');
  return digits.length === 8 ? `${digits.slice(0, 4)}.${digits.slice(4, 6)}.${digits.slice(6)}` : digits;
}

function formatPercent(value) {
  return Number(value || 0).toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 4 }) + '%';
}

function formatDateOnly(value) {
  if (!value) return '-';
  return String(value).slice(0, 10).split('-').reverse().join('/');
}

function todayDateInput() {
  const today = new Date();
  const month = String(today.getMonth() + 1).padStart(2, '0');
  const day = String(today.getDate()).padStart(2, '0');
  return `${today.getFullYear()}-${month}-${day}`;
}
