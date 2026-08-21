"use strict";
// Plain-node unit tests for parseTeslTestOutput. Run: node test-output-parser.test.js
const assert = require("assert");
const { parseTeslTestOutput } = require("./test-output-parser");

let passed = 0;
function t(name, fn) { fn(); passed++; console.log("ok - " + name); }

const GO_FAILURES = [
  "TESL_GO_TESTS_STARTED",
  "--- FAIL: TestTesl2 (0.00s)",
  "    module_test.go:41: expected 5, got 4",
  "--- FAIL: TestTesl4 (0.00s)",
  "    module_test.go:57: boom",
  "FAIL",
  "FAIL\tteslapp/internal/teslmodapp\t0.003s",
].join("\n");

t("Go test: generated failures and messages are parsed", () => {
  const { failures, compileError, reportedFailureCount } = parseTeslTestOutput(GO_FAILURES, 1);
  assert.strictEqual(compileError, null);
  assert.strictEqual(reportedFailureCount, 2);
  assert.strictEqual(failures.size, 2);
  assert.ok(failures.has("TestTesl2"));
  assert.ok(failures.has("TestTesl4"));
  assert.strictEqual(failures.get("TestTesl2").message, "expected 5, got 4");
  assert.strictEqual(failures.get("TestTesl4").message, "boom");
  assert.ok(!/module_test\.go/.test(failures.get("TestTesl2").message), "generated location should be dropped");
});

t("Go test pass: exit 0 has no failures or compile error", () => {
  const out = "TESL_GO_TESTS_STARTED\nPASS\nok  \tteslapp/internal/teslmodapp\t0.003s\n";
  const { failures, compileError } = parseTeslTestOutput(out, 0);
  assert.strictEqual(failures.size, 0);
  assert.strictEqual(compileError, null);
});

t("empty output, exit 0 → clean", () => {
  const { failures, compileError } = parseTeslTestOutput("", 0);
  assert.strictEqual(failures.size, 0);
  assert.strictEqual(compileError, null);
});

t("compile error: non-zero exit with diagnostic sets compileError", () => {
  const out = "error[E000]: expected } but got Foo\n  --> /x/Bad.tesl:18:13\n";
  const { failures, compileError } = parseTeslTestOutput(out, 1);
  assert.strictEqual(failures.size, 0);
  assert.ok(compileError && /error\[E000\]: expected } but got Foo/.test(compileError), "compileError: " + compileError);
});

t("non-zero exit, no diagnostic → falls back to head of output", () => {
  const out = "something unexpected happened\nmore detail\n";
  const { compileError } = parseTeslTestOutput(out, 2);
  assert.ok(compileError && /something unexpected happened/.test(compileError));
});

t("genuine test failure (exit 1, blocks present) is not a compile error", () => {
  const { failures, compileError } = parseTeslTestOutput(GO_FAILURES, 1);
  assert.strictEqual(compileError, null);
  assert.ok(failures.size > 0);
});

console.log("\nAll " + passed + " parser tests passed.");
