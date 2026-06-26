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


(provide IsValidEmail checkUsername checkEmail formatUserSummary UserProfile checkUsername-signature checkEmail-signature formatUserSummary-signature)

(define IsValidEmail 'IsValidEmail)
(define IsValidUsername 'IsValidUsername)

(define-checker
  (checkUsername [name : String])
  #:returns [name : String ::: (IsValidUsername name)]
  (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 85 (list (cons 'name *name)) (lambda () (if (< (raw-value (tesl_import_String_length *name)) 2) (reject "username must be at least 2 characters" #:http-code 400) (if (> (raw-value (tesl_import_String_length *name)) 30) (reject "username must be at most 30 characters" #:http-code 400) (if (tesl_import_String_contains *name "@") (reject "username must not contain @" #:http-code 400) (accept (IsValidUsername name) #:value *name)))))))

(define-checker
  (checkEmail [addr : String])
  #:returns [addr : String ::: (IsValidEmail addr)]
  (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 99 (list (cons 'addr *addr)) (lambda () (if (equal? (raw-value (tesl_import_String_contains *addr "@")) #f) (reject "email must contain @" #:http-code 400) (if (< (raw-value (tesl_import_String_length *addr)) 5) (reject "email address too short" #:http-code 400) (if (> (raw-value (tesl_import_String_length *addr)) 200) (reject "email address too long" #:http-code 400) (accept (IsValidEmail addr) #:value *addr)))))))

(define-record UserProfile
  [username : String ::: (IsValidUsername username)]
  [email : String ::: (IsValidEmail email)]
)

(define/pow
  (describeUser [profile : UserProfile])
  #:returns String
  (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 124 (list (cons 'profile *profile)) (lambda () (format "user ~a <~a>" (tesl-display-val (raw-value profile.username)) (tesl-display-val (raw-value profile.email))))))

(define/pow
  (formatUserSummary [rawName : String] [rawEmail : String])
  #:returns String
  (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 131 (list (cons 'rawName *rawName) (cons 'rawEmail *rawEmail)) (lambda () (let/check ([tesl_checked_0 (checkUsername rawName)]) (let ([name tesl_checked_0]) (let/check ([tesl_checked_1 (checkEmail rawEmail)]) (let ([addr tesl_checked_1]) (let ([profile (UserProfile #:username name #:email addr)]) (raw-value (describeUser profile))))))))))

(module+ test
  (require rackunit)
  (test-case "checkUsername accepts a valid username"
  (define rawName (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 213 (list) (lambda () "alice")))
  (define rawEmail (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 214 (list (cons 'rawName rawName)) (lambda () "alice@example.com")))
  (define tesl_checked_2 (checkUsername rawName))
  (when (check-fail? tesl_checked_2)
    (raise-user-error 'tesl-test "unexpected failure in let name: ~a" (check-fail-message tesl_checked_2)))
  (define name tesl_checked_2)
  (define tesl_checked_3 (checkEmail rawEmail))
  (when (check-fail? tesl_checked_3)
    (raise-user-error 'tesl-test "unexpected failure in let addr: ~a" (check-fail-message tesl_checked_3)))
  (define addr tesl_checked_3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 217 (list (cons 'addr addr) (cons 'name name) (cons 'rawEmail rawEmail) (cons 'rawName rawName)) (lambda () (describeUser (UserProfile #:username name #:email addr))))) "user alice <alice@example.com>")
  )

  (test-case "checkUsername rejects too-short username"
  (define raw (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 221 (list) (lambda () "a")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 222 (list (cons 'raw raw)) (lambda ()
                          ((raw-value (checkUsername raw)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkUsername raw)) (list)"))
  )

  (test-case "checkUsername rejects username with @"
  (define raw (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 226 (list) (lambda () "alice@bad")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 227 (list (cons 'raw raw)) (lambda ()
                          ((raw-value (checkUsername raw)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkUsername raw)) (list)"))
  )

  (test-case "checkEmail accepts a valid email"
  (define rawEmail (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 231 (list) (lambda () "bob@example.com")))
  (define rawName (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 232 (list (cons 'rawEmail rawEmail)) (lambda () "bob")))
  (define tesl_checked_4 (checkEmail rawEmail))
  (when (check-fail? tesl_checked_4)
    (raise-user-error 'tesl-test "unexpected failure in let addr: ~a" (check-fail-message tesl_checked_4)))
  (define addr tesl_checked_4)
  (define tesl_checked_5 (checkUsername rawName))
  (when (check-fail? tesl_checked_5)
    (raise-user-error 'tesl-test "unexpected failure in let name: ~a" (check-fail-message tesl_checked_5)))
  (define name tesl_checked_5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 235 (list (cons 'name name) (cons 'addr addr) (cons 'rawName rawName) (cons 'rawEmail rawEmail)) (lambda () (describeUser (UserProfile #:username name #:email addr))))) "user bob <bob@example.com>")
  )

  (test-case "checkEmail rejects address without @"
  (define raw (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 239 (list) (lambda () "notanemail")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 240 (list (cons 'raw raw)) (lambda ()
                          ((raw-value (checkEmail raw)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkEmail raw)) (list)"))
  )

  (test-case "formatUserSummary produces correct output"
  (define result (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 244 (list) (lambda () (formatUserSummary "carol" "carol@example.com"))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 245 (list (cons 'result result)) (lambda () result))) "user carol <carol@example.com>")
  )

  (test-case "formatUserSummary fails when username is invalid"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 249 (list) (lambda ()
                          ((formatUserSummary "x" "x@example.com") (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (formatUserSummary \"x\" \"x@example.com\") (list)"))
  )

  (test-case "formatUserSummary fails when email is invalid"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 253 (list) (lambda ()
                          ((formatUserSummary "dave" "notanemail") (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (formatUserSummary \"dave\" \"notanemail\") (list)"))
  )

  (test-case "formatUserSummary fails when both are invalid"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 257 (list) (lambda ()
                          ((formatUserSummary "x" "notanemail") (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (formatUserSummary \"x\" \"notanemail\") (list)"))
  )

  (test-case "UserProfile requires both proofs"
  (define rawName (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 261 (list) (lambda () "eve")))
  (define rawEmail (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 262 (list (cons 'rawName rawName)) (lambda () "eve@example.com")))
  (define tesl_checked_6 (checkUsername rawName))
  (when (check-fail? tesl_checked_6)
    (raise-user-error 'tesl-test "unexpected failure in let name: ~a" (check-fail-message tesl_checked_6)))
  (define name tesl_checked_6)
  (define tesl_checked_7 (checkEmail rawEmail))
  (when (check-fail? tesl_checked_7)
    (raise-user-error 'tesl-test "unexpected failure in let addr: ~a" (check-fail-message tesl_checked_7)))
  (define addr tesl_checked_7)
  (define profile (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 265 (list (cons 'addr addr) (cons 'name name) (cons 'rawEmail rawEmail) (cons 'rawName rawName)) (lambda () (UserProfile #:username name #:email addr))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson64-re-exporting-from-libraries.tesl" 266 (list (cons 'profile profile) (cons 'addr addr) (cons 'name name) (cons 'rawEmail rawEmail) (cons 'rawName rawName)) (lambda () (describeUser profile)))) "user eve <eve@example.com>")
  )

)
