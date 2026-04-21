#lang racket

(require racket/list
         "check-runtime.rkt"
         "../types.rkt"
         (for-syntax racket/base
                     syntax/parse
                     "../types.rkt"))

(provide trusted-proof)

(define (trusted-proof/runtime proof-datum)
  (define fact (instantiate-proof-template proof-datum))
  (detached-proof fact
                  (restrict-bindings-to-fact (current-proof-env) fact)))

(begin-for-syntax
  (define body-bound-names-key 'tesl-body-bound-names)

  (define (body-bound-names stx)
    (syntax-property stx body-bound-names-key))

  (define (validate-proof-template-stx! who use-stx proof-stx)
    (define effective-bound-names (body-bound-names use-stx))
    (when effective-bound-names
      (define missing
        (proof-unbound-names (normalize-gdp-expr (syntax->datum proof-stx))
                             effective-bound-names))
      (when (pair? missing)
        (raise-syntax-error who
                            (format "unbound GDP name~a in proof template: ~a"
                                    (if (= (length missing) 1) "" "s")
                                    missing)
                            use-stx)))))

(define-syntax (trusted-proof stx)
  (syntax-parse stx
    [(_ proof)
     (validate-proof-template-stx! 'trusted-proof stx #'proof)
     (define proof-datum (normalize-gdp-expr (syntax->datum #'proof)))
     #`(trusted-proof/runtime '#,proof-datum)]))
