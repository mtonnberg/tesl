This fixture supports `test_migration_row_forward.ml`.

The test compiles and retains V1 before compiling V2, using the compiler's real
embedded runtime. It then builds another compiler in an isolated copy with a
query-only source comment change and emits that compiler's V1 and V2. No emitted
runtime, ABI or migration metadata is patched in the acceptance test.

The Go test launcher drives the generated application's database and compiled
row adapters. Its private test bridge obtains the existing registered physical
plan and opens actual admitted transactions; it cannot fabricate a transaction
token. This tests the internal first V1-to-V2 protocol and typed data path. It is
not the public Main/HTTP rolling deployment test, which additionally needs the
normal generated entity access path.

The required PostgreSQL migration gate runs the suite. Runtime subprocess tests
cover worker crash receipts, unchanged predecessor observation, actual Tesl Row
and Reject branches, canceled writes, generation demotion, and compiler ABI
ordering before and after the first materializing write.
