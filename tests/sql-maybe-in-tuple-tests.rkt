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
  (only-in tesl/tesl/prelude Bool Int List String)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/tuple Tuple2 Tuple3)
  (only-in tesl/tesl/list [List.length tesl_import_List_length])
)


(provide )

;; Debugger: the lines whose statement is a READ-ONLY query.  The pause on
;; those happens AFTER the statement, so the SQL lens can show the exact
;; statement that ran (erased with the checkpoints in a release build).
(register-sql-read-lines! "tests/sql-maybe-in-tuple-tests.tesl" '(43 50 75 81 97 112 146 168))
(define-entity Inst
  #:source (make-hash)
  #:table inst_tuple69
  #:primary-key id
  [Id id : String]
  [Active active : Boolean]
)

(define-adt Box
  [BoxOf [inner : (Maybe Inst)]]
  [BoxEmpty]
)

(define-record TokenLookup
  [installation : (Maybe Inst)]
  [secretPart : String]
)

(define/pow
  (probeBaselineSelectOne [id : String])
  #:capabilities [dbRead]
  #:returns Boolean
  (let ([maybeInst (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 43 (list (cons 'id *id)) (lambda () (let ([tesl_match (select-one (from Inst) (where (==. (entity-field-ref Inst 'id) id)))]) (if tesl_match (Something tesl_match) Nothing))) 'maybeInst)]) (thsl-src-control! "tests/sql-maybe-in-tuple-tests.tesl" 44 (list (cons 'maybeInst *maybeInst) (cons 'id *id)) (lambda () (let ([tesl-case-0 (raw-value maybeInst)]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([inst (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 45 (list (cons 'inst inst)) (lambda () (raw-value #t))))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 46 (list) (lambda () (raw-value #f)))]))))))

(define/pow
  (tuple2NestedMaybe [id : String])
  #:capabilities [dbRead]
  #:returns (Maybe (Tuple2 (Maybe Inst) String))
  (let ([maybeInst (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 50 (list (cons 'id *id)) (lambda () (let ([tesl_match (select-one (from Inst) (where (==. (entity-field-ref Inst 'id) id)))]) (if tesl_match (Something tesl_match) Nothing))) 'maybeInst)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 51 (list (cons 'maybeInst *maybeInst) (cons 'id *id)) (lambda () (raw-value (Something (Tuple2 (raw-value maybeInst) "secret")))))))

(define/pow
  (innerIsSomething [pair : (Tuple2 (Maybe Inst) String)])
  #:returns Boolean
  (thsl-src-control! "tests/sql-maybe-in-tuple-tests.tesl" 54 (list (cons 'pair *pair)) (lambda () (let ([tesl-case-1 *pair]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Tuple2)) (let ([maybeInstVal (hash-ref (adt-value-fields *tesl-case-1) 'first)]) (let ([secretPart (hash-ref (adt-value-fields *tesl-case-1) 'second)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 56 (list (cons 'maybeInstVal maybeInstVal) (cons 'secretPart secretPart)) (lambda () (let ([tesl-case-2 (raw-value maybeInstVal)]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([inst (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 57 (list (cons 'inst inst)) (lambda () (raw-value #t))))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 58 (list) (lambda () (raw-value #f)))]))))))])))))

(define/pow
  (outerUnwraps [m : (Maybe (Tuple2 (Maybe Inst) String))])
  #:returns Boolean
  (thsl-src-control! "tests/sql-maybe-in-tuple-tests.tesl" 61 (list (cons 'm *m)) (lambda () (let ([tesl-case-3 *m]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 62 (list) (lambda () (raw-value #f)))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([pair (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 63 (list (cons 'pair pair)) (lambda () (raw-value (innerIsSomething *pair)))))])))))

(define/pow
  (secondSlotSurvives [m : (Maybe (Tuple2 (Maybe Inst) String))])
  #:returns String
  (thsl-src-control! "tests/sql-maybe-in-tuple-tests.tesl" 66 (list (cons 'm *m)) (lambda () (let ([tesl-case-4 *m]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Nothing)) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 67 (list) (lambda () (raw-value "none")))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Something)) (let ([pair (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 69 (list (cons 'pair pair)) (lambda () (let ([tesl-case-5 (raw-value pair)]) (cond [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Tuple2)) (let ([maybeInstVal (hash-ref (adt-value-fields *tesl-case-5) 'first)]) (let ([secretPart (hash-ref (adt-value-fields *tesl-case-5) 'second)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 70 (list (cons 'maybeInstVal maybeInstVal) (cons 'secretPart secretPart)) (lambda () *secretPart))))])))))])))))

(define/pow
  (bareTuple2 [id : String])
  #:capabilities [dbRead]
  #:returns (Tuple2 (Maybe Inst) String)
  (let ([maybeInst (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 75 (list (cons 'id *id)) (lambda () (let ([tesl_match (select-one (from Inst) (where (==. (entity-field-ref Inst 'id) id)))]) (if tesl_match (Something tesl_match) Nothing))) 'maybeInst)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 76 (list (cons 'maybeInst *maybeInst) (cons 'id *id)) (lambda () (raw-value (Tuple2 (raw-value maybeInst) "secret"))))))

(define/pow
  (maybeInSecondSlot [id : String])
  #:capabilities [dbRead]
  #:returns (Maybe (Tuple2 String (Maybe Inst)))
  (let ([maybeInst (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 81 (list (cons 'id *id)) (lambda () (let ([tesl_match (select-one (from Inst) (where (==. (entity-field-ref Inst 'id) id)))]) (if tesl_match (Something tesl_match) Nothing))) 'maybeInst)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 82 (list (cons 'maybeInst *maybeInst) (cons 'id *id)) (lambda () (raw-value (Something (Tuple2 "secret" (raw-value maybeInst))))))))

(define/pow
  (secondSlotIsSomething [m : (Maybe (Tuple2 String (Maybe Inst)))])
  #:returns Boolean
  (thsl-src-control! "tests/sql-maybe-in-tuple-tests.tesl" 85 (list (cons 'm *m)) (lambda () (let ([tesl-case-6 *m]) (cond [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Nothing)) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 86 (list) (lambda () (raw-value #f)))] [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Something)) (let ([pair (hash-ref (adt-value-fields *tesl-case-6) 'value)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 88 (list (cons 'pair pair)) (lambda () (let ([tesl-case-7 (raw-value pair)]) (cond [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Tuple2)) (let ([secretPart (hash-ref (adt-value-fields *tesl-case-7) 'first)]) (let ([maybeInstVal (hash-ref (adt-value-fields *tesl-case-7) 'second)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 90 (list (cons 'secretPart secretPart) (cons 'maybeInstVal maybeInstVal)) (lambda () (let ([tesl-case-8 (raw-value maybeInstVal)]) (cond [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Something)) (let ([inst (hash-ref (adt-value-fields *tesl-case-8) 'value)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 91 (list (cons 'inst inst)) (lambda () (raw-value #t))))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Nothing)) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 92 (list) (lambda () (raw-value #f)))]))))))])))))])))))

(define/pow
  (tuple3NestedMaybe [id : String])
  #:capabilities [dbRead]
  #:returns (Maybe (Tuple3 (Maybe Inst) String Integer))
  (let ([maybeInst (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 97 (list (cons 'id *id)) (lambda () (let ([tesl_match (select-one (from Inst) (where (==. (entity-field-ref Inst 'id) id)))]) (if tesl_match (Something tesl_match) Nothing))) 'maybeInst)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 98 (list (cons 'maybeInst *maybeInst) (cons 'id *id)) (lambda () (raw-value (Something (Tuple3 (raw-value maybeInst) "secret" 7)))))))

(define/pow
  (tuple3InnerIsSomething [m : (Maybe (Tuple3 (Maybe Inst) String Integer))])
  #:returns Boolean
  (thsl-src-control! "tests/sql-maybe-in-tuple-tests.tesl" 101 (list (cons 'm *m)) (lambda () (let ([tesl-case-9 *m]) (cond [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Nothing)) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 102 (list) (lambda () (raw-value #f)))] [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Something)) (let ([triple (hash-ref (adt-value-fields *tesl-case-9) 'value)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 104 (list (cons 'triple triple)) (lambda () (let ([tesl-case-10 (raw-value triple)]) (cond [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Tuple3)) (let ([maybeInstVal (hash-ref (adt-value-fields *tesl-case-10) 'first)]) (let ([secretPart (hash-ref (adt-value-fields *tesl-case-10) 'second)]) (let ([n (hash-ref (adt-value-fields *tesl-case-10) 'third)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 106 (list (cons 'maybeInstVal maybeInstVal) (cons 'secretPart secretPart) (cons 'n n)) (lambda () (let ([tesl-case-11 (raw-value maybeInstVal)]) (cond [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'Something)) (let ([inst (hash-ref (adt-value-fields *tesl-case-11) 'value)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 107 (list (cons 'inst inst)) (lambda () (raw-value #t))))] [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'Nothing)) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 108 (list) (lambda () (raw-value #f)))])))))))])))))])))))

(define/pow
  (recordNestedMaybe [id : String])
  #:capabilities [dbRead]
  #:returns (Maybe TokenLookup)
  (let ([maybeInst (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 112 (list (cons 'id *id)) (lambda () (let ([tesl_match (select-one (from Inst) (where (==. (entity-field-ref Inst 'id) id)))]) (if tesl_match (Something tesl_match) Nothing))) 'maybeInst)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 113 (list (cons 'maybeInst *maybeInst) (cons 'id *id)) (lambda () (raw-value (Something (TokenLookup #:installation *maybeInst #:secretPart "secret")))))))

(define/pow
  (recordInnerIsSomething [m : (Maybe TokenLookup)])
  #:returns Boolean
  (thsl-src-control! "tests/sql-maybe-in-tuple-tests.tesl" 116 (list (cons 'm *m)) (lambda () (let ([tesl-case-12 *m]) (cond [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Nothing)) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 117 (list) (lambda () (raw-value #f)))] [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Something)) (let ([lookup (hash-ref (adt-value-fields *tesl-case-12) 'value)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 119 (list (cons 'lookup lookup)) (lambda () (let ([tesl-case-13 (tesl-dot/runtime lookup 'installation 'TokenLookup)]) (cond [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Something)) (let ([inst (hash-ref (adt-value-fields *tesl-case-13) 'value)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 120 (list (cons 'inst inst)) (lambda () (raw-value #t))))] [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Nothing)) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 121 (list) (lambda () (raw-value #f)))])))))])))))

(define/pow
  (handBuiltMaybe [present : Boolean])
  #:returns (Maybe String)
  (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 126 (list (cons 'present *present)) (lambda () (if *present (raw-value (raw-value (Something "hi"))) (raw-value Nothing)))))

(define/pow
  (handBuiltWrapped [present : Boolean])
  #:returns (Maybe (Tuple2 (Maybe String) String))
  (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 132 (list (cons 'present *present)) (lambda () (raw-value (Something (Tuple2 (handBuiltMaybe present) "secret"))))))

(define/pow
  (handBuiltInnerIsSomething [m : (Maybe (Tuple2 (Maybe String) String))])
  #:returns Boolean
  (thsl-src-control! "tests/sql-maybe-in-tuple-tests.tesl" 135 (list (cons 'm *m)) (lambda () (let ([tesl-case-14 *m]) (cond [(and (adt-value? *tesl-case-14) (eq? (adt-value-variant *tesl-case-14) 'Nothing)) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 136 (list) (lambda () (raw-value #f)))] [(and (adt-value? *tesl-case-14) (eq? (adt-value-variant *tesl-case-14) 'Something)) (let ([pair (hash-ref (adt-value-fields *tesl-case-14) 'value)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 138 (list (cons 'pair pair)) (lambda () (let ([tesl-case-15 (raw-value pair)]) (cond [(and (adt-value? *tesl-case-15) (eq? (adt-value-variant *tesl-case-15) 'Tuple2)) (let ([inner (hash-ref (adt-value-fields *tesl-case-15) 'first)]) (let ([secretPart (hash-ref (adt-value-fields *tesl-case-15) 'second)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 140 (list (cons 'inner inner) (cons 'secretPart secretPart)) (lambda () (let ([tesl-case-16 (raw-value inner)]) (cond [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Something)) (let ([s (hash-ref (adt-value-fields *tesl-case-16) 'value)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 141 (list (cons 's s)) (lambda () (raw-value #t))))] [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Nothing)) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 142 (list) (lambda () (raw-value #f)))]))))))])))))])))))

(define/pow
  (boxNested [id : String])
  #:capabilities [dbRead]
  #:returns (Maybe Box)
  (let ([maybeInst (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 146 (list (cons 'id *id)) (lambda () (let ([tesl_match (select-one (from Inst) (where (==. (entity-field-ref Inst 'id) id)))]) (if tesl_match (Something tesl_match) Nothing))) 'maybeInst)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 147 (list (cons 'maybeInst *maybeInst) (cons 'id *id)) (lambda () (raw-value (Something (BoxOf (raw-value maybeInst))))))))

(define/pow
  (boxInnerIsSomething [m : (Maybe Box)])
  #:returns Boolean
  (thsl-src-control! "tests/sql-maybe-in-tuple-tests.tesl" 150 (list (cons 'm *m)) (lambda () (let ([tesl-case-17 *m]) (cond [(and (adt-value? *tesl-case-17) (eq? (adt-value-variant *tesl-case-17) 'Nothing)) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 151 (list) (lambda () (raw-value #f)))] [(and (adt-value? *tesl-case-17) (eq? (adt-value-variant *tesl-case-17) 'Something)) (let ([b (hash-ref (adt-value-fields *tesl-case-17) 'value)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 152 (list (cons 'b b)) (lambda () (raw-value (boxHasRow *b)))))])))))

(define/pow
  (boxHasRow [b : Box])
  #:returns Boolean
  (thsl-src-control! "tests/sql-maybe-in-tuple-tests.tesl" 155 (list (cons 'b *b)) (lambda () (let ([tesl-case-18 *b]) (cond [(and (adt-value? *tesl-case-18) (eq? (adt-value-variant *tesl-case-18) 'BoxEmpty)) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 156 (list) (lambda () (raw-value #f)))] [(and (adt-value? *tesl-case-18) (eq? (adt-value-variant *tesl-case-18) 'BoxOf)) (let ([inner (hash-ref (adt-value-fields *tesl-case-18) 'inner)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 157 (list (cons 'inner inner)) (lambda () (raw-value (maybeHasRow *inner)))))])))))

(define/pow
  (maybeHasRow [inner : (Maybe Inst)])
  #:returns Boolean
  (thsl-src-control! "tests/sql-maybe-in-tuple-tests.tesl" 160 (list (cons 'inner *inner)) (lambda () (let ([tesl-case-19 *inner]) (cond [(and (adt-value? *tesl-case-19) (eq? (adt-value-variant *tesl-case-19) 'Something)) (let ([i (hash-ref (adt-value-fields *tesl-case-19) 'value)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 161 (list (cons 'i i)) (lambda () (raw-value #t))))] [(and (adt-value? *tesl-case-19) (eq? (adt-value-variant *tesl-case-19) 'Nothing)) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 162 (list) (lambda () (raw-value #f)))])))))

(define/pow
  (listNested [id : String])
  #:capabilities [dbRead]
  #:returns (Maybe (List (Maybe Inst)))
  (let ([maybeInst (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 168 (list (cons 'id *id)) (lambda () (let ([tesl_match (select-one (from Inst) (where (==. (entity-field-ref Inst 'id) id)))]) (if tesl_match (Something tesl_match) Nothing))) 'maybeInst)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 169 (list (cons 'maybeInst *maybeInst) (cons 'id *id)) (lambda () (raw-value (Something (list *maybeInst)))))))

(define/pow
  (listNestedCount [m : (Maybe (List (Maybe Inst)))])
  #:returns Integer
  (thsl-src-control! "tests/sql-maybe-in-tuple-tests.tesl" 172 (list (cons 'm *m)) (lambda () (let ([tesl-case-20 *m]) (cond [(and (adt-value? *tesl-case-20) (eq? (adt-value-variant *tesl-case-20) 'Nothing)) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 173 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-20) (eq? (adt-value-variant *tesl-case-20) 'Something)) (let ([xs (hash-ref (adt-value-fields *tesl-case-20) 'value)]) (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 174 (list (cons 'xs xs)) (lambda () (raw-value (raw-value (tesl_import_List_length *xs))))))])))))

(module+ test
  (require rackunit)
  (test-case "#69 baseline: a plain selectOne Maybe reads back (control)"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-21 (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 179 (list) (lambda () (insert-one! Inst (tesl-hash 'id "i-1" 'active #t)))))
    (check-equal? (raw-value (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 180 (list) (lambda () (probeBaselineSelectOne "i-1")))) #t)
    (check-equal? (raw-value (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 181 (list) (lambda () (probeBaselineSelectOne "missing")))) #f)
    )
    ))
  )

  (test-case "#69 selectOne Maybe nested in a Tuple2 reads back for a PRESENT row"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-22 (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 185 (list) (lambda () (insert-one! Inst (tesl-hash 'id "i-2" 'active #t)))))
    (check-equal? (raw-value (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 186 (list) (lambda () (outerUnwraps (tuple2NestedMaybe "i-2"))))) #t)
    )
    ))
  )

  (test-case "#69 selectOne Maybe nested in a Tuple2 reads back for a MISSING row"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-23 (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 190 (list) (lambda () (insert-one! Inst (tesl-hash 'id "i-3" 'active #t)))))
    (check-equal? (raw-value (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 191 (list) (lambda () (outerUnwraps (tuple2NestedMaybe "missing"))))) #f)
    )
    ))
  )

  (test-case "#69 the tuple's other slot is unaffected"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-24 (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 195 (list) (lambda () (insert-one! Inst (tesl-hash 'id "i-4" 'active #t)))))
    (check-equal? (raw-value (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 196 (list) (lambda () (secondSlotSurvives (tuple2NestedMaybe "i-4"))))) "secret")
    (check-equal? (raw-value (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 197 (list) (lambda () (secondSlotSurvives (tuple2NestedMaybe "missing"))))) "secret")
    )
    ))
  )

  (test-case "#69 an unwrapped Tuple2 return still works"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-25 (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 201 (list) (lambda () (insert-one! Inst (tesl-hash 'id "i-5" 'active #t)))))
    (check-equal? (raw-value (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 202 (list) (lambda () (innerIsSomething (bareTuple2 "i-5"))))) #t)
    (check-equal? (raw-value (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 203 (list) (lambda () (innerIsSomething (bareTuple2 "missing"))))) #f)
    )
    ))
  )

  (test-case "#69 selectOne Maybe in the SECOND tuple slot reads back"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-26 (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 207 (list) (lambda () (insert-one! Inst (tesl-hash 'id "i-6" 'active #t)))))
    (check-equal? (raw-value (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 208 (list) (lambda () (secondSlotIsSomething (maybeInSecondSlot "i-6"))))) #t)
    (check-equal? (raw-value (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 209 (list) (lambda () (secondSlotIsSomething (maybeInSecondSlot "missing"))))) #f)
    )
    ))
  )

  (test-case "#69 selectOne Maybe nested in a Tuple3 reads back"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-27 (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 213 (list) (lambda () (insert-one! Inst (tesl-hash 'id "i-7" 'active #t)))))
    (check-equal? (raw-value (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 214 (list) (lambda () (tuple3InnerIsSomething (tuple3NestedMaybe "i-7"))))) #t)
    (check-equal? (raw-value (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 215 (list) (lambda () (tuple3InnerIsSomething (tuple3NestedMaybe "missing"))))) #f)
    )
    ))
  )

  (test-case "#69 the record workaround stays correct"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-28 (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 219 (list) (lambda () (insert-one! Inst (tesl-hash 'id "i-8" 'active #t)))))
    (check-equal? (raw-value (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 220 (list) (lambda () (recordInnerIsSomething (recordNestedMaybe "i-8"))))) #t)
    (check-equal? (raw-value (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 221 (list) (lambda () (recordInnerIsSomething (recordNestedMaybe "missing"))))) #f)
    )
    ))
  )

  (test-case "#69 generalises: a USER-DEFINED ADT ctor nested in Something"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-29 (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 225 (list) (lambda () (insert-one! Inst (tesl-hash 'id "i-9" 'active #t)))))
    (check-equal? (raw-value (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 226 (list) (lambda () (boxInnerIsSomething (boxNested "i-9"))))) #t)
    (check-equal? (raw-value (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 227 (list) (lambda () (boxInnerIsSomething (boxNested "missing"))))) #f)
    )
    ))
  )

  (test-case "#69 generalises: a list literal nested in Something"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-30 (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 231 (list) (lambda () (insert-one! Inst (tesl-hash 'id "i-10" 'active #t)))))
    (check-equal? (raw-value (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 232 (list) (lambda () (listNestedCount (listNested "i-10"))))) 1)
    (check-equal? (raw-value (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 233 (list) (lambda () (listNestedCount (listNested "missing"))))) 1)
    )
    ))
  )

  (test-case "#69 a hand-built Maybe nested the same way stays correct (control)"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 237 (list) (lambda () (handBuiltInnerIsSomething (handBuiltWrapped #t))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/sql-maybe-in-tuple-tests.tesl" 238 (list) (lambda () (handBuiltInnerIsSomething (handBuiltWrapped #f))))) #f)
    ))
  )

)
