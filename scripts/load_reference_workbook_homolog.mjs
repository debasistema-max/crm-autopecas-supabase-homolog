import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const XLSX = require('../js/vendor/xlsx.full.min.js');
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoDir = path.resolve(scriptDir, '..');
const expectedProjectRef = 'mtwvxyvpnbgwgltelozw';
const adminProfileId = '0599a872-82f0-4bf5-a7b4-9f908f4bcc1b';
const workbookPath = process.argv.find((arg) => !arg.startsWith('--') && arg !== process.argv[0] && arg !== process.argv[1]);
const shouldEmitSql = process.argv.includes('--emit-sql');

if (!workbookPath || !fs.existsSync(workbookPath)) {
  throw new Error('Informe o caminho existente do XLSX. Uso: node scripts/load_reference_workbook_homolog.mjs <arquivo.xlsx> [--apply]');
}

const fileBytes = fs.readFileSync(workbookPath);
const fileHash = crypto.createHash('sha256').update(fileBytes).digest('hex');
const workbook = XLSX.read(fileBytes, { type: 'buffer', cellDates: true });

function matrix(sheetName, raw = true) {
  const sheet = workbook.Sheets[sheetName];
  if (!sheet) throw new Error(`Aba ausente: ${sheetName}`);
  return XLSX.utils.sheet_to_json(sheet, { header: 1, defval: '', raw, blankrows: false });
}

function text(value) { return value == null ? '' : String(value).trim(); }
function digits(value) { const result = text(value).replace(/\D/g, ''); return result || null; }
function decimal(value) {
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  const source = text(value).replace(/[^0-9,.-]/g, '');
  if (!source) return null;
  const normalized = source.includes(',') ? (source.includes('.') ? source.replace(/\./g, '').replace(',', '.') : source.replace(',', '.')) : source;
  const number = Number(normalized);
  return Number.isFinite(number) ? number : null;
}
function rate(value) { const number = decimal(value); return number == null ? null : (Math.abs(number) > 1 ? number / 100 : number); }
function isoDate(value) {
  if (!value) return null;
  if (value instanceof Date && !Number.isNaN(value.valueOf())) return value.toISOString().slice(0, 10);
  if (typeof value === 'number') {
    const parts = XLSX.SSF.parse_date_code(value);
    return parts ? `${String(parts.y).padStart(4, '0')}-${String(parts.m).padStart(2, '0')}-${String(parts.d).padStart(2, '0')}` : null;
  }
  const source = text(value);
  const match = source.match(/^(\d{1,2})[\/.\-](\d{1,2})[\/.\-](\d{4})$/);
  return match ? `${match[3]}-${match[2].padStart(2, '0')}-${match[1].padStart(2, '0')}` : (/^\d{4}-\d{2}-\d{2}$/.test(source) ? source : null);
}
function compact(data) { return Object.fromEntries(Object.entries(data).filter(([, value]) => value !== '' && value != null)); }
function stageRows(rows, firstExcelRow) { return rows.map((data, index) => ({ row_number: index + firstExcelRow, data })); }

const commercialMatrix = matrix('MATRIZ', false).filter((row) => row.some((cell) => text(cell)));
const commercialSourceRows = commercialMatrix.slice(1).map((row) => compact({
  product_code: text(row[0]), description: text(row[1]), brand: text(row[2]), application: text(row[3]), year: text(row[4]),
  ipi_rate: rate(row[5]), base_price: decimal(row[6])
})).filter((row) => row.product_code);

function mergeCommercialProducts(rows) {
  const merged = new Map();
  for (const row of rows) {
    const current = merged.get(row.product_code);
    if (!current) { merged.set(row.product_code, { ...row }); continue; }
    for (const field of ['description','brand','year','ipi_rate','base_price']) {
      if (current[field] != null && row[field] != null && current[field] !== row[field]) {
        throw new Error(`Produto comercial duplicado conflitante ${row.product_code}: campo ${field}.`);
      }
      if (current[field] == null && row[field] != null) current[field] = row[field];
    }
    current.application = [...new Set([current.application,row.application].filter(Boolean))].join(' / ');
  }
  return [...merged.values()];
}
const commercialRows = mergeCommercialProducts(commercialSourceRows);

const sapMatrix = matrix('Cadastro Item SAP', true).filter((row) => row.some((cell) => text(cell)));
const sapRows = sapMatrix.slice(1).map((row) => compact({
  product_code: text(row[0]), description: text(row[1]), brand: text(row[2]), model: text(row[3]), year: text(row[4]),
  in_stock: text(row[5]), ordered_qty: decimal(row[6]), ipi_rate: rate(row[7]), oem_01: text(row[8]), delivery: text(row[9]),
  ncm: digits(row[10]), last_purchase_date: isoDate(row[11]), compatible: text(row[12]), import_notes: text(row[13]),
  item_group: text(row[14]), sales_unit: text(row[15]), item_notes: text(row[16]), weight: decimal(row[17]), volume: decimal(row[18]),
  cest: digits(row[19]), manufacturer_code_01: text(row[20]), manufacturer_code_02: text(row[21]), manufacturer: text(row[22]),
  barcode: text(row[23]), product_source: text(row[24]), material_type: text(row[25]), origin_and_fiscal_group: text(row[28]),
  materials_group: text(row[29]), origin_and_ncm: text(row[30])
})).filter((row) => row.product_code);

const stockMatrix = matrix('PORTAL ESTOQUE PR', false).filter((row) => row.some((cell) => text(cell)));
const stockRows = stockMatrix.slice(1).map((row) => {
  const display = text(row[7]);
  return compact({ product_code: text(row[1]), description: text(row[2]), stock_qty: decimal(row[3]), confirmed_qty: decimal(row[4]),
    sales_available_qty: decimal(row[5]), authorized_pending_qty: decimal(row[6]), general_available_qty: decimal(display),
    general_available_capped: display.includes('+'), source_display_value: display, group: text(row[8]) });
}).filter((row) => row.product_code);

const priceRows = commercialRows.filter((row) => row.base_price != null && row.base_price >= 0)
  .map((row) => ({ product_code: row.product_code, base_price: row.base_price }));

function fiscalRows(sheetName, destinations, origin) {
  const fiscalMatrix = matrix(sheetName, false).filter((row) => row.some((cell) => text(cell)));
  const selected = fiscalMatrix.slice(1).map((row) => compact({
    source_code: text(row[0]), ncm: digits(row[1]), destination_state: text(row[2]).toUpperCase(),
    interstate_icms_rate: rate(row[3]), internal_icms_rate: rate(row[4]), mva_rate: rate(row[5]), ipi_rate: rate(row[6])
  })).filter((row) => row.ncm && destinations.includes(row.destination_state));
  return selected.map((row) => ({ ...row, has_st: !(origin === 'PR' && row.destination_state === 'SC') }));
}

function deduplicateFiscal(rows, label) {
  const unique = new Map(); const conflicts = [];
  for (const row of rows) {
    const key = `${row.ncm}|${row.destination_state}`;
    if (unique.has(key) && JSON.stringify(unique.get(key)) !== JSON.stringify(row)) conflicts.push(key);
    else unique.set(key, row);
  }
  if (conflicts.length) throw new Error(`${label}: regras conflitantes duplicadas: ${[...new Set(conflicts)].slice(0, 20).join(', ')}`);
  return [...unique.values()];
}

const fiscalPrRows = deduplicateFiscal(fiscalRows('dados fiscais sap pr', ['PR','SC'], 'PR'), 'FISCAL PR');
const fiscalSpRows = deduplicateFiscal(fiscalRows('dados fiscais sap sp', ['SP'], 'SP'), 'FISCAL SP');
const fiscalSpImportRows = fiscalSpRows.filter((row) => !row.has_st || (row.internal_icms_rate != null && row.mva_rate != null));

function duplicateKeys(rows, field) { const seen = new Set(); const duplicates = new Set(); for (const row of rows) { const key = row[field]; if (seen.has(key)) duplicates.add(key); seen.add(key); } return [...duplicates]; }
const datasets = [
  { key: 'sap', kind: 'SAP_ITEM_MASTER', sheet: 'Cadastro Item SAP', rows: sapRows, detected: Object.keys(sapRows[0] || {}) },
  { key: 'commercial', kind: 'COMMERCIAL_PRODUCTS', sheet: 'MATRIZ', rows: commercialRows, detected: ['product_code','description','brand','application','year','ipi_rate'] },
  { key: 'stock_pr', kind: 'STOCK_PR', sheet: 'PORTAL ESTOQUE PR', rows: stockRows, detected: ['product_code','description','stock_qty','confirmed_qty','sales_available_qty','authorized_pending_qty','general_available_qty','group'] },
  { key: 'price_pr', kind: 'BASE_PRICE_PR', sheet: 'MATRIZ / PRECO BASE PR', rows: priceRows, detected: ['product_code','base_price'] },
  { key: 'price_sp', kind: 'BASE_PRICE_SP', sheet: 'MATRIZ / PRECO BASE SP', rows: priceRows, detected: ['product_code','base_price'] },
  { key: 'fiscal_pr', kind: 'FISCAL_RULES_PR', sheet: 'dados fiscais sap pr / PR+SC', rows: fiscalPrRows, detected: ['source_code','ncm','destination_state','interstate_icms_rate','internal_icms_rate','mva_rate','ipi_rate','has_st'] },
  { key: 'fiscal_sp', kind: 'FISCAL_RULES_SP', sheet: 'dados fiscais sap sp / SP', rows: fiscalSpImportRows, detected: ['source_code','ncm','destination_state','interstate_icms_rate','internal_icms_rate','mva_rate','ipi_rate','has_st'] }
];

const report = {
  workbook: path.resolve(workbookPath), file_hash: fileHash, sheets: workbook.SheetNames,
  source_exceptions: { commercial_separator_rows_without_code: commercialMatrix.slice(1).filter((row) => !text(row[0]) && row.some((cell) => text(cell))).length,
    commercial_duplicate_rows_merged: commercialSourceRows.length-commercialRows.length,
    fiscal_sp_incomplete_not_imported: fiscalSpRows.filter((row) => row.has_st && (row.internal_icms_rate == null || row.mva_rate == null)) },
  datasets: datasets.map((dataset) => { const duplicateSamples = dataset.kind.startsWith('FISCAL_') ? [] : duplicateKeys(dataset.rows, 'product_code').slice(0, 10); return ({ kind: dataset.kind, sheet: dataset.sheet, rows: dataset.rows.length,
    duplicate_product_codes: duplicateSamples.length,
    duplicate_samples: duplicateSamples,
    duplicate_rows: dataset.rows.filter((row) => duplicateSamples.includes(row.product_code)).slice(0, 20),
    missing_ipi: dataset.rows.filter((row) => row.ipi_rate == null).length,
    missing_internal_icms: dataset.rows.filter((row) => row.has_st && row.internal_icms_rate == null).length,
    missing_mva: dataset.rows.filter((row) => row.has_st && row.mva_rate == null).length,
    incomplete_route_samples: dataset.rows.filter((row) => row.has_st && (row.internal_icms_rate == null || row.mva_rate == null)).slice(0, 10) }); })
};
console.log(JSON.stringify(report, null, 2));
if (!shouldEmitSql) process.exit(0);

const envPath = path.resolve(repoDir, '..', '.env.homolog.local');
const env = Object.fromEntries(fs.readFileSync(envPath, 'utf8').split(/\r?\n/).filter((line) => line && !line.trim().startsWith('#') && line.includes('='))
  .map((line) => { const index = line.indexOf('='); return [line.slice(0, index).trim(), line.slice(index + 1).trim().replace(/^"|"$/g, '')]; }));
if (env.SUPABASE_HOMOLOG_PROJECT_REF !== expectedProjectRef) throw new Error('Projeto Supabase não corresponde à homologação autorizada.');

const sql = ['\\set ON_ERROR_STOP on', 'begin;', `select set_config('request.jwt.claim.sub','${adminProfileId}',true);`];
for (const dataset of datasets) {
  if (!dataset.rows.length) continue;
  const metadata = { import_kind: dataset.kind, branch_code: dataset.kind.endsWith('_SP') ? 'SP' : 'PR', file_hash: fileHash,
    original_filename: path.basename(workbookPath), sheet_name: dataset.sheet, file_size: fileBytes.length,
    source_name: 'REFERENCE_WORKBOOK', detected_fields: dataset.detected };
  sql.push(`select (public.create_sap_import_batch($meta$${JSON.stringify(metadata)}$meta$::jsonb)->>'batch_id') as batch_id \\gset ${dataset.key}_`);
  const staged = stageRows(dataset.rows, 2);
  for (let index = 0; index < staged.length; index += 200) {
    sql.push(`select public.stage_sap_import_rows(:'${dataset.key}_batch_id'::uuid,$rows$${JSON.stringify(staged.slice(index, index + 200))}$rows$::jsonb)->>'staged_rows' as staged;`);
  }
  sql.push(`select (public.validate_sap_import_batch(:'${dataset.key}_batch_id'::uuid)->'batch')::text as validation;`);
  sql.push(`select public.approve_sap_import_batch(:'${dataset.key}_batch_id'::uuid)->>'state' as approval;`);
  sql.push(`with r as (select public.commit_sap_import_batch(:'${dataset.key}_batch_id'::uuid) value) select value->'batch'->>'state' state,value->>'affected' affected from r;`);
}
sql.push('commit;');

const sqlPath = path.join(process.env.TEMP || process.env.TMP || repoDir, `crm-homolog-import-${fileHash.slice(0, 12)}.sql`);
fs.writeFileSync(sqlPath, sql.join('\n'), 'utf8');
console.log(`SQL_FILE=${sqlPath}`);
