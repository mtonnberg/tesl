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

from module_proxy import verify as verify_module_bundle


def run(arguments, directory, environment, capture=False):
    completed = subprocess.run(arguments, cwd=directory, env=environment,
                               check=True, text=True, capture_output=capture)
    return completed.stdout.strip() if capture else None


def run_checks(checks, environment):
    """Report every independent suite failure, then fail the overall gate."""
    failures = []
    for name, arguments, directory in checks:
        print(f"Native check: {name}", flush=True)
        try:
            run(arguments, directory, environment)
        except (subprocess.CalledProcessError, OSError) as error:
            print(f"FAILED {name}: {error}", flush=True)
            failures.append(name)
    if failures:
        raise SystemExit("Native portability failed: " + ", ".join(failures))


def verify_generated_snapshots(root, environment):
    """Catch promotion drift immediately, with a bounded byte-level diagnosis."""
    for name in ("compiler/lib/embedded_docs.ml",
                 "compiler/lib/go_runtime/embedded/embedded_go_runtime.ml"):
        expected = subprocess.run(["git", "show", "HEAD:" + name], cwd=root, env=environment,
                                  check=True, capture_output=True, timeout=30).stdout
        actual = (root / name).read_bytes()
        if actual != expected:
            offset = next((index for index, pair in enumerate(zip(expected, actual))
                           if pair[0] != pair[1]), min(len(expected), len(actual)))
            start = max(0, offset - 24)
            raise SystemExit(f"Native generated snapshot changed: {name}; first difference at byte {offset}; "
                             f"committed[{len(expected)}]={expected[start:offset + 48]!r}; "
                             f"generated[{len(actual)}]={actual[start:offset + 48]!r}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--module-bundle", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    plan = json.loads(args.plan.read_text(encoding="utf-8"))
    if plan.get("version") != 1:
        raise SystemExit("unsupported native release plan")
    if args.target not in {row["target"] for row in plan["candidates"]}:
        raise SystemExit("target absent from Nix release plan")
    environment = dict(os.environ, TESL_REPO_ROOT=str(root), GOTOOLCHAIN="local",
                       TESL_RELEASE_PLAN=str(args.plan.resolve()),
                       TESL_TEST_MODULE_BUNDLE=str(args.module_bundle.resolve()))
    sha = run(["git", "rev-parse", "HEAD"], root, environment, capture=True)
    if plan["sourceRevision"] != sha:
        raise SystemExit("native checkout does not match the exported source revision")
    verify_module_bundle(plan, root, args.module_bundle)
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
    version = plan["toolchainVersion"]
    ldflags = (f"-X=tesl.dev/runtime/go/internal/toolchain.buildVersion={version} "
               f"-X=tesl.dev/runtime/go/internal/toolchain.buildRevision={sha}")
    run(["go", "build", "-ldflags", ldflags, "-o", str(cli), "./cmd/tesl"], root / "runtime/go", environment)
    # Test the binary's embedded identity, independent of any runner overrides.
    version_environment = dict(environment, TESL_VERSION="", TESL_TOOLCHAIN_ROOT="")
    reported = run([str(cli), "version"], root, version_environment, capture=True)
    if reported.splitlines()[:1] != ["tesl " + version]:
        raise SystemExit("native CLI does not report the exported toolchain version")
    environment["TESL_PROCESS_RUNNER"] = str(cli)
    targets = ["bin/main.exe", "test/test_embedded_go_runtime_seam.exe", "test/test_completion.exe", "test/test_import_cache.exe", "test/test_workspace_session.exe", "test/test_workspace_index.exe", "test/test_process_runner.exe", "test/test_diagnostics.exe", "test/test_stdlib_docs.exe"]
    # These suites run via `dune exec`, which does not build the runtime deps
    # declared for `dune runtest`. Materialize the shared relevance fixture too.
    run(["opam", "exec", "--", "dune", "build", *targets, "test/search-queries.tsv"],
        root / "compiler", environment)
    verify_generated_snapshots(root, environment)
    checks = [(target, ["opam", "exec", "--", "dune", "exec", target], root / "compiler")
              for target in targets[1:]]
    checks.extend([
        ("Go commands", ["go", "build", "-ldflags", ldflags, "./cmd/..."], root / "runtime/go"),
        ("Go CLI and process ownership", ["go", "test", "-race", "-timeout=20m", "./internal/childprocess",
         "./internal/toolchain", "./internal/protocol", "./internal/cli", "./internal/install", "./cmd/tesl", "./cmd/tesl-install"], root / "runtime/go"),
        ("Go LSP", ["go", "test", "-race", "./internal/lsp"], root / "runtime/go"),
        ("Go compiler sessions", ["go", "test", "-race", "./internal/tooling", "-run",
         "TestCompilerPipesDrainAndCloseWithDescendants|Workspace"], root / "runtime/go"),
    ])
    if args.target.startswith("windows-"):
        checks.append(("Windows debug token", ["go", "test", "./teslrt", "-run",
                       "TestWindowsDebugToken"], root / "runtime/go"))
    checks.append(("Editor", ["node", "--test", "toolchain.test.js", "test-output-parser.test.js"],
                   root / "editor/vscode-tesl"))
    run_checks(checks, environment)
    # `dune exec` can promote the generators again while running the suites.
    # Check the final bytes before switching to the distribution build tools.
    verify_generated_snapshots(root, environment)
    evidence = root / "artifacts" / ("native-" + args.target)
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / "checks.json").write_text(json.dumps({
        "version": 1, "toolchain_version": version, "source_revision": sha, "target": args.target,
        "go": go_version, "ocaml": ocaml_version, "native_parity": "passed",
        "offline_install": "not-tested", "signed_distribution": "not-tested",
        "offline_go_modules": "passed",
    }, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
