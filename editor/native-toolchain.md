# Native toolchain implementation notes

This is a development implementation, not a published installation channel.
The active delivery gates are in the three roadmaps under `roadmap/next/`.

## Run the native CLI from a checkout

Build the OCaml compiler with `cd compiler && dune build bin/main.exe`, then,
from the repository root:

```sh
export TESL_REPO_ROOT="$PWD"
cd runtime/go
go build -o ../../.tesl-stuff/native-tools/ ./cmd/...
cd ../..
.tesl-stuff/native-tools/tesl doctor --json
```

Use the pinned repository Go toolchain. `doctor` reports missing components; it
does not download them. `TESL_POSTGRES_BIN` may select a PostgreSQL `bin` directory.
The native CLI is also available through `go run ./cmd/tesl` in `runtime/go`;
its `-C <directory>` option selects the project working directory.

The default Nix CLI remains the existing wrapper until the full parity gate
passes. A successful compiler/Go cross-build does not establish platform support.

## Installation manifest

All native executables locate `share/tesl/toolchain.json` relative to their real
installation prefix, including through a symlinked launcher. The extension uses
the selected `tesl` on PATH, an explicit `tesl.toolchainRoot` setting, or its
documented per-user installation location. A minimal schema example is:

```json
{
  "version": 1,
  "toolchain_version": "0.3.1",
  "source_revision": "FULL_SOURCE_COMMIT_SHA",
  "target": "linux-amd64",
  "components": {
    "compiler": {"path": "libexec/tesl/tesl-compiler", "version": "0.3.1"},
    "go": {"path": "libexec/tesl/go/bin/go", "version": "1.26.6"},
    "go-modules": {"path": "share/tesl/go-modules", "version": "0.3.1"}
  }
}
```

This example is deliberately incomplete as an installation. Complete manifests
must include the six frontend binaries, templates, PostgreSQL tools, and all
resources declared by the release plan. Windows paths use forward slashes in
JSON and executable components include `.exe`.

Precedence is explicit tool override, explicit `TESL_TOOLCHAIN_ROOT`, adjacent
installation manifest, legacy Nix siblings, explicit development checkout, then
PATH. A selected installation with missing or invalid components fails instead
of silently combining incompatible installations. Optional external tools such
as Docker, Git, and scanners may be resolved separately.

Components use relative paths with no traversal, drive prefixes, backslashes,
empty path segments, or NULs. The manifest is versioned and bounded to 1 MiB.
Go builds use the selected GOROOT, `GOTOOLCHAIN=local`, a local file module proxy,
and writable user caches. Missing bundled modules fail offline.

## Behavioral verification

| Area | Regression coverage |
|---|---|
| Discovery | Relocated prefixes, spaces/Unicode, symlinks, explicit overrides, incomplete installations, mixed-toolchain refusal, offline Go environment |
| CLI | Compiler argument forwarding, scaffold preservation, manifest entrypoints, literal dotenv/argv, clean boundaries, previous-build recovery, watched dependency edits |
| Runtime lifecycle | Child descendants stop on cancellation and parent exit; compiler output is drained completely even when descendants inherit its pipes |
| Database | Start/stop/status, version mismatch, port collision, persistent port, existing database fallback, real data preserved across restart and clean |
| Completion | Public functions/types, project types, recovery, comment-preserving imports, duplicate/shadow handling, CRLF/UTF-16, stale overlays, accepted edits checked by the compiler |
| Windows | Drive/UNC URI cases and cross-compilation run on Linux; Job Object behavior and token ACLs have native tests awaiting a Windows runner |

Run `go test -race ./internal/... ./cmd/tesl-mcp ./teslrt` in `runtime/go`.
Tests using the actual compiler require its build to exist. The real PostgreSQL
test requires native PostgreSQL tools. Run the compiler suites with `dune test`
and the extension suite with `npm test` in the repository development environment.
The authoritative release gate remains `./ci.sh`.

`nix build .#release-plan` exports exact inputs and candidate targets.
`.github/workflows/native-parity.yml` consumes this plan and records native
source-build evidence. It does not assemble offline payloads, sign installers,
publish releases, or establish a minimum supported OS version.
