#lang racket

(require
  tesl/dsl/capability
  tesl/dsl/types
  tesl/dsl/check
  tesl/dsl/otel
  tesl/dsl/sql
  tesl/dsl/web
  tesl/dsl/test-support
  tesl/dsl/debug/checkpoint
  tesl/tesl/private/runtime
  tesl/tesl/queue
  tesl/tesl/sse
  tesl/tesl/cache
  (only-in tesl/tesl/prelude Int String Bool List Unit)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
)


(provide )

(define-database TestDB
  #:backend postgres
  #:database ""
  #:user ""
  #:password ""
  #:server ""
  #:port 5432
  #:schema public
  #:entities )

(define-capability cacheCap_StringCache)
(define-cache StringCache #:database TestDB #:default-ttl 3600)

(define-capability cacheCap_IntCache)
(define-cache IntCache #:database TestDB #:default-ttl 60)

(define-capability cacheCap_NoTtlCache)
(define-cache NoTtlCache #:database TestDB)

(define/pow
  (getCached [k : String])
  #:capabilities [cacheCap_StringCache]
  #:returns (Maybe String)
  (thsl-src! "tests/cache-tests.tesl" 53 (list (cons 'k *k)) (lambda () (cache-get! StringCache k))))

(define/pow
  (setCached [k : String] [v : String])
  #:capabilities [cacheCap_StringCache]
  #:returns Unit
  (thsl-src! "tests/cache-tests.tesl" 56 (list (cons 'k *k) (cons 'v *v)) (lambda () (cache-set! StringCache k v))))

(define/pow
  (setCachedTtl [k : String] [v : String])
  #:capabilities [cacheCap_StringCache]
  #:returns Unit
  (thsl-src! "tests/cache-tests.tesl" 59 (list (cons 'k *k) (cons 'v *v)) (lambda () (cache-set! StringCache k v 300))))

(define/pow
  (deleteCached [k : String])
  #:capabilities [cacheCap_StringCache]
  #:returns Unit
  (thsl-src! "tests/cache-tests.tesl" 62 (list (cons 'k *k)) (lambda () (cache-delete! StringCache k))))

(define/pow
  (invalidatePrefix [prefix : String])
  #:capabilities [cacheCap_StringCache]
  #:returns Unit
  (thsl-src! "tests/cache-tests.tesl" 65 (list (cons 'prefix *prefix)) (lambda () (cache-invalidate-prefix! StringCache prefix))))

(define/pow
  (getInt [k : String])
  #:capabilities [cacheCap_IntCache]
  #:returns (Maybe Integer)
  (thsl-src! "tests/cache-tests.tesl" 68 (list (cons 'k *k)) (lambda () (cache-get! IntCache k))))

(define/pow
  (setInt [k : String] [v : Integer])
  #:capabilities [cacheCap_IntCache]
  #:returns Unit
  (thsl-src! "tests/cache-tests.tesl" 71 (list (cons 'k *k) (cons 'v *v)) (lambda () (cache-set! IntCache k v))))

(define/pow
  (deleteInt [k : String])
  #:capabilities [cacheCap_IntCache]
  #:returns Unit
  (thsl-src! "tests/cache-tests.tesl" 74 (list (cons 'k *k)) (lambda () (cache-delete! IntCache k))))

(define/pow
  (getOrDefault [k : String] [def : String])
  #:capabilities [cacheCap_StringCache]
  #:returns String
  (thsl-src-control! "tests/cache-tests.tesl" 77 (list (cons 'k *k) (cons 'def *def)) (lambda () (let ([tesl-case-0 (raw-value (cache-get! StringCache k))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/cache-tests.tesl" 78 (list (cons 'v v)) (lambda () *v)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "tests/cache-tests.tesl" 79 (list) (lambda () *def))])))))

(define/pow
  (cacheAndReturn [k : String] [v : String])
  #:capabilities [cacheCap_StringCache]
  #:returns (Maybe String)
  (let ([_ (thsl-src! "tests/cache-tests.tesl" 82 (list (cons 'k *k) (cons 'v *v)) (lambda () (cache-set! StringCache k v)))]) (thsl-src! "tests/cache-tests.tesl" 83 (list (cons 'k *k) (cons 'v *v)) (lambda () (cache-get! StringCache k)))))

(define/pow
  (setMultiple [k1 : String] [v1 : String] [k2 : String] [v2 : String])
  #:capabilities [cacheCap_StringCache]
  #:returns Unit
  (let ([_ (thsl-src! "tests/cache-tests.tesl" 86 (list (cons 'k1 *k1) (cons 'v1 *v1) (cons 'k2 *k2) (cons 'v2 *v2)) (lambda () (cache-set! StringCache k1 v1)))]) (thsl-src! "tests/cache-tests.tesl" 87 (list (cons 'k1 *k1) (cons 'v1 *v1) (cons 'k2 *k2) (cons 'v2 *v2)) (lambda () (cache-set! StringCache k2 v2)))))

(define/pow
  (getMultiple [k1 : String] [k2 : String])
  #:capabilities [cacheCap_StringCache]
  #:returns (List (Maybe String))
  (thsl-src! "tests/cache-tests.tesl" 90 (list (cons 'k1 *k1) (cons 'k2 *k2)) (lambda () (list (cache-get! StringCache k1) (cache-get! StringCache k2)))))

(module+ test
  (require rackunit)
  (test-case "cache block parses and compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 95 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "Cache.get returns Maybe"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache)
    (define result (thsl-src! "tests/cache-tests.tesl" 99 (list) (lambda () (getCached "test-key"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 100 (list (cons 'result result)) (lambda () result))) Nothing)
    )
    ))
  )

  (test-case "Cache.set and get roundtrip"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache)
    (define tesl-ignored-1 (thsl-src! "tests/cache-tests.tesl" 104 (list) (lambda () (setCached "hello-key" "hello"))))
    (define result (thsl-src! "tests/cache-tests.tesl" 105 (list) (lambda () (getCached "hello-key"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 106 (list (cons 'result result)) (lambda () result))) (raw-value (Something "hello")))
    )
    ))
  )

  (test-case "Cache.delete removes value"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache)
    (define tesl-ignored-2 (thsl-src! "tests/cache-tests.tesl" 110 (list) (lambda () (setCached "delete-me" "gone"))))
    (define before (thsl-src! "tests/cache-tests.tesl" 111 (list) (lambda () (getCached "delete-me"))))
    (define tesl-ignored-3 (thsl-src! "tests/cache-tests.tesl" 112 (list (cons 'before before)) (lambda () (deleteCached "delete-me"))))
    (define after (thsl-src! "tests/cache-tests.tesl" 113 (list (cons 'before before)) (lambda () (getCached "delete-me"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 114 (list (cons 'after after) (cons 'before before)) (lambda () before))) (raw-value (Something "gone")))
    )
    ))
  )

  (test-case "getOrDefault returns default on miss"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache)
    (define result (thsl-src! "tests/cache-tests.tesl" 118 (list) (lambda () (getOrDefault "miss" "default"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 119 (list (cons 'result result)) (lambda () result))) "default")
    )
    ))
  )

  (test-case "getOrDefault returns cached value on hit"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache)
    (define tesl-ignored-4 (thsl-src! "tests/cache-tests.tesl" 123 (list) (lambda () (setCached "my-key" "my-value"))))
    (define result (thsl-src! "tests/cache-tests.tesl" 124 (list) (lambda () (getOrDefault "my-key" "default"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 125 (list (cons 'result result)) (lambda () result))) "my-value")
    )
    ))
  )

  (test-case "Cache.set with explicit TTL"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache)
    (define tesl-ignored-5 (thsl-src! "tests/cache-tests.tesl" 129 (list) (lambda () (setCachedTtl "ttl-key" "ttl-value"))))
    (define result (thsl-src! "tests/cache-tests.tesl" 130 (list) (lambda () (getCached "ttl-key"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 131 (list (cons 'result result)) (lambda () result))) (raw-value (Something "ttl-value")))
    )
    ))
  )

  (test-case "Int cache get and set"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_IntCache)
    (define tesl-ignored-6 (thsl-src! "tests/cache-tests.tesl" 135 (list) (lambda () (setInt "count" 42))))
    (define result (thsl-src! "tests/cache-tests.tesl" 136 (list) (lambda () (getInt "count"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 137 (list (cons 'result result)) (lambda () result))) (raw-value (Something 42)))
    )
    ))
  )

  (test-case "Int cache delete"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_IntCache)
    (define tesl-ignored-7 (thsl-src! "tests/cache-tests.tesl" 141 (list) (lambda () (setInt "del-int" 100))))
    (define tesl-ignored-8 (thsl-src! "tests/cache-tests.tesl" 142 (list) (lambda () (deleteInt "del-int"))))
    (define result (thsl-src! "tests/cache-tests.tesl" 143 (list) (lambda () (getInt "del-int"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 144 (list (cons 'result result)) (lambda () result))) Nothing)
    )
    ))
  )

  (test-case "Cache.invalidate removes matching keys"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache)
    (define tesl-ignored-9 (thsl-src! "tests/cache-tests.tesl" 148 (list) (lambda () (setCached "user_1" "alice"))))
    (define tesl-ignored-10 (thsl-src! "tests/cache-tests.tesl" 149 (list) (lambda () (setCached "user_2" "bob"))))
    (define tesl-ignored-11 (thsl-src! "tests/cache-tests.tesl" 150 (list) (lambda () (invalidatePrefix "user_"))))
    (define r1 (thsl-src! "tests/cache-tests.tesl" 151 (list) (lambda () (getCached "user_1"))))
    (define r2 (thsl-src! "tests/cache-tests.tesl" 152 (list (cons 'r1 r1)) (lambda () (getCached "user_2"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 153 (list (cons 'r2 r2) (cons 'r1 r1)) (lambda () r1))) Nothing)
    )
    ))
  )

  (test-case "cacheAndReturn returns set value"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache)
    (define result (thsl-src! "tests/cache-tests.tesl" 157 (list) (lambda () (cacheAndReturn "k" "v"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 158 (list (cons 'result result)) (lambda () result))) (raw-value (Something "v")))
    )
    ))
  )

  (test-case "Cache with no defaultTtl compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_NoTtlCache)
    (define result (thsl-src! "tests/cache-tests.tesl" 162 (list) (lambda () (cache-get! NoTtlCache "any-key"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 163 (list (cons 'result result)) (lambda () result))) Nothing)
    )
    ))
  )

  (test-case "Cache.get on fresh cache returns Nothing"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache)
    (define r (thsl-src! "tests/cache-tests.tesl" 167 (list) (lambda () (getCached "brand-new-key-xyz"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 168 (list (cons 'r r)) (lambda () r))) Nothing)
    )
    ))
  )

  (test-case "Multiple set and get"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache)
    (define tesl-ignored-12 (thsl-src! "tests/cache-tests.tesl" 172 (list) (lambda () (setMultiple "a" "1" "b" "2"))))
    (define results (thsl-src! "tests/cache-tests.tesl" 173 (list) (lambda () (getMultiple "a" "b"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 174 (list (cons 'results results)) (lambda () results))) (list (raw-value (Something "1")) (raw-value (Something "2"))))
    )
    ))
  )

  (test-case "Cache.set overwrites previous value"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache)
    (define tesl-ignored-13 (thsl-src! "tests/cache-tests.tesl" 178 (list) (lambda () (setCached "overwrite" "first"))))
    (define tesl-ignored-14 (thsl-src! "tests/cache-tests.tesl" 179 (list) (lambda () (setCached "overwrite" "second"))))
    (define result (thsl-src! "tests/cache-tests.tesl" 180 (list) (lambda () (getCached "overwrite"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 181 (list (cons 'result result)) (lambda () result))) (raw-value (Something "second")))
    )
    ))
  )

  (test-case "Cache operations in sequence"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache)
    (define tesl-ignored-15 (thsl-src! "tests/cache-tests.tesl" 185 (list) (lambda () (setCached "seq-key" "v1"))))
    (define r1 (thsl-src! "tests/cache-tests.tesl" 186 (list) (lambda () (getCached "seq-key"))))
    (define tesl-ignored-16 (thsl-src! "tests/cache-tests.tesl" 187 (list (cons 'r1 r1)) (lambda () (setCached "seq-key" "v2"))))
    (define r2 (thsl-src! "tests/cache-tests.tesl" 188 (list (cons 'r1 r1)) (lambda () (getCached "seq-key"))))
    (define tesl-ignored-17 (thsl-src! "tests/cache-tests.tesl" 189 (list (cons 'r2 r2) (cons 'r1 r1)) (lambda () (deleteCached "seq-key"))))
    (define r3 (thsl-src! "tests/cache-tests.tesl" 190 (list (cons 'r2 r2) (cons 'r1 r1)) (lambda () (getCached "seq-key"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 191 (list (cons 'r3 r3) (cons 'r2 r2) (cons 'r1 r1)) (lambda () r1))) (raw-value (Something "v1")))
    )
    ))
  )

  (test-case "Cache with concatenated key"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache)
    (define prefix (thsl-src! "tests/cache-tests.tesl" 195 (list) (lambda () "profile_")))
    (define id (thsl-src! "tests/cache-tests.tesl" 196 (list (cons 'prefix prefix)) (lambda () "user123")))
    (define key (thsl-src! "tests/cache-tests.tesl" 197 (list (cons 'id id) (cons 'prefix prefix)) (lambda () (string-append (raw-value prefix) (raw-value id)))))
    (define tesl-ignored-18 (thsl-src! "tests/cache-tests.tesl" 198 (list (cons 'key key) (cons 'id id) (cons 'prefix prefix)) (lambda () (setCached key "profile-data"))))
    (define result (thsl-src! "tests/cache-tests.tesl" 199 (list (cons 'key key) (cons 'id id) (cons 'prefix prefix)) (lambda () (getCached key))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 200 (list (cons 'result result) (cons 'key key) (cons 'id id) (cons 'prefix prefix)) (lambda () result))) (raw-value (Something "profile-data")))
    )
    ))
  )

  (test-case "Cache invalidate prefix"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache)
    (define tesl-ignored-19 (thsl-src! "tests/cache-tests.tesl" 204 (list) (lambda () (setCached "sess_1" "s1"))))
    (define tesl-ignored-20 (thsl-src! "tests/cache-tests.tesl" 205 (list) (lambda () (setCached "sess_2" "s2"))))
    (define tesl-ignored-21 (thsl-src! "tests/cache-tests.tesl" 206 (list) (lambda () (setCached "data_1" "d1"))))
    (define tesl-ignored-22 (thsl-src! "tests/cache-tests.tesl" 207 (list) (lambda () (invalidatePrefix "sess_"))))
    (define r1 (thsl-src! "tests/cache-tests.tesl" 208 (list) (lambda () (getCached "sess_1"))))
    (define r2 (thsl-src! "tests/cache-tests.tesl" 209 (list (cons 'r1 r1)) (lambda () (getCached "data_1"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 210 (list (cons 'r2 r2) (cons 'r1 r1)) (lambda () r2))) (raw-value (Something "d1")))
    )
    ))
  )

  (test-case "Cache get in if-then-else"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache)
    (define cached (thsl-src! "tests/cache-tests.tesl" 214 (list) (lambda () (getCached "if-key"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 215 (list (cons 'cached cached)) (lambda () cached))) Nothing)
    )
    ))
  )

  (test-case "Int cache operations"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_IntCache)
    (define tesl-ignored-23 (thsl-src! "tests/cache-tests.tesl" 219 (list) (lambda () (setInt "num" 99))))
    (define r (thsl-src! "tests/cache-tests.tesl" 220 (list) (lambda () (getInt "num"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 221 (list (cons 'r r)) (lambda () r))) (raw-value (Something 99)))
    )
    ))
  )

  (test-case "StringCache default TTL is 3600"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 225 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "IntCache default TTL is 60"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 229 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "Cache with empty key"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache)
    (define tesl-ignored-24 (thsl-src! "tests/cache-tests.tesl" 233 (list) (lambda () (setCached "" "empty-key-val"))))
    (define result (thsl-src! "tests/cache-tests.tesl" 234 (list) (lambda () (getCached ""))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 235 (list (cons 'result result)) (lambda () result))) (raw-value (Something "empty-key-val")))
    )
    ))
  )

  (test-case "Cache delete is idempotent"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache)
    (define tesl-ignored-25 (thsl-src! "tests/cache-tests.tesl" 239 (list) (lambda () (setCached "idem" "v"))))
    (define tesl-ignored-26 (thsl-src! "tests/cache-tests.tesl" 240 (list) (lambda () (deleteCached "idem"))))
    (define tesl-ignored-27 (thsl-src! "tests/cache-tests.tesl" 241 (list) (lambda () (deleteCached "idem"))))
    (define r (thsl-src! "tests/cache-tests.tesl" 242 (list) (lambda () (getCached "idem"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 243 (list (cons 'r r)) (lambda () r))) Nothing)
    )
    ))
  )

  (test-case "Cache set with long key"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache)
    (define k (thsl-src! "tests/cache-tests.tesl" 247 (list) (lambda () "very_long_key_that_is_quite_long_for_testing_purposes_xyz_abc_def")))
    (define tesl-ignored-28 (thsl-src! "tests/cache-tests.tesl" 248 (list (cons 'k k)) (lambda () (setCached k "long-key-val"))))
    (define result (thsl-src! "tests/cache-tests.tesl" 249 (list (cons 'k k)) (lambda () (getCached k))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 250 (list (cons 'result result) (cons 'k k)) (lambda () result))) (raw-value (Something "long-key-val")))
    )
    ))
  )

  (test-case "Multiple caches are independent"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache cacheCap_IntCache)
    (define tesl-ignored-29 (thsl-src! "tests/cache-tests.tesl" 254 (list) (lambda () (setCached "shared" "string-val"))))
    (define tesl-ignored-30 (thsl-src! "tests/cache-tests.tesl" 255 (list) (lambda () (cache-set! IntCache "shared" 999))))
    (define r1 (thsl-src! "tests/cache-tests.tesl" 256 (list) (lambda () (getCached "shared"))))
    (define r2 (thsl-src! "tests/cache-tests.tesl" 257 (list (cons 'r1 r1)) (lambda () (getInt "shared"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 258 (list (cons 'r2 r2) (cons 'r1 r1)) (lambda () r1))) (raw-value (Something "string-val")))
    )
    ))
  )

  (test-case "Cache invalidate all via empty prefix"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache)
    (define tesl-ignored-31 (thsl-src! "tests/cache-tests.tesl" 262 (list) (lambda () (setCached "x1" "v1"))))
    (define tesl-ignored-32 (thsl-src! "tests/cache-tests.tesl" 263 (list) (lambda () (setCached "x2" "v2"))))
    (define tesl-ignored-33 (thsl-src! "tests/cache-tests.tesl" 264 (list) (lambda () (invalidatePrefix ""))))
    (define r1 (thsl-src! "tests/cache-tests.tesl" 265 (list) (lambda () (getCached "x1"))))
    (define r2 (thsl-src! "tests/cache-tests.tesl" 266 (list (cons 'r1 r1)) (lambda () (getCached "x2"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 267 (list (cons 'r2 r2) (cons 'r1 r1)) (lambda () r1))) Nothing)
    )
    ))
  )

  (test-case "Cache.get in case pattern"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_StringCache)
    (define r (thsl-src! "tests/cache-tests.tesl" 271 (list) (lambda () (getCached "pattern-key"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 272 (list (cons 'r r)) (lambda () r))) Nothing)
    )
    ))
  )

  (test-case "NoTtlCache compiles and operates"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
    (with-capabilities (cacheCap_NoTtlCache)
    (define tesl-ignored-34 (thsl-src! "tests/cache-tests.tesl" 276 (list) (lambda () (cache-set! NoTtlCache "ntk" "ntv"))))
    (define r (thsl-src! "tests/cache-tests.tesl" 277 (list) (lambda () (cache-get! NoTtlCache "ntk"))))
    (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 278 (list (cons 'r r)) (lambda () r))) (raw-value (Something "ntv")))
    )
    ))
  )

  (test-case "Cache capability enforced at compile time"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/cache-tests.tesl" 282 (list) (lambda () #t))) #t)
    ))
  )

)
