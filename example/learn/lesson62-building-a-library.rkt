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
)


(provide UserName IsValidName checkName describeNameLength formatGreeting checkName-signature describeNameLength-signature formatGreeting-signature)

(define IsValidName 'IsValidName)

(define-record UserName
  [value : String]
)

(define-checker
  (checkName [name : String])
  #:returns [name : String ::: (IsValidName name)]
  (thsl-src! "example/learn/lesson62-building-a-library.tesl" 112 (list (cons 'name *name)) (lambda () (if (< (raw-value (tesl_import_String_length *name)) 2) (reject "username must be at least 2 characters" #:http-code 400) (if (> (raw-value (tesl_import_String_length *name)) 50) (reject "username must be at most 50 characters" #:http-code 400) (if (tesl_import_String_contains *name "@") (reject "username must not contain @" #:http-code 400) (accept (IsValidName name) #:value *name)))))))

(define/pow
  (describeNameLength [name : String ::: (IsValidName name)])
  #:returns String
  (thsl-src! "example/learn/lesson62-building-a-library.tesl" 126 (list (cons 'name *name)) (lambda () (if (<= (raw-value (tesl_import_String_length *name)) 10) (raw-value "short") (if (<= (raw-value (tesl_import_String_length *name)) 30) (raw-value "medium") (raw-value "long"))))))

(define/pow
  (formatGreeting [name : String ::: (IsValidName name)])
  #:returns String
  (thsl-src! "example/learn/lesson62-building-a-library.tesl" 137 (list (cons 'name *name)) (lambda () (format "Hello, ~a!" (tesl-display-val *name)))))

(module+ test
  (require rackunit)
  (test-case "checkName accepts a valid username"
  (define raw (thsl-src! "example/learn/lesson62-building-a-library.tesl" 198 (list) (lambda () "alice")))
  (define tesl_checked_0 (checkName raw))
  (when (check-fail? tesl_checked_0)
    (raise-user-error 'tesl-test "unexpected failure in let name: ~a" (check-fail-message tesl_checked_0)))
  (define name tesl_checked_0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson62-building-a-library.tesl" 200 (list (cons 'name name) (cons 'raw raw)) (lambda () (formatGreeting name)))) "Hello, alice!")
  )

  (test-case "checkName accepts a name at the lower length boundary"
  (define raw (thsl-src! "example/learn/lesson62-building-a-library.tesl" 204 (list) (lambda () "ab")))
  (define tesl_checked_1 (checkName raw))
  (when (check-fail? tesl_checked_1)
    (raise-user-error 'tesl-test "unexpected failure in let name: ~a" (check-fail-message tesl_checked_1)))
  (define name tesl_checked_1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson62-building-a-library.tesl" 206 (list (cons 'name name) (cons 'raw raw)) (lambda () (describeNameLength name)))) "short")
  )

  (test-case "checkName accepts a medium-length name"
  (define raw (thsl-src! "example/learn/lesson62-building-a-library.tesl" 210 (list) (lambda () "alexanderthegreater")))
  (define tesl_checked_2 (checkName raw))
  (when (check-fail? tesl_checked_2)
    (raise-user-error 'tesl-test "unexpected failure in let name: ~a" (check-fail-message tesl_checked_2)))
  (define name tesl_checked_2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson62-building-a-library.tesl" 212 (list (cons 'name name) (cons 'raw raw)) (lambda () (describeNameLength name)))) "medium")
  )

  (test-case "checkName rejects a single-character name"
  (define raw (thsl-src! "example/learn/lesson62-building-a-library.tesl" 216 (list) (lambda () "a")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson62-building-a-library.tesl" 217 (list (cons 'raw raw)) (lambda ()
                          ((raw-value (checkName raw)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkName raw)) (list)"))
  )

  (test-case "checkName rejects an empty string"
  (define raw (thsl-src! "example/learn/lesson62-building-a-library.tesl" 221 (list) (lambda () "")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson62-building-a-library.tesl" 222 (list (cons 'raw raw)) (lambda ()
                          ((raw-value (checkName raw)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkName raw)) (list)"))
  )

  (test-case "checkName rejects a name with @ symbol"
  (define raw (thsl-src! "example/learn/lesson62-building-a-library.tesl" 226 (list) (lambda () "alice@example")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson62-building-a-library.tesl" 227 (list (cons 'raw raw)) (lambda ()
                          ((raw-value (checkName raw)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkName raw)) (list)"))
  )

  (test-case "checkName rejects a name that is too long"
  (define raw (thsl-src! "example/learn/lesson62-building-a-library.tesl" 231 (list) (lambda () "this-username-is-way-too-long-for-our-system-abcdefghijk")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson62-building-a-library.tesl" 232 (list (cons 'raw raw)) (lambda ()
                          ((raw-value (checkName raw)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkName raw)) (list)"))
  )

  (test-case "describeNameLength returns short for a short name"
  (define raw (thsl-src! "example/learn/lesson62-building-a-library.tesl" 236 (list) (lambda () "bob")))
  (define tesl_checked_3 (checkName raw))
  (when (check-fail? tesl_checked_3)
    (raise-user-error 'tesl-test "unexpected failure in let name: ~a" (check-fail-message tesl_checked_3)))
  (define name tesl_checked_3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson62-building-a-library.tesl" 238 (list (cons 'name name) (cons 'raw raw)) (lambda () (describeNameLength name)))) "short")
  )

  (test-case "describeNameLength returns long for a long name"
  (define raw (thsl-src! "example/learn/lesson62-building-a-library.tesl" 242 (list) (lambda () "christopher-alexander-von-humboldt")))
  (define tesl_checked_4 (checkName raw))
  (when (check-fail? tesl_checked_4)
    (raise-user-error 'tesl-test "unexpected failure in let name: ~a" (check-fail-message tesl_checked_4)))
  (define name tesl_checked_4)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson62-building-a-library.tesl" 244 (list (cons 'name name) (cons 'raw raw)) (lambda () (describeNameLength name)))) "long")
  )

  (test-case "formatGreeting produces the expected string"
  (define raw (thsl-src! "example/learn/lesson62-building-a-library.tesl" 248 (list) (lambda () "tesl")))
  (define tesl_checked_5 (checkName raw))
  (when (check-fail? tesl_checked_5)
    (raise-user-error 'tesl-test "unexpected failure in let name: ~a" (check-fail-message tesl_checked_5)))
  (define name tesl_checked_5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson62-building-a-library.tesl" 250 (list (cons 'name name) (cons 'raw raw)) (lambda () (formatGreeting name)))) "Hello, tesl!")
  )

)
