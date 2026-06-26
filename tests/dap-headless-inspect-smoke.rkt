#lang racket

;; dap-headless-inspect-smoke.rkt — proves the AC2 headless inspector.
;;
;; THE FEATURE UNDER TEST
;; ----------------------
;; `tesl debug-inspect <file.tesl> --break-at LINE [--mode program|test]` runs a
;; Tesl program to a single breakpoint with STOP-THE-WORLD active and dumps the
;; paused runtime state — locals + the full live domain registry + the current
;; SQL capture — as ONE JSON object.  The engine is dsl/debug/headless-inspect.rkt,
;; whose JSON-building functions REUSE the exact same renderers as the live DAP
;; debugger (safe-display from checkpoint.rkt, the domain-inspect.rkt summaries,
;; and the SQL-capture readers), so the headless JSON matches the debugger panels.
;;
;; WHAT THIS TEST DOES (no DB, no subprocess, deterministic)
;; ---------------------------------------------------------
;; It exercises the inspector's REAL JSON-assembly path directly:
;;   1. Creates a queue (with a pending job) and a cache (with an entry) via the
;;      REAL DSL macros at module top level — exactly as an emitted lesson .rkt
;;      would, registering them into the REAL global domain registry.
;;   2. Synthesises the `stopped` event hash that checkpoint.rkt's
;;      thsl-src!/runtime puts on event-ch (file + line + locals), plus a SQL
;;      capture record of the shape dsl/sql.rkt records.
;;   3. Calls (build-result-json evt src line reason sql-cap) — the SAME function
;;      the live runner uses to assemble the emitted JSON — and asserts the
;;      object has stopped=true, the locals, and the expected domain entries.
;;
;; A SEPARATE end-to-end smoke (running the actual `tesl debug-inspect` command on
;; a lesson) is covered by the worktree gate; here we keep the assertion fast,
;; DB-free and flake-free by driving the rendering layer directly.

;; NOTE: require everything via the COLLECTION path (tesl/…), the SAME way
;; headless-inspect.rkt does — NOT via relative "../…" paths.  Racket keys module
;; instances by resolved path; mixing collection-path and relative-path requires
;; of dsl/private/domain-registry.rkt would yield TWO instances, so the queue/cache
;; the test registers (one instance) would be invisible to the inspector's reader
;; (the other).  Sharing the collection path keeps it one live registry.
(require rackunit
         racket/string
         tesl/tesl/queue
         tesl/tesl/cache
         (only-in tesl/dsl/capability define-capability)
         (only-in tesl/dsl/private/domain-registry
                  domain-registry-clear!)
         (only-in tesl/dsl/debug/headless-inspect
                  headless-version
                  infer-type-string
                  locals->json
                  domain->json
                  sql->json
                  build-result-json))

;; Clean registry so this test is independent of load order.
(domain-registry-clear!)

;; ── 1. TOP-LEVEL domain definitions (as an emitted program would) ───────────────
(define-queue InspectJobs
  #:job-types (InspectJob)
  #:max-attempts 3
  #:backoff exponential
  #:initial-delay 5)

(define-capability cache_InspectCache)
(define-cache InspectCache #:default-ttl 60)

;; Populate live state: one pending job, one cache entry.
(hash-set! (queue-spec-store InspectJobs) "job-1"
           (hash 'payload (hash) 'status 'pending 'attempts 0))
(hash-set! (cache-spec-store InspectCache) "k1" (vector "v1" #f))

;; ── 2. The synthesised paused frame ─────────────────────────────────────────────
;; The locals checkpoint.rkt captures are (cons 'name value) pairs.  We include a
;; compiler-generated name (tesl_…) to prove it is skipped, and a "_" to prove the
;; underscore is skipped, exactly as the DAP Variables panel does.
(define SRC "/abs/path/lesson.tesl")
(define LINE 42)
(define paused-locals
  (list (cons 'userId "alice")
        (cons 'count 3)
        (cons '_ 999)
        (cons 'tesl_checked_0 'internal)))

;; The stopped event hash, exactly as thsl-src!/runtime puts on event-ch.
(define stopped-evt
  (hasheq 'event  "stopped"
          'file   SRC
          'line   LINE
          'locals paused-locals
          'reason "breakpoint"))

;; A SQL capture record of the shape dsl/sql.rkt records (task #43).
(define sql-cap
  (hasheq 'sql       "SELECT * FROM users WHERE id = $1"
          'params    (list 7)
          'table     "users"
          'op        'select
          'status    'executed
          'row-count 1
          'seq       1))

;; ── 3. Build the result JSON via the REAL assembly function ──────────────────────
(define RESULT (build-result-json stopped-evt SRC LINE "stopped" sql-cap))

;; ── 4. Assertions ───────────────────────────────────────────────────────────────

(test-case "version + stopped flag"
  (check-equal? (hash-ref RESULT 'version) headless-version)
  (check-true (hash-ref RESULT 'stopped) "breakpoint hit ⇒ stopped=true"))

(test-case "source reflects the paused file + line"
  (define src (hash-ref RESULT 'source))
  (check-equal? (hash-ref src 'file) SRC)
  (check-equal? (hash-ref src 'line) LINE))

(test-case "locals carry the user vars, proof-unwrapped, with skips applied"
  (define locals (hash-ref RESULT 'locals))
  (define names (map (lambda (l) (hash-ref l 'name)) locals))
  (check-not-false (member "userId" names) "user string local present")
  (check-not-false (member "count" names) "user int local present")
  (check-false (member "_" names) "underscore local skipped")
  (check-false (member "tesl_checked_0" names) "compiler-generated local skipped")
  ;; value + type rendering matches the debugger's safe-display / infer-type.
  (define uid (for/or ([l locals]) (and (equal? (hash-ref l 'name) "userId") l)))
  (check-equal? (hash-ref uid 'value) "\"alice\"" "string shown with quotes")
  (check-equal? (hash-ref uid 'type) "String"))

(test-case "domain has the expected QUEUE entry with its live pending count"
  (define queues (hash-ref (hash-ref RESULT 'domain) 'queues))
  (check-true (pair? queues) "queue surfaced from the global registry")
  (define q (car queues))
  (check-equal? (hash-ref q 'kind) "queue-spec")
  (check-equal? (hash-ref q 'name) "InspectJobs")
  (check-equal? (hash-ref q 'pending) 1 "one pending job")
  (check-true (string-contains? (hash-ref q 'summary) "Queue") "summary reused"))

(test-case "domain has the expected CACHE entry with its entry count"
  (define caches (hash-ref (hash-ref RESULT 'domain) 'caches))
  (check-true (pair? caches) "cache surfaced from the global registry")
  (define c (car caches))
  (check-equal? (hash-ref c 'kind) "cache-spec")
  (check-equal? (hash-ref c 'name) "InspectCache")
  (check-equal? (hash-ref c 'entries) 1 "one cache entry"))

(test-case "domain buckets are present even when empty"
  (define d (hash-ref RESULT 'domain))
  (for ([k '(queues caches sse email workers)])
    (check-true (list? (hash-ref d k)) (format "bucket ~a is a list" k))))

(test-case "sql capture renders the exact parameterized statement + typed params"
  (define sql (hash-ref RESULT 'sql))
  (check-true (hash? sql) "sql scope present when a capture exists")
  (check-equal? (hash-ref sql 'sql) "SELECT * FROM users WHERE id = $1")
  (check-equal? (hash-ref sql 'table) "users")
  (check-equal? (hash-ref sql 'operation) "select")
  (check-equal? (hash-ref sql 'status) "executed")
  (check-equal? (hash-ref sql 'row-count) 1)
  ;; the read-only preview folds the escaped literal in
  (check-equal? (hash-ref sql 'preview) "SELECT * FROM users WHERE id = 7")
  (define params (hash-ref sql 'params))
  (check-equal? (length params) 1)
  (check-equal? (hash-ref (car params) 'index) 1)
  (check-equal? (hash-ref (car params) 'type) "Int"))

(test-case "not-stopped result carries reason and empty locals/domain"
  (define r (build-result-json #f SRC LINE "breakpoint-not-hit" #f))
  (check-false (hash-ref r 'stopped))
  (check-equal? (hash-ref r 'reason) "breakpoint-not-hit")
  (check-equal? (hash-ref r 'locals) '())
  (check-equal? (hash-ref r 'sql) 'null "no capture ⇒ sql is json null")
  ;; the live domain registry still surfaces (domain state is global, not frame-local)
  (check-true (pair? (hash-ref (hash-ref r 'domain) 'queues))
              "domain registry still rendered when not stopped"))

(test-case "infer-type-string matches the debugger's type inference"
  (check-equal? (infer-type-string "x") "String")
  (check-equal? (infer-type-string 5) "Int")
  (check-equal? (infer-type-string #t) "Bool"))

;; Print the surfaced JSON for human eyeballing when run directly.
(module+ main
  (require json)
  (printf "\n=== headless debug-inspect JSON (synthesised stop) ===\n~a\n"
          (jsexpr->string RESULT)))
