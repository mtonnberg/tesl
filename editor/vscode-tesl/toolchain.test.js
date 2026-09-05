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
  // PATH discovery follows the launcher, including macOS's /var directory alias.
  return { root, realRoot: fs.realpathSync(root), manifest, write, suffix };
}

test("desktop discovery selects one installation and preserves paths", (t) => {
  const { root, realRoot, suffix } = fixture(t);
  const installation = findInstallation({ env: { PATH: path.join(root, "bin") } });
  assert.equal(installation.component("tesl-lsp"), path.join(realRoot, "bin", "tesl-lsp" + suffix));
  assert.equal(installation.component("compiler"), path.join(realRoot, "bin", "compiler" + suffix));
});

test("Windows discovery finds .exe without where.exe or a shell", (t) => {
  const { root, realRoot } = fixture(t, ".exe");
  const env = { Path: path.join(root, "bin") };
  assert.equal(findOnPath("tesl", { env, platform: "win32" }), path.join(root, "bin", "tesl.exe"));
  assert.equal(findInstallation({ env, platform: "win32" }).component("tesl-dap"), path.join(realRoot, "bin", "tesl-dap.exe"));
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
  const { root, realRoot, suffix } = fixture(t);
  const links = path.join(root, "links");
  fs.mkdirSync(links);
  try { fs.symlinkSync(path.join(root, "bin", "tesl" + suffix), path.join(links, "tesl" + suffix)); }
  catch (error) { if (error.code === "EPERM") { t.skip("symlinks unavailable"); return; } throw error; }
  assert.equal(findInstallation({ env: { PATH: links } }).root, realRoot);
});

test("symlinked installation directories resolve to their real tools", (t) => {
  const { root, realRoot, suffix } = fixture(t);
  const link = path.join(path.dirname(root), "current");
  try { fs.symlinkSync(root, link, "junction"); }
  catch (error) { if (error.code === "EPERM") { t.skip("symlinks unavailable"); return; } throw error; }
  const installation = findInstallation({ env: { PATH: path.join(link, "bin") } });
  assert.equal(installation.root, realRoot);
  assert.equal(installation.component("tesl-lsp"), path.join(realRoot, "bin", "tesl-lsp" + suffix));
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

function managedFixture(t, suffix) {
  const original = fixture(t, suffix);
  const root = path.join(path.dirname(original.root), "managed å");
  const version = "0.3.1-dev.123.g" + "a".repeat(40);
  const selected = path.join(root, "versions", version);
  fs.mkdirSync(path.dirname(selected), { recursive: true });
  fs.renameSync(original.root, selected);
  const manifest = { ...original.manifest, toolchain_version: version };
  const writeManifest = () => fs.writeFileSync(path.join(selected, "share", "tesl", "toolchain.json"), JSON.stringify(manifest));
  writeManifest();
  fs.mkdirSync(path.join(root, "bin"));
  for (const name of ["tesl", "tesl-lsp", "tesl-dap"]) {
    fs.writeFileSync(path.join(root, "bin", name + original.suffix), "native shim", { mode: 0o755 });
  }
  fs.writeFileSync(path.join(root, ".tesl-install.json"), JSON.stringify({
    version: 1, kind: "tesl-managed-installation", launcher_sha256: "b".repeat(64),
  }));
  const state = { version: 1, active_version: version, previous_version: "", generation: 1 };
  const writeState = () => fs.writeFileSync(path.join(root, "state.json"), JSON.stringify(state));
  writeState();
  return { root, selected, version, state, writeState, manifest, writeManifest, suffix: original.suffix };
}

test("managed PATH installs use native shims with a pinned version on Unix and Windows", (t) => {
  // Unix hosts can model Windows suffix lookup; Windows cannot model Unix
  // executable permission bits (chmod is not an executable-bit API there).
  for (const platform of new Set([process.platform, "win32"])) {
    const value = managedFixture(t, platform === "win32" ? ".exe" : "");
    const selected = findInstallation({ platform, env: { PATH: path.join(value.root, "bin") } });
    const realRoot = fs.realpathSync(value.root);
    assert.equal(selected.component("tesl-lsp"), path.join(realRoot, "bin", "tesl-lsp" + value.suffix));
    assert.equal(selected.component("compiler"), path.join(realRoot, "versions", value.version, "bin", "compiler" + value.suffix));
    assert.deepEqual(selected.launchEnvironment, { TESL_INSTALL_VERSION: value.version });
    value.state.active_version = "";
    value.writeState();
    assert.equal(selected.launchEnvironment.TESL_INSTALL_VERSION, value.version);
    assert.equal(findInstallation({ root: value.selected }).manifest.toolchain_version, value.version);
    assert.equal(findInstallation({ platform, env: { PATH: path.join(value.root, "bin") } }), null);
  }
});

test("managed selection refuses malformed state, traversal and mismatched manifests", (t) => {
  const value = managedFixture(t);
  const original = { ...value.state };
  for (const change of [{ active_version: "../escape" }, { active_version: "C:/escape" },
    { active_version: "0.3.1/else" }, { previous_version: value.version }, { generation: -1 },
    { generation: "1" }, { version: 2 }, { active_version: null }, { extra: true }]) {
    fs.writeFileSync(path.join(value.root, "state.json"), JSON.stringify({ ...original, ...change }));
    assert.throws(() => findInstallation({ root: value.root }), /selection state/);
  }
  value.writeState();
  value.manifest.toolchain_version = "0.3.0";
  value.writeManifest();
  assert.throws(() => findInstallation({ root: value.root }), /does not match/);
});

test("managed default discovery works without PATH and missing selected versions fail explicitly", (t) => {
  const value = managedFixture(t, ".exe");
  const local = path.join(path.dirname(value.root), "AppData å");
  const target = path.join(local, "Programs", "Tesl");
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.renameSync(value.root, target);
  const selected = findInstallation({ platform: "win32", env: { LOCALAPPDATA: local } });
  assert.equal(selected.managedRoot, target);
  fs.rmSync(path.join(target, "versions", value.version), { recursive: true });
  assert.throws(() => findInstallation({ platform: "win32", env: { LOCALAPPDATA: local } }), /ENOENT/);
});

test("managed directory and state links cannot redirect selection outside the installation", (t) => {
  const value = managedFixture(t);
  const moved = path.join(path.dirname(value.root), "outside-version");
  fs.renameSync(value.selected, moved);
  try { fs.symlinkSync(moved, value.selected, "junction"); }
  catch (error) { if (error.code === "EPERM") { t.skip("symlinks unavailable"); return; } throw error; }
  assert.throws(() => findInstallation({ root: value.root }), /must not be symlinks/);
});
