"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const os = require("node:os");
const fs = require("node:fs");
const { registerMigrationAuthoring, migrationLensLocations, previewItems, renderGuide, inside, codeHoleOffset } = require("./migration-authoring");

function fixture(trusted = true) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "tesl-migration-editor-"));
  const entryFile = path.join(root, "app.tesl");
  fs.writeFileSync(entryFile, "module App exposing []\n");
  fs.writeFileSync(path.join(root, "tesl.toml"), "");
  const commands = new Map(), panels = [], providers = [], requests = [], warnings = [], errors = [], copies = [], opened = [], diffs = [];
  const uri = (file) => ({ fsPath: file, toString: () => file });
  const vscode = {
    Uri: { file: uri, parse: uri }, ViewColumn: { Beside: 2 },
    Range: class { constructor(a, b, c, d) { this.start = { line: a, character: b }; this.end = { line: c, character: d }; } },
    CodeLens: class { constructor(range, command) { this.range = range; this.command = command; } },
    env: { clipboard: { writeText: async (text) => copies.push(text) } },
    workspace: {
      isTrusted: trusted, getWorkspaceFolder: () => ({ uri: uri(root) }), asRelativePath: (file) => path.relative(root, file.fsPath),
      findFiles: async () => [uri(entryFile)], openTextDocument: async () => ({ lineCount: 1, lineAt: () => ({ text: "🌱 title" }) }),
      registerTextDocumentContentProvider: (_scheme, provider) => { providers.push(provider); return { dispose() {} }; },
    },
    window: {
      activeTextEditor: { document: { uri: uri(entryFile) } }, showQuickPick: async (items) => items[0],
      showWarningMessage: (message) => warnings.push(message), showErrorMessage: (message) => errors.push(message),
      showTextDocument: async (...args) => opened.push(args),
      createWebviewPanel: () => {
        const panel = { webview: { html: "", onDidReceiveMessage: (handler) => { panel.message = handler; } }, dispose() { panel.disposed = true; } };
        panels.push(panel); return panel;
      },
    },
    languages: { registerCodeLensProvider: (_selector, provider) => { providers.push(provider); return { dispose() {} }; } },
    commands: {
      registerCommand: (name, handler) => { commands.set(name, handler); return { dispose() {} }; },
      executeCommand: async (name, ...args) => {
        if (name === "vscode.diff") { diffs.push(args); return; }
        return commands.get(name)?.(...args);
      },
    },
  };
  const preview = { version: 1, kind: "migration-editor-preview", ok: true, previewId: "retained", database: "App.Main", operation: "refresh", compilable: false,
    files: [{ path: entryFile, creates: false }],
    diagnostics: { version: 1, diagnostics: [{ code: "MIG003", severity: "error", file: entryFile, start: { line: 0, col: 5 }, message: "Choose a <script>bad()</script> value" }] },
    guidance: [{ diagnosticIndex: 0, guide: { title: "Choose a value", summary: "Keep custom code explicit", options: [{ title: "Typed template", when: "Compiler supported route", example: "Additive [Default count (todo \"Choose Int\")]" }], help: ["Review; never guess values"] } }],
  };
  const client = { sendRequest: async (method, params) => { requests.push({ method, params }); if (params.command === "tesl.generateMigration") return preview; return { before: "before", after: "after" }; } };
  registerMigrationAuthoring(vscode, { subscriptions: [] }, { getClient: () => client, requireTrustedWorkspace: () => trusted });
  return { root, entryFile, uri, vscode, client, commands, panels, providers, requests, warnings, errors, copies, opened, diffs, preview,
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
  assert.ok(html.includes('data-action="next"'));
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
    f.commands.get("tesl.migrationGuide")();
    assert.ok(f.panels[0].webview.html.includes("Migration authoring guide"));
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
    assert.deepEqual(lenses.map((lens) => lens.command.command), ["tesl.migrationGuide", "tesl.previewMigration"]);
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
    await f.commands.get("tesl.previewMigration")(f.uri(path.join(f.root, "schema", "notes", "v-current.tesl")));
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
    assert.ok(f.panels[0].webview.html.includes("Use this option and update source"));
    await f.panels[0].message({action:"choose",optionIndex:0});
    assert.equal(fs.readFileSync(f.entryFile,"utf8"),after);
    assert.deepEqual(f.requests[1].params.arguments[0], {entryFile:f.entryFile,projectRoot:f.root,decisionId:"entity:Todo",optionId:"additive-default",expectedInputDigest:"a".repeat(64)});
    assert.ok(!JSON.stringify(f.requests[1]).includes("template"));
    assert.equal(f.opened[0][1].selection.start.line,1);
    assert.equal(f.opened[0][1].selection.end.character-f.opened[0][1].selection.start.character,4);
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


test("custom-code selection ignores todo text in comments and strings", () => {
 const source='note = "todo" # todo in comment\n# another todo\nfn convert = todo "Write converter"\n';
 assert.equal(codeHoleOffset(source),source.indexOf('todo "Write'));
 assert.equal(codeHoleOffset('note = "todo" # todo\n'),-1);
});
