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
  (only-in tesl/tesl/prelude String)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
)


(provide Task fetchTask seedAndFetch processTask fetchAndProcess seedAndProcess existentialFetch fetchTask-signature seedAndFetch-signature processTask-signature fetchAndProcess-signature seedAndProcess-signature existentialFetch-signature)

;; Debugger: the lines whose statement is a READ-ONLY query.  The pause on
;; those happens AFTER the statement, so the SQL lens can show the exact
;; statement that ran (erased with the checkpoints in a release build).
(register-sql-read-lines! "example/learn/lesson20-named-db-results.tesl" '(108 117 157))
(define-entity Task
  #:source (make-hash)
  #:table tasks
  #:primary-key id
  [Id id : String]
  [Title title : String]
  [Status status : String]
)

(define/pow
  (fetchTask [id : String])
  #:capabilities [dbRead]
  #:returns (? Task _entity ::: (FromDb (Id == id) _entity))
  (let ([r (thsl-src! "example/learn/lesson20-named-db-results.tesl" 108 (list (cons 'id *id)) (lambda () (let ([tesl_match (select-one (from Task) (where (==. (entity-field-ref Task 'id) id)))]) (if tesl_match (Something tesl_match) Nothing))) 'r)]) (thsl-src-control! "example/learn/lesson20-named-db-results.tesl" 109 (list (cons 'r *r) (cons 'id *id)) (lambda () (let ([tesl-case-0 (raw-value r)]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/learn/lesson20-named-db-results.tesl" 110 (list) (lambda () (reject "task not found" #:http-code 404)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([t (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson20-named-db-results.tesl" 111 (list (cons 't t)) (lambda () t)))]))))))

(define/pow
  (seedAndFetch [id : String])
  #:capabilities [dbRead dbWrite]
  #:returns (? Task _entity ::: (FromDb (Id == id) _entity))
  (let ([_ (thsl-src! "example/learn/lesson20-named-db-results.tesl" 116 (list (cons 'id *id)) (lambda () (insert-one! Task (tesl-hash 'id id 'title (format "task: ~a" (tesl-display-val *id)) 'status "open"))))]) (let ([r (thsl-src! "example/learn/lesson20-named-db-results.tesl" 117 (list (cons '_ *_) (cons 'id *id)) (lambda () (let ([tesl_match (select-one (from Task) (where (==. (entity-field-ref Task 'id) id)))]) (if tesl_match (Something tesl_match) Nothing))) 'r)]) (thsl-src-control! "example/learn/lesson20-named-db-results.tesl" 118 (list (cons 'r *r) (cons '_ *_) (cons 'id *id)) (lambda () (let ([tesl-case-1 (raw-value r)]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "example/learn/lesson20-named-db-results.tesl" 119 (list) (lambda () (reject "missing after insert" #:http-code 500)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([t (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "example/learn/lesson20-named-db-results.tesl" 120 (list (cons 't t)) (lambda () t)))])))))))

(define/pow
  (processTask [t : Task ::: (FromDb (Id == id) t)] [id : String])
  #:returns String
  (thsl-src! "example/learn/lesson20-named-db-results.tesl" 131 (list (cons 't *t) (cons 'id *id)) (lambda () (format "task: ~a status=~a" (tesl-display-val *id) (tesl-display-val (raw-value t.status))))))

(define/pow
  (fetchAndProcess [id : String])
  #:capabilities [dbRead]
  #:returns String
  (let ([t (thsl-src! "example/learn/lesson20-named-db-results.tesl" 139 (list (cons 'id *id)) (lambda () (fetchTask id)))]) (thsl-src! "example/learn/lesson20-named-db-results.tesl" 140 (list (cons 't *t) (cons 'id *id)) (lambda () (raw-value (processTask t id))))))

(define/pow
  (seedAndProcess [id : String])
  #:capabilities [dbRead dbWrite]
  #:returns String
  (let ([t (thsl-src! "example/learn/lesson20-named-db-results.tesl" 144 (list (cons 'id *id)) (lambda () (seedAndFetch id)))]) (thsl-src! "example/learn/lesson20-named-db-results.tesl" 145 (list (cons 't *t) (cons 'id *id)) (lambda () (raw-value (processTask t id))))))

(define/pow
  (existentialFetch [prefix : String])
  #:capabilities [dbRead dbWrite]
  #:returns (Exists [taskId : String] (? Task _entity ::: (FromDb (Id == taskId) _entity)))
  (let ([taskId (thsl-src! "example/learn/lesson20-named-db-results.tesl" 155 (list (cons 'prefix *prefix)) (lambda () (format "~a-auto" (tesl-display-val *prefix))))]) (let ([_ (thsl-src! "example/learn/lesson20-named-db-results.tesl" 156 (list (cons 'taskId *taskId) (cons 'prefix *prefix)) (lambda () (insert-one! Task (tesl-hash 'id taskId 'title "auto task" 'status "new"))))]) (let ([r (thsl-src! "example/learn/lesson20-named-db-results.tesl" 157 (list (cons '_ *_) (cons 'taskId *taskId) (cons 'prefix *prefix)) (lambda () (let ([tesl_match (select-one (from Task) (where (==. (entity-field-ref Task 'id) taskId)))]) (if tesl_match (Something tesl_match) Nothing))) 'r)]) (thsl-src-control! "example/learn/lesson20-named-db-results.tesl" 158 (list (cons 'r *r) (cons '_ *_) (cons 'taskId *taskId) (cons 'prefix *prefix)) (lambda () (let ([tesl-case-2 (raw-value r)]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "example/learn/lesson20-named-db-results.tesl" 159 (list) (lambda () (reject "missing after insert" #:http-code 500)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([t (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "example/learn/lesson20-named-db-results.tesl" 161 (list (cons 't t)) (lambda () (pack ([taskId]) t))))]))))))))

(module+ test
  (require rackunit)
  (test-case "named db result preserves proof"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define t (thsl-src! "example/learn/lesson20-named-db-results.tesl" 171 (list) (lambda () (seedAndFetch "test-1"))))
    (check-equal? (thsl-src! "example/learn/lesson20-named-db-results.tesl" 174 (list (cons 't t)) (lambda () (raw-value (tesl-dot/runtime t 'title 'Task)))) "task: test-1")
    (check-equal? (thsl-src! "example/learn/lesson20-named-db-results.tesl" 175 (list (cons 't t)) (lambda () (raw-value (tesl-dot/runtime t 'status 'Task)))) "open")
    )
    ))
  )

  (test-case "proof annotation verifies entity came from db"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define queryId (thsl-src! "example/learn/lesson20-named-db-results.tesl" 182 (list) (lambda () "test-proof")))
    (define t (thsl-src! "example/learn/lesson20-named-db-results.tesl" 183 (list (cons 'queryId queryId)) (lambda () (seedAndFetch queryId))))
    (check-equal? (thsl-src! "example/learn/lesson20-named-db-results.tesl" 184 (list (cons 't t) (cons 'queryId queryId)) (lambda () (raw-value (tesl-dot/runtime t 'title 'Task)))) "task: test-proof")
    )
    ))
  )

  (test-case "processTask receives named entity"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-3 (thsl-src! "example/learn/lesson20-named-db-results.tesl" 191 (list) (lambda () (seedAndFetch "test-2"))))
    (define result (thsl-src! "example/learn/lesson20-named-db-results.tesl" 192 (list) (lambda () (fetchAndProcess "test-2"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson20-named-db-results.tesl" 193 (list (cons 'result result)) (lambda () result))) "task: test-2 status=open")
    )
    ))
  )

  (test-case "seedAndProcess chains fetch and process"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define result (thsl-src! "example/learn/lesson20-named-db-results.tesl" 197 (list) (lambda () (seedAndProcess "test-3"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson20-named-db-results.tesl" 198 (list (cons 'result result)) (lambda () result))) "task: test-3 status=open")
    )
    ))
  )

)
