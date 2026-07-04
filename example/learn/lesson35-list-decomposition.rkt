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
  (only-in tesl/tesl/prelude Int String Bool List)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/list [List.head tesl_import_List_head] [List.tail tesl_import_List_tail] [List.isEmpty tesl_import_List_isEmpty] [List.length tesl_import_List_length] [List.foldl tesl_import_List_foldl] [List.map tesl_import_List_map] [List.filter tesl_import_List_filter] [List.append tesl_import_List_append] [List.take tesl_import_List_take] [List.drop tesl_import_List_drop] [List.zip tesl_import_List_zip])
  (only-in tesl/tesl/tuple Tuple2 [Tuple2.first tesl_import_Tuple2_first] [Tuple2.second tesl_import_Tuple2_second])
  (only-in tesl/tesl/int [Int.nonNegative tesl_import_Int_nonNegative])
)


(provide safeHead safeTail firstOrDefault sumRecursive productRecursive myLength myReverse mapIncrement keepPositive pairHeads zipWith splitAt chunksOf describeList safeHead-signature safeTail-signature firstOrDefault-signature sumRecursive-signature productRecursive-signature myLength-signature myReverse-signature mapIncrement-signature keepPositive-signature pairHeads-signature zipWith-signature splitAt-signature chunksOf-signature describeList-signature)

(define/pow
  (safeHead [xs : (List Integer)])
  #:returns (Maybe Integer)
  (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 67 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_head *xs)))))

(define/pow
  (safeTail [xs : (List Integer)])
  #:returns (Maybe (List Integer))
  (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 71 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_tail *xs)))))

(define/pow
  (firstOrDefault [xs : (List Integer)] [default : Integer])
  #:returns Integer
  (thsl-src-control! "example/learn/lesson35-list-decomposition.tesl" 75 (list (cons 'xs *xs) (cons 'default *default)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_List_head *xs))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 76 (list) (lambda () *default))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([h (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 77 (list (cons 'h h)) (lambda () *h)))])))))

(define/pow
  (addInt [acc : Integer] [x : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 104 (list (cons 'acc *acc) (cons 'x *x)) (lambda () (+ *acc *x))))

(define/pow
  (mulInt [acc : Integer] [x : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 107 (list (cons 'acc *acc) (cons 'x *x)) (lambda () (* *acc *x))))

(define/pow
  (countInt [acc : Integer] [_x : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 110 (list (cons 'acc *acc) (cons '_x *_x)) (lambda () (+ *acc 1))))

(define/pow
  (sumRecursive [ns : (List Integer)])
  #:returns Integer
  (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 114 (list (cons 'ns *ns)) (lambda () (raw-value (tesl_import_List_foldl addInt 0 *ns)))))

(define/pow
  (productRecursive [ns : (List Integer)])
  #:returns Integer
  (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 118 (list (cons 'ns *ns)) (lambda () (raw-value (tesl_import_List_foldl mulInt 1 *ns)))))

(define/pow
  (myLength [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 122 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_foldl countInt 0 *xs)))))

(define/pow
  (prependInt [x : Integer] [acc : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 149 (list (cons 'x *x) (cons 'acc *acc)) (lambda () (raw-value (tesl_import_List_append (list *x) *acc)))))

(define/pow
  (myReverse [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 153 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-1 [acc : (List Integer)] [x : Integer]) #:returns Any (tesl_import_List_append (list *x) *acc)) tesl-lambda-1) (list) *xs)))))

(define/pow
  (increment [x : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 168 (list (cons 'x *x)) (lambda () (+ *x 1))))

(define/pow
  (isPositive [x : Integer])
  #:returns Boolean
  (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 171 (list (cons 'x *x)) (lambda () (> *x 0))))

(define/pow
  (mapIncrement [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 175 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_map increment *xs)))))

(define/pow
  (keepPositive [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 179 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_filter isPositive *xs)))))

(define/pow
  (addPair [acc : Integer] [x : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 198 (list (cons 'acc *acc) (cons 'x *x)) (lambda () (+ *acc *x))))

(define/pow
  (pairHeads [xs : (List Integer)] [ys : (List Integer)])
  #:returns (Maybe Integer)
  (thsl-src-control! "example/learn/lesson35-list-decomposition.tesl" 202 (list (cons 'xs *xs) (cons 'ys *ys)) (lambda () (let ([tesl-case-2 (raw-value (tesl_import_List_head *xs))]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 203 (list) (lambda () (raw-value Nothing)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([hx (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 205 (list (cons 'hx hx)) (lambda () (let ([tesl-case-3 (raw-value (tesl_import_List_head *ys))]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 206 (list) (lambda () (raw-value Nothing)))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([hy (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 207 (list (cons 'hy hy)) (lambda () (raw-value (raw-value (Something (+ *hx *hy)))))))])))))])))))

(define/pow
  (zipWith [xs : (List Integer)] [ys : (List Integer)])
  #:returns (List Integer)
  (let ([pairs (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 217 (list (cons 'xs *xs) (cons 'ys *ys)) (lambda () (raw-value (tesl_import_List_zip *xs *ys))))]) (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 218 (list (cons 'pairs *pairs) (cons 'xs *xs) (cons 'ys *ys)) (lambda () (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-4 [p : (Tuple2 Integer Integer)]) #:returns Integer (+ (raw-value (tesl_import_Tuple2_first *p)) (raw-value (tesl_import_Tuple2_second *p)))) tesl-lambda-4) (raw-value pairs)))))))

(define/pow
  (splitAt [xs : (List Integer)] [n : Integer])
  #:returns (List Integer)
  (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 228 (list (cons 'xs *xs) (cons 'n *n)) (lambda () (let/check ([tesl-checked-5 (tesl_import_Int_nonNegative n)]) (let ([safeN tesl-checked-5]) (raw-value (tesl_import_List_take safeN *xs)))))))

(define/pow
  (chunksOf [xs : (List Integer)] [n : Integer])
  #:returns (List (List Integer))
  (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 234 (list (cons 'xs *xs) (cons 'n *n)) (lambda () (let/check ([tesl-checked-6 (tesl_import_Int_nonNegative n)]) (let ([safeN tesl-checked-6]) (let ([len (raw-value (tesl_import_List_length *xs))]) (if (tesl-equal? (raw-value len) 0) (raw-value (list)) (let ([chunk (tesl_import_List_take safeN *xs)]) (let ([rest (tesl_import_List_drop safeN *xs)]) (if (< (raw-value (tesl_import_List_length (raw-value chunk))) (raw-value safeN)) (raw-value (list)) (if (raw-value (tesl_import_List_isEmpty (raw-value rest))) (raw-value (list *chunk)) (raw-value (tesl_import_List_append (list *chunk) (raw-value (chunksOf rest n)))))))))))))))

(define/pow
  (describeList [xs : (List Integer)])
  #:returns String
  (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 267 (list (cons 'xs *xs)) (lambda () (if (raw-value (tesl_import_List_isEmpty *xs)) (raw-value "empty") (let ([tesl-case-7 (raw-value (tesl_import_List_tail *xs))]) (cond [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Nothing)) (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 271 (list) (lambda () (raw-value "one element")))] [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Something)) (let ([rest (hash-ref (adt-value-fields *tesl-case-7) 'value)]) (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 273 (list (cons 'rest rest)) (lambda () (if (raw-value (tesl_import_List_isEmpty *rest)) (raw-value "one element") (let ([tesl-case-8 (raw-value (tesl_import_List_tail *rest))]) (cond [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Nothing)) (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 277 (list) (lambda () (raw-value "exactly two elements")))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Something)) (let ([rest2 (hash-ref (adt-value-fields *tesl-case-8) 'value)]) (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 279 (list (cons 'rest2 rest2)) (lambda () (if (raw-value (tesl_import_List_isEmpty *rest2)) (raw-value "exactly two elements") (raw-value "three or more elements")))))]))))))]))))))

(module+ test
  (require rackunit)
  (test-case "safeHead"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 80 (list) (lambda () (safeHead (list 10 20 30))))) (raw-value (Something 10)))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 81 (list) (lambda () (safeHead (list))))) Nothing)
    ))
  )

  (test-case "safeTail"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 85 (list) (lambda () (safeTail (list 10 20 30))))) (raw-value (Something (list 20 30))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 86 (list) (lambda () (safeTail (list 42))))) (raw-value (Something (list))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 87 (list) (lambda () (safeTail (list))))) Nothing)
    ))
  )

  (test-case "firstOrDefault"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 91 (list) (lambda () (firstOrDefault (list 5 6 7) 99)))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 92 (list) (lambda () (firstOrDefault (list) 99)))) 99)
    ))
  )

  (test-case "sumRecursive"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 125 (list) (lambda () (sumRecursive (list 1 2 3 4))))) 10)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 126 (list) (lambda () (sumRecursive (list))))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 127 (list) (lambda () (sumRecursive (list 5))))) 5)
    ))
  )

  (test-case "productRecursive"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 131 (list) (lambda () (productRecursive (list 2 3 4))))) 24)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 132 (list) (lambda () (productRecursive (list))))) 1)
    ))
  )

  (test-case "myLength"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 136 (list) (lambda () (myLength (list 1 2 3))))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 137 (list) (lambda () (myLength (list))))) 0)
    ))
  )

  (test-case "myReverse"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 156 (list) (lambda () (myReverse (list 1 2 3))))) (list 3 2 1))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 157 (list) (lambda () (myReverse (list))))) (list))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 158 (list) (lambda () (myReverse (list 42))))) (list 42))
    ))
  )

  (test-case "mapIncrement"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 182 (list) (lambda () (mapIncrement (list 1 2 3))))) (list 2 3 4))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 183 (list) (lambda () (mapIncrement (list))))) (list))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 184 (list) (lambda () (mapIncrement (list -1 0 1))))) (list 0 1 2))
    ))
  )

  (test-case "keepPositive"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 188 (list) (lambda () (keepPositive (list -2 -1 0 1 2))))) (list 1 2))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 189 (list) (lambda () (keepPositive (list))))) (list))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 190 (list) (lambda () (keepPositive (list 1 2 3))))) (list 1 2 3))
    ))
  )

  (test-case "pairHeads"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 210 (list) (lambda () (pairHeads (list 10 20) (list 1 2))))) (raw-value (Something 11)))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 211 (list) (lambda () (pairHeads (list) (list 1 2))))) Nothing)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 212 (list) (lambda () (pairHeads (list 10) (list))))) Nothing)
    ))
  )

  (test-case "splitAt"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 249 (list) (lambda () (splitAt (list 1 2 3 4 5) 3)))) (list 1 2 3))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 250 (list) (lambda () (splitAt (list 1 2) 10)))) (list 1 2))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 251 (list) (lambda () (splitAt (list) 3)))) (list))
    ))
  )

  (test-case "chunksOf"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 255 (list) (lambda () (chunksOf (list 1 2 3 4 5 6) 2)))) (list (list 1 2) (list 3 4) (list 5 6)))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 256 (list) (lambda () (chunksOf (list 1 2 3) 2)))) (list (list 1 2)))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 257 (list) (lambda () (chunksOf (list) 3)))) (list))
    ))
  )

  (test-case "describeList"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 285 (list) (lambda () (describeList (list))))) "empty")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 286 (list) (lambda () (describeList (list 1))))) "one element")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 287 (list) (lambda () (describeList (list 1 2))))) "exactly two elements")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 288 (list) (lambda () (describeList (list 1 2 3))))) "three or more elements")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson35-list-decomposition.tesl" 289 (list) (lambda () (describeList (list 1 2 3 4 5))))) "three or more elements")
    ))
  )

)
