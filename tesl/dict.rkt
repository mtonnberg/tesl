#lang racket

(require racket/hash
         "../dsl/types.rkt"
         "../dsl/check.rkt"
         "tuple.rkt"
         (only-in "../dsl/private/evidence.rkt" detached-proof check-ok check-fail)
         (only-in "../dsl/private/check-runtime.rkt" attach validate-runtime-argument))

;; Dict k v — a finite map from keys to values.
;; Keys must be strings, integers, or any value supported by Racket's equal?
;; hashing.  The Dict is immutable (persistent data structure).

(provide
 Dict
 HasKey
 Dict.empty
 Dict.singleton
 Dict.insert
 Dict.insertWith
 Dict.remove
 Dict.lookup
 Dict.requireKey
 Dict.get
 Dict.member
 Dict.size
 Dict.isEmpty
 Dict.keys
 Dict.values
 Dict.toList
 Dict.fromList
 Dict.map
 Dict.mapWithKey
 Dict.filter
 Dict.filterWithKey
 Dict.foldl
 Dict.foldr
 Dict.union
 Dict.unionWith
 Dict.intersection
 Dict.difference
 Dict.update
 Dict.filterCheckValues
 Dict.filterCheckKeys)

(define Dict 'Dict)
(define HasKey 'HasKey)

;; Sentinel for missing key (avoids clash with #f values)
(define missing (gensym 'missing))

(define (raw-key k)   (raw-value k))
(define (raw-dict d [who 'Dict])
  (define raw (raw-value d))
  (unless (hash? raw)
    (raise-user-error who "expected a Dict value, got ~a" raw))
  raw)

(define (proof-subject-matches? proof-bindings fact-subject current-subject current-raw)
  (or (equal? fact-subject current-subject)
      (and (hash-has-key? proof-bindings fact-subject)
           (equal? (hash-ref proof-bindings fact-subject) current-raw))))

(define (dict-has-key-proof? dict-evidence key-evidence)
  (define dict-subject (named-value-name dict-evidence))
  (define key-subject (named-value-name key-evidence))
  (define dict-raw (raw-dict dict-evidence 'Dict.get))
  (define key-raw (raw-key key-evidence))
  (define proof-bindings (named-value-bindings dict-evidence))
  (for/or ([fact (in-list (facts-of dict-evidence))])
    (and (list? fact)
         (= (length fact) 3)
         (eq? (first fact) 'HasKey)
         (proof-subject-matches? proof-bindings (second fact) key-subject key-raw)
         (proof-subject-matches? proof-bindings (third fact) dict-subject dict-raw))))

;; An empty dictionary
(define Dict.empty (hash))

;; A dictionary with a single key/value pair
(define (Dict.singleton k v)
  (hash (raw-key k) (raw-value v)))

;; Insert or overwrite a key
(define (Dict.insert k v d)
  (hash-set (raw-dict d 'Dict.insert) (raw-key k) (raw-value v)))

;; Insert with a combining function: f new-val old-val
(define (Dict.insertWith f k v d)
  (define rk (raw-key k))
  (define rv0 (raw-value v))
  (define rd (raw-dict d 'Dict.insertWith))
  (define existing (hash-ref rd rk missing))
  (if (eq? existing missing)
      (hash-set rd rk rv0)
      (hash-set rd rk (f rv0 existing))))

;; Remove a key (no-op if absent)
(define (Dict.remove k d)
  (hash-remove (raw-dict d 'Dict.remove) (raw-key k)))

;; Returns Something(value) or Nothing
(define (Dict.lookup k d)
  (define v (hash-ref (raw-dict d 'Dict.lookup) (raw-key k) missing))
  (if (eq? v missing) Nothing (Something v)))

(define (Dict.requireKey k d)
  (define checked-key
    (validate-runtime-argument 'Dict.requireKey "check" 'key k 'Any))
  (define checked-dict
    (validate-runtime-argument 'Dict.requireKey "check" 'dict d 'Any))
  (define rk (raw-key checked-key))
  (define rd (raw-dict checked-dict 'Dict.requireKey))
  (if (hash-has-key? rd rk)
      (let* ([key-subject (named-value-name checked-key)]
             [dict-subject (named-value-name checked-dict)]
             [proof (detached-proof `(HasKey ,key-subject ,dict-subject)
                                    (hash key-subject rk
                                          dict-subject rd))]
             [dict-with-proof (attach checked-dict (list proof))])
        (check-ok dict-with-proof
                  (facts-of dict-with-proof)
                  (named-value-bindings dict-with-proof)))
      (check-fail (format "expected key ~a to be present in Dict" rk) 400 #f)))

;; Returns the value for a proven-present key.
(define (Dict.get k d)
  (define checked-key
    (validate-runtime-argument 'Dict.get "function" 'key k 'Any))
  (define checked-dict
    (validate-runtime-argument 'Dict.get "function" 'dict d 'Any))
  (unless (dict-has-key-proof? checked-dict checked-key)
    (raise-user-error 'Dict.get
                      "Dict.get requires a Dict proven to contain the key — use `check Dict.requireKey(key, dict)` first"))
  (define rk (raw-key checked-key))
  (define rd (raw-dict checked-dict 'Dict.get))
  (unless (hash-has-key? rd rk)
    (raise-user-error 'Dict.get
                      "Dict.get requires proof that the requested key is present — use `check Dict.requireKey(key, dict)` first"))
  (hash-ref rd rk))

(define (Dict.member k d)
  (hash-has-key? (raw-dict d 'Dict.member) (raw-key k)))

(define (Dict.size d)
  (hash-count (raw-dict d 'Dict.size)))

(define (Dict.isEmpty d)
  (zero? (hash-count (raw-dict d 'Dict.isEmpty))))

(define (Dict.keys d)
  (hash-keys (raw-dict d 'Dict.keys)))

(define (Dict.values d)
  (hash-values (raw-dict d 'Dict.values)))

;; Returns list of Tuple2(key, value) pairs
(define (Dict.toList d)
  (for/list ([(k v) (in-hash (raw-dict d 'Dict.toList))]) (Tuple2 k v)))

;; Build from list of Tuple2/legacy pair values (later duplicates win)
(define (Dict.fromList pairs)
  (for/hash ([pair (in-list (raw-value pairs))])
    (values (Tuple2.first pair) (Tuple2.second pair))))

;; Map over values
(define (Dict.map f d)
  (for/hash ([(k v) (in-hash (raw-dict d 'Dict.map))])
    (values k (f v))))

;; Map over keys and values
(define (Dict.mapWithKey f d)
  (for/hash ([(k v) (in-hash (raw-dict d 'Dict.mapWithKey))])
    (values k (f k v))))

;; Keep entries where predicate(value) is true
(define (Dict.filter pred d)
  (for/hash ([(k v) (in-hash (raw-dict d 'Dict.filter))]
             #:when (pred v))
    (values k v)))

(define (Dict.filterWithKey pred d)
  (for/hash ([(k v) (in-hash (raw-dict d 'Dict.filterWithKey))]
             #:when (pred k v))
    (values k v)))

;; Left fold over values: f acc value
(define (Dict.foldl f init d)
  (for/fold ([acc (raw-value init)])
            ([(k v) (in-hash (raw-dict d 'Dict.foldl))])
    (f acc v)))

;; Right fold over values (conceptually — hash has no order, so this is
;; semantically a fold over all values in iteration order)
(define (Dict.foldr f init d)
  (foldr (lambda (v acc) (f v acc))
         (raw-value init)
         (hash-values (raw-dict d 'Dict.foldr))))

;; Left-biased union: keys from d1 win on conflict
(define (Dict.union d1 d2)
  ;; hash-union with #:combine keeps d1's value when both dicts have the same key
  (hash-union (raw-dict d2 'Dict.union) (raw-dict d1 'Dict.union) #:combine (lambda (_v2 v1) v1)))

;; Union with combining function: f v1 v2 (v1 from d1, v2 from d2)
(define (Dict.unionWith f d1 d2)
  (define rd1 (raw-dict d1 'Dict.unionWith))
  (define rd2 (raw-dict d2 'Dict.unionWith))
  (for/fold ([acc rd1]) ([(k v2) (in-hash rd2)])
    (define existing (hash-ref acc k missing))
    (if (eq? existing missing)
        (hash-set acc k v2)
        (hash-set acc k (f existing v2)))))

;; Keep only keys present in both dicts (values from d1)
(define (Dict.intersection d1 d2)
  (define rd2 (raw-dict d2 'Dict.intersection))
  (for/hash ([(k v) (in-hash (raw-dict d1 'Dict.intersection))]
             #:when (hash-has-key? rd2 k))
    (values k v)))

;; Keys present in d1 but not in d2
(define (Dict.difference d1 d2)
  (define rd2 (raw-dict d2 'Dict.difference))
  (for/hash ([(k v) (in-hash (raw-dict d1 'Dict.difference))]
             #:unless (hash-has-key? rd2 k))
    (values k v)))

;; Apply f to the existing value at key (Something old-val → result, Nothing → Nothing to remove)
;; f receives Something(val) if key exists, Nothing if absent; returns Something(new-val) to keep, Nothing to remove
(define (Dict.update k f d)
  (define rk (raw-key k))
  (define rd (raw-dict d 'Dict.update))
  (define existing (hash-ref rd rk missing))
  (define result (f (if (eq? existing missing) Nothing (Something existing))))
  (cond
    [(Nothing? result) (hash-remove rd rk)]
    [(Something? result)   (hash-set rd rk (Something-value result))]
    [else             rd]))

;; filterCheckValues: apply a check function to each value; keep entries that pass.
;; Returns the same Dict with values verified. ForAllValues P is a compile-time annotation only.
(define (Dict.filterCheckValues check-fn d)
  (for/fold ([acc (hash)]) ([(k v) (in-hash (raw-dict d 'Dict.filterCheckValues))])
    (define result (check-fn v))
    (cond
      [(check-ok? result) (hash-set acc k (check-ok-value result))]
      [(check-fail? result) acc]
      [else (raise-user-error 'Dict.filterCheckValues
                              "check function returned ~a (expected check-ok or check-fail); pass a `check` function, not a plain function"
                              result)])))

;; filterCheckKeys: apply a check function to each key; keep entries that pass.
;; Returns the same Dict with keys verified. ForAllKeys P is a compile-time annotation only.
(define (Dict.filterCheckKeys check-fn d)
  (for/fold ([acc (hash)]) ([(k v) (in-hash (raw-dict d 'Dict.filterCheckKeys))])
    (define result (check-fn k))
    (cond
      [(check-ok? result) (hash-set acc (check-ok-value result) v)]
      [(check-fail? result) acc]
      [else (raise-user-error 'Dict.filterCheckKeys
                              "check function returned ~a (expected check-ok or check-fail); pass a `check` function, not a plain function"
                              result)])))
