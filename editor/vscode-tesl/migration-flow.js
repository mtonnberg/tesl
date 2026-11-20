"use strict";

const path = require("path");
const fs = require("fs");
const { randomBytes, createHash } = require("crypto");
const { projectForFile } = require("./migration-project");
const { captureDraft, reviewCancellation, restoreDraft } = require("./migration-cancel");

const escape = (value) => String(value ?? "").replace(/[&<>"']/g, (char) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
const button = (action, title, primary = false, attributes = "") => `<button class="${primary ? "primary" : "link"}" data-action="${action}" ${attributes}>${escape(title)}</button>`;
const more = (title, content) => `<details><summary>${escape(title)}</summary>${content}</details>`;
const firstSentence = (text) => String(text || "").split(/\n|\. /)[0];
const planTitle = (option) => ({
  "additive-default": "Give existing rows a default value",
  "migrate-validators": "Use my updated validation rules",
  "migrate-retype": "Write a custom value conversion",
  "require-value": "Keep existing values and fill in missing ones",
  "map-fields": "Map changed fields and keep older versions compatible",
  "delete-rows": "Delete obsolete rows and convert the rest",
  "map-queued-payload": "Convert retained jobs to the new payload",
  "remove-empty-queue": "Retire this queue after it is empty",
})[option.id] || option.title;

// Test runs create build/cache files, so the source-edit manifest's directory
// guards are intentionally too strict for comparing source before/after tests.
// Compare project source bytes instead; editor events also catch edit-and-undo.
function projectSources(root, vscode) {
  const hash = createHash("sha256");
  const excluded = new Set([".git", ".tesl-stuff", ".tesl-postgres", ".direnv", "_build", "node_modules", "result"]);
  const visit = (directory) => {
    for (const item of fs.readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      if (excluded.has(item.name)) continue;
      const file = path.join(directory, item.name);
      if (item.isDirectory()) visit(file);
      else if (item.name.endsWith(".tesl") || item.name === "tesl.toml") {
        hash.update(JSON.stringify([path.relative(root, file), createHash("sha256").update(fs.readFileSync(file)).digest("hex")]));
      }
    }
  };
  visit(root);
  for (const document of vscode.workspace.textDocuments || []) {
    const relative = document.uri.scheme === "file" && path.relative(root, document.uri.fsPath);
    if (document.isDirty && typeof relative === "string" && !path.isAbsolute(relative) && relative !== ".." && !relative.startsWith(`..${path.sep}`)) hash.update(JSON.stringify([relative, document.getText()]));
  }
  return hash.digest("hex");
}

function page(nonce, state, title, body, primary, footer = "") {
  return `<!DOCTYPE html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';">
<style>
body{font-family:var(--vscode-font-family);color:var(--vscode-foreground);max-width:760px;padding:24px;line-height:1.5}h1{font-size:1.7em;margin:12px 0}h2{font-size:1.15em}.state,.muted{color:var(--vscode-descriptionForeground)}
button{cursor:pointer;border:0;border-radius:3px;padding:8px 14px;margin:8px 8px 8px 0}.primary{background:var(--vscode-button-background);color:var(--vscode-button-foreground)}.primary:hover{background:var(--vscode-button-hoverBackground)}.link{background:transparent;color:var(--vscode-textLink-foreground);padding:2px 0;text-align:left}button:disabled{opacity:.5;cursor:default}
button:focus-visible,input:focus-visible,summary:focus-visible{outline:2px solid var(--vscode-focusBorder)}details{margin:12px 0}summary{cursor:pointer;color:var(--vscode-textLink-foreground)}pre{white-space:pre-wrap;overflow-wrap:anywhere}label{display:block;padding:12px;border:1px solid var(--vscode-panel-border);margin:8px 0;cursor:pointer}label p{margin:6px 0 0 24px}.actions{margin-top:20px}footer{margin-top:28px}li{margin:6px 0}
</style></head><body><p class="state">${escape(state)}</p><h1>${escape(title)}</h1>${body}<div class="actions">${primary}</div>${footer ? `<footer>${footer}</footer>` : ""}
<script nonce="${nonce}">const vscode=acquireVsCodeApi();document.addEventListener('change',()=>{const b=document.getElementById('generate-plan');if(b)b.disabled=!document.querySelector('input[name="plan"]:checked');});document.addEventListener('click',event=>{const b=event.target.closest('button');if(!b||b.disabled)return;const selected=document.querySelector('input[name="plan"]:checked');vscode.postMessage({action:b.dataset.action,index:b.dataset.index===undefined?undefined:Number(b.dataset.index),optionIndex:b.dataset.action==='choose'&&selected?Number(selected.value):undefined});});</script></body></html>`;
}

function renderFlow(flow) {
  const { nonce, stage, revision, draft, error } = flow;
  const navigation = `${button("back", "Back")}${button("cancel", "Cancel migration")}`;
  if (stage === "welcome") {
    const resume = draft && draft.status !== "complete" && !flow.forceNew;
    return page(nonce, resume ? `Draft V${draft.revision}` : "Ready to start",
      "Migrate database/queues",
      `<p>${resume ? `V${draft.revision} is still marked as an open draft. Continue to finish it, or start a new revision below.` : draft?.status === "complete" ? `V${draft.revision} authoring is complete. Start prepares the next revision; your existing migration files are kept.` : "Change your schema with help from the compiler. Tesl writes the migration code; you choose what happens to existing data."}</p>`,
      button(resume ? "resume" : "start", resume ? `Continue migration V${draft.revision}` : "Start migration", true),
      `<ol><li>Prepare migration files ${more("About this step", "<p>Start saves a versioned copy of your current schema and prepares the next migration. Wait for the next page before making schema changes.</p>")}</li><li>Edit your schema</li><li>Choose values for existing data</li><li>Check, test and finish</li></ol><p class="muted">Start and review change source files only. Deployment is a separate step.</p>${resume ? button("new", "Start a new migration instead") : ""}${button("cancel", resume ? "Cancel migration" : "Close")}${more("Continue work already started", `<p>Use this for an existing, undeployed draft.</p>${button("resume", "Continue an existing draft")}`)}`);
  }
  if (stage === "prepared") return page(nonce, `Step 1 of 4 · V${revision}`, "Your working copy is ready",
    "<p>The previous schema has been saved. Continue to edit the current schema, or cancel to restore the files from before you started.</p>",
    button("editStep", "Edit schema", true), button("cancel", "Cancel migration"));
  if (stage === "cleanup-needed") return page(nonce, `Step 4 of 4 · draft V${revision}`, "Review the cleanup instructions",
    "<p>The conversion checks pass. Tesl also needs a reviewed source file describing how to retire the old storage after deployment. It will generate that file for you.</p>",
    button("cleanup", "Review cleanup", true), `${navigation}<p class="muted">This writes source only. Runtime cleanup still waits for completed conversion and retirement of old writers.</p>`);
  if (stage === "cancel") return page(nonce, revision || draft?.revision || flow.backup?.revision ? `Draft V${revision || draft?.revision || flow.backup?.revision}` : "Migration not started", "Discard this draft?",
    flow.backup ? `<p>Restore this schema and migration family to its state before Start. This discards your draft edits and removes files created during the draft.</p><p>Other application files are not changed. Only cancel a draft that has not been deployed.</p>` :
      "<p>This draft has no Start backup. You can close the workflow, but its existing files will be kept.</p>",
    button(flow.backup ? "confirmCancel" : "close", flow.backup ? "Discard draft and restore files" : "Close and keep files", true),
    `${button("keepEditing", "Keep editing")}${flow.backup ? more("Files to restore or remove", `<p>${escape(flow.backup.scopes.join("\n"))}</p><ul>${(flow.cancelPlan?.changedPaths || []).map((file) => `<li>${escape(file)}</li>`).join("")}</ul>`) : ""}`);
  if (stage === "cancelled") return page(nonce, "Cancelled", "Draft changes discarded",
    "<p>The schema and migration files have been restored to their pre-Start state.</p>", button("close", "Close", true));
  if (stage === "cancelFailed") return page(nonce, "Cancellation incomplete", "Finish restoring the draft",
    `<p>${escape(firstSentence(error || "A previous cancellation did not finish."))}</p><p>Your original files are still backed up. Review the remaining changes and retry.</p>`,
    button("cancel", "Review cancellation again", true), more("Details", `<pre>${escape(error)}</pre>`) + button("close", "Close and keep backup"));
  if (stage === "preparing") return page(nonce, "Step 1 of 4 · preparing source", "Preparing your migration…",
    "<p>Checking the current revision before creating the next one. Wait to edit the schema until preparation finishes.</p>", button("start", "Preparing…", true, "disabled"));
  if (stage === "edit") return page(nonce, `Step 2 of 4 · draft V${revision} prepared`, "Now edit your schema",
    `<p>${flow.changedAfterCheck ? "Source changed since the last check. " : ""}Edit the current schema opened beside this page. Change fields, validation or queue payloads, then review your changes.</p><p><code>${escape(flow.schemaFiles?.[0] ? path.relative(flow.projectRoot, flow.schemaFiles[0]) : "v-current.tesl")}</code></p>`,
    button("review", "Review my changes", true),
    `${navigation}${button("openSchema", "Open schema")}<p class="muted">Changes belong to V${revision}. Editing this draft changes source files, not deployed data.</p>${more("About schema warnings", "<p>A temporary stale-schema warning means the migration needs to catch up with your edits. Review my changes updates it.</p>")}`);
  if (stage === "testing") return page(nonce, `Step 4 of 4 · V${revision}`, "Running application tests…",
    "<p>Wait for the test result. You can follow progress in Test Results.</p>", button("tests", "Tests running…", true, "disabled"));
  if (stage === "ready") {
    const passed = flow.testStatus === "passed";
    const testMessage = ({ passed: "Application tests passed for the checked source.", failed: "Application tests failed. Read Test Results and fix the failures.", cancelled: "The test run was cancelled. Run it again before deployment.", empty: "No application tests ran. Add tests or run your test suite separately.", unknown: "See Test Results for the test outcome; this runner did not return a completion result.", stale: "Source changed during the test run. Recheck and rerun tests for the latest source." })[flow.testStatus] || "Tests have not run yet.";
    return page(nonce, `Step 4 of 4 · V${revision} source checks passed`, passed ? `Migration V${revision} is ready` : "Your migration source is ready",
      `<p>${escape(testMessage)}</p><p>Finish keeps your migration files and closes this guide. It does not deploy the migration. Opening the workflow again will offer a new migration.</p>`,
      button(passed ? "finish" : "tests", passed ? "Finish and close" : "Save and run application tests", true),
      `${passed ? button("tests", "Run tests again") : button("finish", "Finish and close")}${button("new", "Start next migration")}${button("review", "Recheck source")}<p class="muted">Deploy separately after checking the results.</p>${more("Edit or discard this draft", navigation + "<p>Back keeps edits. Cancel discards this undeployed draft; it is not a finish action.</p>")}${more("Deployment", `<p>Deploy the checked artifact using your migration Worker process. Review the physical plan and required cleanup Contract first.</p>${button("reference", "Open migration reference")}`)}`);
  }
  if (stage === "recovery") return page(nonce, "Source update needs attention", "Check the source update",
    "<p>The source update has not been confirmed complete. Check its outcome before starting another migration.</p>",
    button("status", "Check source update", true), more("Details", `<pre>${escape(error)}</pre><p>Preserve open buffers and the .tesl-source-edit journal if recovery is required.</p>`));
  return page(nonce, flow.revision ? `Draft V${revision} · action blocked` : "Not started · preparation blocked", flow.revision ? "Resolve this before continuing" : "The new revision could not be prepared",
    `<p>${escape(firstSentence(error || "Preparation could not complete."))}</p><p>${flow.revision ? "Your draft is still here. Resolve this issue, then recheck." : flow.restored ? "No new revision was created. The source update was refused or restored, and your edits were preserved." : "No new revision has been confirmed. Resolve the reported issue, then try Start again."}</p>`,
    button(flow.reviewCleanup ? "resume" : flow.revision ? "review" : "start", flow.reviewCleanup ? "Review the existing revision's cleanup" : flow.revision ? "Recheck my draft" : "Try Start again", true),
    `${navigation}${more("Compiler details", `<pre>${escape(error)}</pre>`)}${button("openSchema", "Open current schema")}${!flow.revision ? more("Schema already edited?", "<p>Keep those edits separately, restore the previous source, then Start and reapply the edits. Or continue the existing revision if it is still an undeployed draft.</p>") + button("resume", "Continue existing draft") : ""}`);
}

function renderFlowReview(flow, preview, items, index, controls) {
  flow.previewId = preview.previewId;
  if (!controls.busy && !controls.consumed) flow.stage = flow.changedAfterCheck ? "review" : preview.operation === "contract" ? "cleanup" :
    preview.compilable && preview.files.length === 0 && !flow.reviewOnly ? (preview.cleanup?.some((item) => !item.present) ? "cleanup-needed" : "ready") : "review";
  if (["ready", "cleanup-needed"].includes(flow.stage) && !controls.busy && !controls.consumed) return renderFlow(flow);
  const item = items[index] || items[0];
  const actionable = controls.canChoose && item?.decisionId && item.options?.some((option) => option.id);
  const state = `Step 3 of 4 · draft V${flow.revision} · source only`;
  let title, body, primary;
  if (controls.busy || controls.consumed) {
    title = controls.busy ? "Updating migration source…" : "Recheck this source update";
    body = `<p>${escape(controls.status || "Checking the source transaction.")}</p>`;
    primary = button(controls.canStatus ? "status" : "refresh", controls.canStatus ? "Check source update" : "Recheck source", true, controls.busy ? "disabled" : "");
  } else if (flow.changedAfterCheck) {
    title = "Recheck your changes";
    body = "<p>You edited the source since this review. Recheck to find any remaining values or continue to the final checks.</p>";
    primary = button("review", "Recheck and continue", true);
  } else if (preview.operation === "contract") {
    title = `Cleanup for V${preview.contractVersion}`;
    body = "<p>Review the proposed file below. It authorizes removal of retained old storage only after the runtime's completion and old-writer checks pass.</p>";
    primary = button("apply", "Add reviewed cleanup source", true, controls.canApply ? "" : "disabled");
  } else if (actionable) {
    title = "How should existing data be handled?";
    body = `<p>${escape(firstSentence(item.summary))}</p><p>Choose a plan. Tesl writes the migration and opens the value you need to supply.</p>` + item.options.map((option, number) =>
      `<label><input type="radio" name="plan" value="${number}"> <strong>${escape(planTitle(option))}</strong><p>${escape(firstSentence(option.when))}</p></label>${more("Plan details", `<p>${escape(option.when)}</p><pre>${escape(option.example || "")}</pre>`)}`).join("");
    primary = button("choose", "Generate this plan", true, 'id="generate-plan" disabled');
  } else if (item?.decisionId) {
    title = "Adjust this change before continuing";
    body = `<p>${escape(item.summary)}</p><p>The compiler has no automatic plan for this combination. Return to the schema step and follow the constraint above.</p>`;
    primary = button("openSchema", "Return to schema", true);
  } else if (preview.compilable) {
    title = "Write the generated migration";
    body = "<p>Your changes pass the compiler's checks. Write the proposed source files to finish this draft.</p>";
    primary = preview.files.length ? button("apply", "Write migration files", true) : button("finishReview", "Continue to checks", true);
  } else {
    title = item?.code === "MIG003" ? "Fill in your domain logic" : "One source issue needs attention";
    body = `<p>${escape(firstSentence(item?.summary || "Resolve the compiler diagnostic, then recheck."))}</p>`;
    body += "<p>Fill the selected value in your editor, then recheck to continue.</p>";
    primary = button("review", "Recheck and continue", true);
    body += button(item?.code === "MIG003" ? "edit" : "source", item?.code === "MIG003" ? "Open remaining value or policy" : "Open source issue");
  }
  return page(flow.nonce, state, title, body, primary,
    `${controls.canLeave ?? (!controls.busy && !controls.consumed) ? button("back", "Back") + button("cancel", "Cancel migration") : ""}${button("refresh", "Recheck my changes")}${items.length > 1 ? button("next", `Next item (${Math.max(0, index) + 1}/${items.length})`) : ""}
${more("Details and source changes", `<p>${escape(item?.summary || "")}</p>${(item?.help || []).map((text) => `<p>${escape(text)}</p>`).join("")}<pre>${escape(item?.diagnostic || "")}</pre><div id="files"></div>${controls.canApply && !preview.compilable ? button("apply", "Write proposal without choosing a plan") : ""}`)}`);
}

function registerMigrationFlow(vscode, context, { requestPreview, getView, requireTrustedWorkspace, isApplying = () => false }) {
  const flows = new Map();
  const within = (root, file) => { const relative = path.relative(root, file); return relative === "" || relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative); };
  const snapshot = (flow) => ({ kind: "migration-authoring-flow", flowId: flow.id, stage: flow.stage, revision: flow.revision,
    entryFile: flow.entryFile, projectRoot: flow.projectRoot, previewId: flow.previewId, view: flow.view, testStatus: flow.testStatus, ...(flow.error ? { error: flow.error } : {}) });
  const render = (flow) => { if (!flow.disposed && !["review", "cleanup"].includes(flow.stage)) flow.panel.webview.html = renderFlow(flow); };
  const persistBackup = async (flow, backup) => { await context.workspaceState?.update(`${flow.key}:backup`, backup); flow.backup = backup; };
  async function openSchema(flow) {
    const file = flow.schemaFiles?.find((file) => /v-current\.tesl$/.test(file)) || flow.schemaFiles?.[0] || flow.sourceUri?.fsPath;
    if (!file || !flow.projectRoot || !within(flow.projectRoot, file)) return;
    const doc = await vscode.workspace.openTextDocument(vscode.Uri.file(file));
    await vscode.window.showTextDocument(doc, { preview: false, preserveFocus: false });
  }
  async function remember(flow, view) {
    flow.entryFile = view.entryFile; flow.projectRoot = view.projectRoot; flow.database = view.database;
    flow.revision = view.revisionAfter; flow.schemaFiles = view.schemaFiles; flow.previewId = view.previewId;
    flow.draft = { entryFile: flow.entryFile, projectRoot: flow.projectRoot, database: flow.database, revision: flow.revision, schemaFiles: flow.schemaFiles,
      ...(flow.testStatus === "passed" && !flow.changedAfterCheck ? { status: "complete" } : {}) };
    await context.workspaceState?.update(flow.key, flow.draft);
  }
  function requireMetadata(view) {
    if (!Number.isInteger(view?.revisionAfter) || view.revisionAfter < 2 || !Array.isArray(view.schemaFiles) || !view.schemaFiles.length) {
      throw new Error("Update the matching Tesl language server: revision and current-schema metadata are required for this workflow.");
    }
  }
  async function reviewed(flow, resume = false) {
    const draft = resume ? flow.draft : undefined;
    const entry = draft?.entryFile || flow.entryFile;
    const view = await requestPreview(entry ? vscode.Uri.file(entry) : flow.sourceUri, draft?.database || flow.database,
      { flow, guided: true, expectedRevision: draft?.revision || flow.revision, sourceUri: flow.sourceUri });
    if (!view) return;
    requireMetadata(view);
    if (view.operation !== "refresh") throw new Error("There is no existing draft to continue. Use Start migration first.");
    await remember(flow, view); flow.view = view;
    if (flow.stage === "ready") render(flow);
    return view;
  }
  async function prepared(flow, view) {
    await remember(flow, view);
    flow.stage = "edit"; flow.error = ""; flow.view = undefined; flow.testStatus = undefined;
    render(flow); await openSchema(flow);
  }
  function unsuccessful(flow, result) {
    flow.restored = !result?.active && !result?.sourceTransaction?.recoveryRequired && ["unchanged", "restored"].includes(result?.sourceTransaction?.outcome);
    flow.stage = flow.restored ? "blocked" : "recovery";
    flow.error = result?.error || "Source application outcome is not confirmed.";
  }
  async function saveProject(flow) {
    for (const document of vscode.workspace.textDocuments || []) {
      if (document.isDirty && document.uri.scheme === "file" && document.languageId === "tesl" && within(flow.projectRoot, document.uri.fsPath)) {
        if (!await document.save()) throw new Error("A project source file could not be saved. Save it before continuing.");
      }
    }
  }
  async function finish(flow) {
    await saveProject(flow);
    flow.reviewOnly = false;
    const checked = await reviewed(flow);
    if (flow.stage !== "ready" || !checked?.compilable || checked.files.length) return false;
    await persistBackup(flow, undefined);
    await context.workspaceState?.update(flow.key, undefined);
    flow.draft = undefined;
    return true;
  }
  async function action(flow, name) {
    if (!requireTrustedWorkspace() || flow.disposed || flow.busy || isApplying()) return snapshot(flow);
    flow.busy = true;
    try {
      if (name === "start") {
        if (!["welcome", "blocked"].includes(flow.stage) || flow.revision) return snapshot(flow);
        flow.stage = "preparing"; flow.restored = false; render(flow);
        const view = await requestPreview(flow.sourceUri, undefined, { newRevision: true, silent: true,
          afterApply: async () => prepared(flow, flow.startView) });
        if (!view) { flow.stage = "welcome"; return snapshot(flow); }
        requireMetadata(view);
        if (view.operation !== "start" || !view.compilable) throw new Error("The current source must compile before starting a new revision. Resolve its diagnostics and try again.");
        await persistBackup(flow, captureDraft(vscode, view));
        flow.startView = view;
        flow.startHandle = getView(view);
        const applied = await flow.startHandle.apply();
        if (applied?.result?.sourceTransaction?.outcome !== "committed" || !applied.result.ok || applied.result.sourceTransaction.recoveryRequired) {
          unsuccessful(flow, applied?.result);
          if (flow.restored) await persistBackup(flow, undefined);
        }
      } else if (name === "resume") {
        if (!["welcome", "blocked"].includes(flow.stage)) return snapshot(flow);
        await reviewed(flow, true);
      } else if (name === "review") {
        if (!flow.revision) return snapshot(flow);
        flow.reviewOnly = false;
        flow.changedAfterCheck = false;
        await reviewed(flow);
      } else if (name === "cleanup" && flow.revision) {
        const required = flow.view?.cleanup?.find((item) => !item.present);
        if (!required) return snapshot(flow);
        await requestPreview(vscode.Uri.file(flow.entryFile), flow.database, { flow, guided: true, expectedRevision: flow.revision, contractVersion: required.version });
      } else if (name === "openSchema") { if (flow.stage === "ready") flow.stage = "edit"; await openSchema(flow); }
      else if (name === "tests" && flow.stage === "ready") {
        flow.testStatus = undefined;
        await saveProject(flow);
        const checked = await reviewed(flow);
        if (flow.stage === "ready" && checked?.compilable && checked.files.length === 0) {
          const epoch = flow.sourceEpoch, sources = projectSources(flow.projectRoot, vscode);
          flow.stage = "testing"; render(flow);
          const result = await vscode.commands.executeCommand("tesl.runTests", vscode.Uri.file(flow.entryFile));
          const after = await reviewed(flow);
          flow.testStatus = epoch !== flow.sourceEpoch || sources !== projectSources(flow.projectRoot, vscode) ? "stale" :
            result?.kind === "tesl-test-result" && ["passed", "failed", "cancelled", "empty"].includes(result.status) ? result.status : "unknown";
          if (flow.stage === "ready") await remember(flow, after);
        }
      } else if (name === "finish" && flow.stage === "ready") {
        if (await finish(flow)) { flow.stage = "finished"; flow.panel.dispose(); }
      } else if (name === "reference") await vscode.commands.executeCommand("tesl.migrationReference");
      else if (name === "new" && ["welcome", "ready"].includes(flow.stage)) {
        if (flow.stage === "ready" && !await finish(flow)) return snapshot(flow);
        flow.previewListener?.dispose(); flow.previewListener = undefined;
        flow.forceNew = true; flow.stage = "welcome"; flow.revision = undefined; flow.view = undefined;
      }
      else if (name === "back" && !["preparing", "recovery", "cancelFailed"].includes(flow.stage)) {
        flow.previewListener?.dispose(); flow.previewListener = undefined;
        if (["ready", "cleanup-needed", "cleanup"].includes(flow.stage)) { flow.reviewOnly = true; await reviewed(flow); }
        else if (flow.stage === "review") { flow.stage = "edit"; await openSchema(flow); }
        else flow.stage = flow.revision ? "prepared" : "welcome";
      } else if (name === "editStep" && flow.revision) { flow.stage = "edit"; await openSchema(flow); }
      else if (name === "finishReview" && flow.view?.compilable && !flow.view.files.length) { flow.reviewOnly = false; flow.stage = flow.view.cleanup?.some((item) => !item.present) ? "cleanup-needed" : "ready"; }
      else if (name === "cancel" && !["preparing", "recovery"].includes(flow.stage)) {
        flow.previewListener?.dispose(); flow.previewListener = undefined;
        if (flow.stage === "welcome" && (flow.forceNew || flow.draft?.status === "complete")) { flow.panel.dispose(); return snapshot(flow); }
        if (!flow.revision && !flow.backup && !flow.draft) { flow.panel.dispose(); return snapshot(flow); }
        flow.cancelReturn = flow.stage;
        if (flow.backup) {
          if (flow.backup.root !== flow.projectRoot) throw new Error("The cancellation backup belongs to another project.");
          flow.cancelPlan = reviewCancellation(vscode, flow.backup);
        }
        flow.stage = "cancel";
      } else if (name === "keepEditing" && flow.stage === "cancel") {
        if (["review", "ready", "cleanup", "cleanup-needed"].includes(flow.cancelReturn)) await reviewed(flow);
        else flow.stage = flow.cancelReturn || "edit";
      } else if (name === "confirmCancel" && flow.stage === "cancel" && flow.backup && flow.cancelPlan) {
        await restoreDraft(vscode, flow.backup, flow.cancelPlan, (backup) => persistBackup(flow, backup));
        await context.workspaceState?.update(flow.key, undefined);
        flow.stage = "cancelled"; flow.draft = undefined; flow.revision = undefined; flow.view = undefined;
      } else if (name === "close" && ["cancel", "cancelled", "cancelFailed"].includes(flow.stage)) flow.panel.dispose();
      else if (name === "status" && flow.stage === "recovery" && flow.startHandle) {
        const result = await flow.startHandle.status();
        if (result?.ok && !result.active && result.sourceTransaction?.outcome === "committed" && !result.sourceTransaction.recoveryRequired) await prepared(flow, flow.startView);
        else { unsuccessful(flow, result); if (flow.restored) await persistBackup(flow, undefined); }
      }
    } catch (error) { flow.error = error.message; flow.reviewCleanup = error.reviewCleanup === true; if (flow.backup?.restoring) flow.stage = "cancelFailed"; else if (flow.stage !== "recovery") flow.stage = "blocked"; }
    finally { flow.busy = false; render(flow); }
    return snapshot(flow);
  }
  async function open(uri) {
    if (!requireTrustedWorkspace()) return;
    const sourceUri = uri || vscode.window.activeTextEditor?.document.uri;
    const workspace = sourceUri && vscode.workspace.getWorkspaceFolder(sourceUri)?.uri.fsPath;
    let projectRoot = workspace;
    try { if (workspace) projectRoot = projectForFile(sourceUri.fsPath, workspace).projectRoot; } catch (_) { /* Report discovery errors after Start, in context. */ }
    const key = `tesl.migrationDraft:${projectRoot || sourceUri?.fsPath || "selected"}`;
    const existing = [...flows.values()].find((flow) => flow.key === key && !flow.disposed);
    if (existing) { existing.panel.reveal?.(vscode.ViewColumn.Beside); return snapshot(existing); }
    const flow = { id: randomBytes(16).toString("hex"), key, nonce: randomBytes(16).toString("hex"), stage: "welcome", sourceUri, projectRoot, sourceEpoch: 0,
      draft: context.workspaceState?.get(key), backup: context.workspaceState?.get(`${key}:backup`), panel: vscode.window.createWebviewPanel("teslMigrationFlow", "Migrate database/queues", vscode.ViewColumn.Beside, { enableScripts: true, retainContextWhenHidden: true }) };
    // Older workflows had no cancellation backup. Drop their UI hint when the
    // referenced draft file has been removed, e.g. by an explicit Git restore.
    // Starting still resolves and verifies the real revision with the compiler.
    if (flow.draft && !flow.backup) {
      const schema = flow.draft.schemaFiles?.find((file) => path.basename(file) === "v-current.tesl");
      const relative = schema && path.relative(projectRoot, path.dirname(schema));
      if (relative && /^schema[/\\][^/\\]+$/.test(relative) && Number.isInteger(flow.draft.revision)) {
        const migration = path.join(projectRoot, "migrations", path.basename(relative), `v${flow.draft.revision}.tesl`);
        if (!fs.existsSync(migration)) { flow.draft = undefined; await context.workspaceState?.update(key, undefined); }
      }
    }
    if (flow.backup?.restoring) { flow.stage = "cancelFailed"; flow.revision = flow.draft?.revision; }
    flow.renderReview = (preview, items, index, controls) => renderFlowReview(flow, preview, items, index, controls);
    flow.panel.onDidDispose?.(() => { flow.disposed = true; flow.previewListener?.dispose(); flows.delete(flow.id); }, undefined, context.subscriptions);
    flow.panel.webview.onDidReceiveMessage(async (message) => {
      if (["start", "resume", "review", "cleanup", "openSchema", "tests", "finish", "reference", "new", "back", "editStep", "finishReview", "cancel", "confirmCancel", "keepEditing", "close"].includes(message?.action) || message?.action === "status" && flow.stage === "recovery") await action(flow, message.action);
    }, undefined, context.subscriptions);
    flows.set(flow.id, flow); render(flow); return snapshot(flow);
  }
  context.subscriptions.push(vscode.commands.registerCommand("tesl.migrationFlowAction", async (params) => {
    const flow = flows.get(params?.flowId);
    if (!flow) throw new Error("Migration workflow closed; open Migrate database/queues again.");
    return action(flow, params.action);
  }));
  context.subscriptions.push(vscode.workspace.onDidChangeTextDocument?.(({ document, contentChanges }) => {
    if (contentChanges && contentChanges.length === 0) return;
    for (const flow of flows.values()) if (flow.projectRoot && document.uri?.fsPath && path.extname(document.uri.fsPath) === ".tesl" && within(flow.projectRoot, document.uri.fsPath)) {
      flow.sourceEpoch++;
      flow.testStatus = undefined;
      if (flow.draft?.status === "complete") {
        delete flow.draft.status;
        void context.workspaceState?.update(flow.key, flow.draft);
      }
      if (!isApplying()) flow.changedAfterCheck = true;
      if (!flow.busy && flow.stage === "review") flow.refreshPreview?.();
      if (!flow.busy && ["ready", "cleanup-needed"].includes(flow.stage)) { flow.stage = "edit"; flow.changedAfterCheck = true; render(flow); }
    }
  }) || { dispose() {} });
  return { open, hasPendingCancellation: () => [...flows.values()].some((flow) => flow.backup?.restoring),
    find: (entry, database) => [...flows.values()].find((flow) => !flow.disposed && ["edit", "review", "ready", "prepared"].includes(flow.stage) && flow.entryFile === entry.fsPath && flow.database === database && flow.revision) };
}

module.exports = { registerMigrationFlow, renderFlow, renderFlowReview };
