#lang racket
;; ─────────────────────────────────────────────────────────────────────────────
;; Tesl.List — public runtime module (SHIM).
;;
;; This file no longer hand-implements the pure List combinators.  It is now a
;; thin shim that:
;;   • keeps the irreducible LEAVES + proof/FFI machinery as hand-written Racket
;;     (head/tail/append re-exported from `list-prim.rkt`; the rest defined below),
;;   • re-exports the 16 LIFTED combinators (map/filter/foldl/foldr/length/any/
;;     all/find/sum/maximum/minimum/member/contains/concat/concatMap/reverse) from
;;     `list-derived.rkt`, which is COMPILED FROM `tesl/list.tesl` at build time.
;;
;; The lifted bodies are therefore written in Tesl and dogfood the language; the
;; trusted hand-written Racket core shrinks accordingly.  The public dotted
;; `List.*` runtime names and the `tesl/list.rkt` collection path are UNCHANGED,
;; so user-program emission is byte-identical.
;;
;; `list-prim.rkt` is required by BOTH this shim and `list-derived.rkt`; neither
;; requires the other, so there is no module-load cycle.
;; ─────────────────────────────────────────────────────────────────────────────


(require "../dsl/check.rkt"
         "../dsl/types.rkt"
         "tuple.rkt"
         (only-in "../dsl/private/evidence.rkt" detached-proof)
         (only-in "../dsl/private/check-runtime.rkt" attach validate-runtime-argument current-in-forall-filter))

;; ── Proof predicate name ─────────────────────────────────────────────────────
;; Use in Tesl annotations:   xs ::: IsSorted xs
(provide IsSorted)
(define IsSorted     'IsSorted)
(define IsNonNegative 'IsNonNegative)

;; Helpers: attach proofs to values
(define (attach-proof-to pred-name value)
  (define nv (ensure-named pred-name value))
  (define subj (named-value-name nv))
  (attach nv (list (detached-proof `(,pred-name ,subj) (hash subj value)))))

(define (attach-sorted-proof lst)
  (attach-proof-to 'IsSorted lst))

(provide
 List.isEmpty
 List.last
 List.nth
 List.filterCheck
 List.allCheck
 List.emptyForAll
 List.filterMap
 List.sort
 List.sortBy
 List.findIndex
 List.take
 List.drop
 List.zip
 List.zipWith
 List.unzip
 List.flatten
 List.dedupe
 List.range
 List.repeat
 List.product
 List.count
 List.partition
 List.intersperse
 List.intercalate
 List.groupBy
 List.unique)

(define (rv x) (raw-value x))

(define (require-non-negative-count who n)
  (validate-runtime-argument who "function" 'n n 'Int '(IsNonNegative n)))

(define (List.isEmpty xs)
  (null? (rv xs)))

;; List.length — returns plain Int (can be used inline in comparisons)
; (moved) List.length

;; Returns Something(first) or Nothing
; (moved) List.head

;; Returns Something(rest) or Nothing for empty list
; (moved) List.tail

;; Returns Something(last) or Nothing
(define (List.last xs)
  (define lst (rv xs))
  (if (null? lst)
      Nothing
      (Something (last lst))))

;; Zero-based index; returns Something(elem) or Nothing
(define (List.nth xs n)
  (define lst (rv xs))
  (define idx (rv n))
  (if (and (>= idx 0) (< idx (length lst)))
      (Something (list-ref lst idx))
      Nothing))

; (moved) List.map

; (moved) List.filter

;; filterCheck: apply a check function to each element; keep elements that pass (check-ok?).
;; Returns a plain list of the passing elements (ForAll is a compile-time annotation only).
;; Chain calls to expand the proof: filterCheck(checkP2, filterCheck(checkP1, xs))
;;   → result type: List T ::: ForAll (P1 && P2)
(define (List.filterCheck check-fn xs)
  (filter-map (lambda (x)
                ;; Signal that we're in a ForAll-filter context: proof-annotated check
                ;; params skip runtime validation for plain elements (ForAll is
                ;; compile-time only; the static checker has already verified the proof).
                (define result
                  (parameterize ([current-in-forall-filter #t])
                    (check-fn x)))
                (cond
                  [(check-ok? result) (check-ok-value result)]
                  [(check-fail? result) #f]
                  [else
                   (raise-user-error 'List.filterCheck
                                     "check function returned ~a (expected check-ok or check-fail); pass a `check` function, not a plain function"
                                     result)]))
              (rv xs)))

;; allCheck: apply a check function to EVERY element.
;; Returns (Something list) if all elements pass, Nothing if any element fails.
;; Combines with existing ForAll proof: if xs ::: ForAll P1 and all pass checkP2,
;; the result is (Something xs) ::: ForAll (P1 && P2) (declare this in the return type).
(define (List.allCheck check-fn xs)
  (define lst (rv xs))
  (define results
    (map (lambda (x)
           (define result
             (parameterize ([current-in-forall-filter #t])
               (check-fn x)))
           (cond
             [(or (check-ok? result) (check-fail? result)) result]
             [else
              (raise-user-error 'List.allCheck
                                "check function returned ~a (expected check-ok or check-fail); pass a `check` function, not a plain function"
                                result)]))
         lst))
  (if (andmap check-ok? results)
      (Something (map check-ok-value results))
      Nothing))

;; emptyForAll: create an empty list that statically satisfies ForAll P.
;; Takes a check function to identify the predicate P (same convention as filterCheck).
;; The empty list vacuously satisfies any predicate, so this is always valid.
;; Runtime: equivalent to (List.filterCheck check-fn '()), always returns '().
(define (List.emptyForAll check-fn)
  (List.filterCheck check-fn '()))

;; filterMap: apply f to each element; keep Something results, discard Nothing
(define (List.filterMap f xs)
  (filter-map (lambda (x)
                (define r (f x))
                (and (Something? r) (Something-value r)))
              (rv xs)))

;; foldl: (List.foldl f init xs) — strict left fold
; (moved) List.foldl

;; foldr: (List.foldr f init xs)
; (moved) List.foldr

; (moved) List.append

;; Flatten a list of lists one level
; (moved) List.concat

; (moved) List.reverse

;; Natural sort — returns sorted list ::: IsSorted result
(define (List.sort xs)
  (define sorted
    (sort (rv xs) (lambda (a b)
                    (cond
                      [(and (number? (rv a)) (number? (rv b))) (< (rv a) (rv b))]
                      [(and (string? (rv a)) (string? (rv b))) (string<? (rv a) (rv b))]
                      [else #f]))))
  (attach-sorted-proof sorted))

;; Sort by a key function — returns sorted list ::: IsSorted result
(define (List.sortBy f xs)
  (define sorted
    (sort (rv xs) (lambda (a b)
                    (define ka (f a))
                    (define kb (f b))
                    (cond
                      [(and (number? ka) (number? kb)) (< ka kb)]
                      [(and (string? ka) (string? kb)) (string<? ka kb)]
                      [else #f]))))
  (attach-sorted-proof sorted))

; (moved) List.contains

;; Returns Something(first match) or Nothing
; (moved) List.find

;; Returns Something(index) of first matching element or Nothing
(define (List.findIndex pred xs)
  (define lst (rv xs))
  (let loop ([i 0] [remaining lst])
    (cond
      [(null? remaining) Nothing]
      [(pred (car remaining)) (Something i)]
      [else (loop (add1 i) (cdr remaining))])))

(define (List.take n xs)
  (define checked-n (require-non-negative-count 'List.take n))
  (take (rv xs) (min (rv checked-n) (length (rv xs)))))

(define (List.drop n xs)
  (define checked-n (require-non-negative-count 'List.drop n))
  (drop (rv xs) (min (rv checked-n) (length (rv xs)))))

;; Returns list of Tuple2 values
(define (List.zip xs ys)
  ;; Truncate to the shorter list (SQL/functional convention)
  (let ([rxs (rv xs)] [rys (rv ys)])
    (define len (min (length rxs) (length rys)))
    (map Tuple2 (take rxs len) (take rys len))))

(define (List.zipWith f xs ys)
  (map f (rv xs) (rv ys)))

;; Unzip list of Tuple2/legacy pair values into Tuple2(list-a, list-b)
(define (List.unzip pairs)
  (define ps (rv pairs))
  (Tuple2 (map Tuple2.first ps)
          (map Tuple2.second ps)))

;; Flatten one level of nesting (alias for concat)
(define (List.flatten xss)
  (apply append (map rv (rv xss))))

;; Remove consecutive duplicates (use List.unique for full deduplication)
(define (List.dedupe xs)
  (define lst (rv xs))
  (if (null? lst)
      '()
      (let loop ([prev (car lst)] [rest (cdr lst)] [acc (list (car lst))])
        (cond
          [(null? rest) (reverse acc)]
          [(equal? (rv (car rest)) (rv prev)) (loop (car rest) (cdr rest) acc)]
          [else (loop (car rest) (cdr rest) (cons (car rest) acc))]))))

;; Inclusive range [start, end)
(define (List.range start end)
  (for/list ([i (in-range (rv start) (rv end))]) i))

(define (List.repeat x n)
  (define checked-n (require-non-negative-count 'List.repeat n))
  (make-list (rv checked-n) x))

; (moved) List.sum

(define (List.product xs)
  (apply * (map rv (rv xs))))

; (moved) List.maximum

; (moved) List.minimum

; (moved) List.any

; (moved) List.all

(define (List.count pred xs)
  (count pred (rv xs)))

;; Returns Tuple2(matching, non-matching)
(define (List.partition pred xs)
  (define-values (yes no) (partition pred (rv xs)))
  (Tuple2 yes no))

;; Place sep between each element
(define (List.intersperse sep xs)
  (define lst (rv xs))
  (if (null? lst)
      '()
      (let loop ([remaining (cdr lst)] [acc (list (car lst))])
        (if (null? remaining)
            (reverse acc)
            (loop (cdr remaining) (cons (car remaining) (cons sep acc)))))))

;; Join a list of lists with a separator list between each
(define (List.intercalate sep xss)
  (List.flatten (List.intersperse sep xss)))

;; Group consecutive elements with same key
(define (List.groupBy f xs)
  (define lst (rv xs))
  (if (null? lst)
      '()
      (let loop ([remaining (cdr lst)]
                 [cur-key (f (car lst))]
                 [cur-group (list (car lst))]
                 [acc '()])
        (cond
          [(null? remaining)
           (reverse (cons (reverse cur-group) acc))]
          [(equal? (f (car remaining)) cur-key)
           (loop (cdr remaining) cur-key (cons (car remaining) cur-group) acc)]
          [else
           (loop (cdr remaining) (f (car remaining)) (list (car remaining))
                 (cons (reverse cur-group) acc))]))))

;; Remove all duplicate elements (first occurrence wins)
(define (List.unique xs)
  (define seen (make-hash))
  (for/list ([x (in-list (rv xs))]
             #:unless (hash-has-key? seen (rv x)))
    (hash-set! seen (rv x) #t)
    x))

;; flatMap: apply f to each element, concatenate the resulting lists
; (moved) List.concatMap

;; membership test: is x an element of xs?
; (moved) List.member

;; ── LEAF primitives (head/tail/append) — re-exported from list-prim.rkt ──────
;; `only-in` (not bare `rename-in`) so ONLY these three names enter this module;
;; otherwise list-prim's other provides would shadow Racket builtins here.
(require (only-in "list-prim.rkt"
                  [ListPrim.head List.head]
                  [ListPrim.tail List.tail]
                  [ListPrim.append List.append]))
(provide List.head List.tail List.append)

;; ── LIFTED combinators — compiled from tesl/list.tesl into list-derived.rkt ──
;; CRITICAL: use `only-in`, NOT `rename-in`.  `rename-in` imports EVERY provide
;; of list-derived.rkt (it also provides bare `length`, `take`, `drop`, `zip`,
;; … stubs), which would shadow the Racket `length`/`take`/`drop`/`min` used by
;; the hand-written leaf bodies above.  `only-in` brings in exactly the 16 lifted
;; names and nothing else.
(require (only-in "list-derived.rkt"
                  [map List.map]
                  [filter List.filter]
                  [foldl List.foldl]
                  [foldr List.foldr]
                  [length List.length]
                  [any List.any]
                  [all List.all]
                  [find List.find]
                  [sum List.sum]
                  [maximum List.maximum]
                  [minimum List.minimum]
                  [member List.member]
                  [contains List.contains]
                  [concat List.concat]
                  [concatMap List.concatMap]
                  [reverse List.reverse]))
(provide List.map List.filter List.foldl List.foldr List.length List.any List.all
         List.find List.sum List.maximum List.minimum List.member List.contains
         List.concat List.concatMap List.reverse)
