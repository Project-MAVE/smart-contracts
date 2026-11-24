import { chromium } from 'playwright';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const url = process.argv[2] || 'https://ryodan.grooooog.space';
const destination = new URL('../test-results/', import.meta.url);
await mkdir(destination, { recursive: true });
const deployment = JSON.parse(await readFile(new URL('../src/deployment.json', import.meta.url), 'utf8'));
if (!deployment.address) throw new Error('No v8 deployment in src/deployment.json: deploy the v8 contract before checking the live site.');
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
  assert.equal(await page.locator('#contract-link').getAttribute('href'), `https://etherscan.io/address/${deployment.address}`);
  assert.equal(await page.locator('#deployment option').count(), 1);
  assert.equal(await page.locator('[data-action="mint"]').isDisabled(), true);
  const metrics = await page.locator('.metrics').innerText();
  assert.equal(await page.locator('#network-name').textContent(), 'ETH MAINNET');
  await page.screenshot({ path: fileURLToPath(new URL('mainnet-desktop.png', destination)), fullPage: true, animations: 'disabled' });
  await page.locator('a[data-page="sale"]').click();
  await page.locator('#snapshot-panel').waitFor({ state: 'visible' });
  assert.match(await page.locator('#snapshot-summary').textContent(), /Matches the on-chain snapshot/);
  for (const tier of ['pioneer', 'operative', 'recruit']) {
    const response = await page.request.get(`${url}/templates/${tier}.csv`);
    assert.equal(response.status(), 200); assert.equal(await response.text(), 'address\n');
  }
  const downloadEvent = page.waitForEvent('download');
  await page.locator('a[href="/templates/ryodan-allowlist-templates.zip"]').click();
  const download = await downloadEvent;
  assert.equal(download.suggestedFilename(), 'ryodan-allowlist-templates.zip');
  assert((await readFile(await download.path())).length > 500);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: fileURLToPath(new URL('mainnet-sale.png', destination)), fullPage: true, animations: 'disabled' });
  await page.route('**/ethereum-rpc.publicnode.com/**', async route => {
    const payload = route.request().postDataJSON();
    const failure = request => ({ id: request.id, jsonrpc: '2.0', error: { code: -32000, message: 'Expected test: primary RPC unavailable' } });
    await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(Array.isArray(payload) ? payload.map(failure) : failure(payload)) });
  });
  const fallbackResponse = page.waitForResponse(response => response.url().startsWith('https://rpc.mevblocker.io') && response.status() === 200);
  await page.reload();
  await fallbackResponse;
  await page.waitForFunction(() => /SYNCHRONIZED|OFFLINE/.test(document.querySelector('#sync-status').textContent), null, { timeout: 60000 });
  assert.match(await page.locator('#sync-status').textContent(), /SYNCHRONIZED/, await page.locator('#notice').textContent());
  assert.equal(await page.locator('#contract-link').textContent(), deployment.address);
  await page.unroute('**/ethereum-rpc.publicnode.com/**');
  await page.reload();
  await page.waitForFunction(() => document.querySelector('#sync-status').textContent.includes('SYNCHRONIZED'), null, { timeout: 60000 });
  await page.setViewportSize({ width: 390, height: 844 });
  for (const view of ['mint', 'sale', 'treasury', 'reveal', 'access', 'refund']) {
    await page.locator(`a[data-page="${view}"]`).click();
    await page.locator(`#page-${view}`).waitFor({ state: 'visible' });
    await page.waitForFunction(() => document.documentElement.scrollWidth <= innerWidth, null, { timeout: 3000 });
  }
  await page.locator('a[data-page="mint"]').click();
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: fileURLToPath(new URL('mainnet-mobile.png', destination)), fullPage: true, animations: 'disabled' });
  assert.deepEqual(errors, []);
  const result = { url, checkedAt: new Date().toISOString(), address: deployment.address, metrics, checks: ['HTTP 200', 'Live Ethereum mainnet state', 'v8 contract only', 'Etherscan address links', 'Matching live snapshot and downloadable CSV/ZIP templates', 'Read-only without wallet', 'Six mobile views without overflow', 'Primary RPC failure recovers through live MEV Blocker fallback', 'No unexpected browser or network errors'] };
  await writeFile(new URL('site-verification.json', destination), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result, null, 2));
} catch (error) {
  console.error(JSON.stringify({ notice: await page?.locator('#notice').textContent().catch(() => ''), errors, recentRequests: requests.slice(-12) }, null, 2));
  throw error;
} finally { await browser.close(); }
