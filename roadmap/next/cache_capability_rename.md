# Rename the cache capability `cache <Name>` → `cacheCap <Name>`

**Status:** TODO (deferred — surfaced during the cache config-block migration).

## Why

`cache` is currently overloaded:
- the declaration keyword: `cache X = Cache { … }`
- the cache runtime functions: `Cache.get` / `Cache.set` / …
- the implicit per-cache **capability**: `requires [cache X]` (each cache gets its
  own `cache <Name>` capability token, name-specific like a database).

The capability use of `cache` should be disambiguated to `cacheCap` so the term isn't
overloaded:

```tesl
# now
fn getCachedProfile(id: String) -> Maybe String requires [cache UserProfileCache] = …
# wanted
fn getCachedProfile(id: String) -> Maybe String requires [cacheCap UserProfileCache] = …
```

## Scope (why it was deferred — it's a cross-cutting rename)

- **Parser / capability collection:** `validation_capabilities.ml` synthesizes the
  cache capability as `"cache " ^ c.name` (≈line 595); change to `"cacheCap " ^ c.name`.
  The `requires [...]` parser must accept `cacheCap <Name>` as the two-word cache cap.
- **Emit:** `emit_racket.ml` `cap_ident` special-cases the `cache ` prefix (collapses
  the space to `cache_<Name>`) and the `DCache` emit binds `(define-capability
  cache_<name>)`. Both must move to `cacheCap_<name>`.
- **Runtime macro:** `dsl/cache.rkt`'s `define-cache` macro builds the capability
  identifier as `(~a "cache_" name)` (≈line 276) — must become `cacheCap_`. The two
  (emit + macro) MUST stay in sync or the capability is unbound at expansion.
- **All usages:** every `requires [cache X]` in the cache `.tesl` (lesson59-cache,
  user-service-api) and `.ml` fixtures (test_cache.ml, cache-tests.tesl) → `cacheCap X`.

## Cache-capability GRANTING gap (do as part of this focused cache pass)

Once the cache capability is correctly emitted + enforced (below), the cache test
blocks in `example/learn/lesson59-cache.tesl` and `tests/cache-tests.tesl` FAIL at
runtime with `Missing capabilities: (cache_<Name>)`: they call cache handlers
(`requires [cache X]`) without establishing the capability. Previously this passed
ONLY because the cap was unbound/unenforced (so it was never checked). With the cap
real, the cache-capability GRANTING model needs settling:
- Should declaring `cache X = Cache { … }` make `cache_X` ambient/granted (like a
  cache is "available" once declared), or must callers thread `requires [cache X]`
  up to a `with capabilities`/`main` that grants it (like databases)?
- The two cache test files then need updating to establish the cap (or rely on the
  ambient grant) so their `Cache.get/set/delete/invalidate` test blocks run.
This is the only remaining red in the example batch (2 Tesl test failures); the rest
is green (examples 113/113, racket suite all-pass, OCaml dune green).

## Note on the current cache-capability emit fix (landed)

While migrating cache to `= Cache { … }`, the racket sweep (now reaching cache modules
after the tesl-test Q01 fix) exposed a PRE-EXISTING bug: the `cache <Name>` capability
was emitted space-separated (`#:capabilities [cache UserProfileCache]` → two unbound
identifiers) and no `(define-capability …)` was ever emitted, so cache modules never
raco-expanded. Fixed by: `cap_ident` collapsing `cache <Name>` → `cache_<Name>` at the
capability render sites, and emitting `(define-capability cache_<name>)` before each
`(define-cache …)`. The `cacheCap` rename above is a clean follow-up on top of this.
