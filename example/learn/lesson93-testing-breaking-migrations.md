# Lesson 93 — Test breaking database changes across a rolling deployment

For a non-additive migration, test **stored values and both application versions**.
A successful compilation proves types and evidence are consistent; it cannot
decide whether the conversion preserves the business meaning you intended.

## Choose the right example

| Change | Lesson | Important assertion |
|---|---|---|
| Remove a field | [86 — removing fields](lesson86-removing-fields.md) | New writes still supply the old field until Contract |
| Change a stored record | [87 — JSONB records](lesson87-jsonb-record-migration.md) | Both codecs read their own retained representation |
| Record to ADT | [88 — JSONB Retype](lesson88-jsonb-adt-retype.md) | Every constructor has a deliberate forward/reverse mapping |
| Add a proof | [89 — revalidation](lesson89-proof-revalidation.md) | Invalid rows reject and remain unfinished until repaired |
| Strengthen, weaken or remove a proof | [90 — changing proofs](lesson90-changing-field-proofs.md) | Reverse writes carry the exact historical proof |
| Remove an entity | [91 — table removal](lesson91-removing-a-table.md) | Old requests work until retirement; only the reviewed table disappears |
| Change the same field again | [92 — repeated Retype](lesson92-repeated-retypes.md) | Each edge uses its immediate predecessor and distinct storage |

## First test the pure conversion

Supply representative old-row fixtures, then write `test` blocks that inspect
the returned `Row` or `Reject`. Fixtures alone are smoke tests: a generated
fixture test can succeed when the conversion returns `Reject`.

Include non-default values, empty values, Unicode, each ADT constructor, `Nothing`
and `Something` for nullable fields, and values immediately around a changed
proof's acceptance boundary. For a rejected row, assert the intended rejection
reason. For an accepted row, assert its key and every meaningful converted value.

Test the reverse adapter separately with a **newly created current row**. Testing
only old rows sent through forward then reverse conversion misses current values
that old code cannot represent. If the reverse mapping is lossy, state its fallback
and test it. As lesson 90 explains, a later old write can cause the new reader to
reconstruct that fallback even when the old writer changed an unrelated field.

## Then test the actual deployment window

Use separately compiled old/current executables and retained PostgreSQL data.
The migration suite checks these stages:

1. **Before expansion:** insert non-default rows through the original app.
2. **During overlap:** read through both versions; insert and update from both;
   inspect both physical representations. A lazy read must not claim durable
   backfill completion.
3. **Late old writes:** write after worker conversion and verify invalidation
   causes current readers to obtain the newly converted value.
4. **Failure:** reject conversion or a bulk write and verify rows, generations
   and durable processing metadata have the expected atomic outcome.
5. **Contract:** retain an admitted old transaction while contraction waits;
   repair rejected rows; verify the reviewed cleanup and refusal of retired apps.
6. **Restart and successor:** restart after an interrupted operation, verify
   receipts prevent duplicate work, then deploy the next checked revision.

Table removal also needs dependency tests: a view on the table must refuse
destructive cleanup without cascading into other objects. Retype needs physical
column assertions after Contract, so an apparently correct logical read cannot
hide a stale retained representation.

## Run the gates

From the repository root:

```sh
# Compiler/source tests for the refresh workflow and precise source edits.
nix develop --command bash -c 'dune exec --root compiler ./test/test_migration_refresh.exe && dune exec --root compiler ./test/test_migration_source_syntax.exe'

# Full private PostgreSQL migration gate, including compiled histories and races.
nix develop --command bash scripts/run-migration-tests.sh
```

The second command owns a temporary PostgreSQL cluster and requires PostgreSQL;
it does not turn missing PostgreSQL into passing skipped integration coverage.
The default gate includes the V1–V13 Todo history, primitive/JSONB field removal,
Retype, proof changes, revalidation and table removal. Optional pooler, replica
and crash tiers are separate configurations documented by the test harness.

When reporting results, distinguish pure conversion tests, compiler refusal
tests, generated-code execution and live PostgreSQL lifecycle tests. Together
they answer different questions; none is a substitute for the others.
