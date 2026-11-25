# Installing Tesl

**Tesl is beta.** Expect breaking changes. Nix is the recommended macOS and
established Linux installation path. Native downloads for Linux, macOS and
Windows are published on the [GitHub Releases page](https://github.com/mtonnberg/tesl/releases).
Marketplace publication remains separate from installing the toolchain.

## Downloading a release

There are two kinds of release:

| Release | Tag | When it appears |
|---|---|---|
| Stable | `v0.3.1` | When a version is tagged. Marked "Latest" on GitHub. |
| Continuous (prerelease) | `v0.3.1-dev.<timestamp>.g<commit>` | For every commit on `main` that passes the full CI gate and the native packaging checks. |

Pick the file for your system. Each download has a matching `.sha256` file.

| System | File | Oldest version tested |
|---|---|---|
| Linux x86-64 | `tesl-<version>-linux-amd64.tar.gz` | glibc 2.35 (Ubuntu 22.04) |
| Linux ARM64 | `tesl-<version>-linux-arm64.tar.gz` | glibc 2.35 (Ubuntu 22.04) |
| macOS Apple Silicon | `tesl-<version>-darwin-arm64.tar.gz` | macOS 15 |
| macOS Intel | `tesl-<version>-darwin-amd64.tar.gz` | macOS 15 |
| Windows x86-64 | `tesl-<version>-setup-windows-amd64.exe` or `tesl-<version>-windows-amd64.zip` | Windows Server 2022 (build 20348); Windows 11 uses a newer build |

"Oldest version tested" is what each release's installed-workflow test runs on.
macOS binaries are compiled for macOS 13 and may work there, but only macOS 15
is tested. Every installed-workflow test runs with outbound network access
blocked, so a fresh install works offline.

**Checking a download.** The `.sha256` file proves the bytes were not damaged.
To also prove the file was built by this repository's CI from the exact tagged
commit, use the GitHub CLI (replace `FILE` and `COMMIT` with the file name and
the full commit SHA shown in the release notes):

```sh
gh attestation verify FILE --repo mtonnberg/tesl \
  --signer-workflow mtonnberg/tesl/.github/workflows/native-parity.yml \
  --source-digest COMMIT --signer-digest COMMIT --deny-self-hosted-runners
```

Each release also includes `tesl-<version>-release-catalog.json`, which lists every
file's SHA-256 and every check it passed, and the exact release plan used to build it.

## Native Linux archives

Extract the archive and keep the directory together:

```sh
archive='tesl-<version>-linux-amd64.tar.gz'
sha256sum -c "$archive.sha256" && tar -xzf "$archive"
./tesl-<version>-linux-amd64/bin/tesl doctor
```

Add its absolute `bin` directory to your PATH, or configure the editor's
`tesl.toolchainRoot` to that directory.

## Native macOS archives

Use Nix below for the recommended macOS installation. If you prefer to avoid Nix,
download the complete native archive and its matching `.sha256`: `darwin-arm64`
for Apple Silicon, or `darwin-amd64` for Intel. They contain the compiled
executables, Go SDK, managed PostgreSQL, and resources; no development toolchain
is required. Download them from the [Releases page](https://github.com/mtonnberg/tesl/releases).

Replace `<version>` and select your architecture before running these commands
in the download directory:

```sh
archive='tesl-<version>-darwin-arm64.tar.gz'
shasum -a 256 -c "$archive.sha256" && tar -xzf "$archive"
```

Continue only after checksum verification and extraction succeed:

```sh
./tesl-<version>-darwin-arm64/bin/tesl doctor
./tesl-<version>-darwin-arm64/bin/tesl init myapi --yes
```

Keep the extracted directory together and add its absolute `bin` directory to
your PATH, or configure the editor's `tesl.toolchainRoot` to that directory.
Copying only `bin/tesl` omits the compiler and runtime resources.

These downloads have **no Developer ID signature or Apple notarization**. The
binaries use ad-hoc signatures for execution integrity; these do not establish
publisher identity. macOS may block their first launch. After verifying the
download and deciding to trust it, use Apple's per-app **Privacy & Security →
Open Anyway** procedure, described in [Apple's opening guidance](https://support.apple.com/en-us/102445).
Bundled tools may prompt separately. Nix is the recommended alternative if that
friction is undesirable. Signing accounts are not required for native downloads.

## Native Windows downloads

Windows x86-64 downloads contain the CLI, compiler, editor/agent tools, Go SDK,
managed PostgreSQL, standard library, templates, and offline Go dependencies.
End users do not need Nix, WSL, Bash, Go, or OCaml. Build dependencies are separate.

Download the setup `.exe` and its matching `.sha256` from the same
[release](https://github.com/mtonnberg/tesl/releases). Filenames include the
exact version and target.

Verify the executable in PowerShell before running it. Replace `<version>` with
the downloaded version:

```powershell
$setup = '.\tesl-<version>-setup-windows-amd64.exe'
$expected = ((Get-Content -LiteralPath ($setup + '.sha256') -Raw).Trim() -split '\s+')[0]
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $setup).Hash -ine $expected) {
    throw 'The setup checksum does not match; do not run this download.'
}
& $setup install
& "$env:LOCALAPPDATA\Programs\Tesl\bin\tesl.exe" doctor
```

The initial setup is **unsigned**. Windows may display an unknown-publisher or
reputation warning. The checksum verifies the downloaded bytes; it does not
establish publisher identity. If your organization's policy blocks unsigned
executables, use the source-build path below. Disabling Windows protections is
not part of installation.

Setup installs for the current user under `%LOCALAPPDATA%\Programs\Tesl`; no
administrator account is needed. Add its reported `bin` directory to your user
`PATH` in Windows environment-variable settings, then open a new terminal. The
VS Code/VSCodium extension also discovers this default directory when launched
from the desktop. An open editor keeps its selected version; reload it after an
upgrade to select the new default.

```powershell
tesl init myapi --yes
Set-Location myapi
tesl check app.tesl
tesl test app.tesl
tesl run app.tesl
```

The portable ZIP contains the same complete payload. Extract its top-level
directory and run `bin\tesl.exe` there. Keep the directory together; copying only
`tesl.exe` omits the compiler and runtime resources.

The installed `bin\tesl-install.exe` supports `list`, `select <version>`,
`rollback`, and `uninstall <version>`. Additional versions install alongside
existing versions. Uninstall preserves projects and databases and refuses to
remove a version used by running managed processes.

To build on Windows, use the exact checkout, exported Nix release plan, and native
build recipe in [nix/RELEASES.md](nix/RELEASES.md#native-windows-source-build).
The same plan is included in each payload at `share/tesl/release-plan.json`.

---

## Prerequisites

You need **Nix with flakes enabled**. Check:

```bash
nix --version          # need 2.4 or later
nix flake --help       # if this errors, flakes are not enabled
```

If flakes are not enabled, add this to `~/.config/nix/nix.conf` (or `/etc/nix/nix.conf`):

```
experimental-features = nix-flakes nix-command
```

**macOS / Linux:** The [official Nix installer](https://nixos.org/download/) sets this up. The [Determinate Systems installer](https://github.com/DeterminateSystems/nix-installer) enables flakes automatically.

**Windows:** WSL2 remains an optional way to use the Nix installation path.
Native Windows users use the setup or portable ZIP described above.

---

## Try it without installing

```bash
nix run github:mtonnberg/tesl -- help
```

That's it. No repo clone, no PATH change. Run against a file you already have:

```bash
nix run github:mtonnberg/tesl -- check path/to/my-api.tesl
```

---

## Persistent install

### `nix profile` (recommended for individuals)

```bash
nix profile install github:mtonnberg/tesl
tesl help
```

To upgrade later:

```bash
nix profile upgrade '.*tesl.*'
```

### home-manager

Add to your home-manager configuration:

```nix
home.packages = [
  inputs.tesl.packages.${pkgs.system}.tesl-cli
];
```

With the input:

```nix
inputs.tesl = {
  url = "github:mtonnberg/tesl";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

### NixOS system package

```nix
environment.systemPackages = [
  inputs.tesl.packages.${pkgs.system}.tesl-cli
];
```

---

## Verify the install

Write a file called `hello.tesl` anywhere on your machine:

```tesl
module Hello exposing [greet]
import Tesl.Prelude exposing [String]

fn greet(name: String) -> String =
  "hello from tesl, ${name}"

test "greet works" {
  expect greet("world") == "hello from tesl, world"
}
```

Type-check it (parse + types + proofs + lint, no execution):

```bash
tesl validate hello.tesl
```

Run its `test` block to confirm the **full pipeline** end-to-end
(parser → type-checker → proof-checker → Go emitter → `go test`):

```bash
tesl test hello.tesl
```

To see a complete, runnable web service instead of a single function, scaffold a
project (this is the recommended starting point):

```bash
tesl init myapi --yes
cd myapi
tesl run app.tesl     # serves on http://localhost:8086
```

---

## Language Server (VS Code / VSCodium)

The extension is published on [Open VSX](https://open-vsx.org). Search for **Tesl** in VSCodium's extension panel and install it.

The extension needs the `tesl-lsp` binary to be available. The default nix install already includes it:

```bash
nix profile install github:mtonnberg/tesl
```

This installs both the `tesl` CLI and the `tesl-lsp` language server. The extension will find `tesl-lsp` automatically, even when VSCodium is launched from the desktop rather than a terminal.

**Alternative — explicit installation:** set `tesl.toolchainRoot` to a portable
payload or managed installation directory. For a development override, set
`tesl.lspBinary` to the absolute `tesl-lsp` executable path.

---

## Database setup (for the example APIs)

The example APIs (`example/todo-api.tesl` etc.) need PostgreSQL. When running via the flake dev shell (`nix develop github:mtonnberg/tesl`) a local cluster is started automatically. Outside the dev shell you need PostgreSQL running and the following environment variables set:

```
TESL_POSTGRES_HOST      (default 127.0.0.1)
TESL_POSTGRES_PORT      (default 5432)
TESL_POSTGRES_DATABASE
TESL_POSTGRES_USER
TESL_POSTGRES_PASSWORD  (optional)
```

---

## What is not supported yet

| Path | Status |
|---|---|
| `brew install tesl` / `apt install tesl` | Roadmap — not done |
| Signed Windows / notarized macOS downloads | Not planned for now; downloads are unsigned (Windows) or ad-hoc signed (macOS) |
