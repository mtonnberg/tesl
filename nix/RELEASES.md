# Native release metadata

`nix build .#release-plan` exports the pinned build inputs, version identity,
candidate platforms, archive names, and installation manifests. It does not build
or publish those archives yet. Native parity CI builds and tests source on every
candidate runner, checks the embedded CLI version, and loads the generated
manifests through the shared Go resolver.

## Versions

The single product version is `version` in `toolchain-inputs.nix`, currently
`0.3.1`. `release-identity.nix` derives native artifact versions from it:

| Build | Toolchain version | Release tag |
|---|---|---|
| Clean continuous build | `0.3.1-dev.<commit timestamp>.g<full SHA>` | `v` followed by that version |
| Explicit stable release | `0.3.1` | `v0.3.1` |
| Uncommitted checkout | `0.3.1-dev.worktree` | None; ineligible for publication |

The timestamp is the commit's Unix timestamp exported as `sourceDateEpoch`, not
the build's wall clock or a CI run number. The full SHA distinguishes commits
with identical timestamps. Identical inputs produce identical versions across
platforms and retries. All versions are SemVer; development builds sort below
the corresponding stable version. Commit timestamps need not increase, so a
future continuous-channel publisher must order revisions by the main history,
not rely only on version comparison or build completion time.

A stable plan is an explicit evaluation of `release-plan.nix` with
`releaseTag = "v0.3.1"`, a full clean `revision`, and its `sourceDateEpoch`.
Mismatched tags, abbreviated revisions, and invalid version numbers fail.
Passing a release tag selects identity; it does not authorize publication or
replace any acceptance gate. Converting a development build to a stable version
changes manifests and embedded version strings, so the resulting stable bytes
must be rebuilt, tested, and attested before publication.

Do not rename a Git-hash artifact to pretend it is a stable version. The full
source SHA remains in the release plan, installation manifest, native evidence,
and embedded Go identity. The manifest is authoritative for installed commands.
Without one, legacy Nix uses `TESL_VERSION`, then the native executable falls
back to its linked identity; an ordinary `go build` reports `dev`.

## Payload contract

For each candidate target, `payloads.<target>` contains:

- `archiveName`: `tesl-<version>-<target>.tar.gz`, or `.zip` on Windows.
- `installerName`: versioned setup executable name (self-contained on Windows).
- `manifest`: the exact version-1 `share/tesl/toolchain.json` document to install.

The manifest includes all six frontends, compiler, Go, PostgreSQL server/client
tools, stdlib, templates, documentation, module proxy, and licenses. Versions
come from product/source pins; paths come from `layout`. Executable paths gain
`.exe` on Windows. Resource directories do not. The JSON contains relative,
slash-separated paths, including on Windows, and never Nix store locations.

This inventories the components the payload builder must supply. It does not
prove that native dependencies or licenses have been collected, that installed
workflows work offline, or that the candidate OS baseline has been verified.
The remaining distribution gates are in
[`mainstream_installation.md`](../roadmap/next/mainstream_installation.md) and
[`windows_support.md`](../roadmap/next/windows_support.md).

## Offline Go module bundle

The release plan includes SHA-256 hashes of `runtime/go/go.mod` and `go.sum`.
The module builder refuses changed locks, fetches only their exact versions,
and checks Go's `h1` content hashes before exposing a completed output directory:

```sh
nix build .#release-plan --out-link release-plan
python3 scripts/module_proxy.py --plan release-plan --output module-bundle
```

Use `--source /path/to/pkg/mod/cache/download` to build from a complete local
download cache. No Python packages are needed. The output contains a `proxy/`
directory for the manifest's `go-modules` component, a `licenses/` tree, and
`inventory.json` with the source revision, version, lock hashes, module checksums,
and every payload file's size and SHA-256. Source archives are included only for
versions with a pinned source checksum; older `go.mod`-only entries remain metadata.
There is no latest-version lookup or network fallback in the installed proxy.

Archive members are sorted and use fixed timestamps and uncompressed ZIP entries,
so proxy file bytes do not depend on upstream ZIP ordering, compression, or dates.
An eventual distribution archive can compress these files. This does not yet
prove reproducibility of a complete native payload, its filesystem metadata,
SDK, or PostgreSQL dependencies.

Native CI creates one bundle and verifies its identity and file inventory on each
runner before testing it. The CLI acceptance test copies the runner's compiler and
SDK into a prefix containing spaces and Unicode, then uses empty module caches
for both scaffolds, password hashing, and Windows debug compilation. The test
rejects missing/corrupt modules and checks that installation files remain unchanged;
Unix also enforces read-only permissions. Run it after building the compiler:

```sh
TESL_TEST_MODULE_BUNDLE="$PWD/module-bundle" \
  go -C runtime/go test ./internal/cli -run TestOfflineModuleBundleWorkflow -count=1 -timeout=12m
python3 -m unittest discover -s scripts -p test_module_proxy.py
```

This test uses local module resolution and deliberately unusable network proxies.
It tests module availability, not native dependency relocation or a managed
database. Evidence therefore records `offline_go_modules: passed` separately from
`offline_install: not-tested`; the latter remains a release gate.

## Native candidate archives

`scripts/native_distribution.py` builds a native candidate from the
exported plan, then tests the extracted archive before making its output directory
visible. Unix build hosts need the pinned Go bootstrap and Python 3.10+
and native C/build tools (GNU make, Bison, Flex and Perl). Linux needs `readelf`,
`unshare` with user/network namespaces, and `ip`; macOS uses its native linker,
`otool`, `install_name_tool`, and `codesign`. These are builder requirements.

```sh
python3 scripts/native_distribution.py --plan release-plan --target linux-amd64 \
  --module-bundle module-bundle --output artifacts/native-candidate
```

The builder verifies flat archive hashes and recursive Nix source hashes before
running source code. It builds Go from the pinned upstream archive, using the
runner's Go only for bootstrap. The new SDK builds all six frontends with CGO
disabled and trimmed build paths. OCaml and Dune are built from their exact
Nix-exported source archives; the runner's opam installation is used only by the
separate parity tests. OCaml compression is disabled to avoid an external zstd
dependency. Dune uses its bootstrapped native executable, not its source-tree
shell wrapper. PostgreSQL is built from its pinned source and
retains its own server/client binaries, libraries, schema files, timezones and
license notices. Its local development configuration disables optional ICU,
OpenSSL, readline, compression and other external libraries; it does not provide
TLS for the managed local server. Tesl's Go database client can still connect to
an external TLS-enabled PostgreSQL server.

The assembler requires all manifest components and their expected versions,
includes source/module license files, and records file hashes, permissions and
links. The binary audit rejects Nix runtime references, incompatible architectures,
unresolved libraries, escaping loader paths, and binaries needing a newer glibc
or macOS deployment target than the plan declares. macOS builds set the deployment
target before installing OCaml and use a separate opam cache namespace.

Acceptance runs the actual extracted CLI after another relocation into a read-only
prefix with spaces and Unicode. It uses isolated home/cache directories and a PATH
without development tools, exercises the API scaffold, managed database, compiler
queries, tests, local build and authenticated HTTP, then checks persistence across
clean/restart and installation immutability. Linux additionally runs it in a new
network namespace with loopback only, retaining a non-root UID for PostgreSQL.
macOS uses `sandbox-exec` around the complete acceptance process tree. Local
TCP/UDP listeners must remain reachable; an external connection to the CI
provider supplies a positive control before sandboxing. Inside the sandbox,
off-host IPv4/IPv6 operations must return an explicit policy denial. macOS's
`localhost` filter covers all addresses of this host, so its own LAN address is
not used as the negative control. A refused connection or timeout is not
accepted as proof of isolation. Probe failures prevent candidate export. This CI-only helper
does not change the runner's firewall or add a dependency to installed Tesl.
Acceptance also records the actual host OS, architecture and libc version.
Only execution on the declared baseline earns `minimum_os_runtime: passed`;
a newer macOS runner or a Windows Server runner retains `not-established` for
the declared macOS/desktop Windows baseline.

The current matrix uses macOS 15 and Windows Server 2025. GitHub's
[standard runner list](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
does not include macOS 13 or Windows 11 x86-64. Its Windows 11 ARM runner would
provide supplementary emulation coverage, not native x86-64 baseline evidence.
Minimum-OS acceptance therefore needs a matching test host or an explicit change
to the supported baseline. This test-coverage gap is independent of signing accounts.

Outputs are the versioned `.tar.gz`/`.zip`, its `.sha256`, and `distribution-checks.json`.
They are CI candidates without a publisher certificate. Archive metadata is normalized, but complete
cross-host reproducibility, installers, upgrades and publication remain
separate acceptance gates. Windows Authenticode and macOS Developer ID signing /
notarization are explicitly optional under the maintainer's 2026-09-05 policy.
Windows delivery is unsigned; macOS delivery is an ad-hoc signed native archive,
with Nix recommended for macOS users. Execution on the declared minimum OS and
Windows network isolation remain separate gates. The macOS isolation probe passes
on both architectures; the complete macOS installed workflow remains pending.
Native Windows packaging includes MSVC PostgreSQL, the
verified-source OCaml compiler, and a PE/DLL audit. Required compiler runtime DLLs
come only from the active Visual Studio redistributable directory, retain their
Microsoft signatures, and include hashes, versions, and the pinned license text.
The evidence records these limits instead of claiming a finished release.

The [2026-09-05 native run](https://github.com/mtonnberg/tesl/actions/runs/33973183098)
passed complete archive assembly and isolated installed-workflow acceptance on
Linux x86-64 and ARM64, both with glibc 2.35. The downloaded x86-64 candidate for
source `51e520383b8f02b3942f55c63cfe2eaafad24e55` was independently checksum-checked:
115,102,511 archive bytes, 370,598,455 expanded regular-file bytes, and 18,607 tar
entries. These are prototype measurements; filesystem allocation differs and
the complete matrix still needs a measured size budget.

On macOS, assembly ad-hoc signs every audited Mach-O executable and library with
`codesign --sign - --timestamp=none`, then verifies every signature before recording
file inventories and archive checksums. It needs no keychain identity, Apple
account, or notarization service. Evidence records `publisher_identity: false`
and `notarized: false`; the catalog requires this evidence without treating it as
Developer ID signing. Failed ad-hoc signing/verification still fails assembly.
Quarantined-download acceptance remains separately recorded; it must not be
reported as passed merely because command-line execution on a CI runner passes.
See `INSTALL.md` for checksums, executable paths, and first-launch guidance.

After a complete native matrix on a canonical `main` push, a separate provenance
job validates every archive, checksum, setup executable and evidence file before
attesting those bytes together with the release plan and `native-build-inputs.json`.
It uses GitHub's short-lived workflow identity; no Apple/Windows signing account
or separately managed signing key is involved. PR/manual runs do not attest, and
the build jobs have no attestation-writing or OIDC permissions.

For an attested main-build download, replace `ARTIFACT` and `SOURCE_SHA` below
with its filename and full source commit SHA:

```sh
gh attestation verify ARTIFACT --repo mtonnberg/tesl \
  --signer-workflow mtonnberg/tesl/.github/workflows/native-parity.yml \
  --source-ref refs/heads/main --source-digest SOURCE_SHA \
  --signer-digest SOURCE_SHA --deny-self-hosted-runners
```

The `native-provenance` CI artifact also contains the verification bundle; pass
its path with `--bundle` to use a downloaded bundle. See the
[GitHub CLI verification options](https://cli.github.com/manual/gh_attestation_verify).
This attests native build origin and pinned inputs. It does not declare that the
authoritative gate, minimum-OS matrix or complete release publication passed.
The provenance job still needs its first successful main run after merge.

## Native Windows source build

Use a clean checkout of the exact source revision in the release plan. The native
Windows source build requires Python 3.10+, the plan's exact Go bootstrap version,
Visual Studio 2022 C++ build tools/Windows SDK, and Cygwin with `gcc-core`,
`gcc-g++`, `make`, `m4`, `patch`, `perl`, and `diffutils`. These are build-only
prerequisites. The resulting installed toolchain does not require Cygwin or opam.

The release plan is available in `share/tesl/release-plan.json` inside a payload
and as a CI artifact. A Linux/macOS source builder can also export it from the
same clean checkout with `nix build .#release-plan --out-link native-release-plan.json`.
Its `sourceRevision` must equal `git rev-parse HEAD`; do not reuse a plan from a
different commit.

From a native x64 Visual Studio developer PowerShell, with Cygwin's `bin` on PATH:

```powershell
python scripts/module_proxy.py --plan native-release-plan.json --output native-module-bundle
python scripts/native_distribution.py --plan native-release-plan.json --target windows-amd64 --module-bundle native-module-bundle --output artifacts/distribution-windows-amd64 --cygwin-bash C:\cygwin\bin\bash.exe
```

The builder downloads and verifies the plan's OCaml, Dune, Go, PostgreSQL,
FlexDLL, winpthreads, Meson, Ninja, Perl, Flex, and Bison sources before executing
their build scripts. Flex/Bison run in Cygwin; the packaged executables use native
Windows APIs. No payload DLL is selected from an arbitrary PATH directory.
The workflow in `.github/workflows/native-parity.yml` provides the complete
runner setup and runs the same recipe.

Windows outputs include `tesl-<version>-setup-windows-amd64.exe` and its SHA-256.
The setup embeds the exact tested ZIP, followed by a versioned footer containing
its byte offset, length, and digest. It installs to the current user's directory,
without network downloads or administrator privileges. The native installer
validates the archive and manifest, stages a complete immutable version, and
atomically changes its selection state. Its tests cover corrupt input,
interrupted installation, coexistence, rollback, uninstall, active-process
leases, and PostgreSQL data preservation. The distribution builder additionally
executes the final setup, installed launcher, and uninstall on native Windows.

This setup is unsigned by project policy. An embedded hash protects against
accidental corruption; the separately published hash identifies the final setup
bytes. Neither is an Authenticode publisher signature. Source builds and the
portable ZIP remain alternatives to the setup executable.

To exercise an already unpacked payload directly:

```sh
TESL_TEST_INSTALLED_ROOT=/absolute/path/to/tesl \
  go -C runtime/go test ./internal/cli -run '^TestInstalledToolchainWorkflow$' -count=1 -timeout=20m
```

## Regression checks

The version and plan tests require only the Nix evaluator, without downloads:

```sh
nix-instantiate --eval --strict --json nix/tests/release-identity.nix
nix-instantiate --eval --strict --json nix/tests/release-plan.nix
```

To check the actual pinned export against the native resolver:

```sh
nix build .#release-plan --out-link release-plan
TESL_RELEASE_PLAN="$PWD/release-plan" go -C runtime/go test ./internal/toolchain
```

Native CI runs both sets of checks and preserves the exact plan with its
per-platform evidence. Future publishers must additionally require a clean,
authorized source ref, the complete matrix, offline installation and dependency
audits, and provenance before making any release visible. OS signing follows the
explicit per-platform policy; missing paid signing credentials do not block
unsigned Windows or ad-hoc macOS releases.
