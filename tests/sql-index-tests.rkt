#lang racket

;;; Entity index declarations — the sql.rkt seams that need no live PostgreSQL.
;;;
;;; What this file pins:
;;;   * `parse-entity-indexes` is TOTAL — an unknown index kind, a non-list
;;;     spec, a non-symbol key or an empty key list raises rather than being
;;;     skipped, so a future index kind cannot be silently dropped on the floor.
;;;   * the derived index name is `<table>_<col>_…_idx` over REAL column names
;;;     (camel→snake, honouring an explicit `#:column`), and an over-long name is
;;;     truncated to PostgreSQL's 63-byte limit with a deterministic hash suffix
;;;     — the collision that plain truncation would cause is the whole point.
;;;   * the emitted DDL is `create [unique] index [concurrently] if not exists`
;;;     with quoted identifiers, and the CONCURRENTLY variant is exactly what
;;;     the migration hands the operator.
;;;   * `postgres-index-present?` decides by COLUMN LIST + UNIQUENESS, never by
;;;     name, and a unique index satisfies a plain declaration but not vice
;;;     versa.
;;;   * the Memory backend ENFORCES declared unique indexes (insert, upsert and
;;;     update), with PostgreSQL's NULL semantics: a row with a NULL in any
;;;     indexed column is unconstrained.  Skipping that would let `tesl test`
;;;     pass on data PostgreSQL rejects — the divergence that motivated the
;;;     feature.
;;;
;;; The live-PostgreSQL half (indexes actually present in `pg_index` after
;;; auto-migration, and the populated-table refusal/warning split) lives in
;;; tests/postgres-test.rkt.

(require rackunit
         racket/string
         "../dsl/capability.rkt"
         "../dsl/sql.rkt"
         "../dsl/types.rkt")

;; ── Fixtures ───────────────────────────────────────────────────────────────

(define current-issue-rows (make-parameter (make-hash)))

(define-entity Issue
  #:source (lambda () (current-issue-rows))
  #:table "kanel_issues"
  #:primary-key id
  #:indexes ((plain (orgId createdAt) #f)
             (unique (orgId slug) #f)
             (plain (createdAt) "kanel_issues_recent"))
  [Id id : String]
  [OrgId orgId : String]
  [Slug slug : String]
  [CreatedAt createdAt : Int])

(define issue-db (database-spec 'IssueDb 'memory "app" (list Issue) #f))

(define (index-of n) (list-ref (entity-spec-indexes Issue) n))

;; ── parse-entity-indexes is total ──────────────────────────────────────────

(define parse-tests
  (test-suite
   "parse-entity-indexes"

   (test-case "kinds, keys and explicit names round-trip"
     (define ixs (entity-spec-indexes Issue))
     (check-equal? (length ixs) 3)
     (check-false (entity-index-unique? (index-of 0)))
     (check-equal? (entity-index-keys (index-of 0)) '(orgId createdAt))
     (check-false (entity-index-name (index-of 0)))
     (check-true (entity-index-unique? (index-of 1)))
     (check-equal? (entity-index-name (index-of 2)) "kanel_issues_recent"))

   (test-case "an entity with no #:indexes has none"
     (check-equal? (entity-spec-indexes Plain) '()))

   ;; Fail-closed: every one of these would be a compiler/emitter bug, and the
   ;; wrong answer is to drop the index and run unindexed (or, for a unique
   ;; index, unconstrained).
   (test-case "unknown index kind raises"
     (check-exn #rx"unknown index kind"
                (lambda () (parse-entity-indexes '((sorted (a) #f)) 'E))))
   (test-case "malformed spec raises"
     (check-exn #rx"malformed index spec"
                (lambda () (parse-entity-indexes '((plain (a))) 'E))))
   (test-case "non-list datum raises"
     (check-exn #rx"expects a list"
                (lambda () (parse-entity-indexes 'nope 'E))))
   (test-case "empty key list raises"
     (check-exn #rx"names no fields"
                (lambda () (parse-entity-indexes '((plain () #f)) 'E))))
   (test-case "non-symbol keys raise"
     (check-exn #rx"must be symbols"
                (lambda () (parse-entity-indexes '((plain ("a") #f)) 'E))))
   (test-case "non-string name raises"
     (check-exn #rx"must be a string or #f"
                (lambda () (parse-entity-indexes '((plain (a) 7)) 'E))))))

(define-entity Plain
  #:source (make-hash)
  #:table "plains"
  #:primary-key id
  [Id id : String])

;; ── Names and columns ──────────────────────────────────────────────────────

(define name-tests
  (test-suite
   "index names and columns"

   (test-case "columns are the real snake_case column names, in index order"
     (check-equal? (entity-index-column-names Issue (index-of 0) 'test)
                   '("org_id" "created_at")))

   (test-case "derived name is <table>_<col>…_idx"
     (check-equal? (entity-index-effective-name Issue (index-of 0) 'test)
                   "kanel_issues_org_id_created_at_idx"))

   (test-case "an explicit name wins over the derived one"
     (check-equal? (entity-index-effective-name Issue (index-of 2) 'test)
                   "kanel_issues_recent"))

   (test-case "a field the index does not name is rejected, not skipped"
     (check-exn #rx"unknown field"
                (lambda ()
                  (entity-index-column-names
                   Issue (car (parse-entity-indexes '((plain (nope) #f)) 'Issue)) 'test))))

   (test-case "short names are left alone"
     (check-equal? (truncate-sql-identifier "short_name_idx") "short_name_idx")
     (check-equal? (truncate-sql-identifier (make-string 63 #\a))
                   (make-string 63 #\a)))

   ;; PostgreSQL truncates at 63 bytes with only a NOTICE, so two long names
   ;; sharing a 63-byte prefix would collide and `if not exists` would then
   ;; match the WRONG index.  The hash suffix is what prevents that.
   (test-case "over-long names are truncated to 63 bytes"
     (define long (string-append (make-string 80 #\a) "_idx"))
     (define got (truncate-sql-identifier long))
     (check-equal? (bytes-length (string->bytes/utf-8 got)) 63))

   (test-case "two long names differing only past byte 63 do not collide"
     (define a (string-append (make-string 70 #\a) "_first_idx"))
     (define b (string-append (make-string 70 #\a) "_second_idx"))
     (check-not-equal? (truncate-sql-identifier a) (truncate-sql-identifier b)))

   (test-case "truncation is deterministic across calls"
     (define long (string-append (make-string 90 #\z) "_idx"))
     (check-equal? (truncate-sql-identifier long) (truncate-sql-identifier long)))))

;; ── DDL ────────────────────────────────────────────────────────────────────

(define ddl-tests
  (test-suite
   "index DDL"

   (test-case "plain index"
     (check-equal?
      (index-create-sql issue-db Issue (index-of 0))
      (string-append "create index if not exists \"kanel_issues_org_id_created_at_idx\" "
                     "on \"app\".\"kanel_issues\" (\"org_id\", \"created_at\")")))

   (test-case "unique index"
     (check-equal?
      (index-create-sql issue-db Issue (index-of 1))
      (string-append "create unique index if not exists \"kanel_issues_org_id_slug_idx\" "
                     "on \"app\".\"kanel_issues\" (\"org_id\", \"slug\")")))

   ;; This is the statement the migration prints for a populated table, so its
   ;; exact shape is part of the contract: CONCURRENTLY cannot run inside the
   ;; migration transaction, which is why the operator runs it out of band.
   (test-case "concurrently variant"
     (check-equal?
      (index-create-sql issue-db Issue (index-of 2) #:concurrently? #t)
      (string-append "create index concurrently if not exists \"kanel_issues_recent\" "
                     "on \"app\".\"kanel_issues\" (\"created_at\")")))))

;; ── Presence detection ─────────────────────────────────────────────────────

(define presence-tests
  (test-suite
   "postgres-index-present?"

   ;; Matching by name would report a permanent phantom-missing index for every
   ;; adopted database whose equivalent index is spelled differently.
   (test-case "matched by column list, regardless of the index's name"
     (check-true (postgres-index-present? '((#f . ("org_id" "created_at")))
                                          Issue (index-of 0) 'test)))

   (test-case "column ORDER matters"
     (check-false (postgres-index-present? '((#f . ("created_at" "org_id")))
                                           Issue (index-of 0) 'test)))

   (test-case "a prefix is not a match"
     (check-false (postgres-index-present? '((#f . ("org_id")))
                                           Issue (index-of 0) 'test)))

   (test-case "a unique index satisfies a plain declaration"
     (check-true (postgres-index-present? '((#t . ("org_id" "created_at")))
                                          Issue (index-of 0) 'test)))

   (test-case "a plain index does NOT satisfy a unique declaration"
     (check-false (postgres-index-present? '((#f . ("org_id" "slug")))
                                           Issue (index-of 1) 'test)))

   (test-case "nothing present"
     (check-false (postgres-index-present? '() Issue (index-of 0) 'test)))))

;; ── Memory backend enforces unique indexes ─────────────────────────────────

(define (issue id org slug at)
  (hash 'id id 'orgId org 'slug slug 'createdAt at))

(define issue-id-field (entity-field-ref Issue 'id))

(define memory-tests
  (test-suite
   "Memory backend unique-index enforcement"

   ;; The parity requirement: without this, `upsert … onConflict [orgId, slug]`
   ;; passes `tesl test` and dies on PostgreSQL with "there is no unique or
   ;; exclusion constraint matching the ON CONFLICT specification".
   (test-case "insert violating a unique index is refused"
     (parameterize ([current-issue-rows (make-hash)])
       (with-capabilities (db-read db-write)
         (insert-one! Issue (issue "i1" "org1" "bug" 1))
         (check-exn #rx"unique index"
                    (lambda () (insert-one! Issue (issue "i2" "org1" "bug" 2)))))))

   (test-case "a differing component makes the row distinct"
     (parameterize ([current-issue-rows (make-hash)])
       (with-capabilities (db-read db-write)
         (insert-one! Issue (issue "i1" "org1" "bug" 1))
         (insert-one! Issue (issue "i2" "org2" "bug" 2))
         (insert-one! Issue (issue "i3" "org1" "feature" 3))
         (check-equal? (hash-count (current-issue-rows)) 3))))

   (test-case "the refused row is not stored"
     (parameterize ([current-issue-rows (make-hash)])
       (with-capabilities (db-read db-write)
         (insert-one! Issue (issue "i1" "org1" "bug" 1))
         (with-handlers ([exn:fail? void])
           (insert-one! Issue (issue "i2" "org1" "bug" 2)))
         (check-equal? (hash-count (current-issue-rows)) 1))))

   (test-case "update into a duplicate is refused"
     (parameterize ([current-issue-rows (make-hash)])
       (with-capabilities (db-read db-write)
         (insert-one! Issue (issue "i1" "org1" "bug" 1))
         (insert-one! Issue (issue "i2" "org1" "feature" 2))
         (check-exn #rx"unique index"
                    (lambda ()
                      (update-many! (from Issue)
                                    (hash 'slug "bug")
                                    (where (==. issue-id-field "i2"))))))))

   ;; A row must not conflict with ITSELF: re-writing a row's own indexed
   ;; columns to the values it already has is not a violation.
   (test-case "updating a row without changing the indexed value is allowed"
     (parameterize ([current-issue-rows (make-hash)])
       (with-capabilities (db-read db-write)
         (insert-one! Issue (issue "i1" "org1" "bug" 1))
         (update-many! (from Issue)
                       (hash 'createdAt 99)
                       (where (==. issue-id-field "i1")))
         (check-equal? (hash-ref (hash-ref (current-issue-rows) "i1") 'createdAt) 99))))

   (test-case "upsert conflicting on the unique index updates rather than duplicating"
     (parameterize ([current-issue-rows (make-hash)])
       (with-capabilities (db-read db-write)
         (insert-one! Issue (issue "i1" "org1" "bug" 1))
         (upsert-one! Issue (issue "i9" "org1" "bug" 42) '(orgId slug) '(createdAt))
         (check-equal? (hash-count (current-issue-rows)) 1)
         (check-equal? (hash-ref (hash-ref (current-issue-rows) "i1") 'createdAt) 42))))

   (test-case "upsert inserting a row that violates a DIFFERENT unique index is refused"
     (parameterize ([current-issue-rows (make-hash)])
       (with-capabilities (db-read db-write)
         (insert-one! Issue (issue "i1" "org1" "bug" 1))
         ;; Conflicting on the primary key, so no existing row matches — this is
         ;; an INSERT, and it collides with the (orgId, slug) unique index.
         (check-exn #rx"unique index"
                    (lambda ()
                      (upsert-one! Issue (issue "i2" "org1" "bug" 5)
                                   '(id) '(createdAt)))))))))

;; ── NULL semantics ─────────────────────────────────────────────────────────

(define current-optional-rows (make-parameter (make-hash)))

(define-entity Optional
  #:source (lambda () (current-optional-rows))
  #:table "optionals"
  #:primary-key id
  #:indexes ((unique (tag) #f))
  [Id id : String]
  [Tag tag : (Maybe String)])

(define null-tests
  (test-suite
   "unique indexes and NULL"

   ;; PostgreSQL: two NULLs are not equal, so a unique index does not constrain
   ;; rows with a NULL in an indexed column.  The Memory backend must agree, or
   ;; a legitimate program fails only in tests.
   (test-case "several NULL-tagged rows coexist"
     (parameterize ([current-optional-rows (make-hash)])
       (with-capabilities (db-read db-write)
         (insert-one! Optional (hash 'id "a" 'tag Nothing))
         (insert-one! Optional (hash 'id "b" 'tag Nothing))
         (check-equal? (hash-count (current-optional-rows)) 2))))

   (test-case "non-NULL duplicates are still refused"
     (parameterize ([current-optional-rows (make-hash)])
       (with-capabilities (db-read db-write)
         (insert-one! Optional (hash 'id "a" 'tag (Something "x")))
         (check-exn #rx"unique index"
                    (lambda ()
                      (insert-one! Optional (hash 'id "b" 'tag (Something "x"))))))))))

(module+ main
  (require rackunit/text-ui)
  (exit (+ (run-tests parse-tests)
           (run-tests name-tests)
           (run-tests ddl-tests)
           (run-tests presence-tests)
           (run-tests memory-tests)
           (run-tests null-tests))))

(module+ test
  (require rackunit/text-ui)
  (void (run-tests parse-tests))
  (void (run-tests name-tests))
  (void (run-tests ddl-tests))
  (void (run-tests presence-tests))
  (void (run-tests memory-tests))
  (void (run-tests null-tests)))
