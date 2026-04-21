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
  (only-in tesl/tesl/list [List.map tesl_import_List_map] [List.filter tesl_import_List_filter] [List.foldl tesl_import_List_foldl] [List.length tesl_import_List_length] [List.all tesl_import_List_all])
  (only-in tesl/tesl/string [String.isEmpty tesl_import_String_isEmpty] [String.length tesl_import_String_length])
)


(provide applyTwice applyToList makeAdder makeMultiplier makeGreeter pipeline processList countMatching transformAndFilter buildMessages validateAll applyTwice-signature applyToList-signature makeAdder-signature makeMultiplier-signature makeGreeter-signature pipeline-signature processList-signature countMatching-signature transformAndFilter-signature buildMessages-signature validateAll-signature)

(define/pow
  (applyTwice [f : (-> Integer Integer)] [n : Integer])
  #:returns Integer
  (raw-value (f (f n))))

(define/pow
  (applyToList [xs : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-0 [x : Integer]) #:returns Integer (+ *x 10)) tesl-lambda-0) *xs)))

(define/pow
  (makeAdder [n : Integer])
  #:returns (-> Integer Integer)
  (let () (define/pow (tesl-lambda-1 [x : Integer]) #:returns Integer (+ *x *n)) tesl-lambda-1))

(define/pow
  (makeMultiplier [factor : Integer])
  #:returns (-> Integer Integer)
  (let () (define/pow (tesl-lambda-2 [x : Integer]) #:returns Integer (* *x *factor)) tesl-lambda-2))

(define/pow
  (makeGreeter [prefix : String])
  #:returns (-> String String)
  (let () (define/pow (tesl-lambda-3 [name : String]) #:returns String (format "~a, ~a!" (tesl-display-val *prefix) (tesl-display-val *name))) tesl-lambda-3))

(define/pow
  (double [n : Integer])
  #:returns Integer
  (* *n 2))

(define/pow
  (addOne [n : Integer])
  #:returns Integer
  (+ *n 1))

(define/pow
  (pipeline [n : Integer])
  #:returns Integer
  ((let () (define/pow (tesl-lambda-4 [x : Integer]) #:returns Integer (* *x 3)) tesl-lambda-4) (addOne (double n))))

(define/pow
  (processList [xs : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_filter (let () (define/pow (tesl-lambda-5 [x : Integer]) #:returns Boolean (> *x 0)) tesl-lambda-5) (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-6 [x : Integer]) #:returns Integer (- 0 *x)) tesl-lambda-6) *xs)))))

(define/pow
  (countMatching [xs : (List Integer)] [threshold : Integer])
  #:returns Integer
  (raw-value (tesl_import_List_length (raw-value (tesl_import_List_filter (let () (define/pow (tesl-lambda-7 [x : Integer]) #:returns Boolean (> *x *threshold)) tesl-lambda-7) *xs)))))

(define/pow
  (transformAndFilter [xs : (List Integer)])
  #:returns (List Integer)
  (let ([doubled (tesl_import_List_map (let () (define/pow (tesl-lambda-8 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-8) *xs)]) (raw-value (tesl_import_List_filter (let () (define/pow (tesl-lambda-9 [x : Integer]) #:returns Boolean (> *x 10)) tesl-lambda-9) (raw-value doubled)))))

(define/pow
  (buildMessages [numbers : (List Integer)] [prefix : String])
  #:returns (List String)
  (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-10 [n : Integer]) #:returns String (format "~a: ~a" (tesl-display-val *prefix) (tesl-display-val *n))) tesl-lambda-10) *numbers)))

(define/pow
  (addIfAbove [min : Integer] [acc : Integer] [x : Integer])
  #:returns Integer
  (if (> *x *min) (raw-value (+ *acc *x)) *acc))

(define/pow
  (sumAbove [xs : (List Integer)] [min : Integer])
  #:returns Integer
  (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-11 [acc : Integer] [x : Integer]) #:returns Integer (addIfAbove min acc x)) tesl-lambda-11) 0 *xs)))

(define/pow
  (isNonEmpty [s : String])
  #:returns Boolean
  (equal? (raw-value (tesl_import_String_isEmpty *s)) #f))

(define/pow
  (isShortEnough [s : String])
  #:returns Boolean
  (<= (raw-value (tesl_import_String_length *s)) 50))

(define/pow
  (validateAll [xs : (List String)])
  #:returns Boolean
  (raw-value (tesl_import_List_all (let () (define/pow (tesl-lambda-12 [s : String]) #:returns Boolean (and (raw-value (isNonEmpty s)) (raw-value (isShortEnough s)))) tesl-lambda-12) *xs)))

(module+ test
  (require rackunit)
  (test-case "applyTwice"
  (check-equal? (raw-value (applyTwice (let () (define/pow (tesl-lambda-13 [x : Integer]) #:returns Integer (+ *x 1)) tesl-lambda-13) 5)) 7)
  (check-equal? (raw-value (applyTwice (let () (define/pow (tesl-lambda-14 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-14) 3)) 12)
  )

  (test-case "applyToList"
  (check-equal? (raw-value (applyToList (list 1 2 3))) (list 11 12 13))
  (check-equal? (raw-value (applyToList (list))) (list))
  )

  (test-case "makeAdder"
  (define addFive (makeAdder 5))
  (check-equal? (raw-value (addFive 3)) 8)
  (check-equal? (raw-value (addFive 0)) 5)
  (check-equal? (raw-value (addFive -5)) 0)
  )

  (test-case "makeMultiplier"
  (define triple (makeMultiplier 3))
  (check-equal? (raw-value (triple 4)) 12)
  (check-equal? (raw-value (triple 0)) 0)
  )

  (test-case "makeGreeter"
  (define hello (makeGreeter "Hello"))
  (define hi (makeGreeter "Hi"))
  (check-equal? (raw-value (hello "Alice")) "Hello, Alice!")
  (check-equal? (raw-value (hi "Bob")) "Hi, Bob!")
  )

  (test-case "pipeline"
  (check-equal? (raw-value (pipeline 5)) 33)
  (check-equal? (raw-value (pipeline 0)) 3)
  (check-equal? (raw-value (pipeline 1)) 9)
  )

  (test-case "processList"
  (check-equal? (raw-value (processList (list -3 -1 0 1 3))) (list 3 1))
  (check-equal? (raw-value (processList (list))) (list))
  (check-equal? (raw-value (processList (list 1 2 3))) (list))
  )

  (test-case "countMatching"
  (check-equal? (raw-value (countMatching (list 1 5 3 8 2) 4)) 2)
  (check-equal? (raw-value (countMatching (list 1 2 3) 10)) 0)
  (check-equal? (raw-value (countMatching (list) 0)) 0)
  )

  (test-case "transformAndFilter"
  (check-equal? (raw-value (transformAndFilter (list 3 5 7 1 9))) (list 14 18))
  (check-equal? (raw-value (transformAndFilter (list))) (list))
  )

  (test-case "buildMessages"
  (check-equal? (raw-value (buildMessages (list 1 2 3) "item")) (list "item: 1" "item: 2" "item: 3"))
  (check-equal? (raw-value (buildMessages (list) "x")) (list))
  )

  (test-case "sumAbove"
  (check-equal? (raw-value (sumAbove (list 1 5 3 8 2) 4)) 13)
  (check-equal? (raw-value (sumAbove (list) 0)) 0)
  (check-equal? (raw-value (sumAbove (list 1 2 3) 10)) 0)
  )

  (test-case "validateAll"
  (check-equal? (raw-value (validateAll (list "hello" "world"))) #t)
  (check-equal? (raw-value (validateAll (list "hello" "" "world"))) #f)
  (check-equal? (raw-value (validateAll (list))) #t)
  )

)
