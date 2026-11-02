"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const { createMigrationClient } = require("./migration-client");

function model() {
  const listeners = { open: [], change: [], close: [] }, documents = [], notifications = [], handlers = new Map();
  const root = path.resolve("/workspace/migration-model");
  const uri = (file) => ({ scheme: "file", fsPath: file, toString: () => `file://${file}` });
  const vscode = {
    Uri: { parse: (text) => uri(text.replace(/^file:\/\//, "")) }, EndOfLine: { LF: 1, CRLF: 2 },
    Range: class { constructor(a,b,c,d) { this.start={line:a,character:b};this.end={line:c,character:d}; } },
    workspace: { isTrusted: true, workspaceFolders: [{ uri: uri(root) }], textDocuments: documents,
      onDidOpenTextDocument: (f) => { listeners.open.push(f); return {dispose(){}}; },
      onDidChangeTextDocument: (f) => { listeners.change.push(f); return {dispose(){}}; },
      onDidCloseTextDocument: (f) => { listeners.close.push(f); return {dispose(){}}; },
    }, window: {},
  };
  const controller = createMigrationClient(vscode, { subscriptions: [] });
  const client = {
    registerFeature: (feature) => { const capabilities={};feature.fillClientCapabilities(capabilities);client.capabilities=capabilities; },
    onRequest: (name, f) => { handlers.set(name, f); return {dispose(){}}; },
    sendNotification: async (method, params) => { notifications.push({method,params});await client.beforeFence?.(); },
  };
  controller.attach(client);
  const fire = (kind, event) => { for(const f of listeners[kind]) f(event); };
  const open = (name, source="before\n", version=1) => {
    const document={uri:uri(path.join(root,name)),languageId:"tesl",version,isClosed:false,isDirty:false,source,
      getText(){return this.source;},positionAt(offset){const lines=this.source.slice(0,offset).split(/\r?\n/);return{line:lines.length-1,character:lines.at(-1).length};}};
    documents.push(document);fire("open",document);return document;
  };
  const change = (document, source) => { document.source=source;document.version++;document.isDirty=true;fire("change",{document,contentChanges:[{text:source}]}); };
  const close = (document) => { document.isClosed=true;documents.splice(documents.indexOf(document),1);fire("close",document); };
  const expected = (document, newText="after\n") => ({uri:document.uri.toString(),version:document.version,source:document.getText(),openId:controller.openId(document),newText,range:{start:{line:0,character:0},end:document.positionAt(document.source.length)}});
  vscode.window.showTextDocument = async (document) => ({document, edit: async (callback) => {
    const version=document.version; let text,eol;
    callback({replace:(_range,value)=>{text=value;},setEndOfLine:value=>{eol=value;}});
    await vscode.beforeCommit?.(document);
    if(document.isClosed || !documents.includes(document) || document.version!==version) return false;
    if(eol) text=text.replace(/\r?\n/g,eol===2?"\r\n":"\n");
    change(document,text);return true;
  }});
  const request = (phase="before") => ({version:1,previewId:"reviewed",projectRoot:root,phase});
  return {root,vscode,controller,client,notifications,handlers,documents,open,change,close,expected,request};
}

test("migration capability advertises a checked snapshot barrier",()=>{
 const f=model();assert.deepEqual(f.client.capabilities.experimental.teslMigrationApply,{version:1,snapshotBarrier:1});
 assert.ok(f.handlers.has("tesl/migrationSnapshot"));assert.ok(f.handlers.has("tesl/migrationApplyEdit"));
});

test("snapshot waits for pending document delivery and sends an ordered fence",async()=>{
 const f=model(),doc=f.open("app.tesl");let release;
 const pending=f.controller.middleware.didChange({document:doc},()=>new Promise(resolve=>{release=resolve;}));
 f.change(doc,"unsaved\n");let done=false;const snapshot=f.controller.snapshot(f.request()).then(result=>{done=true;return result;});
 await new Promise(resolve=>setImmediate(resolve));assert.equal(done,false);assert.equal(f.notifications.length,0);
 release();await pending;const result=await snapshot;
 assert.equal(result.documents[0].source,"unsaved\n");assert.equal(result.eventSeq,f.controller.eventSeq);
 assert.equal(f.notifications.at(-1).method,"tesl/migrationSnapshotFence");assert.equal(f.notifications.at(-1).params.eventSeq,result.eventSeq);
});

test("events during a fence force a new complete snapshot",async()=>{
 const f=model(),doc=f.open("app.tesl");let calls=0;
 f.client.beforeFence=async()=>{if(calls++===0)f.change(doc,"newest\n");};
 const result=await f.controller.snapshot(f.request());
 assert.equal(f.notifications.length,2);assert.equal(result.documents[0].source,"newest\n");assert.equal(result.eventSeq,f.notifications.at(-1).params.eventSeq);
});

test("close/reopen gives a new lifetime even with identical URI/version/source",async()=>{
 const f=model(),first=f.open("app.tesl"),old=f.expected(first);f.close(first);const reopened=f.open("app.tesl");
 assert.notEqual(f.controller.openId(reopened),old.openId);
 const result=await f.controller.apply({version:1,previewId:"reviewed",documents:[old]});
 assert.equal(result.applied,false);assert.equal(reopened.source,"before\n");
});

test("applying an option updates the unsaved buffer and returns a verifiable snapshot",async()=>{
 const f=model(),doc=f.open("app.tesl");const before=await f.controller.snapshot(f.request());
 const result=await f.controller.apply({version:1,previewId:"reviewed",documents:[f.expected(doc,"custom (todo \\\"write converter\\\")\n")]});
 assert.equal(result.applied,true);assert.ok(doc.source.includes("todo"));assert.equal(doc.isDirty,true);
 const after=await f.controller.snapshot(f.request("afterApply"));
 assert.equal(after.documents[0].openId,before.documents[0].openId);assert.ok(after.documents[0].version>before.documents[0].version);assert.equal(after.documents[0].source,doc.source);
});

test("a concurrent user edit is preserved rather than overwritten",async()=>{
 const f=model(),doc=f.open("app.tesl");const expected=f.expected(doc);f.vscode.beforeCommit=async()=>{f.change(doc,"user text\n");};
 const result=await f.controller.apply({version:1,previewId:"reviewed",documents:[expected]});
 assert.equal(result.applied,false);assert.equal(doc.source,"user text\n");assert.equal((await f.controller.snapshot(f.request("afterApply"))).documents[0].source,"user text\n");
});

test("closing/reopening during the editor round trip preserves the new document",async()=>{
 const f=model(),doc=f.open("app.tesl");let reopened;f.vscode.beforeCommit=async()=>{f.close(doc);reopened=f.open("app.tesl","new lifetime user text\n");};
 const result=await f.controller.apply({version:1,previewId:"reviewed",documents:[f.expected(doc)]});
 assert.equal(result.applied,false);assert.equal(reopened.source,"new lifetime user text\n");
});

test("partial batches report failure and preserve exact applied/untouched states for reconciliation",async()=>{
 const f=model(),first=f.open("a.tesl"),second=f.open("b.tesl");f.vscode.beforeCommit=async(document)=>{if(document===second)f.change(second,"user b\n");};
 const result=await f.controller.apply({version:1,previewId:"reviewed",documents:[f.expected(first),f.expected(second)]});
 assert.equal(result.applied,false);assert.equal(result.failedChange,1);assert.equal(first.source,"after\n");assert.equal(second.source,"user b\n");
 const actual=await f.controller.snapshot(f.request("afterApply"));assert.equal(actual.documents.length,2);assert.equal(actual.documents[0].source,"after\n");assert.equal(actual.documents[1].source,"user b\n");
});

test("mixed line endings and stale later documents refuse before any buffer edit",async()=>{
 const f=model(),first=f.open("a.tesl"),second=f.open("b.tesl");
 let result=await f.controller.apply({version:1,previewId:"reviewed",documents:[f.expected(first),f.expected(second,"mixed\r\nnew\n")]});
 assert.equal(result.applied,false);assert.equal(first.source,"before\n");
 const edits=[f.expected(first),f.expected(second)];f.change(second,"concurrent\n");result=await f.controller.apply({version:1,previewId:"reviewed",documents:edits});
 assert.equal(result.applied,false);assert.equal(first.source,"before\n");
});

test("CRLF proposals retain their exact line endings",async()=>{
 const f=model(),doc=f.open("app.tesl");const result=await f.controller.apply({version:1,previewId:"reviewed",documents:[f.expected(doc,"after\r\n")]});
 assert.equal(result.applied,true);assert.equal(doc.source,"after\r\n");
});

test("untrusted workspaces and synchronization failures fail closed",async()=>{
 const f=model(),doc=f.open("app.tesl");f.vscode.workspace.isTrusted=false;
 await assert.rejects(f.controller.snapshot(f.request()),/Trust/);assert.equal((await f.controller.apply({version:1,previewId:"reviewed",documents:[f.expected(doc)]})).applied,false);
 f.vscode.workspace.isTrusted=true;await assert.rejects(f.controller.middleware.didChange({document:doc},async()=>{throw new Error("failed write");}),/failed write/);
 await assert.rejects(f.controller.snapshot(f.request()),/synchronization failed/);
});
