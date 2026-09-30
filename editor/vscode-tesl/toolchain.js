"use strict";

const fs = require("fs");
const path = require("path");
const os = require("os");

function findOnPath(name, options = {}) {
  const env = options.env || process.env;
  const platform = options.platform || process.platform;
  const searchPath = Object.entries(env).find(([key]) => key.toLowerCase() === "path")?.[1] || "";
  const suffixes = platform === "win32" && !path.extname(name) ? [".exe", ".com"] : [""];
  const candidates = path.isAbsolute(name) ? [name] : searchPath.split(platform === "win32" ? ";" : path.delimiter)
    .filter(Boolean).flatMap((directory) => suffixes.map((suffix) => path.join(directory, name + suffix)));
  return candidates.find((candidate) => {
    try { return fs.statSync(candidate).isFile() && (platform === "win32" || (fs.statSync(candidate).mode & 0o111) !== 0); }
    catch (_) { return false; }
  }) || null;
}

function readInstallation(root) {
  const filename = path.join(root, "share", "tesl", "toolchain.json");
  let text;
  try {
    const stat = fs.statSync(filename);
    if (!stat.isFile() || stat.size > 1024 * 1024) throw new Error("Tesl toolchain manifest must be a file no larger than 1 MiB");
    text = fs.readFileSync(filename, "utf8");
  }
  catch (error) { if (error.code === "ENOENT") return null; throw error; }
  if (Buffer.byteLength(text) > 1024 * 1024) throw new Error("Tesl toolchain manifest exceeds 1 MiB");
  const manifest = JSON.parse(text);
  const nonemptyString = value => typeof value === "string" && value.length > 0;
  if (!manifest || manifest.version !== 1 || !nonemptyString(manifest.toolchain_version) || !nonemptyString(manifest.source_revision) ||
      (manifest.target !== undefined && typeof manifest.target !== "string") ||
      Object.keys(manifest).some(key => !["version", "toolchain_version", "source_revision", "target", "components"].includes(key)) ||
      !manifest.components || typeof manifest.components !== "object" || Array.isArray(manifest.components) || Object.keys(manifest.components).length === 0) {
    throw new Error("Incomplete or unsupported Tesl toolchain manifest");
  }
  for (const [name, component] of Object.entries(manifest.components)) {
    if (!name || !component || typeof component.path !== "string" || !nonemptyString(component.version) ||
        (component.optional !== undefined && typeof component.optional !== "boolean") ||
        Object.keys(component).some(key => !["path", "version", "optional"].includes(key)) ||
        /[\\:\0]/.test(component.path) || component.path.split("/").some((part) => !part || part === "." || part === "..")) {
      throw new Error("Invalid path in Tesl toolchain manifest");
    }
  }
  return { root, manifest, component(name) {
    const component = manifest.components[name];
    if (!component) throw new Error(`Selected Tesl installation is missing ${name}`);
    const resolved = path.join(root, ...component.path.split("/"));
    const stat = fs.statSync(resolved);
    if (!stat.isFile() || (process.platform !== "win32" && !(stat.mode & 0o111))) throw new Error(`Selected Tesl ${name} is not executable`);
    return resolved;
  } };
}

function readManagedInstallation(root) {
  function readJSON(name) {
    const filename = path.join(root, name);
    const stat = fs.lstatSync(filename);
    if (!stat.isFile() || stat.size > 4096) throw new Error(`Invalid managed Tesl ${name}`);
    const bytes = fs.readFileSync(filename);
    if (bytes.length > 4096) throw new Error(`Invalid managed Tesl ${name}`);
    return JSON.parse(bytes.toString("utf8"));
  }
  let marker;
  try { marker = readJSON(".tesl-install.json"); }
  catch (error) { if (error.code === "ENOENT") return null; throw error; }
  if (!marker || marker.version !== 1 || marker.kind !== "tesl-managed-installation" ||
      typeof marker.launcher_sha256 !== "string" || !/^[a-f0-9]{64}$/.test(marker.launcher_sha256)) {
    throw new Error("Invalid managed Tesl installation marker");
  }
  const state = readJSON("state.json");
  const version = value => typeof value === "string" && value.length <= 160 &&
    /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$/.test(value);
  if (!state || state.version !== 1 || !Number.isInteger(state.generation) || state.generation < 0 ||
      (state.active_version !== "" && !version(state.active_version)) ||
      (state.previous_version !== "" && !version(state.previous_version)) ||
      (!state.active_version && state.previous_version) ||
      (state.active_version && state.active_version === state.previous_version) ||
      Object.keys(state).some(key => !["version", "active_version", "previous_version", "generation"].includes(key))) {
    throw new Error("Invalid managed Tesl selection state");
  }
  if (!state.active_version) return null;
  const selected = path.join(root, "versions", state.active_version);
  for (const directory of [path.join(root, "versions"), selected, path.join(root, "bin")]) {
    const stat = fs.lstatSync(directory);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error("Managed Tesl directories must not be symlinks");
  }
  const installation = readInstallation(selected);
  if (!installation || installation.manifest.toolchain_version !== state.active_version) {
    throw new Error("Managed Tesl selection does not match its manifest");
  }
  const frontends = new Set(["tesl", "tesl-lsp", "tesl-dap", "tesl-mcp", "tesl-debug-inspect", "tesl-debug-attach"]);
  return { ...installation, managedRoot: root,
    launchEnvironment: { TESL_INSTALL_VERSION: state.active_version },
    component(name) {
      const actual = installation.component(name);
      if (!frontends.has(name)) return actual;
      const launcher = path.join(root, "bin", path.basename(actual));
      const stat = fs.statSync(launcher);
      if (!stat.isFile() || (process.platform !== "win32" && !(stat.mode & 0o111))) throw new Error(`Managed Tesl ${name} launcher is not executable`);
      return launcher;
    },
  };
}

function readSelection(root) {
  return readInstallation(root) || readManagedInstallation(root);
}

function findInstallation(options = {}) {
  const env = options.env || process.env;
  const platform = options.platform || process.platform;
  const explicit = options.root || env.TESL_TOOLCHAIN_ROOT;
  if (explicit) {
    const installation = readSelection(path.resolve(explicit));
    if (!installation) throw new Error(`No Tesl toolchain manifest in ${explicit}`);
    return installation;
  }
  const launcher = findOnPath("tesl", { env, platform });
  // A PATH installation is the user's selection, including a legacy Nix install.
  if (launcher) return readSelection(path.dirname(path.dirname(fs.realpathSync(launcher))));
  const home = options.home || os.homedir();
  const roots = platform === "win32"
    ? [env.LOCALAPPDATA && path.join(env.LOCALAPPDATA, "Programs", "Tesl"),
       env.LOCALAPPDATA && path.join(env.LOCALAPPDATA, "Programs", "Tesl", "current")]
    : [path.join(home, ".local", "share", "tesl"), path.join(home, ".local", "share", "tesl", "current"), "/opt/tesl/current"];
  for (const root of roots.filter(Boolean)) {
    const installation = readSelection(root);
    if (installation) return installation;
  }
  return null;
}

module.exports = { findOnPath, findInstallation, readInstallation };
