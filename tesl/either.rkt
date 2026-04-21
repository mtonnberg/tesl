#lang racket

(require "../dsl/types.rkt"
         "../dsl/check.rkt"
         "tuple.rkt")

;; Either a b — a value that is either Left(a) or Right(b).
;; By convention Right is "success" and Left is "error/other".
;;
;; Either is a proper two-parameter Tesl ADT, like Result Ok/Err.
;; Pattern-match it with case:
;;   case result of
;;     Left err   -> ...
;;     Right val  -> ...
;;
;; Field access uses .value in both variants:
;;   left.value   -- the left payload (type a)
;;   right.value  -- the right payload (type b)

(provide
 Either Either? Left Right Left? Right? Left-value Right-value
 Either.isLeft Either.isRight
 Either.fromLeft Either.fromRight
 Either.map Either.mapLeft
 Either.andThen
 Either.withDefault
 Either.toMaybe
 Either.fromMaybe
 Either.partition)

;; Register Either as a two-parameter ADT.
;; Both variants use the field name "value" so that .value accessor works
;; on either side (matching Maybe.Something.value and Result.Ok.value style).
;; Accessors: Left-value, Right-value, Left?, Right?, Either?
(define-adt (Either a b)
  [Left  value]
  [Right value])

;; Convenience predicates (Racket-level; in Tesl use case or Either.isLeft).
(define (Either.isLeft  x) (Left?  (raw-value x)))
(define (Either.isRight x) (Right? (raw-value x)))

;; Returns Something(value) or Nothing
(define (Either.fromLeft x)
  (define v (raw-value x))
  (if (Left?  v) (Something (Left-value  v)) Nothing))

(define (Either.fromRight x)
  (define v (raw-value x))
  (if (Right? v) (Something (Right-value v)) Nothing))

;; Map over the Right side; Left passes through unchanged
(define (Either.map f x)
  (define v (raw-value x))
  (if (Right? v) (Right (f (Right-value v))) x))

;; Map over the Left side; Right passes through unchanged
(define (Either.mapLeft f x)
  (define v (raw-value x))
  (if (Left? v) (Left (f (Left-value v))) x))

;; Monadic bind on Right: f must return an Either
(define (Either.andThen f x)
  (define v (raw-value x))
  (if (Right? v) (f (Right-value v)) x))

;; Extract Right value or use default
(define (Either.withDefault default x)
  (define v (raw-value x))
  (if (Right? v) (Right-value v) (raw-value default)))

;; Right → Something; Left → Nothing
(define (Either.toMaybe x)
  (define v (raw-value x))
  (if (Right? v) (Something (Right-value v)) Nothing))

;; Something → Right; Nothing → Left(left-val)
(define (Either.fromMaybe left-val m)
  (if (Something? m)
      (Right (Something-value m))
      (Left (raw-value left-val))))

;; Partition a list of Either into Tuple2(lefts, rights)
(define (Either.partition eithers)
  (define lst (raw-value eithers))
  (define-values (ls rs)
    (partition (lambda (x) (Left? (raw-value x))) lst))
  (Tuple2 (map (lambda (x) (Left-value  (raw-value x))) ls)
          (map (lambda (x) (Right-value (raw-value x))) rs)))
