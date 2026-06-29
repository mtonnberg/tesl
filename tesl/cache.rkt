#lang racket

;;; Native Cache runtime for Tesl.
;;;
;;; Uses a PostgreSQL UNLOGGED table for persistence (fast — unlogged means no WAL overhead).
;;; Falls back to an in-memory hash when no PostgreSQL runtime is active (tests, development).
;;;
;;; Key design decisions:
;;;   - Each cache block declares its value type at definition time; Cache.get returns Maybe V.
;;;   - Stale/undeserializable entries are silently deleted and Nothing is returned.
;;;   - Cache.set/delete/invalidate inside withTransaction participate atomically.
;;;   - A background sweeper thread deletes expired rows every 60 seconds.
;;;
;;; Capability: "cacheCap_<Name>" Racket identifiers (defined by define-cache macro,
;;; also referenced in define-capability calls emitted by the OCaml compiler).

(require (only-in db query-rows query-exec)
         json
         racket/format
         racket/match
         racket/string
         (only-in "../dsl/capability.rkt"
                  define-capability
                  require-capabilities!
                  current-capabilities)
         (only-in "../dsl/private/check-runtime.rkt"
                  named-value
                  named-value?
                  named-value-name
                  named-value-value
                  raw-value)
         (only-in "../dsl/types.rkt"
                  runtime-value->jsexpr
                  jsexpr->typed-value
                  lookup-record-spec
                  Nothing
                  Something)
         (only-in "../dsl/private/domain-registry.rkt"
                  domain-registry-add!
                  register-background-thread!)
         (only-in "../dsl/sql.rkt"
                  current-database-runtime
                  database-runtime-connection
                  database-runtime-database
                  database-spec-backend
                  database-schema-name)
         (for-syntax racket/base racket/format syntax/parse))

(provide
 ;; Macro for declaring a cache (also defines its capability)
 define-cache
 ;; Cache operations
 cache-get!
 cache-set!
 cache-delete!
 cache-invalidate-prefix!
 ;; Struct accessors (for tests)
 (struct-out cache-spec))

;; ── Data structures ───────────────────────────────────────────────────────────

(struct cache-spec
  (name          ; symbol  — cache identifier
   default-ttl   ; integer | #f — default TTL in seconds
   codec         ; symbol | #f — type name for deserialization
   capability    ; capability-value | #f — the capability for this cache
   store)        ; mutable hash — in-memory fallback: key → (vector value expires-at)
  #:transparent)

;; ── PostgreSQL context helpers ────────────────────────────────────────────────

(define (pg-active?)
  (define r (current-database-runtime))
  (and r (eq? (database-spec-backend (database-runtime-database r)) 'postgres)))

(define (pg-conn)
  (database-runtime-connection (current-database-runtime)))

(define (pg-schema)
  (database-schema-name (database-runtime-database (current-database-runtime))))

(define (pg-table schema table)
  (~a "\"" schema "\".\"" table "\""))

;; ── Serialization ─────────────────────────────────────────────────────────────

(define (serialize-value value)
  (define raw (if (named-value? value) (named-value-value value) value))
  (jsexpr->string (runtime-value->jsexpr raw)))

(define (deserialize-value json-str codec-sym)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define jsexpr (string->jsexpr json-str))
    (if codec-sym
        (jsexpr->typed-value codec-sym jsexpr 'cache)
        jsexpr)))

;; ── In-memory helpers ─────────────────────────────────────────────────────────

(define (mem-get! store key codec-sym)
  (define entry (hash-ref store key #f))
  (cond
    [(not entry) Nothing]
    [(and (vector-ref entry 1)
          (> (current-seconds) (vector-ref entry 1)))
     ;; expired
     (hash-remove! store key)
     Nothing]
    [else
     ;; The in-memory backend stores raw runtime values (mem-set! does not
     ;; serialize), so return the stored value directly — no JSON round-trip.
     ;; (Deserializing here would mangle plain strings: `string->jsexpr "foo"`
     ;; fails, which previously turned every string-cache hit into a miss.)
     (Something (vector-ref entry 0))]))

(define (mem-set! store key value ttl)
  ;; Unwrap named-values so the stored value matches what `serialize-value`
  ;; would persist on the PostgreSQL path (keeps the two backends consistent).
  (define raw (if (named-value? value) (named-value-value value) value))
  (define expires-at (and ttl (+ (current-seconds) ttl)))
  (hash-set! store key (vector raw expires-at)))

(define (mem-delete! store key)
  (hash-remove! store key))

(define (mem-invalidate-prefix! store prefix)
  (for ([k (in-list (hash-keys store))])
    (when (string-prefix? k prefix)
      (hash-remove! store k))))

;; ── PostgreSQL operations ─────────────────────────────────────────────────────

(define (pg-get! conn schema key codec-sym)
  (with-handlers ([exn:fail? (lambda (e)
                               (log-error "cache-get! error: ~a" (exn-message e))
                               Nothing)])
    (define rows
      (query-rows conn
        (format "SELECT value::text FROM ~a WHERE key = $1 AND (expires_at IS NULL OR expires_at > NOW())"
                (pg-table schema "tesl_cache"))
        key))
    (cond
      [(null? rows) Nothing]
      [else
       (define json-str (vector-ref (car rows) 0))
       (define deserialized (deserialize-value json-str codec-sym))
       (if deserialized
           (Something deserialized)
           (begin
             ;; Stale/undeserializable entry — delete and return Nothing
             (query-exec conn
               (format "DELETE FROM ~a WHERE key = $1"
                       (pg-table schema "tesl_cache"))
               key)
             Nothing))])))

(define (pg-set! conn schema key value ttl)
  (define json-str (serialize-value value))
  (define expires-sql
    (if ttl
        (format "NOW() + interval '~a seconds'" ttl)
        "NULL::timestamptz"))
  (query-exec conn
    (format "INSERT INTO ~a (key, value, expires_at) VALUES ($1, $2::jsonb, ~a)
             ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, expires_at = EXCLUDED.expires_at"
            (pg-table schema "tesl_cache")
            expires-sql)
    key json-str))

(define (pg-delete! conn schema key)
  (query-exec conn
    (format "DELETE FROM ~a WHERE key = $1" (pg-table schema "tesl_cache"))
    key))

(define (pg-invalidate-prefix! conn schema prefix)
  (query-exec conn
    (format "DELETE FROM ~a WHERE key LIKE $1 || '%%'" (pg-table schema "tesl_cache"))
    prefix))

;; ── Public cache operations ───────────────────────────────────────────────────
;; Capability checking: if the cache was created with a non-#f capability,
;; require-capabilities! is called. The OCaml compiler emits define-capability
;; calls and adds the capability to function #:capabilities, so at runtime
;; the capability check ensures the caller declared it.

(define (cache-check-capability! cache-s)
  (define cap (cache-spec-capability cache-s))
  (when cap
    (require-capabilities! (list cap))))

(define (cache-get! cache-s key)
  (cache-check-capability! cache-s)
  (start-cache-sweeper!)   ; idempotent — guarded by sweeper-started? flag
  (define raw-key (if (named-value? key) (named-value-value key) key))
  (define str-key (~a raw-key))
  (cond
    [(pg-active?)
     (pg-get! (pg-conn) (pg-schema) str-key (cache-spec-codec cache-s))]
    [else
     (mem-get! (cache-spec-store cache-s) str-key (cache-spec-codec cache-s))]))

(define (cache-set! cache-s key value [ttl #f])
  (cache-check-capability! cache-s)
  (define raw-key (if (named-value? key) (named-value-value key) key))
  (define str-key (~a raw-key))
  (define effective-ttl (or ttl (cache-spec-default-ttl cache-s)))
  (cond
    [(pg-active?)
     (pg-set! (pg-conn) (pg-schema) str-key value effective-ttl)]
    [else
     (mem-set! (cache-spec-store cache-s) str-key value effective-ttl)]))

(define (cache-delete! cache-s key)
  (cache-check-capability! cache-s)
  (define raw-key (if (named-value? key) (named-value-value key) key))
  (define str-key (~a raw-key))
  (cond
    [(pg-active?)
     (pg-delete! (pg-conn) (pg-schema) str-key)]
    [else
     (mem-delete! (cache-spec-store cache-s) str-key)]))

(define (cache-invalidate-prefix! cache-s prefix)
  (cache-check-capability! cache-s)
  (define raw-pfx (if (named-value? prefix) (named-value-value prefix) prefix))
  (define str-pfx (~a raw-pfx))
  (cond
    [(pg-active?)
     (pg-invalidate-prefix! (pg-conn) (pg-schema) str-pfx)]
    [else
     (mem-invalidate-prefix! (cache-spec-store cache-s) str-pfx)]))

;; ── Background sweeper (PostgreSQL) ──────────────────────────────────────────

;; Runs every 60 seconds when a PostgreSQL database is active.
;; Deletes expired cache rows. Runs in a daemon thread so it doesn't block exit.
(define sweeper-started? #f)

(define (start-cache-sweeper!)
  (unless sweeper-started?
    (set! sweeper-started? #t)
    ;; register-background-thread! records the handle for DAP stop-the-world
    ;; (no-op unless TESL_DEBUG is set); previously fire-and-forget.
    (register-background-thread!
     (thread
      (lambda ()
        (let loop ()
          (sleep 60)
          (with-handlers ([exn:fail? (lambda (e)
                                       (log-error "cache-sweeper error: ~a" (exn-message e)))])
            (when (pg-active?)
              (query-exec (pg-conn)
                (format "DELETE FROM ~a WHERE expires_at IS NOT NULL AND expires_at < NOW()"
                        (pg-table (pg-schema) "tesl_cache")))))
          (loop)))))))

;; ── define-cache macro ────────────────────────────────────────────────────────
;;
;; Emitted by the OCaml compiler as:
;;   (define-capability cacheCap_UserProfileCache)
;;   (define-cache UserProfileCache #:database MainDB #:default-ttl 3600)
;;
;; The define-capability call is emitted BEFORE define-cache, so the capability
;; identifier is already bound when define-cache references it.
;;
;; The macro uses the cache name to look up the pre-existing capability binding.

(define-syntax (define-cache stx)
  (syntax-parse stx
    [(_ name:id
        (~optional (~seq #:database _db:id) #:defaults ([_db #'#f]))
        (~optional (~seq #:default-ttl ttl:expr) #:defaults ([ttl #'#f]))
        (~optional (~seq #:codec codec:id) #:defaults ([codec #'#f])))
     ;; Build the capability identifier: cacheCap_<name>
     (define cap-id
       (datum->syntax stx
         (string->symbol
           (~a "cacheCap_" (syntax->datum #'name)))))
     #`(define name
         (let ([spec (cache-spec 'name ttl 'codec
                                 ;; If the capability was defined (by the compiler-emitted
                                 ;; define-capability), bind it; otherwise use #f
                                 ;; (test/dev mode with no capabilities).
                                 (with-handlers ([exn:fail? (lambda (_) #f)])
                                   #,cap-id)
                                 (make-hash))])
           ;; Register the LIVE cache so the DAP debugger can enumerate it (and read
           ;; its entries / keys / ttl) even when it is not a paused-frame local.
           (domain-registry-add! 'caches spec)
           spec))]))
