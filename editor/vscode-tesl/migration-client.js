"use strict";

const path = require("path");
const { randomBytes } = require("crypto");

const MAX_MESSAGE = 4 * 1024 * 1024;
const MAX_DOCUMENTS = 256;

function within(root, file) {
  if (!path.isAbsolute(root || "") || !path.isAbsolute(file || "")) return false;
  const relative = path.relative(root, file);
  return relative === "" || !path.isAbsolute(relative) && relative !== ".." && !relative.startsWith(`..${path.sep}`);
}

// The client owns editor lifetimes. URI/version pairs alone cannot detect a
// close+reopen with the same version, and an applyEdit acknowledgement does not
// establish that the language server observed preceding document notifications.
function createMigrationClient(vscode, context) {
  const lifetimes = new WeakMap();
  const pending = new Set();
  const session = randomBytes(16).toString("hex");
  let serial = 0, eventSeq = 0, syncFailure, client;
  const relevant = (document) => document && !document.isClosed && document.uri.scheme === "file" &&
    document.languageId === "tesl" && path.extname(document.uri.fsPath).toLowerCase() === ".tesl";
  const openId = (document) => {
    if (!lifetimes.has(document)) lifetimes.set(document, `${session}:${++serial}`);
    return lifetimes.get(document);
  };
  const changed = () => {
    if (eventSeq >= Number.MAX_SAFE_INTEGER) throw new Error("Migration editor event sequence exhausted; reload the window.");
    eventSeq++;
  };
  for (const document of vscode.workspace.textDocuments || []) if (relevant(document)) openId(document);
  context.subscriptions.push(vscode.workspace.onDidOpenTextDocument((document) => {
    if (relevant(document)) { lifetimes.delete(document); openId(document); changed(); }
  }));
  context.subscriptions.push(vscode.workspace.onDidChangeTextDocument((event) => { if (relevant(event.document)) changed(); }));
  context.subscriptions.push(vscode.workspace.onDidCloseTextDocument((document) => {
    if (lifetimes.has(document) || document.uri.scheme === "file" && document.languageId === "tesl") {
      lifetimes.delete(document); changed();
    }
  }));
  const track = (value, next) => {
    let result;
    try { result = Promise.resolve(next(value)); } catch (error) { result = Promise.reject(error); }
    pending.add(result);
    result.then(() => pending.delete(result), (error) => { pending.delete(result); syncFailure = error; });
    return result;
  };
  const middleware = { didOpen: track, didChange: track, didClose: track };

  function requireRequest(params) {
    if (!vscode.workspace.isTrusted) throw new Error("Trust the workspace before applying migration source.");
    if (!params || params.version !== 1 || typeof params.previewId !== "string" || !params.previewId) throw new Error("Invalid migration editor request.");
  }
  function requireRoot(root) {
    if (!path.isAbsolute(root || "") || path.normalize(root) !== root || !vscode.workspace.workspaceFolders?.some((folder) => within(folder.uri.fsPath, root))) throw new Error("Migration project is outside the open workspace.");
  }
  function capture(root) {
    const documents = (vscode.workspace.textDocuments || []).filter((document) => relevant(document) && within(root, document.uri.fsPath))
      .map((document) => ({ uri: document.uri.toString(), version: document.version, source: document.getText(), openId: openId(document) }))
      .sort((a, b) => a.uri.localeCompare(b.uri));
    if (documents.length > MAX_DOCUMENTS) throw new Error("Too many open migration documents; close unrelated buffers and retry.");
    return documents;
  }
  async function snapshot(params) {
    requireRequest(params); requireRoot(params.projectRoot);
    if (!["before", "afterApply", "afterRestore"].includes(params.phase)) throw new Error("Invalid migration snapshot phase.");
    for (let attempt = 0; attempt < 20; attempt++) {
      const generation = eventSeq;
      if (syncFailure) throw new Error("Document synchronization failed; restart the language server before applying a migration.");
      await Promise.all([...pending]);
      // vscode-languageclient 9 flushes pending full-text updates before sending
      // any notification. Awaiting this fence also orders their writer handoff
      // before the snapshot response, independent of the apply acknowledgement.
      await client.sendNotification("tesl/migrationSnapshotFence", { version: 1, previewId: params.previewId, eventSeq: generation });
      await Promise.all([...pending]);
      if (syncFailure) throw new Error("Document synchronization failed during migration snapshot.");
      if (generation !== eventSeq) continue;
      // No await between the final event check, complete capture and return.
      const result = { version: 1, previewId: params.previewId, eventSeq, documents: capture(params.projectRoot) };
      if (Buffer.byteLength(JSON.stringify(result)) > MAX_MESSAGE) throw new Error("Migration snapshot exceeds the editor message limit.");
      return result;
    }
    throw new Error("Migration documents keep changing; stop editing and request a fresh preview.");
  }

  function checkedDocument(expected) {
    if (!expected || typeof expected.uri !== "string" || !Number.isSafeInteger(expected.version) || typeof expected.source !== "string" || typeof expected.openId !== "string" || typeof expected.newText !== "string") throw new Error("Invalid migration document edit.");
    const uri = vscode.Uri.parse(expected.uri);
    if (uri.scheme !== "file" || !vscode.workspace.workspaceFolders?.some((folder) => within(folder.uri.fsPath, uri.fsPath))) throw new Error("Migration edit is outside the open workspace.");
    const document = vscode.workspace.textDocuments.find((item) => relevant(item) && item.uri.toString() === expected.uri);
    if (!document || document.version !== expected.version || document.getText() !== expected.source || openId(document) !== expected.openId) throw new Error("Migration document changed or reopened; preserve its text and request a fresh preview.");
    const end = document.positionAt(expected.source.length);
    if (expected.range?.start?.line !== 0 || expected.range?.start?.character !== 0 || expected.range?.end?.line !== end.line || expected.range?.end?.character !== end.character) throw new Error("Migration edit does not cover the exact document preimage.");
    const stripped = expected.newText.replace(/\r\n/g, "");
    if (stripped.includes("\r") || expected.newText.includes("\r\n") && stripped.includes("\n")) throw new Error("Migration proposal has mixed line endings; normalize the undeployed draft explicitly and request a fresh preview.");
    return document;
  }
  async function apply(params) {
    let failedChange = 0;
    try {
      requireRequest(params);
      if (!Array.isArray(params.documents) || params.documents.length === 0 || params.documents.length > MAX_DOCUMENTS || Buffer.byteLength(JSON.stringify(params)) > MAX_MESSAGE) throw new Error("Invalid migration edit batch.");
      const seen = new Set();
      const originals = params.documents.map((expected, index) => {
        failedChange = index;
        if (seen.has(expected.uri)) throw new Error("Duplicate migration document edit.");
        seen.add(expected.uri); return checkedDocument(expected);
      });
      for (let index = 0; index < params.documents.length; index++) {
        failedChange = index;
        const expected = params.documents[index], original = originals[index];
        // Bind edits to a specific TextEditor and TextDocument lifetime. The
        // documented TextEditor.edit contract additionally rejects a changed
        // document in the extension-host -> editor round trip.
        const editor = await vscode.window.showTextDocument(original, { preserveFocus: true, preview: false });
        if (checkedDocument(expected) !== original || editor.document !== original) throw new Error("Migration document closed or reopened before its edit.");
        const applied = await editor.edit((builder) => {
          builder.replace(new vscode.Range(expected.range.start.line, expected.range.start.character, expected.range.end.line, expected.range.end.character), expected.newText);
          if (expected.newText.includes("\n")) builder.setEndOfLine(expected.newText.includes("\r\n") ? vscode.EndOfLine.CRLF : vscode.EndOfLine.LF);
        }, { undoStopBefore: true, undoStopAfter: true });
        if (!applied) return { applied: false, failedChange: index, failureReason: "The editor refused the version-guarded migration edit." };
      }
      // Deliberately do not claim document synchronization here. The server
      // must request and verify an afterApply/afterRestore snapshot even on false.
      return { applied: true };
    } catch (error) { return { applied: false, failedChange, failureReason: error.message }; }
  }

  function attach(languageClient) {
    client = languageClient;
    client.registerFeature({
      fillClientCapabilities(capabilities) {
        capabilities.experimental = { ...capabilities.experimental, teslMigrationApply: { version: 1, snapshotBarrier: 1 } };
      },
      initialize() { syncFailure = undefined; }, clear() {}, getState() { return { kind: "static" }; },
    });
    context.subscriptions.push(client.onRequest("tesl/migrationSnapshot", snapshot));
    context.subscriptions.push(client.onRequest("tesl/migrationApplyEdit", apply));
  }
  return { middleware, attach, snapshot, apply, openId, capture, get eventSeq() { return eventSeq; } };
}

module.exports = { createMigrationClient };
