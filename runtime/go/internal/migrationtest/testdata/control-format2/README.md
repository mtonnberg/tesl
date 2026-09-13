# Frozen format-2 worker application

`worker-app.tar.gz` is the complete Go application emitted from lesson 84 by the
actual compiler before the format-3 bridge existed. It retains its original
format-2 runtime, stored-value contract 2, compiler ABI, history and HTTP app.
The archive contains source; the regression builds its ordinary executable with
the current Go toolchain. No runtime, history or compiler identity is patched.

Keep this fixture immutable. Its manifest pins all 84 emitted files, the archive
and the three original Tesl files under `source/`. The paired
[`control-format3-contract2`](../control-format3-contract2/README.md) fixture was
emitted from those exact Tesl bytes by an actual historical compiler. The current
compiler also compiles those same bytes, using its own stored-value contract.
Every source and generated tree is removed before deploying the executables.

`TestCompiledControlFormatUpgrade` proves distinct boundaries:

- The original app and historical bridge exchange PostgreSQL writes on format 2.
- The historical bridge's explicit installer upgrades 2 to 3 while preserving
  rows, provenance, lifecycle and existing catalog definitions. Lost output after
  commit exercises idempotent retry. The bridge then serves and restarts on 3;
  the original format-2 request and worker binaries refuse it.
- The actual current request, status and installer refuse contract-2 history on
  format 2 with the exact stored-value compatibility diagnostic. The current
  worker stops earlier with its explicit requirement for an installer upgrade.
- On the historical format-3 prototype, current software refuses its missing
  sixth index-recovery function. This is **catalog refusal evidence**, not proof
  of the semantic refusal path: catalog validation runs first.

All current refusals preserve rows, the format number and the complete namespace
object inventory. Contract 3 tightened cross-module proof identity after a real
hidden-wrapper forgery was demonstrated under contract 2; no implicit
revalidation or metadata relabeling upgrades that authority. Current-catalog
runtime regressions cover semantic mismatch separately. These fixtures prove
control-format behavior, not row transformation or index execution.

`TestControlUpgradeFixtureRefusesTampering` checks both closed inventories and
17 altered or malformed cases per fixture without a compiler or PostgreSQL.
Run the actual application scenario from the repository root:

```sh
bash scripts/run-migration-tests.sh -run '^TestCompiledControlFormatUpgrade$'
```
