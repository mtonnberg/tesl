"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { projectForFile, manifestEntry } = require("./migration-project");

test("manifest entry discovery honors sections, quotes, comments and duplicate refusal", () => {
  assert.equal(manifestEntry('[other]\nentrypoint = "wrong.tesl"\n[project] # comment\nentrypoint = "a # b=app.tesl" # comment\n'), "a # b=app.tesl");
  assert.equal(manifestEntry('[project]\nentrypoint = app.tesl # comment\n'), "app.tesl");
  assert.equal(manifestEntry('[project]\nname = "example"\n'), undefined);
  assert.throws(() => manifestEntry('[project]\nentrypoint = "a.tesl"\nentrypoint = "b.tesl"\n'), /duplicate/);
  assert.throws(() => manifestEntry('[project]\nentrypoint = "unterminated\n'), /Invalid/);
});

test("nearest nested project wins; invalid or absent local entry does not select an unrelated parent app", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "tesl-guide-project-"));
  try {
    const nested = path.join(root, "example", "notes");
    fs.mkdirSync(nested, { recursive: true });
    fs.writeFileSync(path.join(root, "tesl.toml"), '[project]\nentrypoint = "unrelated.tesl"');
    const manifest = path.join(nested, "tesl.toml");
    fs.writeFileSync(manifest, '[project]\nentrypoint = "todo-app.tesl"');
    const schema = path.join(nested, "schema", "todo", "v-current.tesl");
    assert.deepEqual(projectForFile(schema, root), { projectRoot: nested, entry: path.join(nested, "todo-app.tesl") });
    assert.deepEqual(projectForFile(schema, root, () => '[project]\nname = "draft"'), { projectRoot: nested, entry: undefined });
    assert.throws(() => projectForFile(schema, root, () => '[project]\nentrypoint = "../../outside.tesl"'), /inside its project/);
    assert.throws(() => projectForFile(path.join(root, "..", "outside.tesl"), root), /inside an open workspace/);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
