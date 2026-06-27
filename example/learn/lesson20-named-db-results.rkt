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
)


(provide Task fetchTask seedAndFetch processTask fetchAndProcess seedAndProcess existentialFetch fetchTask-signature seedAndFetch-signature processTask-signature fetchAndProcess-signature seedAndProcess-signature existentialFetch-signature)

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
  (let ([r (thsl-src! "example/learn/lesson20-named-db-results.tesl" 106 (list (cons 'id *id)) (lambda () (let ([tesl_match (select-one (from Task) (where (==. (entity-field-ref Task 'id) id)))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src-control! "example/learn/lesson20-named-db-results.tesl" 107 (list (cons 'r *r) (cons 'id *id)) (lambda () (let ([tesl_case_0 (raw-value r)]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) (thsl-src! "example/learn/lesson20-named-db-results.tesl" 108 (list) (lambda () (reject "task not found" #:http-code 404)))] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (let ([t (hash-ref (adt-value-fields *tesl_case_0) 'value)]) (thsl-src! "example/learn/lesson20-named-db-results.tesl" 109 (list (cons 't t)) (lambda () t)))]))))))

(define/pow
  (seedAndFetch [id : String])
  #:capabilities [dbRead dbWrite]
  #:returns (? Task _entity ::: (FromDb (Id == id) _entity))
  (let ([_ (thsl-src! "example/learn/lesson20-named-db-results.tesl" 114 (list (cons 'id *id)) (lambda () (insert-one! Task (hash 'id id 'title (format "task: ~a" (tesl-display-val *id)) 'status "open"))))]) (let ([r (thsl-src! "example/learn/lesson20-named-db-results.tesl" 115 (list (cons '_ *_) (cons 'id *id)) (lambda () (let ([tesl_match (select-one (from Task) (where (==. (entity-field-ref Task 'id) id)))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src-control! "example/learn/lesson20-named-db-results.tesl" 116 (list (cons 'r *r) (cons '_ *_) (cons 'id *id)) (lambda () (let ([tesl_case_1 (raw-value r)]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Nothing)) (thsl-src! "example/learn/lesson20-named-db-results.tesl" 117 (list) (lambda () (reject "missing after insert" #:http-code 500)))] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Something)) (let ([t (hash-ref (adt-value-fields *tesl_case_1) 'value)]) (thsl-src! "example/learn/lesson20-named-db-results.tesl" 118 (list (cons 't t)) (lambda () t)))])))))))

(define/pow
  (processTask [t : Task ::: (FromDb (Id == id) t)] [id : String])
  #:returns String
  (thsl-src! "example/learn/lesson20-named-db-results.tesl" 129 (list (cons 't *t) (cons 'id *id)) (lambda () (format "task: ~a status=~a" (tesl-display-val *id) (tesl-display-val (raw-value t.status))))))

(define/pow
  (fetchAndProcess [id : String])
  #:capabilities [dbRead]
  #:returns String
  (let ([t (thsl-src! "example/learn/lesson20-named-db-results.tesl" 137 (list (cons 'id *id)) (lambda () (fetchTask id)))]) (thsl-src! "example/learn/lesson20-named-db-results.tesl" 138 (list (cons 't *t) (cons 'id *id)) (lambda () (raw-value (processTask t id))))))

(define/pow
  (seedAndProcess [id : String])
  #:capabilities [dbRead dbWrite]
  #:returns String
  (let ([t (thsl-src! "example/learn/lesson20-named-db-results.tesl" 142 (list (cons 'id *id)) (lambda () (seedAndFetch id)))]) (thsl-src! "example/learn/lesson20-named-db-results.tesl" 143 (list (cons 't *t) (cons 'id *id)) (lambda () (raw-value (processTask t id))))))

(define/pow
  (existentialFetch [prefix : String])
  #:capabilities [dbRead dbWrite]
  #:returns (Exists [taskId : String] (? Task _entity ::: (FromDb (Id == taskId) _entity)))
  (let ([taskId (thsl-src! "example/learn/lesson20-named-db-results.tesl" 153 (list (cons 'prefix *prefix)) (lambda () (format "~a-auto" (tesl-display-val *prefix))))]) (let ([_ (thsl-src! "example/learn/lesson20-named-db-results.tesl" 154 (list (cons 'taskId *taskId) (cons 'prefix *prefix)) (lambda () (insert-one! Task (hash 'id taskId 'title "auto task" 'status "new"))))]) (let ([r (thsl-src! "example/learn/lesson20-named-db-results.tesl" 155 (list (cons '_ *_) (cons 'taskId *taskId) (cons 'prefix *prefix)) (lambda () (let ([tesl_match (select-one (from Task) (where (==. (entity-field-ref Task 'id) taskId)))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src-control! "example/learn/lesson20-named-db-results.tesl" 156 (list (cons 'r *r) (cons '_ *_) (cons 'taskId *taskId) (cons 'prefix *prefix)) (lambda () (let ([tesl_case_2 (raw-value r)]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Nothing)) (thsl-src! "example/learn/lesson20-named-db-results.tesl" 157 (list) (lambda () (raw-value (reject "missing after insert" #:http-code 500))))] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Something)) (let ([t (hash-ref (adt-value-fields *tesl_case_2) 'value)]) (thsl-src! "example/learn/lesson20-named-db-results.tesl" 159 (list (cons 't t)) (lambda () (raw-value (pack ([taskId]) t)))))]))))))))

(module+ test
  (require rackunit)
  (test-case "named db result preserves proof"
    (with-capabilities (dbRead dbWrite)
    (define t (thsl-src! "example/learn/lesson20-named-db-results.tesl" 169 (list) (lambda () (seedAndFetch "test-1"))))
    (check-equal? (thsl-src! "example/learn/lesson20-named-db-results.tesl" 172 (list (cons 't t)) (lambda () (raw-value (tesl-dot/runtime t 'title)))) "task: test-1")
    (check-equal? (thsl-src! "example/learn/lesson20-named-db-results.tesl" 173 (list (cons 't t)) (lambda () (raw-value (tesl-dot/runtime t 'status)))) "open")
    )
  )

  (test-case "proof annotation verifies entity came from db"
    (with-capabilities (dbRead dbWrite)
    (define queryId (thsl-src! "example/learn/lesson20-named-db-results.tesl" 180 (list) (lambda () "test-proof")))
    (define t (thsl-src! "example/learn/lesson20-named-db-results.tesl" 181 (list (cons 'queryId queryId)) (lambda () (seedAndFetch queryId))))
    (check-equal? (thsl-src! "example/learn/lesson20-named-db-results.tesl" 182 (list (cons 't t) (cons 'queryId queryId)) (lambda () (raw-value (tesl-dot/runtime t 'title)))) "task: test-proof")
    )
  )

  (test-case "processTask receives named entity"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_3 (thsl-src! "example/learn/lesson20-named-db-results.tesl" 189 (list) (lambda () (seedAndFetch "test-2"))))
    (define result (thsl-src! "example/learn/lesson20-named-db-results.tesl" 190 (list) (lambda () (fetchAndProcess "test-2"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson20-named-db-results.tesl" 191 (list (cons 'result result)) (lambda () result))) "task: test-2 status=open")
    )
  )

  (test-case "seedAndProcess chains fetch and process"
    (with-capabilities (dbRead dbWrite)
    (define result (thsl-src! "example/learn/lesson20-named-db-results.tesl" 195 (list) (lambda () (seedAndProcess "test-3"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson20-named-db-results.tesl" 196 (list (cons 'result result)) (lambda () result))) "task: test-3 status=open")
    )
  )

)
