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
  (only-in tesl/tesl/prelude Int String Fact detachFact)
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
)


(provide SafeTitle TitleLength checkSafeTitle checkLength SafeMessage createMessage IsPositive checkPositiveInt PriceExceedsQuantity checkPriceExceedsQuantity OrderLine makeOrderLine processOrder checkSafeTitle-signature checkLength-signature createMessage-signature checkPositiveInt-signature checkPriceExceedsQuantity-signature makeOrderLine-signature processOrder-signature)

(define IsPositive 'IsPositive)
(define PriceExceedsQuantity 'PriceExceedsQuantity)
(define SafeTitle 'SafeTitle)
(define TitleLength 'TitleLength)

(define-checker
  (checkSafeTitle [s : String])
  #:returns [s : String ::: (SafeTitle s)]
  (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 53 (list (cons 's *s)) (lambda () (if (and (> (raw-value (tesl_import_String_length *s)) 0) (<= (raw-value (tesl_import_String_length *s)) 120)) (accept (SafeTitle s) #:value *s) (reject "title must be 1-120 characters" #:http-code 400)))))

(define-checker
  (checkLength [s : String])
  #:returns [s : String ::: (TitleLength s)]
  (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 62 (list (cons 's *s)) (lambda () (if (<= (raw-value (tesl_import_String_length *s)) 500) (accept (TitleLength s) #:value *s) (reject "too long" #:http-code 400)))))

(define-record SafeMessage
  [title : String ::: (SafeTitle title)]
  [body : String ::: (TitleLength body)]
)

(define (tesl-codec-encode-SafeMessage _v)
  (error "toJson is forbidden for type SafeMessage: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-SafeMessage-0 _j)
  (define _fraw_title (tesl-decode-prim-field _j "title" tesl-decode-prim-string))
  (define _r1_title
    (let ([_r (checkSafeTitle _fraw_title)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_title
    (if (check-ok? _r1_title)
        (ensure-named 'title (check-ok-value _r1_title) (check-ok-facts _r1_title) (check-ok-bindings _r1_title) #:subject 'title)
        _r1_title))
  (define _fraw_body (tesl-decode-prim-field _j "body" tesl-decode-prim-string))
  (define _r1_body
    (let ([_r (checkLength _fraw_body)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_body
    (if (check-ok? _r1_body)
        (ensure-named 'body (check-ok-value _r1_body) (check-ok-facts _r1_body) (check-ok-bindings _r1_body) #:subject 'body)
        _r1_body))
  (or (and (check-fail? _f_title) _f_title) (and (check-fail? _f_body) _f_body)
      (record-value 'SafeMessage (hash 'title _f_title 'body _f_body))))
(register-type-codec! 'SafeMessage tesl-codec-encode-SafeMessage (list tesl-codec-decode-SafeMessage-0))

(define/pow
  (createMessage [title : String ::: (SafeTitle title)] [body : String ::: (TitleLength body)])
  #:returns SafeMessage
  (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 90 (list (cons 'title *title) (cons 'body *body)) (lambda () (SafeMessage #:title title #:body body))))

(define-checker
  (checkPositiveInt [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 208 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "must be positive" #:http-code 400)))))

(define-checker
  (checkPriceExceedsQuantity [price : Integer] [quantity : Integer])
  #:returns [price : Integer ::: (PriceExceedsQuantity price quantity)]
  (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 218 (list (cons 'price *price) (cons 'quantity *quantity)) (lambda () (if (> *price *quantity) (accept (PriceExceedsQuantity price quantity) #:value *price) (reject "price must exceed quantity" #:http-code 422)))))

(define-record OrderLine
  [price : Integer ::: (IsPositive price)]
  [quantity : Integer ::: (IsPositive quantity)]
)

(define (tesl-codec-encode-OrderLine _v)
  (error "toJson is forbidden for type OrderLine: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-OrderLine-0 _j)
  (define _fraw_price (tesl-decode-prim-field _j "price" tesl-decode-prim-int))
  (define _r1_price
    (let ([_r (checkPositiveInt _fraw_price)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_price
    (if (check-ok? _r1_price)
        (ensure-named 'price (check-ok-value _r1_price) (check-ok-facts _r1_price) (check-ok-bindings _r1_price) #:subject 'price)
        _r1_price))
  (define _fraw_quantity (tesl-decode-prim-field _j "quantity" tesl-decode-prim-int))
  (define _r1_quantity
    (let ([_r (checkPositiveInt _fraw_quantity)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_quantity
    (if (check-ok? _r1_quantity)
        (ensure-named 'quantity (check-ok-value _r1_quantity) (check-ok-facts _r1_quantity) (check-ok-bindings _r1_quantity) #:subject 'quantity)
        _r1_quantity))
  (or (and (check-fail? _f_price) _f_price) (and (check-fail? _f_quantity) _f_quantity)
      (let ([_cross_check_result (checkPriceExceedsQuantity _f_price _f_quantity)])
        (if (check-fail? _cross_check_result)
            _cross_check_result
            (record-value 'OrderLine (hash 'price _f_price 'quantity _f_quantity))))))
(register-type-codec! 'OrderLine tesl-codec-encode-OrderLine (list tesl-codec-decode-OrderLine-0))

(define/pow
  (makeOrderLine [price : Integer ::: (IsPositive price)] [quantity : Integer ::: (IsPositive quantity)] [recordProof : (Fact (PriceExceedsQuantity price quantity))])
  #:returns OrderLine
  (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 247 (list (cons 'price *price) (cons 'quantity *quantity) (cons 'recordProof *recordProof)) (lambda () (OrderLine #:price price #:quantity quantity))))

(define/pow
  (shouldWork_ConfusingForTheCallerButNorRealError [price : Integer ::: (IsPositive price)] [quantity : Integer ::: (IsPositive quantity)] [recordProof : (Fact (PriceExceedsQuantity price quantity))])
  #:returns OrderLine
  (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 250 (list (cons 'price *price) (cons 'quantity *quantity) (cons 'recordProof *recordProof)) (lambda () (let/check ([tesl-checked-0 (checkPositiveInt 10)]) (let ([p tesl-checked-0]) (let/check ([tesl-checked-1 (checkPositiveInt 3)]) (let ([q tesl-checked-1]) (let/check ([tesl-checked-2 (checkPriceExceedsQuantity p q)]) (let ([pq tesl-checked-2]) (let ([proodd (detach-all-proof pq)]) (OrderLine #:price p #:quantity q)))))))))))

(define/pow
  (processOrder [order : OrderLine])
  #:returns String
  (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 262 (list (cons 'order *order)) (lambda () (format "order: price=~a, qty=~a" (tesl-display-val (raw-value order.price)) (tesl-display-val (raw-value order.quantity))))))

(module+ test
  (require rackunit)
  (test-case "checkSafeTitle valid"
    (call-with-fresh-memory-db '() (lambda ()
  (define s1 (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 124 (list) (lambda () "hello")))
  (define tesl-checked-3 (checkSafeTitle s1))
  (when (check-fail? tesl-checked-3)
    (raise-user-error 'tesl-test "unexpected failure in let x: ~a" (check-fail-message tesl-checked-3)))
  (define x tesl-checked-3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 126 (list (cons 'x x) (cons 's1 s1)) (lambda () x))) "hello")
  (define s2 (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 127 (list (cons 'x x) (cons 's1 s1)) (lambda () "a")))
  (define tesl-checked-4 (checkSafeTitle s2))
  (when (check-fail? tesl-checked-4)
    (raise-user-error 'tesl-test "unexpected failure in let y: ~a" (check-fail-message tesl-checked-4)))
  (define y tesl-checked-4)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 129 (list (cons 'y y) (cons 's2 s2) (cons 'x x) (cons 's1 s1)) (lambda () y))) "a")
    ))
  )

  (test-case "checkSafeTitle rejects"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 133 (list) (lambda ()
                          (checkSafeTitle ""))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkSafeTitle \"\""))
    ))
  )

  (test-case "checkLength valid"
    (call-with-fresh-memory-db '() (lambda ()
  (define s1 (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 137 (list) (lambda () "")))
  (define tesl-checked-5 (checkLength s1))
  (when (check-fail? tesl-checked-5)
    (raise-user-error 'tesl-test "unexpected failure in let y: ~a" (check-fail-message tesl-checked-5)))
  (define y tesl-checked-5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 139 (list (cons 'y y) (cons 's1 s1)) (lambda () y))) "")
  (define s2 (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 140 (list (cons 'y y) (cons 's1 s1)) (lambda () "hello")))
  (define tesl-checked-6 (checkLength s2))
  (when (check-fail? tesl-checked-6)
    (raise-user-error 'tesl-test "unexpected failure in let x: ~a" (check-fail-message tesl-checked-6)))
  (define x tesl-checked-6)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 142 (list (cons 'x x) (cons 's2 s2) (cons 'y y) (cons 's1 s1)) (lambda () x))) "hello")
    ))
  )

  (test-case "createMessage valid"
    (call-with-fresh-memory-db '() (lambda ()
  (define rawTitle (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 146 (list) (lambda () "My Title")))
  (define tesl-checked-7 (checkSafeTitle rawTitle))
  (when (check-fail? tesl-checked-7)
    (raise-user-error 'tesl-test "unexpected failure in let t: ~a" (check-fail-message tesl-checked-7)))
  (define t tesl-checked-7)
  (define rawBody (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 148 (list (cons 't t) (cons 'rawTitle rawTitle)) (lambda () "Some body text")))
  (define tesl-checked-8 (checkLength rawBody))
  (when (check-fail? tesl-checked-8)
    (raise-user-error 'tesl-test "unexpected failure in let b: ~a" (check-fail-message tesl-checked-8)))
  (define b tesl-checked-8)
  (define msg (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 150 (list (cons 'b b) (cons 'rawBody rawBody) (cons 't t) (cons 'rawTitle rawTitle)) (lambda () (createMessage t b))))
  (check-equal? (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 151 (list (cons 'msg msg) (cons 'b b) (cons 'rawBody rawBody) (cons 't t) (cons 'rawTitle rawTitle)) (lambda () (raw-value (tesl-dot/runtime msg 'title)))) "My Title")
  (check-equal? (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 152 (list (cons 'msg msg) (cons 'b b) (cons 'rawBody rawBody) (cons 't t) (cons 'rawTitle rawTitle)) (lambda () (raw-value (tesl-dot/runtime msg 'body)))) "Some body text")
    ))
  )

  (test-case "valid OrderLine"
    (call-with-fresh-memory-db '() (lambda ()
  (define rawP (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 265 (list) (lambda () 10)))
  (define tesl-checked-9 (checkPositiveInt rawP))
  (when (check-fail? tesl-checked-9)
    (raise-user-error 'tesl-test "unexpected failure in let p: ~a" (check-fail-message tesl-checked-9)))
  (define p tesl-checked-9)
  (define rawQ (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 267 (list (cons 'p p) (cons 'rawP rawP)) (lambda () 3)))
  (define tesl-checked-10 (checkPositiveInt rawQ))
  (when (check-fail? tesl-checked-10)
    (raise-user-error 'tesl-test "unexpected failure in let q: ~a" (check-fail-message tesl-checked-10)))
  (define q tesl-checked-10)
  (define tesl-checked-11 (checkPriceExceedsQuantity p q))
  (when (check-fail? tesl-checked-11)
    (raise-user-error 'tesl-test "unexpected failure in let pq: ~a" (check-fail-message tesl-checked-11)))
  (define pq tesl-checked-11)
  (define order (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 270 (list (cons 'pq pq) (cons 'q q) (cons 'rawQ rawQ) (cons 'p p) (cons 'rawP rawP)) (lambda () (makeOrderLine p q (detach-all-proof pq)))))
  (define orderAlt (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 271 (list (cons 'order order) (cons 'pq pq) (cons 'q q) (cons 'rawQ rawQ) (cons 'p p) (cons 'rawP rawP)) (lambda () (attach-proof (OrderLine #:price p #:quantity q) (detach-all-proof pq)))))
  (check-equal? (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 272 (list (cons 'orderAlt orderAlt) (cons 'order order) (cons 'pq pq) (cons 'q q) (cons 'rawQ rawQ) (cons 'p p) (cons 'rawP rawP)) (lambda () (raw-value (tesl-dot/runtime order 'price)))) 10)
  (check-equal? (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 273 (list (cons 'orderAlt orderAlt) (cons 'order order) (cons 'pq pq) (cons 'q q) (cons 'rawQ rawQ) (cons 'p p) (cons 'rawP rawP)) (lambda () (raw-value (tesl-dot/runtime order 'quantity)))) 3)
    ))
  )

  (test-case "checkPriceExceedsQuantity rejects price <= quantity"
    (call-with-fresh-memory-db '() (lambda ()
  (define rawP (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 279 (list) (lambda () 3)))
  (define tesl-checked-12 (checkPositiveInt rawP))
  (when (check-fail? tesl-checked-12)
    (raise-user-error 'tesl-test "unexpected failure in let p: ~a" (check-fail-message tesl-checked-12)))
  (define p tesl-checked-12)
  (define rawQ (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 281 (list (cons 'p p) (cons 'rawP rawP)) (lambda () 10)))
  (define tesl-checked-13 (checkPositiveInt rawQ))
  (when (check-fail? tesl-checked-13)
    (raise-user-error 'tesl-test "unexpected failure in let q: ~a" (check-fail-message tesl-checked-13)))
  (define q tesl-checked-13)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson12-records-with-proofs.tesl" 283 (list (cons 'q q) (cons 'rawQ rawQ) (cons 'p p) (cons 'rawP rawP)) (lambda ()
                          (checkPriceExceedsQuantity p q))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPriceExceedsQuantity p q"))
    ))
  )

)
