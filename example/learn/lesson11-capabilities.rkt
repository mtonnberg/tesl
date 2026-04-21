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
  (only-in tesl/tesl/prelude String)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/time nowMillis time PosixMillis)
  (only-in tesl/tesl/env env)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
)


(provide readEnvVar getCurrentTime logMessage readAndWrite readEnvVar-signature getCurrentTime-signature logMessage-signature readAndWrite-signature)

(define-capability fileRead)

(define-capability auditWrite (implies dbWrite))

(define-capability appCapability (implies auditWrite fileRead))

(define/pow
  (readEnvVar [key : String])
  #:returns (Maybe String)
  (raw-value (env *key)))

(define/pow
  (getCurrentTime)
  #:capabilities [time]
  #:returns PosixMillis
  (raw-value (nowMillis)))

(define/pow
  (logMessage [message : String])
  #:capabilities [auditWrite dbRead]
  #:returns String
  (format "logged: ~a" (tesl-display-val *message)))

(define/pow
  (readAndWrite [key : String])
  #:capabilities [appCapability]
  #:returns String
  (let ([value (readEnvVar key)]) (let ([valueStr (let ([tesl_case_0 (raw-value value)]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) "(not set)"] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl_case_0) 'value)]) *v)]))]) (format "read key: ~a, value: ~a" (tesl-display-val *key) (tesl-display-val *valueStr)))))
