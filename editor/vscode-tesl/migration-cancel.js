"use strict";

const fs = require("fs");
const path = require("path");
const discardedDocuments = new Map();

const inside = (root, file) => { const relative = path.relative(root, file); return relative === "" || relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative); };
const disk = (file) => {
  try {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || fs.realpathSync(file) !== file) throw new Error(`Cannot restore a linked or non-regular source file: ${file}`);
    return fs.readFileSync(file).toString("base64");
  } catch (error) { if (error.code === "ENOENT") return null; throw error; }
};

function validate(snapshot) {
  if (snapshot?.version !== 1 || !path.isAbsolute(snapshot.root || "") || fs.realpathSync(snapshot.root) !== snapshot.root ||
      !Number.isInteger(snapshot.revision) || !Array.isArray(snapshot.scopes) || snapshot.scopes.length !== 2 || !Array.isArray(snapshot.files)) {
    throw new Error("The cancellation backup is unavailable or invalid. Keep the files and restore them manually.");
  }
  for (const scope of snapshot.scopes) {
    if (!/^(schema|migrations)[/\\][^/\\]+$/.test(scope) || path.normalize(scope) !== scope || !inside(snapshot.root, path.resolve(snapshot.root, scope))) throw new Error("Cancellation scope is outside the selected schema family.");
  }
  for (const record of snapshot.files) {
    const file = path.resolve(snapshot.root, record.path);
    if (path.extname(file) !== ".tesl" || !snapshot.scopes.some((scope) => inside(path.join(snapshot.root, scope), file)) || typeof record.disk !== "string") throw new Error("Invalid cancellation source backup.");
  }
}

function safeParent(snapshot, file, create = false) {
  let directory = snapshot.root;
  for (const component of path.relative(snapshot.root, path.dirname(file)).split(path.sep).filter(Boolean)) {
    directory = path.join(directory, component);
    if (!fs.existsSync(directory) && create) fs.mkdirSync(directory, { mode: 0o700 });
    if (fs.existsSync(directory) && (!fs.lstatSync(directory).isDirectory() || fs.realpathSync(directory) !== directory)) throw new Error(`Source directory changed during cancellation: ${directory}`);
  }
}

function scan(vscode, snapshot) {
  validate(snapshot);
  const files = new Set();
  const visit = (directory) => {
    if (!fs.existsSync(directory)) return;
    if (!fs.lstatSync(directory).isDirectory() || fs.realpathSync(directory) !== directory) throw new Error(`Cancellation cannot follow a linked directory: ${directory}`);
    for (const item of fs.readdirSync(directory, { withFileTypes: true })) {
      const file = path.join(directory, item.name);
      if (item.isSymbolicLink()) throw new Error(`Cancellation cannot follow a source link: ${file}`);
      if (item.isDirectory()) visit(file);
      else if (path.extname(file) === ".tesl") files.add(file);
      if (files.size > 2048) throw new Error("This schema family exceeds the cancellation backup limit.");
    }
  };
  snapshot.scopes.forEach((scope) => visit(path.join(snapshot.root, scope)));
  const documents = (vscode.workspace.textDocuments || []).filter((doc) => !doc.isClosed && doc.uri.scheme === "file" && path.extname(doc.uri.fsPath) === ".tesl" &&
    !(discardedDocuments.get(doc.uri.fsPath) === doc && !doc.isDirty && !fs.existsSync(doc.uri.fsPath)) &&
    snapshot.scopes.some((scope) => inside(path.join(snapshot.root, scope), doc.uri.fsPath)));
  documents.forEach((doc) => files.add(doc.uri.fsPath));
  let bytes = 0;
  const records = [...files].sort().map((file) => {
    const document = documents.find((doc) => doc.uri.fsPath === file);
    const record = { path: path.relative(snapshot.root, file), disk: disk(file), mode: fs.existsSync(file) ? fs.statSync(file).mode & 0o777 : undefined,
      ...(document ? { source: document.getText(), dirty: document.isDirty } : {}) };
    bytes += Buffer.byteLength(JSON.stringify(record));
    if (bytes > 16 * 1024 * 1024) throw new Error("This schema family exceeds the cancellation backup size limit.");
    return record;
  });
  return { records, documents: documents.map((doc) => ({ doc, version: doc.version, source: doc.getText() })) };
}

function captureDraft(vscode, view) {
  const rootFile = view.schemaFiles.find((file) => path.basename(file) === "v-current.tesl");
  const migration = view.files.find((file) => /[/\\]migrations[/\\][^/\\]+[/\\]v\d+\.tesl$/.test(file.path));
  if (!rootFile || !migration) throw new Error("The compiler did not identify the schema and migration files to back up.");
  const snapshot = { version: 1, root: view.projectRoot, revision: view.revisionAfter,
    scopes: [path.relative(view.projectRoot, path.dirname(rootFile)), path.relative(view.projectRoot, path.dirname(migration.path))], files: [] };
  snapshot.files = scan(vscode, snapshot).records;
  if (snapshot.files.some((file) => file.disk === null)) throw new Error("Save new schema files before starting so Cancel can restore their original contents.");
  return snapshot;
}

function reviewCancellation(vscode, snapshot) {
  if (fs.existsSync(path.join(snapshot.root, ".tesl-source-edit"))) throw new Error("A source update is active or needs recovery. Finish that update before cancelling this draft.");
  const current = scan(vscode, snapshot);
  const later = current.records.find((record) => {
    const match = record.path.match(/^(schema|migrations)[/\\][^/\\]+[/\\]v(\d+)(?:-contract)?(?:\.tesl|[/\\])/);
    return match && (match[1] === "schema" ? Number(match[2]) >= snapshot.revision : Number(match[2]) > snapshot.revision);
  });
  if (later) throw new Error(`A later revision exists (${later.path}). Cancel that revision first; this draft cannot be removed underneath it.`);
  const paths = [...new Set([...snapshot.files.map((file) => file.path), ...current.records.map((file) => file.path)])].sort();
  const changedPaths = paths.filter((name) => {
    const original = snapshot.files.find((file) => file.path === name), actual = current.records.find((file) => file.path === name);
    return !original || !actual || original.disk !== actual.disk ||
      (actual.source ?? Buffer.from(actual.disk || "", "base64").toString("utf8")) !== (original.source ?? Buffer.from(original.disk, "base64").toString("utf8"));
  });
  return { current, paths, changedPaths };
}

function checkDocument(vscode, file, captured) {
  const current = (vscode.workspace.textDocuments || []).find((doc) => !doc.isClosed && doc.uri.scheme === "file" && doc.uri.fsPath === file);
  if (captured && (current !== captured.doc || current.version !== captured.version || current.getText() !== captured.source) || !captured && current) {
    throw new Error("A source buffer changed or reopened after the cancellation review. Review Cancel again before discarding it.");
  }
  return current;
}

// Cancellation is a source restore, not a database rollback. The private backup
// is kept until disk and buffers are verified. A partial restore can be reviewed
// and retried; it never deletes its recovery data on a failed edit/save/delete.
async function restoreDraft(vscode, snapshot, plan, persist) {
  validate(snapshot);
  if (fs.existsSync(path.join(snapshot.root, ".tesl-source-edit"))) throw new Error("A source update is active or needs recovery. Finish it before cancellation.");
  const now = scan(vscode, snapshot);
  if (JSON.stringify(now.records) !== JSON.stringify(plan.current.records)) throw new Error("Source changed after the cancellation review. Review Cancel again before discarding it.");
  for (const captured of plan.current.documents) checkDocument(vscode, captured.doc.uri.fsPath, captured);
  snapshot.restoring = true;
  await persist(snapshot);
  for (const relative of plan.paths) {
    if (fs.existsSync(path.join(snapshot.root, ".tesl-source-edit"))) throw new Error("Another source update started during cancellation. The backup is retained.");
    const file = path.resolve(snapshot.root, relative);
    const before = plan.current.records.find((item) => item.path === relative);
    const original = snapshot.files.find((item) => item.path === relative);
    const captured = plan.current.documents.find((item) => item.doc.uri.fsPath === file);
    safeParent(snapshot, file);
    let document = checkDocument(vscode, file, captured);
    let expectedDisk = before?.disk ?? null;
    if (disk(file) !== expectedDisk) throw new Error(`Source changed during cancellation: ${relative}`);
    if (!original) {
      // openTextDocument can preload a clean file without a tab. Give that
      // working copy a tab so deletion/close also removes its LSP overlay;
      // otherwise a deleted migration could remain visible to the compiler.
      if (document && !document.isClosed && !document.isDirty) {
        const expected = document.getText(), version = document.version;
        const editor = await vscode.window.showTextDocument(document, { preview: false, preserveFocus: true });
        if (document.isClosed || editor.document !== document || document.version !== version || document.getText() !== expected) throw new Error(`Draft changed before deletion: ${relative}`);
      }
      // Discard only the reviewed draft text through a version-guarded edit,
      // then save its existing disk image so the editor can close the clean
      // resource without another unsaved-file prompt. Concurrent typing remains
      // in its buffer and stops cancellation rather than being silently lost.
      if (document?.isDirty) {
        const saved = Buffer.from(before?.disk || "", "base64").toString("utf8");
        const expected = document.getText(), version = document.version;
        const editor = await vscode.window.showTextDocument(document, { preview: false, preserveFocus: true });
        if (document.isClosed || editor.document !== document || document.version !== version || document.getText() !== expected) throw new Error(`Draft changed before deletion: ${relative}`);
        const end = document.positionAt(expected.length);
        if (!await editor.edit((edit) => {
          edit.replace(new vscode.Range(0, 0, end.line, end.character), saved);
          if (saved.includes("\n")) edit.setEndOfLine(saved.includes("\r\n") ? vscode.EndOfLine.CRLF : vscode.EndOfLine.LF);
        })) throw new Error(`The editor refused to discard ${relative}.`);
        if (disk(file) !== (before?.disk ?? null) || document.getText() !== saved) throw new Error(`Draft changed while preparing deletion: ${relative}`);
        // Replacing with the saved preimage can already mark the working copy
        // clean. VS Code may then report no save, or close that clean model.
        // Verify the actual buffer/disk postconditions rather than the save ack.
        if (document.isDirty) await document.save();
        if (document.getText() !== saved || document.isDirty || disk(file) !== Buffer.from(saved).toString("base64")) throw new Error(`Could not close the reviewed draft cleanly: ${relative}. The backup is retained.`);
        expectedDisk = Buffer.from(saved).toString("base64");
      }
      // Direct deletion avoids depending on a desktop trash service (remote
      // workspaces and mounted filesystems often have none). The user confirmed
      // these new draft files; original files remain in the private backup.
      // Opening/saving the editor yields to other writers. Recheck the disk
      // image even when its clean cached buffer has not observed their edit.
      if (disk(file) !== expectedDisk) throw new Error(`Source changed before deletion: ${relative}. The backup is retained.`);
      if (expectedDisk !== null) await vscode.workspace.fs.delete(vscode.Uri.file(file), { recursive: false, useTrash: false });
      if (document && !document.isClosed) {
        if (document.isDirty) throw new Error(`A new edit appeared in ${relative}; preserve it before retrying cancellation.`);
        // VS Code caches preloaded models after their tabs close. A language
        // change produces didClose for the deleted Tesl URI immediately, so
        // that cached text cannot resurrect the draft in compiler overlays.
        const discarded = await vscode.languages.setTextDocumentLanguage(document, "plaintext");
        discardedDocuments.set(file, discarded);
        const tabs = (vscode.window.tabGroups?.all || []).flatMap((group) => group.tabs).filter((tab) => tab.input?.uri?.fsPath === file);
        if (tabs.length && !await vscode.window.tabGroups.close(tabs, true)) throw new Error(`Close the discarded draft ${relative} before completing cancellation.`);
      }
      if (disk(file) !== null) throw new Error(`Source deletion was not confirmed: ${relative}`);
      continue;
    }
    const wanted = original.source ?? Buffer.from(original.disk, "base64").toString("utf8");
    if (document || original.source !== undefined) {
      if (!document) {
        // A user may have deleted an original file and closed its buffer during
        // the draft. Recreate its saved image before asking VS Code to open it;
        // the separate pre-Start dirty text is restored below, without saving it.
        if (expectedDisk === null) {
          safeParent(snapshot, file, true);
          fs.writeFileSync(file, Buffer.from(original.disk, "base64"), { mode: original.mode ?? 0o600, flag: "wx" });
          expectedDisk = original.disk;
        }
        document = await vscode.workspace.openTextDocument(vscode.Uri.file(file));
      }
      const expected = document.getText(), version = document.version;
      if (expected !== (before?.source ?? Buffer.from(expectedDisk || "", "base64").toString("utf8"))) throw new Error(`Source changed before restoring ${relative}.`);
      const editor = await vscode.window.showTextDocument(document, { preview: false, preserveFocus: true });
      if (document.isClosed || editor.document !== document || document.version !== version || document.getText() !== expected) throw new Error(`Source changed while opening ${relative}.`);
      if (expected !== wanted) {
        const end = document.positionAt(expected.length);
        if (!await editor.edit((edit) => {
          edit.replace(new vscode.Range(0, 0, end.line, end.character), wanted);
          if (wanted.includes("\n")) edit.setEndOfLine(wanted.includes("\r\n") ? vscode.EndOfLine.CRLF : vscode.EndOfLine.LF);
        })) throw new Error(`The editor refused to restore ${relative}.`);
      }
      if (document.getText() !== wanted) throw new Error(`Source changed during restoration: ${relative}`);
    }
    if (disk(file) !== expectedDisk) throw new Error(`Saved source changed during cancellation: ${relative}`);
    // These paths and bytes come only from the private Start backup. No caller
    // or webview can provide replacement source or a deletion path.
    safeParent(snapshot, file, true);
    if (expectedDisk !== original.disk) fs.writeFileSync(file, Buffer.from(original.disk, "base64"), { mode: original.mode ?? 0o600 });
    if (document && !original.dirty && document.isDirty) {
      if (document.getText() !== wanted || !await document.save() || document.getText() !== wanted) throw new Error(`Could not confirm the restored buffer: ${relative}`);
    }
  }
  const restored = scan(vscode, snapshot);
  for (const file of snapshot.files) {
    const actual = restored.records.find((item) => item.path === file.path);
    if (!actual || actual.disk !== file.disk || actual.source !== undefined && actual.source !== (file.source ?? Buffer.from(file.disk, "base64").toString("utf8"))) {
      throw new Error(`Cancellation is incomplete at ${file.path}. The original backup is retained.`);
    }
  }
  if (restored.records.some((file) => (file.disk !== null || file.dirty) && !snapshot.files.some((original) => original.path === file.path))) throw new Error("A new source file or buffer remains. Close it and review cancellation again; the backup is retained.");
  await persist(undefined);
}

// A later migration may create the same filename. Restore language support for
// that actual file (or for new user edits), never for a clean deleted cache.
async function restoreDiscardedDocuments(vscode, root) {
  if (fs.existsSync(path.join(root, ".tesl-source-edit"))) return;
  for (const [file, document] of discardedDocuments) {
    if (document.isClosed) { discardedDocuments.delete(file); continue; }
    if (!inside(root, file) || !document.isDirty && !fs.existsSync(file)) continue;
    if (!document.isDirty && fs.existsSync(file)) {
      const saved = fs.readFileSync(file, "utf8"), expected = document.getText();
      if (saved !== expected) {
        const editor = await vscode.window.showTextDocument(document, { preview: false, preserveFocus: true });
        if (document.isClosed || editor.document !== document || document.isDirty) throw new Error("A recreated migration buffer changed before reload; preserve it and retry.");
        // Let VS Code reload its clean model and disk revision together. An
        // editor.edit would only change text, leaving the old file timestamp;
        // a later save could then fail with a spurious external-write conflict.
        for (let attempt = 0; attempt < 100 && document.getText() !== saved; attempt++) {
          if (document.isClosed || document.isDirty) throw new Error("A recreated migration buffer changed during reload; preserve it and retry.");
          await new Promise((resolve) => setTimeout(resolve, 20));
        }
        if (document.isClosed || document.isDirty || document.getText() !== saved || fs.readFileSync(file, "utf8") !== saved) throw new Error("The recreated migration has not reloaded cleanly. Reopen its file and recheck; new edits are preserved.");
      }
    }
    await vscode.languages.setTextDocumentLanguage(document, "tesl");
    discardedDocuments.delete(file);
  }
}

module.exports = { captureDraft, reviewCancellation, restoreDraft, restoreDiscardedDocuments };
