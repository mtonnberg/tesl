# Installing Tesl

**Tesl is alpha.** Expect breaking changes. The only supported install path today is Nix. A standalone binary installer and VS Code Marketplace publish are on the roadmap but not yet done.

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

**Windows:** Use WSL2, install Nix inside it, then follow the Linux path.

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
module Hello

endpoint GET /hello -> Text {
  "hello from tesl"
}
```

Check it type-checks:

```bash
tesl check hello.tesl
```

Compile it to Racket to confirm the full pipeline:

```bash
tesl compile hello.tesl
# → writes hello.rkt
```

Run it (requires Racket in PATH — included when you enter `nix develop` or install via Nix):

```bash
tesl run hello.tesl
```

---

## Language Server (VS Code / VSCodium)

The VS Code extension is not yet published to the Marketplace. Until it is, install it manually:

1. Clone the repo: `git clone https://github.com/mtonnberg/tesl`
2. Open VS Code in `editor/vscode-tesl/`
3. Run **Extensions: Install from VSIX…** or press `F5` to launch a development host

The extension expects `tesl-lsp` in PATH. With a profile install that is already present. You can also point the extension at the LSP script directly via the `tesl.lspScript` setting.

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
| Standalone binary (no Nix) | Roadmap — not done |
| `brew install tesl` / `apt install tesl` | Roadmap — not done |
| VS Code Marketplace | Roadmap — not done |
| Native Windows (no WSL2) | Not planned for alpha |
| Docker image | Roadmap — not done |

See `roadmap/next/language_distribution.md` for the plan.
