const { LanguageClient, TransportKind } = require("vscode-languageclient/node");
const path = require("path");
const fs = require("fs");
const os = require("os");
const { spawnSync } = require("child_process");
const vscode = require("vscode");

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
  // Regex that matches 'test "name"' at any indentation level.
  const TEST_RE = /^\s*test\s+"([^"]+)"/;
  // A doctest example line: '#> <expr>'. The runnable unit is the whole doctest
  // block for the fn that follows; the compiler names that test "doctest: <fn>"
  // (see parser.ml extract_doctest_decls). We surface a lens on the FIRST '#>'
  // line of each block and resolve the fn name from the next 'fn <name>' line.
  const DOCTEST_RE = /^\s*#>\s*\S/;
  const FN_RE = /^\s*fn\s+([A-Za-z_][A-Za-z0-9_]*)/;

  // Returns { tests: [{name, line}], doctests: [{fnName, line}], hasAny }.
  function discoverTests(text) {
    const lines = text.split("\n");
    const tests = [];
    const doctests = [];
    for (let i = 0; i < lines.length; i++) {
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
    return { tests, doctests, hasAny: tests.length > 0 || doctests.length > 0 };
  }

  // ── CodeLens: per-test run/debug + per-doctest run + run-all-in-file ───────────
  const lensProvider = {
    provideCodeLenses(document) {
      if (!document.fileName.endsWith(".tesl")) return [];
      const file = document.uri.fsPath;
      const { tests, doctests, hasAny } = discoverTests(document.getText());
      const lenses = [];

      // File-level "run all tests" lens at the first test/doctest block.
      if (hasAny) {
        const firstLine = Math.min(
          ...[...tests, ...doctests].map((t) => t.line)
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
          arguments: [file, t.name],
        }));
        lenses.push(new vscode.CodeLens(range, {
          title: "🐛 Debug test",
          command: "tesl.debugSingleTest",
          arguments: [file, t.name],
        }));
      }

      for (const d of doctests) {
        const range = new vscode.Range(d.line, 0, d.line, 0);
        // Doctests compile to a test named exactly "doctest: <fnName>".
        const testName = `doctest: ${d.fnName}`;
        lenses.push(new vscode.CodeLens(range, {
          title: "▶ Run doctest",
          command: "tesl.runSingleTest",
          arguments: [file, testName],
        }));
      }

      return lenses;
    },
  };
  context.subscriptions.push(
    vscode.languages.registerCodeLensProvider({ language: "tesl" }, lensProvider)
  );

  // "Run test" — compile only the named test, then run with raco test.
  // Uses the compiler directly so this works regardless of which version
  // of the tesl shell script is installed (the --test-name flag may not
  // be present in older nix-installed wrappers).
  // Shared helper: compile a single named test (or doctest) to a temp .rkt and
  // run it with `raco test`, in a freshly-created terminal. Returns the terminal.
  // Shelling directly to the compiler keeps this independent of the installed
  // `tesl` shell wrapper's flag support.
  function runNamedTestInTerminal(file, testName, terminalName) {
    const compiler = findTeslCompiler(wsPath);
    const racketBin = findRacketBinary();
    const raco = racketBin ? path.join(path.dirname(racketBin), "raco") : "raco";
    const terminal = vscode.window.createTerminal({ name: terminalName || `Tesl: ${testName}` });
    terminal.show(true);
    if (compiler) {
      const tmp = `/tmp/tesl-test-${Date.now()}.rkt`;
      terminal.sendText(
        `"${compiler}" --test-name "${testName}" "${file}" > "${tmp}" && "${raco}" test "${tmp}"; rm -f "${tmp}"`
      );
    } else {
      // Fallback: requires a recent enough tesl script
      terminal.sendText(`tesl test --test-name "${testName}" "${file}"`);
    }
    return terminal;
  }

  context.subscriptions.push(
    vscode.commands.registerCommand("tesl.runSingleTest", (file, testName) => {
      runNamedTestInTerminal(file, testName);
    })
  );

  // "Debug test" — compile only the named test, then start a debug session.
  context.subscriptions.push(
    vscode.commands.registerCommand("tesl.debugSingleTest", (file, testName) => {
      const folder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(file));
      vscode.debug.startDebugging(folder, {
        type: "tesl", request: "launch",
        name: `Debug: ${testName}`,
        program: file,
        mode: "test",
        testName,          // passed as args.testName → DAP server → --test-name flag
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
  // Enumerate test blocks + doctests per .tesl file and wire run + debug through
  // the same compiler/DAP paths the code lenses use. Test IDs encode the compiler
  // test name so the run handler can target an individual test via --test-name.
  if (vscode.tests && typeof vscode.tests.createTestController === "function") {
    const ctrl = vscode.tests.createTestController("tesl", "Tesl Tests");
    context.subscriptions.push(ctrl);

    // ID helpers: "<fsPath>::test::<name>" / "<fsPath>::doctest::<fnName>".
    function refreshFile(document) {
      if (!document.fileName.endsWith(".tesl")) return;
      const uri = document.uri;
      const { tests, doctests, hasAny } = discoverTests(document.getText());
      if (!hasAny) { ctrl.items.delete(uri.toString()); return; }

      let fileItem = ctrl.items.get(uri.toString());
      if (!fileItem) {
        fileItem = ctrl.createTestItem(uri.toString(), path.basename(uri.fsPath), uri);
        ctrl.items.add(fileItem);
      }
      fileItem.children.replace([]);

      for (const t of tests) {
        const id = `${uri.fsPath}::test::${t.name}`;
        const item = ctrl.createTestItem(id, t.name, uri);
        item.range = new vscode.Range(t.line, 0, t.line, 0);
        fileItem.children.add(item);
      }
      for (const d of doctests) {
        const id = `${uri.fsPath}::doctest::${d.fnName}`;
        const item = ctrl.createTestItem(id, `doctest: ${d.fnName}`, uri);
        item.range = new vscode.Range(d.line, 0, d.line, 0);
        fileItem.children.add(item);
      }
    }

    // Map a TestItem back to (file, compilerTestName) for --test-name targeting.
    function targetOf(item) {
      const id = item.id;
      let m = /^(.*)::test::(.*)$/.exec(id);
      if (m) return { file: m[1], testName: m[2] };
      m = /^(.*)::doctest::(.*)$/.exec(id);
      if (m) return { file: m[1], testName: `doctest: ${m[2]}` };
      return null; // file-level node
    }

    // Collect the leaf TestItems implied by a run request.
    function collectLeaves(request) {
      const leaves = [];
      const visit = (item) => {
        if (item.children.size > 0) item.children.forEach(visit);
        else leaves.push(item);
      };
      if (request.include && request.include.length) request.include.forEach(visit);
      else ctrl.items.forEach(visit);
      const excluded = new Set((request.exclude || []).map((i) => i.id));
      return leaves.filter((i) => !excluded.has(i.id));
    }

    // Run profile: shell each selected test through the compiler + raco test.
    ctrl.createRunProfile("Run", vscode.TestRunProfileKind.Run, (request) => {
      const run = ctrl.createTestRun(request);
      for (const item of collectLeaves(request)) {
        const tgt = targetOf(item);
        if (!tgt) continue;
        run.started(item);
        runNamedTestInTerminal(tgt.file, tgt.testName, `Tesl: ${item.label}`);
        // Terminal-based execution: we can't observe pass/fail programmatically
        // without parsing raco output, so we mark the item enqueued/skipped to
        // avoid reporting a false pass. The terminal shows the authoritative result.
        run.skipped(item);
      }
      run.end();
    }, false);

    // Debug profile: launch the DAP session per selected test (test mode).
    ctrl.createRunProfile("Debug", vscode.TestRunProfileKind.Debug, (request) => {
      const run = ctrl.createTestRun(request);
      for (const item of collectLeaves(request)) {
        const tgt = targetOf(item);
        if (!tgt) continue;
        run.started(item);
        const folder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(tgt.file));
        vscode.debug.startDebugging(folder, {
          type: "tesl", request: "launch",
          name: `Debug: ${item.label}`,
          program: tgt.file, mode: "test", testName: tgt.testName,
        });
        run.skipped(item);
      }
      run.end();
    }, false);

    // Keep the tree fresh as files open/change.
    const refreshOpen = () => vscode.workspace.textDocuments.forEach(refreshFile);
    refreshOpen();
    context.subscriptions.push(
      vscode.workspace.onDidOpenTextDocument(refreshFile),
      vscode.workspace.onDidChangeTextDocument((e) => refreshFile(e.document)),
      vscode.workspace.onDidCloseTextDocument((doc) => {
        if (doc.fileName.endsWith(".tesl")) ctrl.items.delete(doc.uri.toString());
      })
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
