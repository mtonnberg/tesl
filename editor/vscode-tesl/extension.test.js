"use strict";

const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const Module = require("module");
const { spawn } = require("child_process");
const { test } = require("node:test");

const repoRoot = path.resolve(__dirname, "../..");

class Disposable {
  dispose() {}
}

class Uri {
  constructor(fsPath) { this.fsPath = fsPath; }
  toString() { return this.fsPath; }
  static file(file) { return new Uri(path.resolve(file)); }
  static parse(value) { return new Uri(value); }
}

class Range {
  constructor(startLine, startCharacter, endLine, endCharacter) {
    this.start = { line: startLine, character: startCharacter };
    this.end = { line: endLine, character: endCharacter };
  }
}

class CodeLens {
  constructor(range, command) { this.range = range; this.command = command; }
}

class TestItem {
  constructor(id, label, uri) {
    this.id = id;
    this.label = label;
    this.uri = uri;
    this.children = new TestChildren();
  }
}

class TestChildren {
  constructor() { this.values = new Map(); }
  get size() { return this.values.size; }
  forEach(callback) { this.values.forEach(callback); }
  replace(items) { this.values = new Map(items.map((item) => [item.id, item])); }
}

class TestItems {
  constructor() { this.values = new Map(); }
  add(item) { this.values.set(item.id, item); }
  get(id) { return this.values.get(id); }
  delete(id) { return this.values.delete(id); }
  forEach(callback) { this.values.forEach(callback); }
}

class TestRun {
  constructor() { this.events = []; this.output = ""; this.ended = false; }
  enqueued(item) { this.events.push({ kind: "enqueued", item }); }
  started(item) { this.events.push({ kind: "started", item }); }
  passed(item, duration) { this.events.push({ kind: "passed", item, duration }); }
  failed(item, message, duration) { this.events.push({ kind: "failed", item, message, duration }); }
  errored(item, message, duration) { this.events.push({ kind: "errored", item, message, duration }); }
  skipped(item) { this.events.push({ kind: "skipped", item }); }
  appendOutput(value) { this.output += value; }
  end() { this.ended = true; }
}

class TestController {
  constructor(id, label) {
    this.id = id;
    this.label = label;
    this.items = new TestItems();
    this.profiles = [];
    this.runs = [];
  }
  createTestItem(id, label, uri) { return new TestItem(id, label, uri); }
  createTestRun() {
    const run = new TestRun();
    this.runs.push(run);
    return run;
  }
  createRunProfile(name, kind, handler, isDefault) {
    this.profiles.push({ name, kind, handler, isDefault });
  }
  dispose() {}
}

function makeVscode(files, debugCalls, terminalCalls, workspacePath = repoRoot) {
  const workspaceFolder = { uri: Uri.file(workspacePath) };
  const commands = new Map();
  const codeLensProviders = [];
  const controllers = [];
  const debugFactories = [];
  const vscode = {
    Uri,
    Range,
    CodeLens,
    DebugAdapterExecutable: class {
      constructor(command, args, options) { this.command = command; this.args = args; this.options = options; }
    },
    TestTag: class { constructor(value) { this.id = value; } },
    TestMessage: class { constructor(message) { this.message = message; } },
    Location: class { constructor(uri, range) { this.uri = uri; this.range = range; } },
    CancellationTokenSource: class {
      constructor() {
        this.token = {
          isCancellationRequested: false,
          onCancellationRequested: () => new Disposable(),
        };
      }
      dispose() {}
    },
    TestRunRequest: class {
      constructor(include, exclude) { this.include = include; this.exclude = exclude || []; }
    },
    TestRunProfileKind: { Run: 1, Debug: 2 },
    workspace: {
      workspaceFolders: [workspaceFolder],
      textDocuments: [],
      getConfiguration: () => ({ get: () => "" }),
      getWorkspaceFolder: () => workspaceFolder,
      findFiles: async () => files,
      createFileSystemWatcher: () => ({
        onDidCreate: () => new Disposable(),
        onDidChange: () => new Disposable(),
        onDidDelete: () => new Disposable(),
      }),
      onDidOpenTextDocument: () => new Disposable(),
      onDidChangeTextDocument: () => new Disposable(),
    },
    languages: {
      registerCodeLensProvider: (_selector, provider) => {
        codeLensProviders.push(provider);
        return new Disposable();
      },
    },
    commands: {
      registerCommand: (name, handler) => {
        commands.set(name, handler);
        return new Disposable();
      },
    },
    tests: {
      createTestController: (id, label) => {
        const controller = new TestController(id, label);
        controllers.push(controller);
        return controller;
      },
    },
    window: {
      activeTextEditor: null,
      createOutputChannel: () => ({ appendLine() {}, show() {}, dispose() {} }),
      createTerminal: (options) => ({
        show() {},
        sendText(text) { if (terminalCalls) terminalCalls.push({ options, text }); },
      }),
      showWarningMessage() {},
      showErrorMessage() {},
      showInputBox: async () => undefined,
    },
    debug: {
      startDebugging: async (_folder, config) => { debugCalls.push(config); return true; },
      registerDebugAdapterDescriptorFactory: (_type, factory) => {
        debugFactories.push(factory);
        return new Disposable();
      },
      registerDebugConfigurationProvider: () => new Disposable(),
    },
  };
  return { vscode, commands, codeLensProviders, controllers, debugFactories };
}

function loadExtension(vscode) {
  const originalLoad = Module._load;
  Module._load = function (request, parent, isMain) {
    if (request === "vscode") return vscode;
    if (request === "vscode-languageclient/node") {
      return {
        LanguageClient: class {
          constructor() {}
          start() { return Promise.resolve(); }
          stop() { return Promise.resolve(); }
        },
        TransportKind: { stdio: 0 },
      };
    }
    return originalLoad.call(this, request, parent, isMain);
  };
  try {
    delete require.cache[require.resolve("./extension")];
    return require("./extension");
  } finally {
    Module._load = originalLoad;
  }
}

async function activateWithFile(file, cleanup, workspacePath = repoRoot) {
  const uri = Uri.file(file);
  const debugCalls = [];
  const terminalCalls = [];
  const host = makeVscode([uri], debugCalls, terminalCalls, workspacePath);
  const extension = loadExtension(host.vscode);
  const context = { extensionPath: __dirname, subscriptions: { push() {} } };
  extension.activate(context);
  await new Promise((resolve) => setImmediate(resolve));
  return {
    ...host,
    file,
    uri,
    debugCalls,
    terminalCalls,
    cleanup: cleanup || (() => {}),
  };
}

async function activatedFixture(source) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "tesl-extension-test-"));
  const file = path.join(directory, "fixture.tesl");
  fs.writeFileSync(file, source, "utf8");
  return activateWithFile(file, () => fs.rmSync(directory, { recursive: true, force: true }));
}

async function activatedExistingFixture(relativeFile, workspacePath = repoRoot) {
  return activateWithFile(path.join(repoRoot, relativeFile), undefined, workspacePath);
}

async function testCodeLensCommands() {
  const fixture = await activatedFixture(`module Fixture exposing []

test "add" {
  expect 1 == 1
}
`);
  try {
    const document = {
      fileName: fixture.file,
      uri: fixture.uri,
      getText: () => fs.readFileSync(fixture.file, "utf8"),
    };
    const lenses = fixture.codeLensProviders[0].provideCodeLenses(document);
    const titles = lenses.map((lens) => lens.command.title);
    assert.ok(titles.includes("▶ Run all tests in file"));
    assert.ok(titles.includes("🐛 Debug all tests"));
    assert.ok(titles.includes("▶ Run test"));
    assert.ok(titles.includes("🐛 Debug test"));
  } finally {
    fixture.cleanup();
  }
}

async function testCodeLensRunReportsTestResult() {
  const fixture = await activatedFixture(`module Fixture exposing []

test "add" {
  expect 1 == 2
}
`);
  try {
    await fixture.commands.get("tesl.runSingleTest")(fixture.file, "add", "test");
    const run = fixture.controllers[0].runs[0];
    const failure = run.events.find((event) => event.kind === "failed");
    assert.ok(failure, `events: ${run.events.map((event) => event.kind).join(", ")} output: ${run.output}`);
    assert.match(failure.message.message, /Tesl expectation failed/);
    assert.strictEqual(failure.message.location.uri.fsPath, fixture.file);
    assert.match(run.output, /fixture\.tesl :: add/);
    assert.strictEqual(run.ended, true);
  } finally {
    fixture.cleanup();
  }
}

async function testFileLevelRunAndDebug() {
  const fixture = await activatedFixture(`module Fixture exposing []

test "one" {
  expect 1 == 1
}

test "two" {
  expect 2 == 2
}
`);
  try {
    await fixture.commands.get("tesl.runTests")(fixture.uri);
    assert.ok(fixture.controllers[0].runs[0].events.some((event) => event.kind === "passed"));

    await fixture.commands.get("tesl.debugTests")(fixture.uri);
    assert.strictEqual(fixture.debugCalls.length, 1);
    assert.strictEqual(fixture.debugCalls[0].mode, "test");
    assert.strictEqual(fixture.debugCalls[0].program, fixture.file);
    assert.strictEqual(fixture.debugCalls[0].testName, undefined);

    const debugProfile = fixture.controllers[0].profiles.find((profile) => profile.name === "Debug");
    const fileItem = fixture.controllers[0].items.get(fixture.uri.toString());
    await debugProfile.handler(new fixture.vscode.TestRunRequest([fileItem]), {
      isCancellationRequested: false,
    });
    assert.strictEqual(fixture.debugCalls.length, 2);
  } finally {
    fixture.cleanup();
  }
}

async function testSingleDebugConfiguration() {
  const fixture = await activatedFixture(`module Fixture exposing []

test "add" {
  expect 1 == 1
}
`);
  try {
    await fixture.commands.get("tesl.debugSingleTest")(fixture.file, "add", "test");
    assert.strictEqual(fixture.debugCalls[0].testName, "add");
    assert.strictEqual(fixture.debugCalls[0].testKind, "test");
  } finally {
    fixture.cleanup();
  }
}

async function testApiTestWithQueueAndSseRunsInExplorer() {
  const fixture = await activatedExistingFixture("example/learn/lesson33-sse-and-queue-tests.tesl");
  try {
    await fixture.commands.get("tesl.runSingleTest")(
      fixture.file,
      "subscribe collect and process queue",
      "api-test"
    );
    const run = fixture.controllers[0].runs[0];
    assert.ok(run.events.some((event) => event.kind === "passed"), run.output);
    assert.strictEqual(run.ended, true);
    await fixture.commands.get("tesl.debugSingleTest")(
      fixture.file,
      "subscribe collect and process queue",
      "api-test"
    );
    assert.strictEqual(fixture.debugCalls[0].mode, "test");
    assert.strictEqual(fixture.debugCalls[0].testKind, "api-test");
  } finally {
    fixture.cleanup();
  }
}

async function testApiTestWithCacheRunsInExplorer() {
  const fixture = await activatedExistingFixture("tests/cache-tests.tesl");
  try {
    await fixture.commands.get("tesl.runSingleTest")(
      fixture.file,
      "Cache.set and get roundtrip",
      "test"
    );
    const run = fixture.controllers[0].runs[0];
    assert.ok(run.events.some((event) => event.kind === "passed"), run.output);
    assert.strictEqual(run.ended, true);
  } finally {
    fixture.cleanup();
  }
}

async function testLoadTestRunsInExplorer() {
  const fixture = await activatedExistingFixture("example/learn/lesson41-load-tests.tesl");
  try {
    await fixture.commands.get("tesl.runSingleTest")(
      fixture.file,
      "greet throughput",
      "load-test"
    );
    const run = fixture.controllers[0].runs[0];
    assert.ok(run.events.some((event) => event.kind === "passed"), run.output);
    assert.strictEqual(run.ended, true);
  } finally {
    fixture.cleanup();
  }
}

async function testFullApplicationRunAndDebugUsesProgramMode() {
  const applications = [
    ["example/learn/lesson31-worker-concurrency.tesl", /queue EmailQueue/],
    ["example/user-service-api.tesl", /cache UserProfileCache/],
  ];
  for (const [relativeFile, feature] of applications) {
    const fixture = await activatedExistingFixture(relativeFile);
    try {
      assert.match(fs.readFileSync(fixture.file, "utf8"), feature);
      fixture.vscode.window.activeTextEditor = { document: { fileName: fixture.file } };
      fixture.commands.get("tesl.runDebugMode")();
      assert.strictEqual(fixture.terminalCalls.length, 1);
      assert.match(fixture.terminalCalls[0].text, /run --debug/);
      assert.match(fixture.terminalCalls[0].text, new RegExp(path.basename(fixture.file).replace(".", "\\.")));

      await fixture.commands.get("tesl.debugProgram")(fixture.uri);
      assert.strictEqual(fixture.debugCalls.length, 1);
      assert.strictEqual(fixture.debugCalls[0].mode, "program");
      assert.strictEqual(fixture.debugCalls[0].program, fixture.file);
    } finally {
      fixture.cleanup();
    }
  }
}

function dapRequest(child, state, command, args) {
  const seq = state.nextSeq++;
  const body = JSON.stringify({ seq, type: "request", command, arguments: args || {} });
  const result = new Promise((resolve, reject) => state.pending.set(seq, { resolve, reject }));
  child.stdin.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
  return result;
}

function dapEvent(state, eventName) {
  return new Promise((resolve, reject) => {
    state.events.set(eventName, { resolve, reject });
  });
}

async function withDapSession({ source, file: existingFile, breakpointLine, launch, cwd = repoRoot }, inspect) {
  const directory = source ? fs.mkdtempSync(path.join(os.tmpdir(), "tesl-dap-extension-test-")) : null;
  const file = existingFile || path.join(directory, "fixture.tesl");
  if (source) fs.writeFileSync(file, source, "utf8");
  const child = spawn("go", ["run", "./cmd/tesl-dap"], {
    cwd: path.join(repoRoot, "runtime", "go"),
    detached: process.platform !== "win32",
    env: {
      ...process.env,
      TESL_REPO_ROOT: repoRoot,
      TESL_COMPILER: path.join(repoRoot, "compiler", "_build", "default", "bin", "main.exe"),
      TMPDIR: "/tmp",
      GOTMPDIR: "/tmp",
      TMP: "/tmp",
      TEMP: "/tmp",
    },
  });
  const state = { nextSeq: 1, pending: new Map(), events: new Map(), buffer: Buffer.alloc(0) };
  const fail = (error) => {
    for (const pending of state.pending.values()) pending.reject(error);
    for (const event of state.events.values()) event.reject(error);
  };
  child.on("error", fail);
  child.stdout.on("data", (data) => {
    state.buffer = Buffer.concat([state.buffer, data]);
    while (true) {
      const separator = state.buffer.indexOf("\r\n\r\n");
      if (separator < 0) break;
      const header = state.buffer.subarray(0, separator).toString();
      const match = /Content-Length: (\d+)/i.exec(header);
      if (!match) { fail(new Error(`invalid DAP header: ${header}`)); return; }
      const length = Number(match[1]);
      const bodyStart = separator + 4;
      if (state.buffer.length < bodyStart + length) break;
      const message = JSON.parse(state.buffer.subarray(bodyStart, bodyStart + length));
      state.buffer = state.buffer.subarray(bodyStart + length);
      if (message.type === "response") {
        const pending = state.pending.get(message.request_seq);
        if (pending) {
          state.pending.delete(message.request_seq);
          if (message.success === false) pending.reject(new Error(message.message || message.command));
          else pending.resolve(message);
        }
      } else if (message.type === "event") {
        const event = state.events.get(message.event);
        if (event) {
          state.events.delete(message.event);
          event.resolve(message);
        }
      }
    }
  });
  child.stderr.on("data", () => {});
  try {
    await dapRequest(child, state, "initialize", {
      adapterID: "tesl",
      linesStartAt1: true,
      columnsStartAt1: true,
    });
    await dapRequest(child, state, "launch", {
      ...launch,
      program: file,
      cwd,
    });
    await dapRequest(child, state, "setBreakpoints", {
      source: { path: file },
      breakpoints: [{ line: breakpointLine }],
    });
    const stopped = dapEvent(state, "stopped");
    await dapRequest(child, state, "configurationDone");
    await stopped;
    await inspect((command, args) => dapRequest(child, state, command, args));
    await dapRequest(child, state, "disconnect");
  } finally {
    if (process.platform === "win32") child.kill();
    else {
      try { process.kill(-child.pid, "SIGKILL"); } catch (_e) { child.kill(); }
    }
    if (directory) fs.rmSync(directory, { recursive: true, force: true });
  }
}

async function testDapScalarLocalHasZeroVariablesReference() {
  const source = `module Fixture exposing []

test "locals" {
  let answer = 42
  expect answer == 42
}
`;
  await withDapSession({ source, breakpointLine: 5, launch: {
    mode: "test", testName: "locals", testKind: "test",
  } }, async (request) => {
    const stack = await request("stackTrace", { threadId: 1 });
    const frame = stack.body.stackFrames[0];
    const scopes = await request("scopes", { frameId: frame.id });
    const locals = scopes.body.scopes.find((scope) => scope.name === "Locals");
    assert.ok(locals && locals.variablesReference > 0);
    const variables = await request("variables", { variablesReference: locals.variablesReference });
    const answer = variables.body.variables.find((variable) => variable.name === "answer");
    assert.ok(answer, JSON.stringify(variables.body));
    assert.strictEqual(Object.prototype.hasOwnProperty.call(answer, "variablesReference"), true);
    assert.strictEqual(answer.variablesReference, 0);
  });
}

async function testDapApiResponseExposesJsonFields() {
  const file = path.join(repoRoot, "example", "learn", "lesson32-api-tests.tesl");
  const line = fs.readFileSync(file, "utf8").split("\n")
    .findIndex((text) => text.includes('expect echoResp.body.message ==')) + 1;
  await withDapSession({ file, breakpointLine: line, launch: {
    mode: "test",
    testName: "raw JSON body and dynamic response fields",
    testKind: "api-test",
  } }, async (request) => {
    const stack = await request("stackTrace", { threadId: 1 });
    const frame = stack.body.stackFrames[0];
    const scopes = await request("scopes", { frameId: frame.id });
    const locals = scopes.body.scopes.find((scope) => scope.name === "Locals");
    const localVariables = await request("variables", { variablesReference: locals.variablesReference });
    const response = localVariables.body.variables.find((variable) => variable.name === "echoResp");
    assert.ok(response && response.variablesReference > 0, JSON.stringify(localVariables.body));
    const responseVariables = await request("variables", { variablesReference: response.variablesReference });
    assert.deepStrictEqual(responseVariables.body.variables.map((variable) => variable.name), ["status", "body", "headers"]);
    const body = responseVariables.body.variables.find((variable) => variable.name === "body");
    assert.ok(body && body.variablesReference > 0, JSON.stringify(responseVariables.body));
    const bodyVariables = await request("variables", { variablesReference: body.variablesReference });
    const message = bodyVariables.body.variables.find((variable) => variable.name === "message");
    assert.ok(message, JSON.stringify(bodyVariables.body));
    assert.strictEqual(message.value, "hello from api-test");
    assert.strictEqual(message.type, "String");
    assert.strictEqual(message.evaluateName, "echoResp.body.message");
    const evaluated = await request("evaluate", { expression: "echoResp.body.message", frameId: frame.id });
    assert.strictEqual(evaluated.body.result, "hello from api-test");
  });
}

async function testDapProgramBreakpointHitsLessonMain() {
  const file = path.join(repoRoot, "example", "learn", "lesson31-worker-concurrency.tesl");
  const line = fs.readFileSync(file, "utf8").split("\n")
    .findIndex((text) => text.includes("let port = 8090")) + 1;
  await withDapSession({ file, breakpointLine: line, launch: { mode: "program" } }, async (request) => {
    const stack = await request("stackTrace", { threadId: 1 });
    const frame = stack.body.stackFrames[0];
    assert.strictEqual(frame.source.path, file);
    assert.strictEqual(frame.line, line);
  });
}

async function testDapApiBreakpointHitsFromNestedWorkspaceCwd() {
  const file = path.join(repoRoot, "example", "learn", "lesson32-api-tests.tesl");
  const line = fs.readFileSync(file, "utf8").split("\n")
    .findIndex((text) => text.includes('expect echoResp.body.message ==')) + 1;
  await withDapSession({ file, breakpointLine: line, cwd: path.join(repoRoot, "example", "learn"), launch: {
    mode: "test",
    testName: "raw JSON body and dynamic response fields",
    testKind: "api-test",
  } }, async () => {});
}

async function testNestedWorkspaceUsesCheckoutTools() {
  const file = path.join(repoRoot, "example", "learn", "lesson32-api-tests.tesl");
  const workspacePath = path.join(repoRoot, "example", "learn");
  const fixture = await activatedExistingFixture("example/learn/lesson32-api-tests.tesl", workspacePath);
  try {
    const descriptor = fixture.debugFactories[0].createDebugAdapterDescriptor({
      workspaceFolder: { uri: Uri.file(workspacePath) },
      configuration: { program: file },
    });
    assert.match(descriptor.command, /^\/nix\/store\/.*\/bin\/go$/);
    assert.deepStrictEqual(descriptor.args, ["run", "./cmd/tesl-dap"]);
    assert.strictEqual(descriptor.options.cwd, path.join(repoRoot, "runtime", "go"));
    assert.strictEqual(descriptor.options.env.TESL_REPO_ROOT, repoRoot);
    assert.strictEqual(descriptor.options.env.TESL_POSTGRES_HOST, "127.0.0.1");
    assert.strictEqual(descriptor.options.env.TESL_POSTGRES_PORT, "55432");
    assert.strictEqual(descriptor.options.env.TESL_POSTGRES_USER, "tesl");
    assert.strictEqual(
      descriptor.options.env.TESL_COMPILER,
      path.join(repoRoot, "compiler", "_build", "default", "bin", "main.exe")
    );
  } finally {
    fixture.cleanup();
  }
}

test("CodeLens exposes file and test actions", testCodeLensCommands);
test("CodeLens run reports failure in Test Results", testCodeLensRunReportsTestResult);
test("file-level run and debug use file actions", testFileLevelRunAndDebug);
test("single-test debug preserves test selection", testSingleDebugConfiguration);
test("queue and SSE api-test runs in Test Explorer", testApiTestWithQueueAndSseRunsInExplorer);
test("cache test runs in Test Explorer", testApiTestWithCacheRunsInExplorer);
test("load-test runs in Test Explorer", testLoadTestRunsInExplorer);
test("full queue and cache applications run and debug in program mode", testFullApplicationRunAndDebugUsesProgramMode);
test("DAP scalar locals include zero variablesReference", testDapScalarLocalHasZeroVariablesReference);
test("DAP API response locals expose JSON fields", testDapApiResponseExposesJsonFields);
test("DAP program breakpoint hits full application main", testDapProgramBreakpointHitsLessonMain);
test("DAP API breakpoint hits from nested workspace cwd", testDapApiBreakpointHitsFromNestedWorkspaceCwd);
test("nested workspaces use checkout debugger and compiler", testNestedWorkspaceUsesCheckoutTools);
