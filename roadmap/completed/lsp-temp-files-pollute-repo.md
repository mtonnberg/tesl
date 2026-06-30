# LSP writes transient validation files into the watched source tree

## Problem
The Tesl LSP (`editor/tesl-lsp/`) writes transient validation copies named
`tesl-lsp-<digits>.tesl` into the **directory of the file being edited**
(observed in `example/` and `example/learn/`). Because the repo's tooling globs
those directories, the temp files cause real churn:
- `compile-examples.sh` globs `example/learn/*.tesl` / `example/*.tesl` — a temp
  file present during a run is compiled and (being a partial buffer) can fail.
- `gen/gen_docs.ml` bakes `example/**` into `compiler/lib/embedded_docs.ml`, so a
  temp file dirtied `embedded_docs.ml` on every `dune build`.

## Workarounds already applied (core_polish)
- `gen_docs.ml` now skips `tesl-lsp-*` files (no embedded_docs churn).
- `.gitignore` ignores `tesl-lsp-*.tesl` anywhere.

## Real fix (this item)
Make the LSP write its transient validation copy to a **system temp dir**
(`Filename.temp_dir` / Racket `make-temporary-file`), not the document's
directory — then nothing leaks into the watched source tree. Anchor:
`editor/tesl-lsp/tesl-lsp.rkt` (the validate-on-change path that shells out to the
compiler against a temp file). Also have `compile-examples.sh` defensively skip
`tesl-lsp-*` in its globs.
