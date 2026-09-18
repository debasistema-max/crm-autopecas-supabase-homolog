const { chromium } = require('playwright');

const baseUrl = process.argv[2] || 'http://127.0.0.1:8765';
const pages = [
  'ui-b2b-smoke.html',
  'ui-b2b-admin-smoke.html',
  'ui-operational-smoke.html?module=products',
  'ui-operational-smoke.html?module=partners',
  'ui-commercial-documents-smoke.html?doc=quote'
];
const viewports = [
  { width: 390, height: 844 },
  { width: 768, height: 1024 },
  { width: 1440, height: 1000 }
];

(async () => {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  let failures = 0;
  for (const file of pages) {
    for (const viewport of viewports) {
      const page = await browser.newPage({ viewport });
      const errors = [];
      page.on('pageerror', (error) => errors.push(error.message));
      await page.goto(`${baseUrl}/tests/${file}`, { waitUntil: 'networkidle' });
      await page.waitForFunction(() => ['pass', 'fail'].includes(document.documentElement.dataset.smoke), null, { timeout: 5000 });
      const result = await page.evaluate(() => ({
        smoke: document.documentElement.dataset.smoke,
        overflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
        smokeResult: document.getElementById('smokeResult')?.value || '',
        text: document.body.innerText.slice(0, 3000)
      }));
      const passed = result.smoke === 'pass' && !result.overflow && errors.length === 0;
      console.log(`${passed ? 'PASS' : 'FAIL'} ${file} ${viewport.width}x${viewport.height}`,
        passed ? '' : JSON.stringify({ ...result, errors }));
      if (!passed) failures += 1;
      await page.close();
    }
  }
  await browser.close();
  process.exitCode = failures ? 1 : 0;
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
