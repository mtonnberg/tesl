# Rename the cache capability `cache <Name>` → `cacheCap <Name>`

**Status:** ✅ COMPLETE. The capability is now `cacheCap <Name>` end-to-end; the
declaration keyword stays `cache X = Cache { … }`. The focused pass also fixed
the cache-capability GRANTING gap and uncovered + fixed two latent cache-runtime
bugs (see below). Full example batch green: examples 113/113, Tesl tests 113/113,
Racket suite all-pass, OCaml dune green.

## What landed

- **Pipeline rename** (`cache <Name>` → `cacheCap <Name>` capability token →
  `cacheCap_<Name>` Racket identifier): `parser.ml` (`parse_cap_name` +
  `parse_capability_names` accept `cacheCap <UIdent>`), `validation_capabilities.ml`,
  `proof_checker.ml`, `emit_racket.ml` (`cap_ident`/`cap_list_str` + `DCache`
  `define-capability cacheCap_<name>`), `mutate.ml`, and the runtime macro
  `tesl/cache.rkt` `define-cache` (builds `cacheCap_<name>`).
- **All usages migrated** to `requires [cacheCap X]`: lesson59-cache, user-service-api,
  cache-tests.tesl, test_cache.ml, LANGUAGE-SPEC.md, and the hand-written DAP smoke
  fixtures (`tests/dap-*-smoke.rkt` `define-capability cacheCap_<Name>`).

## Cache-capability GRANTING gap — RESOLVED (threading, like databases)

Settled by precedent (lesson21 DB tests declare `requires [dbRead, dbWrite]` on the
test block): test blocks GRANT the caps they use. Each cache-using test block in
lesson59-cache.tesl and cache-tests.tesl now declares the precise `requires
[cacheCap …]`; pure `expect True` tests stay bare. NOT ambient auto-grant.

## Two latent cache-runtime bugs exposed by the granting fix (both FIXED)

Once the cap was granted, the tests ran far enough to hit real bugs the cap-failure
had masked:
1. **emit:** test / api-test / load-test `with-capabilities` (+ api-test `(list …)`)
   rendered the cap list with raw `String.concat " "`, so the two-word `cacheCap X`
   became two unbound identifiers. Fixed: those 4 sites now use `cap_list_str`
   (the same sanitiser used for function `#:capabilities`).
2. **runtime (`tesl/cache.rkt`):**
   - `mem-get!`/`pg-get!` returned a non-canonical `Maybe` (`'Nothing` /
     `(list 'Something v)`) instead of the `adt-value` the emitted case-match and
     handler-return net expect. Fixed to return `Nothing` / `(Something v)`.
   - the in-memory backend stored raw values but `mem-get!` tried to JSON-`deserialize`
     them (`string->jsexpr "foo"` → fail → `#f` → every string-cache hit became a
     miss). Fixed: in-memory backend stores/returns raw (no JSON round-trip);
     `mem-set!` unwraps named-values to match the PG path.

---

## Original notes (kept for context)

**Status:** TODO (deferred — surfaced during the cache config-block migration).

## Why

`cache` is currently overloaded:
- the declaration keyword: `cache X = Cache { … }`
- the cache runtime functions: `Cache.get` / `Cache.set` / … (this is fine since this is a module with capital C)
- the implicit per-cache **capability**: `requires [cache X]` (each cache gets its
  own `cache <Name>` capability token, name-specific like a database). (this is the problem since this is the exact word as the declaration keyword)

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
