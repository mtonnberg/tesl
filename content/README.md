# Verified content exports

The main Tesl repository owns teaching code and its verification rules. Publication
tools consume a self-contained JSON bundle; this repository never needs a checkout
of `tesl-adoption`.

From the repository root in the development environment:

```sh
python3 -m unittest discover -s tests -p test_content.py
python3 scripts/content.py verify --preview
python3 scripts/content.py export --preview --out /tmp/tesl-content.json
```

Omit `--preview` for a release input: the exporter requires a clean checkout.
Write the export outside the tracked source tree. The authoritative `./ci.sh`
includes verification; GitHub CI also exports an artifact after the gate passes.
Exporting evidence does not publish an article or approve its claims.

## Current scope

The [catalog](catalog.json) covers one complete
[title validation example](../example/adoption/validation-title.tesl), selected
manual pages, `String.length` reference from `--doc-json`, and `V001` explanation
from the compiler. It does **not** certify all manual examples or export the whole
builtin catalog. The source's named regions are display fragments; the bundle
also includes complete modules with imports and tests.

The example has four behavior tests, covering lengths 0, 3, 4, 120 and 121.
Its deliberately broken variant omits validation before a proof-requiring call.
The verifier requires exactly the expected error code, message discriminator and
source line. Restoring the named repair region must restore the canonical source
byte for byte. The example neither saves data nor serves an HTTP endpoint.

## Evidence contract

The [schema](bundle.schema.json) describes the version 1 envelope. The exporter:

1. Builds the compiler from this checkout, then records source and compiler hashes.
2. Checks the broken and repaired modules through `agent-context`.
3. Emits the repaired module to Go and executes its tests in a temporary directory.
4. Requires every declared test to run and pass; skips, empty suites, unexpected
   tests, timeout and missing dependencies fail verification.
5. Confirms the source/compiler have not changed during verification.

`payload` holds source text, hashes, reference and normalized verification results.
`content_sha256` hashes that deterministic payload. `run` preserves timestamps,
commands and raw output; the outer `sha256` additionally locks that exact run.
Two checks of unchanged inputs can have the same content digest and different run
digests. A dirty preview records its base commit **and** actual tree digest; the
commit alone must never be presented as the preview's complete source identity.

These hashes establish consistency, not authenticity. Consumers must obtain
bundles from a trusted checkout or CI artifact and review changes to their lock.
Compiler checks and boundary tests support specific claims; they do not establish
general correctness, security or the quality of an article's explanation.

## Adding an example

Add a complete module under `example/adoption/`, paired whole-line
`# content:start name` / `# content:end name` markers, native `test` blocks and a
catalog entry. Record ownership, license, prerequisites, limitations and claim IDs.
The catalog's test names must exactly match the source order; keep expected
negative diagnostics specific. Run `agent-context` after source edits, verify the
catalog, and mint its Go snapshot with `scripts/regen-go-snapshots.sh --mint
example/adoption`. Run the full gate before committing.

The verifier executes **trusted repository code**, with bounded subprocess
timeouts. A temporary directory is not a sandbox. Review external examples and
run them in a disposable development/CI environment without publication secrets.
No model account is needed to verify or export content.
