# Row generation and trigger prerequisite

This is a private runtime prerequisite for the first transforming migration.
It does not enable `Migrate` or `Derived` execution. The production catalog still
refuses unrecorded triggers. The compiler must not emit an executable transform
plan until generation registration, adapters, processing ABI checks, backfill
and retirement are integrated.

`migration_row_generation.go` derives one invalidation function and trigger from
an exact namespace, table, consecutive entity generations and physical source
columns. The descriptor owns a sorted copy of those columns. Object names derive
from its hash, but a name is never sufficient identity. SQL identifier quoting and
function-body quoting preserve embedded quotes, backslashes and dollar delimiters.

An old writer changing a source column lowers the row's `_tesl_v` to the previous
generation. The trigger compares actual values with `IS DISTINCT FROM`, including
NULL and JSONB. It leaves unrelated updates alone. It lowers **NEW**, so coexisting
triggers preserve an earlier trigger's lower marker in either execution order.
A table-specific, transaction-local writer generation suppresses invalidation
only for a writer at or above the target generation. Setting that value requires
the generated writer to materialize the complete target row; the trigger cannot
prove that obligation itself.

`migration_catalog_trigger.go` observes trigger and function attributes in the
same SQL snapshot as their table. It records relation identity, events, timing,
enablement, arguments, conditions, constraints, transitions, function body,
signature, configuration, owner and ACL. Requested deployment roles additionally
have effective privilege observations. Unrelated cluster roles do not change the
fingerprint. The observer never executes stored trigger code and requires no
temporary objects. Tables without triggers retain their previous fingerprint.

The private invalidation checker compares the actual observation with the exact
generated contract, including the table and function owner. It does not establish
the descriptor's persisted provenance or substitute for deployment role checks.
The protected queue candidate continues to verify its foreign-key triggers with
its existing exact checker before omitting them from ordinary table comparison.

Real PostgreSQL tests cover old, current and later writer generations; commit and
rollback of the local writer setting; valid NULL targets; JSONB equality; both
coexisting-trigger orders; exact quoted identifiers; and malformed writer values.
The catalog tests change trigger behavior, function definitions, ownership and
privileges under the original names, and verify that a lookalike trigger on a
different table cannot satisfy the descriptor.

Remaining integration requirements include permanent markers in authentic
predecessor binaries, immutable generation registration, complete facility
inventory, typed read/write adapters, migration-wide processing ABI pinning,
bounded-age `xmin` compare-and-swap with leased backfill, and fence-held retirement.
Passing these mechanism tests does not establish a rolling application migration.
