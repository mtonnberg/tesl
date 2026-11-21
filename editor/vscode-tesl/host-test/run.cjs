"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { spawn, execFileSync } = require("node:child_process");

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
  const workspace = path.join(run, "workspace"), project = path.join(workspace, "example/db-migration-example"), userData = path.join(run, "user-data"), extensions = path.join(run, "extensions");
  fs.mkdirSync(path.join(project, "schema/notes"), { recursive: true });
  fs.mkdirSync(path.join(userData, "User"), { recursive: true }); fs.mkdirSync(extensions);
  fs.writeFileSync(path.join(project, "tesl.toml"), '[project]\nentrypoint = "todo-app.tesl"\n');
  fs.writeFileSync(path.join(project, "schema/notes/v-current.tesl"), 'module NotesSchema.VCurrent exposing [Note]\nimport Tesl.Prelude exposing [String]\nentity Note table "notes" primaryKey id { id: String }\n');
  fs.writeFileSync(path.join(project, "todo-app.tesl"), 'module App exposing []\nimport Tesl.Database exposing [Database, Memory]\nimport NotesSchema.VCurrent\ndatabase Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate, backend: Memory }\ntest "migration application smoke" { expect 1 == 1 }\n');
  const example = path.join(workspace, "example/real-todo");
  // Use the committed V13 fixture, independent of the user's current draft.
  const prefix = "example/db-migration-example/";
  const exampleFiles = execFileSync("git", ["ls-tree", "-r", "--name-only", "HEAD", "--", prefix], { cwd: repo, encoding: "utf8" }).trim().split("\n");
  for (const file of exampleFiles) {
    const target = path.join(example, file.slice(prefix.length));
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, execFileSync("git", ["show", `HEAD:${file}`], { cwd: repo }));
  }
  const queue = path.join(workspace, "example/queue-authoring");
  fs.mkdirSync(path.join(queue, "schema/notes"), { recursive: true });
  fs.writeFileSync(path.join(queue, "tesl.toml"), '[project]\nentrypoint = "jobs-app.tesl"\n');
  fs.writeFileSync(path.join(queue, "schema/notes/v-current.tesl"), `module NotesSchema.VCurrent exposing [Tasks, Notify]
import Tesl.Prelude exposing [String, Int]
import Tesl.Json exposing [stringCodec, intCodec]
record Notify { text: String }
codec Notify {
  toJson { text -> "text" with_codec stringCodec }
  fromJson [ { text <- "text" with_codec stringCodec } ]
}
queueSchema Tasks { jobs: [Notify] }
`);
  fs.writeFileSync(path.join(queue, "jobs-app.tesl"), `module App exposing []
import NotesSchema.VCurrent
import Tesl.Prelude exposing [Unit, String]
import Tesl.Database exposing [Database, Memory]
import Tesl.Queue exposing [Queue, FromQueue, queueRead]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.App exposing [App]
database Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate, backend: Memory }
queue Tasks requires [queueRead] = Queue { database: Main, schema: NotesSchema.VCurrent.Tasks,
  jobs: [Job NotesSchema.VCurrent.Notify handle Nothing] }
worker handle(job: NotesSchema.VCurrent.Notify ::: FromQueue (Id == jobId) job) requires [queueRead] = job
handler get healthy() -> String = "ok"
api Routes { get "/" -> String }
server Web for Routes { healthy }
main() -> App requires [queueRead] = App { database: Main, queues: [Tasks], api: Web }
`);
  const proof = path.join(workspace, "example/proof-authoring");
  fs.mkdirSync(path.join(proof, "schema/notes"), { recursive: true });
  fs.writeFileSync(path.join(proof, "tesl.toml"), '[project]\nentrypoint = "app.tesl"\n');
  fs.writeFileSync(path.join(proof, "app.tesl"), 'module App exposing []\nimport NotesSchema.VCurrent\nimport Tesl.Database exposing [Database, Memory]\ndatabase Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate, backend: Memory }\n');
  fs.writeFileSync(path.join(proof, "schema/notes/v-current.tesl"), `module NotesSchema.VCurrent exposing [Note, Status(..), Good, accept, newNote]
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.String exposing [String.trim, String.length]
fact Good(value: String)
establish accept(raw: String) -> Maybe (value: String ::: Good value) =
  let value = String.trim raw
  if String.length value > 0 && String.length value <= 120 then
    Something (value ::: Good value)
  else
    Nothing
type Status =
  | Open
  | Closed
codec Status { adtJson }
entity Note table "notes" primaryKey id { id: String, title: String ::: Good title, status: Status }
fn newNote(id: String, title: String ::: Good title) -> Note = Note { id: id, title: title, status: Open }
`);
  fs.writeFileSync(path.join(userData, "User/settings.json"), JSON.stringify({ "tesl.compilerBinary": compiler, "tesl.lspBinary": lsp, "security.workspace.trust.enabled": false, "workbench.startupEditor": "none", "window.restoreWindows": "none", "update.mode": "none", "extensions.autoUpdate": false, "telemetry.telemetryLevel": "off" }));
  const env = { ...process.env, TESL_MIGRATION_HOST_PROJECT: project, TESL_MIGRATION_HOST_EXAMPLE: example, TESL_MIGRATION_HOST_QUEUE: queue, TESL_MIGRATION_HOST_PROOF: proof, TESL_MIGRATION_HOST_EVIDENCE: path.join(run, "evidence.json") };
  for (const [name, subdir] of Object.entries({ XDG_STATE_HOME: "state", XDG_CONFIG_HOME: "config", XDG_DATA_HOME: "data", XDG_CACHE_HOME: "cache", XDG_RUNTIME_DIR: "runtime" })) {
    env[name] = path.join(run, subdir); fs.mkdirSync(env[name], { mode: 0o700 });
  }
  const args = ["--wait", "--no-sandbox", "--disable-gpu", "--disable-workspace-trust", "--skip-welcome", "--skip-release-notes", "--user-data-dir", userData, "--extensions-dir", extensions, "--extensionDevelopmentPath", extension, "--extensionTestsPath", path.join(__dirname, "index.cjs"), workspace];
  const log = fs.createWriteStream(path.join(run, "editor.log"));
  const child = spawn(binary, args, { env, stdio: ["ignore", "pipe", "pipe"], detached: process.platform !== "win32" });
  child.stdout.pipe(log); child.stderr.pipe(log);
  const timer = setTimeout(() => { try { process.kill(process.platform === "win32" ? child.pid : -child.pid, "SIGTERM"); } catch (_) {} }, 300000);
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
