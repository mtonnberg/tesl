# Tesl CLI Tool

> **Implemented** — `tesl` shell function available immediately on `nix-shell` entry.

## What was built

`shell.nix` was updated with a `shellHook` that defines a `tesl` bash function available in every nix-shell session without any extra steps.

### Usage

```bash
nix-shell                              # enters the dev shell
tesl help                             # print usage
tesl compile example/todo-api.tesl   # compile .tesl → .rkt
tesl check   file.tesl               # type-check + lint
tesl fmt     file.tesl               # format in-place
tesl run     file.tesl [args…]       # compile + run with racket
tesl test    file.tesl               # compile + raco test
```

### Implementation notes

- The `shellHook` exports a `TESL_REPO_ROOT` env var pointing to the nix-shell working directory.
- All subcommands resolve `compile_thsl.py` relative to `$TESL_REPO_ROOT`.
- The function is a bash function (not a compiled binary), so it is only available inside `nix-shell`. A proper `nix build` / `raco pkg` distribution is tracked separately (not yet warranted).

## Open improvements

- `tesl run` currently writes a temp `.rkt` and deletes it; a proper `#lang tesl` reader integration would be cleaner.
- No `--verbose` flag yet (see `implement_verbose_ambient_logging.md`).
- `tesl test` invokes `raco test` directly; output could be prettified.
