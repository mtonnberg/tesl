#lang racket

(require rackunit
         racket/match
         racket/runtime-path
         "../dsl/capability.rkt"
         "../dsl/check.rkt"
         "../dsl/sql.rkt"
         "../dsl/types.rkt"
         "../dsl/web.rkt"
         (prefix-in private: "../dsl/private/check-runtime.rkt"))

(define-runtime-path check-rkt "../dsl/check.rkt")
(define-runtime-path web-rkt "../dsl/web.rkt")

(define (run-temp-module source [provided #f])
  (define temp-path (make-temporary-file "tesl-sql-test-~a.rkt"))
  (call-with-output-file temp-path
    (lambda (out)
      (display source out))
    #:exists 'replace)
  (dynamic-wind
    void
    (lambda ()
      (dynamic-require temp-path provided))
    (lambda ()
      (when (file-exists? temp-path)
        (delete-file temp-path)))))

(define-adt SqlTaskStatus
  [Open]
  [Done])

(define current-task-rows (make-parameter (make-hash)))

(define-entity TestTask
  #:source (lambda () (current-task-rows))
  #:primary-key id
  [Id id : Integer]
  [Title title : String]
  [OwnerId ownerId : String]
  [Status status : SqlTaskStatus])

(current-task-rows
 (make-hash
  (list (cons 1 (hash 'id 1 'title "Pay invoices" 'ownerId "mikael" 'status Open))
        (cons 2 (hash 'id 2 'title "Review audit log" 'ownerId "anna" 'status Open)))))

(check-exn
 exn:fail:user?
 (lambda ()
   (select-many (from TestTask))))

(define/pow
  (list-tasks-without-declared-cap)
  #:returns Any
  (select-many (from TestTask)))

(define/pow
  (list-tasks-with-declared-cap)
  #:capabilities [db-read]
  #:returns Any
  (select-many (from TestTask)))

(check-exn
 (lambda (exn)
   (and (exn:fail:user? exn)
        (regexp-match? #rx"current DSL context" (exn-message exn))))
 (lambda ()
   (with-capabilities (db-read)
     (list-tasks-without-declared-cap))))

(with-capabilities (db-write)

(define task-id-binding (private:runtime-bind 'taskId 1))
(define task-id-name (runtime-binding-name task-id-binding))
(define queried-task
  (parameterize ([private:current-name-env (private:extend-name-env (hash) '(taskId) (list task-id-binding))]
                 [private:current-proof-env (private:extend-proof-env (hash) (list task-id-binding))])
    (select-one (from TestTask)
                (where (==. (TestTask-id) task-id-name)))))

(check-true (named-value? queried-task))
(check-true ((runtime-type-predicate 'TestTask) (raw-value queried-task)))
(check-equal? (hash-ref (raw-value queried-task) 'title) "Pay invoices")
(check-true (Open? (hash-ref (raw-value queried-task) 'status)))
(match (facts-of queried-task)
  [`((FromDb (Id == ,token) ,_entity-subject))
   (check-equal? token task-id-name)]
  [other
   (error 'test "unexpected query facts: ~a" other)])
(check-equal? (hash-ref (named-value-bindings queried-task) task-id-name) 1)

(check-false
 (parameterize ([private:current-name-env (private:extend-name-env (hash) '(taskId) (list task-id-binding))]
                [private:current-proof-env (private:extend-proof-env (hash) (list task-id-binding))])
   (select-one (from TestTask)
               (where (==. (TestTask-id) 99)))))

(define owner-id-binding (private:runtime-bind 'ownerId "mikael"))
(define owner-id-name (runtime-binding-name owner-id-binding))
(define owner-matched-task
  (parameterize ([private:current-name-env (private:extend-name-env (hash) '(ownerId) (list owner-id-binding))]
                 [private:current-proof-env (private:extend-proof-env (hash) (list owner-id-binding))])
    (select-one (from TestTask)
                (where (==. (TestTask-ownerId) owner-id-name)))))

(check-true (named-value? owner-matched-task))
(check-equal? (hash-ref (raw-value owner-matched-task) 'ownerId) "mikael")
(match (facts-of owner-matched-task)
  [`((FromDb (OwnerId == ,token) ,_entity-subject))
   (check-equal? token owner-id-name)]
  [other
   (error 'test "unexpected owner query facts: ~a" other)])
(check-equal? (hash-ref (named-value-bindings owner-matched-task) owner-id-name) "mikael")

(define open-tasks
  (select-many (from TestTask)
               (where (==. (TestTask-status) Open))))
(check-equal? (length open-tasks) 2)
(check-true (andmap named-value? open-tasks))

(define later-task-matches
  (select-many (from TestTask)
               (where (>. (TestTask-id) 1))))
(check-equal? (length later-task-matches) 1)
(check-equal? (hash-ref (raw-value (car later-task-matches)) 'id) 2)

(define early-title-matches
  (select-many (from TestTask)
               (where (<. (TestTask-title) "Q"))))
(check-equal? (length early-title-matches) 1)
(check-equal? (hash-ref (raw-value (car early-title-matches)) 'title) "Pay invoices")

(check-exn exn:fail:user?
           (lambda ()
             (select-many (from TestTask)
                          (where (==. (TestTask-status) "open")))))
(check-exn exn:fail:user?
           (lambda ()
             (select-many (from TestTask)
                          (where (>. (TestTask-status) Open)))))
(check-exn exn:fail:user?
           (lambda ()
             (insert-one! TestTask
                          (hash 'id 4
                                'title "Bypass ADT"
                                'ownerId "mikael"
                                'status "open"))))

(define bad-return-module
  (format #<<MODULE
#lang racket
(require (file ~s) (file ~s))
(define (pass-auth req) (ensure-named 'requestUser (hash 'id "mikael")))
(define-handler
  (bad-handler
    [requestUser : User ::: (Authenticated requestUser)]
    [taskId : Integer ::: (Positive taskId)])
  #:returns (Task ::: (FromDb [Id == taskId]))
  (hash 'id *taskId 'title "Not proved"))
(define-api BadAPI
  [get-task :
    (Auth [requestUser : User ::: (Authenticated requestUser)]
          #:via pass-auth)
    :> "tasks"
    :> (Capture [taskId : Integer ::: (Positive taskId)]
                #:parser integer-segment)
    :> (Get JSON
         (Task ::: (FromDb [Id == taskId])))])
(define-server BadServer
  #:api BadAPI
  [get-task bad-handler])
(provide BadServer)
MODULE
          (path->string check-rkt)
          (path->string web-rkt)))

(define bad-server (run-temp-module bad-return-module 'BadServer))
(define bad-response
  (parameterize ([current-handler-error-port (open-output-nowhere)])
    (dispatch-request bad-server
                      (make-request 'GET '("tasks" "1"))
                      #:capabilities '())))
(check-equal? (dsl-response-status bad-response) 500)
(check-true
 (regexp-match?
  #rx"declared return (type|proof)"
  (format "~a" (first (hash-ref (dsl-response-body bad-response) 'details)))))

(define created-task-id-binding (private:runtime-bind 'createdTaskId 3))
(define created-task-id-name (runtime-binding-name created-task-id-binding))
(define inserted-task
  (parameterize ([private:current-name-env (private:extend-name-env (hash) '(createdTaskId) (list created-task-id-binding))]
                 [private:current-proof-env (private:extend-proof-env (hash) (list created-task-id-binding))])
    (insert-one! TestTask
                 (hash 'id created-task-id-name
                       'title "Write migration tests"
                       'ownerId "mikael"
                       'status Open))))
(check-true (named-value? inserted-task))
(check-equal? (hash-ref (raw-value inserted-task) 'id) 3)
(check-true (Open? (hash-ref (raw-value inserted-task) 'status)))
(match (facts-of inserted-task)
  [`((FromDb (Id == ,token) ,_entity-subject))
   (check-equal? token created-task-id-name)]
  [other
   (error 'test "unexpected insert facts: ~a" other)])
(check-equal? (length (select-many (from TestTask))) 3)

(check-exn exn:fail:user?
           (lambda ()
             (update-many! (from TestTask)
                           (hash (TestTask-status) "done")
                           (where (==. (TestTask-id) 1)))))

(define updated-task
  (parameterize ([private:current-name-env (private:extend-name-env (hash) '(taskId) (list task-id-binding))]
                 [private:current-proof-env (private:extend-proof-env (hash) (list task-id-binding))])
    (car (update-many! (from TestTask)
                       (hash (TestTask-status) Done)
                       (where (==. (TestTask-id) task-id-name))))))
(check-equal? (hash-ref (raw-value updated-task) 'status) Done)
(check-true (Done? (hash-ref (raw-value updated-task) 'status)))
(match (facts-of updated-task)
  [`((FromDb (Id == ,token) ,_entity-subject))
   (check-equal? token task-id-name)]
  [other
   (error 'test "unexpected update facts: ~a" other)])

(check-equal? (length (select-many (from TestTask)
                                   (where (==. (TestTask-status) Done))))
              1)
(check-equal? (length (select-many (from TestTask)
                                   (where (!=. (TestTask-status) Done))))
              2)
(check-equal? (length (select-many (from TestTask)
                                   (where (>=. (TestTask-id) 2))))
              2)

(check-equal? (delete-many-with-count! (from TestTask)
                            (where (==. (TestTask-id) 3)))
              (RowsDeleted 1))
(check-false (select-one (from TestTask)
                         (where (==. (TestTask-id) 3))))

(check-equal? (length (list-tasks-with-declared-cap)) 2))

;; ── New SQL feature tests ────────────────────────────────────────────────────

(define current-user-rows (make-parameter (make-hash)))

(define-entity TestUser
  #:source (lambda () (current-user-rows))
  #:primary-key id
  [Id id : Integer]
  [Name name : String]
  [Email email : String]
  [Active active : Boolean])

(current-user-rows
 (make-hash
  (list (cons 1 (hash 'id 1 'name "Alice" 'email "alice@example.com" 'active #t))
        (cons 2 (hash 'id 2 'name "Bob" 'email "bob@example.com" 'active #f))
        (cons 3 (hash 'id 3 'name "Charlie" 'email "charlie@example.com" 'active #t)))))

(with-capabilities (db-read)

;; ── OFFSET tests ──────────────────────────────────────────────────────────────

(check-equal?
 (length (select-many (from TestUser)))
 3
 "all users returned without limit/offset")

(check-equal?
 (length (select-many (from TestUser)
                      (limit 10)
                      (offset 0)))
 3
 "limit 10 offset 0 returns all 3")

(check-equal?
 (length (select-many (from TestUser)
                      (limit 2)
                      (offset 1)))
 2
 "limit 2 offset 1 returns 2")

(check-equal?
 (length (select-many (from TestUser)
                      (limit 10)
                      (offset 2)))
 1
 "limit 10 offset 2 returns 1")

(check-equal?
 (length (select-many (from TestUser)
                      (limit 10)
                      (offset 10)))
 0
 "offset past end returns empty")

;; ── IN / NOT IN tests ─────────────────────────────────────────────────────────

(check-equal?
 (length (select-many (from TestUser)
                      (where (in?. (TestUser-name) (list "Alice" "Charlie")))))
 2
 "in?. matches two users")

(check-equal?
 (length (select-many (from TestUser)
                      (where (not-in?. (TestUser-name) (list "Alice" "Bob")))))
 1
 "not-in?. excludes two users")

(check-equal?
 (length (select-many (from TestUser)
                      (where (in?. (TestUser-name) (list)))))
 0
 "in?. with empty list returns nothing")

;; ── LIKE / ILIKE tests ────────────────────────────────────────────────────────

(check-equal?
 (length (select-many (from TestUser)
                      (where (like?. (TestUser-email) "alice%"))))
 1
 "like?. matches prefix")

(check-equal?
 (length (select-many (from TestUser)
                      (where (like?. (TestUser-email) "%@example.com"))))
 3
 "like?. matches suffix for all 3")

(check-equal?
 (length (select-many (from TestUser)
                      (where (like?. (TestUser-email) "%bob%"))))
 1
 "like?. matches substring")

(check-equal?
 (length (select-many (from TestUser)
                      (where (ilike?. (TestUser-email) "%EXAMPLE.COM"))))
 3
 "ilike?. case-insensitive matches all 3")

(check-equal?
 (length (select-many (from TestUser)
                      (where (ilike?. (TestUser-name) "ALICE"))))
 1
 "ilike?. case-insensitive name match")

;; ── IS NULL / IS NOT NULL tests ───────────────────────────────────────────────

(check-equal?
 (length (select-many (from TestUser)
                      (where (not-null?. (TestUser-name)))))
 3
 "not-null?. matches all non-null names")

(check-equal?
 (length (select-many (from TestUser)
                      (where (null?. (TestUser-name)))))
 0
 "null?. matches zero rows (names are not null)")

;; ── GROUP BY (in-memory: ignores group-by) ────────────────────────────────────

(check-equal?
 (length (select-many (from TestUser)
                      (group-by (TestUser-active))))
 3
 "group-by in-memory ignored, returns all rows")

;; ── Compile-predicate-sql tests ────────────────────────────────────────────────

(define test-field (TestUser-name))

(define-values (null-sql null-params null-idx)
  (compile-predicate-sql (null-predicate test-field) 1))
(check-equal? null-sql "\"name\" IS NULL")
(check-equal? null-params '())
(check-equal? null-idx 1)

(define-values (not-null-sql not-null-params not-null-idx)
  (compile-predicate-sql (not-null-predicate test-field) 1))
(check-equal? not-null-sql "\"name\" IS NOT NULL")
(check-equal? not-null-params '())
(check-equal? not-null-idx 1)

(define-values (like-sql like-params like-idx)
  (compile-predicate-sql (like-predicate test-field "%Smith%") 1))
(check-equal? like-sql "\"name\" LIKE $1")
(check-equal? like-params '("%Smith%"))
(check-equal? like-idx 2)

(define-values (ilike-sql ilike-params ilike-idx)
  (compile-predicate-sql (ilike-predicate test-field "%smith%") 3))
(check-equal? ilike-sql "\"name\" ILIKE $3")
(check-equal? ilike-params '("%smith%"))
(check-equal? ilike-idx 4)

(define-values (in-sql in-params in-idx)
  (compile-predicate-sql (in-predicate (TestUser-id) (list 1 2 3)) 1))
(check-equal? in-sql "\"id\" IN ($1, $2, $3)")
(check-equal? in-params (list 1 2 3))
(check-equal? in-idx 4)

(define-values (not-in-sql not-in-params not-in-idx)
  (compile-predicate-sql (not-in-predicate (TestUser-id) (list 1 2)) 5))
(check-equal? not-in-sql "\"id\" NOT IN ($5, $6)")
(check-equal? not-in-params (list 1 2))
(check-equal? not-in-idx 7)

)  ;; end with-capabilities

;; ── INNER JOIN tests ──────────────────────────────────────────────────────────

(define current-profile-rows (make-parameter (make-hash)))

(define-entity TestProfile
  #:source (lambda () (current-profile-rows))
  #:primary-key id
  [Id id : Integer]
  [UserId userId : Integer]
  [Bio bio : String])

;; Alice (id=1) and Charlie (id=3) have profiles; Bob (id=2) does not.
(current-profile-rows
 (make-hash
  (list (cons 1 (hash 'id 1 'userId 1 'bio "Alice's bio"))
        (cons 2 (hash 'id 2 'userId 3 'bio "Charlie's bio")))))

(with-capabilities (db-read)

(check-equal?
 (length (select-many (from TestUser)
                      (inner-join TestProfile (TestUser-id) (TestProfile-userId))))
 2
 "inner-join filters to users with a matching profile (2 of 3)")

(check-equal?
 (sort
  (map (lambda (row) (hash-ref (raw-value row) 'name))
       (select-many (from TestUser)
                    (inner-join TestProfile (TestUser-id) (TestProfile-userId))))
  string<?)
 (list "Alice" "Charlie")
 "inner-join returns Alice and Charlie, not Bob")

(check-equal?
 (length (select-many (from TestUser)
                      (where (==. (TestUser-active) #t))
                      (inner-join TestProfile (TestUser-id) (TestProfile-userId))))
 2
 "inner-join combined with where: active users with profiles")

)  ;; end with-capabilities
