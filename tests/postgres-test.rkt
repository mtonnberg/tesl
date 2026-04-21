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

(define (run-postgres-tests)
  (if (not (postgres-tooling-available?))
      (displayln "Skipping postgres-test.rkt because initdb/pg_ctl are not available")
      (call-with-temporary-postgres
       (lambda (cfg)
         (run-query-tests cfg)
         (run-malformed-row-tests cfg)
         (run-migration-tests cfg)))))

(run-postgres-tests)
