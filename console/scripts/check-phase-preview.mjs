import assert from 'node:assert/strict';
import { mkdir } from 'node:fs/promises';
import { chromium } from 'playwright';

const url = process.argv[2] || 'https://ryodan.grooooog.space';
const output = new URL('../test-results/', import.meta.url);
await mkdir(output, { recursive: true });
const browser = await chromium.launch();
const reads = new Set(['eth_chainId', 'eth_blockNumber', 'eth_getBlockByNumber', 'eth_call', 'eth_getCode', 'eth_getBalance']);
try {
  for (const [device, width, height] of [['desktop', 1440, 1000], ['mobile', 390, 844]]) {
    const context = await browser.newContext({ viewport: { width, height }, isMobile: device === 'mobile', hasTouch: device === 'mobile', acceptDownloads: false, serviceWorkers: 'block' });
    const page = await context.newPage();
    const errors = [];
    const methods = new Set();
    const wallet = [];
    await page.exposeFunction('recordWalletRequest', method => wallet.push(method));
    await page.addInitScript(() => {
      window.ethereum = { request: async ({ method }) => {
        await window.recordWalletRequest(method);
        throw new Error('Wallet disabled in read-only check');
      }};
    });
    page.on('pageerror', e => errors.push(e.message));
    page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
    page.on('requestfailed', r => errors.push(r.url() + ' ' + r.failure()?.errorText));
    page.on('response', r => { if (r.status() >= 400) errors.push(r.status() + ' ' + r.url()); });
    page.on('download', d => errors.push('Unexpected download ' + d.suggestedFilename()));
    await context.route('**/*', async route => {
      const req = route.request();
      if (['GET', 'HEAD', 'OPTIONS'].includes(req.method())) return route.continue();
      if (req.method() === 'POST' && ['ethereum-rpc.publicnode.com', 'rpc.mevblocker.io'].includes(new URL(req.url()).hostname)) {
        const body = req.postDataJSON();
        const calls = Array.isArray(body) ? body : [body];
        if (calls.every(call => reads.has(call.method))) {
          calls.forEach(call => methods.add(call.method));
          return route.continue();
        }
      }
      errors.push('Blocked unexpected request ' + req.url());
      return route.abort();
    });
    await page.goto(url + '/#sale');
    const preview = page.locator('#phase-preview');
    const count = page.locator('#phase-count-dialog');
    const final = page.locator('#phase-final-dialog');
    let lastQuestion;
    let lastBlock;
    for (const outcome of ['cancel-count', 'cancel-final', 'acknowledge']) {
      await preview.click({ timeout: 60000 });
      await count.waitFor({ state: 'visible' });
      const active = page.locator('#page-sale .phase-step.current').first();
      const phase = await active.locator('strong').innerText();
      const match = (await active.innerText()).match(/(\d+) minted/i);
      assert.ok(match);
      lastQuestion = await page.locator('#phase-count-question').innerText();
      const amount = Number(match[1]);
      assert.ok(lastQuestion.includes(amount.toLocaleString('it-IT') + (amount === 1 ? ' chiave' : ' chiavi') + ' nella fase ' + phase));
      lastBlock = await page.locator('#block-label').innerText();
      assert.equal(await count.locator('[data-preview-only]').isVisible(), true);
      if (outcome === 'acknowledge') await count.screenshot({ path: output.pathname + device + '-phase-count.png' });
      await count.locator(outcome === 'cancel-count' ? 'button[value=cancel]' : 'button[value=continue]').click();
      if (outcome !== 'cancel-count') {
        await final.waitFor({ state: 'visible' });
        assert.match(await final.innerText(), /Sono consapevole che non posso più tornare indietro/);
        assert.equal(await final.locator('[data-preview-only]').isVisible(), true);
        assert.ok(await final.evaluate(el => el.getBoundingClientRect().width <= innerWidth && el.scrollWidth <= el.clientWidth));
        if (outcome === 'acknowledge') await final.screenshot({ path: output.pathname + device + '-phase-final.png' });
        await final.locator(outcome === 'cancel-final' ? 'button[value=cancel]' : 'button[value=continue]').click();
      }
      await page.waitForFunction(() => !document.querySelector('dialog[open]') && !document.querySelector('#phase-preview').disabled);
      assert.equal(await page.locator('#activity-log .error').count(), 0);
    }
    assert.equal(await page.locator('#contract-link').textContent(), '0x8C53E98B6659832f86DEb8Dd5c8FeE21C712D6e7');
    assert.equal(await page.locator('input[accept*="json"], a[download$=".json"]').count(), 0);
    assert.equal(await page.getByRole('button', {name: /\bjson\b/i}).count(), 0);
    assert.deepEqual(wallet, []);
    assert.deepEqual(errors, []);
    assert.ok(methods.has('eth_call'));
    console.log(device, lastBlock, lastQuestion, ' | both cancellations and acknowledgement passed; wallet requests=0; errors=0; RPC:', [...methods].join(', '));
    await context.close();
  }
} finally {
  await browser.close();
}
