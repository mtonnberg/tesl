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
  (only-in tesl/tesl/prelude Bool Int String List)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/string [String.startsWith tesl_import_String_startsWith] [String.length tesl_import_String_length] [String.isEmpty tesl_import_String_isEmpty] [String.toInt tesl_import_String_toInt])
  (only-in tesl/tesl/int [Int.nonNegative tesl_import_Int_nonNegative] IsNonNegative)
  (only-in tesl/tesl/list [List.map tesl_import_List_map] [List.filter tesl_import_List_filter] [List.concatMap tesl_import_List_concatMap] [List.filterMap tesl_import_List_filterMap] [List.foldl tesl_import_List_foldl] [List.append tesl_import_List_append] [List.concat tesl_import_List_concat] [List.reverse tesl_import_List_reverse] [List.unique tesl_import_List_unique] [List.zip tesl_import_List_zip] [List.range tesl_import_List_range] [List.repeat tesl_import_List_repeat] [List.length tesl_import_List_length] [List.isEmpty tesl_import_List_isEmpty] [List.head tesl_import_List_head] [List.any tesl_import_List_any] [List.all tesl_import_List_all] [List.find tesl_import_List_find] [List.member tesl_import_List_member] [List.sum tesl_import_List_sum] [List.maximum tesl_import_List_maximum] [List.minimum tesl_import_List_minimum] [List.take tesl_import_List_take] [List.drop tesl_import_List_drop] [List.sort tesl_import_List_sort] [List.sortBy tesl_import_List_sortBy] IsSorted)
  (only-in tesl/tesl/tuple Tuple2)
)


(provide doubleAll keepPositive total flattenTags hasAdmin findFirst groupByPrefix zipPairs buildRange doubleAll-signature keepPositive-signature flattenTags-signature total-signature hasAdmin-signature findFirst-signature zipPairs-signature buildRange-signature groupByPrefix-signature)

(define/pow
  (doubleAll [ns : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-0 [n : Integer]) #:returns Integer (* *n 2)) tesl-lambda-0) *ns)))

(define/pow
  (toUpperLength [words : (List String)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_map tesl_import_String_length *words)))

(define/pow
  (keepPositive [ns : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_filter (let () (define/pow (tesl-lambda-1 [n : Integer]) #:returns Boolean (> *n 0)) tesl-lambda-1) *ns)))

(define/pow
  (shortWords [words : (List String)])
  #:returns (List String)
  (raw-value (tesl_import_List_filter (let () (define/pow (tesl-lambda-2 [w : String]) #:returns Boolean (<= (raw-value (tesl_import_String_length *w)) 4)) tesl-lambda-2) *words)))

(define/pow
  (neighbours [ns : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_concatMap (let () (define/pow (tesl-lambda-3 [n : Integer]) #:returns Any (list (- *n 1) (+ *n 1))) tesl-lambda-3) *ns)))

(define/pow
  (flattenTags [tagGroups : (List String)])
  #:returns (List String)
  (raw-value (tesl_import_List_concatMap (let () (define/pow (tesl-lambda-4 [s : String]) #:returns Any (if (tesl_import_String_isEmpty *s) (list) (list *s))) tesl-lambda-4) *tagGroups)))

(define/pow
  (parseInts [strs : (List String)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_filterMap (let () (define/pow (tesl-lambda-5 [s : String]) #:returns Any (let ([tesl_case_6 (raw-value (tesl_import_String_toInt *s))]) (cond [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Something)) (let ([n (hash-ref (adt-value-fields *tesl_case_6) 'value)]) (raw-value (Something *n)))] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Nothing)) Nothing]))) tesl-lambda-5) *strs)))

(define/pow
  (total [ns : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-7 [acc : Integer] [n : Integer]) #:returns Integer (+ *acc *n)) tesl-lambda-7) 0 *ns)))

(define/pow
  (joinWords [words : (List String)])
  #:returns String
  (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-8 [acc : String] [w : String]) #:returns String (if (tesl_import_String_isEmpty *acc) *w (format "~a ~a" (tesl-display-val *acc) (tesl-display-val *w)))) tesl-lambda-8) "" *words)))

(define/pow
  (hasAdmin [roles : (List String)])
  #:returns Boolean
  (raw-value (tesl_import_List_member "admin" *roles)))

(define/pow
  (allPositive [ns : (List Integer)])
  #:returns Boolean
  (raw-value (tesl_import_List_all (let () (define/pow (tesl-lambda-9 [n : Integer]) #:returns Boolean (> *n 0)) tesl-lambda-9) *ns)))

(define/pow
  (anyNegative [ns : (List Integer)])
  #:returns Boolean
  (raw-value (tesl_import_List_any (let () (define/pow (tesl-lambda-10 [n : Integer]) #:returns Boolean (< *n 0)) tesl-lambda-10) *ns)))

(define/pow
  (findFirst [ns : (List Integer)] [threshold : Integer])
  #:returns (Maybe Integer)
  (raw-value (tesl_import_List_find (let () (define/pow (tesl-lambda-11 [n : Integer]) #:returns Boolean (> *n *threshold)) tesl-lambda-11) *ns)))

(define/pow
  (dedup [ns : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_unique *ns)))

(define/pow
  (zipPairs [names : (List String)] [scores : (List Integer)])
  #:returns (List (Tuple2 String Integer))
  (raw-value (tesl_import_List_zip *names *scores)))

(define/pow
  (buildRange [start : Integer] [count : Integer])
  #:returns (List Integer)
  (let/check ([tesl_checked_12 (tesl_import_Int_nonNegative count)]) (let ([safeCount tesl_checked_12]) (raw-value (tesl_import_List_take safeCount (raw-value (tesl_import_List_range *start (+ *start *count))))))))

(define/pow
  (fillWith [value : Integer] [n : Integer])
  #:returns (List Integer)
  (let/check ([tesl_checked_13 (tesl_import_Int_nonNegative n)]) (let ([safeN tesl_checked_13]) (raw-value (tesl_import_List_repeat *value safeN)))))

(define/pow
  (firstThree [ns : (List Integer)])
  #:returns (List Integer)
  (let ([raw3 3]) (let/check ([tesl_checked_14 (tesl_import_Int_nonNegative raw3)]) (let ([n3 tesl_checked_14]) (raw-value (tesl_import_List_take n3 *ns))))))

(define/pow
  (skipFirst [ns : (List Integer)] [n : Integer])
  #:returns (List Integer)
  (let/check ([tesl_checked_15 (tesl_import_Int_nonNegative n)]) (let ([safeN tesl_checked_15]) (raw-value (tesl_import_List_drop safeN *ns)))))

(define/pow
  (sortInts [ns : (List Integer)])
  #:returns (? (List Integer) _entity ::: (IsSorted _entity))
  (tesl_import_List_sort *ns))

(define/pow
  (sortByLength [words : (List String)])
  #:returns (List String)
  (raw-value (tesl_import_List_sortBy tesl_import_String_length *words)))

(define/pow
  (highestScore [scores : (List Integer)])
  #:returns (Maybe Integer)
  (raw-value (tesl_import_List_maximum *scores)))

(define/pow
  (lowestPrice [prices : (List Integer)])
  #:returns (Maybe Integer)
  (raw-value (tesl_import_List_minimum *prices)))

(define/pow
  (reversed [ns : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_reverse *ns)))

(define/pow
  (merged [a : (List Integer)] [b : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_append *a *b)))

(define/pow
  (flatten [xss : (List (List Integer))])
  #:returns (List Integer)
  (raw-value (tesl_import_List_concat *xss)))

(define/pow
  (groupByPrefix [words : (List String)] [prefix : String])
  #:returns (List String)
  (raw-value (tesl_import_List_filter (let () (define/pow (tesl-lambda-16 [w : String]) #:returns Boolean (tesl_import_String_startsWith *w *prefix)) tesl-lambda-16) *words)))

(define/pow
  (topPositive [strs : (List String)])
  #:returns (List Integer)
  (let ([pos (keepPositive (parseInts strs))]) (raw-value (firstThree (tesl_import_List_reverse (raw-value (tesl_import_List_sort (raw-value pos))))))))

(module+ test
  (require rackunit)
  (test-case "List.map doubles all elements"
  (check-equal? (raw-value (doubleAll (list 1 2 3))) (list 2 4 6))
  )

  (test-case "List.map works on empty list"
  (check-equal? (raw-value (doubleAll (list))) (list))
  )

  (test-case "List.map with named function (String.length)"
  (check-equal? (raw-value (toUpperLength (list "hi" "hello"))) (list 2 5))
  )

  (test-case "List.filter keeps only positives"
  (check-equal? (raw-value (keepPositive (list -2 0 1 3 -1))) (list 1 3))
  )

  (test-case "List.filter short words"
  (check-equal? (raw-value (shortWords (list "hi" "hello" "fig"))) (list "hi" "fig"))
  )

  (test-case "List.concatMap expands each element"
  (check-equal? (raw-value (neighbours (list 10 20))) (list 9 11 19 21))
  )

  (test-case "List.concatMap on empty list"
  (check-equal? (raw-value (neighbours (list))) (list))
  )

  (test-case "List.concatMap drops empty-result elements"
  (check-equal? (raw-value (flattenTags (list "rust" "" "go" ""))) (list "rust" "go"))
  )

  (test-case "List.filterMap skips Nothings"
  (check-equal? (raw-value (parseInts (list "1" "x" "3" ""))) (list 1 3))
  )

  (test-case "List.filterMap on all non-numbers"
  (check-equal? (raw-value (parseInts (list "a" "b"))) (list))
  )

  (test-case "List.foldl sums a list"
  (check-equal? (raw-value (total (list 1 2 3 4))) 10)
  (check-equal? (raw-value (total (list))) 0)
  )

  (test-case "List.foldl join words"
  (check-equal? (raw-value (joinWords (list "hello" "world"))) "hello world")
  (check-equal? (raw-value (joinWords (list))) "")
  )

  (test-case "List.member returns True when present"
  (check-equal? (raw-value (hasAdmin (list "editor" "admin" "viewer"))) #t)
  )

  (test-case "List.member returns False when absent"
  (check-equal? (raw-value (hasAdmin (list "editor" "viewer"))) #f)
  )

  (test-case "List.any finds a negative"
  (check-equal? (raw-value (anyNegative (list 1 -1 2))) #t)
  (check-equal? (raw-value (anyNegative (list 1 2 3))) #f)
  )

  (test-case "List.all checks every element"
  (check-equal? (raw-value (allPositive (list 1 2 3))) #t)
  (check-equal? (raw-value (allPositive (list 1 -1 3))) #f)
  )

  (test-case "List.find returns first match"
  (check-equal? (raw-value (findFirst (list 1 5 10 20) 8)) (raw-value (Something 10)))
  )

  (test-case "List.find returns Nothing when no match"
  (check-equal? (raw-value (findFirst (list 1 2 3) 100)) Nothing)
  )

  (test-case "List.unique removes duplicates"
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value (dedup (list 1 2 1 3 2)))))) 3)
  )

  (test-case "List.zip pairs elements"
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value (zipPairs (list "alice" "bob") (list 90 80)))))) 2)
  )

  (test-case "List.zip stops at shorter list"
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value (tesl_import_List_zip (list 1 2 3) (list "a" "b")))))) 2)
  )

  (test-case "List.range builds integers"
  (check-equal? (raw-value (buildRange 1 5)) (list 1 2 3 4 5))
  )

  (test-case "List.repeat fills a list"
  (check-equal? (raw-value (fillWith 0 4)) (list 0 0 0 0))
  )

  (test-case "List.take limits list length"
  (check-equal? (raw-value (firstThree (list 10 20 30 40))) (list 10 20 30))
  (check-equal? (raw-value (firstThree (list 1 2))) (list 1 2))
  )

  (test-case "List.drop skips elements"
  (check-equal? (raw-value (skipFirst (list 1 2 3 4) 2)) (list 3 4))
  (check-equal? (raw-value (skipFirst (list 1 2) 5)) (list))
  )

  (test-case "List.sort ascending"
  (check-equal? (raw-value (sortInts (list 3 1 2))) (list 1 2 3))
  )

  (test-case "List.sortBy key function"
  (check-equal? (raw-value (raw-value (tesl_import_List_head (raw-value (sortByLength (list "banana" "fig" "apple")))))) (raw-value (Something "fig")))
  )

  (test-case "List.maximum and minimum"
  (check-equal? (raw-value (highestScore (list 3 7 2))) (raw-value (Something 7)))
  (check-equal? (raw-value (lowestPrice (list 5 1 9))) (raw-value (Something 1)))
  (check-equal? (raw-value (highestScore (list))) Nothing)
  )

  (test-case "List.sum"
  (check-equal? (raw-value (raw-value (tesl_import_List_sum (list 1 2 3 4 5)))) 15)
  (check-equal? (raw-value (raw-value (tesl_import_List_sum (list)))) 0)
  )

  (test-case "List.reverse"
  (check-equal? (raw-value (reversed (list 1 2 3))) (list 3 2 1))
  (check-equal? (raw-value (reversed (list))) (list))
  )

  (test-case "List.append merges lists"
  (check-equal? (raw-value (merged (list 1 2) (list 3 4))) (list 1 2 3 4))
  )

  (test-case "List.concat flattens one level"
  (check-equal? (raw-value (flatten (list (list 1 2) (list 3) (list 4 5)))) (list 1 2 3 4 5))
  )

  (test-case "List.isEmpty"
  (check-equal? (raw-value (raw-value (tesl_import_List_isEmpty (list)))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_List_isEmpty (list 1)))) #f)
  )

  (test-case "List.head and tail"
  (check-equal? (raw-value (raw-value (tesl_import_List_head (list 10 20 30)))) (raw-value (Something 10)))
  (check-equal? (raw-value (raw-value (tesl_import_List_head (list)))) Nothing)
  )

  (test-case "groupByPrefix filters by start"
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value (groupByPrefix (list "apple" "apricot" "banana" "avocado") "a"))))) 3)
  )

  (test-case "topPositive pipeline end-to-end"
  (check-equal? (raw-value (topPositive (list "3" "x" "1" "9" "-2" "5"))) (list 9 5 3))
  )

)
