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
audits, and provenance/signing gates before making any release visible.
