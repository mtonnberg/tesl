"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { captureDraft, reviewCancellation, restoreDraft, restoreDiscardedDocuments } = require("./migration-cancel");

function fixture({ cacheDeleted = false } = {}) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "tesl-cancel-")));
  const schema = path.join(root, "schema/todo/v-current.tesl"), old = path.join(root, "migrations/todo/v13.tesl");
  const created = path.join(root, "migrations/todo/v14.tesl"), frozen = path.join(root, "schema/todo/v13.tesl");
  fs.mkdirSync(path.dirname(schema), { recursive: true }); fs.mkdirSync(path.dirname(old), { recursive: true });
  fs.writeFileSync(schema, "saved schema\r\n", { mode: 0o600 }); fs.writeFileSync(old, "old migration\n");
  fs.writeFileSync(path.join(root, "app.tesl"), "unrelated app edits");
  const documents = [], saves = [];
  const open = (file) => {
    let doc = documents.find((item) => !item.isClosed && item.uri.fsPath === file);
    if (doc) return doc;
    doc = { uri: { scheme: "file", fsPath: file }, languageId: "tesl", text: fs.readFileSync(file, "utf8"), version: 1, isDirty: false,
      getText() { return this.text; }, positionAt(offset) { const lines = this.text.slice(0, offset).split("\n"); return { line: lines.length - 1, character: lines.at(-1).length }; },
      async save() { saves.push(file); fs.writeFileSync(file, this.text); this.isDirty = false; return true; } };
    documents.push(doc); return doc;
  };
  let refuseDelete = false;
  const vscode = {
    Uri: { file: (file) => ({ scheme: "file", fsPath: file }) }, EndOfLine: { CRLF: 2, LF: 1 },
    Range: class {}, WorkspaceEdit: class { constructor() { this.deleted = []; } deleteFile(uri) { this.deleted.push(uri.fsPath); } },
    workspace: { textDocuments: documents, openTextDocument: async (uri) => open(uri.fsPath), fs: { delete: async (uri, options) => {
      assert.equal(options.useTrash, false);
      if (refuseDelete) throw new Error("could not remove file");
      fs.rmSync(uri.fsPath, { force: true }); const doc = documents.find((item) => item.uri.fsPath === uri.fsPath); if (doc && !cacheDeleted) doc.isClosed = true;
    } } },
    languages: { setTextDocumentLanguage: async (document, language) => { document.languageId = language; return document; } },
    window: { showTextDocument: async (document) => {
      if (cacheDeleted && !document.isDirty && fs.existsSync(document.uri.fsPath)) {
        const saved = fs.readFileSync(document.uri.fsPath, "utf8");
        if (saved !== document.text) { document.text = saved; document.version++; }
      }
      return { document, edit: async (fn) => {
      fn({ replace: (_range, text) => { document.text = text; document.version++; document.isDirty = true; }, setEndOfLine() {} }); return true;
    } }; } },
  };
  const doc = open(schema); doc.text = "pre-existing unsaved schema\r\n"; doc.isDirty = true;
  const backup = captureDraft(vscode, { projectRoot: root, revisionAfter: 14, schemaFiles: [schema], files: [{ path: created, creates: true }] });
  fs.writeFileSync(schema, "saved during draft\n"); doc.text = "draft buffer\n"; doc.version++;
  fs.writeFileSync(old, "retargeted migration\n"); fs.writeFileSync(created, "new migration\n"); fs.writeFileSync(frozen, "frozen schema\n");
  const draft = open(created); draft.text = "unsaved migration logic\n"; draft.isDirty = true;
  return { root, schema, old, created, frozen, doc, backup, vscode, saves, refuseDelete: (value) => { refuseDelete = value; },
    cleanup: () => fs.rmSync(root, { recursive: true, force: true }) };
}

test("Cancel restores saved bytes and pre-existing dirty buffers, removes new draft files, and keeps app edits", async () => {
  const f = fixture();
  try {
    let persisted;
    await restoreDraft(f.vscode, f.backup, reviewCancellation(f.vscode, f.backup), async (value) => { persisted = value; });
    assert.equal(fs.readFileSync(f.schema, "utf8"), "saved schema\r\n");
    assert.equal(f.doc.getText(), "pre-existing unsaved schema\r\n");
    assert.equal(f.doc.isDirty, true);
    assert.equal(fs.readFileSync(f.old, "utf8"), "old migration\n");
    assert.equal(fs.existsSync(f.created), false); assert.equal(fs.existsSync(f.frozen), false);
    assert.equal(fs.readFileSync(path.join(f.root, "app.tesl"), "utf8"), "unrelated app edits");
    assert.equal(persisted, undefined);
    assert.ok(!f.saves.includes(f.schema), "pre-existing unsaved work must not be saved by Cancel");
  } finally { f.cleanup(); }
});

test("Cancel refuses edits made after its review", async () => {
  const f = fixture();
  try {
    const plan = reviewCancellation(f.vscode, f.backup);
    f.doc.text = "new concurrent edit"; f.doc.version++;
    await assert.rejects(restoreDraft(f.vscode, f.backup, plan, async () => assert.fail("must not start restoration")), /changed after/);
    assert.equal(f.doc.text, "new concurrent edit");
    assert.equal(fs.readFileSync(f.old, "utf8"), "retargeted migration\n");
  } finally { f.cleanup(); }
});

test("Cancel refuses a closed/reopened buffer even when text and version match", async () => {
  const f = fixture();
  try {
    const plan = reviewCancellation(f.vscode, f.backup);
    f.doc.isClosed = true;
    f.vscode.workspace.textDocuments.push({ ...f.doc, isClosed: false });
    await assert.rejects(restoreDraft(f.vscode, f.backup, plan, async () => assert.fail("must not restore a new document lifetime")), /reopened/);
    assert.equal(fs.readFileSync(f.old, "utf8"), "retargeted migration\n");
  } finally { f.cleanup(); }
});

test("Cancel preserves a disk edit made while opening a clean draft for deletion", async () => {
  const f = fixture();
  try {
    const draft = f.vscode.workspace.textDocuments.find((doc) => doc.uri.fsPath === f.created);
    await draft.save();
    const plan = reviewCancellation(f.vscode, f.backup);
    const show = f.vscode.window.showTextDocument;
    f.vscode.window.showTextDocument = async (document) => {
      const editor = await show(document);
      if (document === draft) fs.writeFileSync(f.created, "new external edit\n");
      return editor;
    };
    let persisted;
    await assert.rejects(restoreDraft(f.vscode, f.backup, plan, async (value) => { persisted = value; }), /changed.*deletion/i);
    assert.equal(fs.readFileSync(f.created, "utf8"), "new external edit\n");
    assert.equal(persisted.restoring, true);
  } finally { f.cleanup(); }
});

test("Cancel restores a deleted original file and its closed pre-existing dirty buffer", async () => {
  const f = fixture();
  try {
    f.doc.isClosed = true;
    fs.unlinkSync(f.schema);
    let persisted;
    await restoreDraft(f.vscode, f.backup, reviewCancellation(f.vscode, f.backup), async (value) => { persisted = value; });
    const restored = f.vscode.workspace.textDocuments.find((doc) => !doc.isClosed && doc.uri.fsPath === f.schema);
    assert.equal(fs.readFileSync(f.schema, "utf8"), "saved schema\r\n");
    assert.equal(restored.getText(), "pre-existing unsaved schema\r\n");
    assert.equal(restored.isDirty, true);
    assert.equal(persisted, undefined);
  } finally { f.cleanup(); }
});

test("Cancel refuses linked sources and an active source transaction", () => {
  const f = fixture();
  try {
    const link = path.join(f.root, "schema/todo/linked.tesl");
    fs.symlinkSync(path.join(f.root, "app.tesl"), link);
    assert.throws(() => reviewCancellation(f.vscode, f.backup), /source link/);
    fs.unlinkSync(link);
    fs.mkdirSync(path.join(f.root, ".tesl-source-edit"));
    assert.throws(() => reviewCancellation(f.vscode, f.backup), /source update is active/);
  } finally { f.cleanup(); }
});

test("partial cancellation retains its backup and can finish after a fresh review", async () => {
  const f = fixture();
  try {
    let persisted;
    const save = async (value) => { persisted = value; };
    f.refuseDelete(true);
    await assert.rejects(restoreDraft(f.vscode, f.backup, reviewCancellation(f.vscode, f.backup), save), /could not remove/);
    assert.equal(persisted.restoring, true);
    f.refuseDelete(false);
    await restoreDraft(f.vscode, f.backup, reviewCancellation(f.vscode, f.backup), save);
    assert.equal(persisted, undefined);
    assert.equal(fs.existsSync(f.created), false);
  } finally { f.cleanup(); }
});

test("Cancel never removes a later revision", () => {
  const f = fixture();
  try {
    fs.writeFileSync(path.join(f.root, "migrations/todo/v15.tesl"), "later revision");
    assert.throws(() => reviewCancellation(f.vscode, f.backup), /later revision/);
    assert.equal(fs.existsSync(f.created), true);
  } finally { f.cleanup(); }
});

test("Cancel withdraws cached deleted Tesl buffers and restores language support only when reused", async () => {
  const f = fixture({ cacheDeleted: true });
  try {
    const draft = f.vscode.workspace.textDocuments.find((doc) => doc.uri.fsPath === f.created);
    await restoreDraft(f.vscode, f.backup, reviewCancellation(f.vscode, f.backup), async () => {});
    assert.equal(draft.isClosed, undefined, "closed tabs may retain their text model");
    assert.equal(draft.languageId, "plaintext", "deleted source must leave compiler overlays");
    await restoreDiscardedDocuments(f.vscode, f.root);
    assert.equal(draft.languageId, "plaintext");
    assert.doesNotThrow(() => captureDraft(f.vscode, { projectRoot: f.root, revisionAfter: 14, schemaFiles: [f.schema], files: [{ path: f.created }] }));
    fs.writeFileSync(f.created, "replacement migration\n");
    await restoreDiscardedDocuments(f.vscode, f.root);
    assert.equal(draft.languageId, "tesl");
    assert.equal(draft.getText(), "replacement migration\n");
  } finally { f.cleanup(); }
});

test("Reusing a discarded buffer preserves new user edits and waits for active source updates", async () => {
  const f = fixture({ cacheDeleted: true });
  try {
    const draft = f.vscode.workspace.textDocuments.find((doc) => doc.uri.fsPath === f.created);
    await restoreDraft(f.vscode, f.backup, reviewCancellation(f.vscode, f.backup), async () => {});
    draft.text = "new user work"; draft.version++; draft.isDirty = true;
    fs.writeFileSync(f.created, "new saved source");
    const journal = path.join(f.root, ".tesl-source-edit");
    fs.mkdirSync(journal);
    await restoreDiscardedDocuments(f.vscode, f.root);
    assert.equal(draft.languageId, "plaintext");
    fs.rmdirSync(journal);
    await restoreDiscardedDocuments(f.vscode, f.root);
    assert.equal(draft.languageId, "tesl");
    assert.equal(draft.getText(), "new user work");
    assert.equal(fs.readFileSync(f.created, "utf8"), "new saved source");
  } finally { f.cleanup(); }
});

test("A clean editor reload of a recreated file is accepted without replacing new user edits", async () => {
  for (const userEdit of [false, true]) {
    const f = fixture({ cacheDeleted: true });
    try {
      const draft = f.vscode.workspace.textDocuments.find((doc) => doc.uri.fsPath === f.created);
      await restoreDraft(f.vscode, f.backup, reviewCancellation(f.vscode, f.backup), async () => {});
      fs.writeFileSync(f.created, "recreated source\n");
      f.vscode.window.showTextDocument = async (document) => {
        setTimeout(() => {
          document.text = userEdit ? "concurrent user edit" : fs.readFileSync(document.uri.fsPath, "utf8");
          document.version++; document.isDirty = userEdit;
        }, 5);
        return { document, edit: async () => assert.fail("must not replace a reloaded or edited model") };
      };
      if (userEdit) {
        await assert.rejects(restoreDiscardedDocuments(f.vscode, f.root), /changed during reload/);
        assert.equal(draft.getText(), "concurrent user edit");
      } else {
        await restoreDiscardedDocuments(f.vscode, f.root);
        assert.equal(draft.getText(), "recreated source\n");
        assert.equal(draft.languageId, "tesl");
      }
    } finally { f.cleanup(); }
  }
});

test("Cancel verifies saved postconditions when the editor reports no save", async () => {
  for (const clean of [false, true]) {
    const f = fixture();
    try {
      const draft = f.vscode.workspace.textDocuments.find((doc) => doc.uri.fsPath === f.created);
      draft.save = async () => { if (clean) draft.isDirty = false; return false; };
      let persisted;
      const restore = () => restoreDraft(f.vscode, f.backup, reviewCancellation(f.vscode, f.backup), async (value) => { persisted = value; });
      if (clean) {
        await restore();
        assert.equal(persisted, undefined);
        assert.equal(fs.existsSync(f.created), false);
      } else {
        await assert.rejects(restore(), /Could not close the reviewed draft cleanly/);
        assert.equal(persisted.restoring, true);
        assert.equal(fs.existsSync(f.created), true);
      }
    } finally { f.cleanup(); }
  }
});
