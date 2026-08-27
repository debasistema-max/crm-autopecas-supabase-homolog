(function createCrmUi(global) {
  function escape(value) {
    if (typeof global.escapeHtml === 'function') return global.escapeHtml(value);
    return String(value == null ? '' : value)
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#039;');
  }

  function renderState(type, title, message, actionHtml = '') {
    const safeType = ['empty', 'error', 'loading', 'success'].includes(type) ? type : 'empty';
    const role = safeType === 'error' ? 'alert' : 'status';
    return `
      <section class="ui-state ui-state-${safeType}" role="${role}">
        <span class="ui-state-mark" aria-hidden="true"></span>
        <div><strong>${escape(title)}</strong>${message ? `<p>${escape(message)}</p>` : ''}</div>
        ${actionHtml ? `<div class="ui-state-action">${actionHtml}</div>` : ''}
      </section>`;
  }

  function renderPageHeader(title, description = '', actionsHtml = '', eyebrow = '') {
    return `
      <header class="page-header">
        <div>${eyebrow ? `<p class="page-header-eyebrow">${escape(eyebrow)}</p>` : ''}<h2>${escape(title)}</h2>${description ? `<p>${escape(description)}</p>` : ''}</div>
        ${actionsHtml ? `<div class="page-header-actions">${actionsHtml}</div>` : ''}
      </header>`;
  }

  function renderStatusBadge(code, label) {
    const normalized = String(code || '').trim().toLowerCase().replace(/[^a-z0-9_-]/g, '-');
    return `<span class="status-pill ${escape(normalized)}">${escape(label || code)}</span>`;
  }

  function enhanceResponsiveTables(root = document) {
    const tables = [];
    if (root instanceof Element && root.matches('table')) tables.push(root);
    if (root.querySelectorAll) tables.push(...root.querySelectorAll('table'));

    tables.forEach((table) => {
      if (table.classList.contains('sap-items-table')) return;
      const labels = Array.from(table.querySelectorAll('thead th')).map((header) => header.textContent.trim());
      if (!labels.length) return;
      table.querySelectorAll('tbody tr').forEach((row) => {
        Array.from(row.children).forEach((cell, index) => {
          if (cell.tagName !== 'TD' || cell.dataset.label) return;
          if (labels[index]) cell.dataset.label = labels[index];
        });
      });
      table.dataset.responsiveReady = 'true';
    });
  }

  function observeResponsiveTables(root) {
    if (!root || typeof MutationObserver === 'undefined') return null;
    enhanceResponsiveTables(root);
    let scheduled = false;
    const observer = new MutationObserver(() => {
      if (scheduled) return;
      scheduled = true;
      queueMicrotask(() => {
        scheduled = false;
        enhanceResponsiveTables(root);
      });
    });
    observer.observe(root, { childList: true, subtree: true });
    return observer;
  }

  global.CrmUi = Object.freeze({
    enhanceResponsiveTables,
    observeResponsiveTables,
    renderPageHeader,
    renderState,
    renderStatusBadge
  });
})(window);
