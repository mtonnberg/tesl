#lang racket

(require
  tesl/dsl/capability
  tesl/dsl/types
  tesl/dsl/check
  tesl/dsl/otel
  tesl/dsl/sql
  tesl/dsl/web
  tesl/dsl/test-support
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
  (let ([r (let ([tesl_match (select-one (from Task) (where (==. (entity-field-ref Task 'id) id)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_0 (raw-value r)]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) (reject "task not found" #:http-code 404)] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (let ([t (hash-ref (adt-value-fields *tesl_case_0) 'value)]) t)]))))

(define/pow
  (seedAndFetch [id : String])
  #:capabilities [dbRead dbWrite]
  #:returns (? Task _entity ::: (FromDb (Id == id) _entity))
  (let ([_ (insert-one! Task (hash 'id id 'title (format "task: ~a" (tesl-display-val *id)) 'status "open"))]) (let ([r (let ([tesl_match (select-one (from Task) (where (==. (entity-field-ref Task 'id) id)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_1 (raw-value r)]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Nothing)) (reject "missing after insert" #:http-code 500)] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Something)) (let ([t (hash-ref (adt-value-fields *tesl_case_1) 'value)]) t)])))))

(define/pow
  (processTask [t : Task ::: (FromDb (Id == id) t)] [id : String])
  #:returns String
  (format "task: ~a status=~a" (tesl-display-val *id) (tesl-display-val (raw-value t.status))))

(define/pow
  (fetchAndProcess [id : String])
  #:capabilities [dbRead]
  #:returns String
  (let ([t (fetchTask id)]) (raw-value (processTask t id))))

(define/pow
  (seedAndProcess [id : String])
  #:capabilities [dbRead dbWrite]
  #:returns String
  (let ([t (seedAndFetch id)]) (raw-value (processTask t id))))

(define/pow
  (existentialFetch [prefix : String])
  #:capabilities [dbRead dbWrite]
  #:returns (Exists [taskId : String] (? Task _entity ::: (FromDb (Id == taskId) _entity)))
  (let ([taskId (format "~a-auto" (tesl-display-val *prefix))]) (let ([_ (insert-one! Task (hash 'id taskId 'title "auto task" 'status "new"))]) (let ([r (let ([tesl_match (select-one (from Task) (where (==. (entity-field-ref Task 'id) taskId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_2 (raw-value r)]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Nothing)) (raw-value (reject "missing after insert" #:http-code 500))] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Something)) (let ([t (hash-ref (adt-value-fields *tesl_case_2) 'value)]) (raw-value (pack ([taskId]) t)))]))))))

(module+ test
  (require rackunit)
  (test-case "named db result preserves proof"
    (with-capabilities (dbRead dbWrite)
    (define t (seedAndFetch "test-1"))
    (check-equal? (raw-value (tesl-dot/runtime t 'title)) "task: test-1")
    (check-equal? (raw-value (tesl-dot/runtime t 'status)) "open")
    )
  )

  (test-case "proof annotation verifies entity came from db"
    (with-capabilities (dbRead dbWrite)
    (define queryId "test-proof")
    (define t (seedAndFetch queryId))
    (check-equal? (raw-value (tesl-dot/runtime t 'title)) "task: test-proof")
    )
  )

  (test-case "processTask receives named entity"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_3 (seedAndFetch "test-2"))
    (define result (fetchAndProcess "test-2"))
    (check-equal? (raw-value result) "task: test-2 status=open")
    )
  )

  (test-case "seedAndProcess chains fetch and process"
    (with-capabilities (dbRead dbWrite)
    (define result (seedAndProcess "test-3"))
    (check-equal? (raw-value result) "task: test-3 status=open")
    )
  )

)
