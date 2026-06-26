#lang racket
;; ─────────────────────────────────────────────────────────────────────────────
;; Tesl.Either — public runtime module (SHIM).
;;
;; Either a b — a value that is either Left(a) or Right(b).
;; By convention Right is "success" and Left is "error/other".
;;
;; Pattern-match it with case:
;;   case result of
;;     Left err  -> ...
;;     Right val -> ...
;;
;; This file no longer hand-implements the pure Either combinators.  It is a
;; thin shim that:
;;   • re-exports the ADT (Either/Left/Right/predicates/accessors) from the leaf
;;     module `either-prim.rkt` (the `define-adt` lives there now), and
;;   • re-exports the 10 LIFTED combinators (isLeft/isRight/fromLeft/fromRight/
;;     map/mapLeft/andThen/withDefault/toMaybe/fromMaybe) from
;;     `either-derived.rkt`, which is COMPILED FROM `tesl/either.tesl` at build
;;     time, under their dotted Either.* runtime names.
;;   • keeps Either.partition (a list-consuming leaf) hand-written here.
;;
;; The public dotted Either.* names and the `tesl/either.rkt` collection path are
;; UNCHANGED, so user-program emission is byte-identical.
;;
;; `either-prim.rkt` is required by BOTH this shim and `either-derived.rkt`;
;; neither requires the other, so there is no module-load cycle.  (A shim that
;; defined the ADT itself and was required back by either-derived.rkt cycles
;; fatally — verified.)
;; ─────────────────────────────────────────────────────────────────────────────

(require "../dsl/types.rkt"
         "../dsl/check.rkt"
         "tuple.rkt")

;; ── ADT (Either/Left/Right) — re-exported from the leaf module ───────────────
(require "either-prim.rkt")
(provide (all-from-out "either-prim.rkt"))

;; ── Either.partition — list-consuming leaf, kept hand-written ────────────────
;; Partition a list of Either into Tuple2(lefts, rights)
(provide Either.partition)
(define (Either.partition eithers)
  (define lst (raw-value eithers))
  (define-values (ls rs)
    (partition (lambda (x) (Left? (raw-value x))) lst))
  (Tuple2 (map (lambda (x) (Left-value  (raw-value x))) ls)
          (map (lambda (x) (Right-value (raw-value x))) rs)))

;; ── LIFTED combinators — compiled from tesl/either.tesl into either-derived.rkt ──
(require (only-in "either-derived.rkt"
                  [isLeft Either.isLeft]
                  [isRight Either.isRight]
                  [fromLeft Either.fromLeft]
                  [fromRight Either.fromRight]
                  [map Either.map]
                  [mapLeft Either.mapLeft]
                  [andThen Either.andThen]
                  [withDefault Either.withDefault]
                  [toMaybe Either.toMaybe]
                  [fromMaybe Either.fromMaybe]))
(provide Either.isLeft Either.isRight Either.fromLeft Either.fromRight Either.map
         Either.mapLeft Either.andThen Either.withDefault Either.toMaybe
         Either.fromMaybe)
