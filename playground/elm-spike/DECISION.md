# Elm feasibility decision — 2026-09-05

**Ship builtin search in the current playground. Defer a full Elm migration.**
Elm is a viable future shell; there is no technical reason to delay useful
search until all existing editor behavior has been migrated.

This bounded experiment implements one Elm screen with a native textarea,
compiler checks, diagnostic rendering, builtin search and source links. It uses
the same compiled OCaml search/checker and the same source-link codec as the
supported playground. No language semantics were implemented in Elm.

Elm owns the model and views. A small JS adapter loads verified compiler assets,
debounces requests, calls compiler exports, handles clipboard/selection and
encodes share links. Port envelopes carry `version`, `request_id`,
`source_revision`, `operation` and `payload`; Elm decodes them, reports malformed
messages visibly and ignores replies for superseded checks or searches. The
adapter currently runs the compiler on the main thread; moving it into a worker
would need separate crash/restart and responsiveness tests.

## Evidence and limits

The optimized Elm 0.19.1 output is **125,194 bytes raw / 28,858 bytes gzip** on
this prototype. This measures the experiment, not a complete migration. Direct
package versions are pinned in `elm.json`; Elm remains an optional playground
tool and is absent from ordinary compiler builds.

Three Chromium scenarios passed: edit/check/search/share with an existing
source/selection/highlight link; native undo and simulated composition through
diagnostic rerenders; and rejection of out-of-order replies with recovery from
malformed envelopes. The supported playground has its own broader browser suite.
These results are desktop Chromium evidence, not physical mobile IME or
screen-reader verification.

The prototype does not yet include syntax overlays, gutters, diagnostic
navigation/explanations, compiler fixes, source highlighting, lessons, search
result actions, themes or generated-code tabs. Those existing features account
for most migration work and the remaining editing risk. Keeping both as supported
interfaces would create duplicate maintenance, so this screen stays an opt-in
experiment with no production link or deployment step.

Revisit the decision when a dedicated migration can preserve those behaviors,
demonstrate worker recovery with the buffer intact, and pass real IME/accessibility
checks. The compiler API, fixtures, link codec and versioned port approach are
available for that work. The experiment demonstrates feasibility; it does not
justify claiming that the complete shell has become simpler or faster.

## Reproduce locally

```sh
nix develop --command playground/build.sh /tmp/tesl-playground-preview
# Elm 0.19.1 and the packages in elm.json are needed for this optional command.
playground/elm-spike/build.sh /tmp/tesl-playground-preview
PLAYGROUND_DIST=/tmp/tesl-playground-preview PLAYGROUND_ELM_SPIKE=1 \
  nix shell --inputs-from . nixpkgs#playwright-test nixpkgs#playwright-driver.browsers \
  --command playwright test --config e2e/playground/playwright.config.cjs
```

Serve that directory and open `elm-spike.html`. Deployment runs only
`playground/build.sh`, which does not require or emit Elm. Use a fresh output
directory when preparing a deployment, rather than publishing an experiment's
working directory.

The design follows Elm's [port interoperability](https://guide.elm-lang.org/interop/ports)
and [text-field state](https://guide.elm-lang.org/architecture/text_fields) patterns.
