#!/usr/bin/env python3
"""Exercise native source builds using versions exported by the Nix release plan.

This is the native build spike/parity gate, not a distributable payload builder.
Build-only opam/C tools on these runners are not runtime installation requirements.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess


def run(arguments, directory, environment, capture=False):
    completed = subprocess.run(arguments, cwd=directory, env=environment,
                               check=True, text=True, capture_output=capture)
    return completed.stdout.strip() if capture else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--target", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    plan = json.loads(args.plan.read_text(encoding="utf-8"))
    if plan.get("version") != 1:
        raise SystemExit("unsupported native release plan")
    if args.target not in {row["target"] for row in plan["candidates"]}:
        raise SystemExit("target absent from Nix release plan")
    environment = dict(os.environ, TESL_REPO_ROOT=str(root), GOTOOLCHAIN="local")
    sha = run(["git", "rev-parse", "HEAD"], root, environment, capture=True)
    if plan["sourceRevision"] != sha:
        raise SystemExit("native checkout does not match the exported source revision")
    host = run(["go", "env", "GOOS", "GOARCH"], root, environment, capture=True).splitlines()
    if "-".join(host) != args.target:
        raise SystemExit("native runner does not match its declared target")
    go_version = run(["go", "env", "GOVERSION"], root, environment, capture=True)
    ocaml_version = run(["opam", "exec", "--", "ocamlc", "-version"], root, environment, capture=True)
    if go_version != "go" + plan["sources"]["go"]["version"] or ocaml_version != plan["sources"]["ocaml"]["version"]:
        raise SystemExit("native compiler versions differ from Nix")
    run(["opam", "install", "--yes", "dune." + plan["sources"]["dune"]["version"],
         "alcotest." + plan["testPackages"]["alcotest"]], root, environment)
    binary_dir = root / "artifacts" / ("native-" + args.target) / "bin"
    binary_dir.mkdir(parents=True, exist_ok=True)
    cli = binary_dir / ("tesl.exe" if os.name == "nt" else "tesl")
    run(["go", "build", "-o", str(cli), "./cmd/tesl"], root / "runtime/go", environment)
    environment["TESL_PROCESS_RUNNER"] = str(cli)
    targets = ["bin/main.exe", "test/test_completion.exe", "test/test_import_cache.exe", "test/test_workspace_session.exe", "test/test_process_runner.exe", "test/test_diagnostics.exe", "test/test_stdlib_docs.exe"]
    run(["opam", "exec", "--", "dune", "build", *targets], root / "compiler", environment)
    for target in targets[1:]:
        run(["opam", "exec", "--", "dune", "exec", target], root / "compiler", environment)
    run(["go", "build", "./cmd/..."], root / "runtime/go", environment)
    run(["go", "test", "-race", "./internal/childprocess", "./internal/toolchain",
         "./internal/protocol", "./internal/cli"], root / "runtime/go", environment)
    run(["go", "test", "./internal/lsp", "-run", "TestBuiltCompiler"], root / "runtime/go", environment)
    run(["go", "test", "-race", "./internal/tooling", "-run", "TestCompilerPipesDrainAndCloseWithDescendants|Workspace"], root / "runtime/go", environment)
    if args.target.startswith("windows-"):
        run(["go", "test", "./teslrt", "-run", "TestWindowsDebugToken"], root / "runtime/go", environment)
    run(["node", "--test", "toolchain.test.js", "test-output-parser.test.js"], root / "editor/vscode-tesl", environment)
    evidence = root / "artifacts" / ("native-" + args.target)
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / "checks.json").write_text(json.dumps({
        "version": 1, "source_revision": sha, "target": args.target,
        "go": go_version, "ocaml": ocaml_version, "native_parity": "passed",
        "offline_install": "not-tested", "signed_distribution": "not-tested",
    }, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
