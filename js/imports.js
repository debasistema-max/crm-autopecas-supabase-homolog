const SAP_IMPORT_TYPES = {
  COMMERCIAL_PRODUCTS: 'Cadastro Comercial / Produtos',
  SAP_ITEM_MASTER: 'Cadastro Item SAP',
  STOCK_PR: 'Estoque PR',
  STOCK_SP: 'Estoque SP',
  BASE_PRICE_PR: 'Preço Base PR',
  BASE_PRICE_SP: 'Preço Base SP',
  FISCAL_RULES_PR: 'Dados Fiscais SAP — Origem PR',
  FISCAL_RULES_SP: 'Dados Fiscais SAP — Origem SP'
};

const SAP_IMPORT_FIELDS = {
  product_code: 'Código do produto', description: 'Descrição', brand: 'Marca', application: 'Aplicação', year: 'Ano',
  ncm: 'NCM', cest: 'CEST', ipi_rate: 'IPI', origin_code: 'Código de origem', origin_description: 'Origem',
  material_group: 'Grupo de materiais', fiscal_group: 'Grupo fiscal', group: 'Grupo', model: 'Modelo', in_stock: 'Em estoque',
  ordered_qty: 'Qtd. pedido', oem_01: 'OEM 01', delivery: 'Entrega', last_purchase_date: 'Última compra', compatible: 'Compatível',
  import_notes: 'Observação importação', item_group: 'Grupo de itens', sales_unit: 'UM venda', item_notes: 'Observação do item',
  weight: 'Peso', volume: 'Volume', manufacturer_code_01: 'Código fabricante 01', manufacturer_code_02: 'Código fabricante 02',
  manufacturer: 'Fabricante', barcode: 'Código de barras', product_source: 'Fonte/origem', material_type: 'Tipo de material',
  origin_and_fiscal_group: 'Origem e grupo fiscal', materials_group: 'Grupo de materiais SAP', origin_and_ncm: 'Origem e NCM',
  stock_qty: 'Estoque', confirmed_qty: 'Confirmado', sales_available_qty: 'Disponível venda',
  authorized_pending_qty: 'Qtd. autorizada pendente', general_available_qty: 'Disponível geral', base_price: 'Preço base',
  source_code: 'Code SAP', destination_state: 'UF destino', interstate_icms_rate: 'ICMS interestadual',
  internal_icms_rate: 'ICMS interno destino', mva_rate: 'MVA', has_st: 'Possui ST', effective_from: 'Vigência inicial',
  effective_to: 'Vigência final', cfop: 'CFOP', cst_code: 'CSOSN/CST', pis_rate: 'PIS', cofins_rate: 'COFINS', fcp_rate: 'FCP',
  base_reduction_rate: 'Redução de base', freight_rate: 'Frete', insurance_rate: 'Seguro', other_expenses_rate: 'Outras despesas', notes: 'Notas'
};

const SAP_IMPORT_REQUIRED = {
  COMMERCIAL_PRODUCTS: ['product_code', 'description'], SAP_ITEM_MASTER: ['product_code', 'description'],
  STOCK_PR: ['product_code', 'general_available_qty'], STOCK_SP: ['product_code', 'general_available_qty'],
  BASE_PRICE_PR: ['product_code', 'base_price'], BASE_PRICE_SP: ['product_code', 'base_price'],
  FISCAL_RULES_PR: ['ncm', 'destination_state', 'interstate_icms_rate', 'internal_icms_rate', 'mva_rate', 'ipi_rate', 'has_st'],
  FISCAL_RULES_SP: ['ncm', 'destination_state', 'interstate_icms_rate', 'internal_icms_rate', 'mva_rate', 'ipi_rate', 'has_st']
};

const SAP_HEADER_ALIASES = {
  product_code: ['codigo', 'codigo ips', 'cod ips', 'n do item', 'nº do item', 'numero do item', 'item', 'product code'],
  description: ['descricao', 'descricao do item', 'descricao item', 'descricao base'], brand: ['marca'], application: ['aplicacao'], year: ['ano'],
  ncm: ['ncm', 'codigo ncm'], cest: ['cest', 'codigo cest'], ipi_rate: ['ipi', '% ipi', 'aliquota ipi'], model: ['modelo'],
  in_stock: ['em estoque'], ordered_qty: ['qtd pedido', 'qtd. pedido', 'quantidade pedido'], oem_01: ['oem 01', 'oem'], delivery: ['entrega'],
  last_purchase_date: ['ultima data de compra', 'data ultima compra', 'ult dt compra'], compatible: ['compativel'],
  import_notes: ['observacao importacao', 'obs importacion', 'obs importacao'],
  item_group: ['grupo de itens'], sales_unit: ['um venda'], item_notes: ['observacao do item', 'obs item'], weight: ['peso'], volume: ['volume'],
  manufacturer_code_01: ['codigo fabricante 01', 'cod fabricante 01'], manufacturer_code_02: ['codigo fabricante 02', 'cod fabricante 02'], manufacturer: ['fabricante'],
  barcode: ['codigo de barras', 'ean'], product_source: ['fonte origem do produto', 'fonte origem', 'origem produto', 'fonte do produto'], material_type: ['tipo de material'],
  origin_and_fiscal_group: ['origem e grupo fiscal'], materials_group: ['grupo de materiais'], origin_and_ncm: ['origem e ncm'],
  origin_code: ['codigo origem', 'origem codigo'], origin_description: ['descricao origem'], fiscal_group: ['grupo fiscal'], group: ['grupo'],
  stock_qty: ['estoque'], confirmed_qty: ['confirmado'], sales_available_qty: ['disp venda', 'disponivel venda'],
  authorized_pending_qty: ['quantidade autorizada pendente', 'qtd autorizada pendente', 'qtd auth pend'], general_available_qty: ['disp geral', 'disponivel geral'],
  base_price: ['preco base', 'preco s imp', 'preco sem imposto', 'valor'], source_code: ['code'], destination_state: ['estado', 'uf destino', 'destino'],
  interstate_icms_rate: ['% icms', 'icms'], internal_icms_rate: ['% icms dest', 'icms dest', 'icms destino'], mva_rate: ['% mva', 'mva'],
  has_st: ['has st', 'possui st', 'st'], effective_from: ['vigencia', 'valid from', 'data inicial'], effective_to: ['valid until', 'data final'],
  cfop: ['cfop'], cst_code: ['cst', 'csosn'], pis_rate: ['pis', '% pis'], cofins_rate: ['cofins', '% cofins'], fcp_rate: ['fcp', '% fcp'],
  base_reduction_rate: ['reducao base', 'reducao de base'], freight_rate: ['frete'], insurance_rate: ['seguro'],
  other_expenses_rate: ['outras despesas'], notes: ['notas', 'observacoes']
};

const sapImportState = { workbook: null, sheet: null, headers: [], sourceRows: [], mapping: {}, bytes: null, filename: '', batchId: null, preview: null, listRows: [], ignoredRows: 0 };

async function renderImportCenter(container) {
  container.innerHTML = `
    <div class="module-page import-workspace">
      ${CrmUi.renderPageHeader(
        'Central de Importacoes',
        'Receba arquivos SAP com staging, validacao, preview, auditoria e commit transacional.',
        '',
        'Operacao'
      )}
      <section class="panel import-center">
        <div class="section-heading"><div><h3>Area de trabalho</h3><p>Escolha a operacao sem perder a rastreabilidade dos lotes.</p></div></div>
        <div class="import-center-tabs" role="tablist" aria-label="Areas da Central de Importacoes">
          <button class="btn btn-primary" type="button" role="tab" aria-selected="true" data-import-tab="new">Nova importação</button>
          <button class="btn btn-ghost" type="button" role="tab" aria-selected="false" data-import-tab="history">Histórico</button>
          <button class="btn btn-ghost" type="button" role="tab" aria-selected="false" data-import-tab="pending">Pendências fiscais</button>
          <button class="btn btn-ghost" type="button" role="tab" aria-selected="false" data-import-tab="lists">Listas comerciais</button>
        </div>
      </section>
      <div id="importCenterContent" class="import-center-content" role="tabpanel" aria-live="polite"></div>
    </div>`;
  container.querySelectorAll('[data-import-tab]').forEach((button) => button.addEventListener('click', () => openImportCenterTab(button.dataset.importTab)));
  await openImportCenterTab('new');
}

async function openImportCenterTab(tab) {
  document.querySelectorAll('[data-import-tab]').forEach((button) => {
    const active = button.dataset.importTab === tab;
    button.classList.toggle('btn-primary', active);
    button.classList.toggle('btn-ghost', !active);
    button.setAttribute('aria-selected', String(active));
  });
  if (tab === 'history') return renderSapImportHistory();
  if (tab === 'pending') return renderFiscalPendingPanel();
  if (tab === 'lists') return renderCommercialListsPanel();
  return renderNewSapImport();
}

function renderNewSapImport() {
  const target = document.getElementById('importCenterContent');
  target.innerHTML = `
    <section class="panel import-input-panel">
      <div class="section-heading"><div><h3>Nova importacao</h3><p>Selecione o tipo, a filial e a fonte. Nenhum dado e efetivado antes da confirmacao.</p></div></div>
      <ol class="import-flow-steps" aria-label="Etapas da importacao">
        <li data-import-step="upload"><span>1</span><strong>Upload</strong></li>
        <li data-import-step="detection"><span>2</span><strong>Deteccao</strong></li>
        <li data-import-step="validation"><span>3</span><strong>Validacao</strong></li>
        <li data-import-step="preview"><span>4</span><strong>Preview</strong></li>
        <li data-import-step="commit"><span>5</span><strong>Confirmacao</strong></li>
      </ol>
      <div class="field-grid import-source-grid">
        <label class="span-4">Tipo
          <select id="sapImportKind">${Object.entries(SAP_IMPORT_TYPES).map(([value, label]) => `<option value="${value}">${escapeHtml(label)}</option>`).join('')}</select>
        </label>
        <label class="span-4">Filial <select id="sapImportBranch"><option>PR</option><option>SP</option></select></label>
        <label class="span-4">ST para linhas sem coluna própria
          <select id="sapImportHasSt"><option value="">Selecione explicitamente</option><option value="true">Com ST</option><option value="false">Sem ST</option></select>
        </label>
        <label class="span-8">Arquivo XLSX / CSV / TSV
          <input id="sapImportFile" type="file" accept=".xlsx,.xls,.csv,.tsv,.txt">
        </label>
        <label class="span-4" id="sapSheetLabel" hidden>Aba <select id="sapImportSheet"></select></label>
        <label class="span-12">Ou cole os dados
          <textarea id="sapImportText" placeholder="Cole aqui a tabela extraída do SAP"></textarea>
        </label>
      </div>
      <div class="actions-row import-primary-actions">
        <button class="btn btn-primary" id="sapAnalyzeButton" type="button">Analisar arquivo</button>
        <button class="btn btn-secondary" id="sapValidateButton" type="button" disabled>Validar no staging</button>
        <button class="btn btn-primary" id="sapCommitButton" type="button" disabled>Confirmar importação</button>
        <p class="form-message" id="sapImportMessage" aria-live="polite"></p>
      </div>
    </section>
    <section class="panel import-stage-panel" id="sapDetection">${CrmUi.renderState('empty', 'Fonte aguardando analise', 'Selecione um arquivo ou cole uma tabela extraida do SAP.')}</section>
    <section class="panel import-stage-panel" id="sapMapping" hidden></section>
    <section class="panel import-stage-panel" id="sapServerPreview" hidden></section>`;
  document.getElementById('sapImportFile').addEventListener('change', (event) => loadSapImportFile(event).catch((error) => {
    console.error(error); document.getElementById('sapImportMessage').textContent = error.message || 'Falha ao ler o arquivo.';
  }));
  document.getElementById('sapImportSheet').addEventListener('change', () => selectSapWorkbookSheet(document.getElementById('sapImportSheet').value));
  document.getElementById('sapAnalyzeButton').addEventListener('click', analyzeSapImportInput);
  document.getElementById('sapValidateButton').addEventListener('click', stageAndValidateSapImport);
  document.getElementById('sapCommitButton').addEventListener('click', approveAndCommitSapImport);
  document.getElementById('sapImportKind').addEventListener('change', () => renderSapColumnMapping());
  setSapImportStage('upload');
}

function setSapImportStage(stage) {
  const stages = ['upload', 'detection', 'validation', 'preview', 'commit'];
  const activeIndex = stage === 'complete' ? stages.length : stages.indexOf(stage);
  document.querySelectorAll('[data-import-step]').forEach((item) => {
    const index = stages.indexOf(item.dataset.importStep);
    item.classList.toggle('is-active', index === activeIndex);
    item.classList.toggle('is-complete', index < activeIndex || stage === 'complete');
    if (index === activeIndex) item.setAttribute('aria-current', 'step');
    else item.removeAttribute('aria-current');
  });
}

async function loadSapImportFile(event) {
  const file = event.target.files && event.target.files[0];
  if (!file) return;
  sapImportState.filename = file.name;
  sapImportState.bytes = await file.arrayBuffer();
  if (/\.xlsx?$/i.test(file.name)) {
    if (!window.XLSX) throw new Error('Leitor XLSX não carregado. Atualize a página.');
    sapImportState.workbook = XLSX.read(sapImportState.bytes, { type: 'array', cellDates: true });
    const select = document.getElementById('sapImportSheet');
    select.innerHTML = sapImportState.workbook.SheetNames.map((name) => `<option value="${escapeHtml(name)}">${escapeHtml(name)}</option>`).join('');
    document.getElementById('sapSheetLabel').hidden = false;
    selectSapWorkbookSheet(sapImportState.workbook.SheetNames[0]);
  } else {
    sapImportState.workbook = null;
    document.getElementById('sapSheetLabel').hidden = true;
    document.getElementById('sapImportText').value = await file.text();
  }
  await analyzeSapImportInput();
}

function selectSapWorkbookSheet(name) {
  sapImportState.sheet = name;
  const matrix = XLSX.utils.sheet_to_json(sapImportState.workbook.Sheets[name], { header: 1, defval: '', raw: true });
  loadSapMatrix(matrix);
  analyzeSapRows();
}

function loadSapMatrix(matrix) {
  const nonEmpty = (matrix || []).filter((row) => row.some((cell) => String(cell || '').trim()));
  sapImportState.headers = sapUniqueHeaders((nonEmpty.shift() || []).map((value) => String(value || '').trim()));
  sapImportState.sourceRows = nonEmpty.map((cells) => Object.fromEntries(sapImportState.headers.map((header, index) => [sapColumnKey(header), sapCellText(cells[index])])));
}

async function analyzeSapImportInput() {
  if (!sapImportState.workbook) {
    const parsed = parseDelimitedTable(document.getElementById('sapImportText').value);
    const originalHeaders = parsed.headers;
    sapImportState.headers = sapUniqueHeaders(originalHeaders);
    sapImportState.sourceRows = parsed.rows.map((row) => Object.fromEntries(
      sapImportState.headers.map((header, index) => [sapColumnKey(header), row[normalizeHeader(originalHeaders[index])] || ''])
    ));
    sapImportState.sheet = null;
    sapImportState.bytes = sapImportState.bytes || new TextEncoder().encode(document.getElementById('sapImportText').value).buffer;
    sapImportState.filename = sapImportState.filename || 'dados-colados.tsv';
  }
  analyzeSapRows();
}

function analyzeSapRows() {
  if (!sapImportState.headers.length || !sapImportState.sourceRows.length) {
    document.getElementById('sapDetection').innerHTML = CrmUi.renderState('error', 'Dados nao reconhecidos', 'Cabecalho ou linhas nao foram encontrados na fonte informada.');
    return;
  }
  sapImportState.mapping = Object.fromEntries(sapImportState.headers.map((header) => [header, suggestSapField(header)]));
  const detectedKind = detectSapImportKind(sapImportState.mapping, sapImportState.headers);
  document.getElementById('sapImportKind').value = detectedKind;
  const mapped = Object.values(sapImportState.mapping).filter(Boolean);
  const missing = (SAP_IMPORT_REQUIRED[detectedKind] || []).filter((field) => !mapped.includes(field));
  const codeHeader = Object.keys(sapImportState.mapping).find((header) => sapImportState.mapping[header] === 'product_code');
  sapImportState.ignoredRows = ['COMMERCIAL_PRODUCTS','SAP_ITEM_MASTER'].includes(detectedKind) && codeHeader
    ? sapImportState.sourceRows.filter((row) => !String(row[sapColumnKey(codeHeader)] || '').trim()).length : 0;
  document.getElementById('sapDetection').innerHTML = `
    <div class="section-heading"><div><h3>Deteccao concluida</h3><p>Confira o tipo identificado e os campos obrigatorios antes do staging.</p></div></div>
    <div class="import-summary">
      <div><strong>${escapeHtml(SAP_IMPORT_TYPES[detectedKind])}</strong><span>Tipo detectado</span></div>
      <div><strong>${sapImportState.sourceRows.length}</strong><span>linhas</span></div>
      <div><strong>${mapped.length}</strong><span>campos encontrados</span></div>
      <div><strong>${missing.length}</strong><span>campos ausentes</span></div>
      ${sapImportState.ignoredRows ? `<div><strong>${sapImportState.ignoredRows}</strong><span>separadores ignorados</span></div>` : ''}
    </div>
    ${missing.length ? `<div class="import-warnings">Ausentes: ${missing.map((field) => escapeHtml(SAP_IMPORT_FIELDS[field] || field)).join(', ')}</div>` : ''}`;
  setSapImportStage('detection');
  renderSapColumnMapping();
}

function renderSapColumnMapping() {
  if (!sapImportState.headers.length) return;
  const target = document.getElementById('sapMapping');
  target.hidden = false;
  target.innerHTML = `<div class="section-heading"><div><h3>Mapeamento de colunas</h3><p>Revise campos ambiguos antes de enviar ao staging.</p></div></div>
    <div class="import-mapping-grid">${sapImportState.headers.map((header) => `
      <label><span>${escapeHtml(header)}</span><select data-sap-map="${escapeHtml(header)}">
        <option value="">Ignorar</option>${Object.entries(SAP_IMPORT_FIELDS).map(([value, label]) => `<option value="${value}" ${sapImportState.mapping[header] === value ? 'selected' : ''}>${escapeHtml(label)}</option>`).join('')}
      </select></label>`).join('')}</div>
    <div class="table-wrap"><table><thead><tr>${sapImportState.headers.slice(0, 8).map((h) => `<th>${escapeHtml(h)}</th>`).join('')}</tr></thead>
      <tbody>${sapImportState.sourceRows.slice(0, 5).map((row) => `<tr>${sapImportState.headers.slice(0, 8).map((h) => `<td>${escapeHtml(row[sapColumnKey(h)] || '')}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`;
  target.querySelectorAll('[data-sap-map]').forEach((select) => select.addEventListener('change', () => {
    sapImportState.mapping[select.dataset.sapMap] = select.value;
    document.getElementById('sapValidateButton').disabled = false;
  }));
  document.getElementById('sapValidateButton').disabled = false;
}

function suggestSapField(header) {
  const normalized = sapNormalizeHeader(header);
  const matches = Object.entries(SAP_HEADER_ALIASES).filter(([, aliases]) => aliases.map(sapNormalizeHeader).includes(normalized));
  return matches.length === 1 ? matches[0][0] : '';
}

function detectSapImportKind(mapping, headers) {
  const fields = Object.values(mapping);
  const current = document.getElementById('sapImportKind').value;
  const sheet = sapNormalizeHeader(sapImportState.sheet || '');
  if (fields.includes('destination_state') && fields.includes('mva_rate') && fields.includes('internal_icms_rate')) {
    return sheet.includes('sap sp') || sheet.endsWith(' sp') || current === 'FISCAL_RULES_SP' ? 'FISCAL_RULES_SP' : 'FISCAL_RULES_PR';
  }
  if (fields.includes('general_available_qty')) return sheet.includes('estoque sp') || current === 'STOCK_SP' ? 'STOCK_SP' : 'STOCK_PR';
  if (fields.includes('base_price') && fields.filter(Boolean).length <= 4) return sheet.includes('sp') || current === 'BASE_PRICE_SP' ? 'BASE_PRICE_SP' : 'BASE_PRICE_PR';
  if (fields.includes('item_group') || fields.includes('manufacturer') || headers.some((header) => sapNormalizeHeader(header) === 'n do item')) return 'SAP_ITEM_MASTER';
  return 'COMMERCIAL_PRODUCTS';
}

async function stageAndValidateSapImport() {
  const message = document.getElementById('sapImportMessage');
  try {
    setSapImportStage('validation');
    const kind = document.getElementById('sapImportKind').value;
    const mapping = Object.fromEntries(Array.from(document.querySelectorAll('[data-sap-map]')).map((select) => [select.dataset.sapMap, select.value]));
    sapImportState.mapping = mapping;
    const detected = [...new Set(Object.values(mapping).filter(Boolean))];
    const explicitStMode = document.getElementById('sapImportHasSt').value;
    if (kind.startsWith('FISCAL_RULES_') && explicitStMode && !detected.includes('has_st')) detected.push('has_st');
    const missing = (SAP_IMPORT_REQUIRED[kind] || []).filter((field) => !detected.includes(field));
    if (missing.length) throw new Error(`Mapeie os campos obrigatórios: ${missing.map((field) => SAP_IMPORT_FIELDS[field]).join(', ')}.`);
    const rows = normalizeSapRows(kind, mapping);
    if (!rows.length) throw new Error('Nenhuma linha válida para staging.');
    if (kind.startsWith('FISCAL_RULES_') && rows.some((row) => row.data.has_st == null)) {
      throw new Error('Defina explicitamente se a relação possui ST ou mapeie uma coluna ST. Para arquivos mistos, importe cada rota separadamente.');
    }
    message.textContent = 'Calculando hash e criando lote...';
    const hash = await sapSha256(sapImportState.bytes || new TextEncoder().encode(JSON.stringify(rows)).buffer);
    const created = await supabaseCreateSapImportBatch({
      import_kind: kind, branch_code: document.getElementById('sapImportBranch').value, file_hash: hash,
      original_filename: sapImportState.filename, sheet_name: sapImportState.sheet, file_size: sapImportState.bytes ? sapImportState.bytes.byteLength : null,
      detected_fields: detected
    });
    sapImportState.batchId = created.batch_id;
    if (created.duplicate) {
      message.textContent = `Arquivo já importado. Lote ${created.batch_id}. Nenhum dado foi duplicado.`;
      sapImportState.preview = await supabasePreviewSapImportBatch(created.batch_id);
      renderSapServerPreview(sapImportState.preview);
      return;
    }
    await supabaseStageSapImportRows(created.batch_id, rows, (progress) => { message.textContent = `Enviando ${progress.done} de ${progress.total} linhas...`; });
    message.textContent = 'Validando dados no banco...';
    sapImportState.preview = await supabaseValidateSapImportBatch(created.batch_id);
    renderSapServerPreview(sapImportState.preview);
    const batch = sapImportState.preview.batch || {};
    message.textContent = batch.error_count ? `Validação encontrou ${batch.error_count} erro(s). Corrija antes de confirmar.` : 'Validação concluída. Revise o antes → depois.';
    document.getElementById('sapCommitButton').disabled = batch.state !== 'PREVIEWED' || batch.error_count > 0;
  } catch (error) {
    console.error(error);
    message.textContent = error.message || 'Falha ao validar importação.';
  }
}

function normalizeSapRows(kind, mapping) {
  const normalizedRows = sapImportState.sourceRows.map((source, index) => {
    const data = {};
    Object.entries(mapping).forEach(([header, field]) => {
      if (!field) return;
      const raw = source[sapColumnKey(header)];
      if (raw == null || String(raw).trim() === '') return;
      data[field] = normalizeSapValue(field, raw, header);
    });
    if (kind.startsWith('FISCAL_RULES_') && data.has_st == null) {
      const stMode = document.getElementById('sapImportHasSt').value;
      if (stMode) data.has_st = stMode === 'true';
    }
    if (kind.startsWith('STOCK_') && data.general_available_qty != null) {
      const display = String(source[sapColumnKey(Object.keys(mapping).find((header) => mapping[header] === 'general_available_qty') || '')] || '');
      data.general_available_capped = display.includes('+'); data.source_display_value = display;
    }
    return { row_number: index + 2, raw: source, data };
  }).filter((row) => Object.keys(row.data).length > 1 || row.data.ncm);
  const requiresCode = ['COMMERCIAL_PRODUCTS','SAP_ITEM_MASTER','STOCK_PR','STOCK_SP','BASE_PRICE_PR','BASE_PRICE_SP'].includes(kind);
  sapImportState.ignoredRows = requiresCode ? normalizedRows.filter((row) => !String(row.data.product_code || '').trim()).length : 0;
  return requiresCode ? normalizedRows.filter((row) => String(row.data.product_code || '').trim()) : normalizedRows;
}

function normalizeSapValue(field, raw, header) {
  if (['stock_qty','confirmed_qty','sales_available_qty','authorized_pending_qty','general_available_qty','base_price','ordered_qty','weight','volume'].includes(field)) return sapDecimal(raw);
  if (field.endsWith('_rate')) {
    const number = sapDecimal(raw); return number == null ? null : (String(header).includes('%') || Math.abs(number) > 1 ? number / 100 : number);
  }
  if (field === 'has_st') return ['1','true','sim','s','com st'].includes(String(raw).trim().toLowerCase());
  if (field === 'last_purchase_date') return sapDate(raw);
  if (field === 'ncm' || field === 'cest') return String(raw).replace(/\D/g, '');
  return String(raw).trim();
}

function renderSapServerPreview(preview) {
  const target = document.getElementById('sapServerPreview');
  const batch = preview.batch || {};
  const rows = preview.rows || [];
  target.hidden = false;
  target.innerHTML = `<div class="section-heading"><div><h3>Preview obrigatorio</h3><p>Lote ${escapeHtml(batch.id || '')}. Compare os valores antes e depois da importacao.</p></div></div>
    <div class="import-summary">
      <div><strong>${batch.total_rows || 0}</strong><span>linhas</span></div><div><strong>${batch.valid_rows || 0}</strong><span>válidas</span></div>
      <div><strong>${batch.warning_count || 0}</strong><span>avisos</span></div><div><strong>${batch.error_count || 0}</strong><span>erros</span></div>
    </div>
    <div class="table-wrap"><table><thead><tr><th>Linha</th><th>Status</th><th>Chave</th><th>Antes</th><th>Depois</th><th>Erros/avisos</th></tr></thead>
      <tbody>${rows.map((row) => `<tr><td>${row.row_number}</td><td><span class="status-pill">${escapeHtml(row.status)}</span></td>
        <td>${escapeHtml(row.normalized_code)}</td><td><pre class="import-json">${escapeHtml(sapCompactJson(row.before_data))}</pre></td>
        <td><pre class="import-json">${escapeHtml(sapCompactJson(row.after_data))}</pre></td>
        <td>${escapeHtml([...(row.errors || []), ...(row.warnings || [])].join(', '))}</td></tr>`).join('')}</tbody></table></div>`;
  setSapImportStage(batch.state === 'COMMITTED' ? 'complete' : 'preview');
}

async function approveAndCommitSapImport() {
  const button = document.getElementById('sapCommitButton');
  const message = document.getElementById('sapImportMessage');
  button.disabled = true;
  try {
    setSapImportStage('commit');
    message.textContent = 'Aprovando e confirmando transação...';
    await supabaseApproveSapImportBatch(sapImportState.batchId);
    const result = await supabaseCommitSapImportBatch(sapImportState.batchId);
    sapImportState.preview = result;
    renderSapServerPreview(result);
    const batch = result.batch || {};
    message.textContent = `IMPORTAÇÃO CONCLUÍDA — afetados: ${result.affected || 0}; ignorados sem chave: ${sapImportState.ignoredRows || 0}; lote: ${batch.id || sapImportState.batchId}.`;
    setSapImportStage('complete');
  } catch (error) { console.error(error); message.textContent = error.message || 'Commit rejeitado; nenhuma alteração parcial foi mantida.'; setSapImportStage('preview'); }
}

async function renderSapImportHistory() {
  const target = document.getElementById('importCenterContent');
  target.innerHTML = `<section class="panel import-history-panel">${CrmUi.renderState('loading', 'Carregando historico', 'Consultando os lotes auditaveis da Central de Importacoes.')}</section>`;
  try {
    const result = await supabaseListSapImportBatches({ limit: 200 });
    const rows = result.rows || [];
    target.innerHTML = `<section class="panel import-history-panel"><div class="section-heading"><div><h3>Historico de importacoes</h3><p>Arquivo, usuario, tipo, status e resultado auditavel.</p></div></div>
      ${rows.length ? `<div class="table-wrap import-history-table-wrap"><table class="import-history-table"><thead><tr><th>Data</th><th>Lote</th><th>Tipo</th><th>Arquivo/aba</th><th>Filial</th><th>Linhas</th><th>Status</th><th>Usuario</th></tr></thead>
      <tbody>${(result.rows || []).map((row) => `<tr><td>${escapeHtml(formatDateTime(row.created_at))}</td><td>${escapeHtml(row.id)}</td><td>${escapeHtml(SAP_IMPORT_TYPES[row.import_kind] || row.import_kind)}</td>
        <td>${escapeHtml(row.original_filename || '')}<small>${escapeHtml(row.sheet_name || '')}</small></td><td>${escapeHtml(row.region || row.origin_state || '')}</td>
        <td>${row.valid_rows || 0}/${row.total_rows || 0}</td><td><span class="status-pill">${escapeHtml(row.state)}</span></td><td>${escapeHtml(row.created_by_name || '')}</td></tr>`).join('')}</tbody></table></div>` : CrmUi.renderState('empty', 'Nenhum lote encontrado', 'As importacoes analisadas aparecerao aqui com seu status e responsavel.')}</section>`;
  } catch (error) { target.innerHTML = `<section class="panel import-history-panel">${CrmUi.renderState('error', 'Nao foi possivel carregar o historico', error.message)}</section>`; }
}

async function renderFiscalPendingPanel() {
  const target = document.getElementById('importCenterContent');
  target.innerHTML = `<section class="panel fiscal-pending-panel">${CrmUi.renderState('loading', 'Analisando pendencias fiscais', 'Consultando produtos, precos, estoques e rotas incompletas.')}</section>`;
  try {
    const data = await supabaseGetFiscalPending({ limit: 1000 }); const summary = data.summary || {}; const rows = data.rows || [];
    target.innerHTML = `<section class="panel fiscal-pending-panel"><div class="section-heading"><div><h3>Pendencias fiscais</h3><p>Produtos e rotas que impedem calculo confiavel.</p></div>
      <button class="btn btn-secondary" id="exportFiscalPending">Exportar CSV</button></div>
      <div class="import-summary"><div><strong>${summary.products_without_ncm || 0}</strong><span>sem NCM</span></div><div><strong>${summary.products_without_cest || 0}</strong><span>sem CEST</span></div>
      <div><strong>${summary.products_without_ipi || 0}</strong><span>sem IPI</span></div><div><strong>${summary.rules_incomplete || 0}</strong><span>regras incompletas</span></div>
      <div><strong>${summary.products_without_price_pr || 0}</strong><span>sem preço PR</span></div><div><strong>${summary.products_without_price_sp || 0}</strong><span>sem preço SP</span></div>
      <div><strong>${summary.products_without_stock_pr || 0}</strong><span>sem estoque PR</span></div><div><strong>${summary.products_without_stock_sp || 0}</strong><span>sem estoque SP</span></div>
      <div><strong>${summary.fiscal_source_rows_rejected || 0}</strong><span>linhas fiscais rejeitadas</span></div></div>
      ${rows.length ? `<div class="table-wrap fiscal-pending-table-wrap"><table class="fiscal-pending-table"><thead><tr><th>Codigo</th><th>Descricao</th><th>NCM</th><th>CEST</th><th>Rota</th><th>Status</th></tr></thead>
      <tbody>${rows.map((row) => `<tr><td>${escapeHtml(row.codigo)}</td><td>${escapeHtml(row.descricao)}</td><td>${escapeHtml(row.ncm)}</td><td>${escapeHtml(row.cest)}</td><td>${escapeHtml(row.route)}</td><td><span class="status-pill">${escapeHtml(row.status)}</span></td></tr>`).join('')}</tbody></table></div>` : CrmUi.renderState('success', 'Nenhuma pendencia listada', 'Os filtros atuais nao encontraram produtos ou rotas incompletas.')}</section>`;
    document.getElementById('exportFiscalPending').addEventListener('click', () => downloadCsv('pendencias-fiscais.csv', rows));
  } catch (error) { target.innerHTML = `<section class="panel fiscal-pending-panel">${CrmUi.renderState('error', 'Nao foi possivel analisar as pendencias', error.message)}</section>`; }
}

function renderCommercialListsPanel() {
  const target = document.getElementById('importCenterContent');
  target.innerHTML = `<section class="panel commercial-list-filter-panel"><div class="section-heading"><div><h3>Listas comerciais por rota</h3><p>Geradas dinamicamente a partir de preco base, estoque da filial e motor fiscal.</p></div></div>
    <div class="field-grid commercial-list-filters"><label class="span-4">Rota <select id="commercialListRoute"><option>PR-PR</option><option>SP-SP</option><option>PR-SC</option></select></label>
      <label class="span-4">Marca <input id="commercialListBrand"></label><label class="span-4">Grupo <input id="commercialListGroup"></label></div>
    <div class="actions-row commercial-list-actions"><button class="btn btn-primary" id="generateCommercialList" type="button">Gerar lista</button><button class="btn btn-secondary" id="exportCommercialCsv" type="button" disabled>Exportar CSV</button>
      <button class="btn btn-secondary" id="exportCommercialXlsx" type="button" disabled>Exportar XLSX</button></div></section><section class="panel commercial-list-result" id="commercialListResult" aria-live="polite">${CrmUi.renderState('empty', 'Escolha uma rota', 'A lista sera calculada sob demanda, sem armazenar preco fiscal como verdade absoluta.')}</section>`;
  document.getElementById('generateCommercialList').addEventListener('click', generateCommercialListFromUi);
  document.getElementById('exportCommercialCsv').addEventListener('click', () => exportCommercialList('csv'));
  document.getElementById('exportCommercialXlsx').addEventListener('click', () => exportCommercialList('xlsx'));
}

async function generateCommercialListFromUi() {
  const route = document.getElementById('commercialListRoute').value;
  const target = document.getElementById('commercialListResult');
  const generateButton = document.getElementById('generateCommercialList');
  generateButton.disabled = true;
  target.innerHTML = CrmUi.renderState('loading', `Gerando lista ${route}`, 'Calculando preco e disponibilidade para a rota selecionada.');
  try {
    const data = await supabaseGenerateCommercialList(route, { brand: document.getElementById('commercialListBrand').value.trim(), group: document.getElementById('commercialListGroup').value.trim() });
    sapImportState.listRows = data.rows || [];
    target.innerHTML = sapImportState.listRows.length ? `<div class="section-heading"><div><h3>Lista ${escapeHtml(route)}</h3><p>${data.count || sapImportState.listRows.length} produtos. A tela exibe no maximo 500 registros; a exportacao utiliza a lista completa.</p></div></div>
      <div class="table-wrap commercial-list-table-wrap"><table class="commercial-list-table"><thead><tr><th>CODIGO IPS</th><th>DESCRICAO</th><th>MARCA</th><th>APLICACAO</th><th>ANO</th><th>PRECO S/IMP</th><th>TRIBUTOS</th><th>PRECO C/IMPOSTOS</th><th>ESTOQUE</th><th>QUANTIDADE</th><th>STATUS FISCAL</th></tr></thead>
      <tbody>${sapImportState.listRows.slice(0, 500).map((row) => `<tr><td>${escapeHtml(row.product_code)}</td><td>${escapeHtml(row.description)}</td><td>${escapeHtml(row.brand)}</td><td>${escapeHtml(row.application)}</td><td>${escapeHtml(row.year)}</td>
        <td>${money(row.base_price)}</td><td>${money(row.total_taxes)}</td><td>${money(row.final_price)}</td><td>${escapeHtml(row.availability)}</td><td>${escapeHtml(row.source_display_value || row.available_qty)}</td><td><span class="status-pill">${escapeHtml(row.status)}</span></td></tr>`).join('')}</tbody></table></div>` : CrmUi.renderState('empty', `Lista ${route} sem produtos`, 'Revise os filtros ou verifique preco, estoque e configuracao fiscal da rota.');
  } catch (error) {
    sapImportState.listRows = [];
    target.innerHTML = CrmUi.renderState('error', 'Nao foi possivel gerar a lista', error.message);
  } finally {
    generateButton.disabled = false;
    document.getElementById('exportCommercialCsv').disabled = !sapImportState.listRows.length;
    document.getElementById('exportCommercialXlsx').disabled = !sapImportState.listRows.length;
  }
}

function commercialExportRows() {
  return sapImportState.listRows.map((row) => ({ 'CODIGO IPS': row.product_code, 'DESCRIÇÃO': row.description, 'MARCA': row.brand, 'APLICAÇÃO': row.application,
    'ANO': row.year, 'PREÇO S/IMP': row.base_price, 'TRIBUTOS': row.total_taxes, 'PREÇO C/IMPOSTOS': row.final_price,
    'ESTOQUE': row.availability, 'QUANTIDADE': row.source_display_value || row.available_qty, 'STATUS FISCAL': row.status }));
}

function exportCommercialList(type) {
  const route = document.getElementById('commercialListRoute').value; const rows = commercialExportRows();
  if (type === 'csv') return downloadCsv(`lista-${route}.csv`, rows);
  const workbook = XLSX.utils.book_new(); XLSX.utils.book_append_sheet(workbook, XLSX.utils.json_to_sheet(rows), `LISTA ${route}`); XLSX.writeFile(workbook, `lista-${route}.xlsx`);
}

function sapColumnKey(value) { return String(value || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/[^a-z0-9%]+/g, ' ').replace(/\s+/g, ' ').trim(); }
function sapNormalizeHeader(value) { return sapColumnKey(String(value || '').replace(/\s+\[\d+\]$/, '')); }
function sapUniqueHeaders(headers) { const counts = {}; return headers.map((header) => { const key = sapNormalizeHeader(header); counts[key] = (counts[key] || 0) + 1; return counts[key] === 1 ? header : `${header} [${counts[key]}]`; }); }
function sapCellText(value) { return value instanceof Date && !Number.isNaN(value.valueOf()) ? value.toISOString().slice(0, 10) : String(value == null ? '' : value).trim(); }
function sapDecimal(value) { const text = String(value == null ? '' : value).replace(/[^0-9,.-]/g, ''); if (!text) return null; const normalized = text.includes(',') ? (text.includes('.') ? text.replace(/\./g, '').replace(',', '.') : text.replace(',', '.')) : text; const number = Number(normalized); return Number.isFinite(number) ? number : null; }
function sapDate(value) { const text = String(value || '').trim(); if (!text) return null; if (/^\d{5}(?:\.\d+)?$/.test(text)) { const date = new Date(Date.UTC(1899, 11, 30) + Number(text) * 86400000); return date.toISOString().slice(0, 10); } const match = text.match(/^(\d{1,2})[\/.\-](\d{1,2})[\/.\-](\d{4})$/); if (match) return `${match[3]}-${match[2].padStart(2, '0')}-${match[1].padStart(2, '0')}`; return /^\d{4}-\d{2}-\d{2}$/.test(text) ? text : null; }
async function sapSha256(buffer) { const digest = await crypto.subtle.digest('SHA-256', buffer); return Array.from(new Uint8Array(digest)).map((byte) => byte.toString(16).padStart(2, '0')).join(''); }
function sapCompactJson(value) { if (!value) return '—'; const entries = Object.entries(value).filter(([, item]) => item != null && !['search_vector','search_text','raw_data'].includes(item)); return JSON.stringify(Object.fromEntries(entries.slice(0, 16)), null, 2); }
