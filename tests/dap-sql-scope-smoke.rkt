#lang racket

;; dap-sql-scope-smoke.rkt — proves the DAP "SQL transparency" capture (task #43):
;; dsl/sql.rkt records the EXACT parameterized statement + ordered params + row
;; count per running thread (debug-gated), and the DAP server reads it for the
;; paused thread. This exercises the capture API in dsl/private/domain-registry.rkt
;; directly (deterministic, no live PostgreSQL session needed — the live round-trip
;; is wired in dsl/sql.rkt's with-sql-capture and exercised by the DB integration
;; suites under a running Postgres).

(require rackunit
         "../dsl/private/domain-registry.rkt")

;; Capture is DEBUG-GATED (mirrors register-background-thread! / the checkpoint gate).
(putenv "TESL_DEBUG" "1")

(test-case "captures the exact parameterized SQL + ordered params + table/op, then the row count"
  (sql-capture-clear!)
  (sql-capture-pending! "SELECT * FROM users WHERE id = $1 AND active = $2"
                        (list 42 #t) "users" 'select-many)
  (define c (current-sql-capture))
  (check-true (hash? c) "a capture exists for the calling thread")
  (check-equal? (hash-ref c 'sql) "SELECT * FROM users WHERE id = $1 AND active = $2"
                "the parameterized statement is captured verbatim ($1,$2 — what the driver runs)")
  (check-equal? (hash-ref c 'params) (list 42 #t) "ordered bound params captured")
  (check-equal? (hash-ref c 'table) "users")
  (check-equal? (hash-ref c 'op) 'select-many)
  (check-equal? (hash-ref c 'status) 'pending)
  (check-false  (hash-ref c 'row-count) "row-count is #f while pending")

  (sql-capture-executed! 3)
  (define c2 (current-sql-capture))
  (check-equal? (hash-ref c2 'status) 'executed)
  (check-equal? (hash-ref c2 'row-count) 3 "row count attached after execution"))

(test-case "debug-gated: nothing captured when TESL_DEBUG is unset (zero release cost)"
  (sql-capture-clear!)
  (putenv "TESL_DEBUG" "")
  (sql-capture-pending! "SELECT 1" '() #f 'select-one)
  (check-false (current-sql-capture) "no capture recorded in a non-debug run")
  (putenv "TESL_DEBUG" "1"))

(test-case "most-recent fallback picks the newest capture across threads"
  (sql-capture-clear!)
  (sql-capture-pending! "SELECT 1" '() #f 'a)
  ;; a worker thread runs a later query
  (define w (thread (lambda () (sql-capture-pending! "INSERT INTO t VALUES ($1)" (list 7) "t" 'insert-one!))))
  (sync (thread-dead-evt w))
  (define mr (most-recent-sql-capture))
  (check-true (hash? mr))
  (check-equal? (hash-ref mr 'op) 'insert-one! "newest (by seq) wins the cross-thread fallback"))

(module+ main (void))
