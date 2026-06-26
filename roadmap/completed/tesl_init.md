# tesl init — zero-to-running Tesl project in one command

> **STATUS: SHIPPED (2026-06-26).** Shipped:
> - **`tesl init [name] [--template minimal|api] [--postgres managed|existing|none]
>   [--yes] [--no-git]`** — scaffolds a runnable project from `templates/{minimal,api}`:
>   `app.tesl` + `tesl.toml` manifest + `.env` + `.gitignore` + `README.md` +
>   `AGENTS.md`/`CLAUDE.md` (with MCP-server + agent-skills onboarding guidance).
>   Friendly guided prompt when flags are omitted; welcoming next-steps message.
> - **`tesl.toml`** manifest (`dev-docs/tesl-manifest.md`) + dependency-free reader
>   `scripts/tesl-manifest.sh` — the shared seam `tesl build` consumes.
> - **`tesl db start|stop|status`** — managed project-local PostgreSQL (binaries via
>   the flake `postgresql` output); auto-starts on `tesl run` in managed mode; `tesl
>   run` auto-loads `./.env` so a fresh project connects with no manual sourcing.
> - Works from the **nix-installed** binary (`nix profile install github:mtonnberg/tesl`
>   → `tesl init` → `tesl run`/`tesl build`): templates + collections are bundled into
>   the derivation, and the CLI body is de-duplicated into `nix/tesl-cli-body.sh` so
>   `flake.nix` and `shell.nix` share one source (can't drift). Verified out-of-repo.
> - **README 3-step quick start** above the fold (install Nix → `nix profile install`
>   → `tesl init`).
> - **Deferred:** `ssr`/`full`/`ai` templates; deploy-target plugin registry beyond
>   `local`/`container`.
>
> _Original proposal below._

> **Status:** Later · **Effort:** M (CLI + templates) + S (managed-PG seam) +
> M (deploy plugins) · **Scope:** project scaffolding, the local-Postgres
> decision, and a deploy-target plugin seam — **not** the deploy artifact itself
> (that's [ci_journey.md](ci_journey.md)).

## Why now

Onboarding today is "install the Nix flake plus the VSCodium extension." After
that, a new user faces a blank page: they must hand-author a `.tesl` file **and**
stand up PostgreSQL before a single request is served. The blank-page problem and
the "now go configure a database" tax are the first two things every newcomer
hits, and they hit them before Tesl has had a chance to show what it's good at.

The bet of this item is that one command should erase both. After a single-command
install (out of scope here — see [language_distribution.md](language_distribution.md)),
`tesl init` produces a **working full app**, giving two three-command journeys:

```
install  →  tesl init  →  tesl run app.tesl     # a working Tesl app, locally
install  →  tesl init  →  tesl package          # a deployable image
```

`tesl package` / `tesl build` itself is owned by [ci_journey.md](ci_journey.md);
this item's job is to guarantee its input — a runnable app plus a project manifest.

## Goals & success criteria

- `tesl init <name>` produces a directory that **validates and runs** with the very
  next command, for whichever template was chosen.
- `tesl init → tesl run app.tesl` works with **zero manual Postgres setup** when the
  user picks managed Postgres, and with **zero external dependency at all** for the
  `minimal` (no-DB) template.
- `tesl init → tesl package` has everything `tesl build` needs: the app plus a
  project manifest (entrypoint, env schema, deploy target).
- Managed Postgres **never installs anything globally** and is fully removed by
  deleting the project directory.
- **Nix stays invisible.** A developer who chooses managed Postgres never types a
  `nix` command and need not know Nix is involved — unless they want to.
- **It feels welcoming and never leaves you stuck.** Every surface — the init
  message, the README, in-file comments, help, and errors — ends with an obvious
  next step, and a coding agent pointed at the repo knows what to do immediately.
- **The proof system shines through.** Templates demonstrate Tesl's signature power
  — input/output proofs and value-level, combined, and record-wide proofs — as an
  empowering payoff, introduced gradually so a newcomer feels it without being
  overwhelmed.
- We have guided the install/usage of the Tesl MCP-server for debugging and development + the agent skills

## Current state — what we build on

Almost everything `tesl init` needs already exists; only the scaffolding seam and
the managed-Postgres lifecycle are missing.

- **CLI shape.** The OCaml binary `compiler/bin/main.ml` dispatches by
  pattern-match; higher-level verbs (`run`, `test`, `watch`, `compile`) are a bash
  wrapper today (`shell.nix`). [improved_devx.md](../next/improved_devx.md) anchors
  `tesl init`'s entry near `compiler/lib/compile.ml`.
- **What a running app needs.** A `.tesl` file (module + imports + `api`/`server` +
  `main with capabilities […] { serve … on PORT }`) and, if it declares a
  `database` block, a reachable Postgres via `TESL_POSTGRES_*` env vars. Schema and
  tables are **auto-created at runtime** — `dsl/sql.rkt`'s `ensure-database-ready!`
  → `postgres-ensure-entity!`, plus the system tables `tesl_jobs`,
  `tesl_pubsub_outbox`, `tesl_cache`, `tesl_email_outbox`. No migration step is
  required for the first run.
- **A managed-Postgres precedent already exists.** `scripts/postgres-init.sh`
  (`initdb -A trust` into `.tesl-postgres/data`) and `scripts/postgres-start.sh`
  (`pg_ctl … -k <socketdir> -p 55432`, then `createdb`) already spin up a
  project-local instance. The managed mode below generalizes exactly this into the
  CLI, with Nix supplying the binaries instead of assuming a dev shell.
- **Templates to copy from.** `example/admin-task-api.tesl` (≈80 lines, no DB),
  `example/todo-api.tesl` (entity + DB + codec + proofs + auth + tests), and
  `example/queue-api.tesl` + `example/chat/chat-backend.tesl` (workers + SSE).
- **The gap.** Nothing scaffolds a project, there is no project manifest, and there
  is no CLI-owned database lifecycle.

## What `tesl init` generates (per project)

- **`app.tesl`** (or `<name>.tesl`) — a complete, valid program for the chosen
  template.
- **A project manifest** (e.g. `tesl.toml`) — the seam [ci_journey.md](ci_journey.md)
  consumes: app name, entrypoint server, declared env schema (`PORT`,
  `TESL_POSTGRES_*`), template id, Postgres mode, and deploy target + active deploy
  plugin(s).
- **`.env` / `.envrc`** with sensible local defaults — `TESL_POSTGRES_*` pointing at
  the managed instance, or placeholders for bring-your-own.
- **`.gitignore`** (ignoring `.tesl-postgres/` and `.env`), a warm template-specific
  **`README.md`**, an **`AGENTS.md` / `CLAUDE.md`** agent guide, and — for managed
  Postgres — the project-local database scaffolding.

## The Postgres decision (the crux)

Postgres is a **choice, not an assumption**. `tesl init` asks; flags override.
Three modes:

| Mode | When | What `tesl init` does | What `tesl run` does |
|---|---|---|---|
| `managed` *(recommended default for DB templates)* | "Set one up for me" | Writes `.env` pointing at a project-local instance under `.tesl-postgres/`; records `managed` in the manifest | Ensures the project-local Postgres is initialized and running (lazy `initdb` + `pg_ctl` into the project dir), **binaries supplied by Nix transparently**, then serves; tables auto-created by `ensure-database-ready!` |
| `existing` | "I have a Postgres" | Prompts for / templates the `TESL_POSTGRES_*` connection vars into `.env`; manifest records `existing` | Connects to the user's instance; auto-creates the app's schema/tables on first run |
| `none` | `minimal` template / no DB | No `database` block, no `.env` Postgres vars | Runs immediately, with no external dependency |

**How managed Postgres stays invisible-Nix.** Generalize
`scripts/postgres-{init,start}.sh` into a CLI-owned lifecycle (`tesl db
start|stop|status`, auto-invoked by `tesl run` when the manifest says `managed`).
The Postgres binaries (`initdb`, `pg_ctl`, `createdb`) come from a pinned Nix
expression the CLI shells out to (a `nix run`-style invocation) — surfaced to the
user only as `starting local database…`. Data and socket live under the project's
`.tesl-postgres/` (trust auth, a non-default port, a Unix socket), so nothing
global is touched and `rm -rf` of the project removes it entirely.

For environments without Nix, document a fallback (point at an existing Postgres, or
a generated `docker-compose.yml`) as a **secondary** path — but managed-via-Nix is
primary, because it is the one that keeps the promise "the dev never has to think
about a database."

## Deployment target (a plugin axis)

A third interactive question: *"Where will this deploy?"* The default is `local`.
Crucially, **providers are plugins, not core** — the core CLI defines a small
deploy-target adapter interface and ships only `local`; every other provider is a
separately-versioned plugin that contributes (a) the init-time scaffolding and
(b) the package-time glue consumed by [ci_journey.md](ci_journey.md)'s
`tesl build` / package step.

| Target | Plugin? | What `tesl init` drops in (target recorded in the manifest) |
|---|---|---|
| `container` *(default)* | core | nothing extra — `tesl run` + managed/existing Postgres |

### Future addition (deferred for now)

| `kubernetes` | plugin | Deployment / Service / Ingress manifests, `/healthz` readiness wiring, env from Secret/ConfigMap |
| `azure` | plugin | Container Apps / App Service config + registry wiring |
| `digitalocean` | plugin | App Platform spec (`.do/app.yaml`) |
| `heroku` | plugin | `heroku.yml` / container stack config |
| `fly` *(likely)* | plugin | `fly.toml` |

The **OCI image is the universal artifact** ([ci_journey.md](ci_journey.md)), so
every plugin targets that one contract and only emits provider-specific deploy
descriptors on top — they do **not** each re-invent building. Keeping providers out
of the core is the whole point: the language never grows an "Azure" concept, and the
provider list grows without touching the compiler. Plugin distribution is an open
question (overlaps [package_manager.md](package_manager.md)); the first cut can
bundle two or three first-party plugins while defining the interface that makes
third-party ones possible.

## Templates

A menu, not a single scaffold — each template is a real, runnable program derived
from the `example/` corpus, chosen at init (or via `--template <name>`).

| Template | Postgres default | DB / entities | Auth | Codec + proof validation | Tests | Workers / queue | SSE / pub-sub | Cache | Email | Telemetry | Based on |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **`minimal`** — show how lightweight Tesl can be | `none` | – | cookie | – | – | – | – | – | – | ✓ | `admin-task-api.tesl` |
| **`api`** — the canonical DB-backed CRUD app *(default)* | `managed` | ✓ | ✓ | ✓ | ✓ | – | – | – | – | ✓ | `todo-api.tesl` |
| **`ssr`** — server-streamed responses (SSE) | `managed` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – | – | ✓ | `chat/chat-backend.tesl` + `queue-api.tesl` |
| **`full`** — the kitchen sink | `managed` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | composed |
| **`ai`** — *gated on [ai_features.md](ai_features.md)* | `managed` | ✓ | ✓ | ✓ | ✓ | ✓ (agent loop) | ✓ (token stream) | optional | – | ✓ | `ai_features.md` worked example |

The `ssr` template showcases one of Tesl's signature features — **server-streamed
responses** over Server-Sent Events (`channel` + `publish` + `sse … subscribe`), the
same mechanism `example/chat/chat-backend.tesl` uses for live rooms. Its hook is a
**self-feeding worker** that re-enqueues itself and publishes to a channel, so a
subscribed client watches the response **grow and grow** in real time — a vivid,
minimal demo of the streaming model (workers/queues appear here in service of that
demo; the broader queue/dead-letter surface lives in `full`). "SSR" here means
server-*streamed* responses, not server-side HTML templating.

The remaining design choice is **deliberate, not a gap**: there is no WebSocket
template because **WebSockets are an intentional non-goal** — SSE is Tesl's chosen
real-time primitive (standard HTTP, same port, native `EventSource`, automatic
reconnect), so `ssr` shows it off with pride rather than as a fallback. The `ai`
template ships only once the `agent {}` block, `ask`, and the auto-mounted MCP
server from [ai_features.md](ai_features.md) exist.

### Templates must showcase the proof system — without overwhelming

Demonstrating proofs is a first-class objective of the corpus, dialed up by tier:

- **Input proofs** — untrusted JSON coerced into proof-carrying values through
  `codec` + `via` check chains — and **output proofs** — return types that *prove* a
  property, e.g. `List Todo ? ForAll (FromDb (OwnerId == requestUser.id))`.
- **Value-level** proofs (`String ::: ValidOrderId orderId`), **combined** proofs
  (conjunctions like `via (isSafeTitle && lengthLessThan30)`), and **record-wide /
  per-field** proofs (a `record` whose fields each carry their own `:::` facts).

The teaching dial: `minimal` and `api` introduce one clear input proof and one
output proof, with friendly comments explaining the payoff ("this value is *proven*
valid everywhere it flows — you never re-check it"); `ssr` and `full` layer in
combined and record-wide proofs. Comments and the `tesl help quickstart` topic
explain *why* a proof earns its keep, so the feature feels empowering rather than
ceremonial — never a wall of syntax dropped on a newcomer.

## Welcoming, guided onboarding (tone & next-step guidance)

The scaffold is not just files — it is a **friendly guide that never leaves the dev
stuck**. Inspiration: Elm's famously kind compiler and onboarding, Rust's
`cargo new` warmth, the delightful create-flows of Astro and Vite — and then take
it further. Every surface points to the obvious next step with zero friction.

- **A guided, paced prompt with visible progress** — the interactive flow shows how
  far along you are with a text-based progress bar, so it never feels open-ended.
  Each question carries its position and a one-line "why we ask," e.g.:

  > Question 2 of 5  `[██░░░]`
  > **Database** — where should your app store data?
  >   › Set one up for me *(recommended — no install, lives in this project)*
  >     I'll connect my own Postgres
  >     No database

  (The five questions: template → database → deploy target → comment level →
  confirm. The bar shrinks to the questions actually needed — picking the `minimal`
  template skips the database question and the bar re-scales.)

- **`tesl init` completion message** — celebratory and concrete, tailored to the
  chosen template and Postgres/deploy mode. For example:

  > ✨ Created `my-app` with the **ssr** template.
  > Next: `cd my-app && tesl run app.tesl`, then open the streaming page.
  > Tinker: open `app.tesl` and put your name on line 34 — watch it stream in.
  > Learn the streaming flow: `tesl help quickstart ssr`
  > More on anything: `tesl help manual`
  > Stuck? We're friendly — https://github.com/mtonnberg/tesl/discussions

- **Generated `README.md`** — short, warm, template-specific: what this app does,
  the exact one or two commands to run it, "try changing X on line N," where to
  learn more (`tesl help manual`, `tesl help quickstart <template>`), and the
  discussions link. It reads like a friend walking you through it, not reference
  docs.
- **In-file guidance, at a comment level the dev chooses** — `tesl init` asks how
  much narration the scaffold should carry (override `--comments`):
  - **`verbose`** — "I like a lot of describing comments": generous explanation on
    most constructs, ideal for learning the language.
  - **`highlights`** *(default)* — "little comments for the highlights": friendly
    notes only at the natural first-edit spots (`👋 change this →`) and on the one or
    two showcase proofs, dissolving the blank-page paralysis without clutter.
  - **`none`** — a clean file for someone who just wants the code.

  The same setting feeds the proof-teaching dial above: `verbose` spells out *why*
  each proof earns its keep; `highlights` keeps a single payoff note; `none` leaves
  the proofs to speak for themselves.
- **`tesl help quickstart <template>`** — a new help topic per template (riding the
  [improved_devx.md](../next/improved_devx.md) help-system overhaul) that gives a
  guided "do this, then this" path through that template's concepts — workers and
  queues, SSE, auth + proofs.
- **LLM / agent guidance (Claude Code & co.)** — the scaffold drops an `AGENTS.md` /
  `CLAUDE.md` (and a clearly-marked README section) telling a coding agent exactly
  what this project is, how to run and check it (`tesl run`, `tesl check`, `tesl
  help manual full`), the capability/proof gotchas to watch for, and what a good
  "next change" looks like — so an agent the dev points at the repo is productive
  immediately. This coordinates with [ai_features.md](ai_features.md)'s Goal B (Tesl
  as the safest target for AI to write) and `improved_devx.md`'s AI-legible help
  surface.
- **Consistent friendly voice everywhere** — prompts, success and error lines, and
  docs share one encouraging tone; every dead-end ends with a pointer
  (`tesl help …`) and, when truly stuck, the discussions link. This is an explicit,
  reviewable bar: *no surface should ever leave the developer without an obvious
  next step.*

## CLI surface

- `tesl init [name] [--template api|minimal|ssr|full] [--postgres
  managed|existing|none] [--deploy local|kubernetes|azure|digitalocean|heroku|fly]
  [--comments verbose|highlights|none] [--yes] [--no-git]` — interactive when flags
  are omitted; fully non-interactive with flags plus `--yes` (CI-friendly).
- `tesl db start|stop|status` — the managed-Postgres lifecycle, auto-invoked by
  `tesl run` when the manifest says `managed`.
- **Anchors:** command dispatch in `compiler/bin/main.ml` / `shell.nix`; init logic
  near `compiler/lib/compile.ml` (per `improved_devx.md`); templates sourced from
  `example/`; the database lifecycle generalized from `scripts/postgres-*.sh`.

## Workstreams

| # | Workstream | Effort | Payoff |
|---|-----------|--------|--------|
| 1 | **Template corpus** — curate `minimal`/`api`/`ssr`/`full` from `example/`, kept green by the existing example-compile tests | M | The runnable starting points; the proof showcase |
| 2 | **`tesl init` command** — arg parse, interactive prompt, file emission, manifest write | M | The one command itself |
| 3 | **Managed-Postgres lifecycle** — CLI-owned `initdb`/`pg_ctl` into the project dir, Nix binary sourcing, `tesl db *` + auto-start on `tesl run` | S–M | Zero-setup local DB; invisible Nix |
| 4 | **Project manifest (`tesl.toml`)** — define the schema `ci_journey.md` consumes (entrypoint, env schema, PG mode, deploy target) | S | The seam to packaging/deploy |
| 5 | **Deploy-target plugin interface + first-party plugins** — define the adapter seam; ship `local` (core) plus 2–3 bundled plugins (e.g. `kubernetes`, one PaaS) | M | Extensible deploy targets without bloating core |
| 6 | **Welcoming guidance layer** — friendly init message, template `README.md`, in-file "👋 change this" comments, `tesl help quickstart <template>`, and the `AGENTS.md`/`CLAUDE.md` agent guide; one friendly voice + a next-step pointer on every surface | S–M | The delightful, never-stuck experience |
| 7 | **Docs + worked walkthrough** — both three-command journeys, end to end | S | Proves the journey; copy-paste start |
| 8 | **`ai` template** — *deferred*, lands with `ai_features.md` | S (when unblocked) | The AI-first showcase |

## Sequencing

1 (templates) → 2 (init) → 3 (managed Postgres), with 4 (manifest, shared with
`ci_journey.md`) in parallel. 5 (deploy plugins) follows 4 and coordinates with
`ci_journey.md`'s packaging. 6 (welcoming guidance) is layered alongside 1–2 once
templates exist → 7 (docs). 8 follows [ai_features.md](ai_features.md).

## Open questions

- **Manifest format/owner** — `tesl.toml` versus reusing an existing config notion;
  align with `ci_journey.md`'s "consumes a manifest."
- **Managed-PG binary delivery when Nix is absent** — does the install step
  guarantee Nix? If not, is `docker-compose` the documented fallback, or do we
  vendor a static Postgres?
- **Multi-file vs single-file scaffolds** — does `full` split into modules?
- **Port-selection ergonomics** — env `PORT` versus a prompt versus a fixed default
  per template.
- **Implicit DB start** — is `tesl run` auto-starting Postgres surprising? Explicit
  `tesl db start` versus implicit, with an opt-out flag.
- **Deploy-plugin distribution** — bundled-only at first versus a real plugin
  registry (overlaps [package_manager.md](package_manager.md)); what the adapter
  interface must expose; the split of "who builds" versus "who emits the descriptor"
  with `ci_journey.md`.

## Relationships

- **Feeds** [ci_journey.md](ci_journey.md) — provides the scaffold and manifest its
  `tesl build` / package step assumes; deploy-target plugins emit the descriptors
  its packaging consumes.
- **Implements** workstream 2 of [improved_devx.md](../next/improved_devx.md).
- **Gated dependency** — the `ai` template depends on [ai_features.md](ai_features.md).
- **Touches** [database-migrations.md](database-migrations.md) (first-run
  auto-create versus managed migrations), [language_distribution.md](language_distribution.md)
  (the out-of-scope install step that precedes `tesl init`), and
  [package_manager.md](package_manager.md) (deploy-target plugin distribution).
