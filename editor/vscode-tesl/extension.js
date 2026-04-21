const { LanguageClient, TransportKind } = require("vscode-languageclient/node");
const path = require("path");
const fs = require("fs");
const vscode = require("vscode");

let client;

/**
 * Find the tesl-lsp.rkt Racket LSP server script.
 *
 * Priority:
 *   1. tesl.lspScript setting (explicit override)
 *   2. editor/tesl-lsp/tesl-lsp.rkt relative to the workspace root
 *   3. Same path relative to the extension directory (dev layout)
 */
function findLspScript(extensionDir) {
  const cfg = vscode.workspace.getConfiguration("tesl");
  const override = cfg.get("lspScript");
  if (override && fs.existsSync(override)) return override;

  const folders = vscode.workspace.workspaceFolders;
  if (folders && folders.length > 0) {
    const wsRoot = folders[0].uri.fsPath;
    const candidate = path.join(wsRoot, "editor", "tesl-lsp", "tesl-lsp.rkt");
    if (fs.existsSync(candidate)) return candidate;
  }

  const devCandidate = path.join(extensionDir, "..", "tesl-lsp", "tesl-lsp.rkt");
  if (fs.existsSync(devCandidate)) return devCandidate;

  const repoCandidate = path.join(extensionDir, "..", "..", "editor", "tesl-lsp", "tesl-lsp.rkt");
  if (fs.existsSync(repoCandidate)) return repoCandidate;

  return null;
}

function activate(context) {
  const lspScript = findLspScript(context.extensionPath);

  if (!lspScript) {
    vscode.window.showWarningMessage(
      "Tesl: could not find tesl-lsp.rkt. " +
      "Open the Tesl repository as a workspace, or set tesl.lspScript in settings."
    );
    return;
  }

  const outputChannel = vscode.window.createOutputChannel("Tesl Language Server");
  outputChannel.appendLine(`[tesl-lsp] script: ${lspScript}`);

  const serverOptions = {
    command: "racket",
    args: [lspScript],
    transport: TransportKind.stdio,
    options: {
      env: {
        ...process.env,
        TESL_REPO_ROOT: (vscode.workspace.workspaceFolders || [{}])[0]?.uri?.fsPath ?? "",
      },
    },
  };

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
