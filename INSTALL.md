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

## Optional: Use Cachix binary cache

To avoid long compilation times (especially for Racket dependencies), you can use the Tesl Cachix cache.
This is optional but recommended for faster installs.

First, install Cachix:

```bash
nix profile install nixpkgs/cachix
```

Then use the Tesl cache:

```bash
cachix use tesl
```

Once configured, subsequent installs will pull pre-built binaries from the cache.

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

The extension is published on [Open VSX](https://open-vsx.org). Search for **Tesl** in VSCodium's extension panel and install it.

The extension needs the `tesl-lsp` binary to be available. The default nix install already includes it:

```bash
nix profile install github:mtonnberg/tesl
```

This installs both the `tesl` CLI and the `tesl-lsp` language server. The extension will find `tesl-lsp` automatically, even when VSCodium is launched from the desktop rather than a terminal.

**Alternative — explicit path override:** if you need to point the extension at a specific LSP script, set `tesl.lspScript` in your VS Code settings to the absolute path of `tesl-lsp.rkt`.

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
