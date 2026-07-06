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
  (only-in tesl/tesl/prelude Int String Bool List Fact forgetFact)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/list [List.length tesl_import_List_length])
)


(provide )

(define InRange 'InRange)
(define IsEven 'IsEven)
(define IsPositive 'IsPositive)

(define-checker
  (isPositive [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "tests/critical-review-51-tests.tesl" 41 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))))

(define-checker
  (isEven [n : Integer])
  #:returns [n : Integer ::: (IsEven n)]
  (thsl-src! "tests/critical-review-51-tests.tesl" 47 (list (cons 'n *n)) (lambda () (if (tesl-equal? (remainder *n 2) 0) (accept (IsEven n) #:value *n) (reject "not even" #:http-code 400)))))

(define-checker
  (inRange [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (InRange lo hi n)]
  (thsl-src! "tests/critical-review-51-tests.tesl" 53 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (and (<= *lo *n) (<= *n *hi)) (accept (InRange lo hi n) #:value *n) (reject "out of range" #:http-code 400)))))

(define/pow
  (needPositive [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-51-tests.tesl" 58 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needEven [n : Integer ::: (IsEven n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-51-tests.tesl" 59 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needInRange [lo : Integer] [hi : Integer] [n : Integer ::: (InRange lo hi n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-51-tests.tesl" 60 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () *n)))

(define/pow
  (p01_flow [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-51-tests.tesl" 68 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-0 (isPositive raw)]) (let ([checked tesl-checked-0]) (raw-value (needPositive checked)))))))

(define/pow
  (p02_roundtrip [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-51-tests.tesl" 73 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-1 (isPositive raw)]) (let ([checked tesl-checked-1]) (let ([tesl-proof-binding-2 checked]) (let ([x (forget-proof tesl-proof-binding-2)] [p (detach-all-proof tesl-proof-binding-2)]) (let ([restored (attach-proof x p)]) (raw-value (needPositive restored))))))))))

(define/pow
  (p03_multi_param [lo : Integer] [hi : Integer] [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-51-tests.tesl" 80 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-3 (inRange lo hi raw)]) (let ([ranged tesl-checked-3]) (raw-value (needInRange lo hi ranged)))))))

(define-trusted
  (isPositiveOpt [n : Integer])
  #:returns (Maybe (Fact (IsPositive n)))
  (thsl-src! "tests/critical-review-51-tests.tesl" 85 (list (cons 'n *n)) (lambda () (if (> *n 0) (Something (trusted-proof (IsPositive n))) Nothing))))

(define/pow
  (p04_attach_sugar [x : Integer])
  #:returns Integer
  (let ([mp (thsl-src! "tests/critical-review-51-tests.tesl" 91 (list (cons 'x *x)) (lambda () (isPositiveOpt x)))]) (thsl-src-control! "tests/critical-review-51-tests.tesl" 92 (list (cons 'mp *mp) (cons 'x *x)) (lambda () (let ([tesl-case-4 (raw-value mp)]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Something)) (let ([p (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (thsl-src! "tests/critical-review-51-tests.tesl" 94 (list (cons 'p p)) (lambda () (raw-value (needPositive (attach-proof x p))))))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Nothing)) (thsl-src! "tests/critical-review-51-tests.tesl" 96 (list) (lambda () (raw-value 0)))]))))))

(define/pow
  (p05_forget_then_recheck [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-51-tests.tesl" 100 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-5 (isPositive raw)]) (let ([checked tesl-checked-5]) (let ([bare (forget-proof checked)]) (let/check ([tesl-checked-6 (isPositive bare)]) (let ([revalidated tesl-checked-6]) (raw-value (needPositive revalidated))))))))))

(define/pow
  (p06_composite [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-51-tests.tesl" 107 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-7 (isPositive raw)]) (let ([pos tesl-checked-7]) (let/check ([tesl-checked-8 (isEven pos)]) (let ([both tesl-checked-8]) (let ([requireBoth (let () (define/pow (tesl-lambda-9 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(((IsPositive n) && (IsEven n))))]) n)) tesl-lambda-9)]) (raw-value (requireBoth both))))))))))

(define/pow
  (t01_tuple_as_list)
  #:returns Integer
  (let ([pair (thsl-src! "tests/critical-review-51-tests.tesl" 117 (list) (lambda () (list 1 2)))]) (thsl-src! "tests/critical-review-51-tests.tesl" 118 (list (cons 'pair *pair)) (lambda () (raw-value (tesl_import_List_length (raw-value pair)))))))

(define-adt (MyTree a)
  [MkLeaf]
  [MkNode [left : (MyTree a)] [value : a] [right : (MyTree a)]]
)

(define/pow
  (t02_tree_size [t : (MyTree Integer)])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-51-tests.tesl" 125 (list (cons 't *t)) (lambda () (let ([tesl-case-10 *t]) (cond [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'MkLeaf)) (thsl-src! "tests/critical-review-51-tests.tesl" 126 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'MkNode)) (thsl-src! "tests/critical-review-51-tests.tesl" 127 (list) (lambda () (raw-value 1)))])))))

(define-newtype UserId String)

(define-newtype ProjectId String)

(define/pow
  (t03_unwrap [uid : UserId])
  #:returns String
  (thsl-src! "tests/critical-review-51-tests.tesl" 133 (list (cons 'uid *uid)) (lambda () (raw-value uid.value))))

(define-adt Wrapped
  [MkWrap [inner : (Maybe Integer)]]
)

(define/pow
  (c01_nested_paren [w : Wrapped])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-51-tests.tesl" 142 (list (cons 'w *w)) (lambda () (let ([tesl-case-11 *w]) (cond [(and (and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'MkWrap)) (let ([tesl-case-11_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-11) 'inner))]) (and (adt-value? *tesl-case-11_f0) (eq? (adt-value-variant *tesl-case-11_f0) 'Something)))) (let ([tesl-case-11_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-11) 'inner))]) (let ([n (hash-ref (adt-value-fields *tesl-case-11_f0) 'value)]) (thsl-src! "tests/critical-review-51-tests.tesl" 143 (list (cons 'n n)) (lambda () *n))))] [(and (and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'MkWrap)) (let ([tesl-case-11_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-11) 'inner))]) (and (adt-value? *tesl-case-11_f0) (eq? (adt-value-variant *tesl-case-11_f0) 'Nothing)))) (let ([tesl-case-11_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-11) 'inner))]) (thsl-src! "tests/critical-review-51-tests.tesl" 144 (list) (lambda () (raw-value 0))))])))))

(define/pow
  (c02_where_guard [m : (Maybe Integer)])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-51-tests.tesl" 147 (list (cons 'm *m)) (lambda () (let ([tesl-case-12 *m]) (cond [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Nothing)) (thsl-src! "tests/critical-review-51-tests.tesl" 148 (list) (lambda () (raw-value 0)))] [(and (and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Something)) (let ([n (hash-ref (adt-value-fields *tesl-case-12) 'value)]) (> *n 100))) (let ([n (hash-ref (adt-value-fields *tesl-case-12) 'value)]) (thsl-src! "tests/critical-review-51-tests.tesl" 149 (list (cons 'n n)) (lambda () (raw-value 100))))] [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Something)) (let ([n (hash-ref (adt-value-fields *tesl-case-12) 'value)]) (thsl-src! "tests/critical-review-51-tests.tesl" 150 (list (cons 'n n)) (lambda () *n)))])))))

(define/pow
  (n01_bare_nullary [m : (Maybe (Maybe Integer))])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-51-tests.tesl" 159 (list (cons 'm *m)) (lambda () (let ([tesl-case-13 *m]) (cond [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Nothing)) (thsl-src! "tests/critical-review-51-tests.tesl" 160 (list) (lambda () (raw-value 0)))] [(and (and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Something)) (let ([tesl-case-13_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-13) 'value))]) (and (adt-value? *tesl-case-13_f0) (eq? (adt-value-variant *tesl-case-13_f0) 'Nothing)))) (let ([tesl-case-13_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-13) 'value))]) (thsl-src! "tests/critical-review-51-tests.tesl" 161 (list) (lambda () (raw-value 1))))] [(and (and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Something)) (let ([tesl-case-13_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-13) 'value))]) (and (adt-value? *tesl-case-13_f0) (eq? (adt-value-variant *tesl-case-13_f0) 'Something)))) (let ([tesl-case-13_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-13) 'value))]) (let ([n (hash-ref (adt-value-fields *tesl-case-13_f0) 'value)]) (thsl-src! "tests/critical-review-51-tests.tesl" 162 (list (cons 'n n)) (lambda () *n))))])))))

(define/pow
  (n02_case_cmp [x : Integer])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-51-tests.tesl" 167 (list (cons 'x *x)) (lambda () (let ([tesl-case-14 (raw-value (> *x 0))]) (cond [(eq? *tesl-case-14 #t) (thsl-src! "tests/critical-review-51-tests.tesl" 168 (list) (lambda () (raw-value 1)))] [(eq? *tesl-case-14 #f) (thsl-src! "tests/critical-review-51-tests.tesl" 169 (list) (lambda () (raw-value 0)))])))))

(define/pow
  (n03_case_conj [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-51-tests.tesl" 173 (list (cons 'a *a) (cons 'b *b)) (lambda () (let ([tesl-case-15 (raw-value (and (> *a 0) (> *b 0)))]) (cond [(eq? *tesl-case-15 #t) (thsl-src! "tests/critical-review-51-tests.tesl" 174 (list) (lambda () (raw-value 1)))] [(eq? *tesl-case-15 #f) (thsl-src! "tests/critical-review-51-tests.tesl" 175 (list) (lambda () (raw-value 0)))])))))

(define/pow
  (n04_case_arith [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-51-tests.tesl" 179 (list (cons 'a *a) (cons 'b *b)) (lambda () (let ([tesl-case-16 (raw-value (+ *a *b))]) (cond [(= *tesl-case-16 0) (thsl-src! "tests/critical-review-51-tests.tesl" 180 (list) (lambda () (raw-value 100)))] [#t (thsl-src! "tests/critical-review-51-tests.tesl" 181 (list) (lambda () (raw-value 0)))])))))

(define-record Point
  [x : Integer]
  [y : Integer]
)

(define/pow
  (n05_record_update_known [p : Point] [dx : Integer])
  #:returns Point
  (thsl-src! "tests/critical-review-51-tests.tesl" 187 (list (cons 'p *p) (cons 'dx *dx)) (lambda () (tesl-record-update *p (hash 'x (raw-value (+ (tesl-dot/runtime p 'x 'Point) *dx)))))))

(define/pow
  (simpleAdd [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-51-tests.tesl" 191 (list (cons 'a *a) (cons 'b *b)) (lambda () (+ *a *b))))

(define/pow
  (n06_proof_free_alias [x : Integer] [y : Integer])
  #:returns Integer
  (let ([f (thsl-src! "tests/critical-review-51-tests.tesl" 194 (list (cons 'x *x) (cons 'y *y)) (lambda () simpleAdd))]) (thsl-src! "tests/critical-review-51-tests.tesl" 195 (list (cons 'f *f) (cons 'x *x) (cons 'y *y)) (lambda () (raw-value (f x y))))))

(define/pow
  (n07_forget_recheck_chain [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-51-tests.tesl" 200 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-17 (isPositive n)]) (let ([p tesl-checked-17]) (let ([p2 (forget-proof p)]) (let/check ([tesl-checked-18 (isPositive p2)]) (let ([p3 tesl-checked-18]) (raw-value (needPositive p3))))))))))

(define/pow
  (n08_existential_with_check [raw : Integer])
  #:returns (Exists [x : Integer] [_entity : Integer ::: (IsPositive x)])
  (thsl-src! "tests/critical-review-51-tests.tesl" 210 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-19 (isPositive raw)]) (let ([checked tesl-checked-19]) (pack ([checked]) checked))))))

(define/pow
  (n09_int_case [code : Integer])
  #:returns String
  (thsl-src-control! "tests/critical-review-51-tests.tesl" 217 (list (cons 'code *code)) (lambda () (let ([tesl-case-20 *code]) (cond [(= *tesl-case-20 200) (thsl-src! "tests/critical-review-51-tests.tesl" 218 (list) (lambda () (raw-value "ok")))] [(= *tesl-case-20 404) (thsl-src! "tests/critical-review-51-tests.tesl" 219 (list) (lambda () (raw-value "not found")))] [#t (thsl-src! "tests/critical-review-51-tests.tesl" 220 (list) (lambda () (raw-value "other")))])))))

(module+ test
  (require rackunit)
  (test-case "R51_P01 check+needPositive round trip"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 227 (list) (lambda () (p01_flow 5)))) 5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-51-tests.tesl" 228 (list) (lambda ()
                          (p01_flow (- 0 5)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: p01_flow (- 0 5)"))
    ))
  )

  (test-case "R51_P02 decompose-reattach preserves proof subject"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 232 (list) (lambda () (p02_roundtrip 7)))) 7)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-51-tests.tesl" 233 (list) (lambda ()
                          (p02_roundtrip 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: p02_roundtrip 0"))
    ))
  )

  (test-case "R51_P03 multi-param proof flow"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 237 (list) (lambda () (p03_multi_param 1 10 5)))) 5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-51-tests.tesl" 238 (list) (lambda ()
                          (p03_multi_param 1 10 99))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: p03_multi_param 1 10 99"))
    ))
  )

  (test-case "R51_P04 attach sugar"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 242 (list) (lambda () (p04_attach_sugar 3)))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 243 (list) (lambda () (p04_attach_sugar 0)))) 0)
    ))
  )

  (test-case "R51_P05 forget+recheck"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 247 (list) (lambda () (p05_forget_then_recheck 8)))) 8)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-51-tests.tesl" 248 (list) (lambda ()
                          (p05_forget_then_recheck 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: p05_forget_then_recheck 0"))
    ))
  )

  (test-case "R51_P06 composite && on single value"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 252 (list) (lambda () (p06_composite 4)))) 4)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-51-tests.tesl" 253 (list) (lambda ()
                          (p06_composite 3))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: p06_composite 3"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-51-tests.tesl" 254 (list) (lambda ()
                          (p06_composite (- 0 2)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: p06_composite (- 0 2)"))
    ))
  )

  (test-case "R51_T01 two-element list has length 2"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 258 (list) (lambda () (t01_tuple_as_list)))) 2)
    ))
  )

  (test-case "R51_T02 parameterised tree"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 262 (list) (lambda () (t02_tree_size MkLeaf)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 263 (list) (lambda () (t02_tree_size (MkNode MkLeaf 1 MkLeaf))))) 1)
    ))
  )

  (test-case "R51_T03 newtype unwrap"
    (call-with-fresh-memory-db '() (lambda ()
  (define uid (thsl-src! "tests/critical-review-51-tests.tesl" 267 (list) (lambda () (raw-value (UserId "u-1")))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 268 (list (cons 'uid uid)) (lambda () (t03_unwrap uid)))) "u-1")
    ))
  )

  (test-case "R51_C01 nested constructor with paren around nullary"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 272 (list) (lambda () (c01_nested_paren (MkWrap (raw-value (Something 9))))))) 9)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 273 (list) (lambda () (c01_nested_paren (MkWrap Nothing))))) 0)
    ))
  )

  (test-case "R51_C02 where guard exercises the clamp branch"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 277 (list) (lambda () (c02_where_guard Nothing)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 278 (list) (lambda () (c02_where_guard (raw-value (Something 50)))))) 50)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 279 (list) (lambda () (c02_where_guard (raw-value (Something 1000)))))) 100)
    ))
  )

  (test-case "R51_N01 nested bare nullary pattern"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 283 (list) (lambda () (n01_bare_nullary Nothing)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 284 (list) (lambda () (n01_bare_nullary (raw-value (Something Nothing)))))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 285 (list) (lambda () (n01_bare_nullary (raw-value (Something (raw-value (Something 42)))))))) 42)
    ))
  )

  (test-case "R51_N02 case expr scrutinee"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 289 (list) (lambda () (n02_case_cmp 5)))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 290 (list) (lambda () (n02_case_cmp 0)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 291 (list) (lambda () (n02_case_cmp (- 0 3))))) 0)
    ))
  )

  (test-case "R51_N03 case with boolean conjunction"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 295 (list) (lambda () (n03_case_conj 1 2)))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 296 (list) (lambda () (n03_case_conj 0 2)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 297 (list) (lambda () (n03_case_conj 1 0)))) 0)
    ))
  )

  (test-case "R51_N04 case with arithmetic scrutinee"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 301 (list) (lambda () (n04_case_arith 0 0)))) 100)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 302 (list) (lambda () (n04_case_arith 1 1)))) 0)
    ))
  )

  (test-case "R51_N05 record update still works on known field"
    (call-with-fresh-memory-db '() (lambda ()
  (define origin (thsl-src! "tests/critical-review-51-tests.tesl" 306 (list) (lambda () (Point #:x 0 #:y 0))))
  (define moved (thsl-src! "tests/critical-review-51-tests.tesl" 307 (list (cons 'origin origin)) (lambda () (n05_record_update_known origin 10))))
  (check-equal? (thsl-src! "tests/critical-review-51-tests.tesl" 308 (list (cons 'moved moved) (cons 'origin origin)) (lambda () (raw-value (tesl-dot/runtime moved 'x 'Point)))) 10)
  (check-equal? (thsl-src! "tests/critical-review-51-tests.tesl" 309 (list (cons 'moved moved) (cons 'origin origin)) (lambda () (raw-value (tesl-dot/runtime moved 'y 'Point)))) 0)
    ))
  )

  (test-case "R51_N06 proof-free fn alias via let"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 313 (list) (lambda () (n06_proof_free_alias 5 7)))) 12)
    ))
  )

  (test-case "R51_N07 forget+recheck chain"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 317 (list) (lambda () (n07_forget_recheck_chain 9)))) 9)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-51-tests.tesl" 318 (list) (lambda ()
                          (n07_forget_recheck_chain 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: n07_forget_recheck_chain 0"))
    ))
  )

  (test-case "R51_N09 int case with literals and catch-all"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 322 (list) (lambda () (n09_int_case 200)))) "ok")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 323 (list) (lambda () (n09_int_case 404)))) "not found")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-51-tests.tesl" 324 (list) (lambda () (n09_int_case 500)))) "other")
    ))
  )

)
