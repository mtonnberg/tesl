# Authoring and rolling out a migration

`tesl migrate app.tesl` prepares checked source files. It does not connect to your
application database or convert stored data. Deployment runs the resulting
application binary with separate Installer, Worker and Request database roles.

## Work through one revision

1. Run `tesl migrate app.tesl` in an interactive terminal. It freezes the previous
   current schema before asking you to edit the new `v-current.tesl`. Use
   `tesl migrate app.tesl --resume` to continue an existing undeployed revision.
2. Save the current schema changes. Refresh produces the compiler's proposed
   migration, preserving user-owned conversion code. Read the overview and work
   through the remaining decisions. Enter a displayed compiler option number to
   write its scaffold directly into the migration files. `?` expands help, `n`
   advances, and Enter refreshes and rechecks saved changes. Save editor buffers
   before using the CLI: its choices update saved files.
3. Fill the typed holes with the business decisions the compiler cannot infer.
   A rename can copy the exact old field; a new default needs a value you choose;
   a changed representation needs a converter; a changed proof may also need a
   reverse converter so old code can keep writing during overlap. Suggested
   options explain these choices; they do not authorize data loss or make an
   unchecked template safe.
4. Run `tesl agent-context app.tesl` after edits. Inspect
   `tesl migrate plan app.tesl`, add application and conversion fixtures covering
   real historical values, and run their tests. Generate the required cleanup
   proposal with `tesl migrate contract app.tesl --version N` and review it before
   building the deployment artifact.
5. Choose the deployment route below. Source generation, compilation, a passing
   fixture and runtime readiness are separate checks. None substitutes for the
   others.

Explicit commands also work in scripts:

```sh
tesl migrate generate app.tesl --manifest-json
tesl migrate generate app.tesl
tesl agent-context app.tesl
tesl migrate plan app.tesl
```

`--manifest-json` is a non-mutating guarded source preview. The guided writer
requires an interactive terminal and its supported filesystem protections;
portable previews do not imply portable source application. Keep every frozen
schema, migration, codec and reviewed Contract that the retained history needs.

## Apply choices in VSCodium

Install extension 0.7.15 or later with a matching compiler and language server,
then reload the editor. Run **Tesl: Preview Migration Decisions** from the Command
Palette or migration CodeLens. When starting from a schema or migration file,
choose the application entry file. Review the overview and expand each decision's
help. **Use this option and update source** writes the compiler scaffold into the
actual files or open buffers, selects a remaining custom-code hole and rechecks.
**Update proposed source files** applies the ordinary generated proposal. The diff
view is for review; there is no manual copy/paste step. See the
[extension setup](../editor/vscode-tesl/README.md) if CodeLens or completion is missing.

Dirty buffers stay unsaved until you save them. A stale preview or changed buffer
refuses instead of overwriting your edit: request a fresh preview. The editor
checks exact text, versions and open/close lifetimes before and after application.
If an outcome is unknown or requires recovery, preserve buffers and the
`.tesl-source-edit` journal, and use **Check application outcome**. Follow its
guidance before starting another operation. Automatic reconciliation after a
server restart is not implemented; an editor-pending journal deliberately refuses
disk-only recovery. Saved-source publication requires Linux filesystem protections.

The compiler scaffolds classifier-approved primitive literal defaults, supported
single primitive-field revalidation using an existing exported establish function,
and bounded primitive conversions with unchanged field names, primary key, table
and indexes. It fills row copies, forward/reverse signatures, imports and historical
fixture structure. Business values, conversion/rejection policies and fixture
values remain explicit `todo` holes. Cross-field proofs, hidden owners,
nonprimitive conversions, key/index changes, renames and removals are outside these
automatic scaffolds. Guidance without a compiler-proposed choice cannot write source.

A scaffold with holes cannot build or deploy. Complete the code, inspect its
diagnostics and test historical values before reviewing the deployment plan.
Selecting an option prepares source and never executes database work.

## Same proofs and changed meaning

`Same Old.Valid New.Valid` means the compiler verified the complete reached
semantic closure, including the relevant checks, proof-producing functions,
helpers and codecs. A matching name or carrier type is insufficient. Renaming a
fact is not permission to change its meaning, and manually adding `Same` cannot
bypass the closure check.

| Your change | Supported decision |
|---|---|
| Comments or unrelated helpers change while the reached meaning is unchanged | Keep the compiler-verified `Same` entries. |
| Add a field's first proof without changing its stored value | Use the checked `Revalidate` path and a check for the new proof. |
| Add a field-local conjunction while retaining every historical proof unchanged | `Revalidate` can retain those exact proofs through verified `Same` evidence and establish the additional proof. |
| Replace an existing proof's meaning, such as changing a bound from `n >= 0` to `n > 0` | Do not mark it `Same`. Use the supported `Migrate` / `Retype` path, plus `WriteBack` returning the exact previous proof when required for rolling overlap. |
| Change a record/ADT representation or codec | Use the checked conversion path; a same-shaped source declaration does not establish codec identity. |
| A reverse converter or historical value cannot satisfy the required old/new contract | Reconsider the business policy or use a supported staged design. Do not weaken the old proof, rewrite frozen history or assume the change is online. |

`Revalidate` checks the same stored value; it is not a general replacement for
changed historical proofs. Current reverse-proof support is field-local, not a
general solution for cross-field facts. The compiler's refusal is part of the
compatibility contract.

Worked examples: [adding a proof](../example/learn/lesson89-proof-revalidation.md),
[changing an existing proof](../example/learn/lesson90-changing-field-proofs.md),
and [retaining old proofs while strengthening a field](../example/learn/lesson94-same-column-proof-strengthening.md).

## Current schema edits and recorded hashes

After editing `v-current.tesl`, `MIG001` can mean the pending migration has not yet
been refreshed to describe those saved changes. That is an expected incomplete
authoring state: save, refresh the migration, resolve its decisions and recheck.
The editor's draft guidance does not make the program deployable; the compiler
still rejects an inconsistent current schema or unresolved migration.

`MIG013` is different: frozen history or its protected metadata no longer matches.
Restore the exact historical file from version control and investigate the change.
Do not dismiss it as an in-progress migration, change a stored digest to match,
or reseal an already-deployed revision. If source publication was interrupted, use
the guarded recovery command named by the tool rather than manually completing a
partial multi-file write.

## Choose the deployment route

Rolling support depends on the change and the retained history. It is not a
promise that every migration can run with every old application still serving.

| Change or operation | Rolling behavior and required action |
|---|---|
| Compatible additive revisions | Several compatible versions can remain admitted. A Worker can catch up a supported additive gap using retained history. Close the additive epoch before its first transforming revision. |
| Supported adjacent row transformation | Keep old/new storage and the required reverse-write behavior during overlap. Start `worker --install`, roll Request instances after expansion is ready, then retire old instances and complete the reviewed Contract. New transformed values may be usable in projections before they are safe in SQL filters or indexes; follow the compiler's restrictions. |
| Queue payload change | Keep the supported stored-row contracts unchanged on that edge. The Worker converts exact historical payload versions; live old claims and rejected/invalid jobs can block retirement. |
| Both stored rows and queue payloads change | Split into a row revision and Contract, then a payload revision. A latest artifact can execute the supported ordered history without shipping intermediate application images. This does not make an incompatible multi-version gap an always-online upgrade. |
| Staged uniqueness | Use the staged releases and per-key guards. Promotion requires the reviewed Contract and correct old-writer retirement; declaring an index does not by itself make conflicting writes safe. |
| Non-adjacent transforming catch-up | Stop incompatible old processes and wait for their heartbeat/claim windows. `deploy` / `catch-up` execute the supported history and refuse unsafe publication. Plan for interrupted availability when there is no admitted surviving service. |
| Contract or additive-epoch closure | This retires old versions and can remove their storage. Do not automatically roll back to an image below the new admission floor. Restore/recovery planning must respect that irreversible boundary. |
| Unrelated table Drop or whole empty-queue removal | Use their explicit reviewed source decisions and narrow history restrictions. Neither allows arbitrary dependency removal, implicit discard or silent queue rename. |

For a compatible adjacent Kubernetes rollout, the order is:

```text
worker --install → worker ready → roll Request pods → old pods/claims drain → deploy/Contract
```

The finite `--schema deploy` command completes retirement. Running it as a
pre-upgrade hook while the controller still keeps old pods alive can wait for
those very pods. Use the [rolling example](../example/kubernetes-rolling/README.md)
for that ordering. A stop → deploy → start pipeline is a useful finite deployment
route, but does not promise continuous availability.

See [operating a migration](migration-operations.md) for credentials, blockers and
recovery, [cleanup Contracts](migration-contracts.md), and
[reviewed empty queue removal](queue-removal.md) for detailed restrictions.
