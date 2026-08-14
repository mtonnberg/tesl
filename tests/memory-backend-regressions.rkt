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
  (prefix-in __tmoney_ (only-in tesl/tesl/money tesl-currency-of tesl-money-rate-div tesl-money-rate-mul tesl-money-rate-scale))
  (only-in tesl/tesl/prelude Bool Int String List Unit)
  (only-in tesl/tesl/list [List.map tesl_import_List_map])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/time PosixMillis [Time.secondsToPosix tesl_import_Time_secondsToPosix] [Time.posixToSeconds tesl_import_Time_posixToSeconds])
  (only-in tesl/tesl/queue FromQueue queueRead queueWrite)
  (only-in tesl/tesl/money Money [Money.usd tesl_import_Money_usd] [Money.minorUnits tesl_import_Money_minorUnits])
  (only-in tesl/tesl/api-test statusOk JobResult JobOk JobFailed processNextJob pendingJobCount expectJobOk)
)


(provide )

;; Debugger: the lines whose statement is a READ-ONLY query.  The pause on
;; those happens AFTER the statement, so the SQL lens can show the exact
;; statement that ran (erased with the checkpoints in a release build).
(register-sql-read-lines! "tests/memory-backend-regressions.tesl" '(92 95 98 101 104 110 111 118 119 126 127 134 135 143 182))
(define-newtype Code Integer)

(define-entity P
  #:source (make-hash)
  #:table mem_reg_ps
  #:primary-key id
  [Id id : String]
  [Qty qty : Integer]
  [Name name : String]
  [At at : PosixMillis]
  [Code code : Code]
  [Done done : Boolean]
)

(define-entity L
  #:source (make-hash)
  #:table mem_reg_lines
  #:primary-key id
  [Id id : String]
  [Cat cat : String]
  [Price price : Money]
)

(define-entity Empty
  #:source (make-hash)
  #:table mem_reg_empty
  #:primary-key id
  [Id id : String]
  [Qty qty : Integer]
)

(define-database D
  #:backend memory
  #:entities P L Empty)

(define/pow
  (qtys [ps : (List P)])
  #:returns (List Integer)
  (thsl-src! "tests/memory-backend-regressions.tesl" 86 (list (cons 'ps *ps)) (lambda () (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-0 [p : P]) #:returns Integer (tesl-dot/runtime p 'qty 'P)) tesl-lambda-0) *ps)))))

(define/pow
  (names [ps : (List P)])
  #:returns (List String)
  (thsl-src! "tests/memory-backend-regressions.tesl" 89 (list (cons 'ps *ps)) (lambda () (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-1 [p : P]) #:returns String (tesl-dot/runtime p 'name 'P)) tesl-lambda-1) *ps)))))

(define/pow
  (orderedAsc)
  #:capabilities [dbRead]
  #:returns (List P)
  (thsl-src! "tests/memory-backend-regressions.tesl" 92 (list) (lambda () (call-with-database D (lambda () (select-many (from P) (order-by (entity-field-ref P 'qty) 'asc)))))))

(define/pow
  (orderedDesc)
  #:capabilities [dbRead]
  #:returns (List P)
  (thsl-src! "tests/memory-backend-regressions.tesl" 95 (list) (lambda () (call-with-database D (lambda () (select-many (from P) (order-by (entity-field-ref P 'qty) 'desc)))))))

(define/pow
  (orderedByName)
  #:capabilities [dbRead]
  #:returns (List P)
  (thsl-src! "tests/memory-backend-regressions.tesl" 98 (list) (lambda () (call-with-database D (lambda () (select-many (from P) (order-by (entity-field-ref P 'name) 'asc)))))))

(define/pow
  (orderedByDone)
  #:capabilities [dbRead]
  #:returns (List P)
  (thsl-src! "tests/memory-backend-regressions.tesl" 101 (list) (lambda () (call-with-database D (lambda () (select-many (from P) (order-by (entity-field-ref P 'done) 'asc)))))))

(define/pow
  (orderedByDoneDesc)
  #:capabilities [dbRead]
  #:returns (List P)
  (thsl-src! "tests/memory-backend-regressions.tesl" 104 (list) (lambda () (call-with-database D (lambda () (select-many (from P) (order-by (entity-field-ref P 'done) 'desc)))))))

(define/pow
  (newest)
  #:capabilities [dbRead]
  #:returns PosixMillis
  (thsl-src! "tests/memory-backend-regressions.tesl" 110 (list) (lambda () (call-with-database D (lambda () (let ([latest (select-max (entity-field-ref P 'at) (from P))]) (let ([tesl-case-2 (raw-value latest)]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "tests/memory-backend-regressions.tesl" 113 (list) (lambda () (raw-value (raw-value (tesl_import_Time_secondsToPosix 0)))))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([at (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "tests/memory-backend-regressions.tesl" 114 (list (cons 'at at)) (lambda () *at)))]))))))))

(define/pow
  (oldest)
  #:capabilities [dbRead]
  #:returns PosixMillis
  (thsl-src! "tests/memory-backend-regressions.tesl" 118 (list) (lambda () (call-with-database D (lambda () (let ([earliest (select-min (entity-field-ref P 'at) (from P))]) (let ([tesl-case-3 (raw-value earliest)]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "tests/memory-backend-regressions.tesl" 121 (list) (lambda () (raw-value (raw-value (tesl_import_Time_secondsToPosix 0)))))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([at (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "tests/memory-backend-regressions.tesl" 122 (list (cons 'at at)) (lambda () *at)))]))))))))

(define/pow
  (maxQty)
  #:capabilities [dbRead]
  #:returns Integer
  (thsl-src! "tests/memory-backend-regressions.tesl" 126 (list) (lambda () (call-with-database D (lambda () (let ([biggest (select-max (entity-field-ref P 'qty) (from P))]) (let ([tesl-case-4 (raw-value biggest)]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Nothing)) (thsl-src! "tests/memory-backend-regressions.tesl" 129 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Something)) (let ([qty (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (thsl-src! "tests/memory-backend-regressions.tesl" 130 (list (cons 'qty qty)) (lambda () *qty)))]))))))))

(define/pow
  (minCode)
  #:capabilities [dbRead]
  #:returns Code
  (thsl-src! "tests/memory-backend-regressions.tesl" 134 (list) (lambda () (call-with-database D (lambda () (let ([smallest (select-min (entity-field-ref P 'code) (from P))]) (let ([tesl-case-5 (raw-value smallest)]) (cond [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Nothing)) (thsl-src! "tests/memory-backend-regressions.tesl" 137 (list) (lambda () (raw-value (raw-value (Code 0)))))] [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Something)) (let ([code (hash-ref (adt-value-fields *tesl-case-5) 'value)]) (thsl-src! "tests/memory-backend-regressions.tesl" 138 (list (cons 'code code)) (lambda () *code)))]))))))))

(define/pow
  (maxOfEmpty)
  #:capabilities [dbRead]
  #:returns (Maybe Integer)
  (thsl-src! "tests/memory-backend-regressions.tesl" 143 (list) (lambda () (call-with-database D (lambda () (raw-value (select-max (entity-field-ref Empty 'qty) (from Empty))))))))

(define/pow
  (sumIn [c : String])
  #:capabilities [dbRead]
  #:returns Money
  (thsl-src! "tests/memory-backend-regressions.tesl" 182 (list (cons 'c *c)) (lambda () (call-with-database D (lambda () (select-sum (entity-field-ref L 'price) (from L) (where (==. (entity-field-ref L 'cat) c))))))))

(define-database QDb
  #:backend memory
  #:schema memregfifo
  #:entities )

(define-record SeqJob
  [tag : String]
)

(define-queue RegQueue
  #:database QDb
  #:job-types (SeqJob)
  #:max-attempts 2
  #:backoff fixed
  #:initial-delay 1)

(define/pow
  (handleSeq [job : SeqJob ::: (FromQueue (Id == jobId) job)])
  #:capabilities [queueRead]
  #:returns SeqJob
  (thsl-src! "tests/memory-backend-regressions.tesl" 234 (list (cons 'job *job)) (lambda () *job)))

(define-record TriggerRequest
  [tag : String]
)

(define (tesl-codec-encode-TriggerRequest _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'tag (tesl-encode-prim-string (raw-value (hash-ref _fields 'tag)))
  ))
(define (tesl-codec-decode-TriggerRequest-0 _j)
  (define _f_tag (tesl-decode-prim-field _j "tag" tesl-decode-prim-string))
  (record-value 'TriggerRequest (tesl-hash 'tag _f_tag)))
(register-type-codec! 'TriggerRequest tesl-codec-encode-TriggerRequest (list tesl-codec-decode-TriggerRequest-0))

(define-handler
  (send [req : TriggerRequest])
  #:capabilities [queueWrite]
  #:returns String
  (let ([_ (thsl-src! "tests/memory-backend-regressions.tesl" 253 (list (cons 'req *req)) (lambda () (enqueue! RegQueue (SeqJob #:tag (tesl-dot/runtime req 'tag 'TriggerRequest)))))]) (thsl-src! "tests/memory-backend-regressions.tesl" 254 (list (cons 'req *req)) (lambda () "queued"))))

(define RegServer-sse-routes '())
(define-api RegApi
  [send :
    "send"
    :> (ReqBody JSON [req : TriggerRequest])
    :> (Post JSON String)
    ]
)

(define-server RegServer
  #:api RegApi
  [send send]
)

(module+ test
  (require rackunit)
  (test-case "in-memory queue dequeues FIFO"
    (call-with-fresh-memory-db (list D QDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (queueRead queueWrite)
              (define r1 (thsl-src! "tests/memory-backend-regressions.tesl" 267 (list) (lambda () (dispatch-api-test-request RegServer 'post (list "send") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "tag") "one") #:capabilities (list queueRead queueWrite)))))
              (check-true (raw-value (thsl-src! "tests/memory-backend-regressions.tesl" 268 (list (cons 'r1 r1)) (lambda () (statusOk (raw-value (api-test-field-access-ref r1 'status)))))))
              (define r2 (thsl-src! "tests/memory-backend-regressions.tesl" 269 (list (cons 'r1 r1)) (lambda () (dispatch-api-test-request RegServer 'post (list "send") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "tag") "two") #:capabilities (list queueRead queueWrite)))))
              (check-true (raw-value (thsl-src! "tests/memory-backend-regressions.tesl" 270 (list (cons 'r2 r2) (cons 'r1 r1)) (lambda () (statusOk (raw-value (api-test-field-access-ref r2 'status)))))))
              (define r3 (thsl-src! "tests/memory-backend-regressions.tesl" 271 (list (cons 'r2 r2) (cons 'r1 r1)) (lambda () (dispatch-api-test-request RegServer 'post (list "send") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "tag") "three") #:capabilities (list queueRead queueWrite)))))
              (check-true (raw-value (thsl-src! "tests/memory-backend-regressions.tesl" 272 (list (cons 'r3 r3) (cons 'r2 r2) (cons 'r1 r1)) (lambda () (statusOk (raw-value (api-test-field-access-ref r3 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/memory-backend-regressions.tesl" 274 (list (cons 'r3 r3) (cons 'r2 r2) (cons 'r1 r1)) (lambda () (pendingJobCount RegQueue)))) 3)
              (define resA (thsl-src! "tests/memory-backend-regressions.tesl" 276 (list (cons 'r3 r3) (cons 'r2 r2) (cons 'r1 r1)) (lambda () (processNextJob RegQueue))))
              (define jobA (thsl-src! "tests/memory-backend-regressions.tesl" 277 (list (cons 'resA resA) (cons 'r3 r3) (cons 'r2 r2) (cons 'r1 r1)) (lambda () (expectJobOk (raw-value resA)))))
              (check-equal? (raw-value (thsl-src! "tests/memory-backend-regressions.tesl" 278 (list (cons 'jobA jobA) (cons 'resA resA) (cons 'r3 r3) (cons 'r2 r2) (cons 'r1 r1)) (lambda () (api-test-field-access-ref jobA 'tag)))) "one")
              (define resB (thsl-src! "tests/memory-backend-regressions.tesl" 280 (list (cons 'jobA jobA) (cons 'resA resA) (cons 'r3 r3) (cons 'r2 r2) (cons 'r1 r1)) (lambda () (processNextJob RegQueue))))
              (define jobB (thsl-src! "tests/memory-backend-regressions.tesl" 281 (list (cons 'resB resB) (cons 'jobA jobA) (cons 'resA resA) (cons 'r3 r3) (cons 'r2 r2) (cons 'r1 r1)) (lambda () (expectJobOk (raw-value resB)))))
              (check-equal? (raw-value (thsl-src! "tests/memory-backend-regressions.tesl" 282 (list (cons 'jobB jobB) (cons 'resB resB) (cons 'jobA jobA) (cons 'resA resA) (cons 'r3 r3) (cons 'r2 r2) (cons 'r1 r1)) (lambda () (api-test-field-access-ref jobB 'tag)))) "two")
              (define resC (thsl-src! "tests/memory-backend-regressions.tesl" 284 (list (cons 'jobB jobB) (cons 'resB resB) (cons 'jobA jobA) (cons 'resA resA) (cons 'r3 r3) (cons 'r2 r2) (cons 'r1 r1)) (lambda () (processNextJob RegQueue))))
              (define jobC (thsl-src! "tests/memory-backend-regressions.tesl" 285 (list (cons 'resC resC) (cons 'jobB jobB) (cons 'resB resB) (cons 'jobA jobA) (cons 'resA resA) (cons 'r3 r3) (cons 'r2 r2) (cons 'r1 r1)) (lambda () (expectJobOk (raw-value resC)))))
              (check-equal? (raw-value (thsl-src! "tests/memory-backend-regressions.tesl" 286 (list (cons 'jobC jobC) (cons 'resC resC) (cons 'jobB jobB) (cons 'resB resB) (cons 'jobA jobA) (cons 'resA resA) (cons 'r3 r3) (cons 'r2 r2) (cons 'r1 r1)) (lambda () (api-test-field-access-ref jobC 'tag)))) "three")
            )
          ))
      ))
  )
)

(define RegQueueWorkers
  (list (cons RegQueue handleSeq)))
(register-api-test-workers! (list (list RegQueue 'SeqJob handleSeq)))

(module+ test
  (require rackunit)
  (test-case "order by asc/desc is applied on the Memory backend"
    (call-with-fresh-memory-db (list D QDb) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-6 (thsl-src! "tests/memory-backend-regressions.tesl" 147 (list) (lambda () (insert-one! P (tesl-hash 'id "a" 'qty 3 'name "cherry" 'at (raw-value (tesl_import_Time_secondsToPosix 300)) 'code (raw-value (Code 7)) 'done #t)))))
    (define tesl-ignored-7 (thsl-src! "tests/memory-backend-regressions.tesl" 148 (list) (lambda () (insert-one! P (tesl-hash 'id "b" 'qty 1 'name "apple" 'at (raw-value (tesl_import_Time_secondsToPosix 100)) 'code (raw-value (Code 9)) 'done #f)))))
    (define tesl-ignored-8 (thsl-src! "tests/memory-backend-regressions.tesl" 149 (list) (lambda () (insert-one! P (tesl-hash 'id "c" 'qty 2 'name "banana" 'at (raw-value (tesl_import_Time_secondsToPosix 200)) 'code (raw-value (Code 3)) 'done #t)))))
    (check-equal? (raw-value (thsl-src! "tests/memory-backend-regressions.tesl" 151 (list) (lambda () (qtys (orderedAsc))))) (list 1 2 3))
    (check-equal? (raw-value (thsl-src! "tests/memory-backend-regressions.tesl" 152 (list) (lambda () (qtys (orderedDesc))))) (list 3 2 1))
    )
    ))
  )

  (test-case "order by on a Bool column sorts false before true (PG parity)"
    (call-with-fresh-memory-db (list D QDb) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-9 (thsl-src! "tests/memory-backend-regressions.tesl" 162 (list) (lambda () (insert-one! P (tesl-hash 'id "b" 'qty 1 'name "apple" 'at (raw-value (tesl_import_Time_secondsToPosix 100)) 'code (raw-value (Code 9)) 'done #f)))))
    (define tesl-ignored-10 (thsl-src! "tests/memory-backend-regressions.tesl" 163 (list) (lambda () (insert-one! P (tesl-hash 'id "a" 'qty 3 'name "cherry" 'at (raw-value (tesl_import_Time_secondsToPosix 300)) 'code (raw-value (Code 7)) 'done #t)))))
    (check-equal? (raw-value (thsl-src! "tests/memory-backend-regressions.tesl" 165 (list) (lambda () (names (orderedByDone))))) (list "apple" "cherry"))
    (check-equal? (raw-value (thsl-src! "tests/memory-backend-regressions.tesl" 166 (list) (lambda () (names (orderedByDoneDesc))))) (list "cherry" "apple"))
    )
    ))
  )

  (test-case "order by on a String column sorts lexicographically"
    (call-with-fresh-memory-db (list D QDb) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-11 (thsl-src! "tests/memory-backend-regressions.tesl" 171 (list) (lambda () (insert-one! P (tesl-hash 'id "a" 'qty 3 'name "cherry" 'at (raw-value (tesl_import_Time_secondsToPosix 300)) 'code (raw-value (Code 7)) 'done #t)))))
    (define tesl-ignored-12 (thsl-src! "tests/memory-backend-regressions.tesl" 172 (list) (lambda () (insert-one! P (tesl-hash 'id "b" 'qty 1 'name "apple" 'at (raw-value (tesl_import_Time_secondsToPosix 100)) 'code (raw-value (Code 9)) 'done #f)))))
    (define tesl-ignored-13 (thsl-src! "tests/memory-backend-regressions.tesl" 173 (list) (lambda () (insert-one! P (tesl-hash 'id "c" 'qty 2 'name "banana" 'at (raw-value (tesl_import_Time_secondsToPosix 200)) 'code (raw-value (Code 3)) 'done #t)))))
    (check-equal? (raw-value (thsl-src! "tests/memory-backend-regressions.tesl" 175 (list) (lambda () (names (orderedByName))))) (list "apple" "banana" "cherry"))
    )
    ))
  )

  (test-case "money sum with a where-clause"
    (call-with-fresh-memory-db (list D QDb) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-14 (thsl-src! "tests/memory-backend-regressions.tesl" 186 (list) (lambda () (insert-one! L (tesl-hash 'id "l1" 'cat "x" 'price (raw-value (tesl_import_Money_usd 100)))))))
    (define tesl-ignored-15 (thsl-src! "tests/memory-backend-regressions.tesl" 187 (list) (lambda () (insert-one! L (tesl-hash 'id "l2" 'cat "x" 'price (raw-value (tesl_import_Money_usd 250)))))))
    (define tesl-ignored-16 (thsl-src! "tests/memory-backend-regressions.tesl" 188 (list) (lambda () (insert-one! L (tesl-hash 'id "l3" 'cat "y" 'price (raw-value (tesl_import_Money_usd 999)))))))
    (check-equal? (raw-value (thsl-src! "tests/memory-backend-regressions.tesl" 190 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (sumIn "x"))))))) 350)
    (check-equal? (raw-value (thsl-src! "tests/memory-backend-regressions.tesl" 191 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (sumIn "y"))))))) 999)
    )
    ))
  )

  (test-case "selectMax/selectMin over newtype columns on the Memory backend"
    (call-with-fresh-memory-db (list D QDb) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-17 (thsl-src! "tests/memory-backend-regressions.tesl" 196 (list) (lambda () (insert-one! P (tesl-hash 'id "a" 'qty 3 'name "cherry" 'at (raw-value (tesl_import_Time_secondsToPosix 300)) 'code (raw-value (Code 7)) 'done #t)))))
    (define tesl-ignored-18 (thsl-src! "tests/memory-backend-regressions.tesl" 197 (list) (lambda () (insert-one! P (tesl-hash 'id "b" 'qty 1 'name "apple" 'at (raw-value (tesl_import_Time_secondsToPosix 100)) 'code (raw-value (Code 9)) 'done #f)))))
    (define tesl-ignored-19 (thsl-src! "tests/memory-backend-regressions.tesl" 198 (list) (lambda () (insert-one! P (tesl-hash 'id "c" 'qty 2 'name "banana" 'at (raw-value (tesl_import_Time_secondsToPosix 200)) 'code (raw-value (Code 3)) 'done #t)))))
    (check-equal? (raw-value (thsl-src! "tests/memory-backend-regressions.tesl" 200 (list) (lambda () (raw-value (tesl_import_Time_posixToSeconds (raw-value (newest))))))) 300)
    (check-equal? (raw-value (thsl-src! "tests/memory-backend-regressions.tesl" 201 (list) (lambda () (raw-value (tesl_import_Time_posixToSeconds (raw-value (oldest))))))) 100)
    (check-equal? (raw-value (thsl-src! "tests/memory-backend-regressions.tesl" 202 (list) (lambda () (minCode)))) (raw-value (Code 3)))
    (check-equal? (raw-value (thsl-src! "tests/memory-backend-regressions.tesl" 203 (list) (lambda () (maxQty)))) 3)
    )
    ))
  )

  (test-case "selectMax over no matching row is Nothing"
    (call-with-fresh-memory-db (list D QDb) (lambda ()
    (with-capabilities (dbRead)
    (check-equal? (raw-value (thsl-src! "tests/memory-backend-regressions.tesl" 207 (list) (lambda () (maxOfEmpty)))) Nothing)
    )
    ))
  )

)
