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
  (only-in tesl/tesl/prelude Int String)
  (only-in tesl/tesl/string [String.fromInt tesl_import_String_fromInt])
)


(provide describeInt httpStatusText parseCommand classifyChar discountForTier describeInt-signature httpStatusText-signature parseCommand-signature classifyChar-signature discountForTier-signature)

(define/pow
  (describeInt [n : Integer])
  #:returns String
  (let ([tesl_case_0 *n]) (cond [(= *tesl_case_0 0) (raw-value "zero")] [(= *tesl_case_0 1) (raw-value "one")] [(= *tesl_case_0 2) (raw-value "two")] [#t (let ([other *tesl_case_0]) (raw-value (format "many (~a)" (tesl-display-val (tesl_import_String_fromInt *other)))))])))

(define/pow
  (httpStatusText [code : Integer])
  #:returns String
  (let ([tesl_case_1 *code]) (cond [(= *tesl_case_1 200) (raw-value "OK")] [(= *tesl_case_1 201) (raw-value "Created")] [(= *tesl_case_1 204) (raw-value "No Content")] [(= *tesl_case_1 400) (raw-value "Bad Request")] [(= *tesl_case_1 401) (raw-value "Unauthorized")] [(= *tesl_case_1 403) (raw-value "Forbidden")] [(= *tesl_case_1 404) (raw-value "Not Found")] [(= *tesl_case_1 500) (raw-value "Internal Server Error")] [#t (raw-value "Unknown")])))

(define/pow
  (parseCommand [cmd : String])
  #:returns String
  (let ([tesl_case_2 *cmd]) (cond [(equal? *tesl_case_2 "help") (raw-value "show help")] [(equal? *tesl_case_2 "version") (raw-value "show version")] [(equal? *tesl_case_2 "exit") (raw-value "exit application")] [#t (let ([other *tesl_case_2]) (raw-value (format "unknown command: ~a" (tesl-display-val *other))))])))

(define/pow
  (classifyChar [c : String])
  #:returns String
  (let ([tesl_case_3 *c]) (cond [(equal? *tesl_case_3 "a") (raw-value "vowel")] [(equal? *tesl_case_3 "e") (raw-value "vowel")] [(equal? *tesl_case_3 "i") (raw-value "vowel")] [(equal? *tesl_case_3 "o") (raw-value "vowel")] [(equal? *tesl_case_3 "u") (raw-value "vowel")] [#t (raw-value "consonant or other")])))

(define-adt Tier
  [Free]
  [Silver]
  [Gold]
  [Enterprise]
)

(define/pow
  (discountForTier [tier : Tier] [promoCode : String])
  #:returns Integer
  (let ([tesl_case_4 *tier]) (cond [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Enterprise)) (raw-value 40)] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Gold)) (raw-value 25)] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Silver)) (raw-value 10)] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Free)) (let ([tesl_case_5 *promoCode]) (cond [(equal? *tesl_case_5 "WELCOME10") (raw-value 10)] [(equal? *tesl_case_5 "SUMMER20") (raw-value 20)] [#t (raw-value 0)]))])))

(module+ test
  (require rackunit)
  (test-case "describeInt"
  (check-equal? (raw-value (describeInt 0)) "zero")
  (check-equal? (raw-value (describeInt 1)) "one")
  (check-equal? (raw-value (describeInt 2)) "two")
  (check-equal? (raw-value (describeInt 99)) "many (99)")
  )

  (test-case "httpStatusText"
  (check-equal? (raw-value (httpStatusText 200)) "OK")
  (check-equal? (raw-value (httpStatusText 404)) "Not Found")
  (check-equal? (raw-value (httpStatusText 999)) "Unknown")
  )

  (test-case "parseCommand"
  (check-equal? (raw-value (parseCommand "help")) "show help")
  (check-equal? (raw-value (parseCommand "version")) "show version")
  (check-equal? (raw-value (parseCommand "deploy")) "unknown command: deploy")
  )

  (test-case "classifyChar"
  (check-equal? (raw-value (classifyChar "a")) "vowel")
  (check-equal? (raw-value (classifyChar "b")) "consonant or other")
  (check-equal? (raw-value (classifyChar "i")) "vowel")
  )

  (test-case "discountForTier"
  (check-equal? (raw-value (discountForTier Enterprise "any")) 40)
  (check-equal? (raw-value (discountForTier Gold "any")) 25)
  (check-equal? (raw-value (discountForTier Free "WELCOME10")) 10)
  (check-equal? (raw-value (discountForTier Free "SUMMER20")) 20)
  (check-equal? (raw-value (discountForTier Free "INVALID")) 0)
  )

)
