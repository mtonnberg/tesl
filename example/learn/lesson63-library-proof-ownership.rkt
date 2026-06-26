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


(provide IsValidEmail checkEmail requiresValidEmail describeEmail validateAndDescribe checkEmail-signature requiresValidEmail-signature describeEmail-signature validateAndDescribe-signature)

(define IsValidEmail 'IsValidEmail)

(define-checker
  (checkEmail [addr : String])
  #:returns [addr : String ::: (IsValidEmail addr)]
  (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 72 (list (cons 'addr *addr)) (lambda () (if (equal? (raw-value (tesl_import_String_contains *addr "@")) #f) (reject "email must contain @" #:http-code 400) (if (< (raw-value (tesl_import_String_length *addr)) 5) (reject "email address too short" #:http-code 400) (if (> (raw-value (tesl_import_String_length *addr)) 200) (reject "email address too long" #:http-code 400) (accept (IsValidEmail addr) #:value *addr)))))))

(define/pow
  (requiresValidEmail [addr : String ::: (IsValidEmail addr)])
  #:returns String
  (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 87 (list (cons 'addr *addr)) (lambda () (format "sending to: ~a" (tesl-display-val *addr)))))

(define/pow
  (describeEmail [addr : String ::: (IsValidEmail addr)])
  #:returns String
  (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 92 (list (cons 'addr *addr)) (lambda () (if (<= (raw-value (tesl_import_String_length *addr)) 20) (raw-value "short address") (if (<= (raw-value (tesl_import_String_length *addr)) 50) (raw-value "medium address") (raw-value "long address"))))))

(define/pow
  (validateAndDescribe [raw : String])
  #:returns String
  (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 104 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_0 (checkEmail raw)]) (let ([addr tesl_checked_0]) (let ([msg (requiresValidEmail addr)]) (let ([desc (describeEmail addr)]) (format "~a (~a)" (tesl-display-val *msg) (tesl-display-val *desc)))))))))

(module+ test
  (require rackunit)
  (test-case "checkEmail accepts a valid address"
  (define raw (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 187 (list) (lambda () "alice@example.com")))
  (define tesl_checked_1 (checkEmail raw))
  (when (check-fail? tesl_checked_1)
    (raise-user-error 'tesl-test "unexpected failure in let addr: ~a" (check-fail-message tesl_checked_1)))
  (define addr tesl_checked_1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 189 (list (cons 'addr addr) (cons 'raw raw)) (lambda () (requiresValidEmail addr)))) "sending to: alice@example.com")
  )

  (test-case "checkEmail accepts a minimal valid address"
  (define raw (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 193 (list) (lambda () "a@b.c")))
  (define tesl_checked_2 (checkEmail raw))
  (when (check-fail? tesl_checked_2)
    (raise-user-error 'tesl-test "unexpected failure in let addr: ~a" (check-fail-message tesl_checked_2)))
  (define addr tesl_checked_2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 195 (list (cons 'addr addr) (cons 'raw raw)) (lambda () (describeEmail addr)))) "short address")
  )

  (test-case "checkEmail rejects address without @"
  (define raw (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 199 (list) (lambda () "notanemail")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 200 (list (cons 'raw raw)) (lambda ()
                          ((raw-value (checkEmail raw)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkEmail raw)) (list)"))
  )

  (test-case "checkEmail rejects address that is too short"
  (define raw (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 204 (list) (lambda () "a@b")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 205 (list (cons 'raw raw)) (lambda ()
                          ((raw-value (checkEmail raw)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkEmail raw)) (list)"))
  )

  (test-case "checkEmail rejects an empty string"
  (define raw (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 209 (list) (lambda () "")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 210 (list (cons 'raw raw)) (lambda ()
                          ((raw-value (checkEmail raw)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkEmail raw)) (list)"))
  )

  (test-case "describeEmail classifies short address"
  (define raw (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 214 (list) (lambda () "hi@example.com")))
  (define tesl_checked_3 (checkEmail raw))
  (when (check-fail? tesl_checked_3)
    (raise-user-error 'tesl-test "unexpected failure in let addr: ~a" (check-fail-message tesl_checked_3)))
  (define addr tesl_checked_3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 216 (list (cons 'addr addr) (cons 'raw raw)) (lambda () (describeEmail addr)))) "short address")
  )

  (test-case "describeEmail classifies medium address"
  (define raw (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 220 (list) (lambda () "firstname.lastname@workplace-domain.org")))
  (define tesl_checked_4 (checkEmail raw))
  (when (check-fail? tesl_checked_4)
    (raise-user-error 'tesl-test "unexpected failure in let addr: ~a" (check-fail-message tesl_checked_4)))
  (define addr tesl_checked_4)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 222 (list (cons 'addr addr) (cons 'raw raw)) (lambda () (describeEmail addr)))) "medium address")
  )

  (test-case "validateAndDescribe composes check and consumers"
  (define raw (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 226 (list) (lambda () "bob@example.com")))
  (define result (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 227 (list (cons 'raw raw)) (lambda () (validateAndDescribe raw))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 228 (list (cons 'result result) (cons 'raw raw)) (lambda () result))) "sending to: bob@example.com (short address)")
  )

  (test-case "validateAndDescribe fails on invalid input"
  (define raw (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 232 (list) (lambda () "badaddress")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 233 (list (cons 'raw raw)) (lambda ()
                          ((validateAndDescribe raw) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (validateAndDescribe raw) (list)"))
  )

  (test-case "proof flows through multiple function calls"
  (define raw (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 237 (list) (lambda () "carol@example.com")))
  (define tesl_checked_5 (checkEmail raw))
  (when (check-fail? tesl_checked_5)
    (raise-user-error 'tesl-test "unexpected failure in let addr: ~a" (check-fail-message tesl_checked_5)))
  (define addr tesl_checked_5)
  (define msg (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 239 (list (cons 'addr addr) (cons 'raw raw)) (lambda () (requiresValidEmail addr))))
  (define desc (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 240 (list (cons 'msg msg) (cons 'addr addr) (cons 'raw raw)) (lambda () (describeEmail addr))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 241 (list (cons 'desc desc) (cons 'msg msg) (cons 'addr addr) (cons 'raw raw)) (lambda () msg))) "sending to: carol@example.com")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson63-library-proof-ownership.tesl" 242 (list (cons 'desc desc) (cons 'msg msg) (cons 'addr addr) (cons 'raw raw)) (lambda () desc))) "short address")
  )

)
