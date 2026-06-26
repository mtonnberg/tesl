#lang racket
;; ─────────────────────────────────────────────────────────────────────────────
;; Tesl.ListPrim — irreducible LEAF primitives for the List standard library.
;;
;; These three are the deconstruction/reconstruction primitives that pure Tesl
;; cannot express (Tesl has no `car`/`cdr`/`cons` and no `[h | t]` pattern):
;;
;;   ListPrim.head : List a -> Maybe a            (Something first | Nothing)
;;   ListPrim.tail : List a -> Maybe (List a)     (Something rest  | Nothing)
;;   ListPrim.append : List a -> List a -> List a  (Racket `append`)
;;
;; The DERIVED List combinators (List.map, List.sum, …) are written in real Tesl
;; in `tesl/list.tesl`, compile to `tesl/list-derived.rkt`, and delegate to these
;; leaves.  Keeping the leaves in their own module breaks the require cycle that
;; would otherwise form between the shim `list.rkt` and `list-derived.rkt`
;; (both require this file; this file requires neither).
;;
;; Bodies are byte-for-byte the same as the original hand-written
;; `List.head`/`List.tail`/`List.append` in `tesl/list.rkt`, only renamed to the
;; dotted `ListPrim.*` runtime symbols.
;; ─────────────────────────────────────────────────────────────────────────────

(require "../dsl/check.rkt"
         "../dsl/types.rkt")

(provide
 ListPrim.head
 ListPrim.tail
 ListPrim.append)

(define (rv x) (raw-value x))

;; Returns Something(first) or Nothing
(define (ListPrim.head xs)
  (define lst (rv xs))
  (if (pair? lst) (Something (car lst)) Nothing))

;; Returns Something(rest) or Nothing for empty list
(define (ListPrim.tail xs)
  (define lst (rv xs))
  (if (pair? lst) (Something (cdr lst)) Nothing))

(define (ListPrim.append xs ys)
  (append (rv xs) (rv ys)))
