# Native Windows support

Status: in progress, 2026-09-05. The native Windows source-build/parity gate passes.
Native Windows is not yet a supported installation; offline distribution remains
unverified.

Implemented so far:
- Shared native CLI and tool discovery, Windows executable suffixes, and
  drive/UNC/escaped file-URI handling.
- [`childprocess`](../../runtime/go/internal/childprocess) assigns new Windows
  processes to kill-on-close Job Objects before resuming them. POSIX uses process
  groups. Goroutines remain the concurrency mechanism on every platform; native
  thread calls only control external process startup during job assignment.
- Authenticated loopback debugger defaults on Windows, protected current-user
  ACLs when token files are created, and the pinned Windows dependency in emitted
  debug projects. ACL tests are Windows-only; generated debug projects have a
  Windows cross-compilation regression test.
- Compiler mutation/build calls no longer use shell command strings. The native
  CLI supplies an internal process owner with Windows Job Objects, deadlines,
  bounded output and native `.exe` names. Standalone Windows compiler invocations
  of these subprocess-producing commands require the CLI owner explicitly.
- Retained compiler sessions use binary-safe pipes and native process ownership;
  their framing, revision and restart tests are included in the native matrix.
- The native matrix includes the complete LSP race suite: active/queued request
  cancellation, discarded late edits, bounded queues and document ordering use
  the same goroutine implementation as Linux/macOS. Installed-resource tests cover
  a compiler prefix containing spaces and Unicode without a development checkout.
- Native extension launch without Bash and a five-target native CI definition
  consuming the Nix-exported source revision and tool versions.
- The matrix now receives one checksum-verified offline Go module bundle and
  exercises copied-SDK scaffold/password/debug builds with empty module caches.
  This new step2 check still needs its native Windows CI result; it does not
  establish compiler DLL or PostgreSQL relocation.
- Shared source verification, payload assembly/inventory, and an installed CLI
  acceptance harness now exist. Distribution remains Linux/macOS-only: the current
  dependency audit rejects Windows explicitly until PE/DLL closure and native
  PostgreSQL packaging are implemented. Windows source parity continues to run.

PR #100's [native Windows job](https://github.com/mtonnberg/tesl/actions/runs/33960309969/job/101291009775)
passed the compiler, CLI/process, LSP, compiler-session, token-ACL, and extension
unit suites. Windows PostgreSQL and scanner parity, complete offline payloads,
signing, installers, and real desktop editor tests remain open. W0 also requires
the packaged workflow and dependency closure; the source-build result is partial
evidence for that gate.

A Windows user should install Tesl, build and run an API, use the managed local
database, and work in VS Code/VSCodium with the same language, proof, testing,
debugging, and agent features as Linux/macOS. The installed workflow must use
native Windows processes without WSL, Bash, MSYS2, Cygwin, or Nix.

## Starting point

| Existing component | Windows gap to resolve |
|---|---|
| OCaml compiler | Native build and process-runner tests pass; inventory and relocate the resulting native runtime dependencies |
| CLI | [`tesl-cli-body.sh`](../../nix/tesl-cli-body.sh) orchestrates Go, database lifecycle, watch, and other commands through Bash/Unix utilities and Nix discovery |
| Go tooling | Job Object ownership and descendant cleanup pass native tests; verify installed end-to-end debugger and agent workflows |
| Debug transport | Authenticated loopback TCP and current-user token ACL tests pass natively; verify the installed desktop workflow |
| Extension | Native launch and installation discovery are implemented in [`extension.js`](../../editor/vscode-tesl/extension.js); legacy Nix compatibility remains, and native desktop scenarios need verification |
| Installation and CI | [`INSTALL.md`](../../INSTALL.md) points Windows users to WSL; native parity CI now passes, but offline payloads and installers do not exist yet |

Reuse the compiler and Go LSP/DAP/MCP/runtime implementations. Port platform
boundaries rather than maintaining a Windows language fork.

## Nix remains the source of truth

Nix's documented supported hosts are Linux and macOS; native Windows release
execution cannot assume Nix is installed. See the
[Nix platform reference](https://nix.dev/manual/nix/2.34/installation/supported-platforms.html).

Use the release definition and export mechanism owned by
[`mainstream_installation.md`](mainstream_installation.md):

1. Nix defines/pins the toolchain sources, patches, target metadata, dependency
   inputs, packaging layout, and native build recipes. Existing Go lock files
   remain consumed inputs with compiler/runtime consistency checks.
2. A Nix-capable CI job exports a versioned build plan for the exact source SHA.
   Include tool URLs/hashes, compiler variant, Dune/Go/PostgreSQL versions,
   required Windows SDK/build tools, and recipe identity.
3. Native Windows runners verify and consume that plan. Any opam repository
   snapshot/package selection must be pinned; do not let a fresh solve silently
   select a different compiler or dependency set.
4. CI regenerates the plan and rejects drift. Native PowerShell/bootstrap code
   performs platform setup and runs the shared recipes; it must not maintain an
   independent list of versions or implement a second Tesl CLI.
5. Publish the build plan and native source-build instructions with the release.
   Source builders may need opam/build tools; users of the installed artifact do
   not. Keep developer dependencies distinct from runtime dependencies.

[OCaml's native Windows documentation](https://ocaml.org/docs/ocaml-on-windows)
provides the starting point for the compiler build. It is not evidence that this
repository's exact pinned toolchain already builds. Evaluate native building
first; cross-compilation is an optimization only after native parity is proven.

## Support contract

- Initial release target: Windows 11 x86-64. W0 freezes minimum tested Windows
  builds and all ABI/runtime requirements. ARM64 is a separately gated follow-up;
  x86-64 emulation does not establish native ARM64 support. Windows Server and
  older Windows releases require an explicit matrix extension.
- Support both PowerShell and Command Prompt, plus desktop-launched VS Code and
  VSCodium. Standard use is per-user and does not require Administrator access.
- Bundle the same standard components as Linux/macOS: native CLI/compiler and
  tooling executables, Go, required generated-program dependencies, PostgreSQL,
  resources, documentation, and licenses. Include necessary redistributable DLLs
  where permitted; no undeclared runtime installer may be required on first run.
- The offline default scaffold, managed database, run/watch/test/mutation,
  compiler JSON/agent queries, LSP, DAP launch/attach, and MCP are parity gates.
  Enumerate every existing CLI command in the shared behavior matrix, including
  generators, database commands, and build-context staging.
- External services and optional integrations follow the shared installation
  contract. Linux-container image builds require an appropriate container engine;
  this does not make WSL a prerequisite for Tesl itself. Specify and test a native
  or external route for each supported DAST scanner rather than silently dropping
  Windows commands. Outstanding parity gaps keep the release in preview.
- Toolchain upgrades and uninstall preserve user projects and database data.
  PostgreSQL major upgrades are explicit operations, not installer side effects.

## Platform work

### Paths, text, and file lifecycle

Use platform path/URI APIs throughout compiler adapters, LSP, DAP, and the
extension. Test drive letters, mixed separators, spaces, non-ASCII usernames,
percent-escaped URIs, CRLF, and non-BMP characters. Convert offsets using the
correct file contents; never trim `file://` or substitute slashes by hand.

Specify canonical file identity without indiscriminately lowercasing paths.
Exercise case-only renames, case-sensitive directories, junctions, and symlinks.
Reject case-colliding module names when the host filesystem cannot distinguish
them, using the same portability diagnostic on other platforms where possible.

Use OS temporary/cache directories and keep installations immutable. Close
handles before replacing/deleting files, account for transient sharing failures,
and bound retries. Test long paths and UNC workspace roots; either support them
or publish precise limits before W0 exits. Never silently resolve a different
module when normalization fails.

### Process, watch, and database lifecycle

Use the shared Go CLI from installation milestone M1. Launch compiler, Go,
PostgreSQL, and debugger processes using argument arrays and explicit environments.
Eliminate shell fragments in compiler mutation execution and editor commands too;
porting only the outer launcher leaves the dependency intact.

Implement bounded graceful shutdown followed by descendant cleanup, using Windows
Job Objects or an equivalent proven process-tree mechanism. Handle Ctrl+C,
compiler cancellation, debugger stop, parent crashes, and watch restarts. Detaching
from an existing server preserves it; terminating an owned launch cleans it up.
Test shutdown under redirected stdio as well as an interactive console.

Managed PostgreSQL uses native binaries, loopback TCP, project-local data, and
explicit lifecycle ownership. Cover initialization, port collisions, stale state,
restart, shutdown, and concurrent projects. Preserve the same startup/auth
contract as other platforms. No dependency on Unix-domain sockets or a system
Windows service.

### Native debugger and editor integration

- Select the existing authenticated loopback TCP debug transport automatically
  on Windows. Preserve breakpoint conditions/hit counts, stepping, values,
  domain/SQL inspection, snapshots, detach/reattach, and rendezvous semantics.
- Protect endpoint/token files with Windows user ACLs; a Unix mode argument alone
  is not proof of equivalent access control. Exercise wrong/missing tokens,
  occupied ports, stale endpoints, and connection loss using the existing protocol.
- Discover `.exe` tools through the shared installation manifest, PATH, and
  explicit overrides. Make desktop launch work after install without shell-init
  scripts, and detect compiler/tooling version mismatches clearly.
- Remove the Bash runtime dependency from debugger launch configuration. Use the
  native debug adapter and safe terminal/task argument handling. Preserve
  Workspace Trust checks and the extension's workspace-side behavior for remote
  sessions; native support must not start a duplicate local server in WSL/remote use.
- Test Test Explorer, run/debug a single test, run-function input, LSP startup,
  DAP launch/attach, and MCP stdio with paths and arguments containing spaces and
  shell metacharacters.

## Delivery plan

W0 starts with the release-plan schema from installation M0 and can prototype
compiler/tooling builds while the shared CLI is being ported. Its complete
packaged run depends on M1's execution path. W1 requires that shared CLI; W3
extends installation M3/M4 after native parity is proven. Linux/macOS releases
do not wait for this work before Windows enters their required target matrix.

### W0 — Prove the native build and freeze the matrix

- [ ] Consume a Nix-exported locked plan on a native Windows runner and build the
  OCaml compiler plus Go CLI/tooling. Audit generators, subprocess calls, DLL
  dependencies, and build-only Unix tools.
- [ ] Run a database-free program, a negative proof fixture, and a compiler JSON
  query with no WSL/Bash/MSYS runtime available to the installed tools.
- [ ] Record the OS/build baseline, path limits, payload size, signing needs,
  and the complete command/feature parity inventory.

Exit: reproducible native build instructions and a runnable packaged prototype.
Failures in the pinned OCaml/Go/PostgreSQL stack are explicit blockers, not a
reason to label WSL execution as native support.

### W1 — Complete CLI and runtime parity

- [ ] Finish the Windows filesystem/process implementations of the shared CLI
  and compiler subprocess paths; land common behavior fixes on all platforms.
- [ ] Bundle/test native Go dependencies and PostgreSQL for offline first run.
- [ ] Exercise native compile, proof rejection, formatting, tests including
  API/load/mutation workflows, watch/restart, generators, and build staging.

Exit: the command matrix passes from PowerShell and Command Prompt on a clean
standard-user account; cancelled work and restarts leave no owned descendants.

### W2 — Complete editor, debugger, and agent parity

- [ ] Implement executable discovery, native DAP launch, TCP endpoint defaults,
  Windows ACLs, and correct path/source mapping.
- [ ] Run real VS Code and VSCodium extension-host scenarios from a desktop
  launch; run MCP and headless debugger scenarios independently of the editor.
- [ ] Reuse the language-tooling fixtures from
  [`gold-standard-lsp.md`](gold-standard-lsp.md) as those features ship. Windows
  support does not depend on completing that roadmap's future enhancements.

Exit: diagnostics/navigation/completion, test execution, a conditional debug stop,
inspection, detach/reattach, and agent queries pass against the same installation.

### W3 — Ship native installation and continuous releases

Distribution decision, 2026-09-05: the initial Windows release is unsigned. A
code-signing subscription/certificate is not feasible for the maintainer now and
does not block this roadmap. Ship a self-contained setup `.exe`, a portable ZIP,
SHA-256 checksums, provenance, and native source-build instructions. Authenticode
signing is a future improvement, not a required account setup for this release.

- [ ] Produce a portable ZIP and unsigned self-contained per-user setup `.exe` from the common
  payload/manifest. Support exact-version selection, install/upgrade/rollback,
  PATH integration, and uninstall while preserving user data.
- [ ] Add generated WinGet metadata for promoted releases, following
  [Microsoft's package-submission guidance](https://learn.microsoft.com/en-us/windows/package-manager/package/).
  Registry review/availability is separate from publishing every successful
  `main` release; the direct download remains usable independently.
- [ ] Test final downloaded artifacts with normal Windows security settings;
  document the unknown-publisher/reputation prompts and checksum verification.
  Checksums verify bytes, not publisher identity. Source builds remain available
  when local policy prevents running unsigned downloads; disabling OS protections
  is not an installation step.
- [ ] Add Windows assets and parity gates to the shared per-revision release
  pipeline once W0–W2 are green. Publish checksums, provenance, licenses, and the
  source/native build plan for the actual shipped bytes.
- [ ] Replace WSL-only setup guidance in installation/editor/contributor docs
  with tested native instructions, retaining WSL as an optional environment.

Exit: a fresh Windows user installs one artifact and completes the same API,
database, editor, and agent walkthrough as a Linux/macOS user.

## Verification and completion

Keep [`ci.sh`](../../ci.sh) as the authoritative shared gate. Extract reusable
test responsibilities into platform-neutral runners/manifests where necessary,
with both the Nix gate and Windows jobs invoking them. Bash-specific test harnesses
must not force Bash into the installed product or excuse missing native coverage.

Gate Windows releases on native compiler tests, Go runtime/tooling tests, emitted
program fixtures, managed-PostgreSQL integration, LSP/DAP/MCP protocol tests, real
editor-host tests, and clean install/upgrade/uninstall. Verify offline operation
with empty caches, a read-only install directory, multiple simultaneous projects,
locked files, Unicode/CRLF, cancellation, and process/port/temp-file cleanup.

Complete when W0–W3 pass and the parity inventory has no unexplained exclusions.
Packaging and release policy remain owned by the installation roadmap; semantic
features remain owned by the LSP roadmap. Once Windows joins the supported release
matrix, its failure blocks publication of a complete release rather than silently
omitting Windows assets.
