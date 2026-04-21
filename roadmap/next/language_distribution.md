# Language Distribution Roadmap

## Goal

A developer discovers Tesl, runs one command, and has a working `tesl` CLI with
compiler, formatter, linter, and LSP — ready to build and run a web API in
minutes. No Racket knowledge needed, no manual path wiring.

## Current State

- `shell.nix` provides a working dev shell with `tesl` CLI, Racket, OCaml, and Postgres.
- The `tesl` CLI wrapper handles compile/check/lint/fmt/run/test/watch.
- No `flake.nix` yet — users cannot `nix run` or `nix profile install`.
- The VS Code extension is local-only (not published).
- No pre-built binaries for non-Nix users.

---

## Path A: Nix Flakes (Recommended first step)

**Why:** The project already uses `shell.nix`. Converting to a Flake is the
lowest-effort path to making Tesl installable with one command.

### Steps

| Step | What | Effort |
|------|------|--------|
| A1 | Create `flake.nix` with `packages.tesl-cli`, `packages.tesl-lsp`, `devShells.default` | Medium |
| A2 | Set up Cachix binary cache (free for open-source) to avoid Racket compile times | Low |
| A3 | Verify `nix run github:user/tesl` works end-to-end | Low |
| A4 | Add `nix profile install` and `home-manager` module instructions to README | Low |

**Result:** `nix run github:user/tesl -- help` just works. Developers on
NixOS/nix-darwin/WSL2+nix get the full toolchain instantly.

**Risk:** Nix audience is small (~5% of developers). Sufficient for early
adopters but not for mainstream reach.

---

## Path B: Static Binary + Install Script

**Why:** Reaches developers without Nix. The OCaml compiler is a single native
binary; the Racket runtime can be bundled.

### Steps

| Step | What | Effort |
|------|------|--------|
| B1 | Build static OCaml compiler binary (musl-linked, no glibc dep) | Medium |
| B2 | Bundle Racket runtime + Tesl stdlib into a self-contained tarball | High |
| B3 | Create `install.sh` that downloads tarball + adds `tesl` to PATH | Medium |
| B4 | GitHub Actions CI: build release tarballs for Linux x86_64, aarch64, macOS | Medium |
| B5 | Add `curl -sSf https://tesl.dev/install.sh \| sh` to README | Low |

**Result:** `curl ... | sh` gives a working `tesl` on any Linux/macOS.

**Risk:** Bundling Racket is non-trivial (~200MB). Need to verify `raco exe`
or `raco distribute` can produce a standalone runtime. May need to strip
unused collections.

---

## Path C: VS Code / Open VSX Extension

**Why:** Most developers discover languages through their editor. A published
extension with bundled LSP removes the "install three things" friction.

### Steps

| Step | What | Effort |
|------|------|--------|
| C1 | Package LSP binary inside the extension (platform-specific `.vsix`) | Medium |
| C2 | Publish to VS Code Marketplace via `vsce` | Low |
| C3 | Publish to Open VSX Registry (for VSCodium users) | Low |
| C4 | Auto-download `tesl` CLI if not found in PATH | Medium |

**Result:** `ext install tesl-lang` in VS Code gives syntax highlighting,
diagnostics, go-to-definition, and formatting. Extension prompts to install
the CLI if missing.

**Risk:** Maintaining platform-specific extension builds (linux-x64, darwin-x64,
darwin-arm64, linux-arm64) adds CI complexity.

---

## Path D: Docker Image (Deferred)

**Why:** For CI/CD pipelines and users who don't want to install anything.

```
docker run --rm -v $(pwd):/app ghcr.io/user/tesl check src/MyApi.tesl
```

Low priority — most useful once Path A or B is done (the Docker image just
wraps the installed binary).

---

## Path E: Online Playground (Deferred)

**Why:** Zero-install "try Tesl in 30 seconds" experience. See
`roadmap/later/online_editor_to_drive_adoption.md`.

Depends on Path B (needs a deployable Tesl binary) and a hosted service.
Highest impact for adoption but highest effort.

---

## Recommended Sequence

1. **Path A** (Nix Flakes) — immediate, low effort, unblocks contributors
2. **Path C** (VS Code extension) — highest developer-experience impact
3. **Path B** (Static binary) — reaches the mainstream, enables Path D and E
4. **Path D** (Docker) — CI/CD story
5. **Path E** (Playground) — adoption driver

Path A and C can be done in parallel. Path B is the critical prerequisite for
reaching developers outside the Nix ecosystem.

---

## Non-Goals (for now)

- **Package managers** (npm, brew, apt): Premature until the language stabilises.
  See `roadmap/later/package_manager.md`.
- **Windows native**: WSL2 is the supported path. Native Windows would require
  porting the Racket runtime setup.
- **Language server protocol via stdio only**: Current LSP already uses stdio;
  no TCP/WebSocket variant needed.
