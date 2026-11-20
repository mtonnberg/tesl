"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const os = require("node:os");
const fs = require("node:fs");
const { registerMigrationAuthoring, migrationLensLocations, previewItems, renderGuide, inside, codeHoleOffset, codeHoleRange } = require("./migration-authoring");

function fixture(trusted = true) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "tesl-migration-editor-"));
  const entryFile = path.join(root, "app.tesl");
  fs.writeFileSync(entryFile, "module App exposing []\n");
  fs.writeFileSync(path.join(root, "tesl.toml"), "");
  const commands = new Map(), panels = [], providers = [], completionProviders = [], requests = [], warnings = [], errors = [], copies = [], opened = [], diffs = [];
  const changes = new Set();
  const uri = (file) => ({ fsPath: file, toString: () => file });
  const vscode = {
    Uri: { file: uri, parse: uri }, ViewColumn: { Beside: 2 },
    RelativePattern: class { constructor(base, pattern) { this.base = base; this.pattern = pattern; } },
    Range: class { constructor(a, b, c, d) { this.start = { line: a, character: b }; this.end = { line: c, character: d }; } },
    CodeLens: class { constructor(range, command) { this.range = range; this.command = command; } },
    CodeAction: class { constructor(title, kind) { this.title = title; this.kind = kind; } },
    CodeActionKind: { QuickFix: "quickfix" },
    CompletionItem: class { constructor(label, kind) { this.label = label; this.kind = kind; } },
    CompletionItemKind: { Snippet: 15 },
    env: { clipboard: { writeText: async (text) => copies.push(text) } },
    workspace: {
      isTrusted: trusted, getWorkspaceFolder: () => ({ uri: uri(root) }), asRelativePath: (file) => path.relative(root, file.fsPath),
      findFiles: async () => [uri(entryFile)], openTextDocument: async () => ({ lineCount: 1, lineAt: () => ({ text: "🌱 title" }) }),
      registerTextDocumentContentProvider: (_scheme, provider) => { providers.push(provider); return { dispose() {} }; },
      onDidChangeTextDocument: (handler) => { changes.add(handler); return { dispose: () => changes.delete(handler) }; },
    },
    window: {
      activeTextEditor: { document: { uri: uri(entryFile) } }, showQuickPick: async (items) => items[0],
      showWarningMessage: (message) => warnings.push(message), showErrorMessage: (message) => errors.push(message),
      showTextDocument: async (...args) => opened.push(args),
      createWebviewPanel: () => {
        const handlers = new Set(), disposals = new Set();
        const panel = { webview: { html: "", onDidReceiveMessage: (handler) => { handlers.add(handler); return { dispose: () => handlers.delete(handler) }; } },
          onDidDispose: (handler) => { disposals.add(handler); return { dispose: () => disposals.delete(handler) }; },
          message: async (message) => { for (const handler of [...handlers]) await handler(message); }, dispose() { panel.disposed = true; for (const handler of disposals) handler(); } };
        panels.push(panel); return panel;
      },
    },
    languages: {
      registerCompletionItemProvider: (_selector, provider) => { completionProviders.push(provider); return { dispose() {} }; },
      registerCodeLensProvider: (_selector, provider) => { providers.push(provider); return { dispose() {} }; },
      registerCodeActionsProvider: (_selector, provider) => { providers.push(provider); return { dispose() {} }; },
    },
    commands: {
      registerCommand: (name, handler) => { commands.set(name, handler); return { dispose() {} }; },
      executeCommand: async (name, ...args) => {
        if (name === "vscode.diff") { diffs.push(args); return; }
        return commands.get(name)?.(...args);
      },
    },
  };
  const preview = { version: 1, kind: "migration-editor-preview", ok: true, previewId: "retained", database: "App.Main", operation: "refresh", compilable: false,
    revisionBefore: 13, revisionAfter: 13, schemaFiles: [path.join(root, "schema/notes/v-current.tesl")],
    files: [{ path: entryFile, creates: false }],
    diagnostics: { version: 1, diagnostics: [{ code: "MIG003", severity: "error", file: entryFile, start: { line: 0, col: 5 }, message: "Choose a <script>bad()</script> value" }] },
    guidance: [{ diagnosticIndex: 0, guide: { title: "Choose a value", summary: "Keep custom code explicit", options: [{ title: "Typed template", when: "Compiler supported route", example: "Additive [Default count (todo \"Choose Int\")]" }], help: ["Review; never guess values"] } }],
  };
  const client = { sendRequest: async (method, params) => { requests.push({ method, params }); if (params.command === "tesl.generateMigration") return preview; return { before: "before", after: "after" }; } };
  const state = new Map();
  registerMigrationAuthoring(vscode, { subscriptions: [], workspaceState: { get: (key) => state.get(key), update: async (key, value) => value === undefined ? state.delete(key) : state.set(key, value) } }, { getClient: () => client, requireTrustedWorkspace: () => trusted });
  return { root, entryFile, uri, vscode, client, commands, panels, providers, completionProviders, requests, warnings, errors, copies, opened, diffs, preview, state,
    change: (file = entryFile) => { for (const handler of changes) handler({ document: { uri: uri(file) } }); },
    cleanup: () => fs.rmSync(root, { recursive: true, force: true }) };
}

test("migration CodeLens recognizes declarations but not comments or literals", () => {
  assert.deepEqual(migrationLensLocations('# migration = Migration {\ntext = "migration = Migration {"\nmigration = Migration {\nmodule NotesSchema.VCurrent exposing []\n'), [2, 3]);
  assert.deepEqual(migrationLensLocations('text = "continued\nmigration = Migration {\n"\n'), []);
});

test("guide escapes diagnostics/templates and uses nonce-only scripting", () => {
  const html = renderGuide([{ title: '<script>alert(1)</script>', summary: '&"', options: [{ title: "<bad>", when: "choice", example: "</pre><script>bad()</script>" }], help: ["details"] }], 0, "abc123", "Heading", "Overview");
  assert.ok(!html.includes("<script>alert(1)</script>"));
  assert.ok(html.includes("&lt;script&gt;alert(1)&lt;/script&gt;"));
  assert.ok(html.includes("script-src 'nonce-abc123'"));
  assert.ok(html.includes("<details>"));
  assert.equal((html.match(/<button class="primary"/g) || []).length, 1);
  assert.ok(html.includes("Next step"));
});

test("compiler decision guidance is authoritative and not duplicated", () => {
  const preview = { diagnostics: { diagnostics: [{ code: "MIG003", message: "choose" }] }, guidance: [{ diagnosticIndex: 0, decisionId: "hole", guide: { title: "No supported template", options: [] } }], decisions: [{ id: "hole", entity: "Todo", options: [] }] };
  const items = previewItems(preview);
  assert.equal(items.length, 1);
  assert.deepEqual(items[0].options, []);
});

test("old-server preview preserves overview, individual help and retained read-only diffs", async () => {
  const f = fixture();
  try {
    await f.commands.get("tesl.previewMigration")(f.uri(f.entryFile));
    const panel = f.panels[0];
    assert.ok(panel.webview.html.includes("1 proposed files; 1 review items"));
    assert.ok(panel.webview.html.includes("Proposal still has decisions or errors to resolve."));
    assert.ok(!panel.webview.html.includes("<script>bad()</script>"));
    await panel.message({ action: "next" });
    assert.ok(panel.webview.html.includes("Keep custom code explicit"));
    assert.ok(panel.webview.html.includes("&lt;script&gt;bad()&lt;/script&gt;"));
    assert.ok(!panel.webview.html.includes("<script>bad()</script>"));
    assert.ok(panel.webview.html.includes("More help"));
    assert.ok(!panel.webview.html.includes("Copy example/template"));
    assert.deepEqual(f.copies, []);
    await panel.message({ action: "source" });
    assert.equal(f.opened[0][1].selection.start.character, 3); // UTF-8 bytes -> UTF-16
    await panel.message({ action: "diff", index: 0 });
    assert.equal(f.requests[1].params.command, "tesl.migrationPreviewFile");
    assert.deepEqual(f.requests[1].params.arguments, [{ previewId: "retained", path: f.entryFile }]);
    assert.equal(f.diffs.length, 1);
    assert.ok(f.diffs[0][0].toString().startsWith("tesl-migration-preview:"));
    assert.ok(f.diffs[0][1].toString().startsWith("tesl-migration-preview:"));
    assert.equal(f.providers[0].provideTextDocumentContent(f.diffs[0][0]), "before");
    assert.ok(f.requests.every((request) => !/apply/i.test(request.params.command)));
    assert.equal(fs.readFileSync(f.entryFile, "utf8"), "module App exposing []\n");
  } finally { f.cleanup(); }
});

test("preview requires trust; static guidance remains available", async () => {
  const f = fixture(false);
  try {
    await f.commands.get("tesl.previewMigration")(f.uri(f.entryFile));
    assert.equal(f.requests.length, 0);
    assert.equal(f.panels.length, 0);
    f.commands.get("tesl.migrationReference")();
    assert.ok(f.panels[0].webview.html.includes("Migration reference"));
    assert.deepEqual(f.providers[1].provideCodeLenses({ getText: () => "migration = Migration {" }), []);
  } finally { f.cleanup(); }
});

test("preview rejects outside-project paths", async () => {
  const f = fixture();
  try {
    f.preview.files[0].path = path.join(path.dirname(f.root), "outside.tesl");
    await f.commands.get("tesl.previewMigration")(f.uri(f.entryFile));
    await f.panels[0].message({ action: "diff", index: 0 });
    assert.equal(f.requests.length, 1);
    assert.equal(f.diffs.length, 0);
    assert.ok(f.errors.some((message) => message.includes("outside the selected project")));
    assert.equal(inside(f.root, path.join(f.root, "..", "escape.tesl")), false);
  } finally { f.cleanup(); }
});

test("migration lenses expose discoverable guidance and preview commands", () => {
  const f = fixture();
  try {
    const lenses = f.providers[1].provideCodeLenses({ uri: f.uri(f.entryFile), getText: () => "migration = Migration {" });
    assert.deepEqual(lenses.map((lens) => lens.command.command), ["tesl.migrateDatabase"]);
    assert.equal(lenses[0].command.arguments[0].fsPath, f.entryFile);
  } finally { f.cleanup(); }
});


test("expired previews remain read-only and report the stale handle", async () => {
  const f = fixture();
  try {
    await f.commands.get("tesl.previewMigration")(f.uri(f.entryFile));
    f.client.sendRequest = async () => { throw new Error("migration preview expired; request a fresh preview"); };
    await f.panels[0].message({ action: "diff", index: 0 });
    assert.equal(f.diffs.length, 0);
    assert.ok(f.errors.some((message) => message.includes("preview expired")));
    assert.equal(fs.readFileSync(f.entryFile, "utf8"), "module App exposing []\n");
  } finally { f.cleanup(); }
});

test("ambiguous databases are selected explicitly from compiler candidates", async () => {
  const f = fixture();
  try {
    const original = f.client.sendRequest;
    f.client.sendRequest = async (method, params) => {
      if (!params.arguments[0].database) return { ok: false, errors: [{ message: "ambiguous", candidates: [{ database: "App.First", file: f.entryFile }, { database: "App.Second", file: f.entryFile }] }] };
      return original(method, params);
    };
    await f.commands.get("tesl.previewMigration")(f.uri(f.entryFile));
    assert.equal(f.requests[0].params.arguments[0].database, "App.First");
    assert.equal(f.panels.length, 1);
  } finally { f.cleanup(); }
});


test("entry selection can browse beyond the bounded discovery list", async () => {
  const f = fixture();
  try {
    f.vscode.window.showQuickPick = async (items) => items.find((item) => item.browse);
    f.vscode.window.showOpenDialog = async () => [f.uri(f.entryFile)];
    await f.commands.get("tesl.previewMigration")(f.uri(path.join(f.root, "schema", "notes", "v-current.tesl")));
    assert.equal(f.requests[0].params.arguments[0].entryFile, f.entryFile);
    assert.equal(f.panels.length, 1);
    f.vscode.window.showOpenDialog = async () => [f.uri(path.join(path.dirname(f.root), "outside.tesl"))];
    fs.mkdirSync(path.join(f.root, "other"));
    fs.writeFileSync(path.join(f.root, "other", "tesl.toml"), "");
    await f.commands.get("tesl.previewMigration")(f.uri(path.join(f.root, "other", "schema", "notes", "v-current.tesl")));
    assert.equal(f.requests.length, 1);
    assert.ok(f.errors.some((message) => message.includes("inside an open workspace folder")));
  } finally { f.cleanup(); }
});


test("using a compiler option updates the real source then opens custom code and rechecks", async () => {
  const f = fixture();
  try {
    f.client.initializeResult = { capabilities: { executeCommandProvider: { commands: ["tesl.applyMigration"] } } };
    f.preview.inputDigest = "a".repeat(64);
    f.preview.guidance[0].decisionId = "entity:Todo";
    f.preview.guidance[0].guide.options[0].id = "additive-default";
    const selected = { ...f.preview, previewId: "selected", inputDigest: "b".repeat(64) };
    const after = 'module App exposing []\nvalue = todo "Write your converter"\n';
    const fresh = { ...selected, previewId: "rechecked", files: [], guidance: [] };
    let applied = false;
    f.vscode.workspace.openTextDocument = async (uri) => {
      const text = fs.readFileSync(uri.fsPath, "utf8");
      return { uri, lineCount: text.split("\n").length, getText: () => text, lineAt: (line) => ({text:text.split("\n")[line]}), positionAt: (offset) => { const lines=text.slice(0,offset).split("\n");return {line:lines.length-1,character:lines.at(-1).length}; } };
    };
    f.client.sendRequest = async (method, params) => {
      f.requests.push({method,params});
      if (params.command === "tesl.generateMigration") {
        if (params.arguments[0].decisionId) return selected;
        return applied ? fresh : f.preview;
      }
      if (params.command === "tesl.applyMigration") {
        assert.deepEqual(params.arguments, [{previewId:"selected"}]);
        fs.writeFileSync(f.entryFile, after); applied=true;
        return {ok:true,active:false,sourceTransaction:{outcome:"committed",recoveryRequired:false}};
      }
      throw new Error("unexpected command");
    };
    await f.commands.get("tesl.previewMigration")(f.uri(f.entryFile));
    await f.panels[0].message({action:"next"});
    assert.ok(f.panels[0].webview.html.includes("Generate selected plan"));
    assert.ok(f.panels[0].webview.html.includes('name="plan"'));
    await f.panels[0].message({action:"choose",optionIndex:0});
    assert.equal(fs.readFileSync(f.entryFile,"utf8"),after);
    assert.deepEqual(f.requests[1].params.arguments[0], {entryFile:f.entryFile,projectRoot:f.root,decisionId:"entity:Todo",optionId:"additive-default",expectedInputDigest:"a".repeat(64)});
    assert.ok(!JSON.stringify(f.requests[1]).includes("template"));
    assert.equal(f.opened[0][1].selection.start.line,1);
    assert.equal(f.opened[0][1].selection.end.character-f.opened[0][1].selection.start.character,'todo "Write your converter"'.length);
    assert.equal(f.requests.at(-1).params.command,"tesl.generateMigration");
    assert.equal(f.panels[0].disposed,true);
    assert.equal(f.copies.length,0);
  } finally { f.cleanup(); }
});

test("stale compiler choice and recovery-required outcomes never trigger automatic retry", async () => {
 const f=fixture();
 try {
  f.client.initializeResult={capabilities:{executeCommandProvider:{commands:["tesl.applyMigration"]}}};
  f.preview.inputDigest="a".repeat(64);f.preview.guidance[0].decisionId="entity:Todo";f.preview.guidance[0].guide.options[0].id="additive-default";
  let applies=0;
  f.client.sendRequest=async(method,params)=>{f.requests.push({method,params});if(params.command==="tesl.generateMigration"&&params.arguments[0].decisionId)throw new Error("source digest changed");if(params.command==="tesl.generateMigration")return f.preview;if(params.command==="tesl.applyMigration"){applies++;return{ok:false,sourceTransaction:{outcome:"editor-pending",recoveryRequired:true},error:"concurrent user edit preserved"};}};
  await f.commands.get("tesl.previewMigration")(f.uri(f.entryFile));await f.panels[0].message({action:"next"});await f.panels[0].message({action:"choose",optionIndex:0});
  assert.equal(applies,0);assert.ok(f.errors.some(message=>message.includes("source digest changed")));assert.equal(fs.readFileSync(f.entryFile,"utf8"),"module App exposing []\n");
  await f.commands.get("tesl.previewMigration")(f.uri(f.entryFile));const panel=f.panels.at(-1);await panel.message({action:"apply"});
  assert.equal(applies,1);assert.ok(panel.webview.html.includes("Recovery is required"));assert.ok(panel.webview.html.includes("concurrent user edit preserved"));
  await panel.message({action:"apply"});assert.equal(applies,1);
 }finally{f.cleanup();}
});

test("a follow-up preview failure preserves the confirmed source transaction result", async () => {
  const f = fixture();
  try {
    f.client.initializeResult = { capabilities: { executeCommandProvider: { commands: ["tesl.applyMigration"] } } };
    let applied = false;
    f.client.sendRequest = async (_method, params) => {
      if (params.command === "tesl.applyMigration") {
        applied = true;
        return { ok: true, sourceTransaction: { outcome: "committed", recoveryRequired: false } };
      }
      if (applied) throw new Error("follow-up source query failed");
      return f.preview;
    };
    const view = await f.commands.get("tesl.previewMigration")(f.uri(f.entryFile));
    const appliedView = await f.commands.get("tesl.applyMigrationSource")({ previewId: view.previewId });
    assert.equal(appliedView.result.sourceTransaction.outcome, "committed");
    assert.equal(appliedView.error, "follow-up source query failed");
    await assert.rejects(f.commands.get("tesl.applyMigrationSource")({ previewId: view.previewId }), /fresh preview/);
  } finally { f.cleanup(); }
});


test("custom-code selection ignores todo text in comments and strings", () => {
 const source='note = "todo" # todo in comment\n# another todo\nfn convert = todo "Write converter"\n';
 assert.equal(codeHoleOffset(source),source.indexOf('todo "Write'));
 assert.equal(codeHoleOffset('note = "todo" # todo\n'),-1);
 assert.equal(codeHoleOffset('Row { todo: old.todo }\nSchema.todo "ordinary call"\n'), -1);
 assert.equal(codeHoleRange('todo'), undefined);
 const quoted = 'value = (todo "Choose \\"a value\\" here") # keep comment';
 const span = codeHoleRange(quoted);
 assert.equal(quoted.slice(span.start, span.end), 'todo "Choose \\"a value\\" here"');
 assert.equal(quoted.slice(0, span.start) + '"Imported"' + quoted.slice(span.end), 'value = ("Imported") # keep comment');
});

test("schema helpers, frozen snapshots, malformed migrations and application databases expose lenses", () => {
  for (const file of ["/project/schema/notes/v1.tesl", "/project/schema/notes/v-current/checks.tesl", "/project/migrations/notes/v2.tesl"]) {
    assert.deepEqual(migrationLensLocations("# incomplete source\n", file), [0]);
  }
  assert.deepEqual(migrationLensLocations('module App exposing []\ndatabase Main = Database {\n'), [1]);
  assert.deepEqual(migrationLensLocations('# database Main = Database {\n'), []);
});

test("migration lightbulbs lead to checked choices; frozen history only offers guidance", () => {
  const f = fixture();
  try {
    const provider = f.providers[2], doc = { uri: f.uri(f.entryFile) };
    const diagnostic = { code: { value: "MIG003" } };
    const actions = provider.provideCodeActions(doc, null, { diagnostics: [diagnostic] });
    assert.deepEqual(actions.map((action) => action.command.command), ["tesl.migrateDatabase", "tesl.previewMigration"]);
    assert.deepEqual(actions[0].diagnostics, [diagnostic]);
    assert.ok(actions.every((action) => !action.edit));
    assert.deepEqual(provider.provideCodeActions(doc, null, { diagnostics: [{ code: "MIG013" }] }).map((action) => action.command.command), ["tesl.previewMigration"]);
    f.vscode.workspace.isTrusted = false;
    assert.deepEqual(provider.provideCodeActions(doc, null, { diagnostics: [diagnostic] }), []);
  } finally { f.cleanup(); }
});

test("welcome does nothing; Start creates the next revision before inviting schema edits", async () => {
  const f = fixture();
  try {
    f.client.initializeResult = { capabilities: { executeCommandProvider: { commands: ["tesl.applyMigration"] } } };
    f.vscode.window.showQuickPick = async () => { throw new Error("no lifecycle picker"); };
    f.client.sendRequest = async (method, params) => {
      f.requests.push({ method, params });
      if (params.command === "tesl.generateMigration") return { ...f.preview, files: [{ path: path.join(f.root, "migrations/notes/v14.tesl"), creates: true }], operation: params.arguments[0].newRevision ? "start" : "refresh", revisionBefore: params.arguments[0].newRevision ? 13 : 14, revisionAfter: 14, compilable: !!params.arguments[0].newRevision };
      if (params.command === "tesl.applyMigration") return { ok: true, sourceTransaction: { outcome: "committed" } };
    };
    const welcome = await f.commands.get("tesl.migrateDatabase")(f.uri(f.entryFile));
    assert.equal(welcome.stage, "welcome");
    assert.equal(f.requests.length, 0);
    assert.ok(f.panels[0].webview.html.includes("Ready to start"));
    assert.ok(f.panels[0].webview.html.includes("Start migration"));
    assert.ok(!f.panels[0].webview.html.includes("MIG003"));
    const prepared = await f.commands.get("tesl.migrationFlowAction")({ flowId: welcome.flowId, action: "start" });
    assert.equal(prepared.stage, "edit");
    assert.equal(prepared.revision, 14);
    assert.equal([...f.state.values()][0].revision, 14, "remember only the committed draft");
    assert.equal(f.requests[0].params.arguments[0].newRevision, true);
    assert.equal(f.requests[1].params.command, "tesl.applyMigration");
    assert.equal(f.requests.length, 2, "no refresh before user edits");
    assert.ok(f.panels[0].webview.html.includes("draft V14 prepared"));
    assert.ok(f.panels[0].webview.html.includes("Now edit your schema"));
    await f.commands.get("tesl.migrationFlowAction")({ flowId: welcome.flowId, action: "review" });
    assert.equal(f.requests.at(-1).params.arguments[0].newRevision, undefined);
    assert.equal(f.panels.length, 1, "all steps reuse the same panel");
  } finally { f.cleanup(); }
});

test("editing before Start blocks preparation without silently refreshing the old revision", async () => {
  const f = fixture();
  try {
    f.client.sendRequest = async (method, params) => { f.requests.push({ method, params }); throw new Error("current schema source differs from its recorded bytes"); };
    const welcome = await f.commands.get("tesl.migrateDatabase")(f.uri(f.entryFile));
    const result = await f.commands.get("tesl.migrationFlowAction")({ flowId: welcome.flowId, action: "start" });
    assert.equal(result.stage, "blocked");
    assert.equal(result.revision, undefined);
    assert.equal(f.requests.length, 1);
    assert.equal(f.requests[0].params.arguments[0].newRevision, true);
    assert.ok(f.panels[0].webview.html.includes("Not started · preparation blocked"));
    assert.ok(f.panels[0].webview.html.includes("Schema already edited?"));
    assert.equal(f.state.size, 0);
  } finally { f.cleanup(); }
});

test("unconfirmed Start outcome cannot create another revision; status can confirm preparation", async () => {
  const f = fixture();
  try {
    f.client.initializeResult = { capabilities: { executeCommandProvider: { commands: ["tesl.applyMigration"] } } };
    f.client.sendRequest = async (method, params) => {
      f.requests.push({ method, params });
      if (params.command === "tesl.generateMigration") return { ...f.preview, files: [{ path: path.join(f.root, "migrations/notes/v14.tesl"), creates: true }], operation: "start", revisionAfter: 14, compilable: true };
      if (params.command === "tesl.applyMigration") return { ok: false, error: "preserve buffers", sourceTransaction: { outcome: "editor-pending", recoveryRequired: true } };
      if (params.command === "tesl.migrationApplicationStatus") return { ok: true, sourceTransaction: { outcome: "committed" } };
    };
    const welcome = await f.commands.get("tesl.migrateDatabase")(f.uri(f.entryFile));
    const call = (action) => f.commands.get("tesl.migrationFlowAction")({ flowId: welcome.flowId, action });
    assert.equal((await call("start")).stage, "recovery");
    assert.equal(f.state.get(`tesl.migrationDraft:${f.root}`), undefined);
    assert.ok(f.state.get(`tesl.migrationDraft:${f.root}:backup`));
    await call("start");
    assert.equal(f.requests.length, 2, "Start is unavailable while outcome is uncertain");
    assert.equal((await call("status")).stage, "edit");
    assert.equal([...f.state.values()][0].revision, 14);
  } finally { f.cleanup(); }
});

test("remembered drafts reopen with Continue and bind refresh to the recorded revision", async () => {
  const f = fixture();
  try {
    f.state.set(`tesl.migrationDraft:${f.root}`, { entryFile: f.entryFile, projectRoot: f.root, database: "App.Main", revision: 12 });
    const welcome = await f.commands.get("tesl.migrateDatabase")(f.uri(f.entryFile));
    assert.equal(f.requests.length, 0);
    assert.ok(f.panels[0].webview.html.includes("Continue migration V12"));
    const result = await f.commands.get("tesl.migrationFlowAction")({ flowId: welcome.flowId, action: "resume" });
    assert.equal(result.stage, "blocked", "must not relabel V13 as the remembered V12 draft");
    assert.equal(f.requests[0].params.arguments[0].newRevision, undefined);
    assert.equal(f.requests.length, 1);
  } finally { f.cleanup(); }
});

test("a removed legacy draft does not trap the welcome page on a stale revision", async () => {
  const f = fixture();
  try {
    const key = `tesl.migrationDraft:${f.root}`;
    f.state.set(key, { entryFile: f.entryFile, projectRoot: f.root, database: "App.Main", revision: 14, schemaFiles: f.preview.schemaFiles });
    await f.commands.get("tesl.migrateDatabase")(f.uri(f.entryFile));
    assert.ok(f.panels[0].webview.html.includes("Start migration"));
    assert.ok(!f.panels[0].webview.html.includes("Continue migration V14"));
    assert.equal(f.state.has(key), false);
    assert.equal(f.requests.length, 0);
  } finally { f.cleanup(); }
});

test("failed status checks retain recovery state; confirmed restoration permits an explicit retry", async () => {
  const f = fixture();
  try {
    f.client.initializeResult = { capabilities: { executeCommandProvider: { commands: ["tesl.applyMigration"] } } };
    let statusCalls = 0;
    f.client.sendRequest = async (_method, params) => {
      if (params.command === "tesl.generateMigration") return { ...f.preview, files: [{ path: path.join(f.root, "migrations/notes/v14.tesl"), creates: true }], operation: "start", revisionAfter: 14, compilable: true };
      if (params.command === "tesl.applyMigration") return { ok: false, sourceTransaction: { outcome: "editor-pending", recoveryRequired: true } };
      if (params.command === "tesl.migrationApplicationStatus") {
        if (++statusCalls === 1) throw new Error("connection lost");
        return { ok: false, sourceTransaction: { outcome: "restored", recoveryRequired: false } };
      }
    };
    const welcome = await f.commands.get("tesl.migrateDatabase")(f.uri(f.entryFile));
    const call = (action) => f.commands.get("tesl.migrationFlowAction")({ flowId: welcome.flowId, action });
    assert.equal((await call("start")).stage, "recovery");
    assert.equal((await call("status")).stage, "recovery");
    assert.equal((await call("status")).stage, "blocked");
    assert.ok(f.panels[0].webview.html.includes("No new revision was created"));
    assert.equal(f.state.size, 0);
  } finally { f.cleanup(); }
});

test("Save and run tests saves only this project's Tesl buffers and rechecks before requesting tests", async () => {
  const f = fixture();
  try {
    f.preview.compilable = true; f.preview.files = []; f.preview.diagnostics.diagnostics = [];
    const events = [];
    const doc = (file) => ({ uri: { ...f.uri(file), scheme: "file" }, isDirty: true, languageId: "tesl", async save() { events.push(file); this.isDirty = false; return true; } });
    f.vscode.workspace.textDocuments = [doc(f.entryFile), doc(path.join(path.dirname(f.root), "outside.tesl"))];
    f.commands.set("tesl.runTests", async (uri) => events.push(`tests:${uri.fsPath}`));
    const welcome = await f.commands.get("tesl.migrateDatabase")(f.uri(f.entryFile));
    assert.equal((await f.commands.get("tesl.migrationFlowAction")({ flowId: welcome.flowId, action: "resume" })).stage, "ready");
    await f.commands.get("tesl.migrationFlowAction")({ flowId: welcome.flowId, action: "tests" });
    assert.deepEqual(events, [f.entryFile, `tests:${f.entryFile}`]);
    assert.equal(f.requests.length, 3, "test action rechecks before and after tests");
    assert.ok(f.panels[0].webview.html.includes("See Test Results"));
    events.length = 0;
    f.vscode.workspace.textDocuments[0].isDirty = true;
    f.preview.cleanup = [{ version: 13, present: false }];
    const changed = await f.commands.get("tesl.migrationFlowAction")({ flowId: welcome.flowId, action: "tests" });
    assert.equal(changed.stage, "cleanup-needed");
    assert.deepEqual(events, [f.entryFile], "missing cleanup discovered during recheck returns to review");
  } finally { f.cleanup(); }
});

test("passed tests offer Finish; closing or finishing offers a new migration without discarding source", async () => {
  for (const finish of [false, true]) {
    const f = fixture();
    try {
      f.preview.compilable = true; f.preview.files = []; f.preview.diagnostics.diagnostics = [];
      f.preview.inputDigest = "a".repeat(64);
      const key = `tesl.migrationDraft:${f.root}`;
      f.state.set(`${key}:backup`, { private: "original source backup" });
      let complete;
      f.commands.set("tesl.runTests", async () => {
        const result = await new Promise((resolve) => { complete = resolve; });
        fs.mkdirSync(path.join(f.root, ".tesl-stuff"));
        fs.writeFileSync(path.join(f.root, ".tesl-stuff/generated.tesl"), "generated test artifact");
        f.preview.inputDigest = "b".repeat(64);
        return result;
      });
      const welcome = await f.commands.get("tesl.migrateDatabase")(f.uri(f.entryFile));
      const call = (action) => f.commands.get("tesl.migrationFlowAction")({ flowId: welcome.flowId, action });
      await call("resume");
      const run = call("tests");
      while (!complete) await new Promise((resolve) => setImmediate(resolve));
      assert.ok(f.panels[0].webview.html.includes("Running application tests"));
      complete({ kind: "tesl-test-result", status: "passed", count: 1 });
      assert.equal((await run).testStatus, "passed");
      assert.ok(f.panels[0].webview.html.includes('class="primary" data-action="finish"'));
      assert.equal(f.state.get(key).status, "complete");
      if (finish) {
        assert.equal((await call("finish")).stage, "finished");
        assert.equal(f.state.has(key), false);
        assert.equal(f.state.has(`${key}:backup`), false);
      } else f.panels[0].dispose();
      const reopened = await f.commands.get("tesl.migrateDatabase")(f.uri(f.entryFile));
      assert.equal(reopened.stage, "welcome");
      assert.ok(f.panels.at(-1).webview.html.includes('class="primary" data-action="start"'));
      assert.ok(!f.panels.at(-1).webview.html.includes("Continue migration V13"));
      assert.equal(fs.readFileSync(f.entryFile, "utf8"), "module App exposing []\n");
    } finally { f.cleanup(); }
  }
});

test("failed, cancelled, empty, unreported and stale tests never mark a draft complete", async () => {
  for (const status of ["failed", "cancelled", "empty", "unknown", "stale", "external-edit"]) {
    const f = fixture();
    try {
      f.preview.compilable = true; f.preview.files = []; f.preview.diagnostics.diagnostics = [];
      f.preview.inputDigest = "a".repeat(64);
      f.commands.set("tesl.runTests", async () => {
        if (status === "stale") f.change();
        if (status === "external-edit") fs.appendFileSync(f.entryFile, "# edited by another process\n");
        return status === "unknown" ? undefined : { kind: "tesl-test-result", status: ["stale", "external-edit"].includes(status) ? "passed" : status, count: 1 };
      });
      const welcome = await f.commands.get("tesl.migrateDatabase")(f.uri(f.entryFile));
      const call = (action) => f.commands.get("tesl.migrationFlowAction")({ flowId: welcome.flowId, action });
      await call("resume");
      assert.equal((await call("tests")).testStatus, status === "external-edit" ? "stale" : status);
      assert.notEqual(f.state.get(`tesl.migrationDraft:${f.root}`).status, "complete");
      assert.ok(!f.panels[0].webview.html.includes("Application tests passed"));
    } finally { f.cleanup(); }
  }
});

test("Finish rechecks source and keeps draft and backup when cleanup is missing", async () => {
  const f = fixture();
  try {
    f.preview.compilable = true; f.preview.files = []; f.preview.diagnostics.diagnostics = [];
    const key = `tesl.migrationDraft:${f.root}`;
    f.state.set(`${key}:backup`, { private: "original" });
    const welcome = await f.commands.get("tesl.migrateDatabase")(f.uri(f.entryFile));
    const call = (action) => f.commands.get("tesl.migrationFlowAction")({ flowId: welcome.flowId, action });
    await call("resume");
    f.preview.cleanup = [{ version: 13, present: false }];
    assert.equal((await call("finish")).stage, "cleanup-needed");
    assert.ok(f.state.has(key)); assert.ok(f.state.has(`${key}:backup`));
    assert.ok(!f.panels[0].disposed);
  } finally { f.cleanup(); }
});

test("source edits replace stale hole navigation with a primary recheck action", async () => {
  const f = fixture();
  try {
    const welcome = await f.commands.get("tesl.migrateDatabase")(f.uri(f.entryFile));
    await f.commands.get("tesl.migrationFlowAction")({ flowId: welcome.flowId, action: "resume" });
    f.change();
    assert.ok(f.panels[0].webview.html.includes("You edited the source since this review"));
    assert.ok(f.panels[0].webview.html.includes('class="primary" data-action="review"'));
    assert.ok(!f.panels[0].webview.html.includes('class="primary" data-action="edit"'));
    f.preview.compilable = true; f.preview.files = []; f.preview.diagnostics.diagnostics = [];
    assert.equal((await f.commands.get("tesl.migrationFlowAction")({ flowId: welcome.flowId, action: "review" })).stage, "ready");
  } finally { f.cleanup(); }
});

test("guide resolves the nearest configured application from a schema in a repository workspace", async () => {
  const f = fixture();
  try {
    const project = path.join(f.root, "example", "db-migration-example");
    fs.mkdirSync(project, { recursive: true });
    fs.writeFileSync(path.join(project, "tesl.toml"), '[project]\nentrypoint = "todo-app.tesl"\n');
    fs.writeFileSync(path.join(project, "todo-app.tesl"), "module TodoApp exposing []\n");
    const schema = f.uri(path.join(project, "schema", "todo", "v-current.tesl"));
    f.vscode.window.activeTextEditor.document.uri = schema;
    f.vscode.window.showQuickPick = async () => { throw new Error("must use the nearest manifest"); };
    f.vscode.workspace.findFiles = async () => { throw new Error("must not scan the repository"); };
    const welcome = await f.commands.get("tesl.migrationGuide")();
    assert.equal(f.requests.length, 0);
    const result = await f.commands.get("tesl.migrationFlowAction")({ flowId: welcome.flowId, action: "resume" });
    assert.equal(result.entryFile, path.join(project, "todo-app.tesl"));
    assert.equal(f.requests[0].params.arguments[0].projectRoot, project);
    const html = f.panels[0].webview.html;
    assert.ok(html.includes("draft V13"));
    assert.ok(html.includes("Keep custom code explicit"));
    assert.ok(!html.includes("Review proof identity"));
    assert.equal(f.errors.length, 0);
  } finally { f.cleanup(); }
});

test("repeated compiler errors become one relevant guide item", () => {
  const diagnostic = { file: "/project/migrations/todo/v13.tesl", code: "MIG024", severity: "error", start: { line: 20, col: 9 }, message: "Same differs" };
  const items = previewItems({ diagnostics: { diagnostics: [diagnostic, diagnostic, { ...diagnostic, start: { line: 30, col: 9 } }] } });
  assert.equal(items.length, 2);
  assert.equal(items[0].code, "MIG024");
});

test("one primary action per guide state; plans require selection and navigation stays secondary", () => {
  const decision = { title: "Choose Todo behavior", decisionId: "entity:Todo", file: "/project/v2.tesl", options: [{ id: "migrate-validators", title: "Use validators", when: "Review the fallback" }, { id: "migrate-retype", title: "Custom conversion", when: "Write the conversion" }] };
  for (const [items, index, controls] of [
    [[decision], 0, { canChoose: true, canApply: true }],
    [[{ code: "MIG024", title: "Same differs", file: "/project/v13.tesl" }], 0, { canApply: true }],
    [[{ code: "MIG003", title: "Choose a literal", file: "/project/v2.tesl" }], 0, {}],
    [[], -1, { canApply: true }], [[], -1, {}], [[decision], -1, {}],
    [[decision], 0, { consumed: true, canStatus: true }],
  ]) {
    const html = renderGuide(items, index, "nonce", "Guide", "This application", controls);
    assert.equal((html.match(/<button class="primary"/g) || []).length, 1, html);
    assert.ok(html.includes('class="secondary" data-action="refresh"'));
    if (controls.canChoose) {
      assert.ok(html.includes('id="generate-plan" disabled'));
      assert.ok(!html.includes('name="plan" checked'));
      assert.ok(!html.includes("Use this option and update source"));
    }
  }
});

test("opening a diagnostic source never silently applies proposed files", async () => {
  const f = fixture();
  try {
    f.client.initializeResult = { capabilities: { executeCommandProvider: { commands: ["tesl.applyMigration"] } } };
    f.preview.diagnostics.diagnostics[0].code = "MIG024";
    await f.commands.get("tesl.previewMigration")(f.uri(f.entryFile));
    await f.panels[0].message({ action: "next" });
    assert.ok(f.panels[0].webview.html.includes("Open invalid Same claim"));
    await f.panels[0].message({ action: "source" });
    assert.equal(f.opened.length, 1);
    assert.equal(f.requests.length, 1, "source navigation makes no application request");
  } finally { f.cleanup(); }
});

test("cancelling Migrate database does not request or apply a proposal", async () => {
  const f = fixture();
  try {
    f.vscode.window.showQuickPick = async () => undefined;
    await f.commands.get("tesl.migrateDatabase")();
    assert.equal(f.requests.length, 0);
  } finally { f.cleanup(); }
});

test("first-use completion explains setup; known projects offer whole compiler scaffolds without editing text", async () => {
  const f = fixture();
  try {
    const document = { uri: f.uri(path.join(f.root, "migrations/notes/v2.tesl")), version: 4, lineAt: () => ({ text: '  Note: todo "Choose migration"' }) };
    const position = { line: 10, character: 9 }, token = { isCancellationRequested: false };
    const provider = f.completionProviders[0];
    let items = await provider.provideCompletionItems(document, position, token);
    assert.equal(items[0].command.command, "tesl.migrateDatabase");
    assert.equal(f.requests.length, 0);
    f.client.initializeResult = { capabilities: { executeCommandProvider: { commands: ["tesl.applyMigration"] } } };
    f.preview.inputDigest = "a".repeat(64);
    f.preview.decisions = [{ id: "entity:Note", entity: "Note", file: document.uri.fsPath, line: 10, options: [{ id: "migrate-validators", label: "Reuse validators", help: "Fill rejection and fallback policy" }] }];
    await f.commands.get("tesl.previewMigration")(f.uri(f.entryFile));
    items = await provider.provideCompletionItems(document, position, token);
    assert.equal(items.length, 1);
    assert.equal(items[0].label, "Note: Reuse validators");
    assert.equal(items[0].insertText, "");
    assert.deepEqual(items[0].range.start, items[0].range.end);
    assert.equal(items[0].command.command, "tesl.completeMigrationDecision");
    assert.deepEqual(items[0].command.arguments, [{ previewId: "retained", decisionId: "entity:Note", optionId: "migrate-validators" }]);
    assert.equal(f.panels.length, 1, "completion does not create a webview");
    assert.equal(f.requests.at(-1).params.arguments[0].database, "App.Main");
    token.isCancellationRequested = true;
    assert.deepEqual(await provider.provideCompletionItems(document, position, token), []);
    document.lineAt = () => ({ text: '# Note: todo "Comment"' });
    assert.deepEqual(await provider.provideCompletionItems(document, position, token), []);
  } finally { f.cleanup(); }
});
