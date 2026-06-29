"use strict";
// Plain-node unit tests for parseTeslTestOutput. Run: node test-output-parser.test.js
const assert = require("assert");
const { parseTeslTestOutput } = require("./test-output-parser");

let passed = 0;
function t(name, fn) { fn(); passed++; console.log("ok - " + name); }

// ── Format B: raw rackunit (what a stale/plain `raco test` prints) ──────────────
const RAW = [
  "raco test: (submod (file \"/x/Txr.rkt\") test)",
  "--------------------",
  "this one fails",
  "FAILURE",
  "name:       check-equal?",
  "location:",
  "  /x/Txr.rkt:33:2",
  "actual:     4",
  "expected:   5",
  "--------------------",
  "1/3 test failures",
].join("\n");

t("raw rackunit: one failure parsed with actual/expected", () => {
  const { failures, compileError } = parseTeslTestOutput(RAW, 1);
  assert.strictEqual(compileError, null, "should not be a compile error");
  assert.strictEqual(failures.size, 1);
  assert.ok(failures.has("this one fails"));
  const f = failures.get("this one fails");
  assert.strictEqual(f.actual, "4");
  assert.strictEqual(f.expected, "5");
  assert.ok(/expected 5, got 4/.test(f.message), "message: " + f.message);
});

t("raw rackunit: summary line is not mistaken for a test name", () => {
  const { failures } = parseTeslTestOutput(RAW, 1);
  assert.ok(!failures.has("1/3 test failures"));
});

t("raw rackunit: reportedFailureCount extracted from summary", () => {
  const { reportedFailureCount } = parseTeslTestOutput(RAW, 1);
  assert.strictEqual(reportedFailureCount, 1);
});

t("FAILURE: <message> variant is still recognized (not a missed failure)", () => {
  const out = [
    "--------------------",
    "weird one",
    "FAILURE: custom assertion message",
    "actual:     1",
    "expected:   2",
    "--------------------",
    "1/2 test failures",
  ].join("\n");
  const { failures, compileError } = parseTeslTestOutput(out, 1);
  assert.strictEqual(compileError, null, "must not be misreported as a compile error");
  assert.ok(failures.has("weird one"), "FAILURE: <msg> block should be parsed");
});

t("partial parse: more reported failures than parsed → not a compile error", () => {
  // Only one block is in a recognizable shape but the summary says 2 failed.
  const out = [
    "--------------------",
    "parsed fail",
    "FAILURE",
    "actual: 1",
    "expected: 2",
    "--------------------",
    "2/5 test failures",
  ].join("\n");
  const { failures, compileError, reportedFailureCount } = parseTeslTestOutput(out, 1);
  assert.strictEqual(reportedFailureCount, 2);
  assert.strictEqual(failures.size, 1);
  // compileError stays null because the summary reports real test failures — the
  // extension uses (failures.size < reportedFailureCount) to avoid false passes.
  assert.strictEqual(compileError, null);
});

// ── Format A: tesl `_tesl_test_format` output ──────────────────────────────────
const FMT = [
  "  FAILED  this one fails",
  "    at /x/Txr.tesl:12",
  "    expected: 5, actual: 4",
  "  FAILED  another broken",
  "    error: boom",
  "  1/3 test failures",
].join("\n");

t("formatted: two failures parsed, location lines dropped", () => {
  const { failures, compileError } = parseTeslTestOutput(FMT, 1);
  assert.strictEqual(compileError, null);
  assert.strictEqual(failures.size, 2);
  assert.ok(failures.has("this one fails"));
  assert.ok(failures.has("another broken"));
  assert.ok(/expected: 5, actual: 4/.test(failures.get("this one fails").message));
  assert.ok(!/at \/x/.test(failures.get("this one fails").message), "location line should be dropped");
  assert.ok(/boom/.test(failures.get("another broken").message));
});

// ── All pass: exit 0, no failure blocks ────────────────────────────────────────
t("all pass: exit 0 → no failures, no compile error", () => {
  const out = "raco test: (submod (file \"/x/Txr.rkt\") test)\n";
  const { failures, compileError } = parseTeslTestOutput(out, 0);
  assert.strictEqual(failures.size, 0);
  assert.strictEqual(compileError, null);
});

t("empty output, exit 0 → clean", () => {
  const { failures, compileError } = parseTeslTestOutput("", 0);
  assert.strictEqual(failures.size, 0);
  assert.strictEqual(compileError, null);
});

// ── Compile error: non-zero exit, no failure blocks ────────────────────────────
t("compile error: non-zero exit with diagnostic → compileError set", () => {
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

// ── A real failure must NOT be misclassified as a compile error ────────────────
t("genuine test failure (exit 1, blocks present) is not a compile error", () => {
  const { failures, compileError } = parseTeslTestOutput(RAW, 1);
  assert.strictEqual(compileError, null);
  assert.ok(failures.size > 0);
});

console.log("\nAll " + passed + " parser tests passed.");
