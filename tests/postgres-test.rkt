#lang racket

(require db
         rackunit
         racket/match
         "../dsl/capability.rkt"
         "../dsl/check.rkt"
         "../dsl/sql.rkt"
         "../dsl/types.rkt"
         (prefix-in private: "../dsl/private/check-runtime.rkt")
         "private/postgres-test-support.rkt")

(define-adt PgTaskStatus
  [Open]
  [Done])

(define-entity PgTask
  #:table pg_tasks
  #:primary-key id
  [Id id : Integer]
  [Title title : String]
  [OwnerId ownerId : String]
  [Status status : PgTaskStatus])

(define-entity MigrationTaskV2
  #:table migration_tasks
  #:primary-key id
  [Id id : Integer]
  [Title title : String]
  [Status status : PgTaskStatus])

;; Entity indexes: the same entity shape with declared indexes, used by
;; run-index-tests below.  Declared indexes are created by auto-migration on a
;; new/empty table; on a POPULATED table a missing plain index warns and boots
;; while a missing unique index refuses, because only the latter is a
;; correctness defect (see postgres-ensure-entity-indexes! in dsl/sql.rkt).
(define-entity IndexedTask
  #:table indexed_tasks
  #:primary-key id
  #:indexes ((plain (ownerId title) #f)
             (unique (title) #f)
             (plain (ownerId) "indexed_tasks_owner_named"))
  [Id id : Integer]
  [Title title : String]
  [OwnerId ownerId : String])

;; Same table, one extra plain index — declared only in the "already populated"
;; scenario so the warn-and-boot path has something missing to report.
(define-entity IndexedTaskExtraPlain
  #:table indexed_tasks
  #:primary-key id
  #:indexes ((plain (title ownerId) #f))
  [Id id : Integer]
  [Title title : String]
  [OwnerId ownerId : String])

;; Same table, one extra UNIQUE index — the refuse-to-boot path.
(define-entity IndexedTaskExtraUnique
  #:table indexed_tasks
  #:primary-key id
  #:indexes ((unique (ownerId) #f))
  [Id id : Integer]
  [Title title : String]
  [OwnerId ownerId : String])

(define (make-direct-connection cfg)
  (postgresql-connect #:user (hash-ref cfg 'user)
                      #:database (hash-ref cfg 'database)
                      #:server (hash-ref cfg 'host)
                      #:port (hash-ref cfg 'port)))

(define (run-query-tests cfg)
  (define host (hash-ref cfg 'host))
  (define port (hash-ref cfg 'port))
  (define db-name (hash-ref cfg 'database))
  (define user (hash-ref cfg 'user))

  (define-database PgTaskDb
    #:backend postgres
    #:database db-name
    #:user user
    #:server host
    #:port port
    #:schema sql_backend_test
    #:entities PgTask)

  (call-with-database
   PgTaskDb
   (lambda ()
     (with-capabilities (db-write)
       (define inserted-task
       (insert-one! PgTask
                    (hash 'id 1
                          'title "Verify migrations"
                          'ownerId "mikael"
                          'status Open)))
     (check-true (named-value? inserted-task))
     (check-equal? (hash-ref (raw-value inserted-task) 'title) "Verify migrations")
     (check-true (Open? (hash-ref (raw-value inserted-task) 'status)))

     (define open-tasks
       (select-many (from PgTask)
                    (where (==. (PgTask-status) Open))))
     (check-equal? (length open-tasks) 1)

     (define id-matches
       (select-many (from PgTask)
                    (where (>. (PgTask-id) 0))))
     (check-equal? (length id-matches) 1)

     (define title-matches
       (select-many (from PgTask)
                    (where (<. (PgTask-title) "Z"))))
     (check-equal? (length title-matches) 1)

     (check-exn exn:fail:user?
                (lambda ()
                  (select-many (from PgTask)
                               (where (==. (PgTask-status) "open")))))
     (check-exn exn:fail:user?
                (lambda ()
                  (select-many (from PgTask)
                               (where (>. (PgTask-status) Open)))))

     (define task-id-binding (private:runtime-bind 'taskId 1))
     (define task-id-name (runtime-binding-name task-id-binding))
     (define queried-task
       (parameterize ([private:current-name-env (private:extend-name-env (hash) '(taskId) (list task-id-binding))]
                      [private:current-proof-env (private:extend-proof-env (hash) (list task-id-binding))])
         (select-one (from PgTask)
                     (where (==. (PgTask-id) task-id-name)))))
     (check-true (named-value? queried-task))
     (check-true (Open? (hash-ref (raw-value queried-task) 'status)))
     (match (facts-of queried-task)
       [`((FromDb (Id == ,token) ,_entity-subject))
        (check-equal? token task-id-name)]
       [other
        (error 'postgres-test "unexpected PostgreSQL query facts: ~a" other)])

     (define updated-task
       (parameterize ([private:current-name-env (private:extend-name-env (hash) '(taskId) (list task-id-binding))]
                      [private:current-proof-env (private:extend-proof-env (hash) (list task-id-binding))])
         (car (update-many! (from PgTask)
                            (hash (PgTask-status) Done)
                            (where (==. (PgTask-id) task-id-name))))))
     (check-true (Done? (hash-ref (raw-value updated-task) 'status)))

     (define done-tasks
       (select-many (from PgTask)
                    (where (==. (PgTask-status) Done))))
     (check-equal? (length done-tasks) 1)
     (check-equal? (length (select-many (from PgTask)
                                        (where (!=. (PgTask-status) Done))))
                   0)

     (check-equal? (delete-many-with-count! (from PgTask)
                                 (where (==. (PgTask-id) 1)))
                   (RowsDeleted 1))
     (check-false (select-one (from PgTask)
                              (where (==. (PgTask-id) 1))))))))


(define (run-malformed-row-tests cfg)
  (define host (hash-ref cfg 'host))
  (define port (hash-ref cfg 'port))
  (define db-name (hash-ref cfg 'database))
  (define user (hash-ref cfg 'user))

  (define-database MalformedPgTaskDb
    #:backend postgres
    #:database db-name
    #:user user
    #:server host
    #:port port
    #:schema malformed_sql_backend_test
    #:entities PgTask)

  (call-with-database MalformedPgTaskDb (lambda () (void)))

  (define direct-conn (make-direct-connection cfg))
  (dynamic-wind
    void
    (lambda ()
      (query-exec direct-conn
                  "insert into malformed_sql_backend_test.pg_tasks (id, title, owner_id, status) values (2, 'Broken status', 'mikael', $1)"
                  "{\"tag\":\"Missing\"}")
      (call-with-database
       MalformedPgTaskDb
       (lambda ()
         (with-capabilities (db-read)
           (check-exn
            #rx"unknown ADT variant"
            (lambda ()
              (select-one (from PgTask)
                          (where (==. (PgTask-id) 2)))))))))
    (lambda ()
      (disconnect direct-conn))))

(define (run-migration-tests cfg)
  (define host (hash-ref cfg 'host))
  (define port (hash-ref cfg 'port))
  (define db-name (hash-ref cfg 'database))
  (define user (hash-ref cfg 'user))
  (define direct-conn (make-direct-connection cfg))

  (dynamic-wind
    void
    (lambda ()
      (query-exec direct-conn "create schema if not exists migration_additive")
      (query-exec direct-conn "create table migration_additive.migration_tasks (id BIGINT PRIMARY KEY, title TEXT NOT NULL)")

      (define-database MigrationAdditiveDb
        #:backend postgres
        #:database db-name
        #:user user
        #:server host
        #:port port
        #:schema migration_additive
        #:entities MigrationTaskV2)

      (call-with-database MigrationAdditiveDb (lambda () (void)))

      (check-true
       (query-value direct-conn
                    "select exists (
                       select 1
                         from information_schema.columns
                        where table_schema = $1 and table_name = $2 and column_name = $3
                     )"
                    "migration_additive"
                    "migration_tasks"
                    "status"))

      (check-equal?
       (query-value direct-conn
                    "select data_type
                       from information_schema.columns
                      where table_schema = $1 and table_name = $2 and column_name = $3"
                    "migration_additive"
                    "migration_tasks"
                    "status")
       "jsonb")

      (query-exec direct-conn "create schema if not exists migration_blocked")
      (query-exec direct-conn "create table migration_blocked.migration_tasks (id BIGINT PRIMARY KEY, title TEXT NOT NULL)")
      (query-exec direct-conn "insert into migration_blocked.migration_tasks (id, title) values (1, 'existing row')")

      (define-database MigrationBlockedDb
        #:backend postgres
        #:database db-name
        #:user user
        #:server host
        #:port port
        #:schema migration_blocked
        #:entities MigrationTaskV2)

      (check-exn
       #rx"automatic migration cannot add required column status"
       (lambda ()
         (connect-database MigrationBlockedDb))))
    (lambda ()
      (disconnect direct-conn))))

;; ── Declared indexes actually reach PostgreSQL ──────────────────────────────
;;
;; A compile-time validation pass and a DDL-string unit test both prove nothing
;; about the database: what matters is whether `pg_index` contains the index
;; after a normal boot.  These are the tests that would catch an emitter or
;; migration regression that every green unit test misses.
(define (run-index-tests cfg)
  (define host (hash-ref cfg 'host))
  (define port (hash-ref cfg 'port))
  (define db-name (hash-ref cfg 'database))
  (define user (hash-ref cfg 'user))
  (define direct-conn (make-direct-connection cfg))

  ;; (unique? . (column …)) for every index on indexed_tasks, primary key
  ;; included.
  (define (existing-indexes schema)
    (for/list ([row (in-list
                     (query-rows
                      direct-conn
                      "select i.indisunique,
                              (select array_to_string(array_agg(a.attname order by k.ord), ',')
                                 from unnest(i.indkey) with ordinality as k(attnum, ord)
                                 join pg_attribute a
                                   on a.attrelid = c.oid and a.attnum = k.attnum)
                         from pg_index i
                         join pg_class c on c.oid = i.indrelid
                         join pg_namespace n on n.oid = c.relnamespace
                        where n.nspname = $1 and c.relname = 'indexed_tasks'"
                      schema))])
      (cons (eq? (vector-ref row 0) #t)
            (string-split (vector-ref row 1) ","))))

  (define (index-names schema)
    (for/list ([row (in-list
                     (query-rows direct-conn
                                 "select indexname from pg_indexes
                                   where schemaname = $1 and tablename = 'indexed_tasks'"
                                 schema))])
      (vector-ref row 0)))

  (define-database IndexFreshDb
    #:backend postgres #:database db-name #:user user #:server host #:port port
    #:schema index_fresh #:entities IndexedTask)

  (define-database IndexEmptyDb
    #:backend postgres #:database db-name #:user user #:server host #:port port
    #:schema index_empty #:entities IndexedTask)

  (define-database IndexPopulatedPlainDb
    #:backend postgres #:database db-name #:user user #:server host #:port port
    #:schema index_populated #:entities IndexedTaskExtraPlain)

  (define-database IndexPopulatedUniqueDb
    #:backend postgres #:database db-name #:user user #:server host #:port port
    #:schema index_populated #:entities IndexedTaskExtraUnique)

  (dynamic-wind
    void
    (lambda ()
      ;; ── A brand-new table gets every declared index inline ───────────────
      (query-exec direct-conn "create schema if not exists index_fresh")
      (call-with-database IndexFreshDb (lambda () (void)))

      (define fresh (existing-indexes "index_fresh"))
      (check-not-false (member '(#f "owner_id" "title") fresh)
                       "declared composite plain index exists")
      (check-not-false (member '(#t "title") fresh)
                       "declared unique index exists AND is unique")
      (check-not-false (member '(#f "owner_id") fresh)
                       "explicitly named index exists")
      ;; The derived name is <table>_<col>…_idx over real column names; the
      ;; explicit `as` name is used verbatim.
      (check-not-false (member "indexed_tasks_owner_id_title_idx" (index-names "index_fresh"))
                       "derived index name")
      (check-not-false (member "indexed_tasks_owner_named" (index-names "index_fresh"))
                       "explicit index name used verbatim")

      ;; Booting twice must be a no-op, not a duplicate-index error: the DDL is
      ;; `if not exists` and presence is decided by column list.
      (define count-before (length (index-names "index_fresh")))
      (call-with-database IndexFreshDb (lambda () (void)))
      (check-equal? (length (index-names "index_fresh")) count-before
                    "a second boot adds nothing")

      ;; The unique index is enforced by PostgreSQL itself, which is the whole
      ;; point of being able to declare it.
      (call-with-database
       IndexFreshDb
       (lambda ()
         (with-capabilities (db-write)
           (insert-one! IndexedTask (hash 'id 1 'title "only" 'ownerId "a"))
           (check-exn
            #rx"duplicate key value|unique"
            (lambda ()
              (insert-one! IndexedTask (hash 'id 2 'title "only" 'ownerId "b")))))))

      ;; ── An existing EMPTY table is treated as fresh ───────────────────────
      (query-exec direct-conn "create schema if not exists index_empty")
      (query-exec direct-conn
                  "create table index_empty.indexed_tasks
                     (id BIGINT PRIMARY KEY, title TEXT NOT NULL, owner_id TEXT NOT NULL)")
      (call-with-database IndexEmptyDb (lambda () (void)))
      (check-not-false (member '(#t "title") (existing-indexes "index_empty"))
                       "an empty pre-existing table still gets its declared indexes")

      ;; ── A POPULATED table: plain index warns and boots ────────────────────
      ;;
      ;; Refusing here would mean a deploy that merely adds an index declaration
      ;; can take the service down, and a missing plain index is only a
      ;; performance defect.  The warning must carry the CONCURRENTLY statement,
      ;; because that is the safe form and it cannot run inside the migration
      ;; transaction.
      (query-exec direct-conn "create schema if not exists index_populated")
      (query-exec direct-conn
                  "create table index_populated.indexed_tasks
                     (id BIGINT PRIMARY KEY, title TEXT NOT NULL, owner_id TEXT NOT NULL)")
      (query-exec direct-conn
                  "insert into index_populated.indexed_tasks (id, title, owner_id)
                     values (1, 'existing', 'a')")

      (define warning
        (let ([out (open-output-string)])
          (parameterize ([current-error-port out])
            (call-with-database IndexPopulatedPlainDb (lambda () (void))))
          (get-output-string out)))

      (check-regexp-match #rx"missing the declared index" warning
                          "a missing plain index warns rather than failing the boot")
      (check-regexp-match #rx"create index concurrently if not exists" warning
                          "the warning hands the operator the CONCURRENTLY statement")
      (check-false (member '(#f "title" "owner_id") (existing-indexes "index_populated"))
                   "and the index is NOT built inside the migration transaction")

      ;; ── A POPULATED table: unique index refuses to boot ───────────────────
      ;;
      ;; A declared unique index the database is not enforcing is a correctness
      ;; defect, and `upsert … onConflict` depends on it existing.  Booting
      ;; anyway would be fail-open.
      (check-exn
       #rx"cannot add the declared unique index"
       (lambda () (connect-database IndexPopulatedUniqueDb)))

      (define refusal
        (with-handlers ([exn:fail? exn-message])
          (connect-database IndexPopulatedUniqueDb)))
      (check-regexp-match #rx"create unique index concurrently if not exists" refusal
                          "the refusal names the exact statement to run")

      ;; ── An index that exists but does not do the declared job ─────────────
      ;;
      ;; A PARTIAL index covers only the rows matching its predicate, so it can
      ;; satisfy neither a whole-table lookup declaration nor a whole-table
      ;; uniqueness one.  Counting it as present would silently leave the
      ;; declaration unmet.
      (query-exec direct-conn
                  "create index indexed_tasks_partial
                     on index_populated.indexed_tasks (title, owner_id)
                   where owner_id = 'a'")

      (define warning-with-partial
        (let ([out (open-output-string)])
          (parameterize ([current-error-port out])
            (call-with-database IndexPopulatedPlainDb (lambda () (void))))
          (get-output-string out)))
      (check-regexp-match #rx"missing the declared index" warning-with-partial
                          "a partial index does not satisfy a whole-table declaration"))
    (lambda ()
      (disconnect direct-conn))))

(define (run-postgres-tests)
  (if (not (postgres-tooling-available?))
      (displayln "Skipping postgres-test.rkt because initdb/pg_ctl are not available")
      (call-with-temporary-postgres
       (lambda (cfg)
         (run-query-tests cfg)
         (run-malformed-row-tests cfg)
         (run-migration-tests cfg)
         (run-index-tests cfg)))))

(run-postgres-tests)
