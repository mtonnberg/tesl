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
  (only-in tesl/tesl/prelude Bool Int String)
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.contains tesl_import_String_contains])
)


(provide ValidName NonEmpty InRange checkNonEmpty checkInRange checkName processName processNameManual checkNonEmpty-signature checkName-signature processName-signature checkInRange-signature processNameManual-signature)

(define HasAt 'HasAt)
(define InRange 'InRange)
(define LongEnough 'LongEnough)
(define NonEmpty 'NonEmpty)
(define ValidName 'ValidName)

(define-checker
  (checkNonEmpty [name : String])
  #:returns [name : String ::: (NonEmpty name)]
  (if (> (raw-value (tesl_import_String_length *name)) 0) (accept (NonEmpty name) #:value *name) (reject "name must not be empty" #:http-code 400)))

(define-checker
  (checkName [name : String ::: (NonEmpty name)])
  #:returns [name : String ::: (ValidName name)]
  (if (<= (raw-value (tesl_import_String_length *name)) 100) (accept (ValidName name) #:value *name) (reject "name too long" #:http-code 400)))

(define/pow
  (processName [name : String ::: (NonEmpty name)] [name2 : String ::: (ValidName name2)])
  #:returns String
  (format "~a / ~a" (tesl-display-val *name) (tesl-display-val *name2)))

(define/pow
  (validateAndProcess [raw : String])
  #:returns String
  (let/check ([tesl_checked_0 (checkNonEmpty raw)]) (let ([ne tesl_checked_0]) (let/check ([tesl_checked_1 (checkName ne)]) (let ([full tesl_checked_1]) (raw-value (processName full full)))))))

(define-checker
  (checkInRange [n : Integer])
  #:returns [n : Integer ::: (InRange n)]
  (if (and (>= *n 0) (<= *n 255)) (accept (InRange n) #:value *n) (reject "value out of range 0-255" #:http-code 400)))

(define-trusted
  (inferInRange [n : Integer])
  #:returns (Fact (InRange n))
  (trusted-proof (InRange n)))

(define/pow
  (processNameManual [name : String])
  #:returns String
  (let/check ([tesl_checked_2 (checkNonEmpty name)]) (let ([ne tesl_checked_2]) (let ([raw (forget-proof ne)]) (let ([proof (detach-all-proof ne)]) (let ([reattach (attach-proof raw proof)]) (let/check ([tesl_checked_3 (checkName reattach)]) (let ([validated tesl_checked_3]) (raw-value validated)))))))))

(define-checker
  (checkHasAt [email : String])
  #:returns [email : String ::: (HasAt email)]
  (if (tesl_import_String_contains *email "@") (accept (HasAt email) #:value *email) (reject "email must contain @" #:http-code 400)))

(define-checker
  (checkLongEnough [email : String])
  #:returns [email : String ::: (LongEnough email)]
  (if (>= (raw-value (tesl_import_String_length *email)) 5) (accept (LongEnough email) #:value *email) (reject "email too short" #:http-code 400)))

(define/pow
  (requiresValidEmail [email : String ::: (HasAt email)] [email2 : String ::: (LongEnough email2)])
  #:returns String
  (format "~a / ~a" (tesl-display-val *email) (tesl-display-val *email2)))

(define/pow
  (validateEmail [raw : String])
  #:returns String
  (let/check ([tesl_checked_4 (checkHasAt raw)]) (let ([withAt tesl_checked_4]) (let/check ([tesl_checked_5 (checkLongEnough withAt)]) (let ([full tesl_checked_5]) (raw-value (requiresValidEmail full full)))))))

(module+ test
  (require rackunit)
  (test-case "validateAndProcess"
  (check-equal? (raw-value (validateAndProcess "Alice")) "Alice / Alice")
  )

  (test-case "validateEmail"
  (check-equal? (raw-value (validateEmail "alice@example.com")) "alice@example.com / alice@example.com")
  )

)
