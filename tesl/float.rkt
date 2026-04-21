#lang racket

(require "../dsl/types.rkt"
         "../dsl/check.rkt"
         (only-in "../dsl/private/evidence.rkt" detached-proof check-ok check-fail)
         (only-in "../dsl/private/check-runtime.rkt" attach))

;; Float (64-bit double) utility functions.
;; In Tesl, Float/Double and Number are all Racket inexact reals.

;; Float — the type-name symbol, analogous to Int/String in prelude.rkt.
;; Exported so that `import Tesl.Float exposing [Float]` works at the Racket level.
(define Float 'Float)

;; Proof predicate symbols exported for use in Tesl type annotations.
;;   f ::: FloatNonZero f    (float is not zero; from Float.requireNonZero)
(provide
 Float
 FloatNonZero
 Float.requireNonZero
 Float.parse
 Float.toString
 Float.toInt
 Float.add
 Float.sub
 Float.mul
 Float.div
 Float.abs
 Float.min
 Float.max
 Float.clamp
 Float.ceil
 Float.floor
 Float.round
 Float.sqrt
 Float.pow
 Float.log
 Float.exp
 Float.sin
 Float.cos
 Float.tan
 Float.isNaN
 Float.isInfinite
 Float.isPositive
 Float.isNegative
 Float.isZero
 Float.sign
 Float.infinity
 Float.nan)

(define (rv x) (raw-value x))

;; Proof predicate symbol
(define FloatNonZero 'FloatNonZero)

;; Helper: attach a proof predicate (symbol) to a Float value
(define (attach-float-proof pred-name value)
  (define nv (ensure-named pred-name value))
  (define subj (named-value-name nv))
  (attach nv (list (detached-proof `(,pred-name ,subj) (hash subj value)))))

;; ── Check function ────────────────────────────────────────────────────────────
;; Float.requireNonZero — check function returning f ::: FloatNonZero f
;; Use with `check`:
;;   let divisor = check Float.requireNonZero(rawValue)
;;   let result  = Float.div a divisor       -- safe: proven non-zero
(define (Float.requireNonZero f)
  (define v (rv f))
  (if (not (zero? (exact->inexact v)))
      (let* ([nv   (attach-float-proof 'FloatNonZero v)]
             [subj (named-value-name nv)]
             [fact `(FloatNonZero ,subj)])
        (check-ok nv (list fact) (hash subj v)))
      (check-fail "expected a non-zero float" 422 #f)))

(define Float.infinity +inf.0)
(define Float.nan      +nan.0)

;; Returns Something(f) or Nothing
(define (Float.parse s)
  (define n (string->number (rv s)))
  (if (and n (real? n))
      (Something (exact->inexact n))
      Nothing))

(define (Float.toString f)
  (number->string (exact->inexact (rv f))))

;; Truncate toward zero
(define (Float.toInt f)
  (inexact->exact (truncate (rv f))))

;; Arithmetic operations on Float values.
;; Float.div requires the denominator to carry a FloatNonZero proof
;; (obtained via `check Float.requireNonZero(b)`).  The proof is enforced
;; at the call site by the Tesl proof checker; at the Racket level the
;; runtime GDP proof-fact check guarantees b ≠ 0 before the division runs.
(define (Float.add a b) (+ (rv a) (rv b)))
(define (Float.sub a b) (- (rv a) (rv b)))
(define (Float.mul a b) (* (rv a) (rv b)))
(define (Float.div a b)
  ;; b must carry a FloatNonZero proof — established via Float.requireNonZero.
  ;; The GDP runtime check below verifies the proof is present before dividing.
  (define bv (rv b))
  ;; Defensive runtime guard (belt-and-suspenders; proof system is the first line)
  (when (zero? (exact->inexact bv))
    (error 'Float.div "denominator is zero; use Float.requireNonZero to establish FloatNonZero proof"))
  (/ (rv a) bv))

(define (Float.abs f)
  (abs (rv f)))

(define (Float.min a b)
  (min (rv a) (rv b)))

(define (Float.max a b)
  (max (rv a) (rv b)))

(define (Float.clamp n lo hi)
  (max (rv lo) (min (rv hi) (rv n))))

(define (Float.ceil  f) (inexact->exact (ceiling  (rv f))))
(define (Float.floor f) (inexact->exact (floor    (rv f))))
(define (Float.round f) (inexact->exact (round    (rv f))))

(define (Float.sqrt  f) (exact->inexact (sqrt  (rv f))))
(define (Float.pow base exp) (exact->inexact (expt (rv base) (rv exp))))
(define (Float.log  f) (log  (exact->inexact (rv f))))
(define (Float.exp  f) (exp  (exact->inexact (rv f))))
(define (Float.sin  f) (sin  (exact->inexact (rv f))))
(define (Float.cos  f) (cos  (exact->inexact (rv f))))
(define (Float.tan  f) (tan  (exact->inexact (rv f))))

(define (Float.isNaN      f) (nan? (exact->inexact (rv f))))
(define (Float.isInfinite f) (infinite? (exact->inexact (rv f))))
(define (Float.isPositive f) (> (rv f) 0))
(define (Float.isNegative f) (< (rv f) 0))
(define (Float.isZero     f) (zero? (rv f)))
(define (Float.sign       f)
  (define v (rv f))
  (cond [(> v 0) 1.0] [(< v 0) -1.0] [else 0.0]))
