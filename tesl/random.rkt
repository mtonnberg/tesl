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

(provide random randomInt)

(define-capability random)

;; Returns a random integer in the range [0, n).
(define (randomInt n)
  (require-capabilities! (list random))
  (racket-random n))
