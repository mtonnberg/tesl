"use strict";

const path = require("path");
const fs = require("fs");
const { randomBytes } = require("crypto");
const { projectForFile } = require("./migration-project");
const { registerMigrationFlow } = require("./migration-flow");
const { restoreDiscardedDocuments } = require("./migration-cancel");

const escape = (value) => String(value ?? "").replace(/[&<>"']/g, (char) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);

// Mask comments and literals before finding declaration lenses; examples and
// commented-out migrations must not acquire actions that look executable.
function migrationLensLocations(source, file = "") {
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
    if (/^\s*(migration|contract|repair)\s*=\s*(?:[A-Z]\w*\.)*(Migration|Contract|Repair)\b/.test(line) ||
        /^\s*database\s+[A-Z]\w*\s*=/.test(line) ||
        /^\s*module\s+[A-Z][\w.]*\.VCurrent\b/.test(line)) result.push(index);
  });
  // Frozen snapshots, private schema helpers and incomplete migration files
  // also need a way back to their application's checked authoring workflow.
  if (result.length === 0 && /[\\/](schema|migrations)[\\/]/.test(file)) result.push(0);
  return result;
}

const generalHelp = [
  { title: "1. Start before editing", summary: "Open Tesl: Migrate database/queues and press Start migration. Wait for the new draft version and Now edit your schema before changing v-current.tesl.", help: ["Start freezes the current schema and creates the next revision. For example, V13 becomes frozen history and your next changes belong to V14. Review my changes generates the migration choices; choose a plan and fill the selected domain placeholders. Ctrl+Space at a generated decision also offers complete plans.", "A stale-schema warning is expected while editing a prepared draft. Review your changes to update its generated source. To resume a draft prepared elsewhere, use Continue an existing draft. The compiler cannot determine which revisions have been deployed."] },
  { title: "2. Review proof identity", summary: "Same means the complete old and new contracts have the same meaning, not merely the same name or stored type.", options: [
    { title: "Same", when: "The complete proof/type/codec dependencies are unchanged and the compiler verifies identity. A more permissive check is still a changed proof, even if every old value passes." },
    { title: "Revalidate", when: "A new proof is added to a previously plain field and the compiler accepts revalidation on retained storage. Return the original primitive value without normalization and test rejected old values. An added conjunction must preserve every old proof through Same. Changed historical proof meaning requires a different route." },
    { title: "Changed proof, including a more permissive check", when: "Choose Reuse existing validators when the compiler offers it, or the custom conversion plan. Old values may all pass the new check, but new values may fail the old check. The generated historical write-back must still return an old-valid value. Choose that fallback policy, or keep new writes within the old rule until old writers are retired. Same and same-column Revalidate do not replace changed historical proof meaning." },
  ], help: ["For example, changing an allowed title length from 120 to 80 changes validity even though the field is still String. Do not declare Same for that changed historical meaning. The supported field-local conversion uses Migrate with Retype and WriteBack, whose reverse function returns the exact old field type and proof; cross-field reverse proofs are unsupported.", "Read every identity pair and affected stored occurrence. A successful build checks the implemented source rules; it does not decide your business policy."] },
  { title: "3. Review entity and queue decisions", summary: "Choose from the compiler's supported plans, fill explicit custom-code/value holes, and recheck. A recommendation is not permission to discard data.", help: ["Additive keeps existing contracts unchanged and supplies supported defaults for new fields. Derived builds a checked field adapter. Migrate requires a pure converter with the exact old/new types. New and Drop are explicit identity/lifecycle decisions.", "Row and payload changes can require separate ordered releases. Queue identity renames and some simultaneous changes are intentionally refused. Read the generated plan and the compiler's diagnostic rather than bypassing it."] },
  { title: "4. Check overlap and Contract", summary: "Test old/new processes together, catch-up and restart, then retire old writers before Contract.", help: ["Expand and conversion support the implemented compatible overlap. A destructive Contract closes that overlap; general rollback after Contract is not promised. Reverse conversions and legacy projections require explicit supported rules.", "Use representative fixtures, rejection cases, application tests and the PostgreSQL migration suites. Passing a finite scenario does not prove arbitrary histories or production-scale latency."] },
];

function previewItems(preview) {
  const diagnostics = preview.diagnostics?.diagnostics || [];
  const guidance = new Map((preview.guidance || []).map((item) => [item.diagnosticIndex, item.guide]));
  const matched = new Set((preview.guidance || []).map((item) => item.decisionId).filter(Boolean));
  const seen = new Set();
  const items = diagnostics.flatMap((diagnostic, index) => {
    const key = JSON.stringify([diagnostic.file, diagnostic.start, diagnostic.end, diagnostic.code, diagnostic.severity, diagnostic.message]);
    if (seen.has(key)) return [];
    seen.add(key);
    return [{
    code: diagnostic.code,
    customHole: diagnostic.message?.startsWith("Migration needs a value: ") || diagnostic.message?.includes("Choose a literal of type "),
    ...guidance.get(index), decisionId: (preview.guidance || []).find((item) => item.diagnosticIndex === index)?.decisionId, title: `${diagnostic.code || "Diagnostic"}: ${guidance.get(index)?.title || diagnostic.severity || "review"}`,
    summary: guidance.get(index)?.summary || diagnostic.message, file: diagnostic.file, line: diagnostic.start?.line, col: diagnostic.start?.col,
    diagnostic: diagnostic.message,
  }]; });
  for (const decision of preview.decisions || []) { if (matched.has(decision.id)) continue; items.push({
    title: `Choose: ${decision.entity || decision.id}`, decisionId: decision.id, summary: decision.reason,
    file: decision.file, line: decision.line, col: decision.col,
    options: (decision.options || []).map((option) => ({ id: option.id, title: option.label, when: option.help, example: option.template })),
    help: ["This compiler-proposed template retains explicit holes for your values or custom code. Choose an option to update the real migration source through a guarded transaction. Complete its explicit custom-code holes, then recheck."],
  }); }
  return items.sort((a, b) => (a.customHole ? 0 : a.decisionId ? 1 : 2) - (b.customHole ? 0 : b.decisionId ? 1 : 2));
}

function renderGuide(items, index, nonce, heading, overview, controls = {}) {
  const item = items[index];
  const button = (action, label, extra = "", primary = false) => `<button class="${primary ? "primary" : "secondary"}" data-action="${action}" ${extra}>${escape(label)}</button>`;
  const details = (item?.help || []).map((text) => `<p>${escape(text)}</p>`).join("");
  const choices = !!(controls.canChoose && item?.decisionId && item.options?.some((option) => option.id));
  const options = (item?.options || []).map((option, optionIndex) => `<section class="option">${choices && option.id ? `<label><input type="radio" name="plan" value="${optionIndex}"> <strong>${escape(option.title)}</strong></label>` : `<strong>${escape(option.title)}</strong>`}<p>${escape(option.when)}</p>${option.example ? `<details><summary>Generated code</summary><pre>${escape(option.example)}</pre></details>` : ""}</section>`).join("");
  let instruction, primary;
  if (controls.busy) {
    instruction = "Updating the checked proposal…";
    primary = button("refresh", "Please wait…", "disabled", true);
  } else if (controls.consumed) {
    instruction = controls.canStatus ? "Check the last source update before continuing." : "This proposal was used or refused. Recheck to get fresh choices.";
    primary = controls.canStatus ? button("status", "Check application outcome", "", true) : button("refresh", "Recheck application", "", true);
  } else if (choices) {
    instruction = "Select one plan below, then press Generate selected plan. Tesl fills the boilerplate and opens the domain logic you need to supply.";
    primary = button("choose", "Generate selected plan", 'id="generate-plan" disabled', true);
  } else if (item?.file) {
    const domain = item.code === "MIG003";
    instruction = item.code === "MIG024" ? "Open the invalid Same claim below. If this is an undeployed draft and the change is intentional, remove that claim, then press Recheck application. Deployed source must be restored before starting a forward revision." :
      item.code === "MIG013" ? "Open the recorded-history error and restore the deployed source from version control. Then recheck." :
      domain ? "Press Fill domain logic, replace the selected placeholder with your value or code, then press Recheck application." :
      "Open this source location, address the compiler message, then press Recheck application.";
    primary = button(domain ? "edit" : "source", domain ? "Fill domain logic" : item.code === "MIG024" ? "Open invalid Same claim" : "Open source location", "", true);
  } else if (!item && items.length) {
    instruction = "Start with the first unresolved item. Each step shows only the compiler's relevant guidance and available plans.";
    primary = button("next", "Review first item", "", true);
  } else if (controls.canApply) {
    instruction = "The compiler prepared the source changes shown below. Review their diffs, then update the generated files.";
    primary = button("apply", controls.newRevision ? "Create next revision" : "Update generated source", "", true);
  } else {
    instruction = controls.reference ? "Choose a topic for general background. To prepare a migration, open Migrate database/queues from its source file." :
      "No source update is pending. Recheck after editing your current schema or domain logic.";
    primary = button("refresh", controls.reference ? "Migrate database/queues" : "Recheck application", "", true);
  }
  const body = index < 0 ? `<h2>${controls.reference ? "Reference topics" : "Remaining items"}</h2><ol>${items.map((entry, number) => `<li>${button("select", entry.title, `data-index="${number}"`)}</li>`).join("")}</ol>` :
    `<h2>${index + 1} / ${items.length}: ${escape(item.title)}</h2><p>${escape(item.summary)}</p>${options}${details ? `<details><summary>More help</summary>${details}</details>` : ""}${item.diagnostic ? `<details><summary>Compiler details</summary><pre>${escape(item.diagnostic)}</pre></details>` : ""}`;
  return `<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';">
<style>
body{font-family:var(--vscode-font-family);line-height:1.5;padding:20px;max-width:950px;color:var(--vscode-foreground)}
button{margin:4px 8px 4px 0;padding:7px 12px;border:1px solid transparent;cursor:pointer;border-radius:3px}
.primary{color:var(--vscode-button-foreground);background:var(--vscode-button-background)}
.primary:hover{background:var(--vscode-button-hoverBackground)}
.secondary{color:var(--vscode-button-secondaryForeground);background:var(--vscode-button-secondaryBackground)}
.secondary:hover{background:var(--vscode-button-secondaryHoverBackground)}
button:disabled{opacity:.5;cursor:default}button:focus-visible,input:focus-visible,summary:focus-visible{outline:2px solid var(--vscode-focusBorder)}
.next-step{border-left:3px solid var(--vscode-focusBorder);padding:4px 14px;margin:20px 0}.context{color:var(--vscode-descriptionForeground)}
.option{border:1px solid var(--vscode-panel-border);padding:12px;margin:12px 0}.option label{cursor:pointer;display:block}
pre{white-space:pre-wrap;overflow-wrap:anywhere}details{margin:12px 0}summary{cursor:pointer}p{white-space:pre-wrap}nav{margin-top:24px}
</style></head><body>
<h1>${escape(heading)}</h1><p class="context">${escape(controls.context || "")}</p><p>${escape(overview)}</p>
${controls.status ? `<p role="status">${escape(controls.status)}</p>` : ""}
${body}<section class="next-step"><h3>Next step</h3><p>${escape(instruction)}</p>${primary}</section>
<nav aria-label="Guide navigation">${index > 0 ? button("previous", "Previous item") : ""}${index >= 0 && index < items.length - 1 ? button("next", "Next item") : ""}${index >= 0 ? button("overview", "All items") : ""}${!controls.reference ? button("refresh", "Recheck application") : ""}</nav>
${!controls.reference ? `<details><summary>Proposed source files (${controls.fileCount || 0})</summary><p>These actions prepare source; they do not run database migrations.</p><div id="files"></div>${controls.canApply && (item || items.length) ? button("apply", "Update generated source only") : ""}</details>` : ""}
<script nonce="${nonce}">
const vscode=acquireVsCodeApi();
document.addEventListener('change',()=>{const button=document.getElementById('generate-plan');if(button)button.disabled=!document.querySelector('input[name="plan"]:checked');});
document.addEventListener('click',event=>{const button=event.target.closest('button');if(!button||button.disabled)return;const selected=document.querySelector('input[name="plan"]:checked');vscode.postMessage({action:button.dataset.action,index:button.dataset.index===undefined?undefined:Number(button.dataset.index),optionIndex:button.dataset.action==='choose'&&selected?Number(selected.value):undefined});});
</script></body></html>`;
}

function inside(root, file) {
  if (!path.isAbsolute(file || "")) return false;
  const relative = path.relative(root, file);
  return relative === "" || relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function codeHoleOffset(source, from = 0) {
  let state = "code";
  for (let i = 0; i < source.length; i++) {
    const char = source[i];
    if (state === "comment") { if (char === "\n") state = "code"; continue; }
    if (state === "escape") { state = "string"; continue; }
    if (state === "string") { if (char === "\\") state = "escape"; else if (char === '"') state = "code"; continue; }
    if (char === "#") { state = "comment"; continue; }
    if (char === '"') { state = "string"; continue; }
    if (i >= from && source.startsWith("todo", i) && !/[A-Za-z0-9_.]/.test(source[i - 1] || "") && !/[A-Za-z0-9_]/.test(source[i + 4] || "")) {
      let argument = i + 4;
      while (argument < source.length && /\s/.test(source[argument])) argument++;
      if (source[argument] === '"') return i;
    }
  }
  return -1;
}

function codeHoleRange(source, from = 0) {
  const start = codeHoleOffset(source, from);
  if (start < 0) return undefined;
  let end = start + 4, cursor = end;
  while (/\s/.test(source[cursor] || "") && cursor < source.length) cursor++;
  if (source[cursor] === '"') {
    for (let i = cursor + 1; i < source.length; i++) {
      if (source[i] === "\\") { i++; continue; }
      if (source[i] === '"') { end = i + 1; break; }
    }
  }
  return { start, end };
}

function registerMigrationAuthoring(vscode, context, { getClient, requireTrustedWorkspace }) {
  const virtualDocuments = new Map();
  const views = new Map();
  const selections = new Map();
  let applyingSource = false;
  context.subscriptions.push(vscode.workspace.registerTextDocumentContentProvider("tesl-migration-preview", {
    provideTextDocumentContent: (uri) => virtualDocuments.get(uri.toString()) || "Preview expired; request a new migration preview.",
  }));

  async function requestPreview(uri, selectedDatabase, viewOptions = {}) {
    if (!requireTrustedWorkspace()) return;
    const languageClient = getClient();
    if (!languageClient) throw new Error("The Tesl language server is not ready. Wait for it to start, or check your toolchain settings, then try again.");
    let entry = uri || vscode.window.activeTextEditor?.document.uri;
    const sourceUri = viewOptions.sourceUri || entry;
    viewOptions = { ...viewOptions, sourceUri };
    const sourceWorkspace = entry && vscode.workspace.getWorkspaceFolder(entry)?.uri.fsPath;
    const readSource = (file) => vscode.workspace.textDocuments?.find((document) => document.uri.fsPath === file)?.getText() ?? fs.readFileSync(file, "utf8");
    const sourceProject = sourceWorkspace ? projectForFile(entry.fsPath, sourceWorkspace, readSource) : undefined;
    if (!entry || /[\\/](schema|migrations)[\\/]/.test(entry.fsPath)) {
      if (sourceProject?.entry) entry = vscode.Uri.file(sourceProject.entry);
      else {
        const remembered = [...selections.values()].filter((selection) => selection.projectRoot === sourceProject?.projectRoot);
        if (remembered.length === 1) entry = remembered[0].entry;
        else {
          const pattern = sourceProject ? new vscode.RelativePattern(sourceProject.projectRoot, "**/*.tesl") : "**/*.tesl";
          const files = await vscode.workspace.findFiles(pattern, "**/{.tesl-stuff,_build,node_modules,schema,migrations}/**", 200);
          const selected = await vscode.window.showQuickPick([...files.map((file) => ({ label: vscode.workspace.asRelativePath(file), uri: file })), { label: "Browse for an application entry file…", browse: true }], { placeHolder: "Select the application entry file for this migration" });
          if (!selected) return;
          entry = selected.browse ? (await vscode.window.showOpenDialog({ canSelectMany: false, filters: { Tesl: ["tesl"] }, title: "Select the application entry file" }))?.[0] : selected.uri;
          if (!entry) return;
        }
      }
    }
    const workspaceRoot = vscode.workspace.getWorkspaceFolder(entry)?.uri.fsPath;
    if (!workspaceRoot || !inside(workspaceRoot, entry.fsPath)) throw new Error("Select an application inside an open workspace folder.");
    const { projectRoot } = projectForFile(entry.fsPath, workspaceRoot, readSource);
    await restoreDiscardedDocuments(vscode, projectRoot);
    const selection = { entryFile: entry.fsPath, projectRoot, ...(selectedDatabase ? { database: selectedDatabase } : {}), ...(viewOptions.newRevision ? { newRevision: true } : {}), ...(viewOptions.contractVersion ? { contractVersion: viewOptions.contractVersion } : {}) };
    const sourceEpoch = viewOptions.flow?.sourceEpoch;
    let preview = await languageClient.sendRequest("workspace/executeCommand", { command: "tesl.generateMigration", arguments: [selection] });
    if (!preview?.ok) {
      const candidates = new Map((preview?.errors || []).flatMap((error) => error.candidates || []).filter((candidate) => typeof candidate.database === "string").map((candidate) => [candidate.database, candidate]));
      if (!selectedDatabase && candidates.size > 1) {
        const selected = await vscode.window.showQuickPick([...candidates.values()].map((candidate) => ({ label: candidate.database, description: candidate.file, database: candidate.database })), { placeHolder: "Choose the database to migrate" });
        if (selected) return requestPreview(entry, selected.database, viewOptions);
        return;
      }
      const error = new Error(`Migration preview refused: ${(preview?.errors || []).map((error) => error.message || "Unknown compiler refusal").join("\n") || "Unsupported language server response"}`);
      error.reviewCleanup = preview?.errors?.some((item) => item.action === "review-cleanup") === true;
      throw error;
    }
    if (viewOptions.expectedRevision && preview.revisionAfter !== viewOptions.expectedRevision) throw new Error("The current revision changed. Reopen the workflow and select the draft to continue.");
    if (viewOptions.flow) {
      if (preview.operation !== "refresh" && !(viewOptions.contractVersion && preview.operation === "contract")) throw new Error("There is no existing draft to continue. Use Start migration first.");
      if (!Number.isInteger(preview.revisionAfter) || !preview.schemaFiles?.length) throw new Error("Update the matching language server to use the revision-aware workflow.");
      if (viewOptions.flow.view?.inputDigest !== preview.inputDigest) viewOptions.flow.testStatus = undefined;
      viewOptions.flow.changedAfterCheck = viewOptions.flow.sourceEpoch !== sourceEpoch;
      Object.assign(viewOptions.flow, { revision: preview.revisionAfter, schemaFiles: preview.schemaFiles, entryFile: entry.fsPath, projectRoot, database: preview.database });
    }
    let items = previewItems(preview);
    selections.set(`${entry.fsPath}:${preview.database}`, { entry, projectRoot, database: preview.database });
    const panel = viewOptions.silent ? undefined : viewOptions.flow?.panel || vscode.window.createWebviewPanel("teslMigrationGuide", "Tesl Migration Decisions", { viewColumn: vscode.ViewColumn.Beside, preserveFocus: !!viewOptions.preserveFocus }, { enableScripts: true, retainContextWhenHidden: false });
    let index = viewOptions.guided && items.length ? 0 : -1, busy = false, consumed = false, status = "", operationPreviewId, panelDisposed = false, outcomeKnown = false;
    const viewId = preview.previewId;
    panel?.onDidDispose?.(() => { panelDisposed = true; views.delete(viewId); }, undefined, context.subscriptions);
    const supportsApply = languageClient.initializeResult?.capabilities?.executeCommandProvider?.commands?.includes("tesl.applyMigration") === true;
    const nonce = randomBytes(16).toString("hex");
    virtualDocuments.clear();
    const refresh = () => {
      if (panelDisposed || !panel) return;
      const controls = {
        context: `Application: ${vscode.workspace.asRelativePath(entry)}\nDatabase: ${preview.database}${sourceUri ? `\nOpened from: ${vscode.workspace.asRelativePath(sourceUri)}` : ""}`,
        busy, consumed, newRevision: !!selection.newRevision, fileCount: preview.files.length,
        canLeave: !busy && (!consumed || !operationPreviewId || outcomeKnown),
        canApply: supportsApply && !busy && !consumed && !viewOptions.flow?.changedAfterCheck && preview.files.length > 0 && (preview.operation !== "contract" || preview.compilable),
        canChoose: supportsApply && !busy && !consumed && !viewOptions.flow?.changedAfterCheck && !selection.newRevision && !selection.contractVersion && typeof preview.inputDigest === "string",
        canStatus: !!operationPreviewId, pendingPaths: preview.files.map((file) => file.path),
        status: status || (supportsApply ? "" : "This language server cannot apply guarded editor changes. Install the matching updated CLI/compiler/LSP and reload."),
      };
      panel.webview.html = (viewOptions.flow ? viewOptions.flow.renderReview(preview, items, index, controls) : renderGuide(items, index, nonce, "Migration source preview", `${preview.files.length} proposed files; ${items.length} review items. ${preview.compilable ? "Proposal compiles." : "Proposal still has decisions or errors to resolve."}`, controls))
        .replace('<div id="files"></div>', `<div id="files">${preview.files.map((file, number) => `<button class="secondary" data-action="diff" data-index="${number}">${escape(path.relative(projectRoot, file.path))}${file.creates ? " (new)" : ""}</button>`).join("")}</div>`);
    };
    const openLocation = async (item) => {
      if (!item || !inside(projectRoot, item.file)) return;
      const document = await vscode.workspace.openTextDocument(vscode.Uri.file(item.file));
      const line = Math.min(Math.max(0, Number.isInteger(item.line) ? item.line : 0), Math.max(0, document.lineCount - 1));
      const sourceLine = line < document.lineCount ? document.lineAt(line).text : "";
      const col = Buffer.from(sourceLine).subarray(0, Math.max(0, Number.isInteger(item.col) ? item.col : 0)).toString("utf8").length;
      await vscode.window.showTextDocument(document, { selection: new vscode.Range(line, col, line, col), preview: false });
    };
    const openCustomCode = async (proposal, preferred) => {
      // Select actual value holes before unrelated, still-unselected migration
      // decisions. This also finds holes in generated queue helper modules.
      for (const diagnostic of proposal.diagnostics?.diagnostics || []) {
        if (!inside(projectRoot, diagnostic.file) || !(diagnostic.message?.startsWith("Migration needs a value: ") || diagnostic.message?.includes("Choose a literal of type "))) continue;
        try {
          const document = await vscode.workspace.openTextDocument(vscode.Uri.file(diagnostic.file));
          const source = document.getText(), lines = source.split("\n"), line = diagnostic.start?.line;
          if (!Number.isInteger(line) || line < 0 || line >= lines.length) continue;
          const col = Buffer.from(lines[line]).subarray(0, diagnostic.start.col).toString("utf8").length;
          const offset = lines.slice(0, line).reduce((count, text) => count + text.length + 1, 0) + col;
          const hole = codeHoleRange(source, offset);
          if (!hole || hole.start !== offset) continue;
          const start = document.positionAt(hole.start), end = document.positionAt(hole.end);
          await vscode.window.showTextDocument(document, { selection: new vscode.Range(start.line, start.character, end.line, end.character), preview: false });
          return;
        } catch (_) { /* Fall back to the source inventory when a location moved. */ }
      }
      const candidates = [...new Set([preferred?.file, ...(proposal.decisions || []).map((item) => item.file), ...(proposal.diagnostics?.diagnostics || []).map((item) => item.file), ...proposal.files.map((file) => file.path)])].filter((file) => inside(projectRoot, file));
      for (const file of candidates) {
        try {
          const document = await vscode.workspace.openTextDocument(vscode.Uri.file(file));
          const hole = codeHoleRange(document.getText());
          if (!hole) continue;
          const start = document.positionAt(hole.start), end = document.positionAt(hole.end);
          await vscode.window.showTextDocument(document, { selection: new vscode.Range(start.line, start.character, end.line, end.character), preview: false });
          return;
        } catch (_) { /* Leave source errors visible in the fresh compiler preview. */ }
      }
      if (preferred) await openLocation(preferred);
      else {
        const frozen = proposal.files.find((file) => /[\\/]schema[\\/][^\\/]+[\\/]v\d+\.tesl$/.test(file.path));
        if (frozen) {
          const current = path.join(path.dirname(frozen.path), "v-current.tesl");
          if (inside(projectRoot, current)) await openLocation({ file: current });
        }
      }
    };
    const showOutcome = (result) => {
      const transaction = result?.sourceTransaction;
      outcomeKnown = !result?.active && !transaction?.recoveryRequired && ["committed", "restored", "unchanged"].includes(transaction?.outcome);
      status = `Source outcome: ${transaction?.outcome || "unknown"}. ${result?.error || ""}${transaction?.recoveryRequired ? " Recovery is required; preserve your buffers and the .tesl-source-edit journal before any further changes." : ""}`;
      refresh();
    };
    const applyProposal = async (choice, preferred) => {
      if (!views.has(viewId) || busy || consumed || !supportsApply) throw new Error("Request a fresh preview with the matching language server before applying source.");
      if (applyingSource || workflow.hasPendingCancellation()) throw new Error("Finish the active source update or cancellation before applying another proposal.");
      applyingSource = true;
      busy = true; status = "Checking source and editor inputs…"; refresh();
      try {
        if (choice) {
          if (selection.newRevision) throw new Error("Apply the new revision before choosing its field conversions.");
          if (typeof preview.inputDigest !== "string" || !choice.decisionId || !choice.optionId) throw new Error("This option is advisory; the compiler has not supplied a checked choice.");
          // Pass only compiler identifiers and its full input digest. Never send
          // a copied/client-edited template as source authority.
          consumed = true;
          const selected = await languageClient.sendRequest("workspace/executeCommand", { command: "tesl.generateMigration", arguments: [{ ...selection, decisionId: choice.decisionId, optionId: choice.optionId, expectedInputDigest: preview.inputDigest }] });
          if (!selected?.ok) throw new Error((selected?.errors || []).map((item) => item.message).join("\n") || "Compiler refused the selected source choice.");
          preview = selected; items = previewItems(preview); index = -1;
        }
        consumed = true; operationPreviewId = preview.previewId;
        let result;
        try {
          result = await languageClient.sendRequest("workspace/executeCommand", { command: "tesl.applyMigration", arguments: [{ previewId: operationPreviewId }] });
        } catch (error) {
          // These protocol errors are produced before the server starts a
          // source transaction. A stale/refused request is not a lost commit.
          if (error.code === -32801 || error.code === -32602) {
            result = { ok: false, active: false, error: error.message, sourceTransaction: { outcome: "unchanged", recoveryRequired: false } };
          } else {
          // A lost acknowledgement does not mean files or buffers were unchanged.
          try { result = await languageClient.sendRequest("workspace/executeCommand", { command: "tesl.migrationApplicationStatus", arguments: [{ previewId: operationPreviewId }] }); }
          catch (_) { status = `Application outcome is unknown: ${error.message}. Preserve buffers and .tesl-source-edit recovery state; do not repeat the apply blindly.`; refresh(); return; }
          }
        }
        showOutcome(result);
        if (result?.ok !== true || result?.active || result?.sourceTransaction?.outcome !== "committed" || result?.sourceTransaction?.recoveryRequired) return { result };
        if (viewOptions.afterApply) {
          await viewOptions.afterApply();
          return { result };
        }
        status = "Source files and buffers updated. Opening custom-code holes and rechecking the application…"; refresh();
        try {
          await restoreDiscardedDocuments(vscode, projectRoot);
          await openCustomCode(preview, preferred);
          const next = await requestPreview(entry, preview.database, { ...viewOptions, newRevision: false, contractVersion: undefined, silent: false, preserveFocus: true });
          if (next) { panelDisposed = true; views.delete(viewId); if (!viewOptions.flow) panel?.dispose(); }
          return { result, nextView: next };
        } catch (error) {
          status = `Source was committed; follow-up check failed: ${error.message}`; refresh();
          return { result, error: error.message };
        }
      } catch (error) { status = `No committed source update was confirmed: ${error.message}`; throw error; }
      finally { applyingSource = false; busy = false; refresh(); }
    };
    if (panel && viewOptions.flow) viewOptions.flow.previewListener?.dispose();
    const previewListener = panel?.webview.onDidReceiveMessage(async (message) => {
      try {
        if (!["refresh", "overview", "select", "next", "previous", "apply", "choose", "status", "edit", "source", "diff"].includes(message?.action)) return;
        if (!requireTrustedWorkspace() || !message || typeof message.action !== "string") return;
        if (busy && message.action !== "status") return;
        if (message.action === "refresh") { await requestPreview(entry, selectedDatabase, viewOptions); panelDisposed = true; if (!viewOptions.flow) panel.dispose(); return; }
        if (message.action === "overview") index = -1;
        if (message.action === "select" && Number.isInteger(message.index) && message.index >= 0 && message.index < items.length) index = message.index;
        if (message.action === "next") index = viewOptions.flow && index >= items.length - 1 ? 0 : Math.min(items.length - 1, index + 1);
        if (message.action === "previous") index = Math.max(-1, index - 1);
        const item = items[index];
        if (message.action === "apply") { await vscode.commands.executeCommand("tesl.applyMigrationSource", { previewId: viewId }); return; }
        if (message.action === "choose" && item && Number.isInteger(message.optionIndex)) {
          const option = item.options?.[message.optionIndex];
          if (!item.decisionId || !option?.id) throw new Error("The compiler has not supplied a checked option here.");
          await vscode.commands.executeCommand("tesl.applyMigrationChoice", { previewId: viewId, decisionId: item.decisionId, optionId: option.id }); return;
        }
        if (message.action === "status" && operationPreviewId) {
          const result = await languageClient.sendRequest("workspace/executeCommand", { command: "tesl.migrationApplicationStatus", arguments: [{ previewId: operationPreviewId }] });
          showOutcome(result); return;
        }
        if (message.action === "edit" && item && inside(projectRoot, item.file)) {
          if (!consumed && supportsApply && preview.files.some((file) => file.path === item.file)) { await applyProposal(undefined, item); return; }
          await openCustomCode(preview, item);
        }
        if (message.action === "source" && item) await openLocation(item);
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
    if (panel && viewOptions.flow) viewOptions.flow.previewListener = previewListener;
    views.clear();
    const view = {
      preview,
      supportsApply,
      apply: () => applyProposal(),
      edit: () => openCustomCode(preview),
      status: async () => {
        if (!operationPreviewId) throw new Error("No source transaction was started.");
        return languageClient.sendRequest("workspace/executeCommand", { command: "tesl.migrationApplicationStatus", arguments: [{ previewId: operationPreviewId }] });
      },
      choose: (decisionId, optionId) => {
        const item = items.find((candidate) => candidate.decisionId === decisionId && candidate.options?.some((option) => option.id === optionId));
        if (!item) throw new Error("That compiler choice is not present in the retained migration view.");
        return applyProposal({ decisionId, optionId }, item);
      },
    };
    views.set(viewId, view);
    const result = { version: 1, kind: "migration-editor-view", previewId: viewId, inputDigest: preview.inputDigest,
      entryFile: entry.fsPath, projectRoot,
      operation: preview.operation, revisionBefore: preview.revisionBefore, revisionAfter: preview.revisionAfter, schemaFiles: preview.schemaFiles,
      cleanup: preview.cleanup || [], contractVersion: preview.contractVersion,
      database: preview.database, compilable: preview.compilable, decisions: preview.decisions || [],
      files: preview.files, diagnostics: preview.diagnostics };
    if (viewOptions.flow) { viewOptions.flow.view = result; viewOptions.flow.refreshPreview = refresh; }
    refresh();
    return result;
  }

  const retainedView = (params) => {
    if (!requireTrustedWorkspace()) throw new Error("Trust this workspace before applying migration source.");
    if (!params || typeof params.previewId !== "string" || !views.has(params.previewId)) throw new Error("Migration view expired; request a fresh preview.");
    return views.get(params.previewId);
  };
  const workflow = registerMigrationFlow(vscode, context, { requestPreview, getView: retainedView, requireTrustedWorkspace, isApplying: () => applyingSource });
  context.subscriptions.push(vscode.commands.registerCommand("tesl.applyMigrationSource", async (params) => retainedView(params).apply()));
  context.subscriptions.push(vscode.commands.registerCommand("tesl.editMigrationHole", async (params) => retainedView(params).edit()));
  context.subscriptions.push(vscode.commands.registerCommand("tesl.applyMigrationChoice", async (params) => {
    if (typeof params?.decisionId !== "string" || typeof params?.optionId !== "string") throw new Error("Select an explicit compiler decision and option.");
    return retainedView(params).choose(params.decisionId, params.optionId);
  }));

  context.subscriptions.push(vscode.commands.registerCommand("tesl.previewMigration", async (uri) => {
    try { return await requestPreview(uri); } catch (error) {
      vscode.window.showErrorMessage(`Tesl migration: ${error.message}`);
      return { kind: "migration-editor-error", ok: false, error: error.message };
    }
  }));
  context.subscriptions.push(vscode.commands.registerCommand("tesl.migrateDatabase", workflow.open));
  context.subscriptions.push(vscode.languages.registerCompletionItemProvider({ scheme: "file", language: "tesl" }, {
    async provideCompletionItems(document, position, token) {
      if (token.isCancellationRequested || !vscode.workspace.isTrusted || !/[\\/]migrations[\\/]/.test(document.uri.fsPath)) return [];
      const line = document.lineAt(position.line).text;
      // Whole migration choices belong at compiler-generated decision holes,
      // not inside comments, strings or handwritten conversion bodies.
      if (codeHoleOffset(line) < 0 || position.character > codeHoleOffset(line) + 4) return [];
      const candidates = [...selections.values()].filter((selection) => inside(selection.projectRoot, document.uri.fsPath));
      const itemFor = (label, detail, command, rank = 0) => {
        const item = new vscode.CompletionItem(label, vscode.CompletionItemKind.Snippet);
        item.detail = detail;
        item.documentation = detail;
        // Acceptance performs no textual replacement. Its command applies the
        // complete compiler-owned, version-guarded multi-file transaction.
        item.insertText = "";
        item.range = new vscode.Range(position.line, position.character, position.line, position.character);
        item.filterText = `todo ${label}`;
        item.sortText = `000:${String(rank).padStart(4, "0")}:${label}`;
        item.command = command;
        return item;
      };
      if (candidates.length !== 1) return [itemFor("Set up migration choices…", "Start or continue a migration; Tesl then offers complete migration scaffolds here.", { title: "Migrate database/queues", command: "tesl.migrateDatabase", arguments: [document.uri] })];
      const version = document.version;
      const { entry, database } = candidates[0];
      try {
        const flow = workflow.find(entry, database);
        const result = await requestPreview(entry, database, { silent: true, flow, expectedRevision: flow?.revision });
        if (!result || token.isCancellationRequested || document.version !== version || document.isClosed) return [];
        const view = views.get(result.previewId);
        if (!view?.supportsApply || !result.inputDigest) return [];
        return result.decisions.filter((decision) => decision.file === document.uri.fsPath && decision.line === position.line)
          .flatMap((decision) => decision.options.map((option, rank) => itemFor(
            `${decision.entity}: ${option.label}`, option.help,
            { title: "Fill migration boilerplate", command: "tesl.completeMigrationDecision", arguments: [{ previewId: result.previewId, decisionId: decision.id, optionId: option.id }] }, rank)));
      } catch (_) { return []; } // Keep compiler diagnostics visible; completion never opens an error popup.
    },
  }));
  context.subscriptions.push(vscode.commands.registerCommand("tesl.completeMigrationDecision", async (params) => {
    try { return await retainedView(params).choose(params.decisionId, params.optionId); }
    catch (error) { vscode.window.showErrorMessage(`Tesl migration: ${error.message}`); }
  }));
  context.subscriptions.push(vscode.commands.registerCommand("tesl.migrationGuide", workflow.open));
  context.subscriptions.push(vscode.commands.registerCommand("tesl.migrationReference", () => {
    const panel = vscode.window.createWebviewPanel("teslMigrationHelp", "Tesl Migration Reference", vscode.ViewColumn.Beside, { enableScripts: true });
    let index = -1;
    const nonce = randomBytes(16).toString("hex");
    const refresh = () => { panel.webview.html = renderGuide(generalHelp, index, nonce, "Migration reference", "General background, independent of any application.", { reference: true }); };
    panel.webview.onDidReceiveMessage(async (message) => {
      if (message.action === "refresh") { await vscode.commands.executeCommand("tesl.migrationGuide"); return; }
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
      return migrationLensLocations(document.getText(), document.uri?.fsPath).flatMap((line) => [
        new vscode.CodeLens(new vscode.Range(line, 0, line, 0), { title: "Migrate database/queues…", command: "tesl.migrateDatabase", arguments: [document.uri] }),
      ]);
    },
  }));
  context.subscriptions.push(vscode.languages.registerCodeActionsProvider({ scheme: "file", language: "tesl" }, {
    provideCodeActions(document, _range, actionContext) {
      if (!vscode.workspace.isTrusted) return [];
      const diagnostics = actionContext.diagnostics.filter((diagnostic) => /^MIG\d+$/.test(String(diagnostic.code?.value ?? diagnostic.code)));
      if (!diagnostics.length) return [];
      const guide = new vscode.CodeAction("Tesl: Inspect migration source diagnostics", vscode.CodeActionKind.QuickFix);
      guide.command = { title: guide.title, command: "tesl.previewMigration", arguments: [document.uri] };
      guide.diagnostics = diagnostics;
      // Frozen-history mismatches need restoration, not regeneration.
      const actionable = diagnostics.filter((diagnostic) => String(diagnostic.code?.value ?? diagnostic.code) !== "MIG013");
      if (!actionable.length) return [guide];
      const migrate = new vscode.CodeAction("Tesl: Migrate database/queues", vscode.CodeActionKind.QuickFix);
      migrate.command = { title: migrate.title, command: "tesl.migrateDatabase", arguments: [document.uri] };
      migrate.diagnostics = actionable;
      return [migrate, guide];
    },
  }, { providedCodeActionKinds: [vscode.CodeActionKind.QuickFix] }));
}

module.exports = { registerMigrationAuthoring, migrationLensLocations, previewItems, renderGuide, inside, codeHoleOffset, codeHoleRange };
