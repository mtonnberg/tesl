# Updating the compiler while the notes app keeps serving

This companion to [lesson 83](lesson83-additive-migrations.tesl) uses its complete
notes HTTP application. The connection, queries, handlers, routes, request/reply
codecs and API tests stay byte-for-byte unchanged. Only its stored schema evolves.

A compiler update is a different operation from a schema revision. Fixing an
editor query should not make an unchanged `ValidTitle` proof stop meaning “a
trimmed title between 1 and 80 characters.” It should not require changing every
handler or rewriting every stored note.

Tesl separates three questions:

| Question | What answers it? |
|---|---|
| Were the historical files edited? | Exact source seals, including private helpers and completed migrations |
| Does this compiler support the stored values and proofs? | Its versioned stored-value contract plus a fresh check of the historical schema and storage definitions |
| Which build began an unfinished migration? | The actual compiler ABI recorded in protected database history |

The compatibility contract is maintained by the compiler, not asserted by your
application. It covers the meaning of proofs, validators, lowering, codecs and
stored representations. Active stdlib changes conservatively change it too.
Matching it does not bypass source checks or authorize a different build to
resume unfinished work.

## Run the complete scenario

Inside the repository development shell:

```sh
bash scripts/run-migration-tests.sh -run '^TestCompiledMigrationCompilerUpgradeRetainsRows$'
```

The regression builds three actual compilers in a temporary copy of the source:

| Build | Difference | Expected behavior |
|---|---|---|
| A | Baseline | Creates the initial database history |
| B | An unrelated query-source change | Reads completed A history under the same stored-value contract |
| C | A different declared stored-value semantic revision | Refuses A history |

The test does not patch compiler identities into a generated application. Each
compiler checks the source and emits its own standalone Go application normally.
All serving applications use the ordinary runtime; a separate instrumented binary
is used only to stop one migration at an exact transaction boundary.

The database belongs to the test. Its operator installs protected control state;
ordinary application startup performs the schema changes. PostgreSQL keeps fsync
enabled, and the test retains real rows across the entire sequence:

1. A builds V1, V2 and V3. The schema adds nullable fields and updates its pure
   constructor. Generating V3 also freezes the completed V2 migration.
2. V1 writes a note. V2 is killed just after recording its expansion intent.
   B refuses to continue that unfinished A work, without changing rows or history.
3. A resumes and completes its revisions. Old and new app versions read each
   other's writes through the same HTTP API.
4. B rebuilds the unchanged V3 application, then creates V4 with another nullable
   field. Frozen A source remains unchanged. A's old binary restarts and keeps
   serving alongside B.
5. Both builds reject empty, oversized and malformed titles without inserting
   rows. The retained original note still passes through the same response codec.
6. C refuses the recorded source during production compilation. Its independently
   compiled fresh V1 also refuses startup against A's database. Schema, rows,
   installation identity, history and progress remain unchanged.

The first three database revisions keep A's creator identity. Only the new V4
intent records B. “This compiler can read those completed values” never rewrites
“that compiler performed this work.”

## What to do in your application

For a compiler-only update, keep your migration files unchanged and build the app
normally. Ordinary source diagnostics check the current program; the production
build additionally checks compatibility against its recorded source seals. Use
`./app --schema status --json` to inspect the deployment before starting it.

If an expansion is pending, finish it with the original build before switching
builds. Even an older binary with another ABI conservatively refuses while a
future intent is unfinished. Keep the old executable available for this reason.

If the stored-value contract differs, restore the matching compiler or use an
explicit revalidation path when one is available. Do not edit a seal or change
database metadata to make a mismatch disappear. Different-contract revalidation
and upgrades from older experimental control formats are still being implemented.

This example is additive. A derived field, renamed representation or changed
record/ADT JSON requires an actual transformation and its own rollout rules.
An unchanged SQL column type does not mean its saved values are unchanged. Those
scenarios belong to the same migration history; they are not completed by this
compiler-upgrade scenario.
