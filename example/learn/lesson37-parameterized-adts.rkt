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
  (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 56 (list (cons 'x *x)) (lambda () (raw-value (MkBox *x)))))

(define/pow
  (unwrap [b : (Box Integer)])
  #:returns Integer
  (thsl-src-control! "example/learn/lesson37-parameterized-adts.tesl" 59 (list (cons 'b *b)) (lambda () (let ([tesl-case-0 *b]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'MkBox)) (let ([value (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 60 (list (cons 'value value)) (lambda () *value)))])))))

(define/pow
  (mapBox [b : (Box Integer)] [f : (-> Integer Integer)])
  #:returns (Box Integer)
  (thsl-src-control! "example/learn/lesson37-parameterized-adts.tesl" 63 (list (cons 'b *b) (cons 'f *f)) (lambda () (let ([tesl-case-1 *b]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'MkBox)) (let ([value (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 64 (list (cons 'value value)) (lambda () (raw-value (raw-value (MkBox (f *value)))))))])))))

(define-adt (Option a)
  [Some [value : a]]
  [None]
)

(define/pow
  (fromOption [o : (Option Integer)] [default : Integer])
  #:returns Integer
  (thsl-src-control! "example/learn/lesson37-parameterized-adts.tesl" 85 (list (cons 'o *o) (cons 'default *default)) (lambda () (let ([tesl-case-2 *o]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Some)) (let ([value (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 86 (list (cons 'value value)) (lambda () *value)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'None)) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 87 (list) (lambda () *default))])))))

(define/pow
  (mapOption [o : (Option Integer)] [f : (-> Integer Integer)])
  #:returns (Option Integer)
  (thsl-src-control! "example/learn/lesson37-parameterized-adts.tesl" 90 (list (cons 'o *o) (cons 'f *f)) (lambda () (let ([tesl-case-3 *o]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Some)) (let ([value (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 91 (list (cons 'value value)) (lambda () (raw-value (raw-value (Some (f *value)))))))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'None)) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 92 (list) (lambda () (raw-value None)))])))))

(define/pow
  (bindOption [o : (Option Integer)] [f : (-> Integer (Option Integer))])
  #:returns (Option Integer)
  (thsl-src-control! "example/learn/lesson37-parameterized-adts.tesl" 95 (list (cons 'o *o) (cons 'f *f)) (lambda () (let ([tesl-case-4 *o]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Some)) (let ([value (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 96 (list (cons 'value value)) (lambda () (raw-value (f *value)))))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'None)) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 97 (list) (lambda () (raw-value None)))])))))

(define-adt (Either a b)
  [Left [value : a]]
  [Right [value : b]]
)

(define/pow
  (mapRight [e : (Either String Integer)] [f : (-> Integer Integer)])
  #:returns (Either String Integer)
  (thsl-src-control! "example/learn/lesson37-parameterized-adts.tesl" 120 (list (cons 'e *e) (cons 'f *f)) (lambda () (let ([tesl-case-5 *e]) (cond [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Left)) (let ([value (hash-ref (adt-value-fields *tesl-case-5) 'value)]) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 121 (list (cons 'value value)) (lambda () (raw-value (raw-value (Left *value))))))] [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Right)) (let ([value (hash-ref (adt-value-fields *tesl-case-5) 'value)]) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 122 (list (cons 'value value)) (lambda () (raw-value (raw-value (Right (f *value)))))))])))))

(define/pow
  (mapLeft [e : (Either String Integer)] [f : (-> String String)])
  #:returns (Either String Integer)
  (thsl-src-control! "example/learn/lesson37-parameterized-adts.tesl" 125 (list (cons 'e *e) (cons 'f *f)) (lambda () (let ([tesl-case-6 *e]) (cond [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Left)) (let ([value (hash-ref (adt-value-fields *tesl-case-6) 'value)]) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 126 (list (cons 'value value)) (lambda () (raw-value (raw-value (Left (f *value)))))))] [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Right)) (let ([value (hash-ref (adt-value-fields *tesl-case-6) 'value)]) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 127 (list (cons 'value value)) (lambda () (raw-value (raw-value (Right *value))))))])))))

(define/pow
  (fromRight [e : (Either String Integer)] [default : Integer])
  #:returns Integer
  (thsl-src-control! "example/learn/lesson37-parameterized-adts.tesl" 130 (list (cons 'e *e) (cons 'default *default)) (lambda () (let ([tesl-case-7 *e]) (cond [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Left)) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 131 (list) (lambda () *default))] [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Right)) (let ([v (hash-ref (adt-value-fields *tesl-case-7) 'value)]) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 132 (list (cons 'v v)) (lambda () *v)))])))))

(define/pow
  (safeDivide [a : Integer] [b : Integer])
  #:returns (Either String Integer)
  (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 137 (list (cons 'a *a) (cons 'b *b)) (lambda () (if (equal? *b 0) (raw-value (raw-value (Left "division by zero"))) (let/check ([tesl-checked-8 (tesl_import_Int_nonZero b)]) (let ([safe tesl-checked-8]) (raw-value (raw-value (Right (tesl_import_Int_divide *a safe))))))))))

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
  (thsl-src-control! "example/learn/lesson37-parameterized-adts.tesl" 175 (list (cons 't *t)) (lambda () (let ([tesl-case-9 *t]) (cond [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Leaf)) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 176 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Node)) (let ([left (hash-ref (adt-value-fields *tesl-case-9) 'left)]) (let ([value (hash-ref (adt-value-fields *tesl-case-9) 'value)]) (let ([right (hash-ref (adt-value-fields *tesl-case-9) 'right)]) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 178 (list (cons 'left left) (cons 'value value) (cons 'right right)) (lambda () (raw-value (+ (+ 1 (raw-value (treeSize *left))) (raw-value (treeSize *right)))))))))])))))

(define/pow
  (treeDepth [t : (Tree Integer)])
  #:returns Integer
  (thsl-src-control! "example/learn/lesson37-parameterized-adts.tesl" 181 (list (cons 't *t)) (lambda () (let ([tesl-case-10 *t]) (cond [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Leaf)) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 182 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Node)) (let ([left (hash-ref (adt-value-fields *tesl-case-10) 'left)]) (let ([value (hash-ref (adt-value-fields *tesl-case-10) 'value)]) (let ([right (hash-ref (adt-value-fields *tesl-case-10) 'right)]) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 184 (list (cons 'left left) (cons 'value value) (cons 'right right)) (lambda () (let ([ld (treeDepth *left)]) (let ([rd (treeDepth *right)]) (let ([maxD (if (> (raw-value ld) (raw-value rd)) ld rd)]) (raw-value (+ 1 (raw-value maxD)))))))))))])))))

(define/pow
  (treeContains [t : (Tree Integer)] [target : Integer])
  #:returns Boolean
  (thsl-src-control! "example/learn/lesson37-parameterized-adts.tesl" 193 (list (cons 't *t) (cons 'target *target)) (lambda () (let ([tesl-case-11 *t]) (cond [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'Leaf)) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 194 (list) (lambda () (raw-value #f)))] [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'Node)) (let ([left (hash-ref (adt-value-fields *tesl-case-11) 'left)]) (let ([value (hash-ref (adt-value-fields *tesl-case-11) 'value)]) (let ([right (hash-ref (adt-value-fields *tesl-case-11) 'right)]) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 196 (list (cons 'left left) (cons 'value value) (cons 'right right)) (lambda () (if (equal? *value *target) (raw-value #t) (if (< *target *value) (raw-value (treeContains *left target)) (raw-value (treeContains *right target)))))))))])))))

(define/pow
  (treeInsert [t : (Tree Integer)] [v : Integer])
  #:returns (Tree Integer)
  (thsl-src-control! "example/learn/lesson37-parameterized-adts.tesl" 204 (list (cons 't *t) (cons 'v *v)) (lambda () (let ([tesl-case-12 *t]) (cond [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Leaf)) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 205 (list) (lambda () (raw-value (raw-value (Node Leaf *v Leaf)))))] [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Node)) (let ([left (hash-ref (adt-value-fields *tesl-case-12) 'left)]) (let ([value (hash-ref (adt-value-fields *tesl-case-12) 'value)]) (let ([right (hash-ref (adt-value-fields *tesl-case-12) 'right)]) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 207 (list (cons 'left left) (cons 'value value) (cons 'right right)) (lambda () (if (equal? *v *value) *t (if (< *v *value) (raw-value (raw-value (Node (treeInsert *left v) *value *right))) (raw-value (raw-value (Node *left *value (treeInsert *right v)))))))))))])))))

(define-adt (Foo a b)
  [FooLeft [value1 : a] [value2 : b]]
  [FooRight [value : b]]
)

(define/pow
  (showcaseFoo [x : (Foo Integer String)])
  #:returns Integer
  (thsl-src-control! "example/learn/lesson37-parameterized-adts.tesl" 244 (list (cons 'x *x)) (lambda () (let ([tesl-case-13 *x]) (cond [(and (and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'FooLeft)) (let ([v1 (hash-ref (adt-value-fields *tesl-case-13) 'value1)]) (let ([v2 (hash-ref (adt-value-fields *tesl-case-13) 'value2)]) (and (equal? *v2 "hej") (> *v1 2))))) (let ([v1 (hash-ref (adt-value-fields *tesl-case-13) 'value1)]) (let ([v2 (hash-ref (adt-value-fields *tesl-case-13) 'value2)]) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 245 (list (cons 'v1 v1) (cons 'v2 v2)) (lambda () (raw-value 5)))))] [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'FooLeft)) (let ([v1 (hash-ref (adt-value-fields *tesl-case-13) 'value1)]) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 246 (list (cons 'v1 v1)) (lambda () *v1)))] [(and (and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'FooRight)) (let ([b (hash-ref (adt-value-fields *tesl-case-13) 'value)]) (equal? *b "hej"))) (let ([b (hash-ref (adt-value-fields *tesl-case-13) 'value)]) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 247 (list (cons 'b b)) (lambda () (raw-value 5))))] [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'FooRight)) (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 248 (list) (lambda () (raw-value 2)))])))))

(module+ test
  (require rackunit)
  (test-case "Box"
  (define b (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 67 (list) (lambda () (wrap 42))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 68 (list (cons 'b b)) (lambda () (unwrap b)))) 42)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 69 (list (cons 'b b)) (lambda () (unwrap (mapBox b (let () (define/pow (tesl-lambda-14 [x : Integer]) #:returns Integer (+ *x 1)) tesl-lambda-14)))))) 43)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 70 (list (cons 'b b)) (lambda () (unwrap (MkBox 0))))) 0)
  )

  (test-case "Option"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 100 (list) (lambda () (fromOption (Some 7) 0)))) 7)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 101 (list) (lambda () (fromOption None 99)))) 99)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 102 (list) (lambda () (fromOption (mapOption (Some 5) (let () (define/pow (tesl-lambda-15 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-15)) 0)))) 10)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 103 (list) (lambda () (fromOption (mapOption None (let () (define/pow (tesl-lambda-16 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-16)) 0)))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 104 (list) (lambda () (fromOption (bindOption (Some 4) (let () (define/pow (tesl-lambda-17 [x : Integer]) #:returns Any (raw-value (Some (+ *x 1)))) tesl-lambda-17)) 0)))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 105 (list) (lambda () (fromOption (bindOption None (let () (define/pow (tesl-lambda-18 [x : Integer]) #:returns Any (raw-value (Some (+ *x 1)))) tesl-lambda-18)) 0)))) 0)
  )

  (test-case "Either"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 144 (list) (lambda () (fromRight (Right 42) 0)))) 42)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 145 (list) (lambda () (fromRight (Left "oops") 0)))) 0)
  (define doubled (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 147 (list) (lambda () (mapRight (Right 5) (let () (define/pow (tesl-lambda-19 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-19)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 148 (list (cons 'doubled doubled)) (lambda () (fromRight doubled 0)))) 10)
  (define unchanged (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 150 (list (cons 'doubled doubled)) (lambda () (mapRight (Left "err") (let () (define/pow (tesl-lambda-20 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-20)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 151 (list (cons 'unchanged unchanged) (cons 'doubled doubled)) (lambda () (fromRight unchanged 0)))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 153 (list (cons 'unchanged unchanged) (cons 'doubled doubled)) (lambda () (fromRight (safeDivide 10 2) -1)))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 154 (list (cons 'unchanged unchanged) (cons 'doubled doubled)) (lambda () (fromRight (safeDivide 10 0) -1)))) -1)
  )

  (test-case "Tree"
  (define empty (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 215 (list) (lambda () Leaf)))
  (define t1 (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 216 (list (cons 'empty empty)) (lambda () (treeInsert empty 5))))
  (define t2 (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 217 (list (cons 't1 t1) (cons 'empty empty)) (lambda () (treeInsert t1 3))))
  (define t3 (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 218 (list (cons 't2 t2) (cons 't1 t1) (cons 'empty empty)) (lambda () (treeInsert t2 7))))
  (define t4 (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 219 (list (cons 't3 t3) (cons 't2 t2) (cons 't1 t1) (cons 'empty empty)) (lambda () (treeInsert t3 1))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 221 (list (cons 't4 t4) (cons 't3 t3) (cons 't2 t2) (cons 't1 t1) (cons 'empty empty)) (lambda () (treeSize Leaf)))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 222 (list (cons 't4 t4) (cons 't3 t3) (cons 't2 t2) (cons 't1 t1) (cons 'empty empty)) (lambda () (treeSize t1)))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 223 (list (cons 't4 t4) (cons 't3 t3) (cons 't2 t2) (cons 't1 t1) (cons 'empty empty)) (lambda () (treeSize t3)))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 224 (list (cons 't4 t4) (cons 't3 t3) (cons 't2 t2) (cons 't1 t1) (cons 'empty empty)) (lambda () (treeSize t4)))) 4)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 226 (list (cons 't4 t4) (cons 't3 t3) (cons 't2 t2) (cons 't1 t1) (cons 'empty empty)) (lambda () (treeDepth Leaf)))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 227 (list (cons 't4 t4) (cons 't3 t3) (cons 't2 t2) (cons 't1 t1) (cons 'empty empty)) (lambda () (treeDepth t1)))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 228 (list (cons 't4 t4) (cons 't3 t3) (cons 't2 t2) (cons 't1 t1) (cons 'empty empty)) (lambda () (treeDepth t3)))) 2)
  (check-true (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 230 (list (cons 't4 t4) (cons 't3 t3) (cons 't2 t2) (cons 't1 t1) (cons 'empty empty)) (lambda () (treeContains t3 5)))))
  (check-true (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 231 (list (cons 't4 t4) (cons 't3 t3) (cons 't2 t2) (cons 't1 t1) (cons 'empty empty)) (lambda () (treeContains t3 3)))))
  (check-true (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 232 (list (cons 't4 t4) (cons 't3 t3) (cons 't2 t2) (cons 't1 t1) (cons 'empty empty)) (lambda () (treeContains t3 7)))))
  (check-true (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 233 (list (cons 't4 t4) (cons 't3 t3) (cons 't2 t2) (cons 't1 t1) (cons 'empty empty)) (lambda () (treeContains t4 1)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 234 (list (cons 't4 t4) (cons 't3 t3) (cons 't2 t2) (cons 't1 t1) (cons 'empty empty)) (lambda () (treeContains t4 5)))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 235 (list (cons 't4 t4) (cons 't3 t3) (cons 't2 t2) (cons 't1 t1) (cons 'empty empty)) (lambda () (treeContains t3 99)))) #f)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson37-parameterized-adts.tesl" 236 (list (cons 't4 t4) (cons 't3 t3) (cons 't2 t2) (cons 't1 t1) (cons 'empty empty)) (lambda () (treeContains Leaf 1)))) #f)
  )

)
