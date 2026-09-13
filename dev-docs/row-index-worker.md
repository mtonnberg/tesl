# Format 5 concurrent index worker

> Audience: compiler and runtime maintainers.

The private format 5 candidate builds checked, nonunique B-tree indexes on
existing tables through the generated `--schema worker` command. An index is
admitted only when every key has a supported fixed-width type, or every key is a
new nullable column with no default. Existing unbounded keys, unique indexes,
and terminal/removal jobs remain refused. New-table indexes still use the
transactional empty-table create operation.

The worker derives the complete ordered descriptor from adjacent checked
physical histories. Registration verifies the full source/catalog state before
and after the protected SQL call in one transaction. SQL separately binds the
format, physical hash, intent, ordinal, immutable descriptor replay and lease.
The Worker role already owns entity DDL; SQL does not independently prove the
descriptor's semantic lineage.

Histories without concurrent index operations preserve the existing row worker
service, including original V1 without a physical companion. For indexed row
histories, the actor holds a version fence only during initial admission and
each active DDL job; idle polling holds no retirement fence. Format 3 retains
its existing round lifetime.

The existing concurrent-build actor owns two bounded connections, its lease and
nonqueued job lock. Failed builds are recorded, observed, cleaned and retried;
connection loss causes fresh observation before further DDL. Format 3 continues
using the same actor through its unchanged public history entrypoints.

Physical verification and writer readiness are separate. Fixed-width nonunique
indexes can remain pending or failed while current and old writers serve. For a
new nullable unbounded key, current writers wait for both PostgreSQL VALID,
READY and LIVE flags and the protected valid job record. Older writers continue
serving with their exact source projection. A worker may inspect and complete an
unready job; request initialization waits within its existing startup budget.

The compiler test `test_migration_row_indexes` builds original V1 before future
source exists, then V2 with a Bool index and V3 with a new nullable String index.
It removes the Tesl source and loose JSON before ordinary generated Main and
schema commands run. Native checks cover retained old writes, canceled builds,
cleanup/retry, both readiness records, exact registration rollback and a killed
registration backend. A separate test-only probe accepts only the actual
emitted Database pointer to exercise a wrong descriptor at the internal boundary.
The compiler's public routing and deployment/adoption coverage remain separate.
