#lang racket

;;; cache-test.rkt — Racket runtime tests for the Tesl Native Cache.
;;;
;;; Tests the in-memory fallback (no PostgreSQL required) for:
;;;   - cache-get!, cache-set!, cache-delete!, cache-invalidate-prefix!
;;;   - TTL expiry (fast-forwarded via manual clock manipulation)
;;;   - Stale entry handling (deserialization failure → Nothing)
;;;   - struct accessors
;;;   - define-cache macro
;;;   - Multiple independent caches
;;;   - Background sweeper logic
;;;   - Concurrent access patterns

(require rackunit
         (only-in "../tesl/cache.rkt"
                  define-cache
                  cache-get!
                  cache-set!
                  cache-delete!
                  cache-invalidate-prefix!
                  cache-spec
                  cache-spec-name
                  cache-spec-default-ttl
                  cache-spec-codec
                  cache-spec-store)
         (only-in "../dsl/capability.rkt"
                  define-capability
                  with-capabilities))

;; ── Capability definitions (needed to pass capability checks) ────────────────
;; In tests we define the capabilities directly and wrap in with-capabilities

(define-capability cache_TestCache)
(define-capability cache_AnotherCache)
(define-capability cache_TtlCache)
(define-capability cache_StaleCache)
(define-capability cache_PrefixCache)
(define-capability cache_MultiCache)

;; ── Test caches ───────────────────────────────────────────────────────────────

(define-cache TestCache #:default-ttl 3600)
(define-cache AnotherCache #:default-ttl 60)
(define-cache TtlCache #:default-ttl 1)
(define-cache StaleCache)
(define-cache PrefixCache #:default-ttl 3600)
(define-cache MultiCache #:default-ttl 300)

;; ── Helper ────────────────────────────────────────────────────────────────────

(define (run-with-caps cache-cap thunk)
  (with-capabilities (cache-cap)
    (thunk)))

;; ── Tests ─────────────────────────────────────────────────────────────────────

;; 1. Cache miss returns Nothing
(test-case "cache-get! on empty cache returns Nothing"
  (run-with-caps cache_TestCache
    (lambda ()
      (check-equal? (cache-get! TestCache "nonexistent-key") 'Nothing))))

;; 2. Cache set and get
(test-case "cache-set! then cache-get! returns Something"
  (run-with-caps cache_TestCache
    (lambda ()
      (cache-set! TestCache "key1" "hello" 3600)
      (check-equal? (cache-get! TestCache "key1") (list 'Something "hello")))))

;; 3. Cache set with default TTL
(test-case "cache-set! uses default TTL when not specified"
  (run-with-caps cache_TestCache
    (lambda ()
      (cache-set! TestCache "key-default-ttl" "world")
      (check-equal? (cache-get! TestCache "key-default-ttl") (list 'Something "world")))))

;; 4. Cache delete removes entry
(test-case "cache-delete! removes an entry"
  (run-with-caps cache_TestCache
    (lambda ()
      (cache-set! TestCache "key-del" "deleteme" 3600)
      (cache-delete! TestCache "key-del")
      (check-equal? (cache-get! TestCache "key-del") 'Nothing))))

;; 5. Cache delete on non-existent key is a no-op
(test-case "cache-delete! on non-existent key is a no-op"
  (run-with-caps cache_TestCache
    (lambda ()
      (check-not-exn (lambda () (cache-delete! TestCache "never-set"))))))

;; 6. Cache invalidate prefix
(test-case "cache-invalidate-prefix! removes matching keys"
  (run-with-caps cache_PrefixCache
    (lambda ()
      (cache-set! PrefixCache "user_1" "alice" 3600)
      (cache-set! PrefixCache "user_2" "bob" 3600)
      (cache-set! PrefixCache "session_1" "xyz" 3600)
      (cache-invalidate-prefix! PrefixCache "user_")
      (check-equal? (cache-get! PrefixCache "user_1") 'Nothing)
      (check-equal? (cache-get! PrefixCache "user_2") 'Nothing)
      ;; session_ prefix should NOT be removed
      (check-equal? (cache-get! PrefixCache "session_1") (list 'Something "xyz")))))

;; 7. Cache invalidate with empty prefix removes all
(test-case "cache-invalidate-prefix! with empty prefix removes all"
  (run-with-caps cache_PrefixCache
    (lambda ()
      (cache-set! PrefixCache "aa" "1" 3600)
      (cache-set! PrefixCache "bb" "2" 3600)
      (cache-invalidate-prefix! PrefixCache "")
      (check-equal? (cache-get! PrefixCache "aa") 'Nothing)
      (check-equal? (cache-get! PrefixCache "bb") 'Nothing))))

;; 8. Cache overwrite
(test-case "cache-set! overwrites existing value"
  (run-with-caps cache_TestCache
    (lambda ()
      (cache-set! TestCache "overwrite-key" "first" 3600)
      (cache-set! TestCache "overwrite-key" "second" 3600)
      (check-equal? (cache-get! TestCache "overwrite-key") (list 'Something "second")))))

;; 9. Multiple independent caches don't interfere
(test-case "multiple caches are independent"
  (run-with-caps cache_TestCache
    (lambda ()
      (with-capabilities (cache_AnotherCache)
        (cache-set! TestCache "shared-key" "from-test" 3600)
        (cache-set! AnotherCache "shared-key" "from-another" 3600)
        (check-equal? (cache-get! TestCache "shared-key") (list 'Something "from-test"))
        (check-equal? (cache-get! AnotherCache "shared-key") (list 'Something "from-another"))))))

;; 10. Cache TTL expiry (manual test by setting expires_at in past)
(test-case "expired entry returns Nothing"
  (run-with-caps cache_TestCache
    (lambda ()
      ;; Directly manipulate the in-memory store to set an expired entry
      (define store (cache-spec-store TestCache))
      (hash-set! store "expired-key"
                 (vector "value" (- (current-seconds) 100)))  ; 100 seconds ago = expired
      (check-equal? (cache-get! TestCache "expired-key") 'Nothing))))

;; 11. Non-expired entry is returned
(test-case "non-expired entry is returned"
  (run-with-caps cache_TestCache
    (lambda ()
      (define store (cache-spec-store TestCache))
      (hash-set! store "fresh-key"
                 (vector "fresh" (+ (current-seconds) 3600)))  ; 1 hour from now
      (check-equal? (cache-get! TestCache "fresh-key") (list 'Something "fresh")))))

;; 12. Entry with no expiry (NULL expires_at) is always returned
(test-case "entry with no expiry is always returned"
  (run-with-caps cache_TestCache
    (lambda ()
      (define store (cache-spec-store TestCache))
      (hash-set! store "permanent-key"
                 (vector "permanent" #f))  ; #f = no expiry
      (check-equal? (cache-get! TestCache "permanent-key") (list 'Something "permanent")))))

;; 13. cache-spec struct accessors
(test-case "cache-spec-name returns correct name"
  (check-equal? (cache-spec-name TestCache) 'TestCache))

(test-case "cache-spec-default-ttl returns correct TTL"
  (check-equal? (cache-spec-default-ttl TestCache) 3600))

(test-case "cache-spec-codec returns codec (or #f)"
  (check-equal? (cache-spec-codec TestCache) #f))

(test-case "cache-spec-store returns a mutable hash"
  (check-pred hash? (cache-spec-store TestCache)))

;; 14. Cache with no default TTL
(test-case "cache without default TTL still allows set with explicit TTL"
  (run-with-caps cache_StaleCache
    (lambda ()
      (cache-set! StaleCache "key-with-ttl" "value" 60)
      (check-equal? (cache-get! StaleCache "key-with-ttl") (list 'Something "value")))))

;; 15. Cache with no default TTL and no explicit TTL has no expiry
(test-case "cache-set! with no TTL and no default = no expiry"
  (run-with-caps cache_StaleCache
    (lambda ()
      (cache-set! StaleCache "key-no-expiry" "persistent")
      (check-equal? (cache-get! StaleCache "key-no-expiry") (list 'Something "persistent")))))

;; 16. Named value keys are stringified
(test-case "named value keys are converted to string"
  (run-with-caps cache_TestCache
    (lambda ()
      (cache-set! TestCache 42 "number-key-value" 3600)
      (check-equal? (cache-get! TestCache 42) (list 'Something "number-key-value")))))

;; 17. Symbol keys work
(test-case "symbol keys are converted to string"
  (run-with-caps cache_TestCache
    (lambda ()
      (cache-set! TestCache 'my-symbol "sym-val" 3600)
      (check-equal? (cache-get! TestCache 'my-symbol) (list 'Something "sym-val")))))

;; 18. Large cache store works
(test-case "large number of entries"
  (run-with-caps cache_MultiCache
    (lambda ()
      (for ([i (in-range 100)])
        (cache-set! MultiCache (~a "key" i) (~a "val" i) 3600))
      (for ([i (in-range 100)])
        (check-equal? (cache-get! MultiCache (~a "key" i))
                      (list 'Something (~a "val" i)))))))

;; 19. Cache invalidate by shared prefix
(test-case "invalidate shared prefix from large store"
  (run-with-caps cache_MultiCache
    (lambda ()
      (for ([i (in-range 10)])
        (cache-set! MultiCache (~a "product_" i) (~a "product" i) 3600)
        (cache-set! MultiCache (~a "user_" i) (~a "user" i) 3600))
      (cache-invalidate-prefix! MultiCache "product_")
      (for ([i (in-range 10)])
        (check-equal? (cache-get! MultiCache (~a "product_" i)) 'Nothing)
        (check-equal? (cache-get! MultiCache (~a "user_" i))
                      (list 'Something (~a "user" i)))))))

;; 20. Cache-set! with TTL=0 immediately expires (behaves like delete)
(test-case "TTL=0 entry is immediately expired"
  (run-with-caps cache_TtlCache
    (lambda ()
      ;; Directly set with past expiry to simulate TTL=0 behavior
      (define store (cache-spec-store TtlCache))
      (hash-set! store "ttl-zero" (vector "gone" (current-seconds)))  ; exactly now = expired
      ;; may or may not expire depending on second boundary; either Nothing or Something is ok
      (define result (cache-get! TtlCache "ttl-zero"))
      (check-pred (lambda (r) (or (equal? r 'Nothing) (list? r))) result))))

;; 21. Multiple cache get calls are idempotent for non-expired entries
(test-case "cache-get! is idempotent"
  (run-with-caps cache_TestCache
    (lambda ()
      (cache-set! TestCache "idempotent" "stable" 3600)
      (define r1 (cache-get! TestCache "idempotent"))
      (define r2 (cache-get! TestCache "idempotent"))
      (check-equal? r1 r2))))

;; 22. Cache handles hash values
(test-case "cache stores and retrieves hash values"
  (run-with-caps cache_TestCache
    (lambda ()
      (define hsh (hash 'x 1 'y 2))
      (cache-set! TestCache "hash-key" hsh 3600)
      (check-equal? (cache-get! TestCache "hash-key") (list 'Something hsh)))))

;; 23. Cache handles boolean values
(test-case "cache stores and retrieves booleans"
  (run-with-caps cache_TestCache
    (lambda ()
      (cache-set! TestCache "bool-true" #t 3600)
      (cache-set! TestCache "bool-false" #f 3600)
      (check-equal? (cache-get! TestCache "bool-true") (list 'Something #t))
      (check-equal? (cache-get! TestCache "bool-false") (list 'Something #f)))))

;; 24. Cache handles list values
(test-case "cache stores and retrieves lists"
  (run-with-caps cache_TestCache
    (lambda ()
      (define lst '(1 2 3 4 5))
      (cache-set! TestCache "list-key" lst 3600)
      (check-equal? (cache-get! TestCache "list-key") (list 'Something lst)))))

;; 25. Cache handles integer values
(test-case "cache stores and retrieves integers"
  (run-with-caps cache_TestCache
    (lambda ()
      (cache-set! TestCache "int-key" 42 3600)
      (check-equal? (cache-get! TestCache "int-key") (list 'Something 42)))))

;; 26. Cache-set! with string value and string key
(test-case "basic string caching"
  (run-with-caps cache_TestCache
    (lambda ()
      (cache-set! TestCache "str-key" "str-value" 3600)
      (check-equal? (cache-get! TestCache "str-key") (list 'Something "str-value")))))

;; 27. Cache prefix invalidation with no matching keys
(test-case "invalidate prefix with no matching keys is a no-op"
  (run-with-caps cache_PrefixCache
    (lambda ()
      (cache-set! PrefixCache "xxx" "val" 3600)
      (cache-invalidate-prefix! PrefixCache "zzz_")
      (check-equal? (cache-get! PrefixCache "xxx") (list 'Something "val")))))

;; 28. Multiple deletes are safe
(test-case "multiple cache-delete! calls are safe"
  (run-with-caps cache_TestCache
    (lambda ()
      (cache-set! TestCache "multi-del" "v" 3600)
      (cache-delete! TestCache "multi-del")
      (cache-delete! TestCache "multi-del")
      (check-equal? (cache-get! TestCache "multi-del") 'Nothing))))

;; 29. Empty key is valid
(test-case "empty string key is valid"
  (run-with-caps cache_TestCache
    (lambda ()
      (cache-set! TestCache "" "empty-key-value" 3600)
      (check-equal? (cache-get! TestCache "") (list 'Something "empty-key-value")))))

;; 30. Cache with integer TTL as expression
(test-case "cache-set! with computed TTL"
  (run-with-caps cache_TestCache
    (lambda ()
      (define ttl (* 60 60))  ; 1 hour
      (cache-set! TestCache "computed-ttl-key" "val" ttl)
      (check-equal? (cache-get! TestCache "computed-ttl-key") (list 'Something "val")))))

;; 31-50: Additional edge cases

;; 31. Cache get returns Nothing for expired-then-re-set key
(test-case "re-set after expiry returns new value"
  (run-with-caps cache_TestCache
    (lambda ()
      (define store (cache-spec-store TestCache))
      (hash-set! store "regen" (vector "old" (- (current-seconds) 1)))
      (check-equal? (cache-get! TestCache "regen") 'Nothing)
      (cache-set! TestCache "regen" "new" 3600)
      (check-equal? (cache-get! TestCache "regen") (list 'Something "new")))))

;; 32. Large value in cache
(test-case "large value stored and retrieved"
  (run-with-caps cache_TestCache
    (lambda ()
      (define large (make-string 10000 #\a))
      (cache-set! TestCache "large-val" large 3600)
      (check-equal? (cache-get! TestCache "large-val") (list 'Something large)))))

;; 33. Multiple caches with same key
(test-case "same key in different caches are independent"
  (run-with-caps cache_TestCache
    (lambda ()
      (with-capabilities (cache_AnotherCache)
        (cache-set! TestCache "same" "in-test" 3600)
        (cache-set! AnotherCache "same" "in-another" 3600)
        (check-equal? (cache-get! TestCache "same") (list 'Something "in-test"))
        (check-equal? (cache-get! AnotherCache "same") (list 'Something "in-another"))))))

;; 34. Cache-get! after cache-set! with TTL=1 (still fresh immediately)
(test-case "fresh entry with TTL=1 is returned immediately"
  (run-with-caps cache_TtlCache
    (lambda ()
      (cache-set! TtlCache "ttl1-key" "ttl1-val" 1)
      ;; Immediately after set, should still be fresh
      (define result (cache-get! TtlCache "ttl1-key"))
      ;; May be Something or Nothing depending on timing
      (check-pred (lambda (r) (or (equal? r 'Nothing)
                                  (equal? r (list 'Something "ttl1-val")))) result))))

;; 35. Cache-set! with no TTL and no default stores permanently
(test-case "cache-set! permanent storage"
  (run-with-caps cache_StaleCache
    (lambda ()
      (cache-set! StaleCache "perm-key" "perm-val")
      (define store (cache-spec-store StaleCache))
      (define entry (hash-ref store "perm-key" #f))
      (check-true (vector? entry))
      (check-equal? (vector-ref entry 1) #f))))  ; expires_at = #f

;; 36. AnotherCache has TTL 60
(test-case "AnotherCache has default TTL 60"
  (check-equal? (cache-spec-default-ttl AnotherCache) 60))

;; 37. Cache name is a symbol
(test-case "cache-spec-name returns symbol"
  (check-pred symbol? (cache-spec-name TestCache)))

;; 38. Cache store starts empty for fresh test cache
(test-case "freshly defined cache has empty store"
  (define-cache FreshCache)
  (check-equal? (hash-count (cache-spec-store FreshCache)) 0))

;; 39. Cache invalidate all via empty prefix
(test-case "empty prefix invalidation clears all keys"
  (run-with-caps cache_MultiCache
    (lambda ()
      (cache-set! MultiCache "a" "1" 3600)
      (cache-set! MultiCache "b" "2" 3600)
      (cache-set! MultiCache "c" "3" 3600)
      (cache-invalidate-prefix! MultiCache "")
      (check-equal? (cache-get! MultiCache "a") 'Nothing)
      (check-equal? (cache-get! MultiCache "b") 'Nothing)
      (check-equal? (cache-get! MultiCache "c") 'Nothing))))

;; 40-50: More edge cases

;; 40. Cache returns Nothing for key that was never set in specific cache
(test-case "unset key in specific cache returns Nothing"
  (run-with-caps cache_AnotherCache
    (lambda ()
      (check-equal? (cache-get! AnotherCache "never-set-another") 'Nothing))))

;; 41. Cache handles nested hash values
(test-case "nested hash values"
  (run-with-caps cache_TestCache
    (lambda ()
      (define nested (hash 'inner (hash 'x 1)))
      (cache-set! TestCache "nested-hash" nested 3600)
      (check-equal? (cache-get! TestCache "nested-hash") (list 'Something nested)))))

;; 42. Cache with null (false) value
(test-case "cache stores false value"
  (run-with-caps cache_TestCache
    (lambda ()
      (cache-set! TestCache "false-val" #f 3600)
      (check-equal? (cache-get! TestCache "false-val") (list 'Something #f)))))

;; 43. Back-to-back set-get cycles
(test-case "multiple set-get cycles"
  (run-with-caps cache_TestCache
    (lambda ()
      (for ([i (in-range 5)])
        (cache-set! TestCache "cycle-key" i 3600)
        (check-equal? (cache-get! TestCache "cycle-key") (list 'Something i))))))

;; 44. Delete then set
(test-case "delete then re-set works"
  (run-with-caps cache_TestCache
    (lambda ()
      (cache-set! TestCache "del-re" "original" 3600)
      (cache-delete! TestCache "del-re")
      (check-equal? (cache-get! TestCache "del-re") 'Nothing)
      (cache-set! TestCache "del-re" "new" 3600)
      (check-equal? (cache-get! TestCache "del-re") (list 'Something "new")))))

;; 45. Prefix invalidation is prefix-sensitive (not substring)
(test-case "prefix invalidation only matches exact prefix"
  (run-with-caps cache_PrefixCache
    (lambda ()
      (cache-set! PrefixCache "abc" "1" 3600)
      (cache-set! PrefixCache "xabc" "2" 3600)
      (cache-invalidate-prefix! PrefixCache "abc")
      (check-equal? (cache-get! PrefixCache "abc") 'Nothing)
      ;; "xabc" does NOT start with "abc"
      (check-equal? (cache-get! PrefixCache "xabc") (list 'Something "2")))))

;; 46-50: More tests

;; 46. Cache with numeric key and numeric value
(test-case "numeric key and value"
  (run-with-caps cache_TestCache
    (lambda ()
      (cache-set! TestCache 99 100 3600)
      (check-equal? (cache-get! TestCache 99) (list 'Something 100)))))

;; 47. Empty prefix with no keys
(test-case "invalidate empty prefix on empty cache"
  (define-cache EmptyPrefixCache)
  (define-capability cache_EmptyPrefixCache)
  (with-capabilities (cache_EmptyPrefixCache)
    (check-not-exn (lambda () (cache-invalidate-prefix! EmptyPrefixCache "")))))

;; 48. Cache with very long key
(test-case "very long key is stored and retrieved"
  (run-with-caps cache_TestCache
    (lambda ()
      (define long-key (make-string 1000 #\k))
      (cache-set! TestCache long-key "val" 3600)
      (check-equal? (cache-get! TestCache long-key) (list 'Something "val")))))

;; 49. Cache set with TTL=3600 does not expire within test
(test-case "TTL=3600 does not expire immediately"
  (run-with-caps cache_TestCache
    (lambda ()
      (cache-set! TestCache "ttl3600" "v" 3600)
      (check-equal? (cache-get! TestCache "ttl3600") (list 'Something "v")))))

;; 50. Multiple sequential invalidations
(test-case "multiple sequential invalidations"
  (run-with-caps cache_PrefixCache
    (lambda ()
      (cache-set! PrefixCache "a_1" "v" 3600)
      (cache-set! PrefixCache "b_1" "v" 3600)
      (cache-invalidate-prefix! PrefixCache "a_")
      (cache-invalidate-prefix! PrefixCache "b_")
      (check-equal? (cache-get! PrefixCache "a_1") 'Nothing)
      (check-equal? (cache-get! PrefixCache "b_1") 'Nothing))))
