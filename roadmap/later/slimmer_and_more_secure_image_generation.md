# Slimmer and more secure container image generation

## Background

`security_review.md` (2026-08-02) flagged that both `templates/docker/*.tmpl` images run on the full `racket/racket:*-full` base (Debian, apt, bash, coreutils, a package manager — everything present after `docker exec`). The non-root `USER` fix (M4) closed the "runs as root" gap, but the base image is still a large, general-purpose Debian userland: a shell to pivot into post-RCE, a package manager to fetch tools with, and a big dependency/CVE surface unrelated to what a Tesl app actually does at runtime.

A follow-up discussion explored the realistic ceiling for the **app-only** image (external Postgres, no embedded DB, a Tesl app that talks to its database and an OTel collector — no bash bootstrap script needed the way the all-in-one image's embedded-Postgres entrypoint does). Findings, verified against the actual base image rather than assumed:

- The `racket` binary itself only needs glibc core (`libc`, `libm`, `libpthread`, `librt`, `libdl`) — a small, stable dependency surface.
- Racket's `openssl` collection (used by `tesl/http-client.rkt`, `tesl/jwt.rkt`, `tesl/crypto.rkt`, `tesl/email.rkt`) needs `libssl`/`libcrypto` — Racket ships its **own** pinned copies at `/usr/lib/racket/lib{ssl,crypto}.so.1.1`, separate from the system's `libssl.so.3`. Worth tracking as its own supply-chain question (is Racket's bundled 1.1 branch patched promptly upstream?), independent of whatever base image is chosen.
- `libsodium` is not present in the base image at all — it's added via `apt-get install libsodium-dev` in both current Dockerfiles.
- The `db` library speaks the Postgres wire protocol in pure Racket — **no `libpq` dependency at all**. One fewer native library to carry into a minimal image.
- CA certificates are present in the base image (needed for TLS server-cert verification against the DB/OTLP collector/webhooks).
- Investigated Chiseled Ubuntu and Chainguard/Wolfi as ready-made minimal bases: neither has a Racket package. Wolfi's live APKINDEX was checked directly (not from memory) — no `racket` or Chez Scheme package exists, only an unrelated `chezmoi` (dotfiles tool). Using either would mean hand-rolling and maintaining a from-scratch Racket package build against that distro's toolchain — a real ongoing engineering cost, not a Dockerfile tweak, and not a fit for a generic init/starter template.

## Goal

Reduce the runtime attack surface of Tesl's generated container images as far as realistically achievable with off-the-shelf components, generically, for every Tesl user's app-only deployment — without asking anyone to maintain a custom OS package build. Layer this with hardening that lives outside the image (runtime flags, kernel-level sandboxing) and, distinctively, use the compiler's own capability system to constrain network egress more precisely than a hand-maintained allowlist ever could.

## Chosen direction

Three layers, roughly in priority order:

### 1. Distroless multi-stage build (the main lift)

Build stage stays on the full `racket/racket:*-full` image (or Debian + installed Racket): compile the app with `raco exe` / `raco distribute` to produce a self-contained executable. Final stage: `gcr.io/distroless/base-debian12:nonroot` (glibc present, CA certs present, a nonroot user baked in, **no shell, no package manager, no coreutils**). Copy in only the compiled binary plus `libssl.so.1.1` / `libcrypto.so.1.1` / `libsodium.so`.

Payoff: post-RCE, an attacker has no shell to pivot with and nothing to fetch tools with — this closes off a large, common class of post-exploitation technique regardless of what the initial bug was.

**Open wrinkle to validate before committing to this, not assume away:** several runtime modules (SSO, OTel/traces) use `dynamic-require` with a compile-time-fixed module path specifically to dodge a `require` cycle (see `dsl/otel.rkt`, `dsl/traces.rkt`, `dsl/web.rkt`'s SSO lazy-load). Need to confirm `raco exe`'s static dependency walk actually captures those and embeds them — if it doesn't, those modules 404 at runtime in a collects-less image, and either the dependency needs restructuring or the relevant collections need to ship alongside the binary instead of being embedded.

**Concrete finding, verified against the current templates: the image ships a full remote-debugger stack it has no runtime need for.** `templates/docker/README.md` is explicit that staging always copies **both** `dsl/` and `tesl/` wholesale — "always both". But `dsl/` contains `debug/`: `dap-server.rkt`, `attach-client.rkt`, `control-channel.rkt`, `headless-inspect.rkt`, `domain-inspect.rkt`, `checkpoint.rkt`, `value-tree.rkt` — the live-attach DAP debugger (`tesl run --debug`) implementation, plus `dsl/test-support.rkt` (733 lines) and `dsl/load-test.rkt` (236 lines), pure dev/test harness code. None of this is required by an ordinary compiled `app.rkt` at runtime; `compiler/lib/compile.ml` only reaches `dsl/debug/headless-inspect.rkt` as a distinct driver when the app is compiled in `--debug` mode, not the normal production build. Copying it wholesale means every production container ships a full extra network-debug-protocol codebase, unused but present — needless attack surface by the plain "don't ship what you don't need" principle, independent of whether it's reachable today. Fix direction: stage two collection profiles from `tesl build` — a full dev profile and a trimmed prod profile that excludes `dsl/debug/*`, `dsl/test-support.rkt`, `dsl/load-test.rkt` — or use `raco exe`'s `++lib`/explicit collection scoping so only modules actually reachable from `app.rkt`'s require graph get embedded, which would catch this class automatically rather than relying on a hand-maintained exclude list.

### 2. Orthogonal, image-independent hardening

Not baked into the Dockerfile itself, but should ship as a documented (or generated) companion — a `docker run` flag set / k8s manifest snippet:

- `--read-only` root filesystem + a `tmpfs` mount for `/tmp` if anything needs scratch space.
- `--cap-drop=ALL`, add back only what's proven necessary (e.g. `NET_BIND_SERVICE` only if binding to a port < 1024, which Tesl apps generally don't).
- `--security-opt=no-new-privileges`.
- Recommend gVisor/Kata as a second isolation boundary (syscall interception / microVM) for anyone who can run one — this addresses container-escape/kernel-CVE risk that no amount of image slimming touches. This is a deployment-time choice gated by host capability (needs `runsc`/KVM), so it's a recommendation in docs/templates, not something baked into a portable Dockerfile.
- Supply chain: pin the base image by digest (not tag) in whatever `tesl build` generates, generate an SBOM (e.g. syft) per built image, and consider signing with cosign if the user has a registry that supports verification at deploy.

### 3. Capability-derived egress constraint ("tree-shaking" the network, not the binary)

The interesting Tesl-specific angle: the checker already knows, at compile time, which capabilities (`db`, `httpClient`, SSO connections, etc.) a given `main`'s handlers are allowed to use, and — for many real apps — the specific hosts they talk to are static: the database host from config, a fixed OTLP collector endpoint, a fixed SSO provider. For that common case, `tesl build` could emit a generated egress allowlist (a k8s `NetworkPolicy`, or an iptables/nftables rule set) derived directly from the declared capabilities and their configured targets — not hand-maintained, and not merely "best effort," but backed by the same static analysis that already gates capability use elsewhere in the compiler.

**Important limitation to design around, not paper over:** this only works cleanly when the destination host is knowable at compile time. A Tesl app can legitimately call out to a URL that's only known at runtime — e.g. three weather-service base URLs stored as rows in the database and selected dynamically, or any `HttpClient` call whose target string is built from request or DB data rather than a literal in the source. In that shape, the compiler cannot enumerate the reachable hosts ahead of time, so a purely static, capability-derived allowlist would either (a) wrongly block a legitimate dynamic destination, or (b) have to fall back to "any host" for that capability grant, which defeats the purpose.

Options to weigh here later (not decided yet):
- Two-tier capability declaration: a `httpClient` grant that's tied to a fixed, literal host (tree-shakeable into a tight allowlist) vs. one explicitly marked as reaching dynamic/data-driven destinations (falls back to a broader but still non-default-open policy — e.g. still deny link-local/metadata/RFC1918 ranges the way `tesl/private/ssrf-guard.rkt` already does for SSRF, just not narrowed to a specific host list).
- Whether the egress policy should be generated as a strict allowlist (fails closed on anything unanticipated, safest but can break a legitimate dynamic-URL feature at the network layer instead of a clear compiler/runtime error) or as a monitored/log-only policy for the dynamic-destination case (safe to ship broadly, catches drift/abuse without breaking legitimate dynamic calls).
- Whether this belongs in `tesl build`'s Docker output at all, or is better scoped as a separate `tesl build --egress-policy` / deploy-time artifact so it doesn't couple container generation to a user's specific network enforcement layer (Docker network vs. k8s NetworkPolicy vs. cloud security groups all differ).

### 4. Other image-level hardening (build-time, not cluster-level)

A grab-bag of smaller changes, all scoped to the image artifact itself rather than how it's deployed:

- **Never bake secrets into a layer, default or otherwise.** The all-in-one image's `TESL_POSTGRES_PASSWORD=app` default (`security_review.md` M5) isn't just a weak default — it's a plaintext credential permanently recoverable from the image via `docker history`/layer inspection, independent of any network-level exposure. Same principle for anything needed only at *build* time (private registry auth, a signing key): use BuildKit `--mount=type=secret` rather than `ARG`/`ENV`, so it never lands in layer history at all.
- **File permission hardening as defense-in-depth under `--read-only`.** After `chown tesl:tesl`, also strip write bits on the app directory/binary (e.g. `chmod -R a-w /opt/tesl/app`) so the image itself doesn't offer a writable app directory even when run without `--read-only`. Audit copied-in content for stray setuid/setgid bits.
- **Strict `.dockerignore`, no `COPY . .`.** Make sure `.git`, `roadmap/`, test fixtures, and `.tesl` source files never ride into a layer by accident via a broad copy.
- **Strip the compiled `raco exe` binary.** Smaller image, marginally less useful to reverse-engineer from a leaked artifact.
- **Scan the produced image, not just the Dockerfile, in CI.** Trivy/Grype (or similar) against the final built image, failing on HIGH/CRITICAL — catches an outdated bundled `libssl`/`libcrypto`/`libsodium` version before it ships, which reading the Dockerfile text alone won't reveal.
- **OCI provenance labels.** Add `org.opencontainers.image.revision` (the git SHA that produced this image), `.created`, `.source` alongside the existing `.title`/`.description` labels — ties a shipped image back to exact source quickly during incident response. Pure metadata, no runtime cost.
- **Digest-pin the base image, and rebuild on a schedule.** Pinning by digest (already noted under supply chain above) only helps once — a digest-pinned base still silently rots into "yesterday's patched version" if nothing ever bumps it. Needs to be a recurring process (e.g. a scheduled CI job that rebuilds and re-pins), not a one-time step.

## Scope

Large, multi-part, and explicitly **not started** — this is a `roadmap/later` placeholder to capture the investigation and direction, not a committed design. Suggest sequencing as:

1. Trim the staged `collections/` to a prod profile (exclude `dsl/debug/*`, `test-support.rkt`, `load-test.rkt`) — cheap, no design risk, immediate attack-surface reduction regardless of anything else here.
2. The other quick build-time items in section 4 (no secrets in layers, file permission hardening, `.dockerignore`, stripped binary, OCI labels) — all independent, no sequencing dependency on each other or on (1).
3. Prototype the distroless multi-stage build for the app-only template only (all-in-one's bash-driven Postgres bootstrap is a poor fit for a shell-less final stage and would need its own redesign — e.g. a small compiled supervisor instead of `entrypoint.sh` — treat as a separate, later effort). Validate the `dynamic-require`/`raco exe` wrinkle before trusting this in production.
4. Wire image scanning (Trivy/Grype) and scheduled base-digest rebuilds into CI as an ongoing process, not a one-time step.
5. Only after (1)-(4) land, explore the capability-derived egress allowlist — it's the most novel and least precedented piece and depends on nailing the static-vs-dynamic-destination distinction first.
