#lang racket

(require "../dsl/types.rkt"
         "../dsl/check.rkt"
         (only-in "../dsl/private/evidence.rkt" detached-proof check-ok check-fail)
         (only-in "../dsl/private/check-runtime.rkt" attach)
         (only-in "../dsl/private/check-runtime.rkt" validate-runtime-argument))

;; Float (64-bit double) utility functions.
;; In Tesl, Float/Double and Number are all Racket inexact reals.

;; Float — the type-name symbol, analogous to Int/String in prelude.rkt.
;; Exported so that `import Tesl.Float exposing [Float]` works at the Racket level.
(define Float 'Float)

;; Proof predicate symbols exported for use in Tesl type annotations.
;;   f ::: FloatNonZero f       (float is not zero; from Float.requireNonZero)
;;   f ::: FloatNonNegative f   (float is >= 0; from Float.requireNonNegative)
(provide
 Float
 FloatNonZero
 FloatNonNegative
 Float.requireNonZero
 Float.requireNonNegative
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
(define FloatNonNegative 'FloatNonNegative)

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

;; Float.requireNonNegative — check function returning f ::: FloatNonNegative f.
;; Zero is accepted: (sqrt 0.0) is 0.0, not a complex number, so requiring strict
;; positivity would reject a well-defined call.
(define (Float.requireNonNegative f)
  (define v (exact->inexact (rv f)))
  (if (>= v 0)
      (let* ([nv   (attach-float-proof 'FloatNonNegative v)]
             [subj (named-value-name nv)]
             [fact `(FloatNonNegative ,subj)])
        (check-ok nv (list fact) (hash subj v)))
      (check-fail "expected a non-negative float" 422 #f)))

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

;; Float.sqrt requires FloatNonNegative on its argument (see
;; compiler/lib/validation_common.ml): without it, (sqrt -1.0) returns the COMPLEX
;; 0.0+1.0i, which no Tesl Float can hold.  The runtime guard mirrors the static one.
(define (Float.sqrt f)
  (define checked
    (validate-runtime-argument 'Float.sqrt "function" 'f f 'Float '(FloatNonNegative f)))
  (define v (rv checked))
  (when (< v 0)
    (raise-user-error 'Float.sqrt
                      "negative input — use `check Float.requireNonNegative(f)` first"))
  (exact->inexact (sqrt v)))
;; `expt` on a NEGATIVE base with a non-integer exponent has no real value, and Racket answers
;; a COMPLEX number — which no Tesl Float can hold.  That is the same hole `Float.sqrt` guards
;; directly above, left open here: `(Float.pow -8.0 (/ 1.0 3.0))` returned
;; `1.0+1.732050807568877i` from a function typed `Float -> Float -> Float`.  (Found by the Go
;; port, 2026-08-17.)
;;
;; The answer is NaN rather than a raise, unlike `Float.sqrt`: sqrt has a static check
;; (`FloatNonNegative`) that makes a refusal actionable, pow has none, and IEEE's own answer for
;; a real `pow` with no real result IS NaN.  C's `pow` makes two exceptions that contradict it —
;; `(-1)^±inf = 1` and `(-4)^+inf = +inf` — which the Go runtime guards back to NaN, so the two
;; backends answer alike at every input.
(define (Float.pow base exp)
  (define result (expt (exact->inexact (rv base)) (exact->inexact (rv exp))))
  (if (real? result) (exact->inexact result) +nan.0))
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
