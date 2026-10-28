# Legacy additive history to row adoption

> Audience: contributors implementing and reviewing the migration protocol bridge.

This first slice inspects the unpublished transition from deployed public control
format 3 to the row format 5 candidate. It performs no DDL, registration, admission,
receipt update, or automatic startup upgrade. Existing public compilation and
format 3 handlers remain unchanged. A successful inspection is a diagnostic
snapshot, not a token an installer may later use as authority.

## Source and observation boundary

The caller supplies the actual generated Database and a dedicated Request-role
connection. The source comes only from that sealed application's linked public
version-3 history and complete queue companion; no supplied JSON, source flag,
catalog list, or hash is accepted. Missing queue metadata remains unknown. The
first slice requires empty current and historical queue inventories and no actual
queue/cache/facility declarations; it preserves each source-seal provenance label
without claiming those labels proved historical absence.

One bounded read-only repeatable-read transaction validates the exact control3
layout/functions/ACLs/roles, UUID and fence registry, every receipt from the real
installed origin through current N, the complete index-job inventory, and all
entity tables and grants. N must equal this binary's source revision. Pending
expansion, pending/failed/terminal index work, unknown protocols, extra entities,
columns, indexes, functions or marker columns refuse. Unlike an ordinary retained
reader, this boundary accepts no benign extra catalog objects. Named secondary
indexes must also match the checked source.

A diagnostic digest retains exact immutable legacy version/expansion/object rows,
including creator ABI, execution identity and timestamps. Heartbeats and lease
expiry are not historical source authority. No legacy row is rewritten. The
prospective anchor is schema N, with generation 1 per existing table, together
with the exact checked source storage identity and the observed catalog digest.
No row V1 through N expansion or processing receipts are constructed.

## Transition model to implement after review

The explicit installer command remains `app --schema install --worker ROLE
--request ROLE`; normal Request/Worker boot must refuse an incompatible catalog.
Before any installer transition, deploy bridge readers capable of validating both
exact legacy and exact preparation/completed catalogs. The absence of old
heartbeats cannot prove obsolete binaries will never restart. Original pre-bridge
binaries remain original artifacts and are expected to refuse reconnection after
the new catalog publishes. This first read-only artifact is not yet that dual
reader.

The installer must re-observe under the family boot lock followed by the existing
installer coordination lock; it cannot trust a prior diagnostic snapshot. A
protected adoption descriptor will bind the legacy prefix digest, UUID/fence,
installed origin, anchor N, current source type/storage closure, ordered exact
marker operations and target row catalog. Its provenance is separate from legacy
creator receipts. A resumable preparation phase adds one `_tesl_v smallint not
null default 1` marker per short transaction, recording its exact source-bound
receipt atomically with each DDL. Only matching adoption progress may admit a
pre-existing marker; arbitrary lookalikes refuse. Each transaction holds only that
table's DDL lock, preserving the roadmap's bounded lock footprint.

Publication must drain the bridge's actual request representation fences with
all-or-release try-locks, revalidate every marker and complete catalog, and publish
the row anchor at N atomically. The positive writer fences of public format3 are
insufficient evidence for old read transactions; bridge readers need a reviewed
read/write lifetime mechanism before marker/publication code is enabled. UUID,
fence allocation and genuine legacy history remain unchanged. Legacy source
validation and row anchor validation remain separate persisted prefixes.

## Required unresolved contracts

* A compiler-owned target-N typed source/physical anchor must be paired with the
  exact legacy source. A raw legacy catalog cannot construct nominal row codec
  authority. The first snapshot only proposes generation 1 and does not register
  a row physical history.
* Current row5 readers/DDL assume fresh origin 1 in several places. They need an
  explicit adopted anchor branch and future transforms beginning at N+1, without
  manufacturing historical row receipts or mapping schema version to generation.
* Exact preparation layout, installer privilege separation, per-table receipt
  grammar and bridge reader fences require independent review and crash tests.
* Queue4, nonempty queue/facility histories, unfinished work, pre-versioning
  adoption and incompatible stored-value contracts remain outside this slice.

## Acceptance of this slice

Build original V1 through the ordinary current public compiler before freezing
its source. Generate a genuine additive V2 with unchanged App handlers, then build
a preparatory bridge binary through the same ordinary compiler route including
the inspector runtime. Remove original source paths before runtime. Original V1
installs/writes format3; V2 expands it and both retained handlers keep operating.
A Request connection observes anchor V2/generation1, unchanged UUID/fence and
creator receipts; independent snapshots prove inspection changed neither tables,
rows, receipts nor metadata. Same-version old/new inspector source at V1 provides
the smallest case; the V2 case rules out an accidental hardcoded V1 anchor.

Freshly altered receipt/source/catalog/owner/queue inputs, pending work, a forged
marker, wrong format and an unregistered Database refuse. Source-absent original
binaries are not privately rebuilt through the row compiler. No PostgreSQL
execution starts until the shared test lane is allocated.
