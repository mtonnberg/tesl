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
  (thsl-src! "example/learn/lesson51-proof-combining.tesl" 47 (list (cons 'name *name)) (lambda () (if (> (raw-value (tesl_import_String_length *name)) 0) (accept (NonEmpty name) #:value *name) (reject "name must not be empty" #:http-code 400)))))

(define-checker
  (checkName [name : String ::: (NonEmpty name)])
  #:returns [name : String ::: (ValidName name)]
  (thsl-src! "example/learn/lesson51-proof-combining.tesl" 53 (list (cons 'name *name)) (lambda () (if (<= (raw-value (tesl_import_String_length *name)) 100) (accept (ValidName name) #:value *name) (reject "name too long" #:http-code 400)))))

(define/pow
  (processName [name : String ::: (NonEmpty name)] [name2 : String ::: (ValidName name2)])
  #:returns String
  (thsl-src! "example/learn/lesson51-proof-combining.tesl" 60 (list (cons 'name *name) (cons 'name2 *name2)) (lambda () (format "~a / ~a" (tesl-display-val *name) (tesl-display-val *name2)))))

(define/pow
  (validateAndProcess [raw : String])
  #:returns String
  (thsl-src! "example/learn/lesson51-proof-combining.tesl" 65 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-0 (checkNonEmpty raw)]) (let ([ne tesl-checked-0]) (let/check ([tesl-checked-1 (checkName ne)]) (let ([full tesl-checked-1]) (raw-value (processName full full)))))))))

(define-checker
  (checkInRange [n : Integer])
  #:returns [n : Integer ::: (InRange n)]
  (thsl-src! "example/learn/lesson51-proof-combining.tesl" 76 (list (cons 'n *n)) (lambda () (if (and (>= *n 0) (<= *n 255)) (accept (InRange n) #:value *n) (reject "value out of range 0-255" #:http-code 400)))))

(define-trusted
  (inferInRange [n : Integer])
  #:returns (Fact (InRange n))
  (thsl-src! "example/learn/lesson51-proof-combining.tesl" 85 (list (cons 'n *n)) (lambda () (trusted-proof (InRange n)))))

(define/pow
  (processNameManual [name : String])
  #:returns String
  (thsl-src! "example/learn/lesson51-proof-combining.tesl" 89 (list (cons 'name *name)) (lambda () (let/check ([tesl-checked-2 (checkNonEmpty name)]) (let ([ne tesl-checked-2]) (let ([raw (forget-proof ne)]) (let ([proof (detach-all-proof ne)]) (let ([reattach (attach-proof raw proof)]) (let/check ([tesl-checked-3 (checkName reattach)]) (let ([validated tesl-checked-3]) (raw-value validated)))))))))))

(define-checker
  (checkHasAt [email : String])
  #:returns [email : String ::: (HasAt email)]
  (thsl-src! "example/learn/lesson51-proof-combining.tesl" 111 (list (cons 'email *email)) (lambda () (if (tesl_import_String_contains *email "@") (accept (HasAt email) #:value *email) (reject "email must contain @" #:http-code 400)))))

(define-checker
  (checkLongEnough [email : String])
  #:returns [email : String ::: (LongEnough email)]
  (thsl-src! "example/learn/lesson51-proof-combining.tesl" 117 (list (cons 'email *email)) (lambda () (if (>= (raw-value (tesl_import_String_length *email)) 5) (accept (LongEnough email) #:value *email) (reject "email too short" #:http-code 400)))))

(define/pow
  (requiresValidEmail [email : String ::: (HasAt email)] [email2 : String ::: (LongEnough email2)])
  #:returns String
  (thsl-src! "example/learn/lesson51-proof-combining.tesl" 123 (list (cons 'email *email) (cons 'email2 *email2)) (lambda () (format "~a / ~a" (tesl-display-val *email) (tesl-display-val *email2)))))

(define/pow
  (validateEmail [raw : String])
  #:returns String
  (thsl-src! "example/learn/lesson51-proof-combining.tesl" 127 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-4 (checkHasAt raw)]) (let ([withAt tesl-checked-4]) (let/check ([tesl-checked-5 (checkLongEnough withAt)]) (let ([full tesl-checked-5]) (raw-value (requiresValidEmail full full)))))))))

(module+ test
  (require rackunit)
  (test-case "validateAndProcess"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson51-proof-combining.tesl" 183 (list) (lambda () (validateAndProcess "Alice")))) "Alice / Alice")
    ))
  )

  (test-case "validateEmail"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson51-proof-combining.tesl" 187 (list) (lambda () (validateEmail "alice@example.com")))) "alice@example.com / alice@example.com")
    ))
  )

)
