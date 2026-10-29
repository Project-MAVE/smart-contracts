import { chromium } from 'playwright';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const url = process.argv[2] || 'https://ryodan.grooooog.space';
const destination = new URL('../test-results/', import.meta.url);
await mkdir(destination, { recursive: true });
const deployment = JSON.parse(await readFile(new URL('../src/deployment.json', import.meta.url), 'utf8'));
const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const browser = await chromium.launch({ headless: true, ...(existsSync(chrome) ? { executablePath: chrome } : {}) });
let page;
const errors = [];
const requests = [];
try {
  page = await browser.newPage({ viewport: { width: 1440, height: 1100 } });
  page.on('request', request => { requests.push(request.url()); });
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  page.on('requestfailed', request => errors.push(`${request.method()} ${request.url()}: ${request.failure()?.errorText}`));
  page.on('response', response => { if (response.status() >= 400) errors.push(`${response.status()} ${response.url()}`); });
  const response = await page.goto(url);
  assert.equal(response.status(), 200);
  await page.waitForFunction(() => document.querySelector('#sync-status')?.textContent.includes('SYNCHRONIZED'), null, { timeout: 60000 });
  assert.equal(await page.locator('#contract-link').textContent(), deployment.address);
  assert.equal(await page.locator('#contract-link').getAttribute('href'), `https://sepolia.etherscan.io/address/${deployment.address}`);
  assert.equal(await page.locator('#deployment option').count(), 6);
  assert.equal(await page.locator('[data-action="mint"]').isDisabled(), true);
  const metrics = await page.locator('.metrics').innerText();
  assert.match(metrics, /PIONEER/);
  await page.screenshot({ path: fileURLToPath(new URL('sepolia-desktop.png', destination)), fullPage: true, animations: 'disabled' });
  await page.locator('#deployment').selectOption('0x4b8D8fd22FB818aa7b312Cb72F7048E4d738109B');
  await page.waitForFunction(() => document.querySelector('#sync-status').textContent.includes('SYNCHRONIZED'), null, { timeout: 60000 });
  await page.locator('a[data-page="sale"]').click();
  assert.equal(await page.locator('#legacy-phase-form').isVisible(), true);
  assert.equal(await page.locator('#phase-form').isVisible(), false);
  await page.locator('#deployment').selectOption('0x85b1024194cFd547Eb81877f8efF77587e7604f9');
  await page.waitForFunction(() => document.querySelector('#sync-status').textContent.includes('SYNCHRONIZED'), null, { timeout: 60000 });
  assert.match(await page.locator('#contract-link').getAttribute('href'), /0x85b1024/);
  await page.locator('#deployment').selectOption(deployment.address);
  await page.waitForFunction(() => document.querySelector('#sync-status').textContent.includes('SYNCHRONIZED'), null, { timeout: 60000 });
  await page.route('**/ethereum-sepolia-rpc.publicnode.com/**', async route => {
    const payload = route.request().postDataJSON();
    const failure = request => ({ id: request.id, jsonrpc: '2.0', error: { code: -32000, message: 'Expected test: primary RPC unavailable' } });
    await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(Array.isArray(payload) ? payload.map(failure) : failure(payload)) });
  });
  const fallbackResponse = page.waitForResponse(response => response.url().startsWith('https://rpc.sepolia.ethpandaops.io') && response.status() === 200);
  await page.reload();
  await fallbackResponse;
  await page.waitForFunction(() => /SYNCHRONIZED|OFFLINE/.test(document.querySelector('#sync-status').textContent), null, { timeout: 60000 });
  assert.match(await page.locator('#sync-status').textContent(), /SYNCHRONIZED/, await page.locator('#notice').textContent());
  assert.match(await page.locator('.metrics').innerText(), /PIONEER/);
  await page.unroute('**/ethereum-sepolia-rpc.publicnode.com/**');
  await page.reload();
  await page.waitForFunction(() => document.querySelector('#sync-status').textContent.includes('SYNCHRONIZED'), null, { timeout: 60000 });
  await page.setViewportSize({ width: 390, height: 844 });
  for (const view of ['mint', 'sale', 'treasury', 'reveal', 'access', 'refund']) {
    await page.locator(`a[data-page="${view}"]`).click();
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, view);
  }
  await page.locator('a[data-page="mint"]').click();
  await page.screenshot({ path: fileURLToPath(new URL('sepolia-mobile.png', destination)), fullPage: true, animations: 'disabled' });
  assert.deepEqual(errors, []);
  const result = { url, checkedAt: new Date().toISOString(), address: deployment.address, metrics, checks: ['HTTP 200', 'Live Sepolia state', 'v3 selected by default', 'Etherscan address links', 'v2 legacy controls and v1 read compatibility', 'Read-only without wallet', 'Six mobile views without overflow', 'Primary RPC failure recovers through live ethPandaOps fallback', 'No unexpected browser or network errors'] };
  await writeFile(new URL('site-verification.json', destination), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result, null, 2));
} catch (error) {
  console.error(JSON.stringify({ notice: await page?.locator('#notice').textContent().catch(() => ''), errors, recentRequests: requests.slice(-12) }, null, 2));
  throw error;
} finally { await browser.close(); }
