const { LanguageClient, TransportKind } = require("vscode-languageclient/node");
const path = require("path");
const fs = require("fs");
const os = require("os");
const { spawnSync } = require("child_process");
const vscode = require("vscode");

let client;

/**
 * Check whether a command exists on PATH.
 * Uses `which` (Unix/macOS) or `where` (Windows).
 */
function commandOnPath(name) {
  const cmd = process.platform === "win32" ? "where" : "which";
  return spawnSync(cmd, [name], { encoding: "utf8" }).status === 0;
}

/**
 * Resolve how to launch the Tesl LSP.
 *
 * Returns one of:
 *   { kind: "binary", command: "tesl-lsp" }
 *     — use the installed tesl-lsp wrapper directly (nix profile install)
 *   { kind: "script", script: "/abs/path/tesl-lsp.rkt" }
 *     — launch via `racket <script>` (repo / dev layout)
 *   null — could not find either
 *
 * Priority:
 *   1. tesl.lspScript setting  (explicit path override → script mode)
 *   2. tesl-lsp binary in PATH (installed via nix profile install)
 *   3. editor/tesl-lsp/tesl-lsp.rkt relative to workspace root
 *   4. tesl-lsp/tesl-lsp.rkt  relative to extension dir  (dev layout)
 *   5. ../../editor/tesl-lsp/tesl-lsp.rkt                (repo layout)
 */
function resolveLsp(extensionDir) {
  // 1. Explicit user override
  const override = vscode.workspace.getConfiguration("tesl").get("lspScript");
  if (override && fs.existsSync(override)) {
    return { kind: "script", script: override };
  }

  // 2. Installed tesl-lsp binary — check PATH first, then common nix dirs
  // (VSCodium launched from the desktop does not inherit the nix profile PATH)
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

  // 3–5. Racket script in repo / dev layouts
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

function activate(context) {
  const lsp = resolveLsp(context.extensionPath);

  if (!lsp) {
    vscode.window.showWarningMessage(
      "Tesl: could not find tesl-lsp. " +
      "Install Tesl (nix profile install github:mtonnberg/tesl) or set " +
      "tesl.lspScript to the absolute path of tesl-lsp.rkt."
    );
    return;
  }

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
    const wsPath = (vscode.workspace.workspaceFolders || [])[0]?.uri?.fsPath ?? "";
    serverOptions = {
      command: "racket",
      args: [lsp.script],
      transport: TransportKind.stdio,
      options: {
        env: {
          ...process.env,
          TESL_REPO_ROOT: wsPath,
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

  client = new LanguageClient(
    "tesl-lsp",
    "Tesl Language Server",
    serverOptions,
    clientOptions,
  );

  client.start().catch((err) => {
    outputChannel.appendLine(`[tesl-lsp] failed to start: ${err}`);
    vscode.window.showErrorMessage(`Tesl LSP failed to start: ${err}`);
  });
}

function deactivate() {
  if (client) {
    return client.stop();
  }
}

module.exports = { activate, deactivate };
