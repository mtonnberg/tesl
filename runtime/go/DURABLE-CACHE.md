# Durable caches with Worker topology

The emitted Go application uses `NewCacheOnArtifact`. In a format5 Worker
database whose compiled application declares caches, `--schema install` creates
the optional `tesl_cache_artifacts` storage extension as the control Owner.
Re-running that application's Installer adds it to an existing format5
installation, or verifies it if already present. Request startup with declared
caches requires that extension; requests never create it. Unversioned databases
retain their legacy storage path. Format5 caches require Worker topology.

The table is unlogged: it shares values across processes but PostgreSQL may
empty it after a crash. It is a cache, not a persistent source of application
records. Installer owns DDL. Request receives exactly SELECT, INSERT, UPDATE
and DELETE; Worker receives no cache data privileges. The table shape, owner,
persistence, constraints, indexes, triggers and ACL are checked using the existing
catalog reader and an independent expected descriptor. Unknown protected
relations remain rejected. A pre-existing legacy `tesl_cache` is not adopted.

## Rolling versions

Each emitted artifact contains a SHA-256 codec identity covering the complete
generated source closure and runtime. Cache declarations use module-qualified
names. Storage keys are `(cache_name, codec, key)`, so instances of the same
artifact share values, while different artifacts cannot decode or overwrite
each other's values. This is deliberately conservative: even a source change
unrelated to the cache may make the new artifact's cache cold. It does not claim
that different artifacts' codecs are equivalent.

Failed decodes return a miss and perform no deletion, including when another
writer replaces the same key while a decoder runs. Expiry is checked by SQL.
Explicit delete, literal-prefix invalidation and reset clear all codec versions
of the logical cache; they are intentional invalidations, not decoder cleanup.

Binaries predating this extension reject its unknown protected relation. Deploy
extension-aware readers before adding it if those binaries must remain running.
Rolling application versions built with this implementation recognize the same
extension. The extension does not change retained row/queue migration inventories:
cached values have no conversion or preservation obligation.

## Combined installation and validation

One Installer invocation installs every declared cache, email and SSE extension
before committing, on fresh and existing installations. A later binary without
a declaration still verifies and retains its installed storage. See
[`MIGRATION_FACILITIES.md`](teslrt/MIGRATION_FACILITIES.md) for the combined grants
and test coverage.

`migration_cache_test.go` covers Installer idempotency and adding the extension,
missing-table refusal, request DDL denial, same-artifact sharing, different-artifact
misses, decode/replacement races, expiry, literal-prefix invalidation and catalog/
ACL drift. The compiler's `durable cache artifact identity` test checks emitted
constructors, stable/revised identities and inclusion of all facility runtime files.

Run the PostgreSQL migration matrix and compiler emission/embedded runtime gates
before merging. Integration has only been syntax-checked; runtime tests have not
been run. Regenerate the embedded Go snapshot once from the integrated sources.
