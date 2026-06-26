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
  (only-in tesl/tesl/prelude Int String)
  (only-in tesl/tesl/string [String.fromInt tesl_import_String_fromInt])
)


(provide describeInt httpStatusText parseCommand classifyChar discountForTier describeInt-signature httpStatusText-signature parseCommand-signature classifyChar-signature discountForTier-signature)

(define/pow
  (describeInt [n : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 39 (list (cons 'n *n)) (lambda () (let ([tesl_case_0 *n]) (cond [(= *tesl_case_0 0) (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 40 (list) (lambda () (raw-value "zero")))] [(= *tesl_case_0 1) (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 41 (list) (lambda () (raw-value "one")))] [(= *tesl_case_0 2) (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 42 (list) (lambda () (raw-value "two")))] [#t (let ([other *tesl_case_0]) (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 43 (list (cons 'other other)) (lambda () (raw-value (format "many (~a)" (tesl-display-val (tesl_import_String_fromInt *other)))))))])))))

(define/pow
  (httpStatusText [code : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 47 (list (cons 'code *code)) (lambda () (let ([tesl_case_1 *code]) (cond [(= *tesl_case_1 200) (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 48 (list) (lambda () (raw-value "OK")))] [(= *tesl_case_1 201) (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 49 (list) (lambda () (raw-value "Created")))] [(= *tesl_case_1 204) (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 50 (list) (lambda () (raw-value "No Content")))] [(= *tesl_case_1 400) (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 51 (list) (lambda () (raw-value "Bad Request")))] [(= *tesl_case_1 401) (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 52 (list) (lambda () (raw-value "Unauthorized")))] [(= *tesl_case_1 403) (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 53 (list) (lambda () (raw-value "Forbidden")))] [(= *tesl_case_1 404) (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 54 (list) (lambda () (raw-value "Not Found")))] [(= *tesl_case_1 500) (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 55 (list) (lambda () (raw-value "Internal Server Error")))] [#t (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 56 (list) (lambda () (raw-value "Unknown")))])))))

(define/pow
  (parseCommand [cmd : String])
  #:returns String
  (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 64 (list (cons 'cmd *cmd)) (lambda () (let ([tesl_case_2 *cmd]) (cond [(equal? *tesl_case_2 "help") (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 65 (list) (lambda () (raw-value "show help")))] [(equal? *tesl_case_2 "version") (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 66 (list) (lambda () (raw-value "show version")))] [(equal? *tesl_case_2 "exit") (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 67 (list) (lambda () (raw-value "exit application")))] [#t (let ([other *tesl_case_2]) (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 68 (list (cons 'other other)) (lambda () (raw-value (format "unknown command: ~a" (tesl-display-val *other))))))])))))

(define/pow
  (classifyChar [c : String])
  #:returns String
  (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 72 (list (cons 'c *c)) (lambda () (let ([tesl_case_3 *c]) (cond [(equal? *tesl_case_3 "a") (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 73 (list) (lambda () (raw-value "vowel")))] [(equal? *tesl_case_3 "e") (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 74 (list) (lambda () (raw-value "vowel")))] [(equal? *tesl_case_3 "i") (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 75 (list) (lambda () (raw-value "vowel")))] [(equal? *tesl_case_3 "o") (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 76 (list) (lambda () (raw-value "vowel")))] [(equal? *tesl_case_3 "u") (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 77 (list) (lambda () (raw-value "vowel")))] [#t (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 78 (list) (lambda () (raw-value "consonant or other")))])))))

(define-adt Tier
  [Free]
  [Silver]
  [Gold]
  [Enterprise]
)

(define/pow
  (discountForTier [tier : Tier] [promoCode : String])
  #:returns Integer
  (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 92 (list (cons 'tier *tier) (cons 'promoCode *promoCode)) (lambda () (let ([tesl_case_4 *tier]) (cond [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Enterprise)) (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 93 (list) (lambda () (raw-value 40)))] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Gold)) (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 94 (list) (lambda () (raw-value 25)))] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Silver)) (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 95 (list) (lambda () (raw-value 10)))] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Free)) (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 97 (list) (lambda () (let ([tesl_case_5 *promoCode]) (cond [(equal? *tesl_case_5 "WELCOME10") (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 98 (list) (lambda () (raw-value 10)))] [(equal? *tesl_case_5 "SUMMER20") (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 99 (list) (lambda () (raw-value 20)))] [#t (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 100 (list) (lambda () (raw-value 0)))]))))])))))

(module+ test
  (require rackunit)
  (test-case "describeInt"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 125 (list) (lambda () (describeInt 0)))) "zero")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 126 (list) (lambda () (describeInt 1)))) "one")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 127 (list) (lambda () (describeInt 2)))) "two")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 128 (list) (lambda () (describeInt 99)))) "many (99)")
  )

  (test-case "httpStatusText"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 132 (list) (lambda () (httpStatusText 200)))) "OK")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 133 (list) (lambda () (httpStatusText 404)))) "Not Found")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 134 (list) (lambda () (httpStatusText 999)))) "Unknown")
  )

  (test-case "parseCommand"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 138 (list) (lambda () (parseCommand "help")))) "show help")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 139 (list) (lambda () (parseCommand "version")))) "show version")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 140 (list) (lambda () (parseCommand "deploy")))) "unknown command: deploy")
  )

  (test-case "classifyChar"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 144 (list) (lambda () (classifyChar "a")))) "vowel")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 145 (list) (lambda () (classifyChar "b")))) "consonant or other")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 146 (list) (lambda () (classifyChar "i")))) "vowel")
  )

  (test-case "discountForTier"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 150 (list) (lambda () (discountForTier Enterprise "any")))) 40)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 151 (list) (lambda () (discountForTier Gold "any")))) 25)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 152 (list) (lambda () (discountForTier Free "WELCOME10")))) 10)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 153 (list) (lambda () (discountForTier Free "SUMMER20")))) 20)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson49-literal-patterns.tesl" 154 (list) (lambda () (discountForTier Free "INVALID")))) 0)
  )

)
