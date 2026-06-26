# The CI / Deployment Journey — Tesl apps to production

> **STATUS: SHIPPED (2026-06-26).** Re-scoped per the maintainer: the deployment
> story is **a Docker image you can just `docker run`** — *no runtime code changes*
> (no `/healthz`, no graceful-SIGTERM; the runtime already auto-creates its tables
> on boot). Shipped:
> - **`tesl build`** → a runnable OCI image in two flavours: **all-in-one**
>   (`--with-postgres`: app + embedded PostgreSQL + entrypoint, runs with no
>   external DB) and **app-only** (`--app-only`: connects to your own DB via env).
>   Built + `docker run` + curl-verified end-to-end (incl. auth/ownership proof
>   boundaries enforced inside the container).
> - Generated multi-stage Dockerfiles in `templates/docker/`; runtime config via
>   `PORT` / `TESL_POSTGRES_*`; tables auto-created on first boot.
> - **GitHub Actions reference** (`templates/docker/github-deploy.yml.example`) +
>   a full deploy guide (`dev-docs/deploy.md`, also in `tesl help manual`).
> - Verified through the **nix-installed** binary (`nix profile install` path), not
>   just the dev shell.
> - **Deferred** (add per platform if needed): health/readiness endpoints + graceful
>   SIGTERM (deliberately out of scope), Nix `dockerTools` reproducible twin,
>   multi-arch (arm64), PaaS adapters (`fly.toml` etc.), NixOS module, `raco distribute`.
>
> _Original proposal below (some specifics were stale — e.g. the runtime-contract
> workstream was dropped by design)._

> **Status:** Later · **Effort:** L–XL (infrastructure) · **Scope:** deploying a
> *web API written in Tesl* to a production environment — **not** distributing
> the toolchain to developers.

## Goal

A developer scaffolds a Tesl web API, writes some endpoints, and ships it to a
production environment **without hand-rolling deployment infrastructure**. The
target experience:

1. One build artifact that **runs anywhere** — any container host, PaaS, or k8s.
2. **Reproducible under Nix** for teams that want it.
3. **Zero Nix knowledge required** to deploy for teams that don't.

The journey should feel near-automatic: `tesl init` → `tesl build` → CI →
running service, with the platform-specific glue generated, not authored.

## Scope / non-scope

**In scope:** the deployable app artifact, its packaging (container + Nix twin),
the CI pipeline that produces and ships it, and the runtime contract it honours.

**Out of scope (assumed or tracked elsewhere):**

- `tesl init` / project manifest internals — **assumed** to exist as an adjacent
  item; this doc consumes a manifest, it does not design one.
- **Toolchain distribution** — covered by
  [language_distribution.md](language_distribution.md). That doc ships the *CLI
  to developers*; its "Path D Docker" wraps the CLI to **`tesl check` source**.
  **This doc is different**: it deploys the *user's running service*.
- Schema/data migrations — see [database-migrations.md](database-migrations.md).

## Current state — what we build on

The runtime story already exists; only the packaging/CI layer is missing.

- **Pipeline:** `.tesl` → OCaml compiler (`compiler/bin/main.ml`) → Racket
  (`compiler/lib/emit_racket.ml`) → runs on the **Racket runtime**. There is no
  standalone binary today.
- **Runtime dependencies to run an app:** Racket + the `tesl` compiler +
  the Tesl Racket collections + (optional) PostgreSQL. Configuration is via env
  vars (`TESL_POSTGRES_*`, `PORT`).
- **Web APIs are first-class:** `api` / `server` / `serve` blocks, auth, pub/sub
  via PostgreSQL `NOTIFY`, background queues, SSE, telemetry. `example/todo-api.tesl`
  is a complete service; `example/chat/` (`run-backend.sh`) demonstrates real
  production patterns including horizontal scaling (outbox + `SKIP LOCKED`).
- **A strong Nix base to reuse (`flake.nix`):**
  - `tesl-compiler` — the OCaml binary.
  - `tesl-racket` — lays out the `dsl`/`tesl`/`lang` collection trees and
    **pre-compiles `.rkt` → `.zo` via `raco make`** so the first run is instant.
  - `tesl-cli` / `tesl-lsp` wrappers inject `PLTCOLLECTS`/`PATH`.
- **The gaps:** no Dockerfile/OCI image, no GitHub Actions, no release/deploy
  automation, no `tesl build` artifact command.

## Central idea — one deployment contract, several packagers

Rather than couple Tesl to a single deploy mechanism, define **once** what a
deployable Tesl service *is*, then let multiple packagers target that contract.
This mirrors the seam philosophy of
[swappable-runtime-backend.md](swappable-runtime-backend.md): a small, explicit
boundary, with implementations on either side.

**The deployment bundle (the contract):**

- the compiled program + its transitive deps as **pre-compiled `.zo` bytecode**
  (reusing the `raco make` step already in the `tesl-racket` derivation),
- an **entrypoint** (which `serve` to start),
- a **pinned Racket runtime version**,
- an **env schema** (declared inputs: `PORT`, `TESL_POSTGRES_*`, secrets),
- a **health/readiness** convention and a **graceful-shutdown** convention.

A new `tesl build` command produces this bundle. Every packager below consumes
the *same* bundle, so the artifact is identical whether built by Docker or Nix.

## Options

| Option | Audience | Effort | Verdict |
|--------|----------|--------|---------|
| **1. Container-first (OCI image)** | Everyone — any Docker host / PaaS / k8s | M | **Recommended primary** |
| **2. Nix-native (NixOS module + `nix run`)** | Nix shops, self-hosted VMs | M | Complement to #1 |
| **3. PaaS convenience (`tesl deploy`)** | Solo devs / fastest path to a URL | S | Sugar on top of #1 |
| **4. `raco distribute` runtime-free tarball** | No-Docker, no-Nix targets | H | **Deprioritize** — defer to dist. Path B |

### Option 1 — Container-first (recommended)

The **OCI image is the universal artifact**. It runs unchanged on Fly.io,
Render, Railway, Cloud Run, ECS, Kubernetes, or a plain `docker run` host, and it
is the lingua franca every cloud already speaks — so it satisfies the
"no Nix required" requirement directly.

Two **equivalent** builders produce the same image against the same contract:

- **(a) Generated multi-stage Dockerfile** — no Nix on the user's machine. Stage 1
  builds with the `tesl` toolchain and runs `tesl build`; stage 2 is a slim Racket
  runtime base with the bundle copied in.
- **(b) `dockerTools.buildLayeredImage`** in the project flake — a
  **bit-reproducible twin** that reuses the existing `tesl-racket` derivation, for
  teams that want reproducibility and Cachix-cached layers.

Both emit an image honouring the runtime contract (`PORT`, env, `/healthz`).

### Option 2 — Nix-native

For Nix/NixOS shops: a flake `packages.default` runnable via `nix run`, plus a
**NixOS module** that wires the service into **systemd** (env, restart policy,
dependency on PostgreSQL). Complements Option 1 for self-hosted VMs.

### Option 3 — PaaS convenience layer

A thin `tesl deploy` that wraps Option 1's image and generates platform configs
(`fly.toml`, Railway/Render) so a solo dev goes from `tesl init` to a live URL in
one command. Pure sugar — no new runtime path.

### Option 4 — `raco distribute` tarball (deprioritized)

A runtime-free tarball (app + bundled Racket) + install script / systemd unit,
for targets with neither Docker nor Nix. High effort and cross-platform-fragile;
overlaps [language_distribution.md](language_distribution.md) **Path B**. Defer
there rather than duplicate.

## Recommended journey (OCI-first happy path)

```
tesl init            # assumed: scaffolds app + manifest (tracked separately)
   ↓
tesl build           # → deployment bundle (.zo bytecode + entrypoint + contract)
   ↓
package              # (a) generated Dockerfile   OR   (b) flake dockerTools twin
   ↓                 #     → identical OCI image
CI (GitHub Actions)  # check → test → build image → push GHCR → deploy
   ↓
run anywhere         # docker run / Fly / Render / Cloud Run / k8s
```

The eventual doc/PR ships concrete sketches for each box: the multi-stage
Dockerfile, the `dockerTools` twin, the GitHub Actions workflow (with a Nix +
Cachix variant), and the runtime contract (`PORT`, env schema, `/healthz`).

## Workstreams

| # | Workstream | Effort | Payoff |
|---|-----------|--------|--------|
| 1 | **Runtime-contract spec** — entrypoint, env schema, port, health, shutdown | S | Single boundary every packager targets |
| 2 | **`tesl build` command** — emit the bundle; reuse `raco make` precompile | M | One artifact, instant cold start |
| 3 | **Base runtime image** — slim Racket + Tesl collections, published to GHCR | M | Tiny per-app Dockerfiles; shared cached layer |
| 4 | **Generated multi-stage Dockerfile** template | S | No-Nix path; universal artifact |
| 5 | **`dockerTools` reproducible twin** in the project flake | M | Bit-reproducible image for Nix shops |
| 6 | **Production conventions** — config-from-env, `/healthz`/readiness, graceful SIGTERM | S–M | Real orchestrators (k8s/Fly) need these — see open Qs |
| 7 | **GitHub Actions reference workflow** + Nix/Cachix variant | M | The "CI" in the journey; check/test/build/push/deploy |
| 8 | **PaaS adapters** — `fly.toml` / Railway generators | S (optional) | Fastest path to a live URL |
| 9 | **NixOS module / systemd unit** | M (optional) | Self-hosted Nix deploys |
| 10 | **Docs + worked example** — deploy `example/todo-api.tesl` end-to-end | S | Proves the journey; copy-paste starting point |

## Sequencing

1 (contract) → 2 (`tesl build`) → 3 (base image) → (4, 5) packagers →
6 (prod conventions) → 7 (CI) → (8, 9) optional targets → 10 (docs/example).

## Open questions

- **Bundling strategy:** container base image vs `raco distribute` — image size
  (Racket is ~200 MB), layer split, and Cachix strategy to keep pulls fast.
- **Runtime support gaps:** `dsl/web.rkt` currently has **no** SIGTERM/graceful
  shutdown, health, or readiness handling (verified). Workstream 6 likely needs
  runtime changes, not just conventions.
- **Multi-arch:** build `arm64` images in CI (Apple silicon, Graviton, Ampere)?
- **Secrets / config:** the convention for injecting DB creds and secrets at
  deploy time across Docker, Fly, and NixOS.
- **Migrations at deploy:** ordering of schema migration vs rollout — depends on
  [database-migrations.md](database-migrations.md).
- **Cold-start budget:** target first-request latency with vs without baked-in
  `.zo` bytecode.

## Out of scope

- `tesl init` / manifest internals (assumed adjacent item).
- Toolchain distribution to developers — [language_distribution.md](language_distribution.md).
- A package registry — [package_manager.md](package_manager.md).
- Windows-native targets (WSL2 + container is the supported path).

## Relationships

- **Distinct from** [language_distribution.md](language_distribution.md) — that
  ships the CLI to developers; this deploys the user's service. Its Path B
  (static binary) absorbs Option 4 above.
- **Depends on** the separate scaffolding/manifest item for the `tesl init` start.
- **Touches** [database-migrations.md](database-migrations.md) (deploy-time
  migrations) and [swappable-runtime-backend.md](swappable-runtime-backend.md)
  (the contract/seam philosophy, and a future non-Racket backend would change the
  base runtime image).
