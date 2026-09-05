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

class ProcessExecution {
  constructor(process, args, options) {
    this.process = process;
    this.args = args;
    this.options = options;
  }
}

class Task {
  constructor(definition, scope, name, source, execution, problemMatchers) {
    this.definition = definition;
    this.scope = scope;
    this.name = name;
    this.source = source;
    this.execution = execution;
    this.problemMatchers = problemMatchers;
  }
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

function makeVscode(files, debugCalls, taskCalls, workspacePath = repoRoot, options = {}) {
  const workspaceFolder = { uri: Uri.file(workspacePath) };
  const commands = new Map();
  const codeLensProviders = [];
  const controllers = [];
  const debugFactories = [];
  const debugProviders = [];
  const taskEndListeners = new Set();
  const warningMessages = [];
  const errorMessages = [];
  const inputValues = [...(options.inputValues || [])];
  const vscode = {
    Uri,
    Range,
    CodeLens,
    ProcessExecution,
    Task,
    TaskScope: { Workspace: 1 },
    TaskRevealKind: { Always: 1 },
    TaskPanelKind: { New: 3 },
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
      isTrusted: options.isTrusted !== false,
      workspaceFolders: [workspaceFolder],
      textDocuments: [],
      getConfiguration: () => ({ get: (key) => options.configuration?.[key] || "" }),
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
    tests: options.enableTests === false ? undefined : {
      createTestController: (id, label) => {
        const controller = new TestController(id, label);
        controllers.push(controller);
        return controller;
      },
    },
    window: {
      activeTextEditor: null,
      createOutputChannel: () => ({ appendLine() {}, show() {}, dispose() {} }),
      showWarningMessage(message) { warningMessages.push(message); },
      showErrorMessage(message) { errorMessages.push(message); },
      showInputBox: async () => inputValues.shift(),
    },
    tasks: {
      executeTask: async (task) => {
        const execution = { task };
        taskCalls.push({ task, execution });
        return execution;
      },
      onDidEndTask: (listener) => {
        taskEndListeners.add(listener);
        return { dispose: () => taskEndListeners.delete(listener) };
      },
    },
    debug: {
      startDebugging: async (_folder, config) => { debugCalls.push(config); return true; },
      registerDebugAdapterDescriptorFactory: (_type, factory) => {
        debugFactories.push(factory);
        return new Disposable();
      },
      registerDebugConfigurationProvider: (_type, provider) => {
        debugProviders.push(provider);
        return new Disposable();
      },
    },
  };
  return {
    vscode,
    commands,
    codeLensProviders,
    controllers,
    debugFactories,
    debugProviders,
    warningMessages,
    errorMessages,
    endTask(task, exitCode = 0) {
      for (const listener of [...taskEndListeners]) {
        listener({ execution: { task }, exitCode });
      }
    },
  };
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

async function activateWithFile(file, cleanup, workspacePath = repoRoot, options = {}) {
  const uri = Uri.file(file);
  const debugCalls = [];
  const taskCalls = [];
  const host = makeVscode([uri], debugCalls, taskCalls, workspacePath, options);
  const extension = loadExtension(host.vscode);
  const context = { extensionPath: __dirname, subscriptions: { push() {} } };
  extension.activate(context);
  await new Promise((resolve) => setImmediate(resolve));
  return {
    ...host,
    file,
    uri,
    debugCalls,
    taskCalls,
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
      await fixture.commands.get("tesl.runDebugMode")();
      assert.strictEqual(fixture.taskCalls.length, 1);
      assert.deepStrictEqual(
        fixture.taskCalls[0].task.execution.args.slice(-3),
        ["run", "--debug", fixture.file]
      );

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
  let stderr = "";
  let finished = false;
  const fail = (error) => {
    for (const pending of state.pending.values()) pending.reject(error);
    for (const event of state.events.values()) event.reject(error);
  };
  const timeout = setTimeout(() => fail(new Error(`DAP scenario timed out\n${stderr}`)), 60000);
  child.on("error", fail);
  child.on("exit", (code, signal) => {
    if (!finished) fail(new Error(`DAP exited before scenario completed (${code ?? signal})\n${stderr}`));
  });
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
        if (message.event === "output") stderr = (stderr + (message.body?.output || "")).slice(-8192);
        if (message.event === "terminated" && state.events.has("stopped")) {
          fail(new Error(`Debug program terminated before reaching its breakpoint\n${stderr}`));
        }
        const event = state.events.get(message.event);
        if (event) {
          state.events.delete(message.event);
          event.resolve(message);
        }
      }
    }
  });
  child.stderr.on("data", data => { stderr = (stderr + data).slice(-8192); });
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
    finished = true;
    clearTimeout(timeout);
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

async function testTerminalCommandsUseArgumentVectors() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "tesl-extension-argv-"));
  const file = path.join(
    directory,
    'fixture $(touch injected-file) `tick` "double" \'single\' spaces.tesl'
  );
  fs.writeFileSync(file, "module Fixture exposing []\n", "utf8");
  const fixture = await activateWithFile(
    file,
    () => fs.rmSync(directory, { recursive: true, force: true }),
    directory,
    { enableTests: false }
  );
  const testName = 'name $(touch injected-test) `tick` "double" \'single\' whitespace';
  const windowsFile = 'C:\\workspace with spaces\\$(calc)\\`tick`\\"quoted".tesl';
  try {
    await fixture.commands.get("tesl.runSingleTest")(file, testName, "api-test");
    await fixture.commands.get("tesl.runTests")(fixture.uri);
    fixture.vscode.window.activeTextEditor = { document: { fileName: file } };
    await fixture.commands.get("tesl.runDebugMode")();
    await fixture.commands.get("tesl.runSingleTest")(windowsFile, testName, "test");

    const executions = fixture.taskCalls.map(({ task }) => task.execution);
    assert.ok(executions.every((execution) => execution instanceof ProcessExecution));
    assert.deepStrictEqual(
      executions[0].args,
      ["test", "--test-name", testName, "--test-kind", "api-test", file]
    );
    assert.deepStrictEqual(executions[1].args, ["test", file]);
    assert.deepStrictEqual(executions[2].args, ["run", "--debug", file]);
    assert.deepStrictEqual(
      executions[3].args,
      ["test", "--test-name", testName, "--test-kind", "test", windowsFile]
    );
    assert.ok(executions.every((execution) => execution.options.cwd));
    assert.ok(fixture.taskCalls.every(({ task }) => task.presentationOptions.reveal === 1));
    assert.ok(fixture.taskCalls.every(({ task }) => task.presentationOptions.panel === 3));
  } finally {
    fixture.cleanup();
  }
}

async function testFunctionInputUsesArgumentsAndFilesystemCleanup() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "tesl-extension-function-"));
  const file = path.join(directory, "function input with spaces.tesl");
  const marker = path.join(directory, "injected-marker");
  const callExpr = `identity "$(touch ${marker}) \`tick\` \\"quoted\\""`;
  const expected = '"value with spaces, $(substitution), `ticks`, and \\"quotes\\""';
  fs.writeFileSync(file, "module Fixture exposing []\n", "utf8");
  const fixture = await activateWithFile(
    file,
    () => fs.rmSync(directory, { recursive: true, force: true }),
    directory,
    { enableTests: false, inputValues: [callExpr, expected], configuration: installedToolFixture(directory) }
  );
  try {
    await fixture.commands.get("tesl.runFunctionWithInput")(fixture.uri);
    assert.strictEqual(fixture.taskCalls.length, 1);
    const { task } = fixture.taskCalls[0];
    const driver = task.execution.args.at(-1);
    assert.ok(task.execution instanceof ProcessExecution);
    assert.deepStrictEqual(
      task.execution.args,
      ["test", "--backend", "go", "--test-name", `repl: ${callExpr}`, driver]
    );
    assert.ok(fs.existsSync(driver));
    assert.match(fs.readFileSync(driver, "utf8"), /expect \(identity/);
    assert.strictEqual(fs.existsSync(marker), false);

    fixture.endTask(task);
    assert.strictEqual(fs.existsSync(path.dirname(driver)), false);
    assert.strictEqual(fs.existsSync(marker), false);
  } finally {
    fixture.cleanup();
  }
}

async function testUntrustedWorkspaceCannotExecute() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "tesl-extension-untrusted-"));
  const file = path.join(directory, "fixture.tesl");
  fs.writeFileSync(file, 'module Fixture exposing []\n\ntest "safe" {\n  expect 1 == 1\n}\n', "utf8");
  const fixture = await activateWithFile(
    file,
    () => fs.rmSync(directory, { recursive: true, force: true }),
    directory,
    { isTrusted: false, inputValues: ["dangerous", "0"], configuration: installedToolFixture(directory) }
  );
  try {
    fixture.vscode.window.activeTextEditor = { document: { fileName: file } };
    await fixture.commands.get("tesl.runSingleTest")(file, "safe", "test");
    await fixture.commands.get("tesl.runTests")(fixture.uri);
    await fixture.commands.get("tesl.runFunctionWithInput")(fixture.uri);
    await fixture.commands.get("tesl.runDebugMode")();
    await fixture.commands.get("tesl.debugSingleTest")(file, "safe", "test");
    await fixture.commands.get("tesl.debugTests")(fixture.uri);
    await fixture.commands.get("tesl.debugProgram")(fixture.uri);
    await fixture.commands.get("tesl.attachRunning")();

    assert.deepStrictEqual(fixture.taskCalls, []);
    assert.deepStrictEqual(fixture.debugCalls, []);
    assert.strictEqual(
      fixture.debugFactories[0].createDebugAdapterDescriptor({ configuration: { program: file } }),
      null
    );
    assert.strictEqual(
      fixture.debugProviders[0].resolveDebugConfiguration(undefined, {
        request: "launch",
        program: file,
      }),
      undefined
    );
    const document = { fileName: file, uri: fixture.uri, getText: () => fs.readFileSync(file, "utf8") };
    assert.deepStrictEqual(fixture.codeLensProviders[0].provideCodeLenses(document), []);
    assert.ok(fixture.warningMessages.every((message) => /trust this workspace/.test(message)));
  } finally {
    fixture.cleanup();
  }
}

// Task construction and trust tests need a selected installation, but never
// execute it. Keep them independent of a developer's PATH or Nix profile.
function installedToolFixture(directory) {
  const root = path.join(directory, "toolchain");
  fs.mkdirSync(path.join(root, "bin"), { recursive: true });
  fs.mkdirSync(path.join(root, "share", "tesl"), { recursive: true });
  const manifest = { version: 1, toolchain_version: "test", source_revision: "fixture", components: {} };
  for (const name of ["tesl", "compiler", "tesl-lsp", "tesl-dap"]) {
    const relative = `bin/${name}${process.platform === "win32" ? ".exe" : ""}`;
    fs.writeFileSync(path.join(root, relative), "fixture", { mode: 0o755 });
    manifest.components[name] = { path: relative, version: "test" };
  }
  fs.writeFileSync(path.join(root, "share", "tesl", "toolchain.json"), JSON.stringify(manifest));
  return { toolchainRoot: root };
}

function testManifestRequiresTrustForExecution() {
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, "package.json"), "utf8"));
  assert.deepStrictEqual(manifest.capabilities.untrustedWorkspaces, {
    supported: "limited",
    description: "Language features remain available, but running tests, programs, and debuggers requires Workspace Trust.",
    restrictedConfigurations: ["tesl.lspBinary", "tesl.dapBinary", "tesl.toolchainRoot"],
  });
  assert.ok(
    manifest.contributes.commands.every((command) => command.enablement === "isWorkspaceTrusted")
  );
  for (const items of Object.values(manifest.contributes.menus)) {
    assert.ok(items.every((item) => item.when.includes("isWorkspaceTrusted")));
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
test("terminal commands pass adversarial POSIX and Windows values as argv", testTerminalCommandsUseArgumentVectors);
test("function input is an argv value and temporary cleanup does not use a shell", testFunctionInputUsesArgumentsAndFilesystemCleanup);
test("untrusted workspaces cannot execute Tesl tasks or debug sessions", testUntrustedWorkspaceCannotExecute);
test("manifest requires Workspace Trust for execution commands", testManifestRequiresTrustForExecution);
