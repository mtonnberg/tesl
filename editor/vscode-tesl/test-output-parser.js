"use strict";

// Pure parser for `tesl test` output → per-test pass/fail results.
//
// This module has NO `vscode` dependency so it can be unit-tested under plain node
// (see test-output-parser.test.js). The VS Code Test Explorer integration in
// extension.js feeds it the combined stdout+stderr of `tesl test <file>` plus the
// process exit code, and maps the parsed failures back to discovered test items by
// name. Passes are silent in rackunit, so the caller treats "discovered ∧ not in
// failures ∧ no compile error" as a pass.
//
// Two output shapes are handled, because the failure text depends on the installed
// `tesl` wrapper version:
//   A) Formatted (`_tesl_test_format`):   "  FAILED  <name>" / "    at <loc>" / "    <msg>"
//   B) Raw rackunit:  "-----" / "<name>" / "FAILURE|ERROR" / "actual:"/"expected:"/"message:"

function parseTeslTestOutput(output, code) {
  const text = String(output == null ? "" : output);
  const lines = text.split(/\r?\n/);
  const failures = new Map(); // name -> { message, expected?, actual? }

  // ── Format A: tesl `_tesl_test_format` output ────────────────────────────────
  // The formatter emits exactly "  FAILED  <name>" (two-space indent, two spaces
  // after FAILED), then an optional "    at <loc>" line and one or more message
  // lines, until the next FAILED block / a "-----" / the run summary.
  for (let i = 0; i < lines.length; i++) {
    const m = /^ {2}FAILED {2}(.+?)\s*$/.exec(lines[i]);
    if (!m) continue;
    const name = m[1];
    const msgLines = [];
    for (let j = i + 1; j < lines.length; j++) {
      const raw = lines[j];
      if (/^ {2}FAILED {2}/.test(raw)) break;
      if (/^-{5,}\s*$/.test(raw)) break;
      if (/\btests?\b.*\b(passed|failure)/.test(raw)) break;
      if (/^\s*\d+\/\d+\s+test/.test(raw)) break;
      const t = raw.trim();
      if (!t) continue;
      if (/^at\s+\S/.test(t)) continue; // location — the extension supplies its own
      msgLines.push(t);
    }
    if (!failures.has(name)) {
      failures.set(name, { message: msgLines.join("\n") || "assertion did not hold" });
    }
  }

  // ── Format B: raw rackunit failure blocks ────────────────────────────────────
  for (let i = 0; i < lines.length; i++) {
    if (!/^-{5,}\s*$/.test(lines[i])) continue;
    let k = i + 1;
    while (k < lines.length && lines[k].trim() === "") k++;
    const name = (lines[k] || "").trim();
    if (!name) continue;
    if (/\btests?\b.*\b(passed|failure)/.test(name) || /^\d+\/\d+\s+test/.test(name)) continue;
    let isFail = false, kind = "", actual, expected, message = "";
    for (let j = k + 1; j < lines.length && !/^-{5,}\s*$/.test(lines[j]); j++) {
      const t = lines[j].trim();
      // Tolerate "FAILURE", "ERROR", and any "FAILURE: ..."/"ERROR - ..." variants.
      const fk = /^(FAILURE|ERROR)\b/.exec(t);
      if (fk) { isFail = true; kind = fk[1]; continue; }
      let mm;
      if ((mm = /^actual:\s*(.*)$/.exec(t))) { actual = mm[1]; continue; }
      if ((mm = /^expected:\s*(.*)$/.exec(t))) { expected = mm[1]; continue; }
      if ((mm = /^message:\s*(.*)$/.exec(t))) { message = mm[1]; continue; }
    }
    if (isFail && !failures.has(name)) {
      let msg = message;
      if (!msg) {
        if (actual !== undefined || expected !== undefined) msg = `expected ${expected}, got ${actual}`;
        else msg = kind || "test failed";
      }
      failures.set(name, { message: msg, actual, expected });
    }
  }

  // rackunit prints a run summary ("N/M test failures"). Capturing N lets the caller
  // detect a PARTIAL parse (failures.size < N) and avoid falsely reporting a missed
  // failure as a pass.
  let reportedFailureCount = null;
  for (const line of lines) {
    let mm = /(\d+)\/\d+\s+test\s+failures?/.exec(line);
    if (!mm) mm = /(\d+)\s+tests?\s+failed/.exec(line);
    if (mm) { reportedFailureCount = parseInt(mm[1], 10); break; }
  }

  // ── Compile / runtime error: non-zero exit with no per-test failures parsed ───
  let compileError = null;
  if (code !== 0 && failures.size === 0 && (reportedFailureCount === null || reportedFailureCount === 0)) {
    const em = /error(\[[^\]]*\])?:\s.*/i.exec(text);
    if (em) {
      compileError = em[0];
    } else {
      const head = lines.filter((l) => l.trim()).slice(0, 5).join("\n");
      compileError = head || `tesl test exited with code ${code}`;
    }
  }

  return { failures, compileError, reportedFailureCount };
}

module.exports = { parseTeslTestOutput };
