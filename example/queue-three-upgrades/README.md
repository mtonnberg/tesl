# Three ordinary queue upgrades: V1 → V2 → V3 → V4

This runnable example builds frozen ordinary application binaries and separately
checked repaired deployments, then uses their public installer, schema Worker and
Contract commands on one PostgreSQL database.

| Release | Typed payload | JSON wire keys |
|---|---|---|
| V1 | `text` | `oldText` |
| V2 | `body`, `priority` | `message`, `priority` |
| V3 | `content`, `importance`, `tag` | `content`, `importance`, `tag` |
| V4 | `message`, `rank`, `audit` | `message`, `rank`, `audit` |

The retained message survives all three conversions, its numeric priority changes
7 → 17 → 27, and its V3 provenance survives into V4. An empty original payload
rejects at each edge; a separate `QueueRepair` deployment makes the explicit
business decision to replace that message with `"repaired"`.

## Run

From the repository root, choose a new output directory:

```sh
nix develop --command dune build --root compiler bin/main.exe
nix develop --command python3 example/queue-three-upgrades/run.py \
  --output /tmp/tesl-queue-three-upgrades
```

The runner owns and cleans up its private PostgreSQL cluster. It retains source
releases, generated Go, standalone binaries and process logs under the
output directory. `--build-only` builds the releases; `--run-built` reruns the
database lifecycle with existing binaries. `--catch-up-only` selects the newest-
binary scenarios. A separate test-instrumented V4 executable drives process-death
probes; ordinary lifecycle scenarios use the uninstrumented application binaries.

The adjacent rollout reports:

```text
PASS: three ordinary non-additive queue upgrades on one PostgreSQL database
```

## What is checked

- Guarded compiler previews freeze each schema and completed conversion closure.
  Every generated source passes `agent-context`, and each release's generated
  conversion/repair fixture tests execute under the Go race detector.
- Request/Worker credentials cannot install. A latest artifact can install its
  genuine retained V1 origin and stage future edges without publishing them.
- Each edge converts retained jobs and quarantines an empty payload at its original
  schema version. Old-version enqueue remains admitted during overlap; the Worker
  also discovers and converts those late arrivals.
- Contract refuses rejected jobs without advancing either admission floor. The
  installer stages an explicitly imported immutable repair revision, and the
  repaired Worker's typed adapter retries the original payload.
- Future proposals can be staged early, but activation refuses until the actual
  immediate predecessor retires. A freshly rehashed substitute retirement receipt
  refuses without changing previously staged authority.
- Contract replay and Worker restart preserve the database UUID, all prior
  descriptors and the original V1 conversion receipt. Three retirement receipts
  and six conversion/repair descriptors remain at V4.
- The final ordinary V4 Request application serves HTTP and its actual typed queue
  handler decodes and acknowledges all seven retained jobs. Conversion receipts
  survive job deletion.
- The latest V4 binary catches up fresh and retained V1/V2/V3 databases, preserving
  values and all three conversion receipts. The V4 repair artifact explicitly
  includes historical repair declarations; an artifact missing staged repair code
  refuses before advancing. No intermediate application image is deployed.
- Live old claims and real recent Request heartbeats block retirement. Tests wait
  for their real expiry rather than editing protected lease/instance records.
- Process death after a staging group, conversion turn or queue retirement resumes
  correctly. Repeated catch-up preserves immutable receipts and database identity.

## Latest-binary deployment commands

```sh
# Configure Installer credentials for this operation.
OUTPUT/v4/app --schema install --worker "$DEMO_WORKER" --request "$DEMO_REQUEST" --json
# Switch to Worker credentials; the same binary executes all retained edges.
OUTPUT/v4/app --schema catch-up --json
```

Stop retiring applications/claimants and let their heartbeats/leases expire first.
Queue catch-up completes the final queue Contract too: success has current version
and minimum admitted version both at V4. If a converter rejects, preserve the
original job and deploy the explicitly checked repair/discard policy, then rerun
installation and catch-up.

The runner seeds jobs through the protected queue enqueue API using the restricted
Request role. It does not patch compiler history or call candidate execution APIs.
The deliberate receipt-corruption probe uses the installer and restores the exact
bytes before continuing.

This scope retains exact queue/job membership and unchanged stored entities.
Mixed entity/queue transformations and membership changes remain unsupported.
For varied row-data upgrades (Rename, Legacy removal, Retype/WriteBack and proof
Revalidate), see [the database example](../db-three-upgrades/README.md).

The default `scripts/run-migration-tests.sh` gate includes both examples.

## Different compiler builds

The runner also accepts `--compiler PATH`, `--upgrade-compiler PATH` and
`--incompatible-compiler PATH`. With an upgrade compiler, A builds V1 and freezes
its source before B builds the later releases. Frozen V1 bytes must remain exact.
The optional incompatible compiler builds a fresh V1 whose installer must refuse
the original database without changing admission or retained payloads.

`TestCompiledQueueCompilerUpgradeRetainsPayloads` builds actual A/B/C compilers
in an isolated source tree: B has a query-only implementation change and the same
stored-value compatibility; C declares incompatible stored-value semantics. The
test runs the full public three-upgrade lifecycle, then uses a separate database
to prove B cannot replace A's active V2 executable. After A retires V2, B can
catch up directly to V4. The new edges are pinned to B; A's predecessor receipts
are immutable observations. No emitted compiler identity or history is patched.

This tests a compatible new-edge compiler upgrade, not unrestricted substitution
of any binary or runtime into an active processing generation.
