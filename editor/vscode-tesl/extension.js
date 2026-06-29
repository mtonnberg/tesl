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

/**
 * Resolve how to launch the Tesl LSP.
 */
function resolveLsp(extensionDir) {
  const override = vscode.workspace.getConfiguration("tesl").get("lspScript");
  if (override && fs.existsSync(override)) {
    return { kind: "script", script: override };
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

  const candidates = [];
  const folders = vscode.workspace.workspaceFolders;
  if (folders && folders.length > 0) {
    candidates.push(path.join(folders[0].uri.fsPath, "editor", "tesl-lsp", "tesl-lsp.rkt"));
  }
  candidates.push(path.join(extensionDir, "..", "tesl-lsp", "tesl-lsp.rkt"));
  candidates.push(path.join(extensionDir, "..", "..", "editor", "tesl-lsp", "tesl-lsp.rkt"));

  for (const c of candidates) {
    if (fs.existsSync(c)) return { kind: "script", script: c };
  }

  return null;
}

/**
 * Read the tesl-lsp nix wrapper to extract the correct Racket binary and PLTCOLLECTS.
 * The wrapper knows exactly which Racket version the tesl package was built with.
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
      // Extract PLTCOLLECTS — strip shell variable syntax (${PLTCOLLECTS:+:$PLTCOLLECTS})
      // so Racket gets clean colon-separated paths, not shell substitution syntax.
      const pltMatch = content.match(/export PLTCOLLECTS="([^"]+)"/);
      const rawPlt = pltMatch ? pltMatch[1] : null;
      const pltcollects = rawPlt
        ? rawPlt.split("${")[0].replace(/:$/, "").trim()  // strip ${...} and trailing :
        : null;
      // Extract the Racket nix store bin directory — flexible regex handles PATH= format.
      const racketBinDirMatch = content.match(/(\/nix\/store\/[^:\s"']*-racket[^:\s"']*\/bin)/);
      return {
        racketBin: racketBinDirMatch ? racketBinDirMatch[1] + "/racket" : null,
        pltcollects,
      };
    } catch (_) {}
  }
  return null;
}

/**
 * Find the Racket binary — prefer the one from the tesl-lsp wrapper (correct version).
 */
function findRacketBinary() {
  if (process.env.TESL_RACKET_PATH && fs.existsSync(process.env.TESL_RACKET_PATH)) {
    return process.env.TESL_RACKET_PATH;
  }
  // Read the tesl-lsp wrapper to get the correct Racket for the tesl package
  const wrapper = readTeslLspWrapper();
  if (wrapper && wrapper.racketBin && fs.existsSync(wrapper.racketBin)) {
    return wrapper.racketBin;
  }
  // Fallbacks
  const nixPaths = [
    path.join(os.homedir(), ".nix-profile", "bin", "racket"),
    "/nix/var/nix/profiles/default/bin/racket",
    "/run/current-system/sw/bin/racket",
  ];
  for (const p of nixPaths) {
    if (fs.existsSync(p)) return p;
  }
  const r = spawnSync("which", ["racket"], { encoding: "utf8" });
  if (r.status === 0) return r.stdout.trim();
  return null;
}

/**
 * Find the Tesl compiler binary.
 * Prefer the locally compiled binary (supports --debug) over the nix wrapper.
 */
function findTeslCompiler(wsPath) {
  // 1. Locally compiled binary in the workspace repo
  if (wsPath) {
    const local = path.join(wsPath, "compiler", "_build", "default", "bin", "main.exe");
    if (fs.existsSync(local)) return local;
  }

  // 2. TESL_COMPILER env var
  if (process.env.TESL_COMPILER && fs.existsSync(process.env.TESL_COMPILER)) {
    return process.env.TESL_COMPILER;
  }

  // 3. nix profile / PATH
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

/**
 * Find the dap-server.rkt file.
 * Search order: workspace repo → nix profile → extension dir (if bundled).
 */
function findDapServer(wsPath, extensionDir) {
  const candidates = [];

  if (wsPath) {
    candidates.push(path.join(wsPath, "dsl", "debug", "dap-server.rkt"));
  }

  // Derive from the tesl-lsp wrapper's baked PLTCOLLECTS. This is the reliable
  // path for a flake-installed binary: the wrapper references the exact
  // /nix/store/…-tesl-racket-collections/share/tesl-collections store path that
  // ships dap-server.rkt — even though `nix profile install` does NOT mirror
  // that derivation into ~/.nix-profile/share/ (the source of the user's
  // "dap-server: NOT FOUND"). Each PLTCOLLECTS entry is a collections root
  // holding tesl/{dsl,tesl,lang}.
  const wrapper = readTeslLspWrapper();
  if (wrapper && wrapper.pltcollects) {
    for (const entry of wrapper.pltcollects.split(":")) {
      if (!entry) continue;
      candidates.push(path.join(entry, "tesl", "dsl", "debug", "dap-server.rkt"));
    }
  }

  candidates.push(
    path.join(os.homedir(), ".nix-profile", "share", "tesl-collections", "tesl", "dsl", "debug", "dap-server.rkt"),
    "/nix/var/nix/profiles/default/share/tesl-collections/tesl/dsl/debug/dap-server.rkt",
    // Check if bundled inside the extension itself
    path.join(extensionDir, "dsl", "debug", "dap-server.rkt"),
  );

  return candidates.find((p) => fs.existsSync(p)) || null;
}

/**
 * Build PLTCOLLECTS for launching dap-server.rkt.
 *
 * For nix installs: use the PLTCOLLECTS from the tesl-lsp wrapper (already
 * contains both the Racket stdlib AND the tesl-collections from nix store).
 *
 * For dev/repo layout: create .tesl-collections/ symlinks and prepend the
 * Racket stdlib path (derived from the Racket binary location).
 */
function buildPltcollects(wsPath, racketBin) {
  // Build dev .tesl-collections symlinks (needed for dsl/debug/ which is not in nix release)
  const collDir = wsPath ? path.join(wsPath, ".tesl-collections") : null;
  if (collDir) {
    const teslColl = path.join(collDir, "tesl");
    try {
      if (!fs.existsSync(teslColl)) fs.mkdirSync(teslColl, { recursive: true });
      for (const sub of ["dsl", "tesl", "lang"]) {
        const link = path.join(teslColl, sub);
        const target = path.join(wsPath, sub);
        if (!fs.existsSync(link) && fs.existsSync(target)) fs.symlinkSync(target, link);
      }
    } catch (_) {}
  }

  // For nix install: nix wrapper has the pre-compiled runtime collections.
  // Append dev .tesl-collections AFTER nix so nix's compiled .zo files win for
  // the main runtime, but dsl/debug/ (only in dev repo) is still found.
  const wrapper = readTeslLspWrapper();
  if (wrapper && wrapper.pltcollects) {
    return collDir
      ? wrapper.pltcollects + ":" + collDir
      : wrapper.pltcollects;
  }

  // Dev/repo layout without nix: use dev collection + Racket stdlib
  if (!collDir) return null;
  if (racketBin) {
    const racketPrefix = path.dirname(path.dirname(racketBin));
    const racketCollects = path.join(racketPrefix, "share", "racket", "collects");
    if (fs.existsSync(racketCollects)) return collDir + ":" + racketCollects;
  }
  return collDir;
}

function activate(context) {
  const wsPath = (vscode.workspace.workspaceFolders || [])[0]?.uri?.fsPath ?? "";

  // ── LSP ──────────────────────────────────────────────────────────────────────
  const lsp = resolveLsp(context.extensionPath);

  if (!lsp) {
    vscode.window.showWarningMessage(
      "Tesl: could not find tesl-lsp. " +
      "Install Tesl (nix profile install github:mtonnberg/tesl) or set " +
      "tesl.lspScript to the absolute path of tesl-lsp.rkt."
    );
  } else {
    const outputChannel = vscode.window.createOutputChannel("Tesl Language Server");
    let serverOptions;
    if (lsp.kind === "binary") {
      outputChannel.appendLine(`[tesl-lsp] using binary: ${lsp.command}`);
      serverOptions = {
        command: lsp.command,
        args: [],
        transport: TransportKind.stdio,
        options: { env: { ...process.env } },
      };
    } else {
      outputChannel.appendLine(`[tesl-lsp] using script: ${lsp.script}`);
      serverOptions = {
        command: "racket",
        args: [lsp.script],
        transport: TransportKind.stdio,
        options: {
          env: { ...process.env, TESL_REPO_ROOT: wsPath },
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
      if (!document.fileName.endsWith(".tesl")) return [];
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
  // IMPORTANT: do NOT emit a .rkt and run bare `raco test` on it. The emitted
  // test module does `(require tesl/dsl/...)`, and those collections are only on
  // PLTCOLLECTS when the `tesl` *wrapper* runs raco — a direct `raco test` fails
  // with "collection not found: tesl/dsl/capability". `tesl test --test-name`
  // sets PLTCOLLECTS and also reformats rackunit output to the .tesl test name +
  // source line. Resolve the wrapper (NOT the raw compiler, which has no `test`
  // verb): prefer `tesl` on PATH (dev shell or nix profile), then nix profile.
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
  function runNamedTestInTerminal(file, testName, terminalName, kind) {
    const tesl = findTeslWrapper();
    const terminal = vscode.window.createTerminal({ name: terminalName || `Tesl: ${testName}` });
    terminal.show(true);
    // `--test-kind` disambiguates same-named blocks of different kinds and is what
    // lets a single api-test/load-test/doctest run in isolation.
    const kindArg = kind ? ` --test-kind ${kind}` : "";
    terminal.sendText(`"${tesl}" test --test-name "${testName}"${kindArg} "${file}"`);
    return terminal;
  }

  context.subscriptions.push(
    vscode.commands.registerCommand("tesl.runSingleTest", (file, testName, kind) => {
      runNamedTestInTerminal(file, testName, undefined, kind);
    })
  );

  // "Debug test" — compile only the named test, then start a debug session.
  context.subscriptions.push(
    vscode.commands.registerCommand("tesl.debugSingleTest", (file, testName, kind) => {
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
    vscode.commands.registerCommand("tesl.debugTests", (uri) => {
      const file = teslFileFrom(uri);
      if (!file) { vscode.window.showErrorMessage("No Tesl file selected."); return; }
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
    vscode.commands.registerCommand("tesl.runTests", (uri) => {
      const file = teslFileFrom(uri);
      if (!file) { vscode.window.showErrorMessage("No Tesl file selected."); return; }
      const terminal = vscode.window.createTerminal({ name: "Tesl Tests" });
      terminal.show(true);
      terminal.sendText(`tesl test "${file}"`);
    })
  );

  // ── REPL-like "Run Function with Input" ───────────────────────────────────────
  // Prompt for a function call (seeded from the identifier under the cursor) plus
  // an expected value, then append a synthetic `test` block to a temp copy of the
  // file and run it through the same compiler + raco path the test lenses use.
  // Tesl has no user-facing print primitive, so the test harness IS the REPL: on a
  // mismatch the harness prints the actual value (the function's result); on match
  // it prints PASS. This shells directly to the compiler/runtime we discover and
  // does NOT depend on the LSP.
  context.subscriptions.push(
    vscode.commands.registerCommand("tesl.runFunctionWithInput", async (uri) => {
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

      const compiler = findTeslCompiler(wsPath);
      if (!compiler) {
        vscode.window.showErrorMessage(
          "Run Function: Tesl compiler not found. Build compiler/_build or install via nix."
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
        vscode.window.showErrorMessage(`Run Function: could not prepare driver: ${e}`);
        return;
      }

      const racketBin = findRacketBinary();
      const raco = racketBin ? path.join(path.dirname(racketBin), "raco") : "raco";
      const tmpRkt = path.join(tmpDir, "run.rkt");
      const terminal = vscode.window.createTerminal({ name: `Tesl: ${expr}` });
      terminal.show(true);
      // Compile only the synthetic test, run it, then remove the temp dir.
      terminal.sendText(
        `"${compiler}" --test-name "${testName}" "${driver}" > "${tmpRkt}" && "${raco}" test "${tmpRkt}"; rm -rf "${tmpDir}"`
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
    const TESL_EXCLUDE = "**/{node_modules,.git,_build,result,.tesl-postgres}/**";

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
    function runTeslTestFile(file, token) {
      return new Promise((resolve) => {
        const tesl = findTeslWrapper();
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
        let child;
        try {
          child = spawn(tesl, ["test", file], { cwd: path.dirname(file) });
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

    // Run profile (default): execute selected tests, report real pass/fail/error.
    // Selected leaves are grouped by file and each file is run ONCE (rackunit prints
    // only failures; passes are inferred from "discovered ∧ not failed ∧ compiled").
    const runHandler = async (request, token) => {
      const run = ctrl.createTestRun(request);
      try {
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
          for (const { item, tgt } of entries) {
            if (token.isCancellationRequested) { run.skipped(item); continue; }
            if (compileError) {
              run.errored(item, new vscode.TestMessage(compileError), per);
              continue;
            }
            const f = failures.get(tgt.testName);
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
    ctrl.createRunProfile("Run", vscode.TestRunProfileKind.Run, runHandler, true);

    // Debug profile: launch the DAP session per selected test (test mode). The DAP
    // session does not report pass/fail back to the TestRun (the debugger UI is the
    // feedback channel), so we await each launch and only flag a launch FAILURE on the
    // item — we never mark a started item skipped (an illegal state transition).
    // Load-tests are throughput benchmarks, not steppable, so they are skipped here.
    ctrl.createRunProfile("Debug", vscode.TestRunProfileKind.Debug, async (request, token) => {
      const run = ctrl.createTestRun(request);
      try {
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
  // Use a DebugAdapterDescriptorFactory to launch launch-dap.sh with the right
  // environment variables — TESL_REPO_ROOT and TESL_COMPILER are set from the
  // workspace, so the script doesn't need to guess paths.
  context.subscriptions.push(
    vscode.debug.registerDebugAdapterDescriptorFactory("tesl", {
      createDebugAdapterDescriptor(session) {
        const launchScript = path.join(context.extensionPath, "debug", "launch-dap.sh");

        if (!fs.existsSync(launchScript)) {
          vscode.window.showErrorMessage(
            `Tesl debugger: launch-dap.sh not found at ${launchScript}. Reinstall the extension.`
          );
          return null;
        }

        const racketBin = findRacketBinary();
        const compiler = findTeslCompiler(wsPath);
        const dapServer = findDapServer(wsPath, context.extensionPath);
        const pltcollects = buildPltcollects(wsPath, racketBin);

        // Build env for the shell script
        const env = {
          ...process.env,
          ...(wsPath ? { TESL_REPO_ROOT: wsPath } : {}),
          ...(compiler ? { TESL_COMPILER: compiler } : {}),
          ...(dapServer ? { TESL_DAP_SERVER: dapServer } : {}),
          ...(pltcollects ? { PLTCOLLECTS: pltcollects + (process.env.PLTCOLLECTS ? ":" + process.env.PLTCOLLECTS : "") } : {}),
        };

        // Log to the output channel for diagnostics
        const dbgOut = vscode.window.createOutputChannel("Tesl Debugger");
        dbgOut.appendLine(`[tesl-debug] racket:        ${racketBin || "NOT FOUND"}`);
        dbgOut.appendLine(`[tesl-debug] dap-server:    ${dapServer || "NOT FOUND"}`);
        dbgOut.appendLine(`[tesl-debug] compiler:      ${compiler || "NOT FOUND"}`);
        dbgOut.appendLine(`[tesl-debug] PLTCOLLECTS:   ${env.PLTCOLLECTS || "(not set)"}`);
        dbgOut.appendLine(`[tesl-debug] TESL_REPO_ROOT:${wsPath || "(not set)"}`);
        dbgOut.show(true);

        if (!racketBin) {
          vscode.window.showErrorMessage(
            "Tesl debugger: racket binary not found. Install via nix or set TESL_RACKET_PATH."
          );
          return null;
        }

        if (!dapServer) {
          vscode.window.showErrorMessage(
            "Tesl debugger: dap-server.rkt not found. Ensure workspace is the tesl repo or install via nix."
          );
          return null;
        }

        // Spawn Racket directly — no bash wrapper needed since extension.js
        // already resolved all paths and env vars.
        return new vscode.DebugAdapterExecutable(racketBin, [dapServer], { env });
      },
    })
  );
}

function deactivate() {
  if (client) {
    return client.stop();
  }
}

module.exports = { activate, deactivate };
