#lang racket

(require "private/runtime.rkt"
         "random.rkt"
         (only-in "../dsl/capability.rkt" require-capabilities!))

(provide
 generatePrefixedId)

(define (generatePrefixedId prefix)
  (require-capabilities! (list random))
  (tesl-generate-prefixed-id prefix))
