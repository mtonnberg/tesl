# Three ordinary non-additive upgrades: V1 → V2 → V3 → V4

This is a small **row-data** example using ordinary compiled Tesl applications,
public schema workers and reviewed Contracts. Three upgrades deliberately combine
different kinds of database changes:

| Upgrade | Non-additive changes | Overlap and retirement checks |
|---|---|---|
| V1 → V2 | JSONB `Retype`/`WriteBack`; rename `author` to `owner` | Old inserts retain ownership; Contract removes the old column and rename representation |
| V2 → V3 | Another JSONB representation; remove `memo` with `Legacy memo "legacy-default"` | Existing memo survives overlap; new V3 inserts provide the explicit old-reader default; Contract drops `memo` |
| V3 → V4 | Tighten plain `title` to `AllowedTitle` through `Revalidate` | Formerly valid titles reject; predecessor repair permits retirement; metadata keeps its existing column |

The JSONB representations are:

| Release | Metadata fields | Stored JSON keys | Physical column |
|---|---|---|---|
| V1 | `text` | `oldText` | `metadata` |
| V2 | `text`, `detail` | `message`, `detail` | `metadata__v2` |
| V3 | `body`, `origin`, `revision` | `body`, `origin`, `revision` | `metadata__v3` |
| V4 | Same as V3, with an explicit verified `Same` entry | Same as V3 | `metadata__v3` |

V2 and V3 use `Retype metadata` and a typed `WriteBack` callback. Old
representations remain available during overlap; the matching Contract removes
them after retirement. Changing the codec alone does not rewrite stored values.

## Run the complete example

From the repository root:

```sh
nix develop --command dune build --root compiler bin/main.exe
nix develop --command python3 example/db-three-upgrades/run.py \
  --output /tmp/tesl-three-upgrades-demo
```

Choose a new output directory. The script creates its own PostgreSQL cluster,
database and isolated owner/worker/request roles, then stops and removes the
cluster when finished. It retains generated source releases, standalone binaries
and process logs in the output directory.

Expected final output:

```text
Built ordinary application V1
Built ordinary application V2
Built ordinary application V3
Built ordinary application V4
V1 → V2: Retype/WriteBack + Rename; rejection, repair, overlap and Contract passed
V2 → V3: Retype/WriteBack + Legacy removal; rejection, repair, overlap and Contract passed
V3 → V4: proof Revalidate; rejection, repair, overlap and Contract passed
PASS: ordinary V1 → V2 → V3 → V4 mixed non-additive rollout on one PostgreSQL database
```

Go, PostgreSQL, Python 3 and the built compiler are required; `nix develop` provides
the toolchain. To build without a database run, pass `--build-only`. To repeat the
database run using existing binaries, pass `--run-built` with the same output.

## What it verifies

1. Builds V1, then uses the compiler's guarded migration previews to freeze V1,
   refresh the typed V2 transition, and generate its exact Contract.
2. Builds V2, freezes it, refreshes the V3 transition, and generates its Contract.
    The compiler advances the inherited Retype annotation to `metadata__v3`.
3. Builds V3, freezes it, and generates the V4 proof-revalidation edge and Contract.
   V4 keeps the retained `metadata__v3` annotation and explicitly proves the stored
   metadata and codec are unchanged with `Same`.
4. Runs generated tests and builds ordinary standalone binaries for all releases.
5. Installs V1 through `--schema install` and starts its public worker and HTTP app.
6. Seeds a real row, changes its metadata to `blocked`, and deploys V2. Contract
   must fail while the typed converter rejects the old value.
7. Repairs the row through V1's still-admitted HTTP endpoint, checks V2 can read it,
   and exercises V1 updates and inserts during overlap, including the renamed field.
8. Stops V1 requests and executes V2's public Contract. The test checks both
   admission floors and physical removal of the V1 column and old field spelling.
9. Repeats rejection, repair, overlap and Contract for V2 → V3. A new V3 row is
   readable through V2 with `memo == "legacy-default"`; existing memo remains
   unchanged until Contract removes the physical column.
10. Deploys V4 over a V3-valid `title == "blocked"`. Contract refuses, V3 repairs
    the title, and V4's proof-producing constructor refuses a new invalid write.
    The metadata value and its physical column remain unchanged.
11. Replays each Contract and restarts its Worker. The final database retains all
    three rows, three distinct upgrade receipts, and admission floors at V4.

The HTTP handlers in [app.tesl](app.tesl) are shared across the releases. Schema
constructors and codecs own their representation. Repairs here are ordinary
admitted row updates, which invalidate/retry the conversion; they are distinct
from the separately checked queued-payload repair revisions in lesson 96.

## Files and release commands

- [schema/notes/v-current.tesl](schema/notes/v-current.tesl): runnable initial V1 schema.
- [versions/](versions/): V2/V3/V4 schema inputs copied into the generated working project.
- [transitions/](transitions/): reviewed typed conversion and reverse-write bodies.
- [run.py](run.py): builds source releases and exercises their actual public commands.

Templates become canonical, sealed migration files in `OUTPUT/vN/source/` through
the compiler's preview/refresh workflow. The script verifies input hashes,
directory inventories and original edit bytes before applying each preview.
Committed example inputs are not modified during the demonstration.

For a manually configured PostgreSQL deployment, the release binaries use:

```sh
OUTPUT/v1/app --schema install --worker "$DEMO_WORKER" --request "$DEMO_REQUEST" --json
OUTPUT/v2/app --schema worker --json
OUTPUT/v2/app --schema contract V2 --json
OUTPUT/v3/app --schema worker --json
OUTPUT/v3/app --schema contract V3 --json
OUTPUT/v4/app --schema worker --json
OUTPUT/v4/app --schema contract V4 --json
```

Set `DEMO_HOST`, `DEMO_PORT`, `DEMO_DB`, `DEMO_USER`, `DEMO_OWNER`, `DEMO_WORKER`,
`DEMO_REQUEST`, `DEMO_DDL` and `DEMO_HTTP_PORT`. `DEMO_DDL` must use the short-lived
installer for installation and the Worker login for worker/Contract commands.
Drain predecessor request processes before each Contract.

The complete example is included in `scripts/run-migration-tests.sh`. For the
separate initial public queue conversion/repair/retirement rollout, see
[lesson 96](../learn/lesson96-typed-queue-conversion.md).
