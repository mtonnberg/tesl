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
  (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "value must be positive" #:http-code 400)))

(define/pow
  (needPositive [n : Integer ::: (IsPositive n)])
  #:returns Integer
  *n)

(define/pow
  (insertTree [t : PositiveTree] [v : Integer ::: (IsPositive v)])
  #:returns PositiveTree
  (let ([tesl_case_0 *t]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Leaf)) (raw-value (raw-value (Node Leaf v Leaf)))] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl_case_0) 'left)]) (let ([cur (hash-ref (adt-value-fields *tesl_case_0) 'value)]) (let ([r (hash-ref (adt-value-fields *tesl_case_0) 'right)]) (if (< *v *cur) (raw-value (raw-value (Node (insertTree *l v) cur *r))) (if (> *v *cur) (raw-value (raw-value (Node *l cur (insertTree *r v)))) *t)))))])))

(define/pow
  (treeSize [t : PositiveTree])
  #:returns Integer
  (let ([tesl_case_1 *t]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Leaf)) (raw-value 0)] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl_case_1) 'left)]) (let ([r (hash-ref (adt-value-fields *tesl_case_1) 'right)]) (raw-value (+ (+ 1 (raw-value (treeSize *l))) (raw-value (treeSize *r))))))])))

(define/pow
  (treeSum [t : PositiveTree])
  #:returns Integer
  (let ([tesl_case_2 *t]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Leaf)) (raw-value 0)] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl_case_2) 'left)]) (let ([v (hash-ref (adt-value-fields *tesl_case_2) 'value)]) (let ([r (hash-ref (adt-value-fields *tesl_case_2) 'right)]) (raw-value (+ (+ *v (raw-value (treeSum *l))) (raw-value (treeSum *r)))))))])))

(define/pow
  (findMin [t : PositiveTree])
  #:returns (Either String Integer)
  (let ([tesl_case_3 *t]) (cond [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Leaf)) (raw-value (Left "Not found"))] [(and (and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Node)) (let ([tesl_case_3_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_3) 'left))]) (and (adt-value? *tesl_case_3_f0) (eq? (adt-value-variant *tesl_case_3_f0) 'Leaf)))) (let ([tesl_case_3_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_3) 'left))]) (let ([cur (hash-ref (adt-value-fields *tesl_case_3) 'value)]) (raw-value (Right cur))))] [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl_case_3) 'left)]) (findMin l))])))

(define-adt (CustomEither l r)
  [CustomLeft [left : l]]
  [CustomRight [right : r]]
)

(define/pow
  (findMinAlt [t : PositiveTree])
  #:returns (CustomEither String Integer)
  (let ([tesl_case_4 *t]) (cond [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Leaf)) (raw-value (CustomLeft "Not found"))] [(and (and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Node)) (let ([tesl_case_4_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_4) 'left))]) (and (adt-value? *tesl_case_4_f0) (eq? (adt-value-variant *tesl_case_4_f0) 'Leaf)))) (let ([tesl_case_4_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_4) 'left))]) (let ([cur (hash-ref (adt-value-fields *tesl_case_4) 'value)]) (raw-value (CustomRight cur))))] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl_case_4) 'left)]) (findMinAlt l))])))

(define/pow
  (findMax [t : PositiveTree])
  #:returns (Maybe Integer)
  (let ([tesl_case_5 *t]) (cond [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Leaf)) Nothing] [(and (and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Node)) (let ([tesl_case_5_f2 (raw-value (hash-ref (adt-value-fields *tesl_case_5) 'right))]) (and (adt-value? *tesl_case_5_f2) (eq? (adt-value-variant *tesl_case_5_f2) 'Leaf)))) (let ([cur (hash-ref (adt-value-fields *tesl_case_5) 'value)]) (let ([tesl_case_5_f2 (raw-value (hash-ref (adt-value-fields *tesl_case_5) 'right))]) (raw-value (Something cur))))] [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Node)) (let ([r (hash-ref (adt-value-fields *tesl_case_5) 'right)]) (findMax *r))])))

(define/pow
  (doubleMin [t : PositiveTree])
  #:returns Integer
  (let ([m (findMin t)]) (let ([tesl_case_6 (raw-value m)]) (cond [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Left)) (raw-value 0)] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Right)) (let ([v (hash-ref (adt-value-fields *tesl_case_6) 'value)]) (raw-value (+ (raw-value (needPositive v)) (raw-value (needPositive v)))))]))))

(define/pow
  (sumMinMax [t : PositiveTree])
  #:returns Integer
  (let ([mn (findMin t)]) (let ([mx (findMax t)]) (let ([tesl_case_7 (raw-value mn)]) (cond [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Left)) (raw-value 0)] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Right)) (let ([lo (hash-ref (adt-value-fields *tesl_case_7) 'value)]) (let ([tesl_case_8 (raw-value mx)]) (cond [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Nothing)) (raw-value 0)] [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Something)) (let ([hi (hash-ref (adt-value-fields *tesl_case_8) 'value)]) (raw-value (+ (raw-value (needPositive lo)) (raw-value (needPositive hi)))))])))])))))

(define/pow
  (insertRaw [t : PositiveTree] [raw : Integer])
  #:returns PositiveTree
  (let ([tesl_proof_binding_9 (checkPositive raw)]) (let ([_ (forget-proof tesl_proof_binding_9)] [p (detach-all-proof tesl_proof_binding_9)]) (let ([proven (attach-proof raw p)]) (raw-value (insertTree t proven))))))

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
  (define _f_value (tesl-codec-decode-field _j "value" tesl-json-int-codec))
  (record-value 'InsertRequest (hash 'value _f_value)))
(register-type-codec! 'InsertRequest tesl-codec-encode-InsertRequest (list tesl-codec-decode-InsertRequest-0))

(define/pow
  (exampleTree)
  #:returns PositiveTree
  (let ([t0 Leaf]) (let ([t1 (insertRaw t0 3)]) (let ([t2 (insertRaw t1 1)]) (let ([t3 (insertRaw t2 5)]) (raw-value (insertRaw t3 2)))))))

(define-handler
  (getSize)
  #:returns Integer
  (treeSize (exampleTree)))

(define-handler
  (getMin)
  #:returns Integer
  (let ([m (findMin (exampleTree))]) (let ([tesl_case_10 (raw-value m)]) (cond [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Left)) 0] [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Right)) (let ([v (hash-ref (adt-value-fields *tesl_case_10) 'value)]) (needPositive *v))]))))

(define-handler
  (getMinAlt)
  #:returns Integer
  (let ([m (findMinAlt (exampleTree))]) (let ([tesl_case_11 (raw-value m)]) (cond [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'CustomLeft)) 0] [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'CustomRight)) (let ([v (hash-ref (adt-value-fields *tesl_case_11) 'right)]) (needPositive *v))]))))

(define-handler
  (getMax)
  #:returns Integer
  (let ([m (findMax (exampleTree))]) (let ([tesl_case_12 (raw-value m)]) (cond [(and (adt-value? *tesl_case_12) (eq? (adt-value-variant *tesl_case_12) 'Nothing)) 0] [(and (adt-value? *tesl_case_12) (eq? (adt-value-variant *tesl_case_12) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl_case_12) 'value)]) (needPositive *v))]))))

(define-handler
  (getSum)
  #:returns Integer
  (treeSum (exampleTree)))

(define-handler
  (insertValue [req : InsertRequest])
  #:returns Integer
  (let ([t (insertRaw (exampleTree) (raw-value req.value))]) (treeSize t)))

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
  (define t0 Leaf)
  (define t1 (insertRaw t0 5))
  (check-equal? (raw-value (treeSize t1)) 1)
  )

  (test-case "insertRaw: inserting multiple values"
  (define t0 Leaf)
  (define t1 (insertRaw t0 3))
  (define t2 (insertRaw t1 1))
  (define t3 (insertRaw t2 5))
  (check-equal? (raw-value (treeSize t3)) 3)
  )

  (test-case "insertRaw: rejects non-positive value"
  (define t0 Leaf)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (insertRaw t0 0))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: insertRaw t0 0"))
  )

  (test-case "insertRaw: rejects negative value"
  (define t0 Leaf)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (insertRaw t0 -1))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: insertRaw t0 -1"))
  )

  (test-case "findMin: empty tree returns Left"
  (define t Leaf)
  (define m (findMin t))
  (let ([*tesl_case_13 (raw-value 
    m)]) (cond
    [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'Left))
      (check-true (raw-value #t))
    ]
    [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'Right))
      (check-true (raw-value #f))
    ]
  ))
  )

  (test-case "findMin: single-node tree"
  (define t (insertRaw Leaf 7))
  (define m (findMin t))
  (let ([*tesl_case_14 (raw-value 
    m)]) (cond
    [(and (adt-value? *tesl_case_14) (eq? (adt-value-variant *tesl_case_14) 'Left))
      (check-true (raw-value #f))
    ]
    [(and (adt-value? *tesl_case_14) (eq? (adt-value-variant *tesl_case_14) 'Right))
      (let ([v (hash-ref (adt-value-fields *tesl_case_14) 'value)])
        (check-equal? (raw-value v) 7)
      )
    ]
  ))
  )

  (test-case "findMin: returns smallest value with IsPositive proof"
  (define t (insertRaw (insertRaw (insertRaw Leaf 3) 1) 5))
  (define m (findMin t))
  (define mAlt (findMinAlt t))
  (let ([*tesl_case_15 (raw-value 
    m)]) (cond
    [(and (adt-value? *tesl_case_15) (eq? (adt-value-variant *tesl_case_15) 'Left))
      (check-true (raw-value #f))
    ]
    [(and (adt-value? *tesl_case_15) (eq? (adt-value-variant *tesl_case_15) 'Right))
      (let ([v (hash-ref (adt-value-fields *tesl_case_15) 'value)])
        (let ([*tesl_case_16 (raw-value 
          mAlt)]) (cond
          [(and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'CustomLeft))
            (check-true (raw-value #f))
          ]
          [(and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'CustomRight))
            (let ([vAlt (hash-ref (adt-value-fields *tesl_case_16) 'right)])
              (define n (needPositive v))
              (define nAlt (needPositive vAlt))
              (check-equal? (raw-value n) nAlt)
            )
          ]
        ))
      )
    ]
  ))
  )

  (test-case "findMax: returns largest value with IsPositive proof"
  (define t (insertRaw (insertRaw (insertRaw Leaf 3) 1) 5))
  (define m (findMax t))
  (let ([*tesl_case_17 (raw-value 
    m)]) (cond
    [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Nothing))
      (check-true (raw-value #f))
    ]
    [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Something))
      (let ([v (hash-ref (adt-value-fields *tesl_case_17) 'value)])
        (define n (needPositive v))
        (check-equal? (raw-value n) 5)
      )
    ]
  ))
  )

  (test-case "doubleMin: uses Maybe arm value"
  (define t (exampleTree))
  (check-equal? (raw-value (doubleMin t)) 2)
  )

  (test-case "sumMinMax: combines min and max"
  (define t (exampleTree))
  (check-equal? (raw-value (sumMinMax t)) 6)
  )

  (test-case "treeSize: counts all nodes"
  (define t (exampleTree))
  (check-equal? (raw-value (treeSize t)) 4)
  )

  (test-case "treeSum: sums all values"
  (define t (exampleTree))
  (check-equal? (raw-value (treeSum t)) 11)
  )

  (test-case "proof isolation: two independent trees"
  (define ta (insertRaw Leaf 10))
  (define tb (insertRaw Leaf 20))
  (define ma (findMin ta))
  (define mb (findMin tb))
  (let ([*tesl_case_18 (raw-value 
    ma)]) (cond
    [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'Left))
      (check-true (raw-value #f))
    ]
    [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'Right))
      (let ([a (hash-ref (adt-value-fields *tesl_case_18) 'value)])
        (let ([*tesl_case_19 (raw-value 
          mb)]) (cond
          [(and (adt-value? *tesl_case_19) (eq? (adt-value-variant *tesl_case_19) 'Left))
            (check-true (raw-value #f))
          ]
          [(and (adt-value? *tesl_case_19) (eq? (adt-value-variant *tesl_case_19) 'Right))
            (let ([b (hash-ref (adt-value-fields *tesl_case_19) 'value)])
              (check-equal? (raw-value a) 10)
              (check-equal? (raw-value b) 20)
              (define na (needPositive a))
              (define nb (needPositive b))
              (check-equal? (raw-value (+ (raw-value na) (raw-value nb))) 30)
            )
          ]
        ))
      )
    ]
  ))
  )

)
