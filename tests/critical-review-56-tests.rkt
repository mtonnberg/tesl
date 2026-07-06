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
  (only-in tesl/tesl/prelude Int Bool String List Fact detachFact)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/list [List.length tesl_import_List_length] [List.filterCheck tesl_import_List_filterCheck])
)


(provide )

(define Capped 'Capped)
(define HasMax 'HasMax)
(define HasMin 'HasMin)
(define IsPositive 'IsPositive)
(define IsSmall 'IsSmall)
(define Named 'Named)
(define PriceExceedsQuantity 'PriceExceedsQuantity)

(define-checker
  (checkPos [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "tests/critical-review-56-tests.tesl" 28 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))))

(define-checker
  (checkSmall [n : Integer])
  #:returns [n : Integer ::: (IsSmall n)]
  (thsl-src! "tests/critical-review-56-tests.tesl" 34 (list (cons 'n *n)) (lambda () (if (< *n 1000) (accept (IsSmall n) #:value *n) (reject "too large" #:http-code 400)))))

(define-checker
  (checkMin10 [n : Integer])
  #:returns [n : Integer ::: (HasMin 10 n)]
  (thsl-src! "tests/critical-review-56-tests.tesl" 40 (list (cons 'n *n)) (lambda () (if (>= *n 10) (accept (HasMin 10 n) #:value *n) (reject "too low" #:http-code 400)))))

(define-checker
  (checkMax100 [n : Integer])
  #:returns [n : Integer ::: (HasMax 100 n)]
  (thsl-src! "tests/critical-review-56-tests.tesl" 46 (list (cons 'n *n)) (lambda () (if (<= *n 100) (accept (HasMax 100 n) #:value *n) (reject "too high" #:http-code 400)))))

(define-trusted
  (proveAlwaysCapped [n : Integer])
  #:returns (Fact (Capped 9999 n))
  (thsl-src! "tests/critical-review-56-tests.tesl" 52 (list (cons 'n *n)) (lambda () (trusted-proof (Capped 9999 n)))))

(define-trusted
  (proveHttp [port : Integer])
  #:returns (Fact (Named "http" port))
  (thsl-src! "tests/critical-review-56-tests.tesl" 55 (list (cons 'port *port)) (lambda () (trusted-proof (Named "http" port)))))

(define/pow
  (needPos [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-56-tests.tesl" 57 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needMin10 [n : Integer ::: (HasMin 10 n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-56-tests.tesl" 58 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needMax100 [n : Integer ::: (HasMax 100 n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-56-tests.tesl" 59 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needBothBounds [n : Integer ::: ((HasMin 10 n) && (HasMax 100 n))])
  #:returns Integer
  (thsl-src! "tests/critical-review-56-tests.tesl" 60 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needCapped [n : Integer ::: (Capped 9999 n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-56-tests.tesl" 61 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needHttp [port : Integer ::: (Named "http" port)])
  #:returns Integer
  (thsl-src! "tests/critical-review-56-tests.tesl" 62 (list (cons 'port *port)) (lambda () *port)))

(define/pow
  (li01_literal_min_correct [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-56-tests.tesl" 67 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-0 (checkMin10 raw)]) (let ([v tesl-checked-0]) (raw-value (needMin10 v)))))))

(define/pow
  (li02_literal_max_correct [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-56-tests.tesl" 71 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-1 (checkMax100 raw)]) (let ([v tesl-checked-1]) (raw-value (needMax100 v)))))))

(define/pow
  (li03_literal_both_bounds [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-56-tests.tesl" 75 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-2 (checkMin10 raw)]) (let ([a tesl-checked-2]) (let/check ([tesl-checked-3 (checkMax100 a)]) (let ([b tesl-checked-3]) (raw-value (needBothBounds b)))))))))

(define/pow
  (li04_string_literal_proof [raw : Integer])
  #:returns Integer
  (let ([pf (thsl-src! "tests/critical-review-56-tests.tesl" 80 (list (cons 'raw *raw)) (lambda () (proveHttp raw)))]) (thsl-src! "tests/critical-review-56-tests.tesl" 81 (list (cons 'pf *pf) (cons 'raw *raw)) (lambda () (raw-value (needHttp (attach-proof raw pf)))))))

(define/pow
  (li05_capped_literal [raw : Integer])
  #:returns Integer
  (let ([pf (thsl-src! "tests/critical-review-56-tests.tesl" 84 (list (cons 'raw *raw)) (lambda () (proveAlwaysCapped raw)))]) (thsl-src! "tests/critical-review-56-tests.tesl" 85 (list (cons 'pf *pf) (cons 'raw *raw)) (lambda () (raw-value (needCapped (attach-proof raw pf)))))))

(define/pow
  (li06_mixed_lit_var_bounds [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-56-tests.tesl" 88 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-4 (checkMin10 raw)]) (let ([a tesl-checked-4]) (let/check ([tesl-checked-5 (checkMax100 a)]) (let ([b tesl-checked-5]) (raw-value (needBothBounds b)))))))))

(define-checker
  (checkPQ [price : Integer] [quantity : Integer])
  #:returns [price : Integer ::: (PriceExceedsQuantity price quantity)]
  (thsl-src! "tests/critical-review-56-tests.tesl" 121 (list (cons 'price *price) (cons 'quantity *quantity)) (lambda () (if (> *price *quantity) (accept (PriceExceedsQuantity price quantity) #:value *price) (reject "price must exceed quantity" #:http-code 422)))))

(define-record OrderLine
  [price : Integer ::: (IsPositive price)]
  [quantity : Integer ::: (IsPositive quantity)]
)

(define/pow
  (makeOrderLine [p : Integer ::: (IsPositive p)] [q : Integer ::: (IsPositive q)] [pq : Integer ::: (PriceExceedsQuantity p q)])
  #:returns OrderLine
  (thsl-src! "tests/critical-review-56-tests.tesl" 134 (list (cons 'p *p) (cons 'q *q) (cons 'pq *pq)) (lambda () (OrderLine #:price p #:quantity q))))

(define/pow
  (getPrice [ol : OrderLine])
  #:returns Integer
  (thsl-src! "tests/critical-review-56-tests.tesl" 136 (list (cons 'ol *ol)) (lambda () (tesl-dot/runtime ol 'price 'OrderLine))))

(define-record ValidPayload
  [serial : Integer ::: (IsPositive serial)]
)

(define/pow
  (extractSerial [payload : ValidPayload])
  #:returns [serial : Integer ::: (IsPositive serial)]
  (thsl-src! "tests/critical-review-56-tests.tesl" 158 (list (cons 'payload *payload)) (lambda () (tesl-dot/runtime payload 'serial 'ValidPayload))))

(define-record ValidItem
  [value : Integer ::: ((IsPositive value) && (IsSmall value))]
)

(define/pow
  (extractValue [item : ValidItem])
  #:returns [value : Integer ::: ((IsPositive value) && (IsSmall value))]
  (thsl-src! "tests/critical-review-56-tests.tesl" 165 (list (cons 'item *item)) (lambda () (tesl-dot/runtime item 'value 'ValidItem))))

(define/pow
  (needBoth [n : Integer ::: ((IsPositive n) && (IsSmall n))])
  #:returns Integer
  (thsl-src! "tests/critical-review-56-tests.tesl" 167 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (fa01_forall_no_literals [xs : (List Integer)])
  #:returns Integer
  (let ([positives (thsl-src! "tests/critical-review-56-tests.tesl" 187 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPos *xs)))]) (let ([consumer (thsl-src! "tests/critical-review-56-tests.tesl" 188 (list (cons 'positives *positives) (cons 'xs *xs)) (lambda () (let () (define/pow (tesl-lambda-6 [ns : (List Integer)]) #:returns Integer (raw-value (tesl_import_List_length *ns))) tesl-lambda-6)))]) (thsl-src! "tests/critical-review-56-tests.tesl" 189 (list (cons 'consumer *consumer) (cons 'positives *positives) (cons 'xs *xs)) (lambda () (raw-value (consumer positives)))))))

(define/pow
  (ch01_combined_literal_preds [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-56-tests.tesl" 200 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-7 (checkMin10 raw)]) (let ([a tesl-checked-7]) (let/check ([tesl-checked-8 (checkMax100 a)]) (let ([b tesl-checked-8]) (raw-value (needBothBounds b)))))))))

(module+ test
  (require rackunit)
  (test-case "R56_LI: literal proof subject runtime correctness"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 93 (list) (lambda () (li01_literal_min_correct 10)))) 10)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 94 (list) (lambda () (li01_literal_min_correct 50)))) 50)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-56-tests.tesl" 95 (list) (lambda ()
                          (li01_literal_min_correct 9))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: li01_literal_min_correct 9"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 97 (list) (lambda () (li02_literal_max_correct 100)))) 100)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 98 (list) (lambda () (li02_literal_max_correct 0)))) 0)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-56-tests.tesl" 99 (list) (lambda ()
                          (li02_literal_max_correct 101))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: li02_literal_max_correct 101"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 101 (list) (lambda () (li03_literal_both_bounds 50)))) 50)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 102 (list) (lambda () (li03_literal_both_bounds 10)))) 10)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 103 (list) (lambda () (li03_literal_both_bounds 100)))) 100)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-56-tests.tesl" 104 (list) (lambda ()
                          (li03_literal_both_bounds 9))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: li03_literal_both_bounds 9"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-56-tests.tesl" 105 (list) (lambda ()
                          (li03_literal_both_bounds 101))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: li03_literal_both_bounds 101"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 107 (list) (lambda () (li04_string_literal_proof 80)))) 80)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 108 (list) (lambda () (li04_string_literal_proof 443)))) 443)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 110 (list) (lambda () (li05_capped_literal 42)))) 42)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 111 (list) (lambda () (li05_capped_literal 0)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 113 (list) (lambda () (li06_mixed_lit_var_bounds 50)))) 50)
    ))
  )

  (test-case "R56_GW: ghost witness construction"
    (call-with-fresh-memory-db '() (lambda ()
  (define price100 (thsl-src! "tests/critical-review-56-tests.tesl" 139 (list) (lambda () 100)))
  (define qty50 (thsl-src! "tests/critical-review-56-tests.tesl" 140 (list (cons 'price100 price100)) (lambda () 50)))
  (define tesl-checked-9 (checkPos price100))
  (when (check-fail? tesl-checked-9)
    (raise-user-error 'tesl-test "unexpected failure in let p: ~a" (check-fail-message tesl-checked-9)))
  (define p tesl-checked-9)
  (define tesl-checked-10 (checkPos qty50))
  (when (check-fail? tesl-checked-10)
    (raise-user-error 'tesl-test "unexpected failure in let q: ~a" (check-fail-message tesl-checked-10)))
  (define q tesl-checked-10)
  (define tesl-checked-11 (checkPQ price100 qty50))
  (when (check-fail? tesl-checked-11)
    (raise-user-error 'tesl-test "unexpected failure in let pq: ~a" (check-fail-message tesl-checked-11)))
  (define pq tesl-checked-11)
  (define ol (thsl-src! "tests/critical-review-56-tests.tesl" 144 (list (cons 'pq pq) (cons 'q q) (cons 'p p) (cons 'qty50 qty50) (cons 'price100 price100)) (lambda () (makeOrderLine p q pq))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 145 (list (cons 'ol ol) (cons 'pq pq) (cons 'q q) (cons 'p p) (cons 'qty50 qty50) (cons 'price100 price100)) (lambda () (getPrice ol)))) 100)
  (define badPrice (thsl-src! "tests/critical-review-56-tests.tesl" 146 (list (cons 'ol ol) (cons 'pq pq) (cons 'q q) (cons 'p p) (cons 'qty50 qty50) (cons 'price100 price100)) (lambda () 50)))
  (define badQty (thsl-src! "tests/critical-review-56-tests.tesl" 147 (list (cons 'badPrice badPrice) (cons 'ol ol) (cons 'pq pq) (cons 'q q) (cons 'p p) (cons 'qty50 qty50) (cons 'price100 price100)) (lambda () 100)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-56-tests.tesl" 148 (list (cons 'badQty badQty) (cons 'badPrice badPrice) (cons 'ol ol) (cons 'pq pq) (cons 'q q) (cons 'p p) (cons 'qty50 qty50) (cons 'price100 price100)) (lambda ()
                          (checkPQ badPrice badQty))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPQ badPrice badQty"))
    ))
  )

  (test-case "R56_FP: field proof passthrough runtime"
    (call-with-fresh-memory-db '() (lambda ()
  (define rawSerial (thsl-src! "tests/critical-review-56-tests.tesl" 170 (list) (lambda () 42)))
  (define tesl-checked-12 (checkPos rawSerial))
  (when (check-fail? tesl-checked-12)
    (raise-user-error 'tesl-test "unexpected failure in let posSerial: ~a" (check-fail-message tesl-checked-12)))
  (define posSerial tesl-checked-12)
  (define payload (thsl-src! "tests/critical-review-56-tests.tesl" 172 (list (cons 'posSerial posSerial) (cons 'rawSerial rawSerial)) (lambda () (ValidPayload #:serial posSerial))))
  (define extracted (thsl-src! "tests/critical-review-56-tests.tesl" 173 (list (cons 'payload payload) (cons 'posSerial posSerial) (cons 'rawSerial rawSerial)) (lambda () (extractSerial payload))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 174 (list (cons 'extracted extracted) (cons 'payload payload) (cons 'posSerial posSerial) (cons 'rawSerial rawSerial)) (lambda () (needPos extracted)))) 42)
  (define rawVal (thsl-src! "tests/critical-review-56-tests.tesl" 176 (list (cons 'extracted extracted) (cons 'payload payload) (cons 'posSerial posSerial) (cons 'rawSerial rawSerial)) (lambda () 5)))
  (define tesl-checked-13 (checkPos rawVal))
  (when (check-fail? tesl-checked-13)
    (raise-user-error 'tesl-test "unexpected failure in let pv: ~a" (check-fail-message tesl-checked-13)))
  (define pv tesl-checked-13)
  (define tesl-checked-14 (checkSmall pv))
  (when (check-fail? tesl-checked-14)
    (raise-user-error 'tesl-test "unexpected failure in let sv: ~a" (check-fail-message tesl-checked-14)))
  (define sv tesl-checked-14)
  (define item (thsl-src! "tests/critical-review-56-tests.tesl" 179 (list (cons 'sv sv) (cons 'pv pv) (cons 'rawVal rawVal) (cons 'extracted extracted) (cons 'payload payload) (cons 'posSerial posSerial) (cons 'rawSerial rawSerial)) (lambda () (ValidItem #:value sv))))
  (define v (thsl-src! "tests/critical-review-56-tests.tesl" 180 (list (cons 'item item) (cons 'sv sv) (cons 'pv pv) (cons 'rawVal rawVal) (cons 'extracted extracted) (cons 'payload payload) (cons 'posSerial posSerial) (cons 'rawSerial rawSerial)) (lambda () (extractValue item))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 181 (list (cons 'v v) (cons 'item item) (cons 'sv sv) (cons 'pv pv) (cons 'rawVal rawVal) (cons 'extracted extracted) (cons 'payload payload) (cons 'posSerial posSerial) (cons 'rawSerial rawSerial)) (lambda () (needBoth v)))) 5)
    ))
  )

  (test-case "R56_FA: ForAll without literal args works"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 192 (list) (lambda () (fa01_forall_no_literals (list 1 2 -3 4))))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 193 (list) (lambda () (fa01_forall_no_literals (list -1 -2 -3))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 194 (list) (lambda () (fa01_forall_no_literals (list 1 2 3))))) 3)
    ))
  )

  (test-case "R56_CH: combined literal predicate checks"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 205 (list) (lambda () (ch01_combined_literal_preds 10)))) 10)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 206 (list) (lambda () (ch01_combined_literal_preds 55)))) 55)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-56-tests.tesl" 207 (list) (lambda () (ch01_combined_literal_preds 100)))) 100)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-56-tests.tesl" 208 (list) (lambda ()
                          (ch01_combined_literal_preds 9))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: ch01_combined_literal_preds 9"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-56-tests.tesl" 209 (list) (lambda ()
                          (ch01_combined_literal_preds 101))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: ch01_combined_literal_preds 101"))
    ))
  )

)
