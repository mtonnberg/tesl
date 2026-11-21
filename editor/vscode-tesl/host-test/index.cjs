"use strict";
// Runs inside the real VS Code/VSCodium extension host. It invokes the same
// product commands as webview choices, using the real LSP/compiler and editor API.
const vscode = require("vscode");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

exports.run = async () => {
  const root = process.env.TESL_MIGRATION_HOST_PROJECT;
  const evidence = { host: vscode.version, checks: [] };
  const entry = path.join(root, "todo-app.tesl"), current = path.join(root, "schema/notes/v-current.tesl");
  const migration = path.join(root, "migrations/notes/v2.tesl");
  const replaceDocument = async (document, text) => {
    const editor = await vscode.window.showTextDocument(document, { preview: false });
    const end = document.positionAt(document.getText().length);
    assert.equal(await editor.edit((edit) => edit.replace(new vscode.Range(0, 0, end.line, end.character), text)), true);
  };
  try {
    const extension = vscode.extensions.getExtension("Tesl.vscode-tesl");
    assert.ok(extension, "development extension is available");
    await extension.activate();
    assert.ok((await vscode.commands.getCommands(true)).includes("tesl.migrateDatabase"));
    const schema = await vscode.workspace.openTextDocument(vscode.Uri.file(current));
    await vscode.window.showTextDocument(schema, { preview: false });
    const welcome = await vscode.commands.executeCommand("tesl.migrateDatabase");
    assert.equal(welcome?.kind, "migration-authoring-flow");
    assert.equal(welcome.stage, "welcome");
    assert.equal(fs.existsSync(migration), false, "opening welcome never prepares a migration");
    const initial = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: welcome.flowId, action: "start" });
    assert.equal(initial.stage, "edit", JSON.stringify(initial));
    assert.equal(initial.revision, 2);
    assert.equal(initial.entryFile, entry);
    assert.equal(initial.projectRoot, root);
    evidence.checks.push("welcome is inert; Start resolves the nested project and prepares the next revision before inviting schema edits");
    assert.equal(fs.existsSync(path.join(root, "schema/notes/v1.tesl")), true);
    assert.equal(fs.existsSync(migration), true);
    evidence.checks.push("initial proposal creates real frozen schema and migration files through the editor transaction");

    const schemaDisk = fs.readFileSync(current, "utf8");
    const lenses = await vscode.commands.executeCommand("vscode.executeCodeLensProvider", schema.uri);
    assert.ok(lenses.some((lens) => lens.command?.command === "tesl.migrateDatabase" && lens.command.arguments[0].fsPath === current));
    evidence.checks.push("the real editor exposes migration CodeLens on VCurrent");
    await replaceDocument(schema, schemaDisk.replace("{ id: String }", "{ id: String, title: String }"));
    assert.equal(schema.isDirty, true);
    let stale;
    for (let attempt = 0; attempt < 100; attempt++) {
      stale = vscode.languages.getDiagnostics(schema.uri).find((item) => (item.code?.value ?? item.code) === "MIG001");
      if (stale) break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    assert.ok(stale, "unsaved schema change publishes a migration diagnostic");
    assert.equal(stale.severity, vscode.DiagnosticSeverity.Warning);
    assert.ok(!stale.range.isEmpty, "file-level migration warning has visible underline text");
    const actions = await vscode.commands.executeCommand("vscode.executeCodeActionProvider", schema.uri, stale.range, vscode.CodeActionKind.QuickFix.value);
    assert.ok(actions.some((action) => action.command?.command === "tesl.migrateDatabase"));
    evidence.checks.push("unsaved schema changes have warning squiggles and a Migrate database lightbulb in the real editor");
    const draft = await vscode.workspace.openTextDocument(vscode.Uri.file(migration));
    const migrationDisk = fs.readFileSync(migration, "utf8");
    const sameLine = draft.getText().split("\n").findIndex((line) => line.includes("same: ["));
    const sameCol = draft.lineAt(sameLine).text.indexOf("[") + 1;
    const completions = await vscode.commands.executeCommand("vscode.executeCompletionItemProvider", draft.uri, new vscode.Position(sameLine, sameCol));
    assert.ok(completions.items.some((item) => item.label === "Same"));
    evidence.checks.push("migration Same completion travels through the real language client and compiler");
    await replaceDocument(draft, draft.getText() + "\n# Handwritten unsaved migration note\n");
    let view = await vscode.commands.executeCommand("tesl.previewMigration", vscode.Uri.file(entry));
    const decision = view.decisions.find((item) => item.options.some((option) => option.id === "additive-default"));
    assert.ok(decision, JSON.stringify(view));
    assert.match(view.inputDigest, /^[0-9a-f]{64}$/);

    // A real edit after review must invalidate that view's compiler digest.
    await replaceDocument(draft, draft.getText() + "# Concurrent user edit after preview\n");
    const userText = draft.getText();
    await assert.rejects(vscode.commands.executeCommand("tesl.applyMigrationChoice", { previewId: view.previewId, decisionId: decision.id, optionId: "additive-default" }), /changed|digest|fresh|stale/i);
    assert.equal(draft.getText(), userText);
    assert.equal(fs.readFileSync(migration, "utf8"), migrationDisk);
    evidence.checks.push("a source edit after preview refuses the stale choice and preserves user text and disk");

    view = await vscode.commands.executeCommand("tesl.previewMigration", vscode.Uri.file(entry));
    const prepared = await vscode.commands.executeCommand("tesl.applyMigrationSource", { previewId: view.previewId });
    assert.equal(prepared?.result?.sourceTransaction?.outcome, "committed", JSON.stringify(prepared));
    const holeLine = prepared.nextView.decisions.find((item) => item.options.some((option) => option.id === "additive-default"))?.line;
    assert.ok(Number.isInteger(holeLine), "generated migration exposes a decision hole");
    const holePosition = new vscode.Position(holeLine, draft.lineAt(holeLine).text.indexOf("todo"));
    const plans = await vscode.commands.executeCommand("vscode.executeCompletionItemProvider", draft.uri, holePosition);
    assert.ok(plans.items.some((item) => item.command?.command === "tesl.completeMigrationDecision"), "Ctrl+Space offers full compiler migration plans");
    const editor = await vscode.window.showTextDocument(draft, { preview: false });
    editor.selection = new vscode.Selection(holePosition, holePosition);
    await vscode.commands.executeCommand("editor.action.triggerSuggest");
    await new Promise((resolve) => setTimeout(resolve, 1000));
    await vscode.commands.executeCommand("acceptSelectedSuggestion");
    for (let attempt = 0; attempt < 150 && !/Default title \(todo/.test(draft.getText()); attempt++) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    assert.match(draft.getText(), /Default title \(todo/);
    evidence.checks.push("accepting a full migration completion applies the guarded compiler scaffold without manual syntax or copy/paste");
    assert.ok(draft.getText().includes("Handwritten unsaved migration note"));
    assert.ok(draft.getText().includes("Concurrent user edit after preview"));
    assert.equal(draft.isDirty, true);
    assert.equal(schema.isDirty, true);
    assert.equal(fs.readFileSync(migration, "utf8"), migrationDisk);
    assert.equal(fs.readFileSync(current, "utf8"), schemaDisk);
    evidence.checks.push("choosing an option updates the real dirty migration buffer while preserving handwritten edits and unsaved disk preimages");
    // Wait for the command's follow-up preview and custom-code selection.
    for (let attempt = 0; attempt < 100 && !/^todo "/.test(draft.getText(vscode.window.activeTextEditor.selection)); attempt++) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    assert.equal(vscode.window.activeTextEditor.document.uri.toString(), draft.uri.toString());
    assert.match(draft.getText(vscode.window.activeTextEditor.selection), /^todo ".*"$/);
    const domainSelection = vscode.window.activeTextEditor.selection;
    const incomplete = await vscode.commands.executeCommand("tesl.previewMigration", vscode.Uri.file(entry));
    assert.equal(incomplete.compilable, false);
    evidence.checks.push("the actual custom-code hole is selected and the complete application is rechecked as incomplete");

    await vscode.window.showTextDocument(draft, { preview: false, selection: domainSelection });
    assert.equal(await vscode.window.activeTextEditor.edit((edit) => edit.replace(vscode.window.activeTextEditor.selection, '"Imported"')), true);
    const checked = await vscode.commands.executeCommand("tesl.previewMigration", vscode.Uri.file(entry));
    assert.ok(checked, draft.getText());
    assert.equal(checked.compilable, true, JSON.stringify(checked));
    await schema.save(); await draft.save();
    assert.ok(fs.readFileSync(migration, "utf8").includes('Default title ("Imported")'));
    assert.ok(fs.readFileSync(current, "utf8").includes("title: String"));
    evidence.checks.push("completing custom code makes the real compiler preview valid and explicit saves persist the updated files");
    const sourceReady = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: welcome.flowId, action: "review" });
    assert.equal(sourceReady.stage, "ready", JSON.stringify(sourceReady));
    const tested = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: welcome.flowId, action: "tests" });
    assert.equal(tested.testStatus, "passed", JSON.stringify(tested));
    const finished = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: welcome.flowId, action: "finish" });
    assert.equal(finished.stage, "finished", JSON.stringify(finished));
    assert.equal(fs.existsSync(migration), true, "Finish keeps the completed revision");
    const nextWelcome = await vscode.commands.executeCommand("tesl.migrateDatabase", schema.uri);
    assert.equal(nextWelcome.stage, "welcome");
    const nextDraft = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: nextWelcome.flowId, action: "start" });
    assert.equal(nextDraft.stage, "edit", JSON.stringify(nextDraft));
    assert.equal(nextDraft.revision, 3);
    await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: nextWelcome.flowId, action: "cancel" });
    const nextCancelled = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: nextWelcome.flowId, action: "confirmCancel" });
    assert.equal(nextCancelled.stage, "cancelled", JSON.stringify(nextCancelled));
    assert.ok(fs.readFileSync(migration, "utf8").includes('Default title ("Imported")'), "cancelling the next draft preserves the finished revision");
    evidence.checks.push("real application tests report success; Finish preserves source and reopening starts the next revision rather than resuming the completed draft");

    // Reproduce the reported V13 -> V14 journey using a temporary copy of the
    // real example, through the same workflow actions exposed by its buttons.
    const example = process.env.TESL_MIGRATION_HOST_EXAMPLE;
    const exampleCurrent = path.join(example, "schema/todo/v-current.tesl");
    const exampleEntry = path.join(example, "todo-app.tesl");
    const v14 = path.join(example, "migrations/todo/v14.tesl");
    const exampleSchema = await vscode.workspace.openTextDocument(vscode.Uri.file(exampleCurrent));
    await vscode.window.showTextDocument(exampleSchema, { preview: false });
    const before = exampleSchema.getText();
    const originalMigration = fs.readFileSync(path.join(example, "migrations/todo/v13.tesl"), "utf8");
    const exampleWelcome = await vscode.commands.executeCommand("tesl.migrateDatabase", exampleSchema.uri);
    assert.equal(exampleWelcome.stage, "welcome");
    assert.equal(fs.existsSync(v14), false);
    const examplePrepared = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: exampleWelcome.flowId, action: "start" });
    assert.equal(examplePrepared.stage, "edit", JSON.stringify(examplePrepared));
    assert.equal(examplePrepared.revision, 14);
    assert.equal(fs.existsSync(path.join(example, "schema/todo/v13.tesl")), true);
    assert.equal(fs.existsSync(v14), true);
    assert.equal(exampleSchema.getText(), before, "Start freezes the old shape without changing domain fields");
    const changed = before.replace("  details: Maybe String", "  details: String")
      .replace('completed: False, details: Nothing', 'completed: False, details: ""');
    assert.notEqual(changed, before);
    await replaceDocument(exampleSchema, changed);
    const reviewed = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: exampleWelcome.flowId, action: "review" });
    assert.equal(reviewed.stage, "review", JSON.stringify(reviewed));
    const defaultPlan = reviewed.view.decisions.find((item) => item.options.some((option) => option.id === "require-value"));
    assert.ok(defaultPlan, JSON.stringify(reviewed));
    assert.equal(defaultPlan.file, v14, "new domain decisions belong to V14, not V13");
    assert.ok(defaultPlan.reason.includes("details is now required"));
    assert.ok(!defaultPlan.reason.includes("old row fields"));
    const generated = await vscode.commands.executeCommand("tesl.applyMigrationChoice", { previewId: reviewed.previewId, decisionId: defaultPlan.id, optionId: "require-value" });
    assert.equal(generated.result.sourceTransaction.outcome, "committed");
    let ready;
    for (const value of ['"No details"', '"Historical title"', '"fixture-id"']) {
      const domainEditor = vscode.window.activeTextEditor;
      assert.equal(domainEditor.document.uri.fsPath, v14);
      assert.match(domainEditor.document.getText(domainEditor.selection), /^todo "/);
      assert.equal(await domainEditor.edit((edit) => edit.replace(domainEditor.selection, value)), true);
      ready = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: exampleWelcome.flowId, action: "review" });
      if (!["ready", "cleanup-needed"].includes(ready.stage)) {
        assert.ok(ready.view.diagnostics.diagnostics.every((item) => item.code === "MIG003"), JSON.stringify(ready));
        await vscode.commands.executeCommand("tesl.editMigrationHole", { previewId: ready.previewId });
      }
    }
    assert.equal(ready.stage, "cleanup-needed", JSON.stringify(ready));
    const cleanup = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: exampleWelcome.flowId, action: "cleanup" });
    assert.equal(cleanup.stage, "cleanup", JSON.stringify(cleanup));
    assert.equal(fs.existsSync(path.join(example, "migrations/todo/v14-contract.tesl")), false);
    const cleanupApplied = await vscode.commands.executeCommand("tesl.applyMigrationSource", { previewId: cleanup.previewId });
    assert.equal(cleanupApplied.result.sourceTransaction.outcome, "committed");
    ready = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: exampleWelcome.flowId, action: "review" });
    assert.equal(ready.stage, "ready", JSON.stringify(ready));
    assert.equal(ready.view.compilable, true);
    assert.equal(ready.entryFile, exampleEntry);
    evidence.checks.push("real Maybe String -> String migration needs only a missing-value string and two historical example strings; all migration, proof and fixture boilerplate is generated");
    let navigation = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: exampleWelcome.flowId, action: "back" });
    assert.equal(navigation.stage, "review");
    navigation = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: exampleWelcome.flowId, action: "back" });
    assert.equal(navigation.stage, "edit");
    assert.ok(exampleSchema.getText().includes("details: String"), "Back must not undo domain edits");
    const appDoc = await vscode.workspace.openTextDocument(vscode.Uri.file(exampleEntry));
    await replaceDocument(appDoc, appDoc.getText() + "\n# unrelated application work\n");
    const cancel = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: exampleWelcome.flowId, action: "cancel" });
    assert.equal(cancel.stage, "cancel");
    assert.equal(fs.existsSync(v14), true, "Cancel first shows the files to discard");
    const cancelled = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: exampleWelcome.flowId, action: "confirmCancel" });
    assert.equal(cancelled.stage, "cancelled", JSON.stringify(cancelled));
    assert.equal(exampleSchema.getText(), before);
    assert.equal(fs.readFileSync(exampleCurrent, "utf8"), before);
    assert.equal(fs.readFileSync(path.join(example, "migrations/todo/v13.tesl"), "utf8"), originalMigration);
    assert.equal(fs.existsSync(v14), false);
    assert.equal(fs.existsSync(path.join(example, "schema/todo/v13.tesl")), false);
    assert.equal(fs.existsSync(path.join(example, "migrations/todo/v14-contract.tesl")), false);
    assert.ok(appDoc.getText().includes("unrelated application work"));
    assert.equal(appDoc.isDirty, true);
    evidence.checks.push("Back preserves edits; confirmed Cancel restores the exact pre-Start schema/history and removes draft files while preserving unrelated dirty app work");
    evidence.checks.push("the compiler identifies missing cleanup; the editor previews and applies its checked source before reporting source ready");

    const queueRoot = process.env.TESL_MIGRATION_HOST_QUEUE;
    const queueSchema = await vscode.workspace.openTextDocument(vscode.Uri.file(path.join(queueRoot, "schema/notes/v-current.tesl")));
    const queueBefore = queueSchema.getText();
    const queueWelcome = await vscode.commands.executeCommand("tesl.migrateDatabase", queueSchema.uri);
    const queueStart = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: queueWelcome.flowId, action: "start" });
    assert.equal(queueStart.stage, "edit", JSON.stringify(queueStart));
    await replaceDocument(queueSchema, queueBefore.replace("text: String", "body: String, priority: Int")
      .replace('text -> "text" with_codec stringCodec', 'body -> "message" with_codec stringCodec, priority -> "priority" with_codec intCodec')
      .replace('text <- "text" with_codec stringCodec', 'body <- "message" with_codec stringCodec, priority <- "priority" with_codec intCodec'));
    let queueReview = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: queueWelcome.flowId, action: "review" });
    const queuePlan = queueReview.view.decisions.find((item) => item.options.some((option) => option.id === "map-queued-payload"));
    assert.ok(queuePlan, JSON.stringify(queueReview));
    const queueApplied = await vscode.commands.executeCommand("tesl.applyMigrationChoice", { previewId: queueReview.previewId, decisionId: queuePlan.id, optionId: "map-queued-payload" });
    assert.equal(queueApplied.result.sourceTransaction.outcome, "committed");
    const queueHelper = vscode.window.activeTextEditor.document.uri.fsPath;
    assert.ok(queueHelper.includes("/v2/author-notify.tesl"), queueHelper);
    const queueInputs = [...new Map(queueApplied.nextView.diagnostics.diagnostics
      .filter((item) => item.message.startsWith("Migration needs a value: "))
      .map((item) => [JSON.stringify([item.file, item.start, item.message]), item])).values()];
    assert.ok(queueInputs.length > 1, `queue conversion has several explicit domain inputs: ${JSON.stringify(queueApplied.nextView.diagnostics)}`);
    await vscode.commands.executeCommand("tesl.editMigrationHole", { previewId: queueApplied.nextView.previewId, itemIndex: 1 });
    const selectedInput = vscode.window.activeTextEditor;
    assert.equal(selectedInput.document.uri.fsPath, queueInputs[1].file);
    assert.equal(selectedInput.document.getText(selectedInput.selection), `todo ${JSON.stringify(queueInputs[1].message.slice("Migration needs a value: ".length))}`);
    evidence.checks.push("selecting a later migration input focuses that exact placeholder instead of returning to the first todo");
    for (let count = 0; count < 5; count++) {
      const editor = vscode.window.activeTextEditor;
      const hole = editor.document.getText(editor.selection);
      assert.match(hole, /^todo "/);
      const value = hole.includes(".body") ? "value.text" : hole.includes(".priority") ? "7" : '"historical"';
      assert.equal(await editor.edit((edit) => edit.replace(editor.selection, value)), true);
      queueReview = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: queueWelcome.flowId, action: "review" });
      if (queueReview.stage === "ready") break;
      await vscode.commands.executeCommand("tesl.editMigrationHole", { previewId: queueReview.previewId });
    }
    assert.equal(queueReview.stage, "ready", JSON.stringify(queueReview));
    await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: queueWelcome.flowId, action: "cancel" });
    const queueCancelled = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: queueWelcome.flowId, action: "confirmCancel" });
    assert.equal(queueCancelled.stage, "cancelled", JSON.stringify(queueCancelled));
    assert.equal(queueSchema.getText(), queueBefore);
    assert.equal(fs.existsSync(queueHelper), false);
    const queueRestored = await vscode.commands.executeCommand("tesl.previewMigration", vscode.Uri.file(path.join(queueRoot, "jobs-app.tesl")));
    assert.equal(queueRestored?.compilable, true, JSON.stringify({ result: queueRestored, documents: vscode.workspace.textDocuments.filter((doc) => doc.uri.fsPath.startsWith(queueRoot)).map((doc) => ({ file: doc.uri.fsPath, dirty: doc.isDirty, closed: doc.isClosed })) }));
    evidence.checks.push("queue record/JSON changes create a pure helper, focus its domain inputs, reach source ready, and cancel back to the original schema including helper-file deletion");
    await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: queueWelcome.flowId, action: "close" });
    const repeat = await vscode.commands.executeCommand("tesl.migrateDatabase", queueSchema.uri);
    const restarted = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: repeat.flowId, action: "start" });
    assert.equal(restarted.stage, "edit", JSON.stringify(restarted));
    await replaceDocument(queueSchema, queueBefore.replace("text: String", "text: String, priority: Int")
      .replace('text -> "text" with_codec stringCodec', 'text -> "text" with_codec stringCodec, priority -> "priority" with_codec intCodec')
      .replace('text <- "text" with_codec stringCodec', 'text <- "text" with_codec stringCodec, priority <- "priority" with_codec intCodec'));
    const repeatedReview = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: repeat.flowId, action: "review" });
    assert.ok(repeatedReview.view, JSON.stringify(repeatedReview));
    const repeatedPlan = repeatedReview.view.decisions.find((item) => item.options.some((option) => option.id === "map-queued-payload"));
    assert.ok(repeatedPlan, JSON.stringify(repeatedReview));
    const repeatedApply = await vscode.commands.executeCommand("tesl.applyMigrationChoice", { previewId: repeatedReview.previewId, decisionId: repeatedPlan.id, optionId: "map-queued-payload" });
    assert.ok(repeatedApply && !repeatedApply.error, JSON.stringify(repeatedApply));
    assert.equal(repeatedApply.result.sourceTransaction.outcome, "committed");
    assert.equal(vscode.window.activeTextEditor.document.uri.fsPath, queueHelper);
    assert.equal(vscode.window.activeTextEditor.document.languageId, "tesl");
    assert.ok(!vscode.window.activeTextEditor.document.getText().includes(".body"), "recreated helper must not reuse the previous draft's cached source");
    const repeatedMigration = await vscode.workspace.openTextDocument(vscode.Uri.file(path.join(queueRoot, "migrations/notes/v2.tesl")));
    assert.equal(repeatedMigration.languageId, "tesl");
    await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: repeat.flowId, action: "cancel" });
    const repeatedCancel = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: repeat.flowId, action: "confirmCancel" });
    assert.equal(repeatedCancel.stage, "cancelled", JSON.stringify(repeatedCancel));
    evidence.checks.push("a second migration reuses cancelled filenames with fresh source and Tesl language support, and can be cancelled again");
    const proofRoot = process.env.TESL_MIGRATION_HOST_PROOF;
    const proofSchema = await vscode.workspace.openTextDocument(vscode.Uri.file(path.join(proofRoot, "schema/notes/v-current.tesl")));
    const proofBefore = proofSchema.getText();
    const proofWelcome = await vscode.commands.executeCommand("tesl.migrateDatabase", proofSchema.uri);
    const proofAction = (action) => vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: proofWelcome.flowId, action });
    assert.equal((await proofAction("start")).stage, "edit");
    const frozenPath = path.join(proofRoot, "schema/notes/v1.tesl");
    const frozenBytes = fs.readFileSync(frozenPath, "utf8");
    await replaceDocument(proofSchema, proofBefore.replace("<= 120", "<= 200").replace("  | Closed\n", ""));
    let proofReview = await proofAction("review");
    const proofPlan = proofReview.view.decisions.find((item) => item.options.some((option) => option.id === "delete-rows"));
    assert.ok(proofPlan, JSON.stringify(proofReview));
    const proofApplied = await vscode.commands.executeCommand("tesl.applyMigrationChoice", { previewId: proofReview.previewId, decisionId: proofPlan.id, optionId: "delete-rows" });
    assert.equal(proofApplied.result.sourceTransaction.outcome, "committed");
    for (let count = 0; count < 10; count++) {
      const editor = vscode.window.activeTextEditor;
      const hole = editor.document.getText(editor.selection);
      assert.match(hole, /^todo "/);
      const value = hole.includes("Return True only") ? "case old.status of\n    NotesSchema.V1.Closed -> True\n    NotesSchema.V1.Open -> False" :
        hole.includes("Map removed or renamed variant") ? "Nothing" : '"fixture"';
      assert.equal(await editor.edit((edit) => edit.replace(editor.selection, value)), true);
      proofReview = await proofAction("review");
      if (proofReview.stage === "ready") break;
      await vscode.commands.executeCommand("tesl.editMigrationHole", { previewId: proofReview.previewId });
    }
    assert.equal(proofReview.stage, "ready", JSON.stringify(proofReview));
    assert.equal(fs.readFileSync(frozenPath, "utf8"), frozenBytes);
    evidence.checks.push("removed ADT variants offer explicit row deletion, changed proofs use ordinary fallible write-back, completed source checks pass, and frozen source stays byte-identical");
    // Interrupt cancellation after its backup is marked restoring. Then emulate
    // the user's Git restore/clean and reset only the persisted editor state.
    const proofMigration = path.join(proofRoot, "migrations/notes/v2.tesl");
    const proofDraft = await vscode.workspace.openTextDocument(vscode.Uri.file(proofMigration));
    await replaceDocument(proofDraft, proofDraft.getText() + "\n# cancellation recovery regression\n");
    await proofAction("cancel");
    const journal = path.join(proofRoot, ".tesl-source-edit");
    const interrupt = vscode.workspace.onDidChangeTextDocument(({ document }) => {
      if (document.uri.fsPath === proofMigration && !fs.existsSync(journal)) fs.mkdirSync(journal);
    });
    let interrupted;
    try { interrupted = await proofAction("confirmCancel"); }
    finally { interrupt.dispose(); }
    assert.equal(interrupted.stage, "cancelFailed", JSON.stringify(interrupted));
    fs.rmdirSync(journal); // This test created the empty marker, not a source transaction.
    assert.equal(fs.existsSync(proofMigration), false, "failure occurs after deleting the draft migration");
    await replaceDocument(proofSchema, proofBefore);
    if (proofSchema.isDirty) assert.equal(await proofSchema.save(), true);
    assert.equal(fs.readFileSync(proofSchema.uri.fsPath, "utf8"), proofBefore);
    await vscode.workspace.fs.delete(vscode.Uri.file(frozenPath), { useTrash: false });
    await replaceDocument(proofSchema, proofBefore + "\n# current unsaved work after manual restore\n");
    const keptText = proofSchema.getText(), keptDisk = fs.readFileSync(proofSchema.uri.fsPath, "utf8");
    await proofAction("close");
    const recoveryWelcome = await vscode.commands.executeCommand("tesl.migrateDatabase", proofSchema.uri);
    assert.equal(recoveryWelcome.stage, "cancelFailed", "failed cancellation survives reopening until explicitly reset");
    const staleAction = (action) => vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: recoveryWelcome.flowId, action });
    assert.equal((await staleAction("reset")).stage, "reset");
    assert.equal((await staleAction("confirmReset")).stage, "welcome");
    assert.equal(proofSchema.getText(), keptText);
    assert.equal(proofSchema.isDirty, true);
    assert.equal(fs.readFileSync(proofSchema.uri.fsPath, "utf8"), keptDisk);
    assert.equal(fs.existsSync(proofMigration), false);
    assert.equal(fs.existsSync(frozenPath), false);
    await staleAction("cancel"); // Close the now-empty welcome page.
    const freshWelcome = await vscode.commands.executeCommand("tesl.migrateDatabase", proofSchema.uri);
    assert.equal(freshWelcome.stage, "welcome");
    const freshStart = await vscode.commands.executeCommand("tesl.migrationFlowAction", { flowId: freshWelcome.flowId, action: "start" });
    assert.equal(freshStart.stage, "edit", JSON.stringify(freshStart));
    assert.equal(freshStart.revision, 2);
    evidence.checks.push("failed cancellation can be reset after manual source restoration without changing disk or unsaved text, and a fresh migration starts normally");
    evidence.ok = true;
  } catch (error) { evidence.ok = false; evidence.error = error.stack; throw error; }
  finally {
    fs.writeFileSync(process.env.TESL_MIGRATION_HOST_EVIDENCE, JSON.stringify(evidence, null, 2));
    // Do not discard dirty buffers on failure: the host may exit, while the
    // evidence and source journal identify any unresolved operation outcome.
  }
};
