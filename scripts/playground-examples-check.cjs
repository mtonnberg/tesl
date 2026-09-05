/* Keep every picker example honest, including deliberate failures and Go files. */
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const { spawnSync } = require('node:child_process'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..'), dist = path.resolve(process.argv[2] || 'playground/dist');
const compiler = process.env.TESL_OCAML_COMPILER || path.join(root, 'compiler/_build/default/bin/main.exe');
const env = { ...process.env, TESL_REPO_ROOT: root };
require(path.join(dist, 'tesl_playground.js'));
const examples = JSON.parse(fs.readFileSync(path.join(root, 'playground/examples.json')));
const repairs = {
  'capability-chain.tesl': ['requires [dbRead Note]', 'requires [dbWrite Note]'],
  'money-check.tesl': ['Money.add price shipping', 'let checked = check Money.requireSameCurrency price shipping\n  Money.add price checked'],
  'units-check.tesl': ['speed + elapsed', 'speed * elapsed']
};
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'tesl-picker-check-'));
try {
  for (const example of examples) {
    const file = path.join(root, 'example/playground', example.file), source = fs.readFileSync(file, 'utf8');
    const native = spawnSync(compiler, ['--check-json', file], { env, encoding: 'utf8' });
    const diagnostics = JSON.parse(native.stdout).diagnostics;
    const browser = JSON.parse(global.teslCheck(source));
    const normalized = list => list.map(({ file, ...diagnostic }) => diagnostic);
    assert.deepEqual(normalized(browser.diagnostics), normalized(diagnostics), example.file);
    assert.deepEqual(diagnostics.filter(d => d.severity === 'error').map(d => d.code), example.errors, example.file);
    assert.equal(browser.go, browser.racket);
    if (example.file === 'customer-invoice.tesl') {
      const retargeted = JSON.parse(global.teslCheck(source.replace('  invoiceLabel invoice customer', '  invoiceLabel invoice "other-team"')));
      assert.ok(retargeted.diagnostics.some(d => d.code === 'V001'), 'Customer evidence must not transfer to a different customer');
      assert.deepEqual(retargeted.go_files, []);
    }
    const repair = repairs[example.file] || example.repair;
    if (repair) {
      const repaired = source.replace(...repair);
      const repairedPath = path.join(temporary, 'repaired', example.file);
      fs.mkdirSync(path.dirname(repairedPath), { recursive: true });
      fs.writeFileSync(repairedPath, repaired);
      const context = spawnSync(compiler, ['agent-context', repairedPath], { env, encoding: 'utf8' });
      assert.equal(context.status, 0, context.stdout + context.stderr);
      assert.equal(JSON.parse(context.stdout).ok, true);
      assert.equal(JSON.parse(global.teslCheck(repaired)).diagnostics.some(d => d.severity === 'error'), false);
    }
    if (example.errors.length) {
      assert.equal(browser.go, null); assert.deepEqual(browser.go_files, []);
    } else {
      assert.ok(browser.go_files.length > 0);
      assert.equal(browser.go_files.map(f => f.content).join('\n'), browser.go);
      const out = path.join(temporary, example.file);
      const namedSource = path.join(temporary, source.match(/^module\s+(\w+)/m)[1] + '.tesl');
      fs.writeFileSync(namedSource, source);
      const emitted = spawnSync(compiler, ['--backend', 'go', namedSource, '--out', out], { env, encoding: 'utf8' });
      assert.equal(emitted.status, 0, emitted.stderr);
      for (const artifact of browser.go_files) {
        assert.equal(artifact.content, fs.readFileSync(path.join(out, artifact.path), 'utf8'), `${example.file}: ${artifact.path}`);
      }
    }
    console.log(`PASS ${example.file}: diagnostics and ${browser.go_files.length} generated project files`);
  }
} finally { fs.rmSync(temporary, { recursive: true, force: true }); }
