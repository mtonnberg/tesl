#lang racket

;;; Memory-database registry (matrix 2026-07: test/api-test/load-test state
;;; isolation with an IMPORTED Memory database).
;;;
;;; The emitter wraps every test-ish block in
;;;   (call-with-fresh-memory-db <this module's database decls> …)
;;; but it can only list the EMITTING module's own `database` blocks — when the
;;; database lives in an imported module the list is '(), so the previous
;;; block's rows leaked into the next one (second api-test saw the first's
;;; seed: 200-vs-404 wrong answers; a load-test's seed then trapped on a
;;; duplicate primary key).  Fix: `define-database #:backend memory`
;;; self-registers its spec in dsl/sql.rkt's memory-database-registry, and
;;; call-with-fresh-memory-db resets the UNION of the passed list and every
;;; registered memory database — module instantiation (a plain require) always
;;; precedes test execution, so imported databases are registered by the time
;;; any block runs.  These tests pin that contract at the runtime layer, where
;;; it lives; the end-to-end multi-module emission is exercised by the
;;; compiler-side suites.
;;;
;;; Run:  raco test tests/memory-db-registry-test.rkt

(require rackunit
         "../dsl/sql.rkt"
         (only-in "../dsl/capability.rkt" with-capabilities)
         (only-in "../dsl/test-support.rkt" call-with-fresh-memory-db))

(define-entity RegProbeItem
  #:source (make-hash)
  #:table reg_probe_items
  #:primary-key id
  [Id id : String]
  [Name name : String]
)

(define-entity RegProbeOther
  #:source (make-hash)
  #:table reg_probe_others
  #:primary-key id
  [Id id : String]
)

(define-database RegProbeDb
  #:backend memory
  #:entities RegProbeItem)

(define-database RegProbeOtherDb
  #:backend memory
  #:entities RegProbeOther)

(define (item-count)
  (with-capabilities (db-read)
    (call-with-database RegProbeDb
      (lambda () (length (select-many (from RegProbeItem)))))))

(define (other-count)
  (with-capabilities (db-read)
    (call-with-database RegProbeOtherDb
      (lambda () (length (select-many (from RegProbeOther)))))))

(define (seed-item! id)
  (with-capabilities (db-write)
    (call-with-database RegProbeDb
      (lambda () (insert-one! RegProbeItem (hash 'id id 'name id))))))

(define (seed-other! id)
  (with-capabilities (db-write)
    (call-with-database RegProbeOtherDb
      (lambda () (insert-one! RegProbeOther (hash 'id id))))))

(test-case "define-database #:backend memory self-registers its spec"
  (check-true (and (memq RegProbeDb (registered-memory-databases)) #t))
  (check-true (and (memq RegProbeOtherDb (registered-memory-databases)) #t)))

(test-case "an EMPTY reset list still resets registered memory databases (imported-db emission shape)"
  ;; Simulate the leak: seed outside any block, exactly like a previous test
  ;; block that ran to completion would leave rows behind pre-fix.
  (seed-item! "leak-1")
  (seed-other! "leak-2")
  (check-equal? (item-count) 1)
  (check-equal? (other-count) 1)
  ;; The emitter passes '() when the database is declared in an imported
  ;; module — the registry must cover it.
  (call-with-fresh-memory-db '()
    (lambda ()
      (check-equal? (item-count) 0 "imported-db block starts fresh")
      (check-equal? (other-count) 0 "every registered memory db starts fresh")
      ;; Re-seeding the same primary key must not trap (the load-test
      ;; duplicate-pk symptom).
      (check-not-exn (lambda () (seed-item! "leak-1")))))
  ;; dynamic-wind exit reset: nothing survives the block either.
  (check-equal? (item-count) 0)
  (check-equal? (other-count) 0))

(test-case "an explicitly passed database list still resets (same-module emission shape)"
  (seed-item! "same-module")
  (check-equal? (item-count) 1)
  (call-with-fresh-memory-db (list RegProbeDb)
    (lambda ()
      (check-equal? (item-count) 0 "same-module isolation intact")))
  (check-equal? (item-count) 0))
