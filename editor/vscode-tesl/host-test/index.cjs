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
  const entry = path.join(root, "app.tesl"), current = path.join(root, "schema/notes/v-current.tesl");
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
    const app = await vscode.workspace.openTextDocument(vscode.Uri.file(entry));
    await vscode.window.showTextDocument(app, { preview: false });
    let view = await vscode.commands.executeCommand("tesl.previewMigration", vscode.Uri.file(entry));
    assert.equal(view?.kind, "migration-editor-view", "real preview command returns a retained view");
    const initial = await vscode.commands.executeCommand("tesl.applyMigrationSource", { previewId: view.previewId });
    assert.equal(initial?.result?.sourceTransaction?.outcome, "committed", JSON.stringify(initial));
    assert.equal(fs.existsSync(path.join(root, "schema/notes/v1.tesl")), true);
    assert.equal(fs.existsSync(migration), true);
    evidence.checks.push("initial proposal creates real frozen schema and migration files through the editor transaction");

    const schema = await vscode.workspace.openTextDocument(vscode.Uri.file(current));
    const schemaDisk = fs.readFileSync(current, "utf8");
    const lenses = await vscode.commands.executeCommand("vscode.executeCodeLensProvider", schema.uri);
    assert.ok(lenses.some((lens) => lens.command?.command === "tesl.previewMigration"));
    assert.ok(lenses.some((lens) => lens.command?.command === "tesl.migrateDatabase"));
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
    view = await vscode.commands.executeCommand("tesl.previewMigration", vscode.Uri.file(entry));
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
    evidence.ok = true;
  } catch (error) { evidence.ok = false; evidence.error = error.stack; throw error; }
  finally {
    fs.writeFileSync(process.env.TESL_MIGRATION_HOST_EVIDENCE, JSON.stringify(evidence, null, 2));
    // Do not discard dirty buffers on failure: the host may exit, while the
    // evidence and source journal identify any unresolved operation outcome.
  }
};
