# Staged TEXT preparation

`staging unique index [field]` accepts the exact builtin `String` or `Maybe String`
on an existing TEXT column, with no storage annotation or `@db(text)`. It creates
a **nonunique** btree index and an immutable pending stage. Promotion, cancellation,
unique conflict arbiters and Memory uniqueness enforcement remain refused.

## Equality and storage contract

The canonical semantic descriptor carries
`default-text-btree-libc-c-posix-v1`, alongside the complete typed field contract
and reachable proof/helper/codec definitions. This requirement participates in the
stage ID and the source and physical descriptors. The runtime refuses a text
descriptor that substitutes the old `default-btree` requirement, even if rehashed.
Owned types merely named String are not builtin String; implicit nominal wrapper
support is not added.

The runtime resolves the pinned PostgreSQL default collation (OID 100,
`pg_catalog.default`, provider `d`, deterministic) through `pg_database`. Both
`datcollate` and `datctype` must be exactly C or POSIX, with libc provider `c`.
PostgreSQL 14 has no database provider field and uses libc; later versions are
checked through that field. C.UTF-8, other locales, ICU and builtin-provider
databases are refused. A named custom alias is not the pinned default. Column and
index collation OIDs must still match the exact expected catalog: explicit column
`COLLATE "C"` is a different catalog and remains unsupported. There is no new
`@collation` syntax.

Columns remain TEXT. Empty strings, case, trailing spaces and composed versus
decomposed Unicode are preserved; no normalization, trimming, old-carrier
reinterpretation or conversion to native UUID/Bytes occurs. PostgreSQL TEXT's
existing encoding/NUL restrictions still apply. NULL values remain distinct.

**TEXT is not an unbounded btree key.** This explicit stage intent accepts
PostgreSQL's index tuple-size limit. Oversized existing values fail the index job
through its existing `failed`/blocked-readiness path; later oversized writes can
fail too. No fixed character count is promised (encoding, compression and server
page configuration affect the bound). Ordinary concurrent indexes on unbounded
existing fields retain their previous refusal. The exception is derived from the
verified stage/source/job inventory, never from a supplied database flag.

## Compatibility and evidence

Bool/Int32 stage identities and storage formats are retained. This adds an equality
requirement for newly supported text descriptors without changing stored-value
semantics revision 5: the values and codecs are unchanged. The compiler/runtime
source ABI changes automatically. Full source, descriptor, dependency closure and
ABI comparisons remain enforced; unfinished jobs are still compiler-ABI pinned.
This does not promise archived pre-extension binary interoperability.

Mandatory tests include:

- `test_staged_indexes`: String/Maybe String with optional `@db(text)`, nominal
  shadow refusal, existing proof-dependency and promotion/cancellation checks.
- `TestStageText*`: pure catalog fixtures covering same default OID with non-C
  locales/providers, nondeterminism, named/namespace/OID spoofing, and coherently
  rehashed equality-descriptor substitution.
- `test_migration_row_indexes` / `TestPgStagePreparation*`: compiler-generated V1,
  stage V2 and carry V3 with Bool, Maybe Int32, String and Maybe String; predecessor
  writes including empty/case/space/Unicode values, duplicate writes and multiple
  NULLs; restart, catch-up, exact column/index collation drift, descriptor/source/
  ABI mutations, protected registration attacks and oversized build failure.
- Real private C/POSIX databases, plus non-C locales when installed. Unavailable
  extra locales are reported; non-C/provider catalog-fixture refusals remain
  mandatory independently of installed locales. No host locale is changed.

The focused compiler suite and private PostgreSQL race stage suite
passed during implementation. Real C and POSIX databases were accepted; installed
C.UTF-8 and en_US.UTF-8 databases were rejected. Inventory, storage,
table-Drop planning and compiled PostgreSQL execution, embedded runtime seam,
compiler ABI, ordinary compiled index tests, row-baseline/facility race regressions
and reviewed queue removal (including both compiled PostgreSQL histories) also
passed. The shared migration gate includes a mandatory `stage-text-equality`
phase as well as the compiled native stage suite.
