#lang racket

(require racket/set
         "../dsl/types.rkt"
         "../dsl/check.rkt"
         "tuple.rkt")

;; Set a — an unordered collection of unique elements.
;; Backed by Racket immutable hash sets for O(1) member/insert/remove.

(provide
 Set
 Set.empty
 Set.singleton
 Set.insert
 Set.remove
 Set.delete
 Set.member
 Set.size
 Set.isEmpty
 Set.toList
 Set.fromList
 Set.union
 Set.intersection
 Set.difference
 Set.isSubset
 Set.map
 Set.filter
 Set.foldl
 Set.any
 Set.all
 Set.partition
 Set.filterCheck
 Set.allCheck)

(define Set 'Set)

;; Canonical empty set (equal?-based hashing for mixed key types)
(define Set.empty (set))

;; Note: we use Racket's immutable setequalv? sets (equal?-based hashing)
;; so that string keys and integers work naturally.
;;
;; THE HASH REPRESENTATION IS LOAD-BEARING FOR SECRETS — do not switch this to a
;; list- or assoc-backed set without re-reading this.
;;
;; `Set.member` on a `secret`-typed element (e.g. `Set.member submittedKey
;; validApiKeys`) reaches Racket's `equal?`, which short-circuits at the first
;; differing byte. On a LIST-backed set that would be a genuine timing oracle:
;; an attacker submitting candidates would learn how many leading bytes matched a
;; stored key, one byte at a time — exactly the attack that `==` on a secret is
;; lowered to a constant-time compare to prevent.
;;
;; It is NOT an oracle here, because a hash set compares only within a bucket and
;; the hash is computed over the WHOLE candidate. A candidate differing from a
;; real key in its last byte lands in an unrelated bucket and never reaches a
;; byte-by-byte comparison at all, so there is no "guess one more byte" primitive
;; to iterate. Reaching the compare requires a hash collision with a real key,
;; which is not a prefix-extension step.
;;
;; Residual, stated so it is not mistaken for a guarantee: the hash is computed
;; over the secret, and its cost varies with the value's LENGTH. Length is not
;; the thing being protected, so that is acceptable — but it is the reason this is
;; "no usable oracle" rather than "constant-time".

(define (make-set-from xs)
  (list->set xs))

(define (raw-set s [who 'Set])
  (define v (raw-value s))
  (unless (set? v)
    (raise-user-error who "expected a Set value, got ~a" v))
  v)

(define (Set.singleton x)
  (set (raw-value x)))

(define (Set.insert x s)
  (set-add (raw-set s 'Set.insert) (raw-value x)))

(define (Set.remove x s)
  (set-remove (raw-set s 'Set.remove) (raw-value x)))

;; `Set.delete` is a synonym of `Set.remove` (declared as an alias in the type
;; table; was importable but had no runtime binding → unbound at load).
(define Set.delete Set.remove)

(define (Set.member x s)
  (set-member? (raw-set s 'Set.member) (raw-value x)))

(define (Set.size s)
  (set-count (raw-set s 'Set.size)))

(define (Set.isEmpty s)
  (set-empty? (raw-set s 'Set.isEmpty)))

(define (Set.toList s)
  (set->list (raw-set s 'Set.toList)))

(define (Set.fromList xs)
  (list->set (map raw-value (raw-value xs))))

(define (Set.union s1 s2)
  (set-union (raw-set s1 'Set.union) (raw-set s2 'Set.union)))

(define (Set.intersection s1 s2)
  (set-intersect (raw-set s1 'Set.intersection) (raw-set s2 'Set.intersection)))

(define (Set.difference s1 s2)
  (set-subtract (raw-set s1 'Set.difference) (raw-set s2 'Set.difference)))

;; Returns true if every element of s1 is also in s2
(define (Set.isSubset s1 s2)
  (subset? (raw-set s1 'Set.isSubset) (raw-set s2 'Set.isSubset)))

(define (Set.map f s)
  (list->set (map f (set->list (raw-set s 'Set.map)))))

(define (Set.filter pred s)
  (for/set ([x (in-set (raw-set s 'Set.filter))]
            #:when (pred x))
    x))

(define (Set.foldl f init s)
  (for/fold ([acc (raw-value init)])
            ([x (in-set (raw-set s 'Set.foldl))])
    (f acc x)))

(define (Set.any pred s)
  (for/or ([x (in-set (raw-set s 'Set.any))]) (pred x)))

(define (Set.all pred s)
  (for/and ([x (in-set (raw-set s 'Set.all))]) (pred x)))

;; filterCheck: apply a check function to each element; keep elements that pass (check-ok?).
;; Returns a plain set of the passing elements (ForAll is a compile-time annotation only).
(define (Set.filterCheck check-fn s)
  (list->set
   (filter-map (lambda (x)
                 (define result (check-fn x))
                 (cond
                   [(check-ok? result) (check-ok-value result)]
                   [(check-fail? result) #f]
                   [else
                    (raise-user-error 'Set.filterCheck
                                      "check function returned ~a (expected check-ok or check-fail); pass a `check` function, not a plain function"
                                      result)]))
               (set->list (raw-set s 'Set.filterCheck)))))

;; allCheck: apply a check function to EVERY element.
;; Returns (Something set) if all elements pass, Nothing if any element fails.
(define (Set.allCheck check-fn s)
  (define lst (set->list (raw-set s 'Set.allCheck)))
  (define results
    (map (lambda (x)
           (define result (check-fn x))
           (cond
             [(or (check-ok? result) (check-fail? result)) result]
             [else
              (raise-user-error 'Set.allCheck
                                "check function returned ~a (expected check-ok or check-fail); pass a `check` function, not a plain function"
                                result)]))
         lst))
  (if (andmap check-ok? results)
      (Something (list->set (map check-ok-value results)))
      Nothing))

;; Returns Tuple2(matching-set, non-matching-set)
(define (Set.partition pred s)
  (define-values (yes no)
    (for/fold ([y (set)] [n (set)])
              ([x (in-set (raw-set s 'Set.partition))])
      (if (pred x)
          (values (set-add y x) n)
          (values y (set-add n x)))))
  (Tuple2 yes no))