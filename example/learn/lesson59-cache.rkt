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
  (only-in tesl/tesl/prelude Int String Bool Unit)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
)


(provide getCachedProfile setCachedProfile invalidateUserCache getProfileOrDefault storeSession lookupSession getCachedProfile-signature setCachedProfile-signature invalidateUserCache-signature getProfileOrDefault-signature storeSession-signature lookupSession-signature)

(define-database MainDB
  #:backend postgres
  #:database (tesl-env-raw "LESSON59_DB")
  #:user (tesl-env-raw "TESL_POSTGRES_USER")
  #:password (tesl-env-raw "TESL_POSTGRES_PASSWORD")
  #:server (tesl-env-raw "TESL_POSTGRES_HOST")
  #:port (tesl-env-int-raw "TESL_POSTGRES_PORT" 5432)
  #:schema lesson59
  #:entities )

(define-capability cacheCap_UserProfileCache)
(define-cache UserProfileCache #:database MainDB #:default-ttl 3600)

(define-capability cacheCap_CounterCache)
(define-cache CounterCache #:database MainDB #:default-ttl 60)

(define-capability cacheCap_SessionCache)
(define-cache SessionCache #:database MainDB)

(define/pow
  (getCachedProfile [userId : String])
  #:capabilities [cacheCap_UserProfileCache]
  #:returns (Maybe String)
  (thsl-src! "example/learn/lesson59-cache.tesl" 102 (list (cons 'userId *userId)) (lambda () (cache-get! UserProfileCache (string-append "profile:" *userId)))))

(define/pow
  (setCachedProfile [userId : String] [profile : String])
  #:capabilities [cacheCap_UserProfileCache]
  #:returns Unit
  (thsl-src! "example/learn/lesson59-cache.tesl" 107 (list (cons 'userId *userId) (cons 'profile *profile)) (lambda () (cache-set! UserProfileCache (string-append "profile:" *userId) profile))))

(define/pow
  (deleteProfileCache [userId : String])
  #:capabilities [cacheCap_UserProfileCache]
  #:returns Unit
  (thsl-src! "example/learn/lesson59-cache.tesl" 112 (list (cons 'userId *userId)) (lambda () (cache-delete! UserProfileCache (string-append "profile:" *userId)))))

(define/pow
  (invalidateUserCache [prefix : String])
  #:capabilities [cacheCap_UserProfileCache]
  #:returns Unit
  (thsl-src! "example/learn/lesson59-cache.tesl" 118 (list (cons 'prefix *prefix)) (lambda () (cache-invalidate-prefix! UserProfileCache prefix))))

(define/pow
  (getProfileOrDefault [userId : String] [defaultProfile : String])
  #:capabilities [cacheCap_UserProfileCache]
  #:returns String
  (thsl-src-control! "example/learn/lesson59-cache.tesl" 124 (list (cons 'userId *userId) (cons 'defaultProfile *defaultProfile)) (lambda () (let ([tesl_case_0 (raw-value (cache-get! UserProfileCache (string-append "profile:" *userId)))]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (let ([profile (hash-ref (adt-value-fields *tesl_case_0) 'value)]) (thsl-src! "example/learn/lesson59-cache.tesl" 125 (list (cons 'profile profile)) (lambda () *profile)))] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) (thsl-src! "example/learn/lesson59-cache.tesl" 126 (list) (lambda () *defaultProfile))])))))

(define/pow
  (getCachedCounter [name : String])
  #:capabilities [cacheCap_CounterCache]
  #:returns (Maybe Integer)
  (thsl-src! "example/learn/lesson59-cache.tesl" 131 (list (cons 'name *name)) (lambda () (cache-get! CounterCache name))))

(define/pow
  (setCachedCounter [name : String] [value : Integer])
  #:capabilities [cacheCap_CounterCache]
  #:returns Unit
  (thsl-src! "example/learn/lesson59-cache.tesl" 135 (list (cons 'name *name) (cons 'value *value)) (lambda () (cache-set! CounterCache name value))))

(define/pow
  (storeSession [sessionId : String] [userId : String])
  #:capabilities [cacheCap_SessionCache]
  #:returns Unit
  (thsl-src! "example/learn/lesson59-cache.tesl" 140 (list (cons 'sessionId *sessionId) (cons 'userId *userId)) (lambda () (cache-set! SessionCache (string-append "session:" *sessionId) userId 86400))))

(define/pow
  (lookupSession [sessionId : String])
  #:capabilities [cacheCap_SessionCache]
  #:returns (Maybe String)
  (thsl-src! "example/learn/lesson59-cache.tesl" 144 (list (cons 'sessionId *sessionId)) (lambda () (cache-get! SessionCache (string-append "session:" *sessionId)))))

(define/pow
  (invalidateUserSessions [userId : String])
  #:capabilities [cacheCap_SessionCache]
  #:returns Unit
  (thsl-src! "example/learn/lesson59-cache.tesl" 148 (list (cons 'userId *userId)) (lambda () (cache-invalidate-prefix! SessionCache (string-append "session:" *userId)))))

(module+ test
  (require rackunit)
  (test-case "cache miss returns Nothing"
    (with-capabilities (cacheCap_UserProfileCache)
    (define result (thsl-src! "example/learn/lesson59-cache.tesl" 214 (list) (lambda () (getCachedProfile "unknown-user-xyz-never-set"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson59-cache.tesl" 215 (list (cons 'result result)) (lambda () result))) Nothing)
    )
  )

  (test-case "set and get profile round-trip"
    (with-capabilities (cacheCap_UserProfileCache)
    (define tesl_ignored_1 (thsl-src! "example/learn/lesson59-cache.tesl" 219 (list) (lambda () (setCachedProfile "user1" "{\"name\":\"Alice\"}"))))
    (define result (thsl-src! "example/learn/lesson59-cache.tesl" 220 (list) (lambda () (getCachedProfile "user1"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson59-cache.tesl" 221 (list (cons 'result result)) (lambda () result))) (raw-value (Something "{\"name\":\"Alice\"}")))
    )
  )

  (test-case "delete removes cached entry"
    (with-capabilities (cacheCap_UserProfileCache)
    (define tesl_ignored_2 (thsl-src! "example/learn/lesson59-cache.tesl" 225 (list) (lambda () (setCachedProfile "del-user" "data"))))
    (define tesl_ignored_3 (thsl-src! "example/learn/lesson59-cache.tesl" 226 (list) (lambda () (deleteProfileCache "del-user"))))
    (define result (thsl-src! "example/learn/lesson59-cache.tesl" 227 (list) (lambda () (getCachedProfile "del-user"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson59-cache.tesl" 228 (list (cons 'result result)) (lambda () result))) Nothing)
    )
  )

  (test-case "getProfileOrDefault returns default on cache miss"
    (with-capabilities (cacheCap_UserProfileCache)
    (define result (thsl-src! "example/learn/lesson59-cache.tesl" 232 (list) (lambda () (getProfileOrDefault "nonexistent-user-abc" "default-profile"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson59-cache.tesl" 233 (list (cons 'result result)) (lambda () result))) "default-profile")
    )
  )

  (test-case "getProfileOrDefault returns cached value on hit"
    (with-capabilities (cacheCap_UserProfileCache)
    (define tesl_ignored_4 (thsl-src! "example/learn/lesson59-cache.tesl" 237 (list) (lambda () (setCachedProfile "user2" "profile-data"))))
    (define result (thsl-src! "example/learn/lesson59-cache.tesl" 238 (list) (lambda () (getProfileOrDefault "user2" "default"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson59-cache.tesl" 239 (list (cons 'result result)) (lambda () result))) "profile-data")
    )
  )

  (test-case "counter cache get and set"
    (with-capabilities (cacheCap_CounterCache)
    (define tesl_ignored_5 (thsl-src! "example/learn/lesson59-cache.tesl" 243 (list) (lambda () (setCachedCounter "visits" 42))))
    (define result (thsl-src! "example/learn/lesson59-cache.tesl" 244 (list) (lambda () (getCachedCounter "visits"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson59-cache.tesl" 245 (list (cons 'result result)) (lambda () result))) (raw-value (Something 42)))
    )
  )

  (test-case "overwriting a cache entry stores the new value"
    (with-capabilities (cacheCap_UserProfileCache)
    (define tesl_ignored_6 (thsl-src! "example/learn/lesson59-cache.tesl" 249 (list) (lambda () (setCachedProfile "user3" "old-data"))))
    (define tesl_ignored_7 (thsl-src! "example/learn/lesson59-cache.tesl" 250 (list) (lambda () (setCachedProfile "user3" "new-data"))))
    (define result (thsl-src! "example/learn/lesson59-cache.tesl" 251 (list) (lambda () (getCachedProfile "user3"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson59-cache.tesl" 252 (list (cons 'result result)) (lambda () result))) (raw-value (Something "new-data")))
    )
  )

  (test-case "session cache round-trip"
    (with-capabilities (cacheCap_SessionCache)
    (define tesl_ignored_8 (thsl-src! "example/learn/lesson59-cache.tesl" 256 (list) (lambda () (storeSession "sess123" "user42"))))
    (define result (thsl-src! "example/learn/lesson59-cache.tesl" 257 (list) (lambda () (lookupSession "sess123"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson59-cache.tesl" 258 (list (cons 'result result)) (lambda () result))) (raw-value (Something "user42")))
    )
  )

  (test-case "multiple caches are independent (same key, different caches)"
    (with-capabilities (cacheCap_UserProfileCache cacheCap_CounterCache)
    (define tesl_ignored_9 (thsl-src! "example/learn/lesson59-cache.tesl" 262 (list) (lambda () (setCachedProfile "key" "string-val"))))
    (define tesl_ignored_10 (thsl-src! "example/learn/lesson59-cache.tesl" 263 (list) (lambda () (setCachedCounter "key" 100))))
    (define r1 (thsl-src! "example/learn/lesson59-cache.tesl" 264 (list) (lambda () (getCachedProfile "key"))))
    (define r2 (thsl-src! "example/learn/lesson59-cache.tesl" 265 (list (cons 'r1 r1)) (lambda () (getCachedCounter "key"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson59-cache.tesl" 266 (list (cons 'r2 r2) (cons 'r1 r1)) (lambda () r1))) (raw-value (Something "string-val")))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson59-cache.tesl" 267 (list (cons 'r2 r2) (cons 'r1 r1)) (lambda () r2))) (raw-value (Something 100)))
    )
  )

  (test-case "invalidate by prefix clears matching entries"
    (with-capabilities (cacheCap_UserProfileCache)
    (define tesl_ignored_11 (thsl-src! "example/learn/lesson59-cache.tesl" 271 (list) (lambda () (setCachedProfile "alice" "alice-data"))))
    (define tesl_ignored_12 (thsl-src! "example/learn/lesson59-cache.tesl" 272 (list) (lambda () (setCachedProfile "alicia" "alicia-data"))))
    (define tesl_ignored_13 (thsl-src! "example/learn/lesson59-cache.tesl" 273 (list) (lambda () (invalidateUserCache "profile:al"))))
    (define r1 (thsl-src! "example/learn/lesson59-cache.tesl" 274 (list) (lambda () (getCachedProfile "alice"))))
    (define r2 (thsl-src! "example/learn/lesson59-cache.tesl" 275 (list (cons 'r1 r1)) (lambda () (getCachedProfile "alicia"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson59-cache.tesl" 276 (list (cons 'r2 r2) (cons 'r1 r1)) (lambda () r1))) Nothing)
    (check-equal? (raw-value (thsl-src! "example/learn/lesson59-cache.tesl" 277 (list (cons 'r2 r2) (cons 'r1 r1)) (lambda () r2))) Nothing)
    )
  )

)
