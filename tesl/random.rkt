#lang racket

;;; Tesl.Random — random number generation capability and functions.
;;;
;;; The `random` capability gates all non-deterministic random operations.
;;; Import it and list it in a capability's `implies` clause to opt in:
;;;
;;;   import Tesl.Random exposing [random, randomInt]
;;;   capability myWrite implies dbWrite, random

;; Import Racket's built-in random under an alias so it is not shadowed
;; by the (define-capability random) below.
(require (only-in racket/base [random racket-random])
         "private/runtime.rkt"
         (only-in "../dsl/capability.rkt" define-capability require-capabilities!))

(provide random randomInt randomFloat)

(define-capability random)

;; Returns a random integer in the range [lo, hi).  (2026-07-06: was a 1-arg
;; `[0, n)` runtime that disagreed with the `(Int, Int) -> Int` type — an arity
;; crash on any real call.  Now 2-arg to match the type; callers constrain
;; `lo < hi` via a proof on the inputs, per roadmap/completed/stdlib_surface_binding_drift.md.)
(define (randomInt lo hi)
  (require-capabilities! (list random))
  (+ lo (racket-random (- hi lo))))

;; Returns a random float in [0, 1).  Called as `randomFloat()` (a fresh value
;; per call, like `UUID.v4()`), NOT a once-evaluated constant.
(define (randomFloat)
  (require-capabilities! (list random))
  (racket-random))
