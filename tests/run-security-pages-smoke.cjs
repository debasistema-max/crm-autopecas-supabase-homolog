const { chromium } = require('playwright');

const baseUrl = process.argv[2] || 'http://127.0.0.1:8765';
const pages = ['index.html', 'b2b/index.html', 'cadastro-publico/index.html'];

(async () => {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  let failures = 0;
  for (const file of pages) {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    page.on('console', (message) => {
      if (message.type() === 'error') errors.push(message.text());
    });
    const response = await page.goto(`${baseUrl}/${file}`, { waitUntil: 'networkidle' });
    const supabaseLoaded = await page.evaluate(() => Boolean(window.supabase?.createClient));
    const securityErrors = errors.filter((message) => /content security policy|integrity|refused to (load|connect)/i.test(message));
    const passed = response?.ok() && supabaseLoaded && securityErrors.length === 0;
    console.log(`${passed ? 'PASS' : 'FAIL'} ${file}`, passed ? '' : JSON.stringify({
      status: response?.status(), supabaseLoaded, securityErrors
    }));
    if (!passed) failures += 1;
    await page.close();
  }

  {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    const response = await page.goto(`${baseUrl}/tests/ui-import-center-smoke.html`, { waitUntil: 'networkidle' });
    const assertions = await page.locator('#smokeAssertions').evaluate((element) => element.value);
    const parsed = assertions ? JSON.parse(assertions) : {};
    const passed = response?.ok() && errors.length === 0 && parsed.xlsxLoaded === true;
    console.log(`${passed ? 'PASS' : 'FAIL'} tests/ui-import-center-smoke.html`, passed ? '' : JSON.stringify({
      status: response?.status(), errors, assertions: parsed
    }));
    if (!passed) failures += 1;
    await page.close();
  }
  await browser.close();
  process.exitCode = failures ? 1 : 0;
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
