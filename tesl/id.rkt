#lang racket

(require "private/runtime.rkt"
         "random.rkt"
         (only-in "../dsl/capability.rkt" require-capabilities!))

(provide
 generateId
 generatePrefixedId)

(define (generatePrefixedId prefix)
  (require-capabilities! (list random))
  (tesl-generate-prefixed-id prefix))

;; `generateId()` — a fresh unprefixed id (2026-07-06: was importable + typed
;; but had no runtime binding → unbound at load; the manual already teaches it).
;; Same `random` capability as generatePrefixedId; called as `generateId()`.
(define (generateId)
  (require-capabilities! (list random))
  (tesl-generate-prefixed-id ""))
