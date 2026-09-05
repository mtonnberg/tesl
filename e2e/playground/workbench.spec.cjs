const { test, expect } = require('@playwright/test');
const toolClick = async (page, id) => { if (!await page.locator(id).isVisible()) await page.locator('#tools > summary').click(); await page.locator(id).click(); };
const valid = 'module Valid exposing [answer]\nimport Tesl.Prelude exposing [Int]\nfn answer() -> Int = 42\n';
const ready = async page => { await page.goto('/'); await page.locator('#examples').selectOption('1'); await expect(page.locator('#diags')).toContainText('V001'); };

test('incremental type search keeps exact and provisional matches distinct', async ({ page }) => {
  await ready(page);
  await page.locator('#search-open').click();
  for (const query of ['Float', 'Float ->', 'Float -> F', 'Float -> Float']) {
    await page.locator('#search-query').fill(query);
    await expect(page.locator('.search-card').first()).toBeVisible();
    await expect(page.locator('#search-status')).toContainText(query === 'Float' ? 'Matches by name or description' : query === 'Float -> Float' ? 'Exact type shapes' : 'Completions for an unfinished type');
  }
  await page.locator('#search-query').fill('Float -> ->');
  await expect(page.locator('#search-status')).toContainText('Expected a type');
  await expect(page.locator('.search-card')).toHaveCount(0);
});

test('production Elm rejects stale replies and recovers from malformed envelopes', async ({ page }) => {
  await ready(page);
  await page.evaluate(() => { window.requests = []; TeslPlayground.ports.request.subscribe(r => requests.push(r)); });
  await page.locator('#src').fill('module ???');
  await expect(page.locator('#diags')).not.toBeEmpty();
  await page.locator('#src').fill(valid);
  await expect(page.locator('#status')).toContainText('All checks passed');
  await page.locator('#search-open').click();
  await page.locator('#search-query').fill('String.length');
  await expect(page.getByRole('heading', { name: 'String.length', exact: true })).toBeVisible();
  await page.locator('#search-query').fill('Set.toList');
  await expect(page.getByRole('heading', { name: 'Set.toList', exact: true })).toBeVisible();
  await page.evaluate(() => {
    for (const operation of ['check', 'search']) {
      const old = requests.find(r => r.operation === operation);
      TeslPlayground.ports.response.send({ ...old, payload: {}, error: 'STALE' });
    }
  });
  await expect(page.locator('#diags')).toBeEmpty();
  await expect(page.locator('#search-status')).not.toContainText('STALE');
  await page.keyboard.press('Escape');
  await page.evaluate(() => TeslPlayground.ports.response.send({ version: 99 }));
  await expect(page.locator('#bridge-error')).toContainText('Could not decode');
  await expect(page.locator('#src')).toHaveValue(valid);
  await page.locator('#check').click();
  await expect(page.locator('#bridge-error')).toBeEmpty();
  await expect(page.locator('#status')).toContainText('All checks passed');
});

test('compiler failure, explanation, navigation and highlighted sharing survive Elm migration', async ({ page, context }) => {
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  let fail = true;
  await page.route('**/tesl_playground.js*', async route => { if (fail) { fail = false; await route.abort(); } else await route.continue(); });
  await page.goto('/');
  await expect(page.locator('#compiler-retry')).toBeVisible();
  await page.locator('#compiler-retry').click();
  await page.locator('#examples').selectOption('1');
  const source = await page.locator('#src').inputValue();
  await expect(page.locator('#diags')).toContainText('V001');
  await page.getByText('Explain V001', { exact: true }).click();
  await expect(page.locator('.explain pre')).not.toContainText('Loading');
  await page.locator('.diag-jump').first().click();
  const selection = await page.locator('#src').evaluate(el => [el.selectionStart, el.selectionEnd]);
  expect(selection[1]).toBeGreaterThan(selection[0]);
  await page.locator('#src').press('Control+Shift+h');
  await expect(page.locator('#gutter .selected').first()).toBeVisible();
  await page.locator('#share').click();
  await expect(page.locator('#share')).toHaveText('Copied!');
  const url = await page.evaluate(() => navigator.clipboard.readText());
  expect(new URL(url).hash).toMatch(/\.L\d+-\d+\.H\d+-\d+$/);
  await page.goto(url); await page.reload();
  await expect(page.locator('#src')).toHaveValue(source);
  await expect(page.locator('#gutter .selected').first()).toBeVisible();
  await expect(page.locator('#landing')).not.toBeVisible();
});

test('Monaco is lazy, projects real squiggles, edits with undo, shares selection and switches back', async ({ page, context }) => {
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  const requests = [], errors = [];
  page.on('request', r => requests.push(r.url())); page.on('pageerror', e => errors.push(e.message));
  await ready(page);
  expect(requests.some(url => /monaco\.(js|css)/.test(url))).toBe(false);
  const source = await page.locator('#src').inputValue();
  await toolClick(page, '#editor-mode');
  await expect(page.locator('#editor-mode')).toHaveText('Use simple editor', { timeout: 25000 });
  await expect(page.locator('.monaco-editor')).toBeVisible();
  await expect(page.locator('.squiggly-error').first()).toBeVisible();
  await page.evaluate(() => {
    const { editor, model } = document.querySelector('tesl-editor').ide;
    const end = model.getPositionAt(model.getValueLength());
    editor.setPosition(end); editor.trigger('test', 'type', { text: '\n# IDE edit' });
  });
  await expect(page.locator('#src')).toHaveValue(source + '\n# IDE edit');
  await page.evaluate(() => document.querySelector('tesl-editor').ide.editor.trigger('test', 'undo', null));
  await expect(page.locator('#src')).toHaveValue(source);
  await page.evaluate(() => document.querySelector('tesl-editor').ide.select(0, 20));
  await page.locator('#share').click();
  await expect(page.locator('#share')).toHaveText('Copied!');
  expect(new URL(await page.evaluate(() => navigator.clipboard.readText())).hash).toContain('.L1-1');
  await page.screenshot({ path: test.info().outputPath('workbench-monaco.png') });
  await toolClick(page, '#editor-mode');
  await expect(page.locator('#src')).toBeVisible();
  await expect(page.locator('#src')).toHaveValue(source);
  expect(errors).toEqual([]);
});

test('Monaco offers actual compiler fixes and builtin completions, with recoverable load failure', async ({ page }) => {
  let fail = true;
  await page.route('**/monaco.js*', async route => { if (fail) { fail = false; await route.abort(); } else await route.continue(); });
  await ready(page);
  await page.locator('#examples').selectOption('2');
  await expect(page.locator('#diags')).toContainText('Import String.length');
  await toolClick(page, '#editor-mode');
  await expect(page.locator('#bridge-error')).toContainText('Could not load');
  await expect(page.locator('#src')).toBeVisible();
  await toolClick(page, '#editor-mode');
  await expect(page.locator('.monaco-editor')).toBeVisible();
  await page.evaluate(() => {
    const { editor } = document.querySelector('tesl-editor').ide;
    editor.setPosition({ lineNumber: 8, column: 5 });
    editor.trigger('test', 'editor.action.quickFix', {});
  });
  await expect(page.getByRole('option', { name: /Import String.length from Tesl.String/ })).toBeVisible();
  await page.mouse.move(1, 1); // Monaco dismisses its initial pointer shield on movement.
  await page.getByRole('option', { name: /Import String.length from Tesl.String/ }).click();
  await expect(page.locator('#status')).toContainText('All checks passed');
  await page.locator('#search-open').click();
  await page.locator('#search-query').fill('Float -> F');
  await expect(page.locator('.search-card').first()).toBeVisible();
  await page.keyboard.press('Escape');
  await page.evaluate(() => {
    const { editor, model } = document.querySelector('tesl-editor').ide;
    editor.setPosition(model.getPositionAt(model.getValueLength()));
    editor.trigger('test', 'type', { text: '\n# String.len' });
    editor.trigger('test', 'editor.action.triggerSuggest', {});
  });
  await expect(page.locator('.suggest-widget')).toContainText('String.length');
});

test('welcoming start leads through a useful fix to building and sharing, with content-free milestones', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('#status')).toHaveText('All checks passed');
  await expect(page.locator('#welcome-title')).toHaveText('Keep building as your codebase grows');
  await expect(page.locator('#build-tesl')).toHaveAttribute('href', 'start.html');
  await page.screenshot({ path: test.info().outputPath('workbench-welcome-desktop.png') });
  await page.locator('#landing-next').click();
  await expect(page.locator('#landing')).not.toBeVisible();
  await expect(page.locator('#diags')).toContainText('V001');
  const unchecked = await page.locator('#src').inputValue();
  await page.locator('#src').fill(unchecked.replace('  invoiceLabel raw customer', '  let invoice = check checkCustomer raw customer\n  invoiceLabel invoice customer'));
  await expect(page.locator('#status')).toHaveText('All checks passed');
  await expect(page.locator('.success-card')).toContainText('Your code passes the compiler’s checks');
  await page.evaluate(() => {
    window.milestones = [];
    window.addEventListener('tesl:adoption', e => milestones.push(e.detail));
    const link = document.getElementById('build-tesl');
    link.addEventListener('click', e => e.preventDefault()); link.click();
  });
  await expect.poll(() => page.evaluate(() => milestones)).toEqual([{ version: 1, event: 'install_intent' }]);
  const downloadPromise = page.waitForEvent('download');
  await toolClick(page, '#download');
  const download = await downloadPromise;
  expect(download.suggestedFilename()).toBe('CustomerInvoiceUnchecked.tesl');
  const fs = require('node:fs');
  expect(fs.readFileSync(await download.path(), 'utf8')).toBe(await page.locator('#src').inputValue());
  await expect.poll(() => page.evaluate(() => milestones)).toEqual([{ version: 1, event: 'install_intent' }, { version: 1, event: 'source_download' }]);
  await page.setViewportSize({ width: 375, height: 812 });
  await toolClick(page, '#welcome-toggle');
  await expect(page.locator('#welcome-title')).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(375);
  const checkBounds = await page.locator('#check').boundingBox();
  expect(checkBounds.x + checkBounds.width).toBeLessThanOrEqual(375);
  await page.screenshot({ path: test.info().outputPath('workbench-welcome-mobile.png') });
});

test('introduction preference survives reload and shared sources stay focused', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('#landing')).toBeVisible();
  await page.getByRole('button', { name: 'Hide getting started' }).click();
  await page.reload();
  await expect(page.locator('#landing')).toBeHidden();
  await toolClick(page, '#welcome-toggle');
  await expect(page.locator('#landing')).toBeVisible();
  await page.reload();
  await expect(page.locator('#landing')).toBeVisible();
  const before = await page.locator('#src').inputValue();
  await toolClick(page, '#welcome-toggle');
  await expect(page.locator('#src')).toHaveValue(before);
});

test('local explanations follow selection, gutter and Monaco without replacing source', async ({ page }) => {
  await page.goto('/');
  await page.locator('#examples').selectOption('0');
  await expect(page.locator('#status')).toHaveText('All checks passed');
  const source = await page.locator('#src').inputValue();
  await page.locator('#src').evaluate(el => { const i = el.value.indexOf('fact '); el.setSelectionRange(i, i + 4); });
  await page.locator('#learn-selection').click();
  await expect(page.locator('#learning')).toContainText('fact: give a rule a name');
  await expect(page.locator('#learning')).toContainText('declaration alone checks nothing');
  await page.locator('#close-learning').click();
  await page.locator('#gutter .gl').nth(8).click({ button: 'right' });
  await expect(page.locator('#learning')).toContainText('check: validate once');
  await toolClick(page, '#editor-mode');
  await expect(page.locator('#editor-mode')).toHaveText('Use simple editor', { timeout: 25000 });
  await page.evaluate(async () => {
    const { editor, model } = document.querySelector('tesl-editor').ide;
    editor.setPosition(model.getPositionAt(model.getValue().indexOf(':::') + 1));
    await editor.getAction('tesl-learn').run();
  });
  await expect(page.locator('#learning')).toContainText('::: means');
  await expect(page.locator('#src')).toHaveValue(source);
  await page.screenshot({ path: test.info().outputPath('workbench-explain.png') });
  await page.locator('#examples').selectOption('2');
  await expect(page.locator('#learning')).toHaveCount(0);
});

test('Go preview contains named real files and keyboard tabs include all outputs', async ({ page }) => {
  await page.goto('/');
  await page.locator('#examples').selectOption('4');
  await expect(page.locator('#status')).toHaveText('All checks passed');
  await expect(page.locator('#runnote')).toContainText('tesl run HelloServer.tesl');
  await page.getByText('See generated code', { exact: true }).click();
  await page.getByRole('tab', { name: 'Go project' }).click();
  await expect(page.locator('#go-file')).toHaveValue('internal/teslmodhelloserver/module.go');
  await expect(page.locator('#panel-go pre')).toContainText('package teslmodhelloserver');
  await page.locator('#go-file').selectOption('cmd/app/main.go');
  await expect(page.locator('#panel-go pre')).toContainText('func main()');
  await page.locator('#tab-go').press('ArrowLeft');
  await expect(page.locator('#tab-elm')).toHaveAttribute('aria-selected', 'true');
  await page.locator('#tab-elm').press('ArrowRight');
  await expect(page.locator('#tab-go')).toHaveAttribute('aria-selected', 'true');
  await page.locator('#examples').selectOption('1');
  await expect(page.locator('#diags')).toContainText('V001');
  await expect(page.locator('#artifacts')).toBeEmpty();
});

test('run guide is readable without JavaScript and agent prompt has a clipboard fallback', async ({ page, context }) => {
  await page.goto('/start.html');
  await expect(page.getByRole('heading', { name: 'Make your first request.' })).toBeVisible();
  const downloaded = await page.request.get('/examples/hello-server.tesl');
  expect(await downloaded.text()).toContain('App { database: Local, api: HelloServer, port: 8086 }');
  await page.locator('#agent-setup summary').click();
  await page.evaluate(() => Object.defineProperty(navigator, 'clipboard', { value: { writeText: async () => { throw Error('denied'); } } }));
  await page.locator('#copy-install').click();
  await expect(page.locator('#copy-status')).toContainText('Select and copy');
  const selection = await page.locator('#install-prompt').evaluate(el => el.value.slice(el.selectionStart, el.selectionEnd));
  expect(selection).toContain('only report steps you verified');
  const agents = await page.request.get('/agents.md');
  expect(agents.ok()).toBe(true);
  expect(await agents.text()).toContain('not a complete authorization system');
  const staticContext = await context.browser().newContext({ javaScriptEnabled: false });
  const staticPage = await staticContext.newPage();
  await staticPage.goto(new URL('/start.html', page.url()).href);
  await expect(staticPage.getByRole('heading', { name: 'Make your first request.' })).toBeVisible();
  await expect(staticPage.getByText('curl http://localhost:8086/hello', { exact: true })).toBeVisible();
  await staticContext.close();
});

test('server is the default and secondary tools do not crowd the toolbar', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('#examples')).toHaveValue('4');
  await expect(page.locator('#src')).toHaveValue(/module HelloServer/);
  await expect(page.locator('#share')).toBeVisible();
  await expect(page.locator('#search-open')).toBeVisible();
  await expect(page.locator('#run-locally')).toBeVisible();
  await expect(page.locator('#download')).toBeHidden();
  await expect(page.locator('#editor-mode')).toBeHidden();
  await page.locator('#tools > summary').click();
  await expect(page.locator('#download')).toBeVisible();
  await page.locator('#tools > summary').press('Escape');
  await expect(page.locator('#download')).toBeHidden();
  await expect(page.locator('#tools > summary')).toBeFocused();
  await page.screenshot({ path: test.info().outputPath('journey-welcome.png') });
});

test('guided activities earn compiler-backed progress and restore the starting buffer', async ({ page }) => {
  await page.goto('/');
  const original = valid + '# My unfinished project\n';
  await page.locator('#src').fill(original);
  await expect(page.locator('#status')).toHaveText('All checks passed');
  await toolClick(page, '#journey-menu');
  await expect(page.locator('#src')).toHaveValue(/module HelloServer/);
  await expect(page.locator('#status')).toHaveText('All checks passed');
  await expect(page.locator('#journey-progress')).toContainText('Apply the suggested edit');
  await expect(page.locator('#status')).toHaveText('All checks passed');
  await expect(page.locator('#journey-progress')).toContainText('Apply the suggested edit');
  const server = await page.locator('#src').inputValue();
  await page.locator('#src').fill(server.replace('Hello from Tesl!', 'Hello from my first API!'));
  await expect(page.locator('#journey-progress')).toContainText('Step completed');
  await page.locator('#journey-next').click();
  // The text and source change together, and revisiting restores the edited buffer.
  await expect(page.locator('#src')).toHaveValue(/module MissingImport/);
  await page.getByRole('button', {name: 'Your first endpoint — checked', exact: true}).click();
  await expect(page.locator('#src')).toHaveValue(/Hello from my first API!/);
  await page.locator('#journey-next').click();
  await page.getByRole('button', { name: 'Apply fix: Import String.length from Tesl.String', exact: true }).click();
  await expect(page.locator('#journey-progress')).toContainText('Step completed');
  await page.locator('#journey-next').click();
  await expect(page.locator('#diags')).toContainText('V001');
  const unchecked = await page.locator('#src').inputValue();
  await page.locator('#src').fill(unchecked.replace('  invoiceLabel raw customer', '  let invoice = check checkCustomer raw customer\n  invoiceLabel invoice customer'));
  await expect(page.locator('#status')).toHaveText('All checks passed');
  await expect(page.locator('#journey-progress')).toContainText('Step completed');
  await page.locator('#journey-next').click();
  await expect.poll(() => page.evaluate(() => JSON.parse(localStorage.getItem('tesl-playground-stars-v1')).length)).toBe(3);
  await page.locator('#journey-chapter').selectOption('3');
  await expect(page.locator('#journey')).toContainText('won’t mark it complete from a download or a click');
  await page.locator('.journey-options > summary').click();
  await page.locator('#journey-restore').click();
  await expect(page.locator('#journey')).toHaveCount(0);
  await expect(page.locator('#src')).toHaveValue(original);
});

test('guide is optional on shared sources, remains usable on mobile and keeps edits on exit', async ({ page }) => {
  await page.goto('/');
  await page.locator('#journey-start').click();
  await page.setViewportSize({ width: 375, height: 812 });
  await page.locator('#journey').scrollIntoViewIfNeeded();
  await expect(page.getByRole('navigation', { name: /Step \d+ of \d+/ })).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(375);
  await page.screenshot({ path: test.info().outputPath('journey-mobile.png') });
  await page.locator('#src').fill(valid);
  await page.locator('#journey-close').click();
  await expect(page.locator('#src')).toHaveValue(valid);
  await page.locator('#share').click();
  await expect(page).toHaveURL(/#(?:s|z)/);
  await page.reload();
  await expect(page.locator('#src')).toHaveValue(valid);
  await expect(page.locator('#landing')).toBeHidden();
  await expect(page.locator('#journey')).toHaveCount(0);
});

test('discreet introduction controls, installation, reasons and community help are discoverable', async ({ page, context }) => {
  await page.goto('/');
  await expect(page.locator('#run-locally')).toHaveText('Install Tesl');
  await expect(page.locator('#run-locally')).toHaveAttribute('href', 'start.html#install');
  const alignment = await page.locator('.tagline').evaluate(el => {
    const range = document.createRange(); range.selectNodeContents(el.firstChild);
    const badge = el.querySelector('.privacy-badge');
    return { text: range.getBoundingClientRect().left, badge: badge.getBoundingClientRect().left,
      textSize: parseFloat(getComputedStyle(el).fontSize), badgeSize: parseFloat(getComputedStyle(badge).fontSize) };
  });
  expect(Math.abs(alignment.text - alignment.badge)).toBeLessThan(1);
  expect(alignment.badgeSize).toBeLessThan(alignment.textSize);
  await expect(page.locator('.community-help a')).toHaveAttribute('href', 'https://github.com/mtonnberg/tesl/discussions');
  const source = await page.locator('#src').inputValue();
  const whyPopup = page.waitForEvent('popup');
  await page.locator('.why-link a').click();
  const why = await whyPopup;
  await expect(why.getByRole('heading', { name: 'Focus review on the rules that matter' })).toBeVisible();
  await expect(why.getByRole('heading', { name: 'Deploy Go with familiar hosting tools' })).toBeVisible();
  await why.close();
  await expect(page.locator('#src')).toHaveValue(source);
  await page.locator('#welcome-close').click();
  await expect(page.locator('#landing')).toBeHidden();
  await expect(page.locator('#src')).toHaveValue(source);
  await page.reload();
  await expect(page.locator('#landing')).toBeHidden();
  const staticContext = await context.browser().newContext({ javaScriptEnabled: false });
  const staticPage = await staticContext.newPage();
  await staticPage.goto(new URL('/why.html', page.url()).href);
  await expect(staticPage.getByRole('heading', { name: 'Where it fits today' })).toBeVisible();
  await staticContext.close();
});

test('random lessons load only on demand, open checked source and preserve the original tab', async ({ page }) => {
  const requests = [];
  page.on('request', r => requests.push(r.url()));
  await page.goto('/');
  await expect(page.locator('#status')).toHaveText('All checks passed');
  const original = await page.locator('#src').inputValue();
  expect(requests.some(url => url.includes('random.html'))).toBe(false);
  const popup = page.waitForEvent('popup');
  await page.locator('#random-lesson').click();
  const lesson = await popup;
  await expect(lesson.locator('#lesson-title')).not.toHaveText('Pick a lesson');
  const first = await lesson.locator('#lesson-title').textContent();
  await lesson.locator('#another-lesson').click();
  await expect(lesson.locator('#lesson-title')).not.toHaveText(first);
  await lesson.locator('#open-random-lesson').click();
  await expect(lesson).toHaveURL(/index.html#(?:s|z)/);
  await expect(lesson.locator('#status')).not.toContainText('Loading');
  await expect(lesson.locator('#status')).not.toContainText('Checking');
  await expect(lesson.locator('#diags .error')).toHaveCount(0);
  await expect(lesson.locator('#src')).toHaveValue(/module Lesson/);
  await expect(page.locator('#src')).toHaveValue(original);
  await lesson.close();
});


test('guide resumes the same step and original buffer after Keep editing', async ({ page }) => {
  await page.goto('/');
  const original = await page.locator('#src').inputValue();
  await page.locator('#journey-start').click();
  await expect(page.locator('#journey-next')).toHaveText('Next step →');
  await page.locator('#journey-chapter').selectOption('2');
  await expect(page.locator('#diags')).toContainText('V001');
  const exercise = await page.locator('#src').inputValue();
  await page.locator('#journey-close').click();
  await expect(page.locator('#journey-resume')).toHaveText('Resume guide');
  await page.locator('#journey-resume').click();
  await expect(page.locator('#journey-title')).toHaveText('Keep invoices with the right customer');
  await expect(page.locator('#src')).toHaveValue(exercise);
  await page.locator('.journey-options > summary').click();
  await page.locator('#journey-restore').click();
  await expect(page.locator('#src')).toHaveValue(original);
});

test('capabilities, money and dimensions earn persistent stars only for intact repairs', async ({ page }) => {
  await page.goto('/?guide=capabilities');
  await expect(page.locator('#diags')).toContainText('V001');
  const capability = await page.locator('#src').inputValue();
  await expect(page.locator('#src')).toHaveValue(/saveNote id body/);
  // Removing the privileged caller is clean code, but does not solve the exercise.
  await page.locator('#src').fill(capability.split('# Try changing')[0].replace(', publishNote]', ']'));
  await expect(page.locator('#diags .error')).toHaveCount(0);
  await expect(page.locator('#journey-progress')).toContainText('Apply the suggested edit');
  await page.locator('#src').fill(capability.replace('requires [dbRead Note]', 'requires [dbWrite Note]'));
  await expect(page.locator('#journey-progress')).toContainText('Step completed');
  await page.locator('#journey-next').click();
  await expect(page.locator('#journey-title')).toHaveText('Keep currencies apart');
  await expect(page.locator('#diags')).toContainText('V001');
  const money = await page.locator('#src').inputValue();
  await page.locator('#src').fill(money.replace('Money.add price shipping', 'let checked = check Money.requireSameCurrency price shipping\n  Money.add price checked'));
  await expect(page.locator('#journey-progress')).toContainText('Step completed');
  await page.locator('#journey-next').click();
  await expect(page.locator('#diags')).toContainText('T001');
  const units = await page.locator('#src').inputValue();
  await page.locator('#src').fill(units.replace('speed + elapsed', 'speed * elapsed'));
  await expect(page.locator('#journey-progress')).toContainText('Step completed');
  await expect.poll(() => page.evaluate(() => JSON.parse(localStorage.getItem('tesl-playground-stars-v1')).sort())).toEqual([4,5,6]);
  await page.goto('/?guide=dimensions');
  await expect(page.locator('#journey-progress')).toContainText('Completed earlier');
  await expect(page.locator('#diags')).toContainText('T001'); // History is separate from current result.
  await page.locator('.journey-options > summary').click();
  await page.locator('#journey-reset').click();
  await expect(page.locator('#journey-progress')).toContainText('Apply the suggested edit');
  await page.reload();
  await expect(page.locator('#journey-progress')).toContainText('Apply the suggested edit');
});

test('diagram explanations work with keyboard and touch-sized layouts', async ({ page }) => {
  await page.goto('/?guide=api');
  await page.emulateMedia({ colorScheme: 'dark' });
  const node = page.locator('.flow-detail').nth(1);
  await page.locator('#journey-close').click();
  await expect(page.locator('#journey-resume')).toHaveText('Resume guide');
  await page.locator('#journey-resume').click();
  await expect(node.locator('summary')).toHaveAttribute('title', /Why separate the handler/);
  await node.locator('summary').focus();
  await node.locator('summary').press('Enter');
  await expect(node.locator('p')).toBeVisible();
  await expect(node).toContainText('change the implementation while keeping the public contract');
  await node.locator('summary').press('Enter');
  await expect(node.locator('p')).toBeHidden();
  await page.setViewportSize({ width: 375, height: 812 });
  await node.locator('summary').click();
  await expect(node.locator('p')).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(375);
  await node.locator('summary').scrollIntoViewIfNeeded();
  await page.screenshot({ path: test.info().outputPath('chapter-explanation-mobile.png') });
});

test('Why Tesl links compiler features to live exercises and runtime features to guides', async ({ page }) => {
  await page.goto('/why.html');
  await expect(page.locator('.why-features > details')).toHaveCount(12);
  const links = await page.locator('.feature-action a').evaluateAll(nodes => nodes.map(a => a.getAttribute('href')));
  expect(links).toHaveLength(9);
  const expected = { customer: 'CustomerInvoiceUnchecked', capabilities: 'CapabilityChain', api: 'HelloServer', money: 'MoneyCheck', dimensions: 'UnitsCheck', runtime: 'HelloServer', compiler: 'MissingImport', tests: 'RegularTests', sql: 'SqlFields' };
  await page.locator('.why-features summary').nth(1).click();
  await expect(page.locator('.why-features details').nth(1).getByRole('link', { name: 'See it in action →' })).toBeVisible();
  await page.screenshot({ path: test.info().outputPath('why-chapters.png') });
  for (const link of links) {
    await page.goto('/' + link);
    await expect(page.locator('#journey')).toBeVisible();
    const key = new URL(page.url()).searchParams.get('guide');
    const selectedChapter = await page.locator('#journey-chapter').inputValue();
    expect(selectedChapter).toBe(({customer:'2',capabilities:'2',api:'0',money:'5',dimensions:'5',runtime:'3',compiler:'0',tests:'7',sql:'12'})[key]);
    await expect(page.locator('#examples option:checked')).not.toHaveText('Shared source');
    await expect(page.locator('#src')).toHaveValue(new RegExp('^module ' + expected[key]));
  }
});

test('guide links respect shared source and malformed or unavailable progress storage', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('tesl-playground-stars-v1', '{bad json'));
  await page.goto('/?guide=customer');
  await expect(page.locator('#journey-progress')).toContainText('Apply the suggested edit');
  await page.locator('#src').fill(valid);
  await page.locator('#share').click();
  await expect(page).toHaveURL(/#/);
  const shared = page.url();
  await page.goto(shared);
  await page.reload();
  await expect(page.locator('#src')).toHaveValue(valid);
  await expect(page.locator('#journey')).toHaveCount(0);
  await page.addInitScript(() => { Storage.prototype.setItem = () => { throw new Error('blocked'); }; Storage.prototype.getItem = () => { throw new Error('blocked'); }; });
  await page.goto('/?guide=dimensions');
  await expect(page.locator('#src')).toHaveValue(/module UnitsCheck/);
  const source = await page.locator('#src').inputValue();
  await page.locator('#src').fill(source.replace('speed + elapsed', 'speed * elapsed'));
  await expect(page.locator('#journey-progress')).toContainText('Step completed');
});


test('the original six exercises have applicable edits and preserve stars across immediate navigation', async ({ page }) => {
  await page.goto('/');
  const original = await page.locator('#src').inputValue();
  await page.locator('#journey-start').click();
  const steps = [0,1,2,4,5,6];
  for (const step of steps) {
    await expect(page.locator('#repair-' + step)).toBeVisible();
    await expect(page.locator('#repair-' + step + ' pre')).toBeVisible();
    await expect(page.locator('#journey-apply')).toBeEnabled();
    await page.locator('#journey-apply').click();
    await page.locator('#journey-next').click();
    await expect.poll(() => page.evaluate(() => JSON.parse(localStorage.getItem('tesl-playground-stars-v1') || '[]'))).toContain(step);
  }
  await expect(page.locator('#journey-title')).toHaveText('Query declared fields');
  await page.locator('#journey-chapter').selectOption('3');
  await expect(page.locator('#journey-title')).toHaveText('Take it with you');
  await expect(page.locator('#journey-progress')).toHaveText('6 of 14 steps completed');
  await page.locator('.journey-options > summary').click();
  await expect(page.getByRole('link', {name: 'Suggest one in Discussions →'})).toHaveAttribute('href', 'https://github.com/mtonnberg/tesl/discussions');
  await page.locator('#journey-restore').click();
  await expect(page.locator('#src')).toHaveValue(original);
  await page.reload();
  await expect.poll(() => page.evaluate(() => JSON.parse(localStorage.getItem('tesl-playground-stars-v1')).length)).toBe(6);
});

test('a debounced edit earns its star before the guide changes source and import cleanup is accepted', async ({ page }) => {
  await page.goto('/?guide=api');
  await expect(page.locator('#status')).toHaveText('All checks passed');
  const greeting = await page.locator('#src').inputValue();
  await page.locator('#src').fill(greeting.replace('Hello from Tesl!', 'Hello with whitespace!').replace('handler get hello()', 'handler  get hello()'));
  await page.locator('#journey-next').click();
  await expect(page.locator('#src')).toHaveValue(/module MissingImport/);
  await expect.poll(() => page.evaluate(() => JSON.parse(localStorage.getItem('tesl-playground-stars-v1') || '[]'))).toContain(0);
  await page.goto('/?guide=capabilities');
  await expect(page.locator('#diags')).toContainText('V001');
  const source = await page.locator('#src').inputValue();
  await page.locator('#src').fill(source.replace('requires [dbRead Note]', 'requires [dbWrite Note]').replace('exposing [dbRead, dbWrite]', 'exposing [dbWrite]'));
  await page.locator('#journey-next').click();
  await expect(page.locator('#journey-title')).toHaveText('Keep currencies apart');
  await expect.poll(() => page.evaluate(() => JSON.parse(localStorage.getItem('tesl-playground-stars-v1') || '[]'))).toContain(4);
});

test('skipped steps remain incomplete and chapter navigation restores per-step edits', async ({ page }) => {
  await page.goto('/?guide=customer');
  await expect(page.locator('#diags')).toContainText('V001');
  const source = await page.locator('#src').inputValue();
  await page.locator('#src').fill(source + '# My work in progress\n');
  await page.locator('#journey-next').click();
  await expect(page.locator('#src')).toHaveValue(/module CapabilityChain/);
  await expect(page.locator('#journey-progress')).toContainText('Apply the suggested edit');
  await page.getByRole('button', { name: 'Keep invoices with the right customer', exact: true }).click();
  await expect(page.locator('#src')).toHaveValue(source + '# My work in progress\n');
  await expect(page.locator('#journey-progress')).toContainText('Apply the suggested edit');
  await page.screenshot({ path: test.info().outputPath('guide-repair-desktop.png') });
  await page.setViewportSize({width:375,height:812});
  await page.locator('.journey-repair').scrollIntoViewIfNeeded();
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(375);
  await page.screenshot({ path: test.info().outputPath('guide-repair-mobile.png') });
});


test('manual repairs may name their checked value and applying a repair preserves surrounding edits', async ({page}) => {
  await page.goto('/?guide=money');
  await expect(page.locator('#diags')).toContainText('V001');
  const money = await page.locator('#src').inputValue();
  await page.locator('#src').fill(money.replace('Money.add price shipping', 'let verified = check Money.requireSameCurrency price shipping\n  Money.add price verified'));
  await expect(page.locator('#journey-progress')).toHaveText('★ Step completed');
  await page.goto('/?guide=customer');
  await expect(page.locator('#diags')).toContainText('V001');
  const invoice = await page.locator('#src').inputValue();
  await page.locator('#src').fill(invoice.replace('  invoiceLabel raw customer', '  let validated = check checkCustomer raw customer\n  invoiceLabel validated customer'));
  await expect(page.locator('#journey-progress')).toHaveText('★ Step completed');
  await page.goto('/?guide=capabilities');
  await expect(page.locator('#diags')).toContainText('V001');
  const cap = await page.locator('#src').inputValue();
  await page.locator('#src').fill(cap + '# Keep my note\n');
  await page.locator('#journey-apply').click();
  await expect(page.locator('#journey-progress')).toHaveText('★ Step completed');
  await expect(page.locator('#src')).toHaveValue(cap.replace('  requires [dbRead Note]', '  requires [dbWrite Note]') + '# Keep my note\n');
});

test('an obsolete pending compiler fix cannot trap chapter navigation', async ({page}) => {
  await page.goto('/?guide=compiler');
  await expect(page.locator('#diags')).toContainText('T001');
  await page.evaluate(() => {
    const port = window.TeslPlayground.ports.response;
    const send = port.send;
    port.send = envelope => {
      if (envelope.operation === 'fix') window.delayedGuideFix = () => send(envelope);
      else send(envelope);
    };
  });
  await page.getByRole('button', {name:'Apply fix: Import String.length from Tesl.String',exact:true}).click();
  await expect.poll(() => page.evaluate(() => typeof window.delayedGuideFix)).toBe('function');
  const source = await page.locator('#src').inputValue();
  await page.locator('#src').fill(source + '# Newer edit before the fix arrives\n');
  await page.locator('#journey-next').click();
  await expect(page.locator('#journey-title')).toHaveText('Keep invoices with the right customer');
  const next = await page.locator('#src').inputValue();
  await page.evaluate(() => window.delayedGuideFix());
  await expect(page.locator('#src')).toHaveValue(next);
});

test('stars earned in different open tabs are retained together', async ({page, context}) => {
  await page.goto('/?guide=api');
  const money = await context.newPage();
  await money.goto('/?guide=money');
  await expect(money.locator('#diags')).toContainText('V001');
  await page.locator('#journey-apply').click();
  await expect(page.locator('#journey-progress')).toContainText('Step completed');
  await money.locator('#journey-apply').click();
  await expect(money.locator('#journey-progress')).toContainText('Step completed');
  await expect.poll(() => page.evaluate(() => JSON.parse(localStorage.getItem('tesl-playground-stars-v1') || '[]').sort())).toEqual([0,5]);
  await expect(page.locator('#journey-chapter option[value="5"]')).toHaveText(/★ 1\/2/);
  await expect(money.locator('#journey-chapter option[value="0"]')).toHaveText(/★ 1\/2/);
  await money.locator('.journey-options > summary').click();
  await money.locator('#journey-reset').click();
  await expect(page.locator('#journey-progress')).not.toContainText('Step completed');
  await expect.poll(() => page.evaluate(() => JSON.parse(localStorage.getItem('tesl-playground-stars-v1') || '[]'))).toEqual([]);
});

test('an edit checked just after Keep editing still earns its star', async ({page}) => {
  await page.goto('/?guide=api');
  await expect(page.locator('#status')).toHaveText('All checks passed');
  await page.evaluate(() => { document.querySelector('#journey-apply').click(); document.querySelector('#journey-close').click(); });
  await expect(page.locator('#status')).toHaveText('All checks passed');
  await page.locator('#journey-resume').click();
  await expect(page.locator('#journey-progress')).toContainText('Step completed');
});

test('a capability repair can keep read access as well as write access', async ({page}) => {
  await page.goto('/?guide=capabilities');
  await expect(page.locator('#diags')).toContainText('V001');
  const source = await page.locator('#src').inputValue();
  await page.locator('#src').fill(source.replace('requires [dbRead Note]', 'requires [dbRead Note, dbWrite Note]'));
  await expect(page.locator('#status')).toHaveText('All checks passed');
  await expect(page.locator('#journey-progress')).toContainText('Step completed');
});


test('the visible primary action earns a star before Next step is offered', async ({page}) => {
  await page.goto('/?guide=api');
  await expect(page.locator('#status')).toHaveText('All checks passed');
  await expect(page.getByRole('button', {name:'Apply edit',exact:true})).toBeVisible();
  await expect(page.locator('.journey-repair pre')).toBeVisible();
  await expect(page.locator('.journey-repair #journey-apply')).toHaveText('Apply edit');
  await expect(page.locator('.journey-legend')).toContainText('Stars mark completed edits');
  await expect(page.locator('#journey-next')).toHaveText('Next step →');
  await page.locator('#journey-apply').click();
  await expect(page.locator('#journey-progress')).toContainText('Step completed');
  await expect(page.locator('#journey-next')).toHaveText('Next step →');
  await page.locator('#journey-next').click();
  await expect(page.getByRole('button', {name:'Apply edit',exact:true})).toBeVisible();
  await page.locator('#journey-apply').click();
  await expect(page.locator('#journey-chapter option[value="0"]')).toHaveText(/★ 2\/2/);
  await page.screenshot({path: test.info().outputPath('first-chapter-two-stars.png')});
});

test('existing stars migrate and read-only storage still permits session progress', async ({page, context}) => {
  await page.addInitScript(() => localStorage.setItem('tesl-playground-stars-v1', '[0,2,5,6]'));
  await page.goto('/?guide=api');
  await expect(page.locator('#journey-progress')).toContainText('Completed earlier');
  await expect.poll(() => page.evaluate(() => localStorage.getItem('tesl-playground-star-v2:0'))).toBe('1');
  const isolated = await context.browser().newContext();
  const temporary = await isolated.newPage();
  await temporary.addInitScript(() => { Storage.prototype.setItem = () => { throw new Error('quota'); }; });
  await temporary.goto(new URL('/?guide=compiler', page.url()).href);
  await temporary.locator('#journey-apply').click();
  await expect(temporary.locator('#journey-progress')).toContainText('Step completed');
  await isolated.close();
});


test('testing chapter covers example, documentation, property, API and load tests with honest local execution guidance', async ({page}) => {
  await page.goto('/?guide=tests');
  const cases = [
    ['RegularTests', 'test "below zero becomes zero"', 'Example tests'],
    ['DocTests', '#> double 0\n#= 0', 'Documentation tests'],
    ['PropertyTests', 'property "idempotent"', 'Fuzz / property tests'],
    ['ApiTests', 'api-test "unknown route returns 404"', 'API tests'],
    ['LoadTests', 'assert p95 < 500ms', 'Load tests']
  ];
  for (const [module, added, title] of cases) {
    await expect(page.locator('#journey-title')).toHaveText(title);
    await expect(page.locator('#src')).toHaveValue(new RegExp('^module ' + module));
    await expect(page.locator('#status')).toHaveText('All checks passed');
    await expect(page.locator('.testing-run')).toContainText('does not run these tests');
    await expect(page.locator('.testing-run code')).toHaveText('tesl test ' + module + '.tesl');
    await expect(page.locator('#runnote')).toBeHidden();
    await expect(page.locator('#journey-progress')).not.toContainText('★');
    await page.locator('#journey-apply').click();
    await expect.poll(() => page.locator('#src').inputValue()).toContain(added);
    await expect(page.locator('#journey-progress')).toHaveText('★ Test added and compiler-checked · run it locally below');
    if (module === 'DocTests') await page.screenshot({path:test.info().outputPath('testing-chapter-doctests.png')});
    if (module === 'LoadTests') await page.screenshot({path:test.info().outputPath('testing-chapter-load.png')});
    await page.locator('#journey-next').click();
  }
  await expect(page.locator('#journey-title')).toHaveText('Take it with you');
  await expect(page.locator('#journey-chapter option[value="7"]')).toHaveText('Testing your code · ★ 5/5');
  await page.reload();
  await page.locator('#journey-resume').click();
  await expect(page.locator('#journey-chapter option[value="7"]')).toHaveText('Testing your code · ★ 5/5');
});

test('testing chapter deep links and mobile navigation resolve through the Elm catalog', async ({page}) => {
  for (const [key, title] of [['tests','Example tests'], ['doctests','Documentation tests'], ['fuzz','Fuzz / property tests'], ['api-tests','API tests'], ['load-tests','Load tests']]) {
    await page.goto('/?guide=' + key);
    await expect(page.locator('#journey-title')).toHaveText(title);
    await expect(page.locator('#journey-chapter')).toHaveValue('7');
  }
  await page.setViewportSize({width:375,height:812});
  await page.locator('#journey-title').scrollIntoViewIfNeeded();
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(375);
  await page.screenshot({path:test.info().outputPath('testing-chapter-mobile.png')});
});

test('saved stars distinguish prior completion from the current source', async ({page}) => {
  await page.goto('/?guide=doctests');
  await expect(page.locator('#status')).toHaveText('All checks passed');
  await page.locator('#journey-apply').click();
  await expect(page.locator('#journey-progress')).toContainText('Test added and compiler-checked');
  await page.goto('/?guide=doctests');
  await expect(page.locator('#status')).toHaveText('All checks passed');
  await expect(page.locator('#journey-progress')).toHaveText('★ Completed earlier; your star is saved.');
  await expect(page.locator('#journey-chapter option[value="7"]')).toHaveText('Testing your code · ★ 1/5');
  await expect(page.locator('#steps-heading')).toHaveText('Step 2 of 5');
  await page.locator('#journey-apply').click();
  await expect(page.locator('#journey-progress')).toContainText('Test added and compiler-checked');
  const source = await page.locator('#src').inputValue();
  await page.locator('#src').fill(source.replace('n * 2', 'n + 2'));
  await expect(page.locator('#status')).toHaveText('All checks passed');
  await expect(page.locator('#journey-progress')).toHaveText('★ Completed earlier; your star is saved.');
  await page.locator('#src').fill(source.replace('n * 2', 'unknown n'));
  await expect(page.locator('#diags')).toContainText('T001');
  await expect(page.locator('#journey-progress')).toHaveText('★ Completed earlier; your star is saved.');
});

test('customer edits are visible before applying and capability errors name the missing access', async ({page}) => {
  await page.goto('/?guide=workspace'); // Previously shared guide links still resolve.
  await expect(page.locator('#journey-title')).toHaveText('Keep invoices with the right customer');
  await expect(page.locator('#src')).toHaveValue(/module CustomerInvoiceUnchecked/);
  await expect(page.locator('.diagnostic-guide')).toHaveText('This value needs a check before it can be used here.');
  const preview = page.getByRole('region', {name:'Suggested edit'});
  await expect(preview.locator('pre')).toBeVisible();
  await expect(preview.locator('pre')).toContainText('checkCustomer raw customer');
  await expect(preview.getByRole('button', {name:'Apply edit',exact:true})).toBeVisible();
  await expect(page.locator('#journey-next')).toHaveText('Next step →');
  await page.screenshot({path:test.info().outputPath('customer-suggested-edit.png')});
  await page.locator('#journey-next').click();
  await expect(page.locator('.diagnostic-guide')).toHaveText('Missing capability: declare [dbWrite Note] in the requires clause.');
  await expect(page.locator('#journey-next')).toHaveText('Next chapter →');
  await page.locator('#journey-apply').click();
  await expect(page.locator('#status')).toHaveText('All checks passed');
  await page.goto('/?guide=customer');
  await page.locator('#journey-apply').click();
  await expect(page.locator('#status')).toHaveText('All checks passed');
  await expect(page.locator('#src')).toHaveValue(/check checkCustomer raw customer/);
});


test('SQL adventure checks queries, missing rows and evidence while preserving drafts and stars', async ({ page }) => {
  await page.goto('/?guide=sql');
  await expect(page.locator('#journey-chapter')).toHaveValue('12');
  const steps = [
    { id: 12, module: 'SqlFields', error: 'customerId', title: 'Query declared fields' },
    { id: 13, module: 'SqlResults', error: 'non-exhaustive case', title: 'Handle a missing row' },
    { id: 14, module: 'SqlEvidence', error: 'does not carry the required database evidence', title: 'Keep the requested row' }
  ];
  let repairedQuery;
  for (const step of steps) {
    await expect(page.locator('#journey-title')).toHaveText(step.title);
    await expect(page.locator('#src')).toHaveValue(new RegExp('^module ' + step.module));
    await expect(page.locator('#diags')).toContainText(step.error);
    await expect(page.locator('#repair-' + step.id + ' pre')).toBeVisible();
    await expect(page.locator('.testing-run')).toContainText('tesl test ' + step.module + '.tesl');
    await page.locator('#journey-apply').click();
    await expect(page.locator('#status')).toHaveText('All checks passed');
    await expect(page.locator('#journey-progress')).toHaveText('★ Query compiler-checked · run its tests locally below');
    if (step.id === 12) repairedQuery = await page.locator('#src').inputValue();
    await page.locator('#journey-next').click();
  }
  await expect(page.locator('#journey-title')).toHaveText('Example tests');
  await page.locator('#journey-chapter').selectOption('12');
  await expect(page.locator('#src')).toHaveValue(repairedQuery);
  await page.locator('#journey-close').click();
  await page.locator('#journey-resume').click();
  await expect(page.locator('#src')).toHaveValue(repairedQuery);
  await page.reload();
  await expect.poll(() => page.evaluate(() => JSON.parse(localStorage.getItem('tesl-playground-stars-v1')).sort((a,b) => a-b))).toEqual([12,13,14]);
  await page.goto('/?guide=sql-results');
  await expect(page.locator('#journey-title')).toHaveText('Handle a missing row');
  await page.goto('/?guide=sql-evidence');
  await expect(page.locator('.diagnostic-guide')).toHaveText('This row does not carry the required database evidence.');
  await page.setViewportSize({ width: 375, height: 812 });
  await page.locator('#journey-title').scrollIntoViewIfNeeded();
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(375);
  await page.screenshot({ path: test.info().outputPath('sql-adventure-mobile.png') });
});
