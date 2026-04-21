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
  (only-in tesl/tesl/prelude Int Fact String)
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
)


(provide InRange checkInRange Trusted makeProofTrusted IsAdmin adminAuth checkInRange-signature makeProofTrusted-signature adminAuth-signature)

(define InRange 'InRange)
(define IsAdmin 'IsAdmin)
(define Trusted 'Trusted)

(define-checker
  (checkInRange [n : Integer])
  #:returns [n : Integer ::: (InRange n)]
  (if (and (>= *n 0) (<= *n 100)) (accept (InRange n) #:value *n) (reject "must be between 0 and 100" #:http-code 422)))

(define-trusted
  (makeProofTrusted [n : Integer])
  #:returns (Fact (Trusted n))
  (trusted-proof (Trusted n)))

(define-auther
  (adminAuth [request : HttpRequest])
  #:returns (? String _entity ::: (IsAdmin _entity))
  (let ([tesl_case_0 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) (reject "admin only" #:http-code 401)] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl_case_0) 'value)]) (if (equal? (raw-value userId) "admin") (accept (IsAdmin userId) #:value *userId) (reject "admin only" #:http-code 401)))])))
