# Mainstream installation

Status: in progress, 2026-09-05. Native command orchestration and discovery are
implemented. Distributable payloads, installers, and release
outputs below remain targets until their acceptance gates pass.

Implemented so far:
- [`internal/cli`](../../runtime/go/internal/cli) and [`cmd/tesl`](../../runtime/go/cmd/tesl)
  provide native init/check/compile/run/test/build/watch/database/debug/agent
  orchestration, literal arguments, dotenv parsing, and a doctor report.
- [`internal/toolchain`](../../runtime/go/internal/toolchain) provides versioned
  installation-relative discovery and an offline Go environment. CLI, LSP, DAP,
  and MCP use it; the extension recognizes the same manifest layout. An explicit
  stdlib directory component makes lifted library sources work outside a checkout.
- `nix build .#tesl-native-cli` builds a native CLI candidate using the shared Nix
  tools. Both CLI candidates pass clean-environment init/emit/build and executable
  stdlib tests; CI now checks both. Compiler-adjacent library discovery and explicit
  overrides are tested with relocated and symlinked executables.
- Compiler mutation/build subprocesses use literal argv with bounded output and
  timeouts. The native CLI owns Windows process trees; no Bash or GNU `timeout`
  is required for these compiler commands. DAP compiler/Go preparation uses the
  same bounded Go process client.
- [`toolchain-inputs.nix`](../../nix/toolchain-inputs.nix), the shared Go overlay,
  and [`release-plan.nix`](../../nix/release-plan.nix) export versions, source
  hashes, candidate platforms, layout, and exact-revision release policy.
- [`native-parity.yml`](../../.github/workflows/native-parity.yml) defines native
  compiler/tooling checks for five candidate targets. Main CI revisions are no
  longer canceled by a newer main push.
- Tests exercise a real scaffold/check/test/compile/build/HTTP/cancel workflow,
  PostgreSQL data persistence, build rollback, watch restart, discovery failures,
  and paths containing spaces and Unicode.
- Native version/doctor identity honors the selected manifest or Nix version.
  Subprocess tests cover unchanged diagnostic streams, ordinary exit statuses,
  and Unix child signal statuses; native CI includes these entrypoint tests.
- The authoritative gate runs the existing CLI portability scenarios against
  both implementations, including entrypoints, build targets, symlink boundaries,
  scanner plans, and DAST validation exit statuses.
- [`release-identity.nix`](../../nix/release-identity.nix) derives semantic artifact
  versions from the pinned product version and exact source metadata. The export
  includes versioned archive names and component manifests for all five targets;
  native binaries embed their identity and test the generated manifests. The
  contract and local checks are documented in [`nix/RELEASES.md`](../../nix/RELEASES.md).
- [`module_proxy.py`](../../scripts/module_proxy.py) builds the offline Go module
  bundle from the release plan's lock hashes, verifies module content checksums,
  and collects licenses and a file inventory. Native CI verifies the transferred
  bundle before scaffold/password/debug compilation with empty module caches.
  Tests cover corrupt/missing modules, private-module environment overrides, and
  unchanged installation files. This is an M2 component; the copied SDK/compiler
  acceptance fixture does not establish native dependency closure or managed
  PostgreSQL distribution.
- The native candidate pipeline now builds upstream Go and a minimal local
  PostgreSQL from verified Nix source pins, assembles all manifest components,
  audits native dependencies/baselines, and tests the extracted archive using
  the installed CLI. The installed workflow covers managed database persistence,
  local build and authenticated HTTP; Linux uses a loopback-only network namespace.
  See [`nix/RELEASES.md`](../../nix/RELEASES.md) for commands and evidence limits.
  Local source builds and workflow tests pass; candidate platform CI is still
  required. OCaml and Dune now build from their verified source pins as well.
- The 2026-09-05 native matrix passed complete payload assembly and the isolated
  installed workflow on Linux x86-64 and ARM64 at glibc 2.35. macOS and Windows
  distribution gates remain pending; measurements are in `nix/RELEASES.md`.
- macOS acceptance now uses an inherited network sandbox with positive local
  and external controls and explicit off-host TCP/UDP policy-denial probes for IPv4/IPv6.
  The network probe passes on both native macOS architectures; the complete
  installed workflow remains pending. Failure cannot export a candidate archive.
- The user-prefix installer validates checksums, manifests and archive contents,
  stages immutable versions, and supports selection, rollback and owned-file
  uninstall. Process leases protect active versions, including persistent managed
  PostgreSQL. The editor discovers managed installations and pins its selected
  version until reload. Unit and real PostgreSQL lease tests pass locally.
- Windows now has a source-build pipeline and self-contained setup executable;
  those additions still require native CI execution. The release catalog checks
  exact source/artifact/gate identities and complete matrices, but publication
  and external attestation verification are not yet connected.
- A separate main-only provenance job now validates the complete same-run native
  artifact matrix and attests its final bytes, release plan and pinned-input
  manifest using GitHub's workflow identity. PR/build jobs receive no signing
  permission. Regression tests cover source/event mismatches, partial matrices,
  changed bytes and extra assets. First main execution remains pending.
- Distribution policy, 2026-09-05: Windows ships unsigned setup/ZIP downloads;
  macOS offers ad-hoc signed native archives and recommends Nix. Developer ID,
  notarization and Authenticode are optional future improvements, not account
  prerequisites or roadmap completion blockers. Checksums and provenance remain
  required, and documentation explains first-launch prompts.

Nix's default install, `nix run`, and development shell now select the native CLI
after local command-parity and clean-install checks passed. The authoritative gate
is being rerun with this selection; it also tests the actual default profile.
Native parity CI now includes Linux/macOS candidate assembly
and installed-workflow gates; Windows packaging checks await their first run. It does not
publish releases. M2–M4 remain open, including complete native
dependency closure, scanner parity, provenance, and native install/upgrade tests.

Let Linux and macOS users download one Tesl toolchain and reach a running API
without installing Nix or a development toolchain. Keep Nix as the authoritative
build definition and supported contributor/install path. Derive distribution
formats from that definition instead of maintaining separate products.

## Current state and packaging gap

[`INSTALL.md`](../../INSTALL.md) recommends Nix and documents native CI candidates.
The [`flake`](../../flake.nix) builds an OCaml compiler, Go CLI/LSP/DAP/MCP/debug
tools and templates. The previous Bash CLI in
[`tesl-cli-body.sh`](../../nix/tesl-cli-body.sh) remains a parity-test reference.

The installed wrappers contain Nix store paths and provide Go and GNU utilities.
Running generated programs requires Go, not merely the Tesl compiler. Managed
PostgreSQL discovery falls back to `nix build` when its tools are absent. The
flake also supplies DAST tools. Copying `main.exe` or archiving the current Nix
output therefore does not satisfy the installation goal.

The existing [`clean-install test`](../../tests/go-clean-install.sh) checks
`init`, `emit`, staging a build, and type checking/executing a lifted standard-library
program under a clean environment. It neither proves
absence of `/nix/store` nor tests first-run dependency downloads, a running API,
managed PostgreSQL, or desktop editor discovery. CI currently runs the
authoritative gate on Ubuntu; release-platform testing must be added.

## Product contract

### One download per platform

“One artifact” means one archive or installer containing the working toolchain,
not necessarily one executable. Checksums, provenance, and source archives are
separate verification/rebuild assets, not additional runtime installations.

| Included in the standard artifact | Reason |
|---|---|
| Native CLI and OCaml compiler | Scaffold, check/prove, format, lint, emit, run, watch, test, and build |
| LSP, DAP, MCP, debug-inspect, and debug-attach tools | Editor and agent workflows use the matching compiler revision |
| Pinned Go toolchain and required generated-program dependencies | First `run`/`test` works without a system Go, C compiler, or module download |
| Native PostgreSQL tools and required libraries | The default managed-database scaffold works without Nix or a separate database install |
| Templates, stdlib/runtime resources not already embedded, docs, and licenses | Installed commands work without a checkout |
| Machine-readable release/component manifest | Report identity, locate resources, verify contents, and diagnose mixed installations |

After download, the standard scaffold must compile, run, and pass its local tests
with outbound networking disabled and empty user caches. External APIs and an
explicitly selected remote database naturally still need their services.

Docker image construction requires a user-provided container engine; staging a
build context does not. Inventory DAST/scanner requirements separately in M0:
provide a documented, pinned installation path and preserve those commands, but
do not make a scanner/Java download part of the default API quick start. If full
scanner bundling is selected, measure its size and startup effects explicitly.

### Initial support and installation surfaces

| Target | First-class delivery |
|---|---|
| Linux x86-64 and ARM64, on a declared glibc baseline | Relocatable `.tar.gz`, a user-prefix installer, and generated `.deb`/`.rpm` wrappers around the tested payload |
| macOS Apple Silicon and Intel, on declared minimum OS versions | Nix recommended; ad-hoc signed native downloads and an upstream Homebrew tap using the same tested payload |
| Source builders | Exact-revision source plus lock files and documented Nix build/test/package commands |

Choose the oldest supported OS/ABI baselines in M0 based on actual compiler,
Go, and PostgreSQL constraints; publish and test them. “Linux support” must not
imply all libc variants. Alpine/musl and additional architectures are follow-ups.
Native Windows is specified in [`windows_support.md`](windows_support.md).

Keep the first package-manager integrations thin: no separate compiler builds,
hand-edited version pins, or prerequisite admission to central repositories.
An upstream [Homebrew tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
provides a supported distribution route while wider repository inclusion remains
independent. Package-manager policy may require a formula or cask; verify that
choice against the actual bundled payload in M4.

## Shared architecture

### Nix owns the inputs and release description

- Define component versions, source hashes, patches, target baselines, resource
  layout, and package metadata in Nix, with `flake.lock` pinning inputs. Extract
  shared definitions so `flake.nix` and compatibility entry points cannot drift.
- Export a machine-readable build/release plan for native runners and packaging
  tools. Generated manifests and recipes are outputs, not a second set of pins.
  CI rejects differences between regenerated and consumed metadata.
- Keep existing Go module lock files and compiler/runtime synchronization checks;
  Nix consumes these language-specific inputs. Extend the checks to the bundled
  generated-program dependencies rather than hand-copying their versions again.
- Build relocatable payloads explicitly. Audit dynamic loaders, shared libraries,
  Go paths, and resource lookups; a Nix closure is not automatically relocatable.
  Use relative library/resource paths or static linking where supported, and
  prove the result on machines without Nix.

### One portable CLI

Move the shell orchestration into a shared native Go CLI, retaining the existing
OCaml frontend and command contracts. This is also the prerequisite for native
Windows; do not write a second PowerShell implementation of the Bash CLI.

Inventory every existing command, option, exit code, JSON response, environment
override, and lifecycle behavior before cutover. Migrate command groups with
black-box parity fixtures. Invoke child tools with argument arrays and use
platform filesystem/process APIs. Once parity is demonstrated, both Nix and
standalone installs launch the same CLI; remove duplicate shell behavior.

Use one toolchain discovery contract across CLI, editor, and agent tools: explicit
supported override, then resources beside the selected installation, then a
documented development fallback. Validate compatibility and report every chosen
path. A proposed `tesl doctor --json` reports component versions, source revision,
install location, and missing optional tools without exposing secrets.

Keep immutable program files separate from writable caches and project data.
Bundled Go must have the matching host tools and a verified source of all required
modules; disable implicit toolchain switching/downloading in the offline path.
Managed PostgreSQL must use project/user data directories and survive toolchain
replacement without implicit database-major-version migration.

## Release policy

1. For every distinct pushed `main` head that passes the authoritative gate and
   the required release-platform matrix, publish one immutable continuous release
   tied to the full commit SHA. Pull requests and failed/cancelled builds do not
   publish. Retrying a successful SHA is idempotent.
2. Use `MAJOR.MINOR.PATCH-dev.<commit timestamp>.g<full SHA>` for continuous
   artifacts and `MAJOR.MINOR.PATCH` for deliberate stable releases, with `v`
   prefixed release tags. `nix/toolchain-inputs.nix` owns the base version. A
   stable tag must match it; stable bytes must be rebuilt and tested with their
   final identity. Dirty checkouts use `-dev.worktree` and cannot publish. A new
   successful `main` revision requires no manual version bump. Commit timestamps
   can move backwards; channel advancement must follow main's revision order.
3. Check out and attest the exact tested revision at every stage. Do not resolve
   `main` again during packaging. Stage all mandatory assets before publishing;
   a partial matrix leaves the previous complete release available.
4. Preserve per-revision release work when newer pushes arrive. The current CI
   `cancel-in-progress: true` policy must be adjusted for releasable `main` runs;
   otherwise the promise to release every successful pushed revision is lost.
5. Advance the continuous-channel pointer only after publication, with serialized
   ordering so a slow older build cannot replace a newer one. Stable channels and
   public package registries have their own explicit promotion policy; they need
   not ingest every continuous build.
6. Installers support selecting an exact version. Upgrades stage and verify the
   replacement before switching; interrupted installs preserve the old version.
   Package-manager installs are upgraded by their package manager. Uninstall
   removes owned program files and PATH entries, preserving projects and databases.

## Integrity, provenance, and rebuilding

- Publish SHA-256 digests for the final distributable bytes. A checksum detects
  changed bytes; a checksum hosted beside a binary alone does not prove who built
  it or which source was used.
- Attach verifiable build provenance binding each artifact digest to the source
  SHA, workflow, and build inputs. Document both ordinary checksum verification
  and [GitHub artifact-attestation verification](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations).
  Installer automation validates the expected repository/workflow identity as
  well as the digest before activating a payload.
- macOS initially ships ad-hoc signed native archives, per the maintainer's
  2026-09-05 decision. Nix remains the recommended route. Ad-hoc sign and verify
  each native executable/library before hashing the final payload; this needs no
  certificate. Developer ID signing and notarization are optional future work.
  Record quarantined-download behavior separately and document first-launch
  prompts using [Apple's opening guidance](https://support.apple.com/en-us/102445).
  Do not claim publisher identity or notarization for ad-hoc signatures.
- Windows initially ships unsigned setup executables and portable ZIPs with
  SHA-256 checksums and provenance, per the maintainer's 2026-09-05 decision.
  Windows code signing is optional future work; its absence does not fail a
  Windows release gate. Document unknown-publisher prompts and source builds.
- Ship a component/license inventory and the exact source/lock data needed to
  rebuild. Check redistribution obligations for Go, PostgreSQL, shared libraries,
  and optional tools as part of payload assembly.
- Record separate identities for the reproducible unsigned payload and signed
  distribution. Test independent rebuilds of the former and report differences;
  signing timestamps/notarization must not be described as byte-reproducible.

## Delivery plan and gates

### M0 — Freeze the release contract

- [ ] Inventory CLI behavior and transitive runtime dependencies, including
  managed PostgreSQL, Go module acquisition, Docker, DAST, and debugger launches.
- [ ] Select tested OS/ABI baselines, payload layout, version/channel rules, and
  native-runner export schema. Measure candidate download and installed sizes.
- [x] Record the no-account distribution policy: unsigned Windows, ad-hoc macOS,
  Nix recommended on macOS; paid signing is optional.
- [ ] Record the payload reproducibility target and define a maximum artifact
  size from the measured prototype.

Exit: every dependency is bundled, embedded, an OS baseline dependency, or an
explicit optional integration. No unresolved dependency in the default quick start.

### M1 — Share portable execution and discovery

- [x] Implement the Go CLI and installation-relative tool/resource discovery.
- [ ] Port lifecycle, database, watch, test/mutation, build, and debug behavior
  using the parity fixtures; preserve machine-readable command contracts.
- [ ] Switch Nix to the same implementation after the existing gate passes.

Exit: Nix users retain current behavior, and relocated candidate payloads find
their own compiler, tools, and resources without shell wrappers or Nix paths.

### M2 — Produce complete Linux and macOS payloads

- [x] Build and checksum the locked Go module proxy with licenses; add empty-cache
  scaffold/password/debug coverage to the native matrix.
- [x] Implement native Go/PostgreSQL source builders, the complete payload
  assembler, binary audit, and extracted-archive acceptance harness.
- [ ] Build both architectures on the declared baselines and assemble pinned Go,
  generated-module dependencies, PostgreSQL, resources, and licenses.
- [ ] Test on clean hosts without Nix, a checkout, system Go/OCaml, PostgreSQL,
  or a C compiler. Block outbound networking during the default workflow.
- [ ] Verify symlinked launchers, arbitrary install prefixes, spaces/Unicode in
  paths, read-only installations, TLS trust, time-zone data, and process cleanup.

Exit: `init` → check → test → run → HTTP request works, including a managed
database, plus watch/restart, build-context staging, LSP/MCP startup, and a debug stop.

### M3 — Automate trustworthy per-revision releases

- [ ] Extend CI with exact-revision platform gates, payload identity checks,
  declared signing policy, checksums, provenance, and complete-matrix publication.
- [ ] Exercise duplicate runs, an older run finishing late, a failed architecture,
  ad-hoc signing/verification failure, corrupt downloads, and interrupted upgrades.
- [ ] Publish rebuild instructions and verify an independent unsigned rebuild.

Exit: a successful new `main` revision produces one complete verifiable release
without manual packaging; failures preserve the prior usable channel.

### M4 — Add ecosystem installation and finish onboarding

- [ ] Generate/test the user-prefix installer, `.deb`/`.rpm`, macOS distribution,
  and Homebrew integration from the release manifest.
- [ ] Verify install, exact-version selection, upgrade, rollback, and uninstall
  for each supported route, including coexistence with a Nix installation.
- [ ] Make desktop-launched VS Code/VSCodium discover the selected toolchain;
  publish a compatible extension/VSIX path and test LSP, tests, DAP, and MCP.
- [ ] Update `INSTALL.md`, the README quick start, contributor/source-build
  instructions, editor/MCP docs, and troubleshooting with tested commands.

Exit: a new user follows one documented path to the default API and editor
workflow, with no hidden dependency setup or unexplained PATH/version mismatch.

## Ownership and completion

Sequence the shared work once: M0 defines the inputs/layout consumed by Windows
W0; M1 supplies the portable CLI needed by Windows W1. Linux/macOS M2–M4 can
finish before Windows parity. Windows W3 extends the proven M3 release pipeline
and M4 installer contracts rather than creating another release system. LSP
L0–L4 can proceed independently against the shared discovery/version contract.

This roadmap owns portable CLI orchestration, payload layout/discovery, version
identity, release generation, and Linux/macOS distribution.
[`windows_support.md`](windows_support.md) supplies native Windows builds and
platform behavior against those contracts.
[`gold-standard-lsp.md`](gold-standard-lsp.md) improves language semantics and
editor features independently; installation must ship the existing tools first.

Complete when M0–M4 pass on every declared target, the Nix path remains supported,
all release metadata derives from the shared definition, and fresh-install and
upgrade checks gate subsequent releases. Adding another ecosystem must mean
adapting packaging, not maintaining another Tesl implementation.
