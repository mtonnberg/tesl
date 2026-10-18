# Staged uniqueness: Contract, enforcement and cancellation

The connected PostgreSQL lifecycle is V1 ordinary storage, V2 nonunique
preparation, V3 guarded declaration and reviewed promotion, then V4 reliance.
It supports the existing Bool, int4/int8 and C/POSIX TEXT key domain, including
nullable keys. See [guarded windows](stage-guard-window.md) for mutation coverage,
transaction identity and the managed probe profile.

## Reviewed promotion

V2 declares a preparation and V3 declares a distinct target name:

```tesl
# V2
staging unique index [email] as "email_preparation"
# V3
unique index [email] as "email_unique"
```

V3 still cannot use `onConflict [email]`. Its reviewed companion names exactly the
promoted semantic keys, rather than supplying SQL or index hashes:

```tesl
module Schema.Users.Migrate.V3Contract exposing [contract]
import Tesl.Migration exposing [Contract, Promote(..)]
import Schema.Users.Migrate.V3

contract = Contract {
  of: Schema.Users.Migrate.V3
  drops: []
  tighten: []
  promote: [PromoteStage User [email]]
}
```

Prepare this companion **before freezing V3 for the next revision**. Frozen
migration closure records include the Contract companion; adding, removing or
changing it afterward is rejected. Run the reviewed V3 binary's
`--schema contract V3 --json`, or let checked catch-up/deployment execute the
required historical Contract before V4 expansion.

The compiler resolves each selector to the full pending preparation and target
descriptor. Protected SQL compares the complete ordered operation inventory and
derives the entire settled representation from the recorded guarded physical plan.
Only adding the target UNIQUE indexes is authorized: changing columns, marker
defaults, generations, entities or other indexes is not. Rehashing a forged
descriptor or embedding legitimate bytes inside an atom does not grant authority.

## Durable ordering and provenance

1. Store the exact reviewed Contract intent and its actual executor compiler ABI.
2. Drain older writer transactions and compatibility plans using the existing
   checked epoch-retirement protocol. Commit the minimum version and compatibility
   floor. V3's guards are already active and remain required.
3. Revalidate the reviewed Contract, immutable preparation and committed retirement.
   Commit the promotion handoff and target index jobs. No target job exists before
   these checks, and no DDL actor can see it before this commit.
4. Build separate targets with `CREATE UNIQUE INDEX CONCURRENTLY` through the
   existing job, lease, backend-tag and recovery machinery.
5. After exact catalog validity and protected job completion, remove each guard
   trigger and function and record enforcement in one transaction. The UNIQUE
   index enforces the key before the trigger is removed.

A crash between floor retirement and handoff leaves a guarded, repair-capable V3
with no new target jobs. A crash after physical index validity preserves that
index: recovery observes it instead of dropping or rebuilding it. A crash during
guard removal rolls back both DDL and the enforcement receipt.

Contract jobs have their own provenance. Their IDs derive from the Contract hash
and operation position, and they use the Contract executor's recorded ABI. They
do not append invented expansion receipts, borrow the earlier expansion's ABI,
or rewrite preparation provenance. Unfinished builds remain ABI-pinned; completed
jobs retain their actual creator. Cancellation can retire an old job without
pretending to execute its build under a different ABI.

The older epoch's `contracted` bookkeeping step is **not** a unique-enforcement
receipt. V4 requires the stage-specific receipt and exact valid/ready/live target
catalog, including the recorded index OID and conservative `indcheckxmin=false`
check. Guarded V3 admissions check native target validity after guard removal too.

## Duplicates and recovery

| Stage state | Meaning |
|---|---|
| `pending` | Preparation, possibly with an active V3 guard; no promotion handoff |
| `promoting` | Reviewed handoff committed; target work or enforcement publication remains |
| `blocked_duplicates` | PostgreSQL reported `23505` during the target build |
| `enforced` | Exact target job/catalog verified and enforcement receipt committed |
| `cancelled` | Reviewed pending-stage deletion completed its fenced index retirement |

`--schema status --json` exposes stage state, target and Contract identity,
enforcement OID, cancellation provenance and the index error detail (including
the duplicate key reported by PostgreSQL). A finite Contract attempt returns
`blocked_duplicates` after a real failed build. V3 stays ready for explicit
DELETE/rename repair. Retry the same Contract afterward; ordinary index services
also resume registered work. No migration automatically deletes or rewrites rows.

The guard's eligible index family includes only exact reviewed target jobs in
addition to its preparation and PK indexes. Known invalid/in-progress targets do
not disable V3 writes. The valid preparation remains available throughout build
and invalid-target cleanup. A valid target may supply the probe once usable.
Targets cannot become generic unreviewed index-registration requests.

## Pending-stage cancellation

Deleting the staging declaration is the reviewed source decision. There is no
additional mandatory approval token or migration constructor. The cancellation
physical plan retains the full prior descriptor and the exact before/after source
binding; a stage with activation history cannot be cancelled this way, even if its
preparation row still says `pending`.

The Worker retires older writer/compatibility plans, acquires the exclusive barrier
for the exact preparation index job, verifies the existing index shape and drops
it. Index removal, terminal job status and the cancellation receipt commit together.
The original job row, creator ABI and attempt count remain; active lease/failure
status is cleared. Application rows and queued payloads are not rewritten.

Failed or never-built preparations can be cancelled without first repairing data
to build an unwanted index. Finite catch-up skips building preparations that its
checked upcoming cancellation will retire. Later expansion requires completed
cancellation receipts. Ordinary additive successors and duplicate writes continue
to work after cancellation; historical index names remain reserved.

## Scope and verification

The stage extension is format 2; guarded, reliance and cancellation physical plans
use v10, v11 and v12 respectively. All releases in the native fixture are compiled
with the current toolchain. Pre-extension development catalogs are refused rather
than adopted implicitly.

The mandatory `test_migration_row_indexes` compiler suite builds actual releases
and runs PostgreSQL/race tests for guarded writes, reviewed authority, in-flight
older writers, real concurrent UNIQUE-build waits, duplicate repair/retry,
enforcement switchover, lease takeover, crash recovery, V4 conflict reliance,
catch-up/deployment, and cancellation of failed/unbuilt preparations.

The [major verification](stage-major-verification.md) exercises PostgreSQL 14.23,
17.10 and 18.4 with real compiled/race fixtures and no skipped Go tests. This supplies
bounded scoped technical evidence. The complete repository CI gate remains
required; these targeted results do not establish a full CI pass.

Native UUID/bytea mappings, custom equality/collations/opclasses, composite staged
keys and NULLS NOT DISTINCT remain unsupported. Existing restrictions on combining
stages with row transformations, queue conversion, RemoveEmpty or Drop remain.
Simultaneous promotion/cancellation and another staged decision after an enforced
reliance window are explicitly refused. Guarded/enforced cancellation and reuse of
retired index identities require a separate checked retirement protocol.
