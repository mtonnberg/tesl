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
  (raw-value (tesl_import_List_head *xs)))

(define/pow
  (safeTail [xs : (List Integer)])
  #:returns (Maybe (List Integer))
  (raw-value (tesl_import_List_tail *xs)))

(define/pow
  (firstOrDefault [xs : (List Integer)] [default : Integer])
  #:returns Integer
  (let ([tesl_case_0 (raw-value (tesl_import_List_head *xs))]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) *default] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (let ([h (hash-ref (adt-value-fields *tesl_case_0) 'value)]) *h)])))

(define/pow
  (addInt [acc : Integer] [x : Integer])
  #:returns Integer
  (+ *acc *x))

(define/pow
  (mulInt [acc : Integer] [x : Integer])
  #:returns Integer
  (* *acc *x))

(define/pow
  (countInt [acc : Integer] [_x : Integer])
  #:returns Integer
  (+ *acc 1))

(define/pow
  (sumRecursive [ns : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_foldl addInt 0 *ns)))

(define/pow
  (productRecursive [ns : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_foldl mulInt 1 *ns)))

(define/pow
  (myLength [xs : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_foldl countInt 0 *xs)))

(define/pow
  (prependInt [x : Integer] [acc : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_append (list *x) *acc)))

(define/pow
  (myReverse [xs : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-1 [acc : (List Integer)] [x : Integer]) #:returns Any (tesl_import_List_append (list *x) *acc)) tesl-lambda-1) (list) *xs)))

(define/pow
  (increment [x : Integer])
  #:returns Integer
  (+ *x 1))

(define/pow
  (isPositive [x : Integer])
  #:returns Boolean
  (> *x 0))

(define/pow
  (mapIncrement [xs : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_map increment *xs)))

(define/pow
  (keepPositive [xs : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_filter isPositive *xs)))

(define/pow
  (addPair [acc : Integer] [x : Integer])
  #:returns Integer
  (+ *acc *x))

(define/pow
  (pairHeads [xs : (List Integer)] [ys : (List Integer)])
  #:returns (Maybe Integer)
  (let ([tesl_case_2 (raw-value (tesl_import_List_head *xs))]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Nothing)) (raw-value Nothing)] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Something)) (let ([hx (hash-ref (adt-value-fields *tesl_case_2) 'value)]) (let ([tesl_case_3 (raw-value (tesl_import_List_head *ys))]) (cond [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Nothing)) (raw-value Nothing)] [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Something)) (let ([hy (hash-ref (adt-value-fields *tesl_case_3) 'value)]) (raw-value (raw-value (Something (+ *hx *hy)))))])))])))

(define/pow
  (zipWith [xs : (List Integer)] [ys : (List Integer)])
  #:returns (List Integer)
  (let ([pairs (raw-value (tesl_import_List_zip *xs *ys))]) (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-4 [p : (Tuple2 Integer Integer)]) #:returns Integer (+ (raw-value (tesl_import_Tuple2_first *p)) (raw-value (tesl_import_Tuple2_second *p)))) tesl-lambda-4) (raw-value pairs)))))

(define/pow
  (splitAt [xs : (List Integer)] [n : Integer])
  #:returns (List Integer)
  (let/check ([tesl_checked_5 (tesl_import_Int_nonNegative n)]) (let ([safeN tesl_checked_5]) (raw-value (tesl_import_List_take safeN *xs)))))

(define/pow
  (chunksOf [xs : (List Integer)] [n : Integer])
  #:returns (List (List Integer))
  (let/check ([tesl_checked_6 (tesl_import_Int_nonNegative n)]) (let ([safeN tesl_checked_6]) (let ([len (raw-value (tesl_import_List_length *xs))]) (if (equal? (raw-value len) 0) (raw-value (list)) (let ([chunk (tesl_import_List_take safeN *xs)]) (let ([rest (tesl_import_List_drop safeN *xs)]) (if (< (raw-value (tesl_import_List_length (raw-value chunk))) (raw-value safeN)) (raw-value (list)) (if (raw-value (tesl_import_List_isEmpty (raw-value rest))) (raw-value (list *chunk)) (raw-value (tesl_import_List_append (list *chunk) (raw-value (chunksOf rest n)))))))))))))

(define/pow
  (describeList [xs : (List Integer)])
  #:returns String
  (if (raw-value (tesl_import_List_isEmpty *xs)) (raw-value "empty") (let ([tesl_case_7 (raw-value (tesl_import_List_tail *xs))]) (cond [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Nothing)) (raw-value "one element")] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Something)) (let ([rest (hash-ref (adt-value-fields *tesl_case_7) 'value)]) (if (raw-value (tesl_import_List_isEmpty *rest)) (raw-value "one element") (let ([tesl_case_8 (raw-value (tesl_import_List_tail *rest))]) (cond [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Nothing)) (raw-value "exactly two elements")] [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Something)) (let ([rest2 (hash-ref (adt-value-fields *tesl_case_8) 'value)]) (if (raw-value (tesl_import_List_isEmpty *rest2)) (raw-value "exactly two elements") (raw-value "three or more elements")))]))))]))))

(module+ test
  (require rackunit)
  (test-case "safeHead"
  (check-equal? (raw-value (safeHead (list 10 20 30))) (raw-value (Something 10)))
  (check-equal? (raw-value (safeHead (list))) Nothing)
  )

  (test-case "safeTail"
  (check-equal? (raw-value (safeTail (list 10 20 30))) (raw-value (Something (list 20 30))))
  (check-equal? (raw-value (safeTail (list 42))) (raw-value (Something (list))))
  (check-equal? (raw-value (safeTail (list))) Nothing)
  )

  (test-case "firstOrDefault"
  (check-equal? (raw-value (firstOrDefault (list 5 6 7) 99)) 5)
  (check-equal? (raw-value (firstOrDefault (list) 99)) 99)
  )

  (test-case "sumRecursive"
  (check-equal? (raw-value (sumRecursive (list 1 2 3 4))) 10)
  (check-equal? (raw-value (sumRecursive (list))) 0)
  (check-equal? (raw-value (sumRecursive (list 5))) 5)
  )

  (test-case "productRecursive"
  (check-equal? (raw-value (productRecursive (list 2 3 4))) 24)
  (check-equal? (raw-value (productRecursive (list))) 1)
  )

  (test-case "myLength"
  (check-equal? (raw-value (myLength (list 1 2 3))) 3)
  (check-equal? (raw-value (myLength (list))) 0)
  )

  (test-case "myReverse"
  (check-equal? (raw-value (myReverse (list 1 2 3))) (list 3 2 1))
  (check-equal? (raw-value (myReverse (list))) (list))
  (check-equal? (raw-value (myReverse (list 42))) (list 42))
  )

  (test-case "mapIncrement"
  (check-equal? (raw-value (mapIncrement (list 1 2 3))) (list 2 3 4))
  (check-equal? (raw-value (mapIncrement (list))) (list))
  (check-equal? (raw-value (mapIncrement (list -1 0 1))) (list 0 1 2))
  )

  (test-case "keepPositive"
  (check-equal? (raw-value (keepPositive (list -2 -1 0 1 2))) (list 1 2))
  (check-equal? (raw-value (keepPositive (list))) (list))
  (check-equal? (raw-value (keepPositive (list 1 2 3))) (list 1 2 3))
  )

  (test-case "pairHeads"
  (check-equal? (raw-value (pairHeads (list 10 20) (list 1 2))) (raw-value (Something 11)))
  (check-equal? (raw-value (pairHeads (list) (list 1 2))) Nothing)
  (check-equal? (raw-value (pairHeads (list 10) (list))) Nothing)
  )

  (test-case "splitAt"
  (check-equal? (raw-value (splitAt (list 1 2 3 4 5) 3)) (list 1 2 3))
  (check-equal? (raw-value (splitAt (list 1 2) 10)) (list 1 2))
  (check-equal? (raw-value (splitAt (list) 3)) (list))
  )

  (test-case "chunksOf"
  (check-equal? (raw-value (chunksOf (list 1 2 3 4 5 6) 2)) (list (list 1 2) (list 3 4) (list 5 6)))
  (check-equal? (raw-value (chunksOf (list 1 2 3) 2)) (list (list 1 2)))
  (check-equal? (raw-value (chunksOf (list) 3)) (list))
  )

  (test-case "describeList"
  (check-equal? (raw-value (describeList (list))) "empty")
  (check-equal? (raw-value (describeList (list 1))) "one element")
  (check-equal? (raw-value (describeList (list 1 2))) "exactly two elements")
  (check-equal? (raw-value (describeList (list 1 2 3))) "three or more elements")
  (check-equal? (raw-value (describeList (list 1 2 3 4 5))) "three or more elements")
  )

)
