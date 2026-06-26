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
  (only-in tesl/tesl/prelude Bool Int Fact String)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/either Either Left Right)
)


(provide PositiveTreeServer)

(define IsPositive 'IsPositive)

(define-adt PositiveTree
  [Leaf]
  [Node [left : PositiveTree] [value : Integer] [right : PositiveTree]]
)

(define-checker
  (checkPositive [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 49 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "value must be positive" #:http-code 400)))))

(define/pow
  (needPositive [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 54 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (insertTree [t : PositiveTree] [v : Integer ::: (IsPositive v)])
  #:returns PositiveTree
  (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 60 (list (cons 't *t) (cons 'v *v)) (lambda () (let ([tesl_case_0 *t]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Leaf)) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 62 (list) (lambda () (raw-value (raw-value (Node Leaf v Leaf)))))] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl_case_0) 'left)]) (let ([cur (hash-ref (adt-value-fields *tesl_case_0) 'value)]) (let ([r (hash-ref (adt-value-fields *tesl_case_0) 'right)]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 64 (list (cons 'l l) (cons 'cur cur) (cons 'r r)) (lambda () (if (< *v *cur) (raw-value (raw-value (Node (insertTree *l v) cur *r))) (if (> *v *cur) (raw-value (raw-value (Node *l cur (insertTree *r v)))) *t)))))))])))))

(define/pow
  (treeSize [t : PositiveTree])
  #:returns Integer
  (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 72 (list (cons 't *t)) (lambda () (let ([tesl_case_1 *t]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Leaf)) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 73 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl_case_1) 'left)]) (let ([r (hash-ref (adt-value-fields *tesl_case_1) 'right)]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 74 (list (cons 'l l) (cons 'r r)) (lambda () (raw-value (+ (+ 1 (raw-value (treeSize *l))) (raw-value (treeSize *r))))))))])))))

(define/pow
  (treeSum [t : PositiveTree])
  #:returns Integer
  (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 77 (list (cons 't *t)) (lambda () (let ([tesl_case_2 *t]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Leaf)) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 78 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl_case_2) 'left)]) (let ([v (hash-ref (adt-value-fields *tesl_case_2) 'value)]) (let ([r (hash-ref (adt-value-fields *tesl_case_2) 'right)]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 79 (list (cons 'l l) (cons 'v v) (cons 'r r)) (lambda () (raw-value (+ (+ *v (raw-value (treeSum *l))) (raw-value (treeSum *r)))))))))])))))

(define/pow
  (findMin [t : PositiveTree])
  #:returns (Either String Integer)
  (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 96 (list (cons 't *t)) (lambda () (let ([tesl_case_3 *t]) (cond [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Leaf)) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 97 (list) (lambda () (raw-value (Left "Not found"))))] [(and (and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Node)) (let ([tesl_case_3_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_3) 'left))]) (and (adt-value? *tesl_case_3_f0) (eq? (adt-value-variant *tesl_case_3_f0) 'Leaf)))) (let ([tesl_case_3_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_3) 'left))]) (let ([cur (hash-ref (adt-value-fields *tesl_case_3) 'value)]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 98 (list (cons 'cur cur)) (lambda () (raw-value (Right cur))))))] [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl_case_3) 'left)]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 99 (list (cons 'l l)) (lambda () (findMin l))))])))))

(define-adt (CustomEither l r)
  [CustomLeft [left : l]]
  [CustomRight [right : r]]
)

(define/pow
  (findMinAlt [t : PositiveTree])
  #:returns (CustomEither String Integer)
  (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 106 (list (cons 't *t)) (lambda () (let ([tesl_case_4 *t]) (cond [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Leaf)) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 107 (list) (lambda () (raw-value (CustomLeft "Not found"))))] [(and (and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Node)) (let ([tesl_case_4_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_4) 'left))]) (and (adt-value? *tesl_case_4_f0) (eq? (adt-value-variant *tesl_case_4_f0) 'Leaf)))) (let ([tesl_case_4_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_4) 'left))]) (let ([cur (hash-ref (adt-value-fields *tesl_case_4) 'value)]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 108 (list (cons 'cur cur)) (lambda () (raw-value (CustomRight cur))))))] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl_case_4) 'left)]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 109 (list (cons 'l l)) (lambda () (findMinAlt l))))])))))

(define/pow
  (findMax [t : PositiveTree])
  #:returns (Maybe Integer)
  (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 112 (list (cons 't *t)) (lambda () (let ([tesl_case_5 *t]) (cond [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Leaf)) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 113 (list) (lambda () Nothing))] [(and (and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Node)) (let ([tesl_case_5_f2 (raw-value (hash-ref (adt-value-fields *tesl_case_5) 'right))]) (and (adt-value? *tesl_case_5_f2) (eq? (adt-value-variant *tesl_case_5_f2) 'Leaf)))) (let ([cur (hash-ref (adt-value-fields *tesl_case_5) 'value)]) (let ([tesl_case_5_f2 (raw-value (hash-ref (adt-value-fields *tesl_case_5) 'right))]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 114 (list (cons 'cur cur)) (lambda () (raw-value (Something cur))))))] [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Node)) (let ([r (hash-ref (adt-value-fields *tesl_case_5) 'right)]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 115 (list (cons 'r r)) (lambda () (findMax *r))))])))))

(define/pow
  (doubleMin [t : PositiveTree])
  #:returns Integer
  (let ([m (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 118 (list (cons 't *t)) (lambda () (findMin t)))]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 119 (list (cons 'm *m) (cons 't *t)) (lambda () (let ([tesl_case_6 (raw-value m)]) (cond [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Left)) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 120 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Right)) (let ([v (hash-ref (adt-value-fields *tesl_case_6) 'value)]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 123 (list (cons 'v v)) (lambda () (raw-value (+ (raw-value (needPositive v)) (raw-value (needPositive v)))))))]))))))

(define/pow
  (sumMinMax [t : PositiveTree])
  #:returns Integer
  (let ([mn (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 126 (list (cons 't *t)) (lambda () (findMin t)))]) (let ([mx (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 127 (list (cons 'mn *mn) (cons 't *t)) (lambda () (findMax t)))]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 128 (list (cons 'mx *mx) (cons 'mn *mn) (cons 't *t)) (lambda () (let ([tesl_case_7 (raw-value mn)]) (cond [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Left)) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 129 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Right)) (let ([lo (hash-ref (adt-value-fields *tesl_case_7) 'value)]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 131 (list (cons 'lo lo)) (lambda () (let ([tesl_case_8 (raw-value mx)]) (cond [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Nothing)) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 132 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Something)) (let ([hi (hash-ref (adt-value-fields *tesl_case_8) 'value)]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 134 (list (cons 'hi hi)) (lambda () (raw-value (+ (raw-value (needPositive lo)) (raw-value (needPositive hi)))))))])))))])))))))

(define/pow
  (insertRaw [t : PositiveTree] [raw : Integer])
  #:returns PositiveTree
  (let ([tesl_proof_binding_9 (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 147 (list (cons 't *t) (cons 'raw *raw)) (lambda () (checkPositive raw)))]) (let ([_ (forget-proof tesl_proof_binding_9)] [p (detach-all-proof tesl_proof_binding_9)]) (let ([proven (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 148 (list (cons '_ *_) (cons 't *t) (cons 'raw *raw)) (lambda () (attach-proof raw p)))]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 149 (list (cons 'proven *proven) (cons '_ *_) (cons 't *t) (cons 'raw *raw)) (lambda () (raw-value (insertTree t proven))))))))

(define-capability ptreeService)

(define PositiveTreeServer-sse-routes '())
(define-api PositiveTreeApi
  [getSize :
    "tree"
    :> "size"
    :> (Get JSON Integer)
    ]
  [getMin :
    "tree"
    :> "min"
    :> (Get JSON Integer)
    ]
  [getMinAlt :
    "tree"
    :> "min-alt"
    :> (Get JSON Integer)
    ]
  [getMax :
    "tree"
    :> "max"
    :> (Get JSON Integer)
    ]
  [getSum :
    "tree"
    :> "sum"
    :> (Get JSON Integer)
    ]
  [insertValue :
    "tree"
    :> "insert"
    :> (ReqBody JSON [req : InsertRequest])
    :> (Post JSON Integer)
    ]
)

(define-record InsertRequest
  [value : Integer]
)

(define (tesl-codec-encode-InsertRequest _v)
  (error "toJson is forbidden for type InsertRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-InsertRequest-0 _j)
  (define _f_value (tesl-decode-prim-field _j "value" tesl-decode-prim-int))
  (record-value 'InsertRequest (hash 'value _f_value)))
(register-type-codec! 'InsertRequest tesl-codec-encode-InsertRequest (list tesl-codec-decode-InsertRequest-0))

(define/pow
  (exampleTree)
  #:returns PositiveTree
  (let ([t0 (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 184 (list) (lambda () Leaf))]) (let ([t1 (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 185 (list (cons 't0 *t0)) (lambda () (insertRaw t0 3)))]) (let ([t2 (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 186 (list (cons 't1 *t1) (cons 't0 *t0)) (lambda () (insertRaw t1 1)))]) (let ([t3 (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 187 (list (cons 't2 *t2) (cons 't1 *t1) (cons 't0 *t0)) (lambda () (insertRaw t2 5)))]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 188 (list (cons 't3 *t3) (cons 't2 *t2) (cons 't1 *t1) (cons 't0 *t0)) (lambda () (raw-value (insertRaw t3 2)))))))))

(define-handler
  (getSize)
  #:returns Integer
  (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 190 (list) (lambda () (treeSize (exampleTree)))))

(define-handler
  (getMin)
  #:returns Integer
  (let ([m (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 193 (list) (lambda () (findMin (exampleTree))))]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 194 (list (cons 'm *m)) (lambda () (let ([tesl_case_10 (raw-value m)]) (cond [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Left)) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 195 (list) (lambda () 0))] [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Right)) (let ([v (hash-ref (adt-value-fields *tesl_case_10) 'value)]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 196 (list (cons 'v v)) (lambda () (needPositive *v))))]))))))

(define-handler
  (getMinAlt)
  #:returns Integer
  (let ([m (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 199 (list) (lambda () (findMinAlt (exampleTree))))]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 200 (list (cons 'm *m)) (lambda () (let ([tesl_case_11 (raw-value m)]) (cond [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'CustomLeft)) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 201 (list) (lambda () 0))] [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'CustomRight)) (let ([v (hash-ref (adt-value-fields *tesl_case_11) 'right)]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 202 (list (cons 'v v)) (lambda () (needPositive *v))))]))))))

(define-handler
  (getMax)
  #:returns Integer
  (let ([m (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 205 (list) (lambda () (findMax (exampleTree))))]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 206 (list (cons 'm *m)) (lambda () (let ([tesl_case_12 (raw-value m)]) (cond [(and (adt-value? *tesl_case_12) (eq? (adt-value-variant *tesl_case_12) 'Nothing)) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 207 (list) (lambda () 0))] [(and (adt-value? *tesl_case_12) (eq? (adt-value-variant *tesl_case_12) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl_case_12) 'value)]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 208 (list (cons 'v v)) (lambda () (needPositive *v))))]))))))

(define-handler
  (getSum)
  #:returns Integer
  (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 210 (list) (lambda () (treeSum (exampleTree)))))

(define-handler
  (insertValue [req : InsertRequest])
  #:returns Integer
  (let ([t (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 213 (list (cons 'req *req)) (lambda () (insertRaw (exampleTree) (raw-value req.value))))]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 214 (list (cons 't *t) (cons 'req *req)) (lambda () (treeSize t)))))

(define-server PositiveTreeServer
  #:api PositiveTreeApi
  [getSize getSize]
  [getMin getMin]
  [getMinAlt getMinAlt]
  [getMax getMax]
  [getSum getSum]
  [insertValue insertValue]
)

(module+ test
  (require rackunit)
  (test-case "insertRaw: builds a non-empty tree"
  (define t0 (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 228 (list) (lambda () Leaf)))
  (define t1 (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 229 (list (cons 't0 t0)) (lambda () (insertRaw t0 5))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 230 (list (cons 't1 t1) (cons 't0 t0)) (lambda () (treeSize t1)))) 1)
  )

  (test-case "insertRaw: inserting multiple values"
  (define t0 (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 234 (list) (lambda () Leaf)))
  (define t1 (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 235 (list (cons 't0 t0)) (lambda () (insertRaw t0 3))))
  (define t2 (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 236 (list (cons 't1 t1) (cons 't0 t0)) (lambda () (insertRaw t1 1))))
  (define t3 (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 237 (list (cons 't2 t2) (cons 't1 t1) (cons 't0 t0)) (lambda () (insertRaw t2 5))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 238 (list (cons 't3 t3) (cons 't2 t2) (cons 't1 t1) (cons 't0 t0)) (lambda () (treeSize t3)))) 3)
  )

  (test-case "insertRaw: rejects non-positive value"
  (define t0 (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 242 (list) (lambda () Leaf)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 243 (list (cons 't0 t0)) (lambda ()
                          (insertRaw t0 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: insertRaw t0 0"))
  )

  (test-case "insertRaw: rejects negative value"
  (define t0 (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 247 (list) (lambda () Leaf)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 248 (list (cons 't0 t0)) (lambda ()
                          (insertRaw t0 -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: insertRaw t0 -1"))
  )

  (test-case "findMin: empty tree returns Left"
  (define t (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 252 (list) (lambda () Leaf)))
  (define m (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 253 (list (cons 't t)) (lambda () (findMin t))))
  (let ([*tesl_case_13 (raw-value 
    m)]) (cond
    [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'Left))
      (check-true (raw-value (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 255 (list) (lambda () #t))))
    ]
    [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'Right))
      (check-true (raw-value (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 256 (list) (lambda () #f))))
    ]
  ))
  )

  (test-case "findMin: single-node tree"
  (define t (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 260 (list) (lambda () (insertRaw Leaf 7))))
  (define m (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 261 (list (cons 't t)) (lambda () (findMin t))))
  (let ([*tesl_case_14 (raw-value 
    m)]) (cond
    [(and (adt-value? *tesl_case_14) (eq? (adt-value-variant *tesl_case_14) 'Left))
      (check-true (raw-value (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 263 (list) (lambda () #f))))
    ]
    [(and (adt-value? *tesl_case_14) (eq? (adt-value-variant *tesl_case_14) 'Right))
      (let ([v (hash-ref (adt-value-fields *tesl_case_14) 'value)])
        (check-equal? (raw-value (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 265 (list) (lambda () v))) 7)
      )
    ]
  ))
  )

  (test-case "findMin: returns smallest value with IsPositive proof"
  (define t (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 269 (list) (lambda () (insertRaw (insertRaw (insertRaw Leaf 3) 1) 5))))
  (define m (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 270 (list (cons 't t)) (lambda () (findMin t))))
  (define mAlt (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 271 (list (cons 'm m) (cons 't t)) (lambda () (findMinAlt t))))
  (let ([*tesl_case_15 (raw-value 
    m)]) (cond
    [(and (adt-value? *tesl_case_15) (eq? (adt-value-variant *tesl_case_15) 'Left))
      (check-true (raw-value (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 273 (list) (lambda () #f))))
    ]
    [(and (adt-value? *tesl_case_15) (eq? (adt-value-variant *tesl_case_15) 'Right))
      (let ([v (hash-ref (adt-value-fields *tesl_case_15) 'value)])
        (let ([*tesl_case_16 (raw-value 
          mAlt)]) (cond
          [(and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'CustomLeft))
            (check-true (raw-value (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 276 (list) (lambda () #f))))
          ]
          [(and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'CustomRight))
            (let ([vAlt (hash-ref (adt-value-fields *tesl_case_16) 'right)])
              (define n (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 279 (list) (lambda () (needPositive v))))
              (define nAlt (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 280 (list) (lambda () (needPositive vAlt))))
              (check-equal? (raw-value (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 281 (list) (lambda () n))) nAlt)
            )
          ]
        ))
      )
    ]
  ))
  )

  (test-case "findMax: returns largest value with IsPositive proof"
  (define t (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 285 (list) (lambda () (insertRaw (insertRaw (insertRaw Leaf 3) 1) 5))))
  (define m (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 286 (list (cons 't t)) (lambda () (findMax t))))
  (let ([*tesl_case_17 (raw-value 
    m)]) (cond
    [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Nothing))
      (check-true (raw-value (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 288 (list) (lambda () #f))))
    ]
    [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Something))
      (let ([v (hash-ref (adt-value-fields *tesl_case_17) 'value)])
        (define n (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 290 (list) (lambda () (needPositive v))))
        (check-equal? (raw-value (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 291 (list) (lambda () n))) 5)
      )
    ]
  ))
  )

  (test-case "doubleMin: uses Maybe arm value"
  (define t (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 295 (list) (lambda () (exampleTree))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 296 (list (cons 't t)) (lambda () (doubleMin t)))) 2)
  )

  (test-case "sumMinMax: combines min and max"
  (define t (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 300 (list) (lambda () (exampleTree))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 301 (list (cons 't t)) (lambda () (sumMinMax t)))) 6)
  )

  (test-case "treeSize: counts all nodes"
  (define t (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 305 (list) (lambda () (exampleTree))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 306 (list (cons 't t)) (lambda () (treeSize t)))) 4)
  )

  (test-case "treeSum: sums all values"
  (define t (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 310 (list) (lambda () (exampleTree))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 311 (list (cons 't t)) (lambda () (treeSum t)))) 11)
  )

  (test-case "proof isolation: two independent trees"
  (define ta (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 315 (list) (lambda () (insertRaw Leaf 10))))
  (define tb (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 316 (list (cons 'ta ta)) (lambda () (insertRaw Leaf 20))))
  (define ma (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 317 (list (cons 'tb tb) (cons 'ta ta)) (lambda () (findMin ta))))
  (define mb (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 318 (list (cons 'ma ma) (cons 'tb tb) (cons 'ta ta)) (lambda () (findMin tb))))
  (let ([*tesl_case_18 (raw-value 
    ma)]) (cond
    [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'Left))
      (check-true (raw-value (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 320 (list) (lambda () #f))))
    ]
    [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'Right))
      (let ([a (hash-ref (adt-value-fields *tesl_case_18) 'value)])
        (let ([*tesl_case_19 (raw-value 
          mb)]) (cond
          [(and (adt-value? *tesl_case_19) (eq? (adt-value-variant *tesl_case_19) 'Left))
            (check-true (raw-value (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 323 (list) (lambda () #f))))
          ]
          [(and (adt-value? *tesl_case_19) (eq? (adt-value-variant *tesl_case_19) 'Right))
            (let ([b (hash-ref (adt-value-fields *tesl_case_19) 'value)])
              (check-equal? (raw-value (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 325 (list) (lambda () a))) 10)
              (check-equal? (raw-value (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 326 (list) (lambda () b))) 20)
              (define na (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 328 (list) (lambda () (needPositive a))))
              (define nb (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 329 (list) (lambda () (needPositive b))))
              (check-equal? (raw-value (thsl-src! "example/learn/lesson52-maybe-proof.tesl" 330 (list) (lambda () (+ (raw-value na) (raw-value nb))))) 30)
            )
          ]
        ))
      )
    ]
  ))
  )

)
