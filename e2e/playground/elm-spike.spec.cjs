const { test, expect } = require('@playwright/test');
const fs = require('node:fs');
const path = require('node:path');
test.skip(!process.env.PLAYGROUND_ELM_SPIKE, 'Optional feasibility build; excluded from the production playground.');
const ready = async page => {
  await page.waitForFunction(() => window.TeslElmSpike);
  await expect(page.locator('#spike-check-status')).not.toContainText('Checking');
};

test('Elm edit/check/search/share and historic source selection', async ({ page }) => {
  const source = fs.readFileSync(path.resolve(__dirname, '../../example/adoption/validation-title.tesl'), 'utf8');
  const fragment = '#s' + Buffer.from(source).toString('base64url') + '.L2-3.H4';
  await page.goto('/elm-spike.html' + fragment); await ready(page);
  expect(await page.locator('#spike-source').inputValue()).toBe(source);
  const selected = await page.locator('#spike-source').evaluate(el => el.value.slice(el.selectionStart, el.selectionEnd));
  expect(selected).toBe(source.split('\n').slice(1, 3).join('\n') + '\n');
  await page.locator('#spike-query').fill('String -> Int');
  await expect(page.getByRole('heading', { name: 'String.length', exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Make share link', exact: true }).click();
  await expect(page.locator('#spike-share')).toContainText('index.html#');
  const link = await page.locator('#spike-share').textContent();
  expect(new URL(link).hash.endsWith('.L2-3.H4-4')).toBe(true);
  await page.goto(link);
  await page.waitForFunction(() => typeof window.teslCheck === 'function');
  expect(await page.locator('#src').inputValue()).toBe(source);
});

test('Elm preserves native undo and simulated IME through diagnostic rerenders', async ({ page }) => {
  await page.goto('/elm-spike.html'); await ready(page);
  const editor = page.locator('#spike-source'), initial = await editor.inputValue();
  await editor.focus(); await editor.press('Control+End');
  await page.keyboard.insertText('\n# 日本語');
  await expect(page.locator('#spike-check-status')).toHaveText('No diagnostics.');
  await page.waitForTimeout(300);
  expect(await editor.inputValue()).toBe(initial + '\n# 日本語');
  await editor.press('Control+z');
  expect(await editor.inputValue()).toBe(initial);
  await editor.evaluate(el => {
    el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    el.value += '\n# 文';
    el.setSelectionRange(el.value.length, el.value.length);
    el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertCompositionText', data: '文', isComposing: true }));
    el.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '文' }));
  });
  await page.waitForTimeout(300);
  expect(await editor.inputValue()).toBe(initial + '\n# 文');
  expect(await editor.evaluate(el => el.selectionStart)).toBe((initial + '\n# 文').length);
  await page.screenshot({ path: test.info().outputPath('elm-spike.png') });
});

test('Elm rejects stale check/search replies and visibly reports malformed envelopes', async ({ page }) => {
  await page.goto('/elm-spike.html'); await ready(page);
  await page.evaluate(() => {
    window.spikeRequests = [];
    TeslElmSpike.ports.request.subscribe(message => window.spikeRequests.push(message));
  });
  await page.locator('#spike-source').fill('module ???');
  await expect(page.locator('#spike-diagnostics')).not.toBeEmpty();
  await page.locator('#spike-source').fill('module Valid exposing [answer]\nimport Tesl.Prelude exposing [Int]\nfn answer() -> Int = 42\n');
  await expect(page.locator('#spike-check-status')).toHaveText('No diagnostics.');
  await page.locator('#spike-query').fill('String.length');
  await expect(page.getByRole('heading', { name: 'String.length', exact: true })).toBeVisible();
  await page.locator('#spike-query').fill('Set.toList');
  await expect(page.getByRole('heading', { name: 'Set.toList', exact: true })).toBeVisible();
  await page.evaluate(() => {
    const check = spikeRequests.find(r => r.operation === 'check');
    const search = spikeRequests.find(r => r.operation === 'search');
    TeslElmSpike.ports.response.send({ ...check, payload: { diagnostics: [{ code: 'STALE', start: { line: 0 }, message: 'Old buffer' }] } });
    TeslElmSpike.ports.response.send({ ...search, payload: { results: [{ name: 'STALE', signature: '', doc: '' }], error: null } });
  });
  await expect(page.locator('#spike-diagnostics')).toBeEmpty();
  await expect(page.getByRole('heading', { name: 'Set.toList', exact: true })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'STALE', exact: true })).toHaveCount(0);
  const source = await page.locator('#spike-source').inputValue();
  await page.evaluate(() => TeslElmSpike.ports.response.send({ version: 99 }));
  await expect(page.locator('#spike-error')).toContainText('Could not decode');
  expect(await page.locator('#spike-source').inputValue()).toBe(source);
  await page.getByRole('button', { name: 'Check', exact: true }).click();
  await expect(page.locator('#spike-error')).toBeEmpty();
  await expect(page.locator('#spike-check-status')).toHaveText('No diagnostics.');
});
