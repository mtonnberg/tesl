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
  (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))

(define-checker
  (isLargerThan20 [n : Integer])
  #:returns [n : Integer ::: (IsLargerThan20 n)]
  (if (> *n 20) (accept (IsLargerThan20 n) #:value *n) (reject "not above 20" #:http-code 400)))

(define-checker
  (isLessThan200 [n : Integer])
  #:returns [n : Integer ::: (LessThan200 n)]
  (if (< *n 200) (accept (LessThan200 n) #:value *n) (reject "not below 200" #:http-code 400)))

(define/pow
  (doubleOne [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (* *n 2))

(define/pow
  (doublePositive [xs : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-0 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(IsPositive ,n))]) (doubleOne n))) tesl-lambda-0) *xs)))

(define/pow
  (mapDoubledInline [xs : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-1 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(IsPositive ,n))]) (* *n 2))) tesl-lambda-1) *xs)))

(define/pow
  (mapAndReprove [xs : (List Integer)])
  #:returns (List Integer)
  (let ([doubled (doublePositive xs)]) (tesl_import_List_filterCheck isPositive (raw-value doubled))))

(define/pow
  (mapAndCount [xs : (List Integer)])
  #:returns Integer
  (let ([doubled (doublePositive xs)]) (raw-value (tesl_import_List_length (raw-value doubled)))))

(define/pow
  (filterPositiveSet [s : (Set Integer)])
  #:returns (Set Integer)
  (tesl_import_Set_filterCheck isPositive *s))

(define/pow
  (filterPositiveSetCombined [s : (Set Integer)])
  #:returns (Set Integer)
  (tesl_import_Set_filterCheck (check-and isPositive (check-and isLargerThan20 isLessThan200)) *s))

(define/pow
  (verifyAllPositive [s : (Set Integer)])
  #:returns (Maybe (Set Integer))
  (tesl_import_Set_allCheck isPositive *s))

(define/pow
  (verifyAllCombined [s : (Set Integer)])
  #:returns (Maybe (Set Integer))
  (tesl_import_Set_allCheck (check-and isPositive (check-and isLargerThan20 isLessThan200)) *s))

(define/pow
  (countPositive [s : (Set Integer)])
  #:returns Integer
  (raw-value (tesl_import_Set_size *s)))

(define/pow
  (run)
  #:returns Integer
  (let ([filtered (tesl_import_Set_filterCheck isPositive (raw-value (tesl_import_Set_fromList (list 1 2 3 -1 -2))))]) (raw-value (countPositive filtered))))

(module+ test
  (require rackunit)
  (test-case "List.map with proof-requiring named function (via lambda wrapper)"
  (define src (tesl_import_List_filterCheck isPositive (list 1 2 3 -1)))
  (define doubled (doublePositive src))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value doubled)))) 3)
  )

  (test-case "List.map with inline proof-annotated lambda"
  (define src (tesl_import_List_filterCheck isPositive (list 5 10 15)))
  (define doubled (mapDoubledInline src))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value doubled)))) 3)
  )

  (test-case "mapAndReprove re-attaches proof after map"
  (define src (tesl_import_List_filterCheck isPositive (list 1 2 3)))
  (define result (mapAndReprove src))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value result)))) 3)
  )

  (test-case "mapAndCount counts correctly"
  (define src (tesl_import_List_filterCheck isPositive (list 10 20 30)))
  (check-equal? (raw-value (mapAndCount src)) 3)
  )

  (test-case "Set.filterCheck produces ForAll annotated set"
  (define s (raw-value (tesl_import_Set_fromList (list 1 2 -1 3 -2))))
  (define pos (filterPositiveSet s))
  (check-equal? (raw-value (raw-value (tesl_import_Set_size (raw-value pos)))) 3)
  )

  (test-case "run end-to-end"
  (check-equal? (raw-value (run)) 3)
  )

)
