# Native Cache

## Goal

It is just as easy to work with a performant cache in Tesl as it is to work with SQL and queues.

## Design

**PostgreSQL unlogged table backend.** Starts with Postgres (consistent with "Boring Architecture" — queues, pub/sub, and cache all in one database). Valkey/Redis support can be added later without changing the API surface.

**Key differentiator:** Transactional cache invalidation. Because the cache is a Postgres table, `Cache.set` / `Cache.delete` inside a `withTransaction` block participates atomically with the surrounding database writes. This eliminates the dual-write problem that plagues Redis-alongside-Postgres architectures.

**Typed entries.** Each cache block declares the value type at definition time. This gives the compiler a concrete return type for `Cache.get` (no runtime cast needed). If a stored value cannot be deserialized (e.g. the app was updated with new required fields on the record), the runtime silently invalidates the stale entry and returns `Nothing`. The cache degrades gracefully across schema evolution.

**Multiple caches.** Declare as many `cache X { ... }` blocks as needed, each with its own name, database, value type, and TTL. Each is independent.

**Cache-specific capability.** The capability is `cache UserProfileCache` (name-specific), not a generic `cache`. This mirrors `database MainDB` — each named resource gets its own capability token.

## Syntax

```tesl
cache UserProfileCache {
  database: MainDB
  defaultTtl: 3600
  valueType: UserProfile
}

cache ProductListCache {
  database: MainDB
  defaultTtl: 300
  valueType: List Product
}

handler getUserProfile(id: String) -> UserProfile 
  requires [database, cache UserProfileCache] =
  let cached = Cache.get UserProfileCache ("profile_" ++ id)
  case cached of
    Just profile -> profile
    Nothing ->
      let (profile ::: proof) = check fetchProfileFromDb(id)
      Cache.set UserProfileCache ("profile_" ++ id) profile 3600
      { profile ::: proof }
```

## Operations

```tesl
Cache.get      CacheName key               # -> Maybe ValueType (typed from declaration)
Cache.set      CacheName key value ttl     # -> Unit (ttl optional, uses defaultTtl)
Cache.delete   CacheName key               # -> Unit
Cache.invalidate CacheName prefix          # -> Unit (removes all keys starting with prefix)
```

## Implementation Details

**PostgreSQL schema (unlogged for performance):**
```sql
CREATE UNLOGGED TABLE IF NOT EXISTS tesl_cache (
  key        text PRIMARY KEY,
  value      jsonb NOT NULL,
  expires_at timestamptz
)
```

**Background sweeper thread:** Runs every 60 seconds, deletes `WHERE expires_at < NOW()`.

**Stale entry handling:** If deserialization fails (schema changed), the entry is deleted and `Nothing` is returned. No crash, no error propagation.

**Serialization:** Uses the same codec mechanism as API endpoints. The codec for `valueType` is automatically derived by the emitter (no user annotation needed).

## Open question (resolved)

Allow cache calls inside transactions? **Yes.** This is the unique value-add of the Postgres-only approach. Transactional cache invalidation is impossible with Redis but trivial with a Postgres cache.

## Future work

- Redis/Valkey backend (same API surface, different runtime)
- `Cache.getOrSet`: atomic read-through helper
- Proof-aware caching: store proof metadata alongside value

## Test target

At least 150 tests across OCaml compiler tests (`compiler/test/test_cache.ml`), Racket runtime tests (`tests/cache-test.rkt`), and .tesl test files (`tests/cache-tests.tesl`).

New lesson: `example/learn/lesson31.tesl`
