const FISCAL_RULE_STATUS_LABELS = {
  DRAFT: 'Rascunho',
  VALIDATED: 'Validada',
  ACTIVE: 'Ativa validada',
  REVIEW_REQUIRED: 'Revisão necessária',
  EXPIRED: 'Expirada',
  DISABLED: 'Desativada'
};

async function renderFiscalTaxRules(container) {
  container.innerHTML = `
    <section class="panel admin-panel">
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
        <label class="span-2">Uso no cálculo
          <select id="taxRuleFilterActive">
            <option value="">Todos</option>
            <option value="true">Em uso</option>
            <option value="false">Fora de uso</option>
          </select>
        </label>
        <label class="span-2">Ciclo de vida
          <select id="taxRuleFilterLifecycle">
            <option value="">Todos</option>
            ${Object.entries(FISCAL_RULE_STATUS_LABELS).map(([value, label]) => `<option value="${value}">${label}</option>`).join('')}
          </select>
        </label>
        <div class="span-3 actions-row align-end">
          <button class="btn btn-primary" id="taxRuleFilterButton" type="button">Filtrar</button>
          <button class="btn btn-secondary" id="taxRuleNewButton" type="button">Nova regra</button>
        </div>
      </div>
      <p id="taxRuleMessage" class="form-message"></p>
    </section>
    <section class="panel admin-panel" id="taxRuleEditor" hidden></section>
    <section class="panel admin-panel">
      <div class="panel-header">
        <div><h2>Importar regras fiscais</h2><p>Use a Central de Importações para validar, revisar e confirmar o lote de forma transacional.</p></div>
      </div>
      <p class="form-message">A importação direta por linha foi desativada porque podia deixar um lote parcialmente gravado.</p>
      <div class="actions-row">
        <button class="btn btn-secondary" id="taxRuleOpenImportCenter" type="button">Abrir Central de Importações</button>
      </div>
    </section>
    <section class="panel admin-panel" id="taxRuleResults"><div class="empty-state">Carregando regras fiscais...</div></section>
  `;

  document.getElementById('taxRuleFilterButton').addEventListener('click', loadFiscalTaxRules);
  document.getElementById('taxRuleNewButton').addEventListener('click', () => showFiscalTaxRuleEditor());
  document.getElementById('taxRuleOpenImportCenter').addEventListener('click', () => openModule('sap'));
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
    active: document.getElementById('taxRuleFilterActive').value,
    lifecycle_status: document.getElementById('taxRuleFilterLifecycle').value
  };
}

function renderFiscalTaxRuleResults(rows) {
  if (!rows.length) return '<div class="empty-state">Nenhuma regra fiscal cadastrada.</div>';
  return `
    <div class="cards" style="margin-bottom: 16px;">
      <article class="metric-card"><span>Regras</span><strong>${rows.length}</strong></article>
      <article class="metric-card"><span>Validadas ativas</span><strong>${rows.filter((row) => row.lifecycle_status === 'ACTIVE').length}</strong></article>
      <article class="metric-card"><span>Revisão necessária</span><strong>${rows.filter((row) => row.lifecycle_status === 'REVIEW_REQUIRED').length}</strong></article>
      <article class="metric-card"><span>Rascunhos</span><strong>${rows.filter((row) => row.lifecycle_status === 'DRAFT').length}</strong></article>
    </div>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>NCM</th><th>Rota</th><th>ICMS</th><th>IPI</th><th>PIS/COFINS</th><th>ST/MVA</th><th>Vigência</th><th>Governança</th><th>Ações</th>
          </tr>
        </thead>
        <tbody>
          ${rows.map((row, index) => `
            <tr>
              <td><strong>${escapeHtml(formatNcm(row.ncm))}</strong><small>${escapeHtml(row.customer_type || 'GERAL')}</small></td>
              <td><strong>${escapeHtml(row.uf_origem || '')} → ${escapeHtml(row.uf_destino || '')}</strong></td>
              <td>${formatPercent(row.icms_percent)}</td>
              <td>${formatPercent(row.ipi_percent)}</td>
              <td>${formatPercent(row.pis_percent)}<small>COFINS ${formatPercent(row.cofins_percent)}</small></td>
              <td>${row.has_st ? formatPercent(row.icms_st_percent) : 'SEM ST'}<small>MVA ${formatPercent(row.mva_percent)}</small><small>Revenda: ${escapeHtml(formatResaleCalculationProfile(row))}</small></td>
              <td>${escapeHtml(formatDateOnly(row.effective_from))}<small>${escapeHtml(row.effective_to ? 'ate ' + formatDateOnly(row.effective_to) : 'sem fim')}</small></td>
              <td><span class="status-pill ${fiscalRuleStatusTone(row.lifecycle_status)}">${escapeHtml(fiscalRuleStatusLabel(row.lifecycle_status))}</span><small>${row.active ? 'Em uso no cálculo' : 'Fora de uso'}</small><small>${escapeHtml(row.legal_basis || 'Sem fundamento registrado')}</small></td>
              <td>
                <div class="actions-row compact-actions">
                  ${row.active ? `<button class="btn btn-secondary" type="button" data-tax-version="${index}">Nova versão</button>` : `<button class="btn btn-secondary" type="button" data-tax-edit="${index}">Editar</button>`}
                  ${renderFiscalRuleTransitionButton(row, index)}
                  <button class="btn btn-ghost" type="button" data-tax-history="${index}">Histórico</button>
                  ${row.lifecycle_status === 'DISABLED' ? '' : `<button class="btn btn-ghost" type="button" data-tax-disable="${index}">Desativar</button>`}
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
  document.querySelectorAll('[data-tax-version]').forEach((button) => {
    button.addEventListener('click', () => showFiscalTaxRuleVersionCreator(rows[Number(button.dataset.taxVersion)]));
  });
  document.querySelectorAll('[data-tax-transition]').forEach((button) => {
    button.addEventListener('click', () => {
      const row = rows[Number(button.dataset.taxTransition)];
      showFiscalTaxRuleTransitionEditor(row, button.dataset.taxTargetStatus);
    });
  });
  document.querySelectorAll('[data-tax-history]').forEach((button) => {
    button.addEventListener('click', async () => {
      const row = rows[Number(button.dataset.taxHistory)];
      await runFiscalTaxRuleAction(button, () => showFiscalTaxRuleHistory(row));
    });
  });
  document.querySelectorAll('[data-tax-disable]').forEach((button) => {
    button.addEventListener('click', async () => {
      const row = rows[Number(button.dataset.taxDisable)];
      if (!window.confirm('Desativar esta regra? O histórico será preservado.')) return;
      await runFiscalTaxRuleAction(button, async () => {
        await supabaseDeleteFiscalTaxRule(row.id);
        showFiscalTaxRuleMessage('Regra fiscal desativada. O histórico foi preservado.', true);
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
      <div><h2>${row.id ? 'Editar rascunho fiscal' : 'Nova regra fiscal'}</h2><p>Salvar não ativa a regra. Validação e ativação são etapas separadas e auditadas.</p></div>
    </div>
    <form id="taxRuleForm" class="field-grid">
      <input type="hidden" id="taxRuleId" value="${escapeHtml(row.id || '')}">
      <input type="hidden" id="taxRuleSupersedesId" value="${escapeHtml(row.supersedes_rule_id || '')}">
      <label class="span-2">NCM<input id="taxRuleNcm" inputmode="numeric" maxlength="8" required value="${escapeHtml(row.ncm || '')}"></label>
      <label class="span-1">Origem<input id="taxRuleUfOrigem" maxlength="2" required value="${escapeHtml(row.uf_origem || 'PR')}"></label>
      <label class="span-1">Destino<input id="taxRuleUfDestino" maxlength="2" required value="${escapeHtml(row.uf_destino || 'SP')}"></label>
      <label class="span-2">Operacao<input id="taxRuleOperationType" value="${escapeHtml(row.operation_type || 'VENDA')}"></label>
      <label class="span-2">Tipo cliente<input id="taxRuleCustomerType" value="${escapeHtml(row.customer_type || 'GERAL')}"></label>
      <label class="span-1">ICMS %<input id="taxRuleIcms" type="number" min="0" max="100" step="0.0001" required value="${escapeHtml(fiscalPercentInputValue(row.icms_percent))}"></label>
      <label class="span-1">IPI %<input id="taxRuleIpi" type="number" min="0" max="100" step="0.0001" placeholder="Não definido" value="${escapeHtml(fiscalPercentInputValue(row.ipi_percent))}"></label>
      <label class="span-1">PIS %<input id="taxRulePis" type="number" min="0" max="100" step="0.0001" placeholder="Não definido" value="${escapeHtml(fiscalPercentInputValue(row.pis_percent))}"></label>
      <label class="span-1">COFINS %<input id="taxRuleCofins" type="number" min="0" max="100" step="0.0001" placeholder="Não definido" value="${escapeHtml(fiscalPercentInputValue(row.cofins_percent))}"></label>
      <label class="span-1">FCP %<input id="taxRuleFcp" type="number" min="0" max="100" step="0.0001" placeholder="Não definido" value="${escapeHtml(fiscalPercentInputValue(row.fcp_percent))}"></label>
      <label class="span-1">ICMS-ST %<input id="taxRuleIcmsSt" type="number" min="0" max="100" step="0.0001" placeholder="Obrigatório com ST" value="${escapeHtml(fiscalPercentInputValue(row.icms_st_percent))}"></label>
      <label class="span-1">MVA %<input id="taxRuleMva" type="number" min="0" max="1000" step="0.0001" placeholder="Obrigatória com ST" value="${escapeHtml(fiscalPercentInputValue(row.mva_percent))}"></label>
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
      <label class="span-4">Fundamento legal / referência oficial<input id="taxRuleLegalBasis" maxlength="1000" placeholder="Ex.: decreto, portaria, protocolo ou parecer validado" value="${escapeHtml(row.legal_basis || '')}"></label>
      <label class="span-6">Motivo da alteração<textarea id="taxRuleChangeReason" maxlength="1000" required>${escapeHtml(row.change_reason || '')}</textarea></label>
      <label class="span-6">Observação operacional<textarea id="taxRuleNotes" maxlength="500">${escapeHtml(row.notes || '')}</textarea></label>
      <div class="span-12 actions-row">
        <button class="btn btn-primary" type="submit">Salvar rascunho</button>
        <button class="btn btn-secondary" id="taxRuleCancelButton" type="button">Cancelar</button>
      </div>
    </form>
  `;
  document.getElementById('taxRuleForm').addEventListener('submit', saveFiscalTaxRuleFromForm);
  document.getElementById('taxRuleCancelButton').addEventListener('click', closeFiscalTaxRuleEditor);
  editor.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

async function saveFiscalTaxRuleFromForm(event) {
  event.preventDefault();
  await runFiscalTaxRuleAction(event.submitter, async () => {
    await supabaseSaveFiscalTaxRule(readFiscalTaxRuleForm());
    showFiscalTaxRuleMessage('Rascunho fiscal salvo. Valide antes de ativar.', true);
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
    legal_basis: document.getElementById('taxRuleLegalBasis').value,
    change_reason: document.getElementById('taxRuleChangeReason').value,
    supersedes_rule_id: document.getElementById('taxRuleSupersedesId').value,
    notes: document.getElementById('taxRuleNotes').value
  };
}

function renderFiscalRuleTransitionButton(row, index) {
  const status = row.lifecycle_status || 'REVIEW_REQUIRED';
  if (status === 'DRAFT') {
    return `<button class="btn btn-primary" type="button" data-tax-transition="${index}" data-tax-target-status="VALIDATED">Validar</button>`;
  }
  if (status === 'VALIDATED') {
    return `<button class="btn btn-primary" type="button" data-tax-transition="${index}" data-tax-target-status="ACTIVE">Ativar</button>`;
  }
  if (status === 'REVIEW_REQUIRED') {
    return `<button class="btn btn-primary" type="button" data-tax-transition="${index}" data-tax-target-status="ACTIVE">Validar e manter ativa</button>`;
  }
  if (status === 'ACTIVE') {
    return `<button class="btn btn-secondary" type="button" data-tax-transition="${index}" data-tax-target-status="REVIEW_REQUIRED">Solicitar revisão</button>`;
  }
  return '';
}

function fiscalRuleStatusLabel(status) {
  return FISCAL_RULE_STATUS_LABELS[status] || 'Revisão necessária';
}

function fiscalRuleStatusTone(status) {
  if (status === 'ACTIVE') return 'ok';
  if (status === 'DISABLED') return 'error';
  if (status === 'REVIEW_REQUIRED' || status === 'EXPIRED') return 'warn';
  return 'info';
}

function showFiscalTaxRuleVersionCreator(row) {
  const editor = document.getElementById('taxRuleEditor');
  const minimumDate = nextDateInput(row.effective_from);
  const suggestedDate = todayDateInput() > minimumDate ? todayDateInput() : minimumDate;
  editor.hidden = false;
  editor.innerHTML = `
    <div class="panel-header">
      <div><h2>Nova versão fiscal</h2><p>A regra em uso não será alterada. Será criado um rascunho sucessor.</p></div>
    </div>
    <form id="taxRuleVersionForm" class="field-grid">
      <div class="span-4 form-message"><strong>${escapeHtml(formatNcm(row.ncm))}</strong><br>${escapeHtml(row.uf_origem)} → ${escapeHtml(row.uf_destino)} · ${escapeHtml(row.customer_type || 'GERAL')}</div>
      <label class="span-3">Início da nova vigência<input id="taxRuleVersionDate" type="date" min="${escapeHtml(minimumDate)}" required value="${escapeHtml(suggestedDate)}"></label>
      <label class="span-5">Motivo da nova versão<textarea id="taxRuleVersionReason" maxlength="1000" required placeholder="Descreva a alteração que será preparada."></textarea></label>
      <div class="span-12 actions-row">
        <button class="btn btn-primary" type="submit">Criar rascunho</button>
        <button class="btn btn-secondary" id="taxRuleVersionCancel" type="button">Cancelar</button>
      </div>
    </form>`;
  document.getElementById('taxRuleVersionForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    await runFiscalTaxRuleAction(event.submitter, async () => {
      const created = await supabaseCreateFiscalTaxRuleVersion(
        row.id,
        document.getElementById('taxRuleVersionDate').value,
        document.getElementById('taxRuleVersionReason').value.trim()
      );
      showFiscalTaxRuleEditor(created);
      showFiscalTaxRuleMessage('Rascunho sucessor criado. Revise os dados antes de validar.', true);
    });
  });
  document.getElementById('taxRuleVersionCancel').addEventListener('click', closeFiscalTaxRuleEditor);
  editor.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function showFiscalTaxRuleTransitionEditor(row, targetStatus) {
  const editor = document.getElementById('taxRuleEditor');
  const needsLegalBasis = targetStatus === 'VALIDATED' || targetStatus === 'ACTIVE';
  editor.hidden = false;
  editor.innerHTML = `
    <div class="panel-header">
      <div><h2>${escapeHtml(fiscalRuleTransitionTitle(targetStatus))}</h2><p>${escapeHtml(formatNcm(row.ncm))} · ${escapeHtml(row.uf_origem)} → ${escapeHtml(row.uf_destino)}</p></div>
    </div>
    <form id="taxRuleTransitionForm" class="field-grid">
      ${needsLegalBasis ? `<label class="span-6">Fundamento legal / referência oficial<input id="taxRuleTransitionLegalBasis" maxlength="1000" required value="${escapeHtml(row.legal_basis || '')}" placeholder="Documento oficial ou parecer fiscal validado"></label>` : '<input id="taxRuleTransitionLegalBasis" type="hidden" value="">'}
      <label class="span-6">Motivo da transição<textarea id="taxRuleTransitionReason" maxlength="1000" required placeholder="Registre por que o status está sendo alterado."></textarea></label>
      <div class="span-12 actions-row">
        <button class="btn btn-primary" type="submit">Confirmar transição</button>
        <button class="btn btn-secondary" id="taxRuleTransitionCancel" type="button">Cancelar</button>
      </div>
    </form>`;
  document.getElementById('taxRuleTransitionForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    await runFiscalTaxRuleAction(event.submitter, async () => {
      await supabaseTransitionFiscalTaxRule(
        row.id,
        targetStatus,
        document.getElementById('taxRuleTransitionReason').value.trim(),
        document.getElementById('taxRuleTransitionLegalBasis').value.trim()
      );
      closeFiscalTaxRuleEditor();
      showFiscalTaxRuleMessage(`Regra atualizada para ${fiscalRuleStatusLabel(targetStatus)}.`, true);
      await loadFiscalTaxRules();
    });
  });
  document.getElementById('taxRuleTransitionCancel').addEventListener('click', closeFiscalTaxRuleEditor);
  editor.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

async function showFiscalTaxRuleHistory(row) {
  const versions = await supabaseListFiscalTaxRuleVersions(row.id);
  const editor = document.getElementById('taxRuleEditor');
  editor.hidden = false;
  editor.innerHTML = `
    <div class="panel-header">
      <div><h2>Histórico imutável</h2><p>${escapeHtml(formatNcm(row.ncm))} · ${escapeHtml(row.uf_origem)} → ${escapeHtml(row.uf_destino)}</p></div>
      <button class="btn btn-secondary" id="taxRuleHistoryClose" type="button">Fechar</button>
    </div>
    ${versions.length ? `<div class="table-wrap"><table><thead><tr><th>Versão</th><th>Data</th><th>Evento</th><th>Status</th><th>Motivo</th><th>Fundamento</th></tr></thead><tbody>${versions.map((version) => `
      <tr><td>${escapeHtml(version.rule_version)}</td><td>${escapeHtml(formatDateTime(version.changed_at))}</td><td>${escapeHtml(version.change_type)}</td><td><span class="status-pill ${fiscalRuleStatusTone(version.lifecycle_status)}">${escapeHtml(fiscalRuleStatusLabel(version.lifecycle_status))}</span></td><td>${escapeHtml(version.change_reason || '-')}</td><td>${escapeHtml(version.legal_basis || '-')}</td></tr>
    `).join('')}</tbody></table></div>` : '<div class="empty-state">Nenhuma versão registrada.</div>'}`;
  document.getElementById('taxRuleHistoryClose').addEventListener('click', closeFiscalTaxRuleEditor);
  editor.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function fiscalRuleTransitionTitle(status) {
  if (status === 'VALIDATED') return 'Validar regra fiscal';
  if (status === 'ACTIVE') return 'Validar e ativar regra';
  if (status === 'REVIEW_REQUIRED') return 'Solicitar revisão fiscal';
  return `Alterar para ${fiscalRuleStatusLabel(status)}`;
}

function closeFiscalTaxRuleEditor() {
  const editor = document.getElementById('taxRuleEditor');
  editor.hidden = true;
  editor.innerHTML = '';
}

function nextDateInput(value) {
  const date = new Date(`${String(value || todayDateInput()).slice(0, 10)}T12:00:00`);
  date.setDate(date.getDate() + 1);
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${date.getFullYear()}-${month}-${day}`;
}

function formatDateTime(value) {
  if (!value) return '-';
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? String(value) : date.toLocaleString('pt-BR');
}

function formatResaleCalculationProfile(row) {
  if (row.resale_calculation_method !== 'RATE_DIFFERENCE') return 'lista MVA/ST';
  const rate = row.resale_icms_st_rate == null ? 'diferença de alíquotas' : formatPercent(Number(row.resale_icms_st_rate) * 100);
  return `portal atual (${rate}${row.resale_include_own_icms ? ', soma ICMS próprio' : ', sem somar ICMS próprio'})`;
}

async function runFiscalTaxRuleAction(button, callback) {
  if (button) button.disabled = true;
  try {
    await callback();
  } catch (error) {
    showFiscalTaxRuleMessage(formatFiscalTaxRuleError(error), false);
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
  if (value == null || value === '') return 'Não definido';
  return Number(value).toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 4 }) + '%';
}

function fiscalPercentInputValue(value) {
  return value == null ? '' : value;
}

function formatFiscalTaxRuleError(error) {
  const message = String(error?.message || 'Erro ao processar regra fiscal.');
  const known = {
    REGRA_FISCAL_CONFLITANTE: 'Já existe uma regra fiscal ativa com estes parâmetros e período de vigência.',
    ICMS_OBRIGATORIO: 'Informe a alíquota de ICMS.',
    ICMS_INTERNO_OBRIGATORIO_PARA_ST: 'Informe o ICMS interno para uma regra com ST.',
    MVA_OBRIGATORIA_PARA_ST: 'Informe a MVA para uma regra com ST.',
    UF_INVALIDA: 'Informe uma UF brasileira válida.',
    NCM_INVALIDO: 'Informe um NCM válido com oito dígitos.',
    CEST_INVALIDO: 'Informe um CEST válido com sete dígitos.',
    ALIQUOTA_FORA_DA_FAIXA: 'Revise as alíquotas: há um percentual fora da faixa aceita.',
    REGRA_FISCAL_ATIVA_IMUTAVEL: 'Uma regra em uso não pode ser editada. Crie uma nova versão.',
    FUNDAMENTO_LEGAL_OBRIGATORIO: 'Informe o fundamento legal ou a referência oficial usada na validação.',
    MOTIVO_OBRIGATORIO: 'Informe o motivo da alteração.',
    NOVA_VIGENCIA_DEVE_SER_POSTERIOR: 'A nova versão deve começar depois da vigência da regra atual.',
    VERSAO_FISCAL_JA_EXISTE_NA_DATA: 'Já existe uma versão desta regra com a data informada.',
    VALIDACAO_FISCAL_INCOMPLETA: 'A validação precisa de responsável, data e fundamento legal.',
    REGRA_DEVE_SER_VALIDADA_ANTES_DE_ATIVAR: 'Valide a regra antes de ativá-la.',
    TRANSICAO_FISCAL_INVALIDA: 'Esta alteração de status não é permitida no estado atual.'
  };
  const code = Object.keys(known).find((key) => message.includes(key));
  return code ? known[code] : message;
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
