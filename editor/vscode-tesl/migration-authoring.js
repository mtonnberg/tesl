"use strict";

const path = require("path");
const fs = require("fs");
const { randomBytes } = require("crypto");

const escape = (value) => String(value ?? "").replace(/[&<>"']/g, (char) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);

// Mask comments and literals before finding declaration lenses; examples and
// commented-out migrations must not acquire actions that look executable.
function migrationLensLocations(source) {
  let state = "code";
  const masked = [...source].map((char) => {
    if (char === "\n") { if (state === "comment") state = "code"; return char; }
    if (state === "escape") { state = "string"; return " "; }
    if (state === "string") {
      if (char === "\\") state = "escape";
      else if (char === '"') state = "code";
      return " ";
    }
    if (state === "comment") return " ";
    if (char === "#") { state = "comment"; return " "; }
    if (char === '"') { state = "string"; return " "; }
    return char;
  }).join("");
  const result = [];
  masked.split(/\r?\n/).forEach((line, index) => {
    if (/^\s*migration\s*=\s*(?:[A-Z]\w*\.)*Migration\b/.test(line) ||
        /^\s*module\s+[A-Z][\w.]*\.VCurrent\b/.test(line)) result.push(index);
  });
  return result;
}

const generalHelp = [
  { title: "1. Edit the current schema", summary: "Edit VCurrent, then refresh the undeployed migration with tesl migrate app.tesl. Keep deployed snapshots unchanged.", help: ["A current-target hash mismatch is expected while editing a draft. The compiler still blocks building/running that stale migration until refresh. If a revision has already been deployed, restore it and create the next forward revision; the editor cannot infer deployment state."] },
  { title: "2. Review proof identity", summary: "Same means the complete old and new contracts have the same meaning, not merely the same name or stored type.", options: [
    { title: "Same", when: "The complete proof/type/codec dependencies are unchanged and the compiler verifies identity." },
    { title: "Revalidate", when: "A new proof is added to a previously plain field and the compiler accepts revalidation on retained storage. Return the original primitive value without normalization and test rejected old values. An added conjunction must preserve every old proof through Same. Changed historical proof meaning requires a different route." },
    { title: "Derived or Migrate", when: "The representation or an existing historical proof changed. Supply the checked conversion and the required old-writer projection; add old-value fixtures. The compiler decides which retained-storage paths are supported." },
  ], help: ["For example, changing an allowed title length from 120 to 80 changes validity even though the field is still String. Do not declare Same for that changed historical meaning. The supported field-local conversion uses Migrate with Retype and WriteBack, whose reverse function returns the exact old field type and proof; cross-field reverse proofs are unsupported.", "Read every identity pair and affected stored occurrence. A successful build checks the implemented source rules; it does not decide your business policy."] },
  { title: "3. Review entity and queue decisions", summary: "Choose from the compiler's supported plans, fill explicit custom-code/value holes, and recheck. A recommendation is not permission to discard data.", help: ["Additive keeps existing contracts unchanged and supplies supported defaults for new fields. Derived builds a checked field adapter. Migrate requires a pure converter with the exact old/new types. New and Drop are explicit identity/lifecycle decisions.", "Row and payload changes can require separate ordered releases. Queue identity renames and some simultaneous changes are intentionally refused. Read the generated plan and the compiler's diagnostic rather than bypassing it."] },
  { title: "4. Check overlap and Contract", summary: "Test old/new processes together, catch-up and restart, then retire old writers before Contract.", help: ["Expand and conversion support the implemented compatible overlap. A destructive Contract closes that overlap; general rollback after Contract is not promised. Reverse conversions and legacy projections require explicit supported rules.", "Use representative fixtures, rejection cases, application tests and the PostgreSQL migration suites. Passing a finite scenario does not prove arbitrary histories or production-scale latency."] },
];

function previewItems(preview) {
  const diagnostics = preview.diagnostics?.diagnostics || [];
  const guidance = new Map((preview.guidance || []).map((item) => [item.diagnosticIndex, item.guide]));
  const matched = new Set((preview.guidance || []).map((item) => item.decisionId).filter(Boolean));
  const items = diagnostics.map((diagnostic, index) => ({
    ...guidance.get(index), title: `${diagnostic.code || "Diagnostic"}: ${guidance.get(index)?.title || diagnostic.severity || "review"}`,
    summary: `${diagnostic.message}${guidance.get(index)?.summary ? `\n\n${guidance.get(index).summary}` : ""}`, file: diagnostic.file, line: diagnostic.start?.line, col: diagnostic.start?.col,
  }));
  for (const decision of preview.decisions || []) { if (matched.has(decision.id)) continue; items.push({
    title: `Template: ${decision.entity || decision.id}`, summary: decision.reason,
    file: decision.file, line: decision.line, col: decision.col,
    options: (decision.options || []).map((option) => ({ title: option.label, when: option.help, example: option.template })),
    help: ["This compiler-proposed template retains explicit holes for your values or custom code. Copy and adapt it, then run the compiler again. No source changes occur in this preview."],
  }); }
  return items;
}

function renderGuide(items, index, nonce, heading, overview) {
  const item = items[index];
  const button = (action, label, extra = "") => `<button data-action="${action}" ${extra}>${escape(label)}</button>`;
  const details = (item?.help || []).map((text) => `<p>${escape(text)}</p>`).join("");
  const options = (item?.options || []).map((option, optionIndex) => `<details><summary>${escape(option.title)}</summary><p>${escape(option.when)}</p>${option.example ? `<pre>${escape(option.example)}</pre>${button("copy", "Copy example/template", `data-option="${optionIndex}"`)}` : ""}</details>`).join("");
  return `<!DOCTYPE html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';"><style>body{font-family:var(--vscode-font-family);line-height:1.5;padding:20px;max-width:950px}button{margin:5px;padding:6px;color:var(--vscode-button-foreground);background:var(--vscode-button-background);border:0}pre{white-space:pre-wrap}details{margin:12px 0;padding:8px;border:1px solid var(--vscode-panel-border)}summary{cursor:pointer}p{white-space:pre-wrap}</style></head><body><h1>${escape(heading)}</h1><p>${escape(overview)}</p><p>This guide is read-only. Review choices, edit source, then request a fresh preview. Editor application remains unavailable until its buffer-snapshot safeguards are complete.</p>${button("refresh", "Refresh preview")}${button("overview", "Overview")}<hr>${index < 0 ? `<h2>Overview</h2><ol>${items.map((entry, number) => `<li>${button("select", entry.title, `data-index="${number}"`)}</li>`).join("")}</ol>` : `<h2>${index + 1} / ${items.length}: ${escape(item.title)}</h2><p>${escape(item.summary)}</p>${options}${details ? `<details><summary>More help</summary>${details}</details>` : ""}${item.file ? button("source", "Open source location") : ""}${button("previous", "Previous")}${button("next", "Next")}`}<h2>Proposed files</h2><div id="files"></div><script nonce="${nonce}">const vscode=acquireVsCodeApi();document.addEventListener('click',event=>{const button=event.target.closest('button');if(button)vscode.postMessage({action:button.dataset.action,index:button.dataset.index===undefined?undefined:Number(button.dataset.index),optionIndex:button.dataset.option===undefined?undefined:Number(button.dataset.option)});});</script></body></html>`;
}

function inside(root, file) {
  if (!path.isAbsolute(file || "")) return false;
  const relative = path.relative(root, file);
  return relative === "" || relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function registerMigrationAuthoring(vscode, context, { getClient, requireTrustedWorkspace }) {
  const virtualDocuments = new Map();
  context.subscriptions.push(vscode.workspace.registerTextDocumentContentProvider("tesl-migration-preview", {
    provideTextDocumentContent: (uri) => virtualDocuments.get(uri.toString()) || "Preview expired; request a new migration preview.",
  }));

  async function requestPreview(uri, selectedDatabase) {
    if (!requireTrustedWorkspace()) return;
    const languageClient = getClient();
    if (!languageClient) { vscode.window.showWarningMessage("Tesl: a matching language server is required for migration preview."); return; }
    let entry = uri || vscode.window.activeTextEditor?.document.uri;
    if (!entry || /[\\/](schema|migrations)[\\/]/.test(entry.fsPath)) {
      const files = await vscode.workspace.findFiles("**/*.tesl", "**/{.tesl-stuff,_build,node_modules,schema,migrations}/**", 200);
      const selected = await vscode.window.showQuickPick([...files.map((file) => ({ label: vscode.workspace.asRelativePath(file), uri: file })), { label: "Browse for an application entry file…", browse: true }], { placeHolder: "Select the application entry file for this migration" });
      if (!selected) return;
      entry = selected.browse ? (await vscode.window.showOpenDialog({ canSelectMany: false, filters: { Tesl: ["tesl"] }, title: "Select the application entry file" }))?.[0] : selected.uri;
      if (!entry) return;
    }
    const workspaceRoot = vscode.workspace.getWorkspaceFolder(entry)?.uri.fsPath;
    if (!workspaceRoot || !inside(workspaceRoot, entry.fsPath)) throw new Error("Select an application inside an open workspace folder.");
    let projectRoot = path.dirname(entry.fsPath);
    while (projectRoot !== workspaceRoot && inside(workspaceRoot, projectRoot) && !fs.existsSync(path.join(projectRoot, "tesl.toml"))) projectRoot = path.dirname(projectRoot);
    if (!inside(workspaceRoot, projectRoot)) projectRoot = workspaceRoot;
    const preview = await languageClient.sendRequest("workspace/executeCommand", { command: "tesl.generateMigration", arguments: [{ entryFile: entry.fsPath, projectRoot, ...(selectedDatabase ? { database: selectedDatabase } : {}) }] });
    if (!preview?.ok) {
      const candidates = new Map((preview?.errors || []).flatMap((error) => error.candidates || []).filter((candidate) => typeof candidate.database === "string").map((candidate) => [candidate.database, candidate]));
      if (!selectedDatabase && candidates.size > 1) {
        const selected = await vscode.window.showQuickPick([...candidates.values()].map((candidate) => ({ label: candidate.database, description: candidate.file, database: candidate.database })), { placeHolder: "Choose the database to migrate" });
        if (selected) return requestPreview(entry, selected.database);
        return;
      }
      throw new Error(`Migration preview refused: ${(preview?.errors || []).map((error) => error.message || "Unknown compiler refusal").join("\n") || "Unsupported language server response"}`);
    }
    const items = previewItems(preview);
    const panel = vscode.window.createWebviewPanel("teslMigrationGuide", "Tesl Migration Preview", vscode.ViewColumn.Beside, { enableScripts: true, retainContextWhenHidden: false });
    let index = -1;
    const nonce = randomBytes(16).toString("hex");
    virtualDocuments.clear();
    const refresh = () => {
      panel.webview.html = renderGuide(items, index, nonce, "Migration preview", `${preview.database}: ${preview.operation}; ${preview.files.length} proposed files; ${items.length} review items. ${preview.compilable ? "Proposal compiles." : "Proposal still has decisions or errors to resolve."}`)
        .replace('<div id="files"></div>', `<div id="files">${preview.files.map((file, number) => `<button data-action="diff" data-index="${number}">${escape(path.relative(projectRoot, file.path))}${file.creates ? " (new)" : ""}</button>`).join("")}</div>`);
    };
    panel.webview.onDidReceiveMessage(async (message) => {
      try {
        if (!requireTrustedWorkspace()) return;
        if (message.action === "refresh") { await requestPreview(entry, selectedDatabase); panel.dispose(); return; }
        if (message.action === "overview") index = -1;
        if (message.action === "select" && Number.isInteger(message.index) && message.index >= 0 && message.index < items.length) index = message.index;
        if (message.action === "next") index = Math.min(items.length - 1, index + 1);
        if (message.action === "previous") index = Math.max(-1, index - 1);
        const item = items[index];
        if (message.action === "source" && item && inside(projectRoot, item.file)) {
          const line = Math.max(0, Number.isInteger(item.line) ? item.line : 0);
          const document = await vscode.workspace.openTextDocument(vscode.Uri.file(item.file));
          const sourceLine = line < document.lineCount ? document.lineAt(line).text : "";
          const byteCol = Math.max(0, Number.isInteger(item.col) ? item.col : 0);
          const col = Buffer.from(sourceLine).subarray(0, byteCol).toString("utf8").length;
          await vscode.window.showTextDocument(document, { selection: new vscode.Range(line, col, line, col), preview: true });
        }
        if (message.action === "copy" && item && Number.isInteger(message.optionIndex)) {
          const example = item.options?.[message.optionIndex]?.example;
          if (typeof example === "string") await vscode.env.clipboard.writeText(example);
        }
        if (message.action === "diff" && Number.isInteger(message.index)) {
          const file = preview.files[message.index];
          if (!file || !inside(projectRoot, file.path)) throw new Error("Preview path is outside the selected project.");
          const result = await languageClient.sendRequest("workspace/executeCommand", { command: "tesl.migrationPreviewFile", arguments: [{ previewId: preview.previewId, path: file.path }] });
          const before = vscode.Uri.parse(`tesl-migration-preview:${preview.previewId}/${message.index}/before.tesl`);
          const after = vscode.Uri.parse(`tesl-migration-preview:${preview.previewId}/${message.index}/after.tesl`);
          virtualDocuments.set(before.toString(), result.before);
          virtualDocuments.set(after.toString(), result.after);
          await vscode.commands.executeCommand("vscode.diff", before, after, `Migration: ${path.relative(projectRoot, file.path)}`, { preview: true });
        }
        refresh();
      } catch (error) { vscode.window.showErrorMessage(`Tesl migration: ${error.message}`); }
    }, undefined, context.subscriptions);
    refresh();
    return panel;
  }

  context.subscriptions.push(vscode.commands.registerCommand("tesl.previewMigration", async (uri) => {
    try { return await requestPreview(uri); } catch (error) { vscode.window.showErrorMessage(`Tesl migration: ${error.message}`); }
  }));
  context.subscriptions.push(vscode.commands.registerCommand("tesl.migrationGuide", () => {
    const panel = vscode.window.createWebviewPanel("teslMigrationHelp", "Tesl Migration Guide", vscode.ViewColumn.Beside, { enableScripts: true });
    let index = -1;
    const nonce = randomBytes(16).toString("hex");
    const refresh = () => { panel.webview.html = renderGuide(generalHelp, index, nonce, "Migration authoring guide", "Edit → preview → review each decision → write custom code → recheck → test rollout."); };
    panel.webview.onDidReceiveMessage(async (message) => {
      if (message.action === "refresh") { await vscode.commands.executeCommand("tesl.previewMigration"); return; }
      if (message.action === "overview") index = -1;
      if (message.action === "select" && Number.isInteger(message.index) && message.index >= 0 && message.index < generalHelp.length) index = message.index;
      if (message.action === "next") index = Math.min(generalHelp.length - 1, index + 1);
      if (message.action === "previous") index = Math.max(-1, index - 1);
      refresh();
    }, undefined, context.subscriptions);
    refresh();
  }));
  context.subscriptions.push(vscode.languages.registerCodeLensProvider({ scheme: "file", language: "tesl" }, {
    provideCodeLenses(document) {
      if (!vscode.workspace.isTrusted) return [];
      return migrationLensLocations(document.getText()).flatMap((line) => [
        new vscode.CodeLens(new vscode.Range(line, 0, line, 0), { title: "Migration guide", command: "tesl.migrationGuide" }),
        new vscode.CodeLens(new vscode.Range(line, 0, line, 0), { title: "Preview migration decisions", command: "tesl.previewMigration", arguments: [document.uri] }),
      ]);
    },
  }));
}

module.exports = { registerMigrationAuthoring, migrationLensLocations, previewItems, renderGuide, inside };
