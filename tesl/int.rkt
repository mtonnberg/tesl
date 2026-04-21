#lang racket

(require "private/runtime.rkt"
         "../dsl/types.rkt"
         "../dsl/check.rkt"
         (only-in "../dsl/private/evidence.rkt" detached-proof check-ok check-fail)
         (only-in "../dsl/private/check-runtime.rkt" attach validate-runtime-argument))

;; ── Proof predicate name symbols ────────────────────────────────────────────
;; Use in Tesl annotations:
;;   n ::: IsNonNegative n    (n >= 0 — guaranteed by Int.abs)
;;   n ::: IsNonZero n        (n != 0 — required for safe division)
(provide
 IsNonNegative IsNonZero
 Int.parse
 Int.fromFloat
 Int.toString
 Int.abs
 Int.min
 Int.max
 Int.clamp
 Int.isPositive
 Int.isNegative
 Int.isZero
 Int.isEven
 Int.isOdd
 Int.gcd
 Int.lcm
 Int.pow
 Int.digits
 Int.toFloat
 Int.sign
 Int.nonZero
 Int.nonNegative
 Int.divide
 Int.modulo)

(define IsNonNegative 'IsNonNegative)
(define IsNonZero     'IsNonZero)

(define (rv x) (raw-value x))

;; Helper: attach a numeric proof to an integer value
(define (attach-int-proof pred-name raw-int-value)
  (define nv (ensure-named pred-name raw-int-value))
  (define subj (named-value-name nv))
  (attach nv (list (detached-proof `(,pred-name ,subj) (hash subj raw-int-value)))))

;; ── Plain functions ──────────────────────────────────────────────────────────

;; Parse string to Maybe Int
(define (Int.parse raw)
  (tesl-int-parse raw))

;; Truncate float to int
(define (Int.fromFloat f)
  (inexact->exact (truncate (rv f))))

(define (Int.toString n)
  (number->string (rv n)))

(define (Int.min a b)
  (min (rv a) (rv b)))

(define (Int.max a b)
  (max (rv a) (rv b)))

;; Clamp value between lo and hi (inclusive)
(define (Int.clamp n lo hi)
  (max (rv lo) (min (rv hi) (rv n))))

(define (Int.isPositive n)
  (> (rv n) 0))

(define (Int.isNegative n)
  (< (rv n) 0))

(define (Int.isZero n)
  (= (rv n) 0))

(define (Int.isEven n)
  (even? (rv n)))

(define (Int.isOdd n)
  (odd? (rv n)))

(define (Int.gcd a b)
  (gcd (rv a) (rv b)))

(define (Int.lcm a b)
  (lcm (rv a) (rv b)))

;; Integer exponentiation
(define (Int.pow base exp)
  (expt (rv base) (rv exp)))

;; Number of decimal digits (ignores sign)
(define (Int.digits n)
  (string-length (number->string (abs (rv n)))))

(define (Int.toFloat n)
  (exact->inexact (rv n)))

;; Returns -1, 0, or 1
(define (Int.sign n)
  (define v (rv n))
  (cond [(> v 0) 1] [(< v 0) -1] [else 0]))

;; ── Proof-bearing functions ──────────────────────────────────────────────────

;; Int.abs — returns plain Int (absolute value, always non-negative)
;; The IsNonNegative invariant holds by definition; no runtime proof wrapping
;; to keep it usable inline in arithmetic/comparison expressions.
(define (Int.abs n)
  (abs (rv n)))

;; Int.nonZero — check function: returns n ::: IsNonZero n, or check-fail
;;
;; Use in Tesl with `check`:
;;   let divisor = check Int.nonZero(rawDivisor)
;;   let result  = Int.divide(numerator, divisor)
;;
;; Returns a check-ok with the original value bearing IsNonZero proof,
;; or check-fail 400 if the value is zero.
(define (Int.nonZero n)
  (define v (rv n))
  (if (not (zero? v))
      (let* ([nv   (attach-int-proof 'IsNonZero v)]
             [subj (named-value-name nv)]
             [fact `(IsNonZero ,subj)])
        ;; Wrap in check-ok so callers can use `let x = check Int.nonZero(...)`
        (check-ok nv (list fact) (hash subj v)))
      (check-fail "expected a non-zero integer" 400 #f)))

;; Int.nonNegative — check function: returns n ::: IsNonNegative n, or check-fail
(define (Int.nonNegative n)
  (define v (rv n))
  (if (>= v 0)
      (let* ([nv   (attach-int-proof 'IsNonNegative v)]
             [subj (named-value-name nv)]
             [fact `(IsNonNegative ,subj)])
        (check-ok nv (list fact) (hash subj v)))
      (check-fail "expected a non-negative integer" 400 #f)))

;; Int.divide — integer division (quotient).
;;
;; The second argument `b` must carry an IsNonZero proof so that division
;; by zero is prevented at the proof-checking boundary.  A defensive runtime
;; check is also present for safety.
;;
;; Typical Tesl usage:
;;   fn safeDivide(a: Int, b: Int ::: IsNonZero b) -> Int =
;;     Int.divide(a, b)
(define (Int.divide a b)
  (define checked-divisor
    (validate-runtime-argument 'Int.divide "function" 'b b 'Int '(IsNonZero b)))
  (define denom (rv checked-divisor))
  (when (zero? denom)
    (raise-user-error 'Int.divide
                      "division by zero — use `check Int.nonZero(b)` before calling Int.divide"))
  (quotient (rv a) denom))

;; Int.modulo — integer modulo (remainder).
;;
;; Like Int.divide, the second argument `b` must carry an IsNonZero proof.
(define (Int.modulo a b)
  (define checked-divisor
    (validate-runtime-argument 'Int.modulo "function" 'b b 'Int '(IsNonZero b)))
  (define denom (rv checked-divisor))
  (when (zero? denom)
    (raise-user-error 'Int.modulo
                      "division by zero — use `check Int.nonZero(b)` before calling Int.modulo"))
  (remainder (rv a) denom))
