const { LanguageClient, TransportKind } = require("vscode-languageclient/node");
const path = require("path");
const fs = require("fs");
const os = require("os");
const { spawnSync, spawn } = require("child_process");
const vscode = require("vscode");
const { parseTeslTestOutput } = require("./test-output-parser");

let client;

function commandOnPath(name) {
  const cmd = process.platform === "win32" ? "where" : "which";
  return spawnSync(cmd, [name], { encoding: "utf8" }).status === 0;
}

function findNixShell() {
  if (commandOnPath("nix-shell")) return "nix-shell";
  const candidates = [
    path.join(os.homedir(), ".nix-profile", "bin", "nix-shell"),
    "/nix/var/nix/profiles/default/bin/nix-shell",
    "/run/current-system/sw/bin/nix-shell",
  ];
  return candidates.find((candidate) => fs.existsSync(candidate)) || null;
}

const repoToolchains = new Map();

function findRepoToolchain(repoRoot) {
  if (!repoRoot) return null;
  if (repoToolchains.has(repoRoot)) return repoToolchains.get(repoRoot);
  const nixShell = findNixShell();
  const shellFile = path.join(repoRoot, "shell.nix");
  if (!nixShell || !fs.existsSync(shellFile)) return null;
  const marker = "__TESL_ENV__";
  const result = spawnSync(
    nixShell,
    [shellFile, "--run", `export TESL_RESOLVED_GO="$(command -v go)"; printf '${marker}\\n'; env`],
    {
      cwd: repoRoot,
      encoding: "utf8",
      env: { ...process.env, TESL_SKIP_AUTO_BUILD: "1" },
    }
  );
  const lines = (result.stdout || "").split(/\r?\n/);
  const markerIndex = lines.lastIndexOf(marker);
  if (result.status !== 0 || markerIndex < 0) {
    repoToolchains.set(repoRoot, null);
    return null;
  }
  const environment = {};
  for (const line of lines.slice(markerIndex + 1)) {
    const separator = line.indexOf("=");
    if (separator > 0) environment[line.slice(0, separator)] = line.slice(separator + 1);
  }
  const go = environment.TESL_RESOLVED_GO;
  delete environment.TESL_RESOLVED_GO;
  delete environment.PWD;
  delete environment.OLDPWD;
  delete environment.SHLVL;
  delete environment._;
  const resolved = go && fs.existsSync(go) ? { go, environment } : null;
  repoToolchains.set(repoRoot, resolved);
  return resolved;
}

function findRepoGo(repoRoot) {
  return findRepoToolchain(repoRoot)?.go || null;
}

function stableTempDir() {
  const candidate = os.tmpdir();
  if (process.platform !== "win32") return "/tmp";
  return fs.existsSync(candidate) ? candidate : "C:\\Windows\\Temp";
}

function teslTempEnvironment() {
  const temp = stableTempDir();
  return { TMPDIR: temp, GOTMPDIR: temp, TMP: temp, TEMP: temp };
}

/**
 * Resolve how to launch the Tesl LSP.
 */
function resolveLsp(_extensionDir) {
  const override = vscode.workspace.getConfiguration("tesl").get("lspBinary");
  if (override && (fs.existsSync(override) || commandOnPath(override))) {
    return { kind: "binary", command: override };
  }

  const nixCandidates = [
    path.join(os.homedir(), ".nix-profile", "bin", "tesl-lsp"),
    "/nix/var/nix/profiles/default/bin/tesl-lsp",
    "/run/current-system/sw/bin/tesl-lsp",
  ];
  const binaryCmd = commandOnPath("tesl-lsp")
    ? "tesl-lsp"
    : nixCandidates.find((p) => fs.existsSync(p));
  if (binaryCmd) {
    return { kind: "binary", command: binaryCmd };
  }

  return null;
}

/**
 * Read compiler path from the tesl-lsp wrapper.
 */
function readTeslLspWrapper() {
  const candidates = [
    path.join(os.homedir(), ".nix-profile", "bin", "tesl-lsp"),
    "/nix/var/nix/profiles/default/bin/tesl-lsp",
  ];
  for (const p of candidates) {
    if (!fs.existsSync(p)) continue;
    try {
      const realPath = fs.realpathSync(p);
      const content = fs.readFileSync(realPath, "utf8");
      // The raw OCaml compiler the wrapper was built against. This is the
      // binary that speaks --check-json/--type-at-json; the `tesl` CLI wrapper
      // does NOT (it rejects unknown verbs), so it is a broken stand-in.
      const ocamlMatch = content.match(/export TESL_OCAML_COMPILER="([^"]+)"/);
      return { ocamlCompiler: ocamlMatch ? ocamlMatch[1] : null };
    } catch (_) {}
  }
  return null;
}

/**
 * Find the Tesl compiler binary.
 * Prefer the locally compiled binary (supports --debug) over the nix wrapper.
 */
/**
 * The workspace's own freshly built compiler, if this workspace is a Tesl repo
 * checkout. Kept separate from findTeslCompiler so callers can tell "the user
 * has a local build" from "we fell back to something installed".
 */
function findWorkspaceCompiler(wsPath) {
  if (!wsPath) return null;
  const local = path.join(wsPath, "compiler", "_build", "default", "bin", "main.exe");
  return fs.existsSync(local) ? local : null;
}

function findTeslRepoRoot(startPath) {
  if (!startPath) return null;
  let current = startPath;
  try {
    if (!fs.statSync(current).isDirectory()) current = path.dirname(current);
  } catch (_) {
    current = path.dirname(current);
  }
  while (true) {
    if (findWorkspaceCompiler(current) &&
        fs.existsSync(path.join(current, "runtime", "go", "cmd", "tesl-dap", "main.go"))) {
      return current;
    }
    const parent = path.dirname(current);
    if (parent === current) return null;
    current = parent;
  }
}

function resolveTeslRoot(wsPath, filePath) {
  return findTeslRepoRoot(filePath) || findTeslRepoRoot(wsPath) || wsPath;
}

function findTeslCompiler(wsPath, filePath) {
  // 1. Locally compiled binary in the workspace repo
  const local = findWorkspaceCompiler(resolveTeslRoot(wsPath, filePath));
  if (local) return local;

  // 2. TESL_COMPILER env var
  if (process.env.TESL_COMPILER && fs.existsSync(process.env.TESL_COMPILER)) {
    return process.env.TESL_COMPILER;
  }

  // 3. The raw compiler the installed tesl-lsp wrapper was built against.
  //    Tried BEFORE the `tesl` CLI below: the CLI wrapper dispatches verbs and
  //    rejects the compiler's own JSON flags, so handing it out as "the
  //    compiler" makes every compiler-backed feature fail silently.
  const wrapper = readTeslLspWrapper();
  if (wrapper && wrapper.ocamlCompiler && fs.existsSync(wrapper.ocamlCompiler)) {
    return wrapper.ocamlCompiler;
  }

  // 4. nix profile / PATH
  const nixPaths = [
    path.join(os.homedir(), ".nix-profile", "bin", "tesl"),
    "/nix/var/nix/profiles/default/bin/tesl",
  ];
  for (const p of nixPaths) {
    if (fs.existsSync(p)) return p;
  }
  if (commandOnPath("tesl")) return "tesl";

  return null;
}

function findGoDap(wsPath, filePath) {
  const override = vscode.workspace.getConfiguration("tesl").get("dapBinary");
  if (override && fs.existsSync(override)) return { command: override, args: [], cwd: undefined };

  const runtimeRoot = resolveTeslRoot(wsPath, filePath);
  const runtime = runtimeRoot ? path.join(runtimeRoot, "runtime", "go") : null;
  const go = findRepoGo(runtimeRoot);
  if (runtime && go && fs.existsSync(path.join(runtime, "cmd", "tesl-dap", "main.go"))) {
    return {
      command: go,
      args: ["run", "./cmd/tesl-dap"],
      cwd: runtime,
    };
  }

  const candidates = [
    path.join(os.homedir(), ".nix-profile", "bin", "tesl-dap"),
    "/nix/var/nix/profiles/default/bin/tesl-dap",
    "/run/current-system/sw/bin/tesl-dap",
  ];
  const onPath = commandOnPath("tesl-dap") ? "tesl-dap" : null;
  const binary = onPath || candidates.find((candidate) => fs.existsSync(candidate));
  if (binary) return { command: binary, args: [], cwd: undefined };
  return null;
}

function findTeslCli() {
  if (commandOnPath("tesl")) return "tesl";
  const candidates = [
    path.join(os.homedir(), ".nix-profile", "bin", "tesl"),
    "/nix/var/nix/profiles/default/bin/tesl",
    "/run/current-system/sw/bin/tesl",
  ];
  return candidates.find((candidate) => fs.existsSync(candidate)) || null;
}

function activate(context) {
  const wsPath = (vscode.workspace.workspaceFolders || [])[0]?.uri?.fsPath ?? "";

  function requireTrustedWorkspace() {
    if (vscode.workspace.isTrusted) return true;
    vscode.window.showWarningMessage(
      "Tesl: trust this workspace before running or debugging workspace code."
    );
    return false;
  }

  // ── LSP ──────────────────────────────────────────────────────────────────────
  const lsp = resolveLsp(context.extensionPath);

  if (!lsp) {
    vscode.window.showWarningMessage(
      "Tesl: could not find tesl-lsp. " +
      "Install Tesl (nix profile install github:mtonnberg/tesl) or set " +
      "tesl.lspBinary to the Go tesl-lsp executable."
    );
  } else {
    const outputChannel = vscode.window.createOutputChannel("Tesl Language Server");
    let serverOptions;
    if (lsp.kind === "binary") {
      outputChannel.appendLine(`[tesl-lsp] using binary: ${lsp.command}`);
      // A repo checkout's own build wins over the compiler baked into the
      // installed wrapper: otherwise diagnostics come from whatever revision
      // the profile was installed at, so a rule added in the working tree
      // looks like it simply does not exist. The wrapper honours an inherited
      // TESL_COMPILER (flake.nix, tesl-lsp).
      const wsCompiler = vscode.workspace.isTrusted ? findWorkspaceCompiler(wsPath) : null;
      if (wsCompiler) {
        outputChannel.appendLine(`[tesl-lsp] using workspace compiler: ${wsCompiler}`);
      }
      serverOptions = {
        command: lsp.command,
        args: [],
        transport: TransportKind.stdio,
        options: {
          env: {
            ...process.env,
            ...(wsCompiler ? { TESL_COMPILER: wsCompiler } : {}),
          },
        },
      };
    }

    const clientOptions = {
      documentSelector: [{ scheme: "file", language: "tesl" }],
      synchronize: {
        fileEvents: vscode.workspace.createFileSystemWatcher("**/*.tesl"),
      },
      outputChannel,
      revealOutputChannelOn: 1,
    };

    client = new LanguageClient("tesl-lsp", "Tesl Language Server", serverOptions, clientOptions);
    client.start().catch((err) => {
      outputChannel.appendLine(`[tesl-lsp] failed to start: ${err}`);
      vscode.window.showErrorMessage(`Tesl LSP failed to start: ${err}`);
    });
  }

  // ── Test discovery (shared by CodeLens + Test Explorer) ───────────────────────
  // Regexes for each test kind. api-test/load-test are checked BEFORE the plain
  // `test` regex (their lines start with "api-"/"load-", so they never match TEST_RE,
  // but the explicit ordering keeps the intent clear). Each kind maps to the compiler
  // `--test-kind` value of the same name.
  const TEST_RE = /^\s*test\s+"([^"]+)"/;
  const API_TEST_RE = /^\s*api-test\s+"([^"]+)"/;
  const LOAD_TEST_RE = /^\s*load-test\s+"([^"]+)"/;
  // A doctest example line: '#> <expr>'. The runnable unit is the whole doctest
  // block for the fn that follows; the compiler names that test "doctest: <fn>"
  // (see parser.ml extract_doctest_decls). We surface a lens on the FIRST '#>'
  // line of each block and resolve the fn name from the next 'fn <name>' line.
  const DOCTEST_RE = /^\s*#>\s*\S/;
  const FN_RE = /^\s*fn\s+([A-Za-z_][A-Za-z0-9_]*)/;

  // Returns { tests, apiTests, loadTests, doctests, hasAny }, where tests/apiTests/
  // loadTests are [{name, line}] and doctests are [{fnName, line}].
  function discoverTests(text) {
    const lines = text.split("\n");
    const tests = [];
    const apiTests = [];
    const loadTests = [];
    const doctests = [];
    for (let i = 0; i < lines.length; i++) {
      const am = API_TEST_RE.exec(lines[i]);
      if (am) { apiTests.push({ name: am[1], line: i }); continue; }
      const lm = LOAD_TEST_RE.exec(lines[i]);
      if (lm) { loadTests.push({ name: lm[1], line: i }); continue; }
      const tm = TEST_RE.exec(lines[i]);
      if (tm) { tests.push({ name: tm[1], line: i }); continue; }
      if (DOCTEST_RE.test(lines[i])) {
        // Only the first '#>' of a contiguous block gets a lens.
        const prev = i > 0 ? lines[i - 1] : "";
        const prevIsDoctest = /^\s*#[>=]/.test(prev);
        if (prevIsDoctest) continue;
        // Resolve the fn name: scan forward past the doctest block to the next 'fn'.
        let fnName = null;
        for (let j = i; j < lines.length; j++) {
          const fm = FN_RE.exec(lines[j]);
          if (fm) { fnName = fm[1]; break; }
          // Stop at a blank-then-non-doctest gap that isn't the fn — but doctest
          // lines and the immediately-following fn are contiguous in practice.
        }
        if (fnName) doctests.push({ fnName, line: i });
      }
    }
    return {
      tests, apiTests, loadTests, doctests,
      hasAny: tests.length > 0 || apiTests.length > 0
        || loadTests.length > 0 || doctests.length > 0,
    };
  }

  // ── CodeLens: per-test run/debug + per-doctest run + run-all-in-file ───────────
  const lensProvider = {
    provideCodeLenses(document) {
      if (!vscode.workspace.isTrusted || !document.fileName.endsWith(".tesl")) return [];
      const file = document.uri.fsPath;
      const { tests, apiTests, loadTests, doctests, hasAny } = discoverTests(document.getText());
      const lenses = [];

      // File-level "run all tests" lens at the first test/doctest block.
      if (hasAny) {
        const firstLine = Math.min(
          ...[...tests, ...apiTests, ...loadTests, ...doctests].map((t) => t.line)
        );
        const headRange = new vscode.Range(firstLine, 0, firstLine, 0);
        lenses.push(new vscode.CodeLens(headRange, {
          title: "▶ Run all tests in file",
          command: "tesl.runTests",
          arguments: [document.uri],
        }));
        lenses.push(new vscode.CodeLens(headRange, {
          title: "🐛 Debug all tests",
          command: "tesl.debugTests",
          arguments: [document.uri],
        }));
      }

      for (const t of tests) {
        const range = new vscode.Range(t.line, 0, t.line, 0);
        lenses.push(new vscode.CodeLens(range, {
          title: "▶ Run test",
          command: "tesl.runSingleTest",
          arguments: [file, t.name, "test"],
        }));
        lenses.push(new vscode.CodeLens(range, {
          title: "🐛 Debug test",
          command: "tesl.debugSingleTest",
          arguments: [file, t.name, "test"],
        }));
      }

      // api-tests: Run + Debug (a request scenario is steppable under the DAP).
      for (const t of apiTests) {
        const range = new vscode.Range(t.line, 0, t.line, 0);
        lenses.push(new vscode.CodeLens(range, {
          title: "▶ Run api-test",
          command: "tesl.runSingleTest",
          arguments: [file, t.name, "api-test"],
        }));
        lenses.push(new vscode.CodeLens(range, {
          title: "🐛 Debug api-test",
          command: "tesl.debugSingleTest",
          arguments: [file, t.name, "api-test"],
        }));
      }

      // load-tests: Run only — a throughput/latency benchmark isn't a steppable
      // scenario, so no Debug lens.
      for (const t of loadTests) {
        const range = new vscode.Range(t.line, 0, t.line, 0);
        lenses.push(new vscode.CodeLens(range, {
          title: "▶ Run load-test",
          command: "tesl.runSingleTest",
          arguments: [file, t.name, "load-test"],
        }));
      }

      for (const d of doctests) {
        const range = new vscode.Range(d.line, 0, d.line, 0);
        // Doctests compile to a test named exactly "doctest: <fnName>".
        const testName = `doctest: ${d.fnName}`;
        lenses.push(new vscode.CodeLens(range, {
          title: "▶ Run doctest",
          command: "tesl.runSingleTest",
          arguments: [file, testName, "doctest"],
        }));
        lenses.push(new vscode.CodeLens(range, {
          title: "🐛 Debug doctest",
          command: "tesl.debugSingleTest",
          arguments: [file, testName, "doctest"],
        }));
      }

      return lenses;
    },
  };
  context.subscriptions.push(
    vscode.languages.registerCodeLensProvider({ language: "tesl" }, lensProvider)
  );

  // "Run test" — run a single named test via the `tesl` CLI wrapper.
  //
   // Run through the `tesl` wrapper rather than invoking a compiler directly, so
   // the selected backend and its runtime environment stay consistent.
  function findTeslWrapper() {
    if (commandOnPath("tesl")) return "tesl";
    const nixPaths = [
      path.join(os.homedir(), ".nix-profile", "bin", "tesl"),
      "/nix/var/nix/profiles/default/bin/tesl",
    ];
    for (const p of nixPaths) {
      if (fs.existsSync(p)) return p;
    }
    return "tesl";
  }
  function teslProcessOptions(file) {
    const folder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(file));
    const root = resolveTeslRoot(folder ? folder.uri.fsPath : wsPath, file);
    const compiler = findWorkspaceCompiler(root);
    const toolchain = compiler ? findRepoToolchain(root) : null;
    return {
      cwd: path.dirname(file),
      env: {
        ...(toolchain ? toolchain.environment : process.env),
        ...teslTempEnvironment(),
        ...(compiler ? {
          TESL_REPO_ROOT: root,
          TESL_OCAML_COMPILER: compiler,
          TESL_COMPILER: compiler,
          ...(toolchain ? { TESL_GO: toolchain.go } : {}),
        } : {}),
      },
    };
  }
  function teslLauncher(file) {
    const folder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(file));
    const root = resolveTeslRoot(folder ? folder.uri.fsPath : wsPath, file);
    const localBody = path.join(root, "nix", "tesl-cli-body.sh");
    const bash = fs.existsSync("/bin/bash") ? "/bin/bash" : "bash";
    if (findWorkspaceCompiler(root) && findRepoGo(root) && fs.existsSync(localBody)) {
      return { command: bash, prefixArgs: [localBody] };
    }
    return { command: findTeslWrapper(), prefixArgs: [] };
  }
  function runProcessInTerminal(file, name, command, args, onEnd) {
    const folder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(file));
    const execution = new vscode.ProcessExecution(command, args, teslProcessOptions(file));
    const task = new vscode.Task(
      { type: "tesl" },
      folder || vscode.TaskScope.Workspace,
      name,
      "Tesl",
      execution,
      []
    );
    task.presentationOptions = {
      reveal: vscode.TaskRevealKind.Always,
      focus: false,
      panel: vscode.TaskPanelKind.New,
      echo: true,
      showReuseMessage: false,
    };

    let ended = false;
    let endSubscription = null;
    const finish = () => {
      if (ended) return;
      ended = true;
      if (endSubscription) endSubscription.dispose();
      if (onEnd) onEnd();
    };
    if (onEnd) {
      endSubscription = vscode.tasks.onDidEndTask((event) => {
        if (event.execution.task !== task) return;
        finish();
      });
    }
    return vscode.tasks.executeTask(task).catch((error) => {
      finish();
      throw error;
    });
  }
  function runTeslInTerminal(file, name, args, onEnd) {
    const launcher = teslLauncher(file);
    return runProcessInTerminal(
      file,
      name,
      launcher.command,
      [...launcher.prefixArgs, ...args],
      onEnd
    );
  }
  function runNamedTestInTerminal(file, testName, terminalName, kind) {
    const args = ["test", "--test-name", testName];
    if (kind) args.push("--test-kind", kind);
    args.push(file);
    return runTeslInTerminal(file, terminalName || `Tesl: ${testName}`, args);
  }

  // Set once Test Explorer is initialized. CodeLens runs then share Test Results.
  let runSingleTestInExplorer = null;
  let runFileInExplorer = null;
  let debugFileInExplorer = null;

  context.subscriptions.push(
    vscode.commands.registerCommand("tesl.runSingleTest", async (file, testName, kind) => {
      if (!requireTrustedWorkspace()) return;
      if (runSingleTestInExplorer) {
        await runSingleTestInExplorer(file, testName, kind);
        return;
      }
      await runNamedTestInTerminal(file, testName, undefined, kind);
    })
  );

  // "Debug test" — compile only the named test, then start a debug session.
  context.subscriptions.push(
    vscode.commands.registerCommand("tesl.debugSingleTest", (file, testName, kind) => {
      if (!requireTrustedWorkspace()) return;
      const folder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(file));
      vscode.debug.startDebugging(folder, {
        type: "tesl", request: "launch",
        name: `Debug: ${testName}`,
        program: file,
        mode: "test",
        testName,          // passed as args.testName → DAP server → --test-name flag
        testKind: kind,    // passed as args.testKind → DAP server → --test-kind flag
      });
    })
  );

  // ── Context-menu commands ─────────────────────────────────────────────────────
  // Helper: get the file path from a context-menu invocation or the active editor.
  function teslFileFrom(uri) {
    if (uri && uri.fsPath) return uri.fsPath;
    const editor = vscode.window.activeTextEditor;
    return editor ? editor.document.fileName : null;
  }

  // "Debug Tesl Tests" — launches the debugger in test mode for the current file.
  context.subscriptions.push(
    vscode.commands.registerCommand("tesl.debugTests", async (uri) => {
      if (!requireTrustedWorkspace()) return;
      const file = teslFileFrom(uri);
      if (!file) { vscode.window.showErrorMessage("No Tesl file selected."); return; }
      if (debugFileInExplorer) {
        await debugFileInExplorer(file);
        return;
      }
      const folder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(file));
      vscode.debug.startDebugging(folder, {
        type: "tesl", request: "launch", name: "Debug Tesl Tests",
        program: file, mode: "test",
      });
    })
  );

  // "Debug Tesl Program" — launches the debugger in program (main) mode.
  context.subscriptions.push(
    vscode.commands.registerCommand("tesl.debugProgram", (uri) => {
      if (!requireTrustedWorkspace()) return;
      const file = teslFileFrom(uri);
      if (!file) { vscode.window.showErrorMessage("No Tesl file selected."); return; }
      const folder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(file));
      vscode.debug.startDebugging(folder, {
        type: "tesl", request: "launch", name: "Debug Tesl Program",
        program: file, mode: "program",
      });
    })
  );

  // "Run Tesl Tests in Terminal" — runs tesl test without the debugger.
  context.subscriptions.push(
    vscode.commands.registerCommand("tesl.runTests", async (uri) => {
      if (!requireTrustedWorkspace()) return;
      const file = teslFileFrom(uri);
      if (!file) { vscode.window.showErrorMessage("No Tesl file selected."); return; }
      if (runFileInExplorer) {
        await runFileInExplorer(file);
        return;
      }
      await runTeslInTerminal(file, "Tesl Tests", ["test", file]);
    })
  );

  // ── REPL-like "Run Function with Input" ───────────────────────────────────────
  // Prompt for a function call (seeded from the identifier under the cursor) plus
  // an expected value, then append a synthetic `test` block to a temp copy of the
  // file and run it through the Go CLI test path used by the test lenses.
  // Tesl has no user-facing print primitive, so the test harness IS the REPL: on a
  // mismatch the harness prints the actual value (the function's result); on match
  // it prints PASS. This does NOT depend on the LSP.
  context.subscriptions.push(
    vscode.commands.registerCommand("tesl.runFunctionWithInput", async (uri) => {
      if (!requireTrustedWorkspace()) return;
      const editor = vscode.window.activeTextEditor;
      const file = (uri && uri.fsPath) || (editor && editor.document.fileName);
      if (!file || !file.endsWith(".tesl")) {
        vscode.window.showErrorMessage("Run Function: open a .tesl file first.");
        return;
      }

      // Seed the function name from the word under the cursor, if any.
      let seed = "";
      if (editor && editor.document.fileName === file) {
        const wr = editor.document.getWordRangeAtPosition(editor.selection.active, /[A-Za-z_][A-Za-z0-9_]*/);
        if (wr) seed = editor.document.getText(wr) + " ";
      }

      const callExpr = await vscode.window.showInputBox({
        title: "Tesl: Run Function with Input",
        prompt: "Call expression to evaluate (Tesl source), e.g.  double 3  or  clamp 0 10 99",
        value: seed,
        ignoreFocusOut: true,
        validateInput: (v) => ((v || "").trim() ? null : "Enter a Tesl expression to evaluate."),
      });
      if (!callExpr || !callExpr.trim()) return; // cancelled

      const expected = await vscode.window.showInputBox({
        title: `Tesl: ${callExpr.trim()}`,
        prompt: "Expected value to compare against (Tesl source). On mismatch the harness prints the actual result.",
        value: "0",
        ignoreFocusOut: true,
      });
      if (expected === undefined) return; // cancelled

      const tesl = findTeslCli();
      if (!tesl) {
        vscode.window.showErrorMessage(
          "Run Function: tesl CLI not found. Install Tesl or add tesl to PATH."
        );
        return;
      }

      const expr = callExpr.trim();
      const exp = (expected.trim() || "0");
      const testName = `repl: ${expr}`;
      // Append a synthetic test to a temp copy so the user's file is untouched.
      const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "tesl-run-"));
      const driver = path.join(tmpDir, path.basename(file));
      try {
        const src = fs.readFileSync(file, "utf8");
        const block = `\n\ntest "${testName.replace(/"/g, '\\"')}" {\n  expect (${expr}) == (${exp})\n}\n`;
        fs.writeFileSync(driver, src + block, "utf8");
      } catch (e) {
        fs.rmSync(tmpDir, { recursive: true, force: true });
        vscode.window.showErrorMessage(`Run Function: could not prepare driver: ${e}`);
        return;
      }

      // Compile only the synthetic test with the Go backend, then remove the temp dir.
      await runProcessInTerminal(
        file,
        `Tesl: ${expr}`,
        tesl,
        ["test", "--backend", "go", "--test-name", testName, driver],
        () => fs.rmSync(tmpDir, { recursive: true, force: true })
      );
    })
  );

  // ── Test Explorer (VS Code TestController API) ────────────────────────────────
  // A-tier integration: discover ALL .tesl tests in the workspace (not just open
  // files), run them via the `tesl` CLI capturing real pass/fail/error status, and
  // report results (failure messages + source locations + durations) back to the
  // Test Explorer. Run is the default profile; Debug launches the DAP per test.
  if (vscode.tests && typeof vscode.tests.createTestController === "function") {
    const ctrl = vscode.tests.createTestController("tesl", "Tesl Tests");
    context.subscriptions.push(ctrl);

    // Per-kind tags so the UI can group/filter test / api-test / load-test / doctest.
    const TAGS = {
      "test": new vscode.TestTag("test"),
      "api-test": new vscode.TestTag("api-test"),
      "load-test": new vscode.TestTag("load-test"),
      "doctest": new vscode.TestTag("doctest"),
    };

    // ID scheme: file nodes use the document URI string; leaf nodes use
    // "<fsPath>::<kind>::<name>". targetOf() decodes a leaf back to (file, name, kind);
    // api-test/load-test/doctest are matched before the plain `test` form.
    function targetOf(item) {
      const id = item.id;
      let m = /^(.*)::api-test::(.*)$/.exec(id);
      if (m) return { file: m[1], testName: m[2], kind: "api-test" };
      m = /^(.*)::load-test::(.*)$/.exec(id);
      if (m) return { file: m[1], testName: m[2], kind: "load-test" };
      m = /^(.*)::doctest::(.*)$/.exec(id);
      if (m) return { file: m[1], testName: `doctest: ${m[2]}`, kind: "doctest" };
      m = /^(.*)::test::(.*)$/.exec(id);
      if (m) return { file: m[1], testName: m[2], kind: "test" };
      return null; // file-level node
    }

    function ensureFileItem(uri) {
      let fileItem = ctrl.items.get(uri.toString());
      if (!fileItem) {
        fileItem = ctrl.createTestItem(uri.toString(), path.basename(uri.fsPath), uri);
        fileItem.canResolveChildren = true;
        ctrl.items.add(fileItem);
      }
      return fileItem;
    }

    // Read a .tesl file's text — prefer an open (possibly-unsaved) document so the
    // tree reflects live edits, else read from disk.
    function readTeslText(uri) {
      const open = vscode.workspace.textDocuments.find(
        (d) => d.uri.toString() === uri.toString()
      );
      if (open) return open.getText();
      try { return fs.readFileSync(uri.fsPath, "utf8"); } catch (_e) { return null; }
    }

    // Populate a file node's children from its source. Deletes the node if the file
    // has no tests, so the tree shows only files that actually contain tests.
    function populateChildren(fileItem, uri, text) {
      const { tests, apiTests, loadTests, doctests, hasAny } = discoverTests(text);
      if (!hasAny) { ctrl.items.delete(uri.toString()); return; }
      const kids = [];
      const mk = (id, label, line, kind) => {
        const item = ctrl.createTestItem(id, label, uri);
        item.range = new vscode.Range(line, 0, line, 0);
        item.tags = [TAGS[kind]];
        kids.push(item);
      };
      for (const t of tests) mk(`${uri.fsPath}::test::${t.name}`, t.name, t.line, "test");
      for (const t of apiTests) mk(`${uri.fsPath}::api-test::${t.name}`, `api-test: ${t.name}`, t.line, "api-test");
      for (const t of loadTests) mk(`${uri.fsPath}::load-test::${t.name}`, `load-test: ${t.name}`, t.line, "load-test");
      for (const d of doctests) mk(`${uri.fsPath}::doctest::${d.fnName}`, `doctest: ${d.fnName}`, d.line, "doctest");
      fileItem.children.replace(kids);
      fileItem.canResolveChildren = false; // children are now materialized
    }

    function resolveFileItem(fileItem) {
      const uri = fileItem.uri || vscode.Uri.parse(fileItem.id);
      const text = readTeslText(uri);
      if (text == null) {
        // Transient read failure (e.g. WSL/SSH I/O). Leave the node in place — real
        // deletions are handled by the file watcher's onDidDelete — and surface why.
        console.warn(`tesl: could not read ${uri.fsPath} for test discovery`);
        return;
      }
      populateChildren(fileItem, uri, text);
    }

    const TESL_GLOB = "**/*.tesl";
    // .direnv holds nix flake-input symlinks into the store — for a project whose
    // flake pins tesl, that is the ENTIRE tesl repo (examples, lessons, its own
    // test suites), so without this exclude the Test Explorer fills up with
    // hundreds of foreign tests.
    const TESL_EXCLUDE = "**/{node_modules,.git,_build,result,.tesl-postgres,.direnv}/**";

    // Project-wide discovery: scan every .tesl file once, keep only those with tests.
    // Coalesced — activation calls this fire-and-forget AND resolveHandler(undefined)/
    // refreshHandler may call it concurrently; a single in-flight promise prevents the
    // two from interleaving and double-writing the tree.
    let discoveryInFlight = null;
    function discoverAllFiles() {
      if (discoveryInFlight) return discoveryInFlight;
      discoveryInFlight = (async () => {
        try {
          let uris = [];
          try { uris = await vscode.workspace.findFiles(TESL_GLOB, TESL_EXCLUDE); } catch (_e) { uris = []; }
          const seen = new Set();
          for (const uri of uris) {
            const text = readTeslText(uri);
            if (text == null) continue;
            if (!discoverTests(text).hasAny) { ctrl.items.delete(uri.toString()); continue; }
            seen.add(uri.toString());
            populateChildren(ensureFileItem(uri), uri, text);
          }
          const stale = [];
          ctrl.items.forEach((item) => { if (!seen.has(item.id)) stale.push(item.id); });
          stale.forEach((id) => ctrl.items.delete(id));
        } finally {
          discoveryInFlight = null;
        }
      })();
      return discoveryInFlight;
    }

    // VS Code calls resolveHandler(undefined) to discover the root set (and on the
    // Test Explorer refresh button), and resolveHandler(fileItem) to lazily expand.
    ctrl.resolveHandler = async (item) => {
      if (!item) { await discoverAllFiles(); return; }
      resolveFileItem(item);
    };
    ctrl.refreshHandler = async () => { await discoverAllFiles(); };

    // Gather the leaf test items implied by a run request, resolving file nodes on
    // demand so "run all"/"run file" works even before the user expanded them.
    function collectLeaves(request) {
      const roots = (request.include && request.include.length) ? request.include : null;
      // Resolve unresolved file nodes FIRST via a snapshot pass — resolveFileItem ->
      // populateChildren can delete a (now test-less) file item from ctrl.items, so it
      // must not run inside a live ctrl.items.forEach traversal.
      const toResolve = [];
      const scan = (item) => { if (!targetOf(item) && item.children.size === 0) toResolve.push(item); };
      if (roots) roots.forEach(scan); else ctrl.items.forEach(scan);
      toResolve.forEach(resolveFileItem);
      const leaves = [];
      const visit = (item) => {
        if (item.children.size > 0) { item.children.forEach(visit); return; }
        if (targetOf(item)) leaves.push(item);
      };
      if (roots) roots.forEach(visit);
      else ctrl.items.forEach(visit);
      const excluded = new Set((request.exclude || []).map((i) => i.id));
      return leaves.filter((i) => !excluded.has(i.id));
    }

    // Run `tesl test <file>` once, capturing combined output + exit code + duration.
    // With testName (and optionally kind) runs ONLY that test via --test-name /
    // --test-kind — the same flags the CodeLens path uses.
    function runTeslTestFile(file, token, testName, kind) {
      return new Promise((resolve) => {
        const launcher = teslLauncher(file);
        const start = Date.now();
        let settled = false;
        let cancelSub = null;
        // Both 'error' and 'close' can fire for one process — settle (resolve +
        // dispose the cancellation listener) exactly once.
        const finish = (result) => {
          if (settled) return;
          settled = true;
          if (cancelSub) cancelSub.dispose();
          resolve(result);
        };
        const args = [...launcher.prefixArgs, "test"];
        if (testName) {
          args.push("--test-name", testName);
          if (kind) args.push("--test-kind", kind);
        }
        args.push(file);
        let child;
        try {
          child = spawn(launcher.command, args, teslProcessOptions(file));
        } catch (e) {
          finish({ code: -1, output: `failed to launch tesl: ${e && e.message}`, durationMs: 0 });
          return;
        }
        let out = "";
        const onData = (d) => { out += d.toString(); };
        if (child.stdout) child.stdout.on("data", onData);
        if (child.stderr) child.stderr.on("data", onData);
        cancelSub = token.onCancellationRequested(() => { try { child.kill("SIGTERM"); } catch (_e) {} });
        child.on("error", (err) => finish({ code: -1, output: `${out}\nfailed to run tesl: ${err.message}`, durationMs: Date.now() - start }));
        child.on("close", (code) => finish({ code: code == null ? -1 : code, output: out, durationMs: Date.now() - start }));
      });
    }

    function failureForTest(failures, testName, ordinal, isolated) {
      const direct = failures.get(testName) || failures.get(`TestTesl${ordinal + 1}`);
      if (direct || !isolated || failures.size !== 1) return direct;
      // An isolated compiler run contains exactly one generated test. Its
      // TestTesl index follows source order and may be zero-based, so the sole
      // failure is unambiguously the selected test.
      return failures.values().next().value;
    }

    // Run profile (default): execute selected tests, report real pass/fail/error.
    // Selected leaves are grouped by file and each file is run ONCE (rackunit prints
    // only failures; passes are inferred from "discovered ∧ not failed ∧ compiled").
    const runHandler = async (request, token) => {
      const run = ctrl.createTestRun(request);
      try {
        if (!requireTrustedWorkspace()) return;
        const byFile = new Map(); // file -> [{ item, tgt }]
        for (const item of collectLeaves(request)) {
          const tgt = targetOf(item);
          if (!tgt) continue;
          run.enqueued(item);
          if (!byFile.has(tgt.file)) byFile.set(tgt.file, []);
          byFile.get(tgt.file).push({ item, tgt });
        }
        for (const [file, entries] of byFile) {
          if (token.isCancellationRequested) { entries.forEach((e) => run.skipped(e.item)); continue; }

          // Strict subset of the file's tests selected → run each via
          // --test-name/--test-kind so siblings do NOT run. Whole file selected →
          // one `tesl test <file>` run (cheaper: one compile, one process).
          const fileItem = ctrl.items.get(vscode.Uri.file(file).toString());
          const leafSelected = (request.include || []).some((item) => {
            const target = targetOf(item);
            return target && target.file === file;
          });
          const wholeFile = !leafSelected && (!fileItem || entries.length >= fileItem.children.size);
          if (!wholeFile) {
            for (const { item, tgt } of entries) {
              if (token.isCancellationRequested) { run.skipped(item); continue; }
              run.started(item);
              const res = await runTeslTestFile(file, token, tgt.testName, tgt.kind);
              run.appendOutput(`\r\n=== ${path.basename(file)} :: ${tgt.testName} (exit ${res.code}) ===\r\n`);
              if (res.output) run.appendOutput(res.output.replace(/\r?\n/g, "\r\n"));
              const { failures, compileError, reportedFailureCount } = parseTeslTestOutput(res.output, res.code);
              const confident = res.code === 0 ||
                (reportedFailureCount !== null && failures.size >= reportedFailureCount);
              if (compileError) {
                run.errored(item, new vscode.TestMessage(compileError), res.durationMs);
              } else {
               // Each isolated `--test-name` compile contains one generated Go
               // test, so the sole failure belongs to the selected item.
                const f = failureForTest(failures, tgt.testName, 0, true);
                if (f) {
                  const msg = new vscode.TestMessage(f.message || "test failed");
                  if (item.uri && item.range) msg.location = new vscode.Location(item.uri, item.range);
                  if (f.expected !== undefined) msg.expectedOutput = f.expected;
                  if (f.actual !== undefined) msg.actualOutput = f.actual;
                  run.failed(item, msg, res.durationMs);
                } else if (confident) {
                  run.passed(item, res.durationMs);
                } else {
                  run.errored(item, new vscode.TestMessage(
                    "could not determine this test's result — the test runner reported failures that could not be matched to a test name"), res.durationMs);
                }
              }
            }
            continue;
          }

          entries.forEach((e) => run.started(e.item));
          const res = await runTeslTestFile(file, token);
          run.appendOutput(`\r\n=== ${path.basename(file)} (exit ${res.code}) ===\r\n`);
          if (res.output) run.appendOutput(res.output.replace(/\r?\n/g, "\r\n"));
          const { failures, compileError, reportedFailureCount } = parseTeslTestOutput(res.output, res.code);
          // Only report a PASS when confident every failure was attributed: the run
          // exited 0, OR the parsed failure count matches the run summary. Otherwise a
          // failure the parser could not attribute would masquerade as a pass — so the
          // unattributed tests are marked errored ("undetermined") rather than passed.
          const confident = res.code === 0 ||
            (reportedFailureCount !== null && failures.size >= reportedFailureCount);
          // rackunit reports no per-case timing, so spread the file-run duration
          // evenly across the file's tests.
          const per = entries.length ? Math.max(0, Math.round(res.durationMs / entries.length)) : res.durationMs;
          for (const [ordinal, { item, tgt }] of entries.entries()) {
            if (token.isCancellationRequested) { run.skipped(item); continue; }
            if (compileError) {
              run.errored(item, new vscode.TestMessage(compileError), per);
              continue;
            }
            const f = failureForTest(failures, tgt.testName, ordinal);
            if (f) {
              const msg = new vscode.TestMessage(f.message || "test failed");
              if (item.uri && item.range) msg.location = new vscode.Location(item.uri, item.range);
              if (f.expected !== undefined) msg.expectedOutput = f.expected;
              if (f.actual !== undefined) msg.actualOutput = f.actual;
              run.failed(item, msg, per);
            } else if (confident) {
              run.passed(item, per);
            } else {
              run.errored(item, new vscode.TestMessage(
                "could not determine this test's result — the test runner reported failures that could not be matched to a test name"), per);
            }
          }
        }
      } finally {
        run.end();
      }
    };

    runSingleTestInExplorer = async (file, testName, kind) => {
      await discoverAllFiles();
      const fileItem = ctrl.items.get(vscode.Uri.file(file).toString());
      let item = null;
      if (fileItem) {
        fileItem.children.forEach((child) => {
          const target = targetOf(child);
          if (!item && target && target.testName === testName && target.kind === kind) item = child;
        });
      }
      if (!item) {
        vscode.window.showErrorMessage(`Tesl: test not found in Test Explorer: ${testName}`);
        return;
      }
      const cancellation = new vscode.CancellationTokenSource();
      try {
        await runHandler(new vscode.TestRunRequest([item]), cancellation.token);
      } finally {
        cancellation.dispose();
      }
    };
    runFileInExplorer = async (file) => {
      await discoverAllFiles();
      const fileItem = ctrl.items.get(vscode.Uri.file(file).toString());
      if (!fileItem) {
        vscode.window.showErrorMessage(`Tesl: file not found in Test Explorer: ${file}`);
        return;
      }
      const cancellation = new vscode.CancellationTokenSource();
      try {
        await runHandler(new vscode.TestRunRequest([fileItem]), cancellation.token);
      } finally {
        cancellation.dispose();
      }
    };
    debugFileInExplorer = async (file) => {
      const folder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(file));
      return vscode.debug.startDebugging(folder, {
        type: "tesl", request: "launch", name: "Debug Tesl Tests",
        program: file, mode: "test",
      });
    };
    ctrl.createRunProfile("Run", vscode.TestRunProfileKind.Run, runHandler, true);

    // Debug profile: launch the DAP session per selected test (test mode). The DAP
    // session does not report pass/fail back to the TestRun (the debugger UI is the
    // feedback channel), so we await each launch and only flag a launch FAILURE on the
    // item — we never mark a started item skipped (an illegal state transition).
    // Load-tests are throughput benchmarks, not steppable, so they are skipped here.
    ctrl.createRunProfile("Debug", vscode.TestRunProfileKind.Debug, async (request, token) => {
      const run = ctrl.createTestRun(request);
      try {
        if (!requireTrustedWorkspace()) return;
        // A file-level debug request should be one DAP session for the file. The
        // leaf loop below is for individually selected tests only; launching one
        // session per child without waiting makes VS Code reject the later starts.
        const fileRoots = (request.include || []).filter((item) => !targetOf(item));
        if (fileRoots.length > 0) {
          for (const item of fileRoots) {
            if (token.isCancellationRequested) { run.skipped(item); continue; }
            run.enqueued(item);
            let ok = false;
            try {
              const file = item.uri ? item.uri.fsPath : vscode.Uri.parse(item.id).fsPath;
              ok = await debugFileInExplorer(file);
            } catch (_e) { ok = false; }
            if (!ok) run.errored(item, new vscode.TestMessage("failed to start the Tesl debug session"));
          }
          return;
        }
        for (const item of collectLeaves(request)) {
          const tgt = targetOf(item);
          if (!tgt) continue;
          if (tgt.kind === "load-test" || token.isCancellationRequested) { run.skipped(item); continue; }
          const folder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(tgt.file));
          let ok = false;
          try {
            ok = await vscode.debug.startDebugging(folder, {
              type: "tesl", request: "launch",
              name: `Debug: ${item.label}`,
              program: tgt.file, mode: "test", testName: tgt.testName, testKind: tgt.kind,
            });
          } catch (_e) { ok = false; }
          if (!ok) run.errored(item, new vscode.TestMessage("failed to start the Tesl debug session"));
        }
      } finally {
        run.end();
      }
    }, false);

    // Initial discovery + keep the tree fresh on file create/change/delete and on
    // live edits in open documents.
    discoverAllFiles();
    const teslWatcher = vscode.workspace.createFileSystemWatcher(TESL_GLOB);
    const refreshUri = (uri) => {
      const text = readTeslText(uri);
      if (text != null && discoverTests(text).hasAny) populateChildren(ensureFileItem(uri), uri, text);
      else ctrl.items.delete(uri.toString());
    };
    teslWatcher.onDidCreate(refreshUri);
    teslWatcher.onDidChange(refreshUri);
    teslWatcher.onDidDelete((uri) => ctrl.items.delete(uri.toString()));
    context.subscriptions.push(
      teslWatcher,
      vscode.workspace.onDidOpenTextDocument((doc) => { if (doc.fileName.endsWith(".tesl")) refreshUri(doc.uri); }),
      vscode.workspace.onDidChangeTextDocument((e) => { if (e.document.fileName.endsWith(".tesl")) refreshUri(e.document.uri); })
    );
  }

  // ── Debug Adapter ─────────────────────────────────────────────────────────────
  // Use the shipped Go adapter for both launch and attach. There is no Racket
  // fallback: a missing Go adapter is an installation error, not a reason to
  // silently switch protocol/runtime implementations.
  context.subscriptions.push(
    vscode.debug.registerDebugAdapterDescriptorFactory("tesl", {
      createDebugAdapterDescriptor(session) {
        if (!requireTrustedWorkspace()) return null;
        const sessionRoot = session.workspaceFolder?.uri?.fsPath || wsPath;
        const program = session.configuration.program;
        const projectRoot = resolveTeslRoot(sessionRoot, program);
        const goDap = findGoDap(sessionRoot, program);
        if (!goDap) {
          vscode.window.showErrorMessage(
            "Tesl debugger: Go tesl-dap not found. Install Tesl or add tesl-dap to PATH."
          );
          return null;
        }

        const compiler = findTeslCompiler(sessionRoot, program);
        const toolchain = findTeslRepoRoot(program) ? findRepoToolchain(projectRoot) : null;
        const env = {
          ...(toolchain ? toolchain.environment : process.env),
          ...teslTempEnvironment(),
          TESL_DAP_TRACE: "1",
          ...(projectRoot ? { TESL_REPO_ROOT: projectRoot } : {}),
          ...(compiler ? { TESL_COMPILER: compiler } : {}),
        };
        const dbgOut = vscode.window.createOutputChannel("Tesl Debugger");
        dbgOut.appendLine(`[tesl-debug] Go DAP: ${goDap.command} ${goDap.args.join(" ")}`);
        dbgOut.appendLine(`[tesl-debug] target: ${session.configuration.program || session.configuration.project || "(explicit endpoint)"}`);
        dbgOut.appendLine(`[tesl-debug] compiler: ${compiler || "PATH fallback"}`);
        dbgOut.show(true);
        return new vscode.DebugAdapterExecutable(goDap.command, goDap.args, { env, cwd: goDap.cwd });
      },
    })
  );

  // Attach ergonomics: make `request: "attach"` work with ZERO config.
  // - A bare attach config (no project/socket/port/program) gets the workspace
  //   folder as its project, which is where `tesl run --debug` puts the
  //   endpoint (<project>/.tesl-stuff/debug.sock or debug.port).
  // - Fail fast with a actionable message when no endpoint exists, instead of
  //   letting the adapter session start and immediately terminate.
  context.subscriptions.push(
    vscode.debug.registerDebugConfigurationProvider("tesl", {
      // Phase 1 — runs BEFORE ${...} variable substitution: only fill in
      // defaults here. Never touch the filesystem with config values at this
      // stage — a value like "${workspaceFolder}/backend" is still the raw
      // unsubstituted string and any path check on it is meaningless.
      resolveDebugConfiguration(folder, config) {
        if (!requireTrustedWorkspace()) return undefined;
        if (config.request === "launch" && typeof config.program === "string" &&
            config.program.toLowerCase().endsWith(".tesl") && !config.cwd && folder) {
          config.cwd = folder.uri.fsPath;
        }
        if (config.request === "attach" && !config.socket && !config.port && !config.program) {
          if (!config.project) {
            config.project = folder ? folder.uri.fsPath : wsPath;
          }
          if (!config.name) config.name = "Attach to running app (tesl run --debug)";
        }
        return config;
      },
      // Phase 2 — runs AFTER substitution: config.project is now a real path,
      // so fail fast with an actionable message when no endpoint exists,
      // instead of letting the adapter session start and instantly terminate.
      resolveDebugConfigurationWithSubstitutedVariables(folder, config) {
        if (!requireTrustedWorkspace()) return undefined;
        if (config.request === "attach" && !config.socket && !config.port && !config.program && config.project) {
          const stuff = path.join(config.project, ".tesl-stuff");
          const hasEndpoint =
            fs.existsSync(path.join(stuff, "debug.sock")) ||
            fs.existsSync(path.join(stuff, "debug.port"));
          if (!hasEndpoint) {
            vscode.window.showErrorMessage(
              `Tesl: no attach endpoint under ${stuff} — start the app first with \`tesl run --debug <file.tesl>\` (Tesl: Run current file in debug mode).`
            );
            return undefined; // abort the session cleanly
          }
        }
        return config;
      },
    })
  );

  // Palette command: start the current file under `tesl run --debug` in a
  // terminal — the counterpart of the attach config above.
  context.subscriptions.push(
    vscode.commands.registerCommand("tesl.runDebugMode", async () => {
       if (!requireTrustedWorkspace()) return;
       const editor = vscode.window.activeTextEditor;
       if (!editor || !editor.document.fileName.endsWith(".tesl")) {
         vscode.window.showErrorMessage("Tesl: open a .tesl file first.");
         return;
       }
       await runTeslInTerminal(
         editor.document.fileName,
         "tesl run --debug",
         ["run", "--debug", editor.document.fileName]
       );
     })
   );

  // Palette command: attach to the running app of the current workspace.
  context.subscriptions.push(
    vscode.commands.registerCommand("tesl.attachRunning", () => {
      if (!requireTrustedWorkspace()) return;
      const folder = vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders[0];
      vscode.debug.startDebugging(folder, {
        type: "tesl",
        request: "attach",
        name: "Attach to running app (tesl run --debug)",
      });
    })
  );
}

function deactivate() {
  if (client) {
    return client.stop();
  }
}

module.exports = { activate, deactivate };
