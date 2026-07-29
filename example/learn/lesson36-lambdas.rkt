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
  (only-in tesl/tesl/list [List.map tesl_import_List_map] [List.filter tesl_import_List_filter] [List.foldl tesl_import_List_foldl] [List.length tesl_import_List_length] [List.all tesl_import_List_all])
  (only-in tesl/tesl/string [String.isEmpty tesl_import_String_isEmpty] [String.length tesl_import_String_length])
)


(provide applyTwice applyToList makeAdder makeMultiplier makeGreeter pipeline processList countMatching transformAndFilter buildMessages validateAll applyTwice-signature applyToList-signature makeAdder-signature makeMultiplier-signature makeGreeter-signature pipeline-signature processList-signature countMatching-signature transformAndFilter-signature buildMessages-signature validateAll-signature)

(define/pow
  (applyTwice [f : (-> Integer Integer)] [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson36-lambdas.tesl" 49 (list (cons 'f *f) (cons 'n *n)) (lambda () (raw-value (f (f n))))))

(define/pow
  (applyToList [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "example/learn/lesson36-lambdas.tesl" 53 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-0 [x : Integer]) #:returns Integer (+ *x 10)) tesl-lambda-0) *xs)))))

(define/pow
  (makeAdder [n : Integer])
  #:returns (-> Integer Integer)
  (thsl-src! "example/learn/lesson36-lambdas.tesl" 73 (list (cons 'n *n)) (lambda () (let () (define/pow (tesl-lambda-1 [x : Integer]) #:returns Integer (+ *x *n)) tesl-lambda-1))))

(define/pow
  (makeMultiplier [factor : Integer])
  #:returns (-> Integer Integer)
  (thsl-src! "example/learn/lesson36-lambdas.tesl" 77 (list (cons 'factor *factor)) (lambda () (let () (define/pow (tesl-lambda-2 [x : Integer]) #:returns Integer (* *x *factor)) tesl-lambda-2))))

(define/pow
  (makeGreeter [prefix : String])
  #:returns (-> String String)
  (thsl-src! "example/learn/lesson36-lambdas.tesl" 81 (list (cons 'prefix *prefix)) (lambda () (let () (define/pow (tesl-lambda-3 [name : String]) #:returns String (format "~a, ~a!" (tesl-display-val *prefix) (tesl-display-val *name))) tesl-lambda-3))))

(define/pow
  (double [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson36-lambdas.tesl" 109 (list (cons 'n *n)) (lambda () (* *n 2))))

(define/pow
  (addOne [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson36-lambdas.tesl" 110 (list (cons 'n *n)) (lambda () (+ *n 1))))

(define/pow
  (pipeline [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson36-lambdas.tesl" 116 (list (cons 'n *n)) (lambda () ((let () (define/pow (tesl-lambda-4 [x : Integer]) #:returns Integer (* *x 3)) tesl-lambda-4) (addOne (double n))))))

(define/pow
  (processList [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "example/learn/lesson36-lambdas.tesl" 135 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_filter (let () (define/pow (tesl-lambda-5 [x : Integer]) #:returns Boolean (> *x 0)) tesl-lambda-5) (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-6 [x : Integer]) #:returns Integer (- 0 *x)) tesl-lambda-6) *xs)))))))

(define/pow
  (countMatching [xs : (List Integer)] [threshold : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson36-lambdas.tesl" 145 (list (cons 'xs *xs) (cons 'threshold *threshold)) (lambda () (raw-value (tesl_import_List_length (raw-value (tesl_import_List_filter (let () (define/pow (tesl-lambda-7 [x : Integer]) #:returns Boolean (> *x *threshold)) tesl-lambda-7) *xs)))))))

(define/pow
  (transformAndFilter [xs : (List Integer)])
  #:returns (List Integer)
  (let ([doubled (thsl-src! "example/learn/lesson36-lambdas.tesl" 155 (list (cons 'xs *xs)) (lambda () (tesl_import_List_map (let () (define/pow (tesl-lambda-8 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-8) *xs)))]) (thsl-src! "example/learn/lesson36-lambdas.tesl" 156 (list (cons 'doubled *doubled) (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_filter (let () (define/pow (tesl-lambda-9 [x : Integer]) #:returns Boolean (> *x 10)) tesl-lambda-9) (raw-value doubled)))))))

(define/pow
  (buildMessages [numbers : (List Integer)] [prefix : String])
  #:returns (List String)
  (thsl-src! "example/learn/lesson36-lambdas.tesl" 171 (list (cons 'numbers *numbers) (cons 'prefix *prefix)) (lambda () (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-10 [n : Integer]) #:returns String (format "~a: ~a" (tesl-display-val *prefix) (tesl-display-val *n))) tesl-lambda-10) *numbers)))))

(define/pow
  (addIfAbove [min : Integer] [acc : Integer] [x : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson36-lambdas.tesl" 180 (list (cons 'min *min) (cons 'acc *acc) (cons 'x *x)) (lambda () (if (> *x *min) (raw-value (+ *acc *x)) *acc))))

(define/pow
  (sumAbove [xs : (List Integer)] [min : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson36-lambdas.tesl" 186 (list (cons 'xs *xs) (cons 'min *min)) (lambda () (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-11 [acc : Integer] [x : Integer]) #:returns Integer (addIfAbove min acc x)) tesl-lambda-11) 0 *xs)))))

(define/pow
  (isNonEmpty [s : String])
  #:returns Boolean
  (thsl-src! "example/learn/lesson36-lambdas.tesl" 200 (list (cons 's *s)) (lambda () (tesl-equal? (raw-value (tesl_import_String_isEmpty *s)) #f))))

(define/pow
  (isShortEnough [s : String])
  #:returns Boolean
  (thsl-src! "example/learn/lesson36-lambdas.tesl" 203 (list (cons 's *s)) (lambda () (<= (raw-value (tesl_import_String_length *s)) 50))))

(define/pow
  (validateAll [xs : (List String)])
  #:returns Boolean
  (thsl-src! "example/learn/lesson36-lambdas.tesl" 207 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_all (let () (define/pow (tesl-lambda-12 [s : String]) #:returns Boolean (and (raw-value (isNonEmpty s)) (raw-value (isShortEnough s)))) tesl-lambda-12) *xs)))))

(module+ test
  (require rackunit)
  (test-case "applyTwice"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 56 (list) (lambda () (applyTwice (let () (define/pow (tesl-lambda-13 [x : Integer]) #:returns Integer (+ *x 1)) tesl-lambda-13) 5)))) 7)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 57 (list) (lambda () (applyTwice (let () (define/pow (tesl-lambda-14 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-14) 3)))) 12)
    ))
  )

  (test-case "applyToList"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 61 (list) (lambda () (applyToList (list 1 2 3))))) (list 11 12 13))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 62 (list) (lambda () (applyToList (list))))) (list))
    ))
  )

  (test-case "makeAdder"
    (call-with-fresh-memory-db '() (lambda ()
  (define addFive (thsl-src! "example/learn/lesson36-lambdas.tesl" 84 (list) (lambda () (makeAdder 5))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 85 (list (cons 'addFive addFive)) (lambda () (addFive 3)))) 8)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 86 (list (cons 'addFive addFive)) (lambda () (addFive 0)))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 87 (list (cons 'addFive addFive)) (lambda () (addFive -5)))) 0)
    ))
  )

  (test-case "makeMultiplier"
    (call-with-fresh-memory-db '() (lambda ()
  (define triple (thsl-src! "example/learn/lesson36-lambdas.tesl" 91 (list) (lambda () (makeMultiplier 3))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 92 (list (cons 'triple triple)) (lambda () (triple 4)))) 12)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 93 (list (cons 'triple triple)) (lambda () (triple 0)))) 0)
    ))
  )

  (test-case "makeGreeter"
    (call-with-fresh-memory-db '() (lambda ()
  (define hello (thsl-src! "example/learn/lesson36-lambdas.tesl" 97 (list) (lambda () (makeGreeter "Hello"))))
  (define hi (thsl-src! "example/learn/lesson36-lambdas.tesl" 98 (list (cons 'hello hello)) (lambda () (makeGreeter "Hi"))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 99 (list (cons 'hi hi) (cons 'hello hello)) (lambda () (hello "Alice")))) "Hello, Alice!")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 100 (list (cons 'hi hi) (cons 'hello hello)) (lambda () (hi "Bob")))) "Hi, Bob!")
    ))
  )

  (test-case "pipeline"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 120 (list) (lambda () (pipeline 5)))) 33)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 121 (list) (lambda () (pipeline 0)))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 122 (list) (lambda () (pipeline 1)))) 9)
    ))
  )

  (test-case "processList"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 138 (list) (lambda () (processList (list -3 -1 0 1 3))))) (list 3 1))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 139 (list) (lambda () (processList (list))))) (list))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 140 (list) (lambda () (processList (list 1 2 3))))) (list))
    ))
  )

  (test-case "countMatching"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 148 (list) (lambda () (countMatching (list 1 5 3 8 2) 4)))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 149 (list) (lambda () (countMatching (list 1 2 3) 10)))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 150 (list) (lambda () (countMatching (list) 0)))) 0)
    ))
  )

  (test-case "transformAndFilter"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 159 (list) (lambda () (transformAndFilter (list 3 5 7 1 9))))) (list 14 18))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 160 (list) (lambda () (transformAndFilter (list))))) (list))
    ))
  )

  (test-case "buildMessages"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 174 (list) (lambda () (buildMessages (list 1 2 3) "item")))) (list "item: 1" "item: 2" "item: 3"))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 175 (list) (lambda () (buildMessages (list) "x")))) (list))
    ))
  )

  (test-case "sumAbove"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 189 (list) (lambda () (sumAbove (list 1 5 3 8 2) 4)))) 13)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 190 (list) (lambda () (sumAbove (list) 0)))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 191 (list) (lambda () (sumAbove (list 1 2 3) 10)))) 0)
    ))
  )

  (test-case "validateAll"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 210 (list) (lambda () (validateAll (list "hello" "world"))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 211 (list) (lambda () (validateAll (list "hello" "" "world"))))) #f)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson36-lambdas.tesl" 212 (list) (lambda () (validateAll (list))))) #t)
    ))
  )

)
