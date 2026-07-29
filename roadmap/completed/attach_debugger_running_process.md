# Attach the Debugger to a Running Tesl Process

## STATUS: IMPLEMENTED (2026-07-29)

Option A landed in full: `dsl/debug/control-channel.rkt` (loopback NDJSON
control channel — unix socket with TCP fallback under `.tesl-stuff/`), pause
hardening in `checkpoint.rkt` (stop serialization + `TESL_DEBUG_PAUSE_TIMEOUT_MS`
auto-resume), `tesl run --debug` (+ debug/release bytecode mode marker),
real DAP `attach` (proxy mode; disconnect detaches and the app keeps serving),
`tesl debug-attach` CLI client (--once / --snapshot / --ping / --detach /
NDJSON bridge), VSCode/VSCodium first-class support (attach launch config,
config snippets, palette commands, zero-config resolver), MCP `tesl.debug_attach`
tool. Tests: `tests/dap-attach-smoke.rkt` (19 checks) +
`tests/dap-headless-persistent-smoke.rkt` (closes the session-started coverage
gap), both gated in ci.sh phase 10. Verified end-to-end: control-channel smoke,
wrapper e2e (arm→curl→stop→locals→detach→still serving), scripted DAP-client
attach session. Manual VSCodium F5 verification remains (extension re-publish
needed to ship the editor pieces).

**Status:** next (proposed 2026-07-29; feasibility explored, recommendation below)

## Background

Today every debug session — DAP from VSCodium, `tesl debug-inspect`, the MCP `tesl.debug_inspect` tool, the agent curl loop — must **launch the program itself**: compile into a temp dir, `dynamic-require` into the adapter's own Racket namespace, run. You cannot break into a server that is already running. Concretely:

* The DAP `attach` request is a launch alias by explicit decision (`dsl/debug/dap-server.rkt:970-979`: "no separate OS process to attach to … out of scope"). `supportsAttachRequest` is not advertised (`:824-832`) and `tesl init` never generates an attach config (`nix/tesl-cli-body.sh:551-573`).
* The headless inspector's persistent server mode (`dsl/debug/headless-inspect.rkt:457-476`) keeps a served app alive across many breakpoint hits — but breakpoints are fixed at launch via `--break-at` argv (`compiler/bin/main.ml:1455-1462`); there is no control loop to re-arm mid-session. (This mode is also untested and undocumented.)
* The gap is already acknowledged twice as deferred work — `.claude/commands/tesl-debug-curl.md` ("Not yet supported: arming a breakpoint on an already-running server without relaunching") and `roadmap/completed/ai_access_to_runtime_debug_info_and_other_data.md:17-19` — both pointing at `roadmap/later/further_editor_improvements.md`, **which does not exist**. This item is that missing home.

## Why this matters (value)

The goal is making a Tesl codebase as easy as possible to understand and debug — for humans and AI agents alike. Attach closes the biggest remaining friction:

* **The agent loop today is relaunch-per-question.** `tesl-debug-curl` requires killing your dev server, relaunching under the inspector with breakpoints decided up front, polling the port, then curling. Want a different breakpoint? Relaunch again. With attach: keep one dev server running all day, arm/re-arm freely, curl, inspect, move on. This is the single largest speedup available for the AI debugging workflow.
* **Humans get the "it only happens after the app has been running a while" class.** State accumulated over many requests (queues drained, caches warmed, SSE clients connected, auth sessions established) is exactly what a relaunch destroys. Attach preserves it.
* **VSCodium UX**: F5-attach to your already-running `tesl run --debug` terminal instead of the debugger owning the process lifecycle. Test Explorer keeps its launch flow; attach is additive.
* **Foundation for live domain inspection**: the DAP already renders Domain (queues/caches/SSE/workers) and SQL scopes when paused (`dap-server.rkt:1005-1035`); attach makes those views available against real accumulated state, not a fresh process.

## Feasibility — the one hard fact that makes this cheap

`thsl-src!` checkpoints are erased at **Racket expansion time**, gated on the `TESL_DEBUG` env var being set in the process that *loads* the `.rkt` (`dsl/debug/checkpoint.rkt:202-206`, `:613-621`). The Tesl emitter always emits the checkpoint calls (`checkpoint.rkt:15-32`). Two consequences:

1. **A normal `tesl run` server has zero checkpoints** — nothing to arm, no matter what transport we build. Attaching to an arbitrary production process is impossible without giving up the tested zero-release-cost guarantee (`tests/dap-sql-scope-smoke.rkt:36-41`). We keep that guarantee — see Non-goals.
2. **A server started with `TESL_DEBUG=1` has every checkpoint live**, using the *same emitted `.rkt`* — no recompile, no separate build flavor. The entire attach feature reduces to: (a) a debug-enabled dev-server mode, (b) a control channel into the existing in-process machinery (breakpoint hash `checkpoint.rkt:122`, event channel `:159`, resume channel `:163`), (c) a DAP client for that channel.

Caveat: `.zo` bytecode caches the expansion. A debug-enabled start must not reuse (or pollute) the release bytecode — separate `compiled/` root needed (see plan; composes with `.tesl-stuff/` from `different_output_location.md`).

## Options considered

**A. Debug-enabled dev server + control socket + DAP attach (recommended).** `tesl run --debug` starts the app with checkpoints live and a loopback control channel; DAP/inspector/MCP connect, arm, detach, reconnect at will. Moderate cost, no emitter changes, zero production residue.

**B. Extend persistent headless-inspect with a stdin/socket command loop only.** Smallest possible step (the NDJSON server mode is 90% there), agent-only value — no editor UX, still inspector-owns-the-process. Worth doing *as a milestone inside* Option A rather than instead of it: the control-protocol work is identical.

**C. Full production attach (arbitrary running process, PID/port).** Requires always-emitting runtime-gated checkpoints (kills the zero-residue property), a hardened auth story on the control channel, and production-safe pausing — `stop-the-world-suspend!` (`checkpoint.rkt:476-497`) freezing a live server's background threads is unacceptable, and on a non-debug process the registry is empty (`dsl/private/domain-registry.rkt:133-136`) so the request thread would park forever with no world-stop. **Rejected for now.**

**D. Status quo + docs.** Keeps the relaunch friction that two docs already call out as the deferred gap. Rejected.

## Verdict

**Good idea, in the Option-A scoping.** High value (agent loop + long-lived-state debugging), genuinely cheap because the expansion-time gate means no compiler/emitter work and no production cost, and it upgrades existing machinery rather than adding a parallel system. The production-attach ambition (Option C) should stay out of scope until someone actually needs it.

## Implementation plan (Option A)

### Phase 1 — debug control channel in the runtime debug stack

New `dsl/debug/control-channel.rkt` (or grown inside `checkpoint.rkt`): when the process-wide debug switch is on (`set-debug-active!`, `checkpoint.rkt:100-102`), listen on a **loopback-only** channel. Prefer a Unix domain socket at `<project>/.tesl-stuff/debug.sock` (composes with the new output-location item; falls back to `127.0.0.1:<port>` written to `<project>/.tesl-stuff/debug.port` if unix sockets are unavailable). Never a public route inside `serve` — the app's HTTP surface stays clean.

Wire protocol: NDJSON, mirroring what the machinery already speaks:
* Commands: `set-breakpoints {file, [{line, condition?, hit?}]}` (maps to the existing `hash-set!` shape, `dap-server.rkt:835-863`), `clear-breakpoints`, `continue | step-in | step-over | step-out` (existing resume verbs, `checkpoint.rkt:574-578`), `snapshot` (locals/domain/SQL of the paused thread — reuse `build-result-json`, `headless-inspect.rkt:328`), `detach` (disarm all, resume if paused, keep serving).
* Events: `stopped {file, line, locals, domain, sql}` bridged from `event-ch` (`checkpoint.rkt:159`), `resumed`, `detached`.

Concurrency hardening required by "server keeps running": `paused-thread-box` holds a single thread (`checkpoint.rkt:104-110`) and `last-stopped-event` is a single box (`dap-server.rkt:242`) — serialize stops (second thread hitting a breakpoint while one is paused queues behind a semaphore) as the minimal correct v1. Add an optional auto-resume timeout (env `TESL_DEBUG_PAUSE_TIMEOUT_MS`) so an abandoned attach session can't wedge the dev server forever — the parked `channel-get` at `checkpoint.rkt:568` currently has no bound.

### Phase 2 — `tesl run --debug`

In `nix/tesl-cli-body.sh` `run)`: `--debug` flag sets `TESL_DEBUG=1` for the `racket` child and points bytecode at a separate root (`PLTCOMPILEDROOTS` or a `compiled-debug/` sibling under the build dir) so debug and release `.zo` never mix — the existing `_tesl_freshen_bytecode` buildid logic (`nix/tesl-cli-body.sh:67-88`) is the pattern to follow. Print the control-socket path on startup.

### Phase 3 — real DAP `attach`

`dsl/debug/dap-server.rkt`: make `attach` (`:979`) take `{socket | port | project}` instead of `program`; skip `compile-debug` entirely; proxy setBreakpoints/continue/step/scopes over the control channel instead of in-process calls (`resume!` `:256-259` and the domain-registry reads `:56-70` become RPC in attach mode only — launch mode stays in-process and untouched). `disconnect` in attach mode = `detach`, **not** `(exit 0)` (`:1309-1315`). Advertise `supportsAttachRequest`. `_tesl_init_vscode` (`nix/tesl-cli-body.sh:531-577`) gains a third launch.json entry: `"request": "attach"`.

Known accepted limitation (same as launch mode today): threads list is the single paused thread and stack trace is one synthesized frame (`dap-server.rkt:981-989`) — real stacks are a separate item.

### Phase 4 — agent surface

* `tesl debug-attach` CLI verb (thin NDJSON client over the socket) so `tesl-debug-curl` becomes: arm via one command against the running server, curl, read the stopped event — no relaunch. Update `.claude/commands/tesl-debug-curl.md` and its "Not yet supported" section.
* MCP: add `tesl.debug_attach` (arm/snapshot/continue against a running server) alongside `tesl.debug_inspect` in `editor/tesl-mcp/tesl-mcp.rkt`; update `editor/tesl-mcp/README.md`.
* While here: add the missing test for the persistent NDJSON inspector mode (`session-started` has zero test/doc references today).

### Tests

* Racket smoke in `tests/` (joins the ci.sh phase-10 DAP suite, `ci.sh:1073-1120`): start an app with `TESL_DEBUG=1` + control channel, connect, arm a handler breakpoint, fire an in-process request, assert stopped event with locals, re-arm a *different* line mid-session, assert second stop, detach, assert server still serves.
* Zero-residue regression stays green: no `TESL_DEBUG` ⇒ no socket file created, checkpoints still spliced away (extend `tests/dap-sql-scope-smoke.rkt` pattern).
* Pause-timeout test: paused thread auto-resumes after the configured bound.
* Manual (documented, not automated): VSCodium F5-attach to a `tesl run --debug` terminal; curl triggers the breakpoint; detach leaves the server serving.

## Non-goals

* **Attaching to a process not started with `--debug`.** Checkpoints don't exist there (expansion-time erasure); making them always-present sacrifices the tested zero-release-cost guarantee. If demand appears, that is Option C — a separate decision.
* Remote (cross-machine) attach and any auth story beyond loopback/filesystem permissions.
* Real multi-frame stack traces and true multi-thread stop states — v1 serializes stops; the single-frame model matches launch mode.
* PID-based attach to arbitrary Racket processes.

## Acceptance criteria

* `tesl run --debug` → attach from VSCodium → breakpoint in a handler fires on a real curl with live locals/domain/SQL scopes → detach → server keeps serving with state intact.
* Breakpoints can be added, changed, and removed repeatedly against one running server (the tesl-debug-curl loop with zero relaunches).
* `tesl run` (no flag) has byte-identical behavior to today: no socket, no checkpoint residue, release bytecode untouched.
* Dangling references fixed: `tesl-debug-curl.md` and `ai_access_to_runtime_debug_info_and_other_data.md` point here instead of the nonexistent `roadmap/later/further_editor_improvements.md`.
