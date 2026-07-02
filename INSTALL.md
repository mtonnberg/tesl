# Installing Tesl

**Tesl is beta.** Expect breaking changes. The only supported install path today is Nix. A standalone binary installer and VS Code Marketplace publish are on the roadmap but not yet done.

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
#lang tesl
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
(parser → type-checker → proof-checker → emitter → Racket runtime):

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
| Native Windows (no WSL2) | Not planned for beta |
| Docker image (via `tesl build`) | Available — see [dev-docs/deploy.md](dev-docs/deploy.md) |

See `roadmap/discarded/language_distribution.md` for the plan.
