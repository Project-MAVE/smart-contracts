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
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1100 } });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const response = await page.goto(url);
  assert.equal(response.status(), 200);
  await page.waitForFunction(() => document.querySelector('#sync-status')?.textContent.includes('SYNCHRONIZED'), null, { timeout: 60000 });
  assert.equal(await page.locator('#contract-link').textContent(), deployment.address);
  assert.equal(await page.locator('#contract-link').getAttribute('href'), `https://sepolia.etherscan.io/address/${deployment.address}`);
  assert.equal(await page.locator('#deployment option').count(), 4);
  assert.equal(await page.locator('[data-action="mint"]').isDisabled(), true);
  const metrics = await page.locator('.metrics').innerText();
  assert.match(metrics, /PUBLIC/);
  await page.screenshot({ path: fileURLToPath(new URL('sepolia-desktop.png', destination)), fullPage: true, animations: 'disabled' });
  await page.locator('#deployment').selectOption('0x85b1024194cFd547Eb81877f8efF77587e7604f9');
  await page.waitForFunction(() => document.querySelector('#sync-status').textContent.includes('SYNCHRONIZED'), null, { timeout: 60000 });
  assert.match(await page.locator('#contract-link').getAttribute('href'), /0x85b1024/);
  await page.locator('#deployment').selectOption(deployment.address);
  await page.waitForFunction(() => document.querySelector('#sync-status').textContent.includes('SYNCHRONIZED'), null, { timeout: 60000 });
  await page.setViewportSize({ width: 390, height: 844 });
  for (const view of ['mint', 'sale', 'treasury', 'reveal', 'access', 'refund']) {
    await page.locator(`a[data-page="${view}"]`).click();
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, view);
  }
  await page.locator('a[data-page="mint"]').click();
  await page.screenshot({ path: fileURLToPath(new URL('sepolia-mobile.png', destination)), fullPage: true, animations: 'disabled' });
  assert.deepEqual(errors, []);
  const result = { url, checkedAt: new Date().toISOString(), address: deployment.address, metrics, checks: ['HTTP 200', 'Live Sepolia state', 'v2 selected by default', 'Etherscan address links', 'Earlier test deployment selectable', 'Read-only without wallet', 'Six mobile views without overflow', 'No uncaught browser errors'] };
  await writeFile(new URL('site-verification.json', destination), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result, null, 2));
} finally { await browser.close(); }
