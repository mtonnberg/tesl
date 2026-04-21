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
  (only-in tesl/tesl/prelude Bool Int String)
  (only-in tesl/tesl/int [Int.nonZero tesl_import_Int_nonZero] [Int.divide tesl_import_Int_divide])
)


(provide Box MkBox Option Some None Either Left Right Pair MkPair Tree Leaf Node wrap unwrap mapBox fromOption mapOption bindOption mapRight mapLeft fromRight safeDivide treeSize treeDepth treeInsert treeContains wrap-signature unwrap-signature mapBox-signature fromOption-signature mapOption-signature bindOption-signature mapRight-signature mapLeft-signature fromRight-signature safeDivide-signature treeSize-signature treeDepth-signature treeContains-signature treeInsert-signature)

(define-adt (Box a)
  [MkBox [value : a]]
)

(define/pow
  (wrap [x : Integer])
  #:returns (Box Integer)
  (raw-value (MkBox *x)))

(define/pow
  (unwrap [b : (Box Integer)])
  #:returns Integer
  (let ([tesl_case_0 *b]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'MkBox)) (let ([value (hash-ref (adt-value-fields *tesl_case_0) 'value)]) *value)])))

(define/pow
  (mapBox [b : (Box Integer)] [f : (-> Integer Integer)])
  #:returns (Box Integer)
  (let ([tesl_case_1 *b]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'MkBox)) (let ([value (hash-ref (adt-value-fields *tesl_case_1) 'value)]) (raw-value (raw-value (MkBox (f *value)))))])))

(define-adt (Option a)
  [Some [value : a]]
  [None]
)

(define/pow
  (fromOption [o : (Option Integer)] [default : Integer])
  #:returns Integer
  (let ([tesl_case_2 *o]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Some)) (let ([value (hash-ref (adt-value-fields *tesl_case_2) 'value)]) *value)] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'None)) *default])))

(define/pow
  (mapOption [o : (Option Integer)] [f : (-> Integer Integer)])
  #:returns (Option Integer)
  (let ([tesl_case_3 *o]) (cond [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Some)) (let ([value (hash-ref (adt-value-fields *tesl_case_3) 'value)]) (raw-value (raw-value (Some (f *value)))))] [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'None)) (raw-value None)])))

(define/pow
  (bindOption [o : (Option Integer)] [f : (-> Integer (Option Integer))])
  #:returns (Option Integer)
  (let ([tesl_case_4 *o]) (cond [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Some)) (let ([value (hash-ref (adt-value-fields *tesl_case_4) 'value)]) (raw-value (f *value)))] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'None)) (raw-value None)])))

(define-adt (Either a b)
  [Left [value : a]]
  [Right [value : b]]
)

(define/pow
  (mapRight [e : (Either String Integer)] [f : (-> Integer Integer)])
  #:returns (Either String Integer)
  (let ([tesl_case_5 *e]) (cond [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Left)) (let ([value (hash-ref (adt-value-fields *tesl_case_5) 'value)]) (raw-value (raw-value (Left *value))))] [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Right)) (let ([value (hash-ref (adt-value-fields *tesl_case_5) 'value)]) (raw-value (raw-value (Right (f *value)))))])))

(define/pow
  (mapLeft [e : (Either String Integer)] [f : (-> String String)])
  #:returns (Either String Integer)
  (let ([tesl_case_6 *e]) (cond [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Left)) (let ([value (hash-ref (adt-value-fields *tesl_case_6) 'value)]) (raw-value (raw-value (Left (f *value)))))] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Right)) (let ([value (hash-ref (adt-value-fields *tesl_case_6) 'value)]) (raw-value (raw-value (Right *value))))])))

(define/pow
  (fromRight [e : (Either String Integer)] [default : Integer])
  #:returns Integer
  (let ([tesl_case_7 *e]) (cond [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Left)) *default] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Right)) (let ([v (hash-ref (adt-value-fields *tesl_case_7) 'value)]) *v)])))

(define/pow
  (safeDivide [a : Integer] [b : Integer])
  #:returns (Either String Integer)
  (if (equal? *b 0) (raw-value (raw-value (Left "division by zero"))) (let/check ([tesl_checked_8 (tesl_import_Int_nonZero b)]) (let ([safe tesl_checked_8]) (raw-value (raw-value (Right (tesl_import_Int_divide *a safe))))))))

(define-adt (Pair a b)
  [MkPair [first : a] [second : b]]
)

(define-adt (Tree a)
  [Leaf]
  [Node [left : (Tree Integer)] [value : Integer] [right : (Tree Integer)]]
)

(define/pow
  (treeSize [t : (Tree Integer)])
  #:returns Integer
  (let ([tesl_case_9 *t]) (cond [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Leaf)) (raw-value 0)] [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Node)) (let ([left (hash-ref (adt-value-fields *tesl_case_9) 'left)]) (let ([value (hash-ref (adt-value-fields *tesl_case_9) 'value)]) (let ([right (hash-ref (adt-value-fields *tesl_case_9) 'right)]) (raw-value (+ (+ 1 (raw-value (treeSize *left))) (raw-value (treeSize *right)))))))])))

(define/pow
  (treeDepth [t : (Tree Integer)])
  #:returns Integer
  (let ([tesl_case_10 *t]) (cond [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Leaf)) (raw-value 0)] [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Node)) (let ([left (hash-ref (adt-value-fields *tesl_case_10) 'left)]) (let ([value (hash-ref (adt-value-fields *tesl_case_10) 'value)]) (let ([right (hash-ref (adt-value-fields *tesl_case_10) 'right)]) (let ([ld (treeDepth *left)]) (let ([rd (treeDepth *right)]) (let ([maxD (if (> (raw-value ld) (raw-value rd)) ld rd)]) (raw-value (+ 1 (raw-value maxD)))))))))])))

(define/pow
  (treeContains [t : (Tree Integer)] [target : Integer])
  #:returns Boolean
  (let ([tesl_case_11 *t]) (cond [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'Leaf)) (raw-value #f)] [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'Node)) (let ([left (hash-ref (adt-value-fields *tesl_case_11) 'left)]) (let ([value (hash-ref (adt-value-fields *tesl_case_11) 'value)]) (let ([right (hash-ref (adt-value-fields *tesl_case_11) 'right)]) (if (equal? *value *target) (raw-value #t) (if (< *target *value) (raw-value (treeContains *left target)) (raw-value (treeContains *right target)))))))])))

(define/pow
  (treeInsert [t : (Tree Integer)] [v : Integer])
  #:returns (Tree Integer)
  (let ([tesl_case_12 *t]) (cond [(and (adt-value? *tesl_case_12) (eq? (adt-value-variant *tesl_case_12) 'Leaf)) (raw-value (raw-value (Node Leaf *v Leaf)))] [(and (adt-value? *tesl_case_12) (eq? (adt-value-variant *tesl_case_12) 'Node)) (let ([left (hash-ref (adt-value-fields *tesl_case_12) 'left)]) (let ([value (hash-ref (adt-value-fields *tesl_case_12) 'value)]) (let ([right (hash-ref (adt-value-fields *tesl_case_12) 'right)]) (if (equal? *v *value) *t (if (< *v *value) (raw-value (raw-value (Node (treeInsert *left v) *value *right))) (raw-value (raw-value (Node *left *value (treeInsert *right v)))))))))])))

(define-adt (Foo a b)
  [FooLeft [value1 : a] [value2 : b]]
  [FooRight [value : b]]
)

(define/pow
  (showcaseFoo [x : (Foo Integer String)])
  #:returns Integer
  (let ([tesl_case_13 *x]) (cond [(and (and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'FooLeft)) (let ([v1 (hash-ref (adt-value-fields *tesl_case_13) 'value1)]) (let ([v2 (hash-ref (adt-value-fields *tesl_case_13) 'value2)]) (and (equal? *v2 "hej") (> *v1 2))))) (let ([v1 (hash-ref (adt-value-fields *tesl_case_13) 'value1)]) (let ([v2 (hash-ref (adt-value-fields *tesl_case_13) 'value2)]) (raw-value 5)))] [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'FooLeft)) (let ([v1 (hash-ref (adt-value-fields *tesl_case_13) 'value1)]) *v1)] [(and (and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'FooRight)) (let ([b (hash-ref (adt-value-fields *tesl_case_13) 'value)]) (equal? *b "hej"))) (let ([b (hash-ref (adt-value-fields *tesl_case_13) 'value)]) (raw-value 5))] [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'FooRight)) (raw-value 2)])))

(module+ test
  (require rackunit)
  (test-case "Box"
  (define b (wrap 42))
  (check-equal? (raw-value (unwrap b)) 42)
  (check-equal? (raw-value (unwrap (mapBox b (let () (define/pow (tesl-lambda-14 [x : Integer]) #:returns Integer (+ *x 1)) tesl-lambda-14)))) 43)
  (check-equal? (raw-value (unwrap (MkBox 0))) 0)
  )

  (test-case "Option"
  (check-equal? (raw-value (fromOption (Some 7) 0)) 7)
  (check-equal? (raw-value (fromOption None 99)) 99)
  (check-equal? (raw-value (fromOption (mapOption (Some 5) (let () (define/pow (tesl-lambda-15 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-15)) 0)) 10)
  (check-equal? (raw-value (fromOption (mapOption None (let () (define/pow (tesl-lambda-16 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-16)) 0)) 0)
  (check-equal? (raw-value (fromOption (bindOption (Some 4) (let () (define/pow (tesl-lambda-17 [x : Integer]) #:returns Any (raw-value (Some (+ *x 1)))) tesl-lambda-17)) 0)) 5)
  (check-equal? (raw-value (fromOption (bindOption None (let () (define/pow (tesl-lambda-18 [x : Integer]) #:returns Any (raw-value (Some (+ *x 1)))) tesl-lambda-18)) 0)) 0)
  )

  (test-case "Either"
  (check-equal? (raw-value (fromRight (Right 42) 0)) 42)
  (check-equal? (raw-value (fromRight (Left "oops") 0)) 0)
  (define doubled (mapRight (Right 5) (let () (define/pow (tesl-lambda-19 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-19)))
  (check-equal? (raw-value (fromRight doubled 0)) 10)
  (define unchanged (mapRight (Left "err") (let () (define/pow (tesl-lambda-20 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-20)))
  (check-equal? (raw-value (fromRight unchanged 0)) 0)
  (check-equal? (raw-value (fromRight (safeDivide 10 2) -1)) 5)
  (check-equal? (raw-value (fromRight (safeDivide 10 0) -1)) -1)
  )

  (test-case "Tree"
  (define empty Leaf)
  (define t1 (treeInsert empty 5))
  (define t2 (treeInsert t1 3))
  (define t3 (treeInsert t2 7))
  (define t4 (treeInsert t3 1))
  (check-equal? (raw-value (treeSize Leaf)) 0)
  (check-equal? (raw-value (treeSize t1)) 1)
  (check-equal? (raw-value (treeSize t3)) 3)
  (check-equal? (raw-value (treeSize t4)) 4)
  (check-equal? (raw-value (treeDepth Leaf)) 0)
  (check-equal? (raw-value (treeDepth t1)) 1)
  (check-equal? (raw-value (treeDepth t3)) 2)
  (check-true (raw-value (treeContains t3 5)))
  (check-true (raw-value (treeContains t3 3)))
  (check-true (raw-value (treeContains t3 7)))
  (check-true (raw-value (treeContains t4 1)))
  (check-equal? (raw-value (treeContains t4 5)) #t)
  (check-equal? (raw-value (treeContains t3 99)) #f)
  (check-equal? (raw-value (treeContains Leaf 1)) #f)
  )

)
