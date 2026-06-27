#lang racket

(require (for-syntax racket/base syntax/parse))

(provide
 define-capability
 current-capabilities
 with-capabilities
 expand-capabilities
 require-capabilities!
 call-with-declared-capabilities)

(struct capability-value (name implies-thunk))

(define current-capabilities (make-parameter '()))
(define current-declared-capabilities (make-parameter #f))

;; Zero-cost mode (default ON, mirroring the proof system's TESL_ZERO_COST_PROOFS
;; switch).  In zero-cost mode the per-function DECLARED-CONTEXT (nesting) check is
;; ELIDED — the static capability checker, with capability-row polymorphism, is the
;; source of truth, and eliding it lets capability-bearing callbacks flow through
;; capability-free higher-order functions (List.map/foldl/…) without the runtime
;; narrowing each function's declared context to its own row.  The AMBIENT
;; available-capability check below is ALWAYS enforced, so an ungranted capability
;; still fails at runtime.  TESL_ZERO_COST_PROOFS=0 restores the declared-context
;; net as a regression oracle (note: that net predates polymorphism and is not
;; HOF-aware — see roadmap/next/capability_polymorphism.md).
(define zero-cost-caps?
  (let ([v (getenv "TESL_ZERO_COST_PROOFS")])
    (cond [(not v) #t]
          [(member (string-downcase v) '("0" "false" "no" "off")) #f]
          [(member (string-downcase v) '("1" "true" "yes" "on")) #t]
          [else #t])))

(define (ensure-capability who value)
  (unless (capability-value? value)
    (raise-user-error who "expected a declared capability value, got ~a" value))
  value)

(define (ensure-capability-list who values)
  (for/list ([value (in-list values)])
    (ensure-capability who value)))

(define (capability<? left right)
  (symbol<? (capability-value-name left)
            (capability-value-name right)))

(define (expand-capabilities caps)
  (define seen (make-hasheq))
  (define (visit cap)
    (define checked (ensure-capability 'capabilities cap))
    (unless (hash-has-key? seen checked)
      (hash-set! seen checked #t)
      (for ([next (in-list (ensure-capability-list 'capabilities
                                                   ((capability-value-implies-thunk checked))))])
        (visit next))))
  (for ([cap (in-list (ensure-capability-list 'capabilities caps))])
    (visit cap))
  (sort (hash-keys seen) capability<?))

(define (missing-capability-names required available)
  (for/list ([cap (in-list required)]
             #:unless (member cap available eq?))
    (capability-value-name cap)))

(define (require-capabilities! required)
  (define required-caps (ensure-capability-list 'capabilities required))
  (define declared-context
    (let ([caps (current-declared-capabilities)])
      (and caps (expand-capabilities caps))))
  (when (and (not zero-cost-caps?) declared-context)
    (define undeclared
      (missing-capability-names required-caps declared-context))
    (unless (null? undeclared)
      (raise-user-error
       'capabilities
       (format "Capabilities not declared by the current DSL context: ~a" undeclared))))
  (define available (expand-capabilities (current-capabilities)))
  (define missing
    (missing-capability-names required-caps available))
  (unless (null? missing)
    (raise-user-error
     'capabilities
     (format "Missing capabilities: ~a" missing))))

(define (call-with-declared-capabilities declared thunk)
  (unless (procedure? thunk)
    (raise-user-error 'capabilities "expected a thunk procedure, got ~a" thunk))
  (define declared-caps (expand-capabilities declared))
  (require-capabilities! declared-caps)
  (parameterize ([current-declared-capabilities declared-caps])
    (thunk)))

(define-syntax (define-capability stx)
  (syntax-parse stx
    [(_ name:id)
     #'(define name
         (capability-value 'name
                           (lambda () '())))]
    [(_ name:id (implies implied:id ...))
     #'(define name
         (capability-value 'name
                           (lambda () (list implied ...))))]))

(define-syntax-rule (with-capabilities (cap ...) body ...)
  (parameterize ([current-capabilities
                  (expand-capabilities (append (list cap ...)
                                               (current-capabilities)))])
    body ...))
