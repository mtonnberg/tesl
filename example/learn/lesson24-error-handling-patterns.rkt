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
  (only-in tesl/tesl/prelude Int String Bool)
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.contains tesl_import_String_contains])
  (only-in tesl/tesl/int [Int.parse tesl_import_Int_parse])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
)


(provide ValidEmail checkEmail ValidAge checkAge createUser processRequest parseAndValidate checkEmail-signature checkAge-signature createUser-signature parseAndValidate-signature processRequest-signature)

(define NonEmpty 'NonEmpty)
(define ValidAge 'ValidAge)
(define ValidEmail 'ValidEmail)

(define-checker
  (checkEmail [s : String])
  #:returns [s : String ::: (ValidEmail s)]
  (thsl-src! "example/learn/lesson24-error-handling-patterns.tesl" 37 (list (cons 's *s)) (lambda () (if (and (raw-value (tesl_import_String_contains *s "@")) (> (raw-value (tesl_import_String_length *s)) 3)) (accept (ValidEmail s) #:value *s) (reject "invalid email address" #:http-code 400)))))

(define-checker
  (checkAge [n : Integer])
  #:returns [n : Integer ::: (ValidAge n)]
  (thsl-src! "example/learn/lesson24-error-handling-patterns.tesl" 43 (list (cons 'n *n)) (lambda () (if (and (>= *n 0) (<= *n 150)) (accept (ValidAge n) #:value *n) (reject "age must be between 0 and 150" #:http-code 400)))))

(define-record NewUserRequest
  [email : String]
  [age : Integer]
)

(define-record UserRecord
  [email : String ::: (ValidEmail email)]
  [age : Integer ::: (ValidAge age)]
)

(define/pow
  (createUser [req : NewUserRequest])
  #:returns UserRecord
  (thsl-src! "example/learn/lesson24-error-handling-patterns.tesl" 63 (list (cons 'req *req)) (lambda () (let/check ([tesl-checked-0 (checkEmail (tesl-dot/runtime req 'email))]) (let ([validEmail tesl-checked-0]) (let/check ([tesl-checked-1 (checkAge (tesl-dot/runtime req 'age))]) (let ([validAge tesl-checked-1]) (UserRecord #:email validEmail #:age validAge))))))))

(define-checker
  (parseAndValidate [ageStr : String])
  #:returns [n : Integer ::: (ValidAge n)]
  (thsl-src-control! "example/learn/lesson24-error-handling-patterns.tesl" 72 (list (cons 'ageStr *ageStr)) (lambda () (let ([tesl-case-2 (raw-value (tesl_import_Int_parse *ageStr))]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "example/learn/lesson24-error-handling-patterns.tesl" 73 (list) (lambda () (reject "age must be a number" #:http-code 400)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([parsed (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "example/learn/lesson24-error-handling-patterns.tesl" 75 (list (cons 'parsed parsed)) (lambda () (checkAge parsed))))])))))

(define-checker
  (checkNonEmpty [s : String])
  #:returns [s : String ::: (NonEmpty s)]
  (thsl-src! "example/learn/lesson24-error-handling-patterns.tesl" 84 (list (cons 's *s)) (lambda () (if (> (raw-value (tesl_import_String_length *s)) 0) (accept (NonEmpty s) #:value *s) (reject "must not be empty" #:http-code 400)))))

(define/pow
  (processRequest [req : NewUserRequest])
  #:returns String
  (thsl-src! "example/learn/lesson24-error-handling-patterns.tesl" 90 (list (cons 'req *req)) (lambda () (let/check ([tesl-checked-3 ((check-and checkEmail checkNonEmpty) (tesl-dot/runtime req 'email))]) (let ([email tesl-checked-3]) (let/check ([tesl-checked-4 (checkAge (tesl-dot/runtime req 'age))]) (let ([age tesl-checked-4]) (format "processed ~a age ~a" (tesl-display-val *email) (tesl-display-val *age)))))))))

(module+ test
  (require rackunit)
  (test-case "valid email passes check"
  (define email (thsl-src! "example/learn/lesson24-error-handling-patterns.tesl" 122 (list) (lambda () "user@example.com")))
  (define tesl-checked-5 (checkEmail email))
  (when (check-fail? tesl-checked-5)
    (raise-user-error 'tesl-test "unexpected failure in let result: ~a" (check-fail-message tesl-checked-5)))
  (define result tesl-checked-5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson24-error-handling-patterns.tesl" 124 (list (cons 'result result) (cons 'email email)) (lambda () result))) "user@example.com")
  )

  (test-case "invalid email is rejected"
  (define email (thsl-src! "example/learn/lesson24-error-handling-patterns.tesl" 128 (list) (lambda () "notanemail")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson24-error-handling-patterns.tesl" 129 (list (cons 'email email)) (lambda ()
                          ((raw-value (checkEmail email)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkEmail email)) (list)"))
  )

  (test-case "valid age passes check"
  (define age (thsl-src! "example/learn/lesson24-error-handling-patterns.tesl" 133 (list) (lambda () 25)))
  (define tesl-checked-6 (checkAge age))
  (when (check-fail? tesl-checked-6)
    (raise-user-error 'tesl-test "unexpected failure in let result: ~a" (check-fail-message tesl-checked-6)))
  (define result tesl-checked-6)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson24-error-handling-patterns.tesl" 135 (list (cons 'result result) (cons 'age age)) (lambda () result))) 25)
  )

  (test-case "negative age is rejected"
  (define age (thsl-src! "example/learn/lesson24-error-handling-patterns.tesl" 139 (list) (lambda () -1)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson24-error-handling-patterns.tesl" 140 (list (cons 'age age)) (lambda ()
                          ((raw-value (checkAge age)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkAge age)) (list)"))
  )

  (test-case "age above 150 is rejected"
  (define age (thsl-src! "example/learn/lesson24-error-handling-patterns.tesl" 144 (list) (lambda () 200)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson24-error-handling-patterns.tesl" 145 (list (cons 'age age)) (lambda ()
                          ((raw-value (checkAge age)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkAge age)) (list)"))
  )

  (test-case "parseAndValidate rejects non-numeric string"
  (define s (thsl-src! "example/learn/lesson24-error-handling-patterns.tesl" 149 (list) (lambda () "notanumber")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson24-error-handling-patterns.tesl" 150 (list (cons 's s)) (lambda ()
                          ((raw-value (parseAndValidate s)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (parseAndValidate s)) (list)"))
  )

)
