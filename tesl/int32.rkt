#lang racket

;;; Tesl.Int32 (NT-07) — a JS-safe, 32-bit-bounded integer for wire/storage
;;; boundaries.  `Int32` is NOMINAL at the type level (it does not unify with
;;; `Int`); at runtime an Int32 value is just its underlying exact integer.
;;;
;;;   import Tesl.Int32 exposing [Int32, Int32.fromInt, Int32.toInt]
;;;
;;; THE RANGE RULE (one rule for the whole module):
;;;   * a result that CANNOT leave [-2^31, 2^31) is an `Int32`
;;;     (min/max/clamp/modulo, and the saturating `fromIntClamped`);
;;;   * a result that CAN leave it is a `Maybe Int32` — `Nothing` is the
;;;     out-of-range answer (fromInt/fromFloat/parse/add/subtract/multiply/
;;;     negate/abs/pow/divide);
;;;   * a result that is not an Int32 at all is its own type
;;;     (toInt/toFloat/toString/sign/digits and the predicates).
;;; So an Int32 never silently wraps, and widening (`toInt`) is always total.
;;;
;;; `int32?` is registered as the runtime type so the codec decode-boundary
;;; range-checks an incoming JSON `Int32` field (a value outside [-2^31, 2^31)
;;; is rejected rather than silently wrapped).

(require "private/runtime.rkt"
         "../dsl/types.rkt"
         "../dsl/check.rkt"
         (only-in "../dsl/private/evidence.rkt" detached-proof check-ok check-fail)
         (only-in "../dsl/private/check-runtime.rkt" attach validate-runtime-argument))

;; ── Proof predicate name symbols ────────────────────────────────────────────
;; Use in Tesl annotations (same predicates as Tesl.Int — import ONE of the two
;; modules exposing them; exposing both is a V001 ambiguous-import error):
;;   n ::: IsNonNegative n    (n >= 0 — minted by Int32.nonNegative)
;;   n ::: IsNonZero n        (n != 0 — required by Int32.divide / Int32.modulo)
(provide Int32
         IsNonNegative IsNonZero
         ;; conversions
         Int32.fromInt Int32.toInt Int32.fromIntClamped
         Int32.parse Int32.fromFloat Int32.toFloat Int32.toString
         ;; bounds
         Int32.minValue Int32.maxValue
         ;; range-closed operations
         Int32.min Int32.max Int32.clamp Int32.modulo
         ;; operations that can leave the range
         Int32.add Int32.subtract Int32.multiply
         Int32.negate Int32.abs Int32.pow Int32.divide
         ;; predicates and queries
         Int32.isPositive Int32.isNegative Int32.isZero
         Int32.isEven Int32.isOdd Int32.sign Int32.digits
         ;; proof-minting checks
         Int32.nonZero Int32.nonNegative)

;; The TYPE name is a runtime symbol (like `Maybe`), so `import Tesl.Int32
;; exposing [Int32, …]` resolves the type binding the emitter references.
(define Int32 'Int32)

(define IsNonNegative 'IsNonNegative)
(define IsNonZero     'IsNonZero)

(define INT32-MIN (- (expt 2 31)))
(define INT32-MAX (sub1 (expt 2 31)))

(define (int32? v)
  (and (exact-integer? v) (>= v INT32-MIN) (<= v INT32-MAX)))

(register-runtime-type! 'Int32 int32?)

(define (rv x) (raw-value x))

;; Narrow an exact integer to Maybe Int32 — the ONE range decision every
;; overflow-possible operation below funnels through.
(define (narrow v)
  (if (int32? v) (Something v) Nothing))

;; ── Conversions ─────────────────────────────────────────────────────────────

(define (Int32.fromInt v) (narrow (rv v)))

(define (Int32.toInt v) (rv v))

;; Saturating narrowing: total, and explicit in the name that it changes the
;; value.  Use it when a clamped value is the right business answer; use
;; `Int32.fromInt` when out-of-range must be visible.
(define (Int32.fromIntClamped v)
  (max INT32-MIN (min INT32-MAX (rv v))))

(define (Int32.parse raw)
  (define parsed (tesl-int-parse raw))
  (if (Nothing? parsed) Nothing (narrow (Something-value parsed))))

;; Truncates toward zero (like Int.fromFloat), then range-checks.  A NaN or an
;; infinity is out of range, so it is `Nothing` rather than a crash.
(define (Int32.fromFloat f)
  (define v (rv f))
  ;; `rational?` is #f for both NaN and the infinities — the two float values
  ;; with no integer truncation — so this guard covers them.
  (if (rational? v)
      (narrow (inexact->exact (truncate v)))
      Nothing))

(define (Int32.toFloat n) (exact->inexact (rv n)))

(define (Int32.toString n) (number->string (rv n)))

;; ── Bounds ──────────────────────────────────────────────────────────────────

(define Int32.minValue INT32-MIN)
(define Int32.maxValue INT32-MAX)

;; ── Range-closed operations (always an Int32) ────────────────────────────────

(define (Int32.min a b) (min (rv a) (rv b)))
(define (Int32.max a b) (max (rv a) (rv b)))

(define (Int32.clamp n lo hi)
  (max (rv lo) (min (rv hi) (rv n))))

;; `remainder` is bounded by |b| <= 2^31, so the result is always in range.
;; The divisor must carry an IsNonZero proof (as for Int.modulo).
(define (Int32.modulo a b)
  (define checked-divisor
    (validate-runtime-argument 'Int32.modulo "function" 'b b 'Int32 '(IsNonZero b)))
  (define denom (rv checked-divisor))
  (when (zero? denom)
    (raise-user-error 'Int32.modulo
                      "division by zero — use `check Int32.nonZero(b)` before calling Int32.modulo"))
  (remainder (rv a) denom))

;; ── Operations that can leave the range (Maybe Int32) ────────────────────────

(define (Int32.add a b)      (narrow (+ (rv a) (rv b))))
(define (Int32.subtract a b) (narrow (- (rv a) (rv b))))
(define (Int32.multiply a b) (narrow (* (rv a) (rv b))))

;; negate/abs overflow on exactly one input: -2^31 has no positive counterpart.
(define (Int32.negate n) (narrow (- (rv n))))
(define (Int32.abs n)    (narrow (abs (rv n))))

;; Nothing for a negative exponent (an integer power would be fractional) as
;; well as for an out-of-range result.  The exponent is bounded BEFORE the
;; `expt`: `2^2000000000` cannot fit an Int32 either way, and computing that
;; bignum first would burn memory to reach the same `Nothing`.  |base| > 1
;; needs at most 31 doublings to leave the range; 0/1/-1 never do.
(define (Int32.pow base exp)
  (define b (rv base))
  (define e (rv exp))
  (cond
    [(negative? e) Nothing]
    [(and (> (abs b) 1) (> e 31)) Nothing]
    [else (narrow (expt b e))]))

;; Integer division (quotient).  The divisor must carry an IsNonZero proof;
;; `Nothing` covers the single overflowing quotient, -2^31 / -1 = 2^31.
(define (Int32.divide a b)
  (define checked-divisor
    (validate-runtime-argument 'Int32.divide "function" 'b b 'Int32 '(IsNonZero b)))
  (define denom (rv checked-divisor))
  (when (zero? denom)
    (raise-user-error 'Int32.divide
                      "division by zero — use `check Int32.nonZero(b)` before calling Int32.divide"))
  (narrow (quotient (rv a) denom)))

;; ── Predicates and queries ──────────────────────────────────────────────────

(define (Int32.isPositive n) (> (rv n) 0))
(define (Int32.isNegative n) (< (rv n) 0))
(define (Int32.isZero n)     (= (rv n) 0))
(define (Int32.isEven n)     (even? (rv n)))
(define (Int32.isOdd n)      (odd? (rv n)))

;; -1, 0, or 1 as an `Int` (not an Int32) so it composes with Int arithmetic and
;; compares against Int literals — same shape as Int.sign.
(define (Int32.sign n)
  (define v (rv n))
  (cond [(> v 0) 1] [(< v 0) -1] [else 0]))

(define (Int32.digits n)
  (string-length (number->string (abs (rv n)))))

;; ── Proof-minting checks ────────────────────────────────────────────────────

(define (attach-int32-proof pred-name raw-int-value)
  (define nv (ensure-named pred-name raw-int-value))
  (define subj (named-value-name nv))
  (attach nv (list (detached-proof `(,pred-name ,subj) (hash subj raw-int-value)))))

;; Int32.nonZero — check function: returns n ::: IsNonZero n, or check-fail.
;;
;;   let divisor = check Int32.nonZero(rawDivisor)
;;   let result  = Int32.divide(numerator, divisor)
(define (Int32.nonZero n)
  (define v (rv n))
  (if (not (zero? v))
      (let* ([nv   (attach-int32-proof 'IsNonZero v)]
             [subj (named-value-name nv)]
             [fact `(IsNonZero ,subj)])
        (check-ok nv (list fact) (hash subj v)))
      (check-fail "expected a non-zero Int32" 400 #f)))

;; Int32.nonNegative — check function: returns n ::: IsNonNegative n.
(define (Int32.nonNegative n)
  (define v (rv n))
  (if (>= v 0)
      (let* ([nv   (attach-int32-proof 'IsNonNegative v)]
             [subj (named-value-name nv)]
             [fact `(IsNonNegative ,subj)])
        (check-ok nv (list fact) (hash subj v)))
      (check-fail "expected a non-negative Int32" 400 #f)))
