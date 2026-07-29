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
  (only-in tesl/tesl/tuple Tuple2)
  (only-in tesl/tesl/int [Int.nonNegative tesl_import_Int_nonNegative] IsNonNegative)
  (only-in tesl/tesl/list [List.map tesl_import_List_map] [List.filter tesl_import_List_filter] [List.foldl tesl_import_List_foldl] [List.foldr tesl_import_List_foldr] [List.length tesl_import_List_length] [List.isEmpty tesl_import_List_isEmpty] [List.head tesl_import_List_head] [List.tail tesl_import_List_tail] [List.concat tesl_import_List_concat] [List.append tesl_import_List_append] [List.reverse tesl_import_List_reverse] [List.unique tesl_import_List_unique] [List.take tesl_import_List_take] [List.drop tesl_import_List_drop] [List.zip tesl_import_List_zip] [List.range tesl_import_List_range] [List.repeat tesl_import_List_repeat] [List.any tesl_import_List_any] [List.all tesl_import_List_all] [List.find tesl_import_List_find] [List.sum tesl_import_List_sum] [List.maximum tesl_import_List_maximum] [List.minimum tesl_import_List_minimum] [List.concatMap tesl_import_List_concatMap] [List.member tesl_import_List_member] [List.contains tesl_import_List_contains])
)


(provide )

(define/pow
  (repeatN [value : Integer] [n : Integer])
  #:returns (List Integer)
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 155 (list (cons 'value *value) (cons 'n *n)) (lambda () (let/check ([tesl-checked-0 (tesl_import_Int_nonNegative n)]) (let ([safeN tesl-checked-0]) (raw-value (tesl_import_List_repeat *value safeN)))))))

(define/pow
  (takeN [n : Integer] [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 159 (list (cons 'n *n) (cons 'xs *xs)) (lambda () (let/check ([tesl-checked-1 (tesl_import_Int_nonNegative n)]) (let ([safeN tesl-checked-1]) (raw-value (tesl_import_List_take safeN *xs)))))))

(define/pow
  (dropN [n : Integer] [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 163 (list (cons 'n *n) (cons 'xs *xs)) (lambda () (let/check ([tesl-checked-2 (tesl_import_Int_nonNegative n)]) (let ([safeN tesl-checked-2]) (raw-value (tesl_import_List_drop safeN *xs)))))))

(module+ test
  (require rackunit)
  (test-case "List.map"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 44 (list) (lambda () (tesl_import_List_map (let () (define/pow (tesl-lambda-3 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-3) (list 1 2 3))))) (list 2 4 6))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 45 (list) (lambda () (tesl_import_List_map (let () (define/pow (tesl-lambda-4 [x : Integer]) #:returns Integer (+ *x 1)) tesl-lambda-4) (list))))) (list))
    ))
  )

  (test-case "List.filter"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 49 (list) (lambda () (tesl_import_List_filter (let () (define/pow (tesl-lambda-5 [x : Integer]) #:returns Boolean (> *x 2)) tesl-lambda-5) (list 1 2 3 4))))) (list 3 4))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 50 (list) (lambda () (tesl_import_List_filter (let () (define/pow (tesl-lambda-6 [x : Integer]) #:returns Boolean (> *x 10)) tesl-lambda-6) (list 1 2 3))))) (list))
    ))
  )

  (test-case "List.concatMap"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 54 (list) (lambda () (raw-value (tesl_import_List_concatMap (let () (define/pow (tesl-lambda-7 [x : Integer]) #:returns Any (list *x *x)) tesl-lambda-7) (list 1 2)))))) (list 1 1 2 2))
    ))
  )

  (test-case "List.reverse"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 58 (list) (lambda () (tesl_import_List_reverse (list 1 2 3))))) (list 3 2 1))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 59 (list) (lambda () (tesl_import_List_reverse (list))))) (list))
    ))
  )

  (test-case "List.unique"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 63 (list) (lambda () (tesl_import_List_unique (list 1 1 2 3 3 3))))) (list 1 2 3))
    ))
  )

  (test-case "List.zip"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 67 (list) (lambda () (raw-value (tesl_import_List_zip (list 1 2) (list "a" "b")))))) (list (Tuple2 1 "a") (Tuple2 2 "b")))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 68 (list) (lambda () (raw-value (tesl_import_List_zip (list 1 2 3) (list "a")))))) (list (Tuple2 1 "a")))
    ))
  )

  (test-case "List.length"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 74 (list) (lambda () (raw-value (tesl_import_List_length (list 1 2 3)))))) 3)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 75 (list) (lambda () (raw-value (tesl_import_List_length (list)))))) 0)
    ))
  )

  (test-case "List.isEmpty"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 79 (list) (lambda () (raw-value (tesl_import_List_isEmpty (list)))))) #t)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 80 (list) (lambda () (raw-value (tesl_import_List_isEmpty (list 1)))))) #f)
    ))
  )

  (test-case "List.head"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 84 (list) (lambda () (raw-value (tesl_import_List_head (list 1 2 3)))))) (raw-value (Something 1)))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 85 (list) (lambda () (raw-value (tesl_import_List_head (list)))))) Nothing)
    ))
  )

  (test-case "List.tail"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 89 (list) (lambda () (raw-value (tesl_import_List_tail (list 1 2 3)))))) (raw-value (Something (list 2 3))))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 90 (list) (lambda () (raw-value (tesl_import_List_tail (list)))))) Nothing)
    ))
  )

  (test-case "List.any"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 94 (list) (lambda () (raw-value (tesl_import_List_any (let () (define/pow (tesl-lambda-8 [x : Integer]) #:returns Boolean (> *x 2)) tesl-lambda-8) (list 1 2 3)))))) #t)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 95 (list) (lambda () (raw-value (tesl_import_List_any (let () (define/pow (tesl-lambda-9 [x : Integer]) #:returns Boolean (> *x 9)) tesl-lambda-9) (list 1 2 3)))))) #f)
    ))
  )

  (test-case "List.all"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 99 (list) (lambda () (raw-value (tesl_import_List_all (let () (define/pow (tesl-lambda-10 [x : Integer]) #:returns Boolean (> *x 0)) tesl-lambda-10) (list 1 2 3)))))) #t)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 100 (list) (lambda () (raw-value (tesl_import_List_all (let () (define/pow (tesl-lambda-11 [x : Integer]) #:returns Boolean (> *x 1)) tesl-lambda-11) (list 1 2 3)))))) #f)
    ))
  )

  (test-case "List.find"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 104 (list) (lambda () (raw-value (tesl_import_List_find (let () (define/pow (tesl-lambda-12 [x : Integer]) #:returns Boolean (> *x 2)) tesl-lambda-12) (list 1 2 3 4)))))) (raw-value (Something 3)))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 105 (list) (lambda () (raw-value (tesl_import_List_find (let () (define/pow (tesl-lambda-13 [x : Integer]) #:returns Boolean (> *x 9)) tesl-lambda-13) (list 1 2 3)))))) Nothing)
    ))
  )

  (test-case "List.member"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 109 (list) (lambda () (raw-value (tesl_import_List_member 2 (list 1 2 3)))))) #t)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 110 (list) (lambda () (raw-value (tesl_import_List_member 9 (list 1 2 3)))))) #f)
    ))
  )

  (test-case "List.contains"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 114 (list) (lambda () (raw-value (tesl_import_List_contains 3 (list 1 2 3)))))) #t)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 115 (list) (lambda () (raw-value (tesl_import_List_contains 9 (list 1 2 3)))))) #f)
    ))
  )

  (test-case "List.sum"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 119 (list) (lambda () (raw-value (tesl_import_List_sum (list 1 2 3 4)))))) 10)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 120 (list) (lambda () (raw-value (tesl_import_List_sum (list)))))) 0)
    ))
  )

  (test-case "List.maximum"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 124 (list) (lambda () (raw-value (tesl_import_List_maximum (list 3 1 4 1 5)))))) (raw-value (Something 5)))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 125 (list) (lambda () (raw-value (tesl_import_List_maximum (list)))))) Nothing)
    ))
  )

  (test-case "List.minimum"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 129 (list) (lambda () (raw-value (tesl_import_List_minimum (list 3 1 4 1 5)))))) (raw-value (Something 1)))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 130 (list) (lambda () (raw-value (tesl_import_List_minimum (list)))))) Nothing)
    ))
  )

  (test-case "List.append"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 136 (list) (lambda () (tesl_import_List_append (list 1 2) (list 3 4))))) (list 1 2 3 4))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 137 (list) (lambda () (tesl_import_List_append (list) (list 1))))) (list 1))
    ))
  )

  (test-case "List.concat"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 141 (list) (lambda () (raw-value (tesl_import_List_concat (list (list 1 2) (list 3) (list 4 5))))))) (list 1 2 3 4 5))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 142 (list) (lambda () (raw-value (tesl_import_List_concat (list)))))) (list))
    ))
  )

  (test-case "List.range"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 146 (list) (lambda () (tesl_import_List_range 0 4)))) (list 0 1 2 3))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 147 (list) (lambda () (tesl_import_List_range 3 3)))) (list))
    ))
  )

  (test-case "List.repeat"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 167 (list) (lambda () (repeatN 7 3)))) (list 7 7 7))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 168 (list) (lambda () (repeatN 7 0)))) (list))
    ))
  )

  (test-case "List.foldl"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 174 (list) (lambda () (tesl_import_List_foldl (let () (define/pow (tesl-lambda-14 [acc : Integer] [x : Integer]) #:returns Integer (+ *acc *x)) tesl-lambda-14) 0 (list 1 2 3))))) 6)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 175 (list) (lambda () (tesl_import_List_foldl (let () (define/pow (tesl-lambda-15 [acc : Integer] [x : Integer]) #:returns Integer (- *acc *x)) tesl-lambda-15) 0 (list 1 2 3))))) -6)
    ))
  )

  (test-case "List.foldr"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 179 (list) (lambda () (tesl_import_List_foldr (let () (define/pow (tesl-lambda-16 [x : Integer] [acc : Integer]) #:returns Integer (+ *x *acc)) tesl-lambda-16) 0 (list 1 2 3))))) 6)
    ))
  )

  (test-case "List.take"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 185 (list) (lambda () (takeN 2 (list 1 2 3 4))))) (list 1 2))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 186 (list) (lambda () (takeN 0 (list 1 2 3))))) (list))
    ))
  )

  (test-case "List.drop"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 190 (list) (lambda () (dropN 2 (list 1 2 3 4))))) (list 3 4))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/lifted-list-tests.tesl" 191 (list) (lambda () (dropN 0 (list 1 2 3))))) (list 1 2 3))
    ))
  )

)
