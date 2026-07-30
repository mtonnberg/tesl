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
  (only-in tesl/tesl/prelude Int Fact String)
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/env requireEnv envRead)
  (only-in tesl/tesl/crypto Secret [Crypto.checkSignature tesl_import_Crypto_checkSignature] [Crypto.signatureFromHex tesl_import_Crypto_signatureFromHex])
)


(provide InRange checkInRange Trusted makeProofTrusted IsAdmin adminAuth checkInRange-signature makeProofTrusted-signature adminAuth-signature)

(define InRange 'InRange)
(define IsAdmin 'IsAdmin)
(define Trusted 'Trusted)

(define-checker
  (checkInRange [n : Integer])
  #:returns [n : Integer ::: (InRange n)]
  (thsl-src! "example/learn/lesson06-proof-check-proof-auth.tesl" 52 (list (cons 'n *n)) (lambda () (if (and (tesl-ge? *n 0) (tesl-le? *n 100)) (accept (InRange n) #:value *n) (reject "must be between 0 and 100" #:http-code 422)))))

(define-trusted
  (makeProofTrusted [n : Integer])
  #:returns (Fact (Trusted n))
  (thsl-src! "example/learn/lesson06-proof-check-proof-auth.tesl" 75 (list (cons 'n *n)) (lambda () (trusted-proof (Trusted n)))))

(define-auther
  (adminAuth [request : HttpRequest])
  #:capabilities [envRead]
  #:returns (? String _entity ::: (IsAdmin _entity))
  (thsl-src-control! "example/learn/lesson06-proof-check-proof-auth.tesl" 109 (list (cons 'request *request)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "session" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/learn/lesson06-proof-check-proof-auth.tesl" 110 (list) (lambda () (reject "admin only" #:http-code 401)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([payload (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson06-proof-check-proof-auth.tesl" 112 (list (cons 'payload payload)) (lambda () (let ([tesl-case-1 (raw-value (tesl_import_Dict_lookup "sessionSig" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "example/learn/lesson06-proof-check-proof-auth.tesl" 113 (list) (lambda () (reject "admin only" #:http-code 401)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([sigHex (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "example/learn/lesson06-proof-check-proof-auth.tesl" 115 (list (cons 'sigHex sigHex)) (lambda () (let ([key (raw-value (Secret (raw-value (requireEnv "ADMIN_SESSION_KEY"))))]) (let/check ([tesl-checked-2 (tesl_import_Crypto_checkSignature key (raw-value (tesl_import_Crypto_signatureFromHex (raw-value sigHex))) payload)]) (let ([adminId tesl-checked-2]) (accept (IsAdmin adminId) #:value *adminId)))))))])))))])))))
