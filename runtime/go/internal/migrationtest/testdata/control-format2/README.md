# Frozen format-2 worker application

`worker-app.tar.gz` is the complete Go application emitted from lesson 84 by the
actual compiler before the format-3 bridge was implemented. It contains the
original format-2 runtime, compiled history and HTTP app, not a current runtime
with its format check disabled. The archive contains source, not an executable;
the regression compiles its ordinary application binary with the current Go
toolchain. No ABI, history, runtime or generated application bytes are patched.

`manifest.json` records the source compiler ABI, stored-value compatibility,
original Tesl source hashes, every emitted file hash and the archive hash. Keep
this fixture immutable. A future compatibility baseline is a new fixture, not a
refresh of this one. Its purpose is to test an actual previous application's
behavior across a control-schema upgrade even when CI has a shallow Git checkout.

The original source is `example/learn/lesson84-worker-migrations.tesl` with the two
`schema/worker-notes/v-current` modules. Source and generated trees are removed
before deployed processes run. This preserves the old binary's real admission,
grant, catalog and format limitations as the compiler evolves.
