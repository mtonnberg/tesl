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
  (only-in tesl/tesl/prelude Bool Int String List)
  (only-in tesl/tesl/list [List.map tesl_import_List_map] [List.length tesl_import_List_length])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/db dbRead dbWrite)
)


(provide )

;; Debugger: the lines whose statement is a READ-ONLY query.  The pause on
;; those happens AFTER the statement, so the SQL lens can show the exact
;; statement that ran (erased with the checkpoints in a release build).
(register-sql-read-lines! "tests/sql-clause-placement-tests.tesl" '(1 58 60 62 65 70 73 78 83 88 98 103 114 117 125 128 133 142 145))
(define-entity Thing
  #:source (make-hash)
  #:table clause_placement_things
  #:primary-key id
  [Id id : String]
  [OrgId orgId : String]
  [Name name : String]
  [Qty qty : Integer]
  [Archived archived : Boolean]
)

(define-database D
  #:backend memory
  #:entities Thing)

(define/pow
  (names [ts : (List Thing)])
  #:returns (List String)
  (thsl-src! "tests/sql-clause-placement-tests.tesl" 53 (list (cons 'ts *ts)) (lambda () (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-0 [t : Thing]) #:returns String (tesl-dot/runtime t 'name 'Thing)) tesl-lambda-0) *ts)))))

(define/pow
  (oneWhereOrder [org : String])
  #:capabilities [dbRead]
  #:returns (List Thing)
  (thsl-src! "tests/sql-clause-placement-tests.tesl" 58 (list (cons 'org *org)) (lambda () (select-many (from Thing) (where (==. (entity-field-ref Thing 'orgId) org)) (order-by (entity-field-ref Thing 'name) 'asc)))))

(define/pow
  (oneWhereOrderLimit [org : String])
  #:capabilities [dbRead]
  #:returns (List Thing)
  (thsl-src! "tests/sql-clause-placement-tests.tesl" 60 (list (cons 'org *org)) (lambda () (select-many (from Thing) (where (==. (entity-field-ref Thing 'orgId) org)) (order-by (entity-field-ref Thing 'name) 'asc) (limit 2)))))

(define/pow
  (andWhereOrder [org : String])
  #:capabilities [dbRead]
  #:returns (List Thing)
  (thsl-src! "tests/sql-clause-placement-tests.tesl" 62 (list (cons 'org *org)) (lambda () (select-many (from Thing) (where (==. (entity-field-ref Thing 'orgId) org)) (where (==. (entity-field-ref Thing 'archived) #f)) (order-by (entity-field-ref Thing 'name) 'asc)))))

(define/pow
  (andWhereLimitOffset [org : String])
  #:capabilities [dbRead]
  #:returns (List Thing)
  (thsl-src! "tests/sql-clause-placement-tests.tesl" 65 (list (cons 'org *org)) (lambda () (select-many (from Thing) (where (==. (entity-field-ref Thing 'orgId) org)) (where (==. (entity-field-ref Thing 'archived) #f)) (order-by (entity-field-ref Thing 'name) 'asc) (limit 2) (offset 1)))))

(define/pow
  (andIlikeOrderLimit [org : String] [pat : String])
  #:capabilities [dbRead]
  #:returns (List Thing)
  (thsl-src! "tests/sql-clause-placement-tests.tesl" 70 (list (cons 'org *org) (cons 'pat *pat)) (lambda () (select-many (from Thing) (where (==. (entity-field-ref Thing 'orgId) org)) (where (==. (entity-field-ref Thing 'archived) #f)) (where (ilike?. (entity-field-ref Thing 'name) pat)) (order-by (entity-field-ref Thing 'name) 'asc) (limit 5)))))

(define/pow
  (orWhereOrder [org : String])
  #:capabilities [dbRead]
  #:returns (List Thing)
  (thsl-src! "tests/sql-clause-placement-tests.tesl" 73 (list (cons 'org *org)) (lambda () (select-many (from Thing) (where (or. (==. (entity-field-ref Thing 'orgId) org) (==. (entity-field-ref Thing 'archived) #t))) (order-by (entity-field-ref Thing 'name) 'asc)))))

(define/pow
  (oneWhereOrderMulti [org : String])
  #:capabilities [dbRead]
  #:returns (List Thing)
  (thsl-src! "" 1 (list (cons 'org *org)) (lambda () (select-many (from Thing) (where (==. (entity-field-ref Thing 'orgId) org)) (order-by (entity-field-ref Thing 'name) 'asc)))))

(define/pow
  (andWhereOrderMulti [org : String])
  #:capabilities [dbRead]
  #:returns (List Thing)
  (thsl-src! "" 1 (list (cons 'org *org)) (lambda () (select-many (from Thing) (where (==. (entity-field-ref Thing 'orgId) org)) (where (==. (entity-field-ref Thing 'archived) #f)) (order-by (entity-field-ref Thing 'name) 'asc)))))

(define/pow
  (andWhereLimitOffsetMulti [org : String])
  #:capabilities [dbRead]
  #:returns (List Thing)
  (thsl-src! "" 1 (list (cons 'org *org)) (lambda () (select-many (from Thing) (where (==. (entity-field-ref Thing 'orgId) org)) (where (==. (entity-field-ref Thing 'archived) #f)) (order-by (entity-field-ref Thing 'name) 'asc) (limit 2) (offset 1)))))

(define/pow
  (orWhereOrderMulti [org : String])
  #:capabilities [dbRead]
  #:returns (List Thing)
  (thsl-src! "" 1 (list (cons 'org *org)) (lambda () (select-many (from Thing) (where (or. (==. (entity-field-ref Thing 'orgId) org) (==. (entity-field-ref Thing 'archived) #t))) (order-by (entity-field-ref Thing 'name) 'asc)))))

(define/pow
  (andIlikeOrderLimitMulti [org : String] [pat : String])
  #:capabilities [dbRead]
  #:returns (List Thing)
  (thsl-src! "" 1 (list (cons 'org *org) (cons 'pat *pat)) (lambda () (select-many (from Thing) (where (==. (entity-field-ref Thing 'orgId) org)) (where (==. (entity-field-ref Thing 'archived) #f)) (where (ilike?. (entity-field-ref Thing 'name) pat)) (order-by (entity-field-ref Thing 'name) 'asc) (limit 5)))))

(define/pow
  (countInline [org : String])
  #:capabilities [dbRead]
  #:returns Integer
  (thsl-src! "tests/sql-clause-placement-tests.tesl" 114 (list (cons 'org *org)) (lambda () (raw-value (tesl_import_List_length (select-many (from Thing) (where (==. (entity-field-ref Thing 'orgId) org)) (where (==. (entity-field-ref Thing 'archived) #f)) (order-by (entity-field-ref Thing 'name) 'asc) (limit 5)))))))

(define/pow
  (countInlineMultiLine [org : String])
  #:capabilities [dbRead]
  #:returns Integer
  (thsl-src! "tests/sql-clause-placement-tests.tesl" 117 (list (cons 'org *org)) (lambda () (raw-value (tesl_import_List_length (select-many (from Thing) (where (==. (entity-field-ref Thing 'orgId) org)) (where (==. (entity-field-ref Thing 'archived) #f)) (order-by (entity-field-ref Thing 'name) 'asc) (limit 5)))))))

(define/pow
  (oneRow [org : String])
  #:capabilities [dbRead]
  #:returns (Maybe Thing)
  (thsl-src! "tests/sql-clause-placement-tests.tesl" 125 (list (cons 'org *org)) (lambda () (let ([tesl_match (select-one (from Thing) (where (==. (entity-field-ref Thing 'orgId) org)) (where (==. (entity-field-ref Thing 'archived) #f)) (order-by (entity-field-ref Thing 'name) 'asc))]) (if tesl_match (Something tesl_match) Nothing)))))

(define/pow
  (countRows [org : String])
  #:capabilities [dbRead]
  #:returns Integer
  (thsl-src! "tests/sql-clause-placement-tests.tesl" 128 (list (cons 'org *org)) (lambda () (select-count (from Thing) (where (==. (entity-field-ref Thing 'orgId) org)) (where (==. (entity-field-ref Thing 'archived) #f))))))

(define/pow
  (maxQty [org : String])
  #:capabilities [dbRead]
  #:returns Integer
  (let ([biggest (thsl-src! "tests/sql-clause-placement-tests.tesl" 133 (list (cons 'org *org)) (lambda () (select-max (entity-field-ref Thing 'qty) (from Thing) (where (==. (entity-field-ref Thing 'orgId) org)) (where (==. (entity-field-ref Thing 'archived) #f)))) 'biggest)]) (thsl-src-control! "tests/sql-clause-placement-tests.tesl" 134 (list (cons 'biggest *biggest) (cons 'org *org)) (lambda () (let ([tesl-case-1 (raw-value biggest)]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "tests/sql-clause-placement-tests.tesl" 135 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([qty (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "tests/sql-clause-placement-tests.tesl" 136 (list (cons 'qty qty)) (lambda () *qty)))]))))))

(define/pow
  (aboveOneLine [org : String] [k : Integer])
  #:capabilities [dbRead]
  #:returns (List Thing)
  (thsl-src! "tests/sql-clause-placement-tests.tesl" 142 (list (cons 'org *org) (cons 'k *k)) (lambda () (select-many (from Thing) (where (==. (entity-field-ref Thing 'orgId) org)) (where (>=. (entity-field-ref Thing 'qty) k)) (order-by (entity-field-ref Thing 'name) 'asc)))))

(define/pow
  (aboveMultiLine [org : String] [k : Integer])
  #:capabilities [dbRead]
  #:returns (List Thing)
  (thsl-src! "" 1 (list (cons 'org *org) (cons 'k *k)) (lambda () (select-many (from Thing) (where (==. (entity-field-ref Thing 'orgId) org)) (where (>=. (entity-field-ref Thing 'qty) k)) (order-by (entity-field-ref Thing 'name) 'asc)))))

(define/pow
  (seed)
  #:capabilities [dbRead dbWrite]
  #:returns Thing
  (let ([_ (thsl-src! "tests/sql-clause-placement-tests.tesl" 150 (list) (lambda () (insert-one! Thing (tesl-hash 'id "a" 'orgId "o1" 'name "alpha" 'qty 3 'archived #f))))]) (let ([_ (thsl-src! "tests/sql-clause-placement-tests.tesl" 151 (list (cons '_ *_)) (lambda () (insert-one! Thing (tesl-hash 'id "b" 'orgId "o1" 'name "beta" 'qty 7 'archived #f))))]) (let ([_ (thsl-src! "tests/sql-clause-placement-tests.tesl" 152 (list (cons '_ *_) (cons '_ *_)) (lambda () (insert-one! Thing (tesl-hash 'id "c" 'orgId "o1" 'name "gamma" 'qty 5 'archived #t))))]) (let ([_ (thsl-src! "tests/sql-clause-placement-tests.tesl" 153 (list (cons '_ *_) (cons '_ *_) (cons '_ *_)) (lambda () (insert-one! Thing (tesl-hash 'id "d" 'orgId "o2" 'name "delta" 'qty 9 'archived #f))))]) (thsl-src! "tests/sql-clause-placement-tests.tesl" 154 (list (cons '_ *_) (cons '_ *_) (cons '_ *_) (cons '_ *_)) (lambda () (insert-one! Thing (tesl-hash 'id "e" 'orgId "o1" 'name "epsilon" 'qty 1 'archived #f)))))))))

(module+ test
  (require rackunit)
  (test-case "#77: one-line where + order runs and orders"
    (call-with-fresh-memory-db (list D) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-2 (thsl-src! "tests/sql-clause-placement-tests.tesl" 159 (list) (lambda () (seed))))
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 160 (list) (lambda () (names (oneWhereOrder "o1"))))) (list "alpha" "beta" "epsilon" "gamma"))
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 161 (list) (lambda () (names (oneWhereOrderLimit "o1"))))) (list "alpha" "beta"))
    )
    ))
  )

  (test-case "#77: one-line compound where + order/limit/offset runs"
    (call-with-fresh-memory-db (list D) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-3 (thsl-src! "tests/sql-clause-placement-tests.tesl" 165 (list) (lambda () (seed))))
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 166 (list) (lambda () (names (andWhereOrder "o1"))))) (list "alpha" "beta" "epsilon"))
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 167 (list) (lambda () (names (andWhereLimitOffset "o1"))))) (list "beta" "epsilon"))
    )
    ))
  )

  (test-case "#77: one-line where with && + ilike + order + limit runs"
    (call-with-fresh-memory-db (list D) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-4 (thsl-src! "tests/sql-clause-placement-tests.tesl" 173 (list) (lambda () (seed))))
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 174 (list) (lambda () (names (andIlikeOrderLimit "o1" "%a%"))))) (list "alpha" "beta"))
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 175 (list) (lambda () (names (andIlikeOrderLimit "o1" "%ETA%"))))) (list "beta"))
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 176 (list) (lambda () (names (andIlikeOrderLimit "o1" "%zzz%"))))) (list))
    )
    ))
  )

  (test-case "#77: || where + order runs in both spellings"
    (call-with-fresh-memory-db (list D) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-5 (thsl-src! "tests/sql-clause-placement-tests.tesl" 180 (list) (lambda () (seed))))
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 181 (list) (lambda () (names (orWhereOrder "o1"))))) (list "alpha" "beta" "epsilon" "gamma"))
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 182 (list) (lambda () (names (orWhereOrderMulti "o1"))))) (list "alpha" "beta" "epsilon" "gamma"))
    )
    ))
  )

  (test-case "#77: single-line and multi-line spellings agree"
    (call-with-fresh-memory-db (list D) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-6 (thsl-src! "tests/sql-clause-placement-tests.tesl" 187 (list) (lambda () (seed))))
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 188 (list) (lambda () (names (oneWhereOrder "o1"))))) (names (oneWhereOrderMulti "o1")))
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 189 (list) (lambda () (names (andWhereOrder "o1"))))) (names (andWhereOrderMulti "o1")))
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 190 (list) (lambda () (names (andWhereLimitOffset "o1"))))) (names (andWhereLimitOffsetMulti "o1")))
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 191 (list) (lambda () (names (andIlikeOrderLimit "o1" "%a%"))))) (names (andIlikeOrderLimitMulti "o1" "%a%")))
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 192 (list) (lambda () (countInline "o1")))) (countInlineMultiLine "o1"))
    )
    ))
  )

  (test-case "#77: a query in argument position, one line and many"
    (call-with-fresh-memory-db (list D) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-7 (thsl-src! "tests/sql-clause-placement-tests.tesl" 196 (list) (lambda () (seed))))
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 197 (list) (lambda () (countInline "o1")))) 3)
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 198 (list) (lambda () (countInlineMultiLine "o1")))) 3)
    )
    ))
  )

  (test-case "#77: selectOne/selectCount/selectMax take the same one-line spine"
    (call-with-fresh-memory-db (list D) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-8 (thsl-src! "tests/sql-clause-placement-tests.tesl" 202 (list) (lambda () (seed))))
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 203 (list) (lambda () (countRows "o1")))) 3)
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 204 (list) (lambda () (maxQty "o1")))) 7)
    (let ([*tesl-case-9 (raw-value 
      (oneRow "o1"))]) (cond
      [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Something))
        (let ([t (hash-ref (adt-value-fields *tesl-case-9) 'value)])
          (check-equal? (thsl-src! "tests/sql-clause-placement-tests.tesl" 206 (list) (lambda () (raw-value (tesl-dot/runtime t 'name)))) "alpha")
        )
      ]
      [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Nothing))
        (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 207 (list) (lambda () #f))) #t)
      ]
    ))
    )
    ))
  )

  (test-case "#77: property - spelling never changes the result"
    (call-with-fresh-memory-db (list D) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-10 (thsl-src! "tests/sql-clause-placement-tests.tesl" 215 (list) (lambda () (seed))))
    ; property: one-line == multi-line for any qty threshold
    (for ([tesl-prop-i (in-range 40)])
      (let ([k (- (tesl-prop-random 2000001) 1000000)])
        (when (and (tesl-gt? (raw-value k) 0) (tesl-lt? (raw-value k) 12)) (check-true (tesl-equal? (raw-value (names (aboveOneLine "o1" k))) (raw-value (names (aboveMultiLine "o1" k)))) "one-line == multi-line for any qty threshold"))
      ))
    )
    ))
  )

  (test-case "#77: a dynamic predicate value in a one-line query is read from scope"
    (call-with-fresh-memory-db (list D) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-11 (thsl-src! "tests/sql-clause-placement-tests.tesl" 222 (list) (lambda () (seed))))
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 223 (list) (lambda () (names (aboveOneLine "o1" 1))))) (list "alpha" "beta" "epsilon" "gamma"))
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 224 (list) (lambda () (names (aboveOneLine "o1" 5))))) (list "beta" "gamma"))
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 225 (list) (lambda () (names (aboveOneLine "o1" 8))))) (list))
    (check-equal? (raw-value (thsl-src! "tests/sql-clause-placement-tests.tesl" 226 (list) (lambda () (raw-value (tesl_import_List_length (raw-value (aboveOneLine "o1" 3))))))) 3)
    )
    ))
  )

)
