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
  (only-in tesl/tesl/prelude String)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/time nowMillis time PosixMillis)
  (only-in tesl/tesl/env env envRead)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
)


(provide readEnvVar getCurrentTime logMessage readAndWrite readEnvVar-signature getCurrentTime-signature logMessage-signature readAndWrite-signature)

(define-capability fileRead)

(define-capability auditWrite (implies dbWrite))

(define-capability appCapability (implies auditWrite fileRead))

(define/pow
  (readEnvVar [key : String])
  #:capabilities [envRead]
  #:returns (Maybe String)
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson11-capabilities.tesl" 52 (list (cons 'key *key)) (lambda () (raw-value (env *key)))))

(define/pow
  (getCurrentTime)
  #:capabilities [time]
  #:returns PosixMillis
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson11-capabilities.tesl" 56 (list) (lambda () (raw-value (nowMillis)))))

(define/pow
  (logMessage [message : String])
  #:capabilities [auditWrite dbRead]
  #:returns String
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson11-capabilities.tesl" 61 (list (cons 'message *message)) (lambda () (format "logged: ~a" (tesl-display-val *message)))))

(define/pow
  (readAndWrite [key : String])
  #:capabilities [appCapability envRead]
  #:returns String
  (let ([value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson11-capabilities.tesl" 67 (list (cons 'key *key)) (lambda () (readEnvVar key)))]) (let ([valueStr (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson11-capabilities.tesl" 68 (list (cons 'value *value) (cons 'key *key)) (lambda () (let ([tesl-case-0 (raw-value value)]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson11-capabilities.tesl" 69 (list) (lambda () "(not set)"))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson11-capabilities.tesl" 70 (list (cons 'v v)) (lambda () *v)))]))))]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson11-capabilities.tesl" 71 (list (cons 'valueStr *valueStr) (cons 'value *value) (cons 'key *key)) (lambda () (format "read key: ~a, value: ~a" (tesl-display-val *key) (tesl-display-val *valueStr)))))))
