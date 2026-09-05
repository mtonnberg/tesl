"use strict";

const assert = require("node:assert/strict");
const { test } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { findOnPath, findInstallation, readInstallation } = require("./toolchain");

function fixture(t, suffix = process.platform === "win32" ? ".exe" : "") {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "tesl-install-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const root = path.join(directory, "tools å with spaces");
  fs.mkdirSync(path.join(root, "share", "tesl"), { recursive: true });
  fs.mkdirSync(path.join(root, "bin"));
  const manifest = { version: 1, toolchain_version: "test", source_revision: "a".repeat(40), components: {} };
  for (const name of ["tesl", "tesl-lsp", "tesl-dap", "compiler"]) {
    const relative = `bin/${name}${suffix}`;
    fs.writeFileSync(path.join(root, relative), "tool", { mode: 0o755 });
    manifest.components[name] = { path: relative, version: "test" };
  }
  const write = () => fs.writeFileSync(path.join(root, "share", "tesl", "toolchain.json"), JSON.stringify(manifest));
  write();
  return { root, manifest, write, suffix };
}

test("desktop discovery selects one installation and preserves paths", (t) => {
  const { root, suffix } = fixture(t);
  const installation = findInstallation({ env: { PATH: path.join(root, "bin") } });
  assert.equal(installation.component("tesl-lsp"), path.join(root, "bin", "tesl-lsp" + suffix));
  assert.equal(installation.component("compiler"), path.join(root, "bin", "compiler" + suffix));
});

test("Windows discovery finds .exe without where.exe or a shell", (t) => {
  const { root } = fixture(t, ".exe");
  const env = { Path: path.join(root, "bin") };
  assert.equal(findOnPath("tesl", { env, platform: "win32" }), path.join(root, "bin", "tesl.exe"));
  assert.equal(findInstallation({ env, platform: "win32" }).component("tesl-dap"), path.join(root, "bin", "tesl-dap.exe"));
});

test("explicit installation overrides PATH and rejects missing components", (t) => {
  const selected = fixture(t);
  const other = fixture(t);
  const installation = findInstallation({ root: selected.root, env: { PATH: path.join(other.root, "bin") } });
  assert.equal(installation.root, selected.root);
  fs.unlinkSync(path.join(selected.root, "bin", "compiler" + selected.suffix));
  assert.throws(() => installation.component("compiler"));
});

test("invalid explicit installation does not silently use PATH", (t) => {
  const { root, suffix } = fixture(t);
  assert.throws(() => findInstallation({ root: path.join(root, "missing"), env: { PATH: path.join(root, "bin") } }), /No Tesl toolchain manifest/);
});

test("manifest paths cannot escape through either platform's syntax", (t) => {
  const { root, manifest, write } = fixture(t);
  for (const unsafe of ["../compiler", "/bin/compiler", "C:/compiler.exe", "bin\\compiler.exe", "bin//compiler", "./compiler"]) {
    manifest.components.compiler.path = unsafe;
    write();
    assert.throws(() => readInstallation(root), /Invalid path/);
  }
});

test("symlinked launchers keep their selected installation", (t) => {
  const { root, suffix } = fixture(t);
  const links = path.join(root, "links");
  fs.mkdirSync(links);
  try { fs.symlinkSync(path.join(root, "bin", "tesl" + suffix), path.join(links, "tesl" + suffix)); }
  catch (error) { if (error.code === "EPERM") { t.skip("symlinks unavailable"); return; } throw error; }
  assert.equal(findInstallation({ env: { PATH: links } }).root, root);
});

test("legacy PATH installation does not borrow a different installation", (t) => {
  const { root, suffix } = fixture(t);
  fs.unlinkSync(path.join(root, "share", "tesl", "toolchain.json"));
  assert.equal(findInstallation({ env: { PATH: path.join(root, "bin") }, home: root }), null);
});

test("manifest readers reject incompatible field types and oversized trailing data", (t) => {
  const { root, manifest } = fixture(t);
  const filename = path.join(root, "share", "tesl", "toolchain.json");
  for (const patch of [
    { version: 2 }, { toolchain_version: 1 }, { source_revision: [] },
    { target: {} }, { components: {} }, { unknown: true },
    { components: { compiler: { path: "bin/compiler", version: "test", optional: "yes" } } },
  ]) {
    fs.writeFileSync(filename, JSON.stringify({ ...manifest, ...patch }));
    assert.throws(() => readInstallation(root));
  }
  fs.writeFileSync(filename, JSON.stringify(manifest) + " ".repeat(1024 * 1024));
  assert.throws(() => readInstallation(root), /1 MiB/);
});
