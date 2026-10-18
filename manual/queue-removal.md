# Reviewed empty queue removal

The source decision is **`RemoveEmpty`**, explicitly imported from
`Tesl.Migration` and used as a value in `Migration.jobs`:

```tesl
module Schema.Todo.Migrate.V3 exposing [migration]
import Tesl.Migration exposing [Migration, RemoveEmpty]
import Schema.Todo.V2
import Schema.Todo.VCurrent

migration = Migration {
  from: Schema.Todo.V2,
  to: Schema.Todo.VCurrent,
  same: [],
  entities: {},
  jobs: { Notifications: RemoveEmpty }
}
```

The key names a **previous queueSchema**, not a job payload or application Queue
binding. Remove that queueSchema from VCurrent and remove its current application
Queue binding and `App.queues` entry. Keep every frozen schema from V1 and its complete
payload, codec and proof history. Keep the normal checked migration source seals;
deleting a declaration or rewriting an old seal is not a removal decision.

## Bounded source surface

This slice accepts one whole-queue removal on **V(n−1) → Vn**, after a checked
ordinary additive prefix and before an ordinary additive suffix, with:

- Authoritative complete sealed inventories at both endpoints.
- Unchanged row entities/storage on the removal edge, with no entity decisions
  or conversions on that edge. Other revisions may add tables or additive fields
  and indexes through the established checked row protocol.
- Identical membership and complete payload/proof/codec contracts for every
  surviving queue. The target may have no queues if the only queue was removed.
- No conversion fixtures or payload converters. Other revisions may add genuinely
  new queue/job identities while preserving every existing full payload/proof/
  codec contract. Removed queue and job identities cannot be reintroduced or moved
  under a new owner later. Staged-index entries remain unsupported in this history.
- Worker migration topology.

Queue rename, moving jobs, removing only some jobs, mixed changes on the removal
edge, and multiple removal edges remain refused. Transforming or queue-converting
prefixes **and suffixes**, Drop/reset, and staged indexes are not implemented in
this composition. The compiler reports the offending revision (MIG028 for
non-additive/queue changes; MIG030 for staged history). Runtime checks independently
enforce the same bound. This decision
does not discard any job. Resolve retained jobs through the existing application
and reviewed remediation paths before retrying; changing source cannot bypass
the database check.

## Connected implementation

1. `migration_declaration.ml` checks the explicit decision and complete before /
   after inventories. Existing application binding validation checks VCurrent.
   `migration_retained_storage_canonical.ml` emits physical format v9, whose
   direct removal node carries the removed identity, both old snapshot hashes,
   and both full queue/payload inventories. The new snapshot hashes are in the
   enclosing physical descriptor. Runtime parsing independently checks the exact
   removed complement and unchanged row storage.
2. `--schema install` stages that exact compiled decision in
   `tesl_row_queue_target_staging` and `tesl_row_queue_removal_staging`, bound to
   the actual database UUID, fence namespace, adjacent predecessor physical hash,
   compiler ABI, and compatibility. The immutable receipt also binds a canonical
   digest of every prefix member's actual version, physical hash and complete
   source-inventory hash; it does not invent earlier creator ABIs. A future predecessor may be staged from its
   exact compiled descriptor before installation; protected execution requires
   its actual completed physical/source records. Staging does **not** register
   target membership, publish the target, change jobs, or advance floors.
3. Worker, `--schema contract Vn`, `--schema catch-up`, and
   `--schema deploy` reach the same removal executor. A fresh latest deployment
   first establishes the real original V1 catalog, executes each additive prefix
   step, performs removal, and continues through the additive suffix. Execution
   uses `pgRowExecutionWindow`: `b.target.version` selects the actual historical
   edge while `b.history.CurrentVersion` and its ABI retain the real binary's
   complete source identity. Intermediate application images are not required.
4. The executor verifies the protected catalog and source history, holds the
   deployment lock, and acquires exclusive request/writer and representation
   fences for **every admitted version from the actual minimum through n−1**.
   Queue enqueue/claim/outcome transactions hold the corresponding shared fence;
   the exclusive locks wait for earlier writers to finish. No Vn request
   is admitted yet. The final transaction uses READ COMMITTED so a producer that
   committed while draining cannot be hidden by an earlier snapshot.
5. `tesl_remove_empty_queue` independently checks staged source binding before
   mutation. It validates both full inventories against the actual predecessor
   inventory and its canonical source binding, checks the completed additive
   prefix against those exact staged hashes and canonical source bindings,
   verifies preservation of older queue contracts, and parses the **entire** physical
   document using `tesl_stage_canonical_children`, compares the direct removal
   node and unchanged entity node, and verifies the exact immutable receipt
   bytes. A matching header, hash, or embedded byte suffix alone is insufficient.
6. Under those fences, any removed-queue row blocks: pending, delayed, dead,
   quarantined, claimed, expired-claimed, or a stray schema-version row. Active
   conversion attempts and competing older conversion staging also block. Pending
   retained index jobs must finish through the existing index protocol. There is
   no DELETE/discard branch.
7. Unchanged surviving queues need not be empty. Pending, delayed and dead jobs
   retain payloads, scheduling, attempt counts and claim sequence; audited
   restamps move them to Vn. `tesl_row_queue_removal_restamps` records each job's
   **actual** old schema version, target n, full-contract hash, payload hash,
   claim sequence and removal receipt. Thus a V1 survivor can move directly to
   V3 without inventing a V2 stamp or weakening adjacent conversion/row-restamp
   constraints. Live surviving claims and quarantines safely block
   until resolved. Expired surviving claims are normalized through the existing
   pending/dead restamp convention. No live claimant is silently acknowledged.
8. One transaction writes the removal receipt in `tesl_row_queue_retirements`,
   registers the exact Vn physical/source inventory, records survivor restamps,
   publishes expansion and retirement lifecycle rows, and advances current,
   admission minimum and compatibility floor to Vn. There is no preliminary
   close-epoch that moves floors before the emptiness check. Fences remain held until
   commit. Old waiters recheck admission after acquiring their shared fence and
   are rejected by the permanent floor. Registering source or invoking ordinary
   publication directly cannot bypass the required removal receipt. An
   unfinished removal is pinned to the staged compiler ABI at the protected
   mutation, rather than merely checked by a later Go observer.
9. Replay validates the original immutable receipt and complete installed
   history, including when the database and binary have advanced beyond n. It
   does not lower later floors, rewrite later claims, restamp again, or relabel
   creator ABIs. Later additive epochs recognize the prefix closed by this
   receipt without synthesizing per-version epoch receipts. Historical
   descriptors and audit rows remain available after jobs are processed.

The new tables and SQL functions participate in the independent expected-catalog
and ACL checks. Request has no publication permission; Worker has no staging
table write permission. This extends the current development format5 catalog:
`tesl_schema_queue_removal_protocol (id=1, format=1)` is installed only during
the original fresh V1 installation and checked by readers and protected mutation.
Both release binaries in a rolling deployment must include this protocol in
their original V1 runtime. Older installations lacking these protected objects
are refused; this change does not silently upgrade their control catalog.

## Verification

The four-version witness is **V1 → additive V2 → RemoveEmpty V3 → additive V4**.
V2 and V4 add nullable row columns and new job identities to the surviving queue;
the original full contracts stay intact.
Full catch-up can stop at V2 with the original floor when V1/V2 jobs block V3,
then resume after ordinary claim/completion resolves those jobs. Historical
catch-up also starts from actual V2 and already-removed V3 deployments. V4's
`--schema contract V3` replays V3's receipt without changing V4 claims,
including after a separate close-epoch has raised the floor to V4.

`compiler/test/test_migration_queue_removal.ml` checks source decisions and emits
actual V1/V2 and four-version applications with the normal compiler. It compiles them with race
instrumentation, deletes the original source directory, and runs
`compiler/test/fixtures/queue-removal/application_test.go` against PostgreSQL.
`chain_test.go` covers full/historical/fresh-latest catch-up, blocked removal and
resume, actual V1/V2 survivor stamps, immutable later replay, all-older fence
coverage, races with V1 producers/claims while V2 is current, and forged earlier
prefix members, predecessor source, target-version and pending ABI inputs.
The fixture covers all nonempty categories, unchanged survivors and expired
claim normalization, in-flight producer/claim transactions, post-fence-wait
rejection, crashes before/after commit, immutable replay, protected mutation
refusal of forged source, restricted ACLs, orphan attempts, Worker startup, and
fresh-latest combined deploy. Compiler negatives cover missing/wrong decisions,
multiple removal decisions, surviving codec changes, stale App bindings,
an explicitly refused transforming prefix, and attempted identity resurrection
in an otherwise additive successor. The source suite also positively invokes a
reviewed removal and verifies that mutations to either the frozen predecessor
or current source cannot escape its guarded capture. Runtime negatives cover
missing claim authority and the original protocol marker, including refusal to
manufacture emptiness by erasing a claim.

The test is routed through Dune and `scripts/run-migration-tests.sh`. Runtime
generator, emitter and embedded Dune dependencies include the new sources.

Build explicit targets `bin/main.exe` and `test/test_migration_queue_removal.exe`
under `compiler/`; the ordinary Dune generators refresh the embedded runtime and
compiler ABI inputs. Run the suite against a private PostgreSQL cluster with
`TESL_MIGRATION_TEST_REQUIRE_POSTGRES=1`; native executables use race instrumentation.
`TESL_QUEUE_REMOVAL_OUTPUT` retains emitted fixtures and their build/runtime logs;
`TESL_QUEUE_REMOVAL_KEEP_FAILURES=1` retains failed source projects for diagnosis.
The optional `TESL_QUEUE_REMOVAL_TEST_FILTER` narrows an investigative native run;
the default runs every scenario. Follow with queue/history/Contract/catch-up and
Stage/facility/Drop regressions. Focused results do not constitute a full CI pass.

### Shared baseline formatting repair

The single indentation correction on the argument-specification line for
`tesl_register_stage_preparation` in `migration_stage_preparation.go` was applied
from root commit `66c22b2` before verification. It is a shared baseline defect,
separate from queue removal semantics. No old generated snapshots were copied;
embedded runtime and ABI-bearing snapshots are refreshed by their normal generators.
The separate stale cache-constructor assertion fix from that root commit is not
part of this feature's source changes.
