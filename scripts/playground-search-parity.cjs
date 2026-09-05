#!/usr/bin/env node
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs"), path = require("node:path"), cp = require("node:child_process");
const root = path.resolve(__dirname, "..");
const dist = path.resolve(process.argv[2] || path.join(root, "playground/dist"));
const compiler = process.env.TESL_OCAML_COMPILER || path.join(root, "compiler/_build/default/bin/main.exe");
const native = (...args) => {
  const result = cp.spawnSync(compiler, args, { encoding: "utf8", maxBuffer: 4 * 1024 * 1024, env: { ...process.env, TESL_REPO_ROOT: root } });
  assert.ok(result.status === 0 || result.status === 1, result.stderr);
  const json = JSON.parse(result.stdout);
  if (args[0] === "--search-json") assert.equal(result.status, json.error ? 1 : 0);
  return json;
};
globalThis.window = globalThis;
require(path.join(dist, "tesl_search.js"));
require(path.join(dist, "tesl_playground.js"));
const catalog = native("--catalog-json");
assert.equal(cp.spawnSync(compiler, ["search", "--json"]).status, 1, "a missing JSON query is a usage error");
assert.deepEqual(JSON.parse(teslCatalog()), catalog, "full native/browser catalog identity and metadata");
const fixtures = fs.readFileSync(path.join(root, "compiler/test/search-queries.tsv"), "utf8")
  .split("\n").filter(line => line && !line.startsWith("#")).map(line => line.split("\t"));
assert.equal(fixtures.length, 20);
for (const [query, expected] of fixtures) {
  const result = JSON.parse(teslSearch(query));
  assert.deepEqual(result, native("--search-json", query), query);
  assert.ok(result.results.slice(0, 5).some(entry => entry.name === expected), query + " -> " + expected);
}
const negatives = ["Float", "Float ->", "Float -> F", "Float -> Float", ":: (Float -> F", "Float -> ->","", "UnknownNominal -> Int", "String ->", ":: (String", ":: _", "x: String -> Int",
  "String ::: Safe -> Int", "String -> Int requires [time]", "x".repeat(257), "List.map :: (a -> b) -> List a -> List b",
  "String.length :: Int32 -> Int", "Dict.keys :: Dict a b -> List b", "<script>alert('x')</script>", "🧪".repeat(80)];
for (const query of negatives) assert.deepEqual(JSON.parse(teslSearch(query)), native("--search-json", query), query);
const checked = JSON.parse(teslCheck("module Sample exposing [answer]\nimport Tesl.Prelude exposing [Int]\nfn answer() -> Int = 42\n"));
assert.equal(checked.backend, "go");
assert.equal(checked.go, checked.racket, "legacy emitted-code alias");
assert.ok(checked.go, "clean program emits Go");
const bad = JSON.parse(teslCheck("module ???"));
assert.equal(bad.go, null); assert.equal(bad.racket, null);
const elapsed = [];
for (let i = 0; i < 200; ++i) {
  const start = performance.now();
  teslSearch(fixtures[i % fixtures.length][0]);
  elapsed.push(performance.now() - start);
}
elapsed.sort((a, b) => a - b);
const report = { version: 1, catalog_id: catalog.catalog_id, entries: catalog.entries.length,
  relevance_top5: [20, 20], parity_queries: fixtures.length + negatives.length,
  warm_ms: { p50: elapsed[100], p95: elapsed[190], max: elapsed[199] },
  environment: { node: process.version, platform: process.platform, arch: process.arch },
  checker_bytes: fs.statSync(path.join(dist, "tesl_playground.js")).size,
  search_bytes: fs.statSync(path.join(dist, "tesl_search.js")).size };
assert.ok(report.checker_bytes < 2000000, "checker bundle ceiling");
console.log(JSON.stringify(report, null, 2));
