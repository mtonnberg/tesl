#lang racket
;; ─────────────────────────────────────────────────────────────────────────────
;; Tesl.EitherPrim — irreducible LEAF for the Either standard library: the ADT
;; itself (Left a | Right b) plus its constructors/predicates/accessors.
;;
;; These are defined with `define-adt`, which pure Tesl cannot express, so they
;; stay hand-written Racket.  The DERIVED Either combinators (Either.map, …) are
;; written in Tesl in `tesl/either.tesl`, compile to `tesl/either-derived.rkt`,
;; and delegate to these constructors.  Keeping the ADT in its own module breaks
;; the require cycle that would otherwise form between the public shim
;; `either.rkt` and `either-derived.rkt` (both require this file; this file
;; requires neither).
;;
;; Bodies are byte-for-byte the original `define-adt (Either a b)` from
;; `tesl/either.rkt`.
;; ─────────────────────────────────────────────────────────────────────────────

(require "../dsl/types.rkt")

(provide Either Either? Left Right Left? Right? Left-value Right-value)

;; Register Either as a two-parameter ADT.
;; Both variants use the field name "value" so that .value accessor works
;; on either side (matching Maybe.Something.value and Result.Ok.value style).
;; Accessors: Left-value, Right-value, Left?, Right?, Either?
(define-adt (Either a b)
  [Left  value]
  [Right value])
