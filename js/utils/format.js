function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

function money(value) {
  return Number(value || 0).toLocaleString('pt-BR', {
    style: 'currency',
    currency: APP_CONFIG.currency
  });
}

function csvValue(value) {
  const text = String(value ?? '').replaceAll('"', '""');
  return `"${text}"`;
}

function csvCell(value) {
  const text = String(value ?? '').replaceAll('"', '""');
  return /[;"\n\r]/.test(text) ? `"${text}"` : text;
}

function downloadCsv(filename, rows) {
  const headers = Array.isArray(rows[0]) ? null : Object.keys(rows[0] || {});
  const csv = headers
    ? [headers.join(';')].concat(rows.map((row) => headers.map((header) => csvValue(row[header])).join(';'))).join('\r\n')
    : rows.map((row) => row.map(csvValue).join(';')).join('\n');
  const blob = new Blob(['\ufeff' + csv], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  link.click();
  URL.revokeObjectURL(url);
}
