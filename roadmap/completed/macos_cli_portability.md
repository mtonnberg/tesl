# macOS first-run DX: GNU-userland assumptions, bare verbs, `[deploy].target`

Issue [#46](https://github.com/mtonnberg/tesl/issues/46) — macOS (Apple Silicon,
Determinate Nix), `nix profile install github:mtonnberg/tesl`. A fresh install
could not run a scaffolded project. Three defects, all closed here.

## 1. The CLI assumed a GNU userland (the blocker)

`nix/tesl-cli-body.sh` called `mktemp --suffix=`, `readlink -f`,
`realpath --relative-to`, `stat -c`, `sed -i <expr>` and `xargs -d`. On macOS
the BSD tools are what is on `PATH`, so `tesl run` / `compile` / `test` /
`generate` failed — and the headline symptom was misleading: an empty
`$(mktemp --suffix=.rkt)` turned the following redirect into a bare
`: No such file or directory`.

Fixed in **two independent layers**, so neither has to be perfect:

* **flake.nix** — `runtimePreamble` (and the dev wrapper) prepend a pinned GNU
  userland (`coreutils gnused gnugrep gawk findutils diffutils`) to `PATH` via
  `lib.makeBinPath`. Because the store paths are interpolated into the wrapper
  text they are real runtime references of the installed package, i.e. properly
  GC-rooted — which is exactly what the reporter had to hand-build with
  `nix build -o …` out-links.
* **nix/tesl-cli-body.sh** — a "portable userland shims" section replaces every
  GNU-only construct, so the body is correct even when run directly (ci.sh does)
  or from an environment whose `PATH` was reset:
  `_tesl_abspath` (`cd -P`/`pwd -P`, no `realpath`), `_tesl_resolve_link`
  (bounded `readlink` loop, no `-f`), `_tesl_relpath` (prefix arithmetic, no
  `--relative-to`), `_tesl_file_mtime`/`_tesl_file_stamp` (probe `stat -c`, fall
  back to BSD `stat -f`), `_tesl_mktemp`/`_tesl_mktemp_dir` (always pass a
  template — BSD `mktemp` requires one), `_tesl_tmp_rkt` (a deterministic
  sibling of the destination — a fixed `.rkt` suffix cannot be expressed as a
  BSD `mktemp` template; it also makes the following `mv` a same-filesystem
  rename instead of a `/tmp`→project copy), `_tesl_sed_inplace` (temp file, no
  `-i`), and a `while read` loop instead of `xargs -d '\n' stat -c`.

`_tesl_port_in_use` was wrong on macOS for a second reason: it ran
`netstat -ltn` (GNU flags), which BSD netstat rejects, so every port looked
free. It now probes with `/dev/tcp` first (no flag dialect at all) and falls
back to `ss`, then to either netstat dialect, matching BSD's `host.port` column
format too.

## 2. Bare `tesl test` / `tesl run` contradicted the scaffolded README

`tesl init`'s README documents `tesl run`, `tesl test`, `tesl build` with no file
argument; every file-taking verb hard-failed with a usage line. `compile`,
`check`, `run`, `test`, `watch` and `validate` now fall back to the nearest
`tesl.toml`'s `[project].entrypoint` (resolved from any subdirectory, announced
on stderr so the implicit choice is never silent). With no manifest — or no
`entrypoint` key — the verb still prints its usage line, so the single-file
workflow is unchanged.

## 3. `tesl build` built a Docker image for `[deploy].target = "local"`

The manifest documents `"local"` as "run the compiled binary directly", but the
verb staged a Dockerfile and shelled out to `docker` regardless — requiring
Docker where the manifest said it should not, and contradicting the scaffolded
README's `tesl build  # type-check + compile`.

`tesl build` now reads `[deploy].target`:

| value | behaviour |
|---|---|
| `"local"` | compile the entrypoint (+ deps) into `.tesl-stuff/build/`, print how to `tesl run` it; no Dockerfile, no docker |
| `"container"` | the previous image build |
| key absent | `"container"` — preserves the behaviour of manifests written before the key existed |

`--local` / `--container` override the manifest; the container-only flags
(`--app-only`, `--with-postgres`, `--tag`, `--out`, `--no-docker`) imply
`--container`.

## The ratchet

`tests/cli-portability.sh` (ci.sh phase 9c, runs on the Linux CI):

* **static** — scans `nix/tesl-cli-body.sh` for GNU-only constructs
  (`mktemp --suffix`, template-less `mktemp`, `readlink -f`, `realpath`,
  unguarded `stat -c`/`stat -f`, `sed -i`, `xargs -d`, `grep -P`,
  `find -printf`, `date -d`, long options on core tools);
* **dynamic** — re-runs `compile` / `check` / `test` / `build` / `init` with
  BSD-only `mktemp`/`stat`/`readlink`/`realpath`/`sed`/`xargs`/`netstat` stubs
  shimmed onto `PATH` (each rejecting the GNU flags exactly as macOS does, so
  semantics are checked, not just spelling), plus the bare-verb and
  `[deploy].target` behaviours above.

A macOS-only regression therefore fails CI on Linux.

## Docs touched

`manual/deploy.md` (the two build modes), `manual/tesl-manifest.md`
(`[deploy]` table + entrypoint fallback), `templates/{api,minimal}/README.md`,
`tesl init`'s next-steps + generated `AGENTS.md`, and `tesl help`.
`compiler/lib/embedded_docs.ml` re-promoted by `dune build`.
