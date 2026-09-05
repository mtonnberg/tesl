const { test, expect } = require('@playwright/test');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const ready = async page => {
  await page.waitForFunction(() => typeof window.teslCheck === 'function');
  await expect(page.locator('#status')).not.toContainText('loading');
};
const query = async (page, value) => {
  if (!await page.locator('#search-dialog').isVisible()) await page.getByRole('button', { name: 'Search builtins', exact: true }).click();
  await page.locator('#search-query').fill(value);
};

test('lazy search, keyboard navigation, checked example and unchanged editor', async ({ page }) => {
  const loaded = [];
  page.on('request', request => loaded.push(request.url()));
  await page.goto('/'); await ready(page);
  expect(loaded.some(url => url.includes('tesl_search.js'))).toBe(false);
  const source = await page.locator('#src').inputValue();
  await page.locator('#src').focus();
  await page.evaluate(() => document.getElementById('src').setSelectionRange(10, 35));
  await page.keyboard.press('Control+k');
  await page.locator('#search-query').fill('String -> Int');
  await expect(page.getByRole('heading', { name: 'String.length', exact: true })).toBeVisible();
  await page.locator('#search-query').press('ArrowDown');
  await expect(page.locator('.search-card').first()).toBeFocused();
  const card = page.locator('.search-card').filter({ has: page.getByRole('heading', { name: 'String.length', exact: true }) });
  await expect(card).toContainText('Proof requirements: not indexed');
  await expect(card).toContainText('import Tesl.String exposing [String.length]');
  const popupPromise = page.waitForEvent('popup');
  await card.getByRole('link', { name: /Validate a title/ }).click();
  const popup = await popupPromise; await ready(popup);
  expect(await popup.locator('#src').inputValue()).toBe(fs.readFileSync(path.join(root, 'example/adoption/validation-title.tesl'), 'utf8'));
  expect(await popup.evaluate(() => JSON.parse(teslCheck(document.getElementById('src').value)).diagnostics.filter(d => d.severity === 'error'))).toEqual([]);
  expect(await page.locator('#src').inputValue()).toBe(source);
  expect(await page.locator('#src').evaluate(el => [el.selectionStart, el.selectionEnd])).toEqual([10, 35]);
  await page.screenshot({ path: test.info().outputPath('search-desktop.png') });
  await popup.close();
  await page.keyboard.press('Escape');
  await expect(page.locator('#search-dialog')).not.toBeVisible();
});

test('explicit sharing preserves source, selection and highlight; typing stays local', async ({ page, context }) => {
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  const source = fs.readFileSync(path.join(root, 'example/adoption/validation-title.tesl'), 'utf8');
  const fragment = '#s' + Buffer.from(source).toString('base64url') + '.L2-3.H4';
  await page.goto('/?retained=yes' + fragment); await ready(page);
  await query(page, 'Dict k v -> List k');
  await expect(page.getByRole('heading', { name: 'Dict.keys', exact: true })).toBeVisible();
  expect(new URL(page.url()).search).toBe('?retained=yes');
  await page.getByRole('button', { name: 'Copy search link', exact: true }).click();
  await expect(page.locator('#search-status')).toContainText('Search link copied');
  const shared = new URL(await page.evaluate(() => navigator.clipboard.readText()));
  expect(shared.hash).toBe(fragment);
  expect(shared.searchParams.get('q')).toBe('Dict k v -> List k');
  expect(shared.searchParams.get('retained')).toBe('yes');
  await page.goto(shared.href); await ready(page);
  await expect(page.getByRole('heading', { name: 'Dict.keys', exact: true })).toBeVisible();
  expect(await page.locator('#src').inputValue()).toBe(source);
  await query(page, 'String.length');
  await expect(page.getByRole('heading', { name: 'String.length', exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Copy import', exact: true }).click();
  await expect(page.locator('#search-status')).toContainText('Import copied');
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe('import Tesl.String exposing [String.length]');
});

test('requirements, unsupported syntax, diagnostic lookup and empty results', async ({ page }) => {
  await page.goto('/'); await ready(page);
  await query(page, 'Email.snd');
  await expect(page.getByRole('heading', { name: 'Email.send', exact: true })).toBeVisible();
  await expect(page.locator('#search-results')).toContainText('emailCap');
  await query(page, 'List.map');
  await expect(page.getByRole('heading', { name: 'List.map', exact: true })).toBeVisible();
  await expect(page.locator('#search-results')).toContainText('metadata incomplete');
  await query(page, 'String -> Int requires [time]');
  await expect(page.locator('#search-status')).toContainText('not supported');
  await expect(page.locator('.search-card')).toHaveCount(0);
  await query(page, 'UnknownNominal -> Int');
  await expect(page.locator('#search-status')).toContainText('No results');
  await query(page, 'V001');
  await expect(page.getByRole('heading', { name: 'V001', exact: true })).toBeVisible();
  await expect(page.locator('#search-status')).toContainText('Diagnostic explanation');
});

test('delayed loading cannot replace a newer query; load failure is recoverable', async ({ page }) => {
  let fail = true;
  await page.route('**/tesl_search.js*', async route => {
    if (fail) { fail = false; await route.abort(); return; }
    await new Promise(resolve => setTimeout(resolve, 300));
    await route.continue();
  });
  await page.goto('/'); await ready(page);
  const before = await page.locator('#src').inputValue();
  await query(page, 'String.length');
  await expect(page.getByRole('button', { name: 'Retry search', exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Retry search', exact: true }).click();
  await page.locator('#search-query').fill('Set.toList');
  await expect(page.getByRole('heading', { name: 'Set.toList', exact: true })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'String.length', exact: true })).toHaveCount(0);
  expect(await page.locator('#src').inputValue()).toBe(before);
});

test('catalog mismatch is visible and retry preserves the editor', async ({ page }) => {
  await page.goto('/'); await ready(page);
  await page.evaluate(() => { window.correctCatalog = TESL_BUILD.catalog_id; TESL_BUILD.catalog_id = 'outdated'; });
  const before = await page.locator('#src').inputValue();
  await query(page, 'String.length');
  await expect(page.locator('#search-status')).toContainText('do not match');
  await page.evaluate(() => { TESL_BUILD.catalog_id = window.correctCatalog; });
  await page.getByRole('button', { name: 'Retry search', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'String.length', exact: true })).toBeVisible();
  expect(await page.locator('#src').inputValue()).toBe(before);
});

test('native undo, selection and simulated composition survive diagnostics', async ({ page }) => {
  await page.goto('/'); await ready(page);
  const editor = page.locator('#src'), original = await editor.inputValue();
  await editor.focus(); await editor.press('Control+End');
  await page.keyboard.insertText('\n# organic adoption');
  await page.waitForTimeout(450);
  await editor.press('Control+z');
  expect(await editor.inputValue()).toBe(original);
  await editor.evaluate(el => {
    el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    el.value += '\n# 日本語';
    el.setSelectionRange(el.value.length, el.value.length);
    el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertCompositionText', data: '日本語', isComposing: true }));
    el.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '日本語' }));
  });
  await page.waitForTimeout(450);
  expect(await editor.inputValue()).toBe(original + '\n# 日本語');
  expect(await editor.evaluate(el => el.selectionStart)).toBe((original + '\n# 日本語').length);
});

test('375px viewport and dark theme keep search readable and within the viewport', async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 812 });
  await page.goto('/'); await ready(page);
  await page.locator('input[name="theme"][value="dark"]').check();
  await query(page, 'String.length');
  await expect(page.getByRole('heading', { name: 'String.length', exact: true })).toBeVisible();
  const metrics = await page.locator('#search-dialog').evaluate(el => ({ left: el.getBoundingClientRect().left,
    right: el.getBoundingClientRect().right, width: el.clientWidth, scroll: el.scrollWidth, color: getComputedStyle(el).color }));
  expect(metrics.left).toBeGreaterThanOrEqual(0); expect(metrics.right).toBeLessThanOrEqual(375);
  expect(metrics.scroll).toBeLessThanOrEqual(metrics.width);
  expect(metrics.color).toBe('rgb(230, 232, 236)');
  await page.screenshot({ path: test.info().outputPath('search-mobile-dark.png') });
});

test('existing import fixes and generated TypeScript/Elm tabs still work', async ({ page }) => {
  await page.goto('/'); await ready(page);
  await page.locator('#examples').selectOption('2');
  await page.getByRole('button', { name: 'Apply fix: Import String.length from Tesl.String', exact: true }).click();
  expect(await page.locator('#src').inputValue()).toContain('import Tesl.String exposing [String.length]');
  expect(await page.evaluate(() => JSON.parse(teslCheck(document.getElementById('src').value)).diagnostics.filter(d => d.severity === 'error'))).toEqual([]);
  await page.locator('#src').fill(fs.readFileSync(path.join(root, 'example/learn/lesson03-records.tesl'), 'utf8'));
  await page.getByRole('button', { name: 'Check', exact: true }).click();
  await expect(page.locator('#tab-ts')).toBeVisible();
  await expect(page.locator('#panel-ts')).toContainText('Point');
  await page.locator('#tab-elm').click();
  await expect(page.locator('#panel-elm')).toBeVisible();
  await expect(page.locator('#panel-elm')).toContainText('Point');
  await expect(page.locator('#panel-ts')).not.toBeVisible();
});

test('record cold load, warm query latency and separate asset sizes', async ({ page, browserName, browser }) => {
  test.setTimeout(60000);
  const start = Date.now();
  await page.goto('/'); await ready(page);
  const checkerReady = Date.now() - start;
  const searchStart = Date.now();
  await query(page, 'String.length');
  await expect(page.getByRole('heading', { name: 'String.length', exact: true })).toBeVisible();
  const firstSearch = Date.now() - searchStart;
  const queries = fs.readFileSync(path.join(root, 'compiler/test/search-queries.tsv'), 'utf8')
    .split('\n').filter(line => line && !line.startsWith('#')).map(line => line.split('\t')[0]);
  const measure = () => page.evaluate(queries => {
    const elapsed = [];
    for (let i = 0; i < 200; ++i) {
      const start = performance.now(); teslSearch(queries[i % queries.length]); elapsed.push(performance.now() - start);
    }
    elapsed.sort((a, b) => a - b);
    return { p50: elapsed[100], p95: elapsed[190], max: elapsed[199] };
  }, queries);
  const warm = await measure();
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: 4 });
  const throttled = await measure();
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: 1 });
  const identity = await page.evaluate(() => window.TESL_BUILD);
  const report = { version: 1, browser: browserName + ' ' + browser.version(),
    conditions: 'Local loopback, fresh browser context, desktop CPU; 4x throttling is a simulation, not a mobile-device measurement.',
    checker_ready_ms: checkerReady, first_search_ui_ms: firstSearch, warm_query_ms: warm, four_times_cpu_throttled_ms: throttled,
    catalog_id: identity.catalog_id, assets: identity.assets };
  await test.info().attach('performance.json', { body: JSON.stringify(report, null, 2), contentType: 'application/json' });
  fs.writeFileSync(test.info().outputPath('performance.json'), JSON.stringify(report, null, 2) + '\n');
});
