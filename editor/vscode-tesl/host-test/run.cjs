"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { spawn } = require("node:child_process");

async function main() {
  const extension = path.resolve(__dirname, "..");
  const repo = path.resolve(extension, "../..");
  const binary = process.env.TESL_CODIUM_BINARY;
  const compiler = process.env.TESL_COMPILER || path.join(repo, "compiler/_build/default/bin/main.exe");
  const lsp = process.env.TESL_LSP_HOST_BINARY;
  if (!binary || !lsp || !fs.existsSync(binary) || !fs.existsSync(lsp) || !fs.existsSync(compiler)) throw new Error("Set TESL_CODIUM_BINARY and TESL_LSP_HOST_BINARY to the real editor and matching built LSP; build the compiler first.");
  const artifacts = process.env.TESL_MIGRATION_HOST_ARTIFACTS || path.join(repo, ".tesl-stuff/migration-editor-host");
  fs.mkdirSync(artifacts, { recursive: true });
  const run = fs.mkdtempSync(path.join(artifacts, "run-"));
  const project = path.join(run, "project"), userData = path.join(run, "user-data"), extensions = path.join(run, "extensions");
  fs.mkdirSync(path.join(project, "schema/notes"), { recursive: true });
  fs.mkdirSync(path.join(userData, "User"), { recursive: true }); fs.mkdirSync(extensions);
  fs.writeFileSync(path.join(project, "tesl.toml"), "");
  fs.writeFileSync(path.join(project, "schema/notes/v-current.tesl"), 'module NotesSchema.VCurrent exposing [Note]\nimport Tesl.Prelude exposing [String]\nentity Note table "notes" primaryKey id { id: String }\n');
  fs.writeFileSync(path.join(project, "app.tesl"), 'module App exposing []\nimport Tesl.Database exposing [Database, Memory]\nimport NotesSchema.VCurrent\ndatabase Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate, backend: Memory }\n');
  fs.writeFileSync(path.join(userData, "User/settings.json"), JSON.stringify({ "tesl.compilerBinary": compiler, "tesl.lspBinary": lsp, "security.workspace.trust.enabled": false, "workbench.startupEditor": "none", "window.restoreWindows": "none", "update.mode": "none", "extensions.autoUpdate": false, "telemetry.telemetryLevel": "off" }));
  const env = { ...process.env, TESL_MIGRATION_HOST_PROJECT: project, TESL_MIGRATION_HOST_EVIDENCE: path.join(run, "evidence.json") };
  for (const [name, subdir] of Object.entries({ XDG_STATE_HOME: "state", XDG_CONFIG_HOME: "config", XDG_DATA_HOME: "data", XDG_CACHE_HOME: "cache", XDG_RUNTIME_DIR: "runtime" })) {
    env[name] = path.join(run, subdir); fs.mkdirSync(env[name], { mode: 0o700 });
  }
  const args = ["--wait", "--no-sandbox", "--disable-gpu", "--disable-workspace-trust", "--skip-welcome", "--skip-release-notes", "--user-data-dir", userData, "--extensions-dir", extensions, "--extensionDevelopmentPath", extension, "--extensionTestsPath", path.join(__dirname, "index.cjs"), project];
  const log = fs.createWriteStream(path.join(run, "editor.log"));
  const child = spawn(binary, args, { env, stdio: ["ignore", "pipe", "pipe"], detached: process.platform !== "win32" });
  child.stdout.pipe(log); child.stderr.pipe(log);
  const timer = setTimeout(() => { try { process.kill(process.platform === "win32" ? child.pid : -child.pid, "SIGTERM"); } catch (_) {} }, 180000);
  try {
    const code = await new Promise((resolve, reject) => { child.once("error", reject); child.once("close", resolve); });
    await new Promise((resolve) => log.end(resolve));
    const evidencePath = path.join(run, "evidence.json");
    const evidence = fs.existsSync(evidencePath) ? JSON.parse(fs.readFileSync(evidencePath, "utf8")) : { ok: false, error: "Editor test host did not produce evidence." };
    const hostLog = fs.readFileSync(path.join(run, "editor.log"), "utf8");
    const runtimeErrors = hostLog.split(/\r?\n/).filter((line) => /rejected promise not handled|ERR_UNHANDLED_REJECTION|Uncaught Exception|Activating extension .* failed/.test(line));
    if (runtimeErrors.length) { evidence.ok = false; evidence.runtimeErrors = runtimeErrors.slice(0, 20); fs.writeFileSync(evidencePath, JSON.stringify(evidence, null, 2)); }
    console.log(JSON.stringify({ exitCode: code, evidencePath, ...evidence }, null, 2));
    if (code !== 0 || !evidence.ok) process.exitCode = 1;
  } finally { clearTimeout(timer); if (!log.writableEnded) log.end(); }
}
main().catch((error) => { console.error(error.message); process.exitCode = 1; });
