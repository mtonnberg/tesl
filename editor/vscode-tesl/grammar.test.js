"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const textmate = require("vscode-textmate");
const oniguruma = require("vscode-oniguruma");

// Use the same engine as VS Code/VSCodium: regex-only checks miss scope leakage.
const wasm = fs.readFileSync(require.resolve("vscode-oniguruma/release/onig.wasm"));
const onigLib = oniguruma.loadWASM(wasm.buffer.slice(wasm.byteOffset, wasm.byteOffset + wasm.byteLength)).then(() => ({
  createOnigScanner: patterns => new oniguruma.OnigScanner(patterns),
  createOnigString: value => new oniguruma.OnigString(value),
}));
const grammarPath = path.join(__dirname, "syntaxes/tesl.tmLanguage.json");
const registry = new textmate.Registry({
  onigLib,
  loadGrammar: async scope => scope === "source.tesl"
    ? textmate.parseRawGrammar(fs.readFileSync(grammarPath, "utf8"), grammarPath) : null,
});
const grammar = registry.loadGrammar("source.tesl");

async function tokenize(source) {
  const loaded = await grammar;
  assert.ok(loaded);
  let stack = textmate.INITIAL;
  return source.split(/\r?\n/).map(line => {
    const result = loaded.tokenizeLine(line, stack);
    stack = result.ruleStack;
    return result.tokens.map(token => ({ text: line.slice(token.startIndex, token.endIndex), scopes: token.scopes }));
  });
}

function matching(tokens, text) {
  const found = tokens.flat().filter(token => token.text === text);
  assert.ok(found.length, `missing token ${JSON.stringify(text)}`);
  return found;
}
function keyword(tokens, text, scope = "keyword.other.tesl") {
  for (const token of matching(tokens, text)) assert.ok(token.scopes.includes(scope), `${text}: ${token.scopes.join(" ")}`);
}
function ordinary(tokens, text, nested = false) {
  for (const token of matching(tokens, text)) {
    assert.ok(!token.scopes.some(scope => scope.startsWith("keyword.")), `${text}: ${token.scopes.join(" ")}`);
    if (!nested) assert.ok(!token.scopes.includes("meta.migration.tesl"), `${text} leaked a migration scope`);
  }
}

test("migration grammar highlights the actual archived declarations", async () => {
  for (const version of [2, 3, 4, 5, 6, 7]) {
    const name = path.resolve(__dirname, `../../example/db-migration-example/migrations/todo/v${version}.tesl`);
    const source = fs.readFileSync(name, "utf8");
    const lines = source.split(/\r?\n/);
    const tokens = await tokenize(source);
    keyword([tokens[lines.findIndex(line => /^migration\s*=/.test(line))]], "migration", "keyword.other.declaration.tesl");
    for (const label of ["from", "to", "same", "entities"]) {
      const index = lines.findIndex(line => new RegExp(`^\\s+${label}:`).test(line));
      assert.ok(index >= 0, `${name}: ${label}`);
      keyword([tokens[index]], label);
    }
    keyword(tokens, "Same", "entity.name.type.tesl");
    ordinary([tokens[lines.findIndex(line => line.startsWith("module "))]], "migration");
  }
});

test("migration grammar accepts qualified constructors, tabs and inline fields", async () => {
  for (const constructor of ["Migration", "Tesl.Migration.Migration"]) {
    const tokens = await tokenize(`migration\t=\t${constructor}\t{ from: Schema.Todo.V1, to: Schema.Todo.V2, same: [], entities: {} }`);
    keyword(tokens, "migration", "keyword.other.declaration.tesl");
    keyword(tokens, constructor, "entity.name.type.tesl");
    for (const label of ["from", "to", "same", "entities"]) keyword(tokens, label);
  }
});

test("migration identifiers remain ordinary outside the contextual declaration", async () => {
  const tokens = await tokenize([
    "module Message exposing [migration, same]",
    "record Message { to: String, same: String, migration: String }",
    "fn same (to: String): String = to",
    'migration = Message { to: "reader", same: "text", migration: "value" }',
    "fn use (migration: Message): String = migration.to",
  ].join("\n"));
  for (const name of ["migration", "same", "to"]) ordinary(tokens, name);
});

test("migration field highlighting excludes nested records and resumes afterward", async () => {
  const tokens = await tokenize([
    "migration = Migration {",
    "  from: Schema.Todo.V1",
    "  entities: {",
    '    "Todo": { to: next, same: { to: next }, migration: value }',
    "  }",
    "  to: Schema.Todo.VCurrent",
    "  same: []",
    "}",
    "record Message { to: String, same: String, migration: String }",
  ].join("\n"));
  for (const name of ["to", "same", "migration"]) ordinary([tokens[3]], name, true);
  keyword([tokens[5]], "to");
  keyword([tokens[6]], "same");
  for (const name of ["migration", "same", "to"]) ordinary([tokens[8]], name);
});

test("migration comments and strings cannot close or inject declaration scopes", async () => {
  const tokens = await tokenize([
    "# migration = Migration { to: same: }",
    'text = "migration = Migration { to: same: }"',
    "migration = Migration {",
    "  # } to: same: migration",
    '  same: ["} same: to: migration"]',
    "  to: Schema.Todo.VCurrent",
    "  entities: {}",
    "}",
    "same = to",
  ].join("\n"));
  for (const [line, fragment, scope] of [
    [0, "# migration", "comment.line.number-sign.tesl"],
    [1, "Migration", "string.quoted.double.tesl"],
    [3, "# }", "comment.line.number-sign.tesl"],
    [4, "} same:", "string.quoted.double.tesl"],
  ]) {
    const found = tokens[line].filter(token => token.text.includes(fragment));
    assert.ok(found.length, fragment);
    assert.ok(found.every(token => token.scopes.includes(scope)), fragment);
  }
  keyword([tokens[5]], "to");
  ordinary([tokens[8]], "same");
  ordinary([tokens[8]], "to");
});

test("an unfinished migration record does not paint the next declaration", async () => {
  const tokens = await tokenize("migration = Migration {\n  to: Schema.Todo.V2\nfn same (to: String): String = to");
  keyword([tokens[1]], "to");
  ordinary([tokens[2]], "same");
  ordinary([tokens[2]], "to");
});
