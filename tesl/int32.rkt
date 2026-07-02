#lang racket

;;; Tesl.Int32 (NT-07) — a JS-safe, 32-bit-bounded integer for wire/storage
;;; boundaries. `Int32` is NOMINAL at the type level (it does not unify with
;;; `Int`); at runtime an Int32 value is just its underlying exact integer.
;;;
;;;   import Tesl.Int32 exposing [Int32, Int32.fromInt, Int32.toInt]
;;;
;;;   Int32.fromInt : Int -> Maybe Int32   -- checked narrowing (the ONLY value
;;;                                            check; Nothing when out of range)
;;;   Int32.toInt   : Int32 -> Int          -- total widening (no check)
;;;
;;; `int32?` is registered as the runtime type so the codec decode-boundary
;;; range-checks an incoming JSON `Int32` field (a value outside [-2^31, 2^31)
;;; is rejected rather than silently wrapped).

(require "../dsl/types.rkt")

(provide Int32.fromInt Int32.toInt)

(define INT32-MIN (- (expt 2 31)))
(define INT32-MAX (sub1 (expt 2 31)))

(define (int32? v)
  (and (exact-integer? v) (>= v INT32-MIN) (<= v INT32-MAX)))

(register-runtime-type! 'Int32 int32?)

(define (Int32.fromInt v)
  (if (int32? v) (Something v) Nothing))

(define (Int32.toInt v) v)
