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
  (only-in tesl/tesl/prelude Int List)
  (only-in tesl/tesl/list [List.map tesl_import_List_map] [List.filterCheck tesl_import_List_filterCheck] [List.length tesl_import_List_length])
  (only-in tesl/tesl/set Set [Set.fromList tesl_import_Set_fromList] [Set.size tesl_import_Set_size] [Set.filterCheck tesl_import_Set_filterCheck] [Set.allCheck tesl_import_Set_allCheck])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
)


(provide run doublePositive mapAndCount doublePositive-signature mapAndCount-signature run-signature)

(define IsLargerThan20 'IsLargerThan20)
(define IsPositive 'IsPositive)
(define LessThan200 'LessThan200)

(define-checker
  (isPositive [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 63 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))))

(define-checker
  (isLargerThan20 [n : Integer])
  #:returns [n : Integer ::: (IsLargerThan20 n)]
  (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 71 (list (cons 'n *n)) (lambda () (if (> *n 20) (accept (IsLargerThan20 n) #:value *n) (reject "not above 20" #:http-code 400)))))

(define-checker
  (isLessThan200 [n : Integer])
  #:returns [n : Integer ::: (LessThan200 n)]
  (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 79 (list (cons 'n *n)) (lambda () (if (< *n 200) (accept (LessThan200 n) #:value *n) (reject "not below 200" #:http-code 400)))))

(define/pow
  (doubleOne [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 89 (list (cons 'n *n)) (lambda () (* *n 2))))

(define/pow
  (doublePositive [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 94 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-0 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(IsPositive ,n))]) (doubleOne n))) tesl-lambda-0) *xs)))))

(define/pow
  (mapDoubledInline [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 98 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-1 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(IsPositive ,n))]) (* *n 2))) tesl-lambda-1) *xs)))))

(define/pow
  (mapAndReprove [xs : (List Integer)])
  #:returns (List Integer)
  (let ([doubled (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 102 (list (cons 'xs *xs)) (lambda () (doublePositive xs)))]) (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 103 (list (cons 'doubled *doubled) (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck isPositive (raw-value doubled))))))

(define/pow
  (mapAndCount [xs : (List Integer)])
  #:returns Integer
  (let ([doubled (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 106 (list (cons 'xs *xs)) (lambda () (doublePositive xs)))]) (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 107 (list (cons 'doubled *doubled) (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length (raw-value doubled)))))))

(define/pow
  (filterPositiveSet [s : (Set Integer)])
  #:returns (Set Integer)
  (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 113 (list (cons 's *s)) (lambda () (tesl_import_Set_filterCheck isPositive *s))))

(define/pow
  (filterPositiveSetCombined [s : (Set Integer)])
  #:returns (Set Integer)
  (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 116 (list (cons 's *s)) (lambda () (tesl_import_Set_filterCheck (check-and isPositive (check-and isLargerThan20 isLessThan200)) *s))))

(define/pow
  (verifyAllPositive [s : (Set Integer)])
  #:returns (Maybe (Set Integer))
  (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 123 (list (cons 's *s)) (lambda () (tesl_import_Set_allCheck isPositive *s))))

(define/pow
  (verifyAllCombined [s : (Set Integer)])
  #:returns (Maybe (Set Integer))
  (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 126 (list (cons 's *s)) (lambda () (tesl_import_Set_allCheck (check-and isPositive (check-and isLargerThan20 isLessThan200)) *s))))

(define/pow
  (countPositive [s : (Set Integer)])
  #:returns Integer
  (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 132 (list (cons 's *s)) (lambda () (raw-value (tesl_import_Set_size *s)))))

(define/pow
  (run)
  #:returns Integer
  (let ([filtered (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 137 (list) (lambda () (tesl_import_Set_filterCheck isPositive (raw-value (tesl_import_Set_fromList (list 1 2 3 -1 -2))))))]) (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 138 (list (cons 'filtered *filtered)) (lambda () (raw-value (countPositive filtered))))))

(module+ test
  (require rackunit)
  (test-case "List.map with proof-requiring named function (via lambda wrapper)"
    (call-with-fresh-memory-db '() (lambda ()
  (define src (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 143 (list) (lambda () (tesl_import_List_filterCheck isPositive (list 1 2 3 -1)))))
  (define doubled (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 144 (list (cons 'src src)) (lambda () (doublePositive src))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 145 (list (cons 'doubled doubled) (cons 'src src)) (lambda () (raw-value (tesl_import_List_length (raw-value doubled)))))) 3)
    ))
  )

  (test-case "List.map with inline proof-annotated lambda"
    (call-with-fresh-memory-db '() (lambda ()
  (define src (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 149 (list) (lambda () (tesl_import_List_filterCheck isPositive (list 5 10 15)))))
  (define doubled (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 150 (list (cons 'src src)) (lambda () (mapDoubledInline src))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 151 (list (cons 'doubled doubled) (cons 'src src)) (lambda () (raw-value (tesl_import_List_length (raw-value doubled)))))) 3)
    ))
  )

  (test-case "mapAndReprove re-attaches proof after map"
    (call-with-fresh-memory-db '() (lambda ()
  (define src (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 155 (list) (lambda () (tesl_import_List_filterCheck isPositive (list 1 2 3)))))
  (define result (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 156 (list (cons 'src src)) (lambda () (mapAndReprove src))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 157 (list (cons 'result result) (cons 'src src)) (lambda () (raw-value (tesl_import_List_length (raw-value result)))))) 3)
    ))
  )

  (test-case "mapAndCount counts correctly"
    (call-with-fresh-memory-db '() (lambda ()
  (define src (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 161 (list) (lambda () (tesl_import_List_filterCheck isPositive (list 10 20 30)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 162 (list (cons 'src src)) (lambda () (mapAndCount src)))) 3)
    ))
  )

  (test-case "Set.filterCheck produces ForAll annotated set"
    (call-with-fresh-memory-db '() (lambda ()
  (define s (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 166 (list) (lambda () (raw-value (tesl_import_Set_fromList (list 1 2 -1 3 -2))))))
  (define pos (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 167 (list (cons 's s)) (lambda () (filterPositiveSet s))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 168 (list (cons 'pos pos) (cons 's s)) (lambda () (raw-value (tesl_import_Set_size (raw-value pos)))))) 3)
    ))
  )

  (test-case "run end-to-end"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson30-forall-set-proofs.tesl" 172 (list) (lambda () (run)))) 3)
    ))
  )

)
