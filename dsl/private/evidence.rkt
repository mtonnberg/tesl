#lang typed/racket/optional

;; evidence.rkt — GDP evidence struct definitions and base-layer utilities.
;;
;; Typing note: this module uses #lang typed/racket/optional as a
;; static-documentation experiment.  Optional typing ERASES at runtime
;; (no contracts are generated at the typed/untyped boundary), so the
;; untyped importers (types.rkt, check-runtime.rkt) load these structs and
;; helpers with zero runtime cost and no behavioural change.  Many fields
;; are genuinely heterogeneous Tesl runtime values and are typed `Any`.
;;
;; Design note: this file is the lowest-level layer of the GDP runtime.
;; It is required by types.rkt, which in turn is required by check-runtime.rkt.
;; Because of this load order, functions that need the parameterize-based
;; environment lookups (current-evidence-env, current-proof-env) cannot live
;; here — those live in check-runtime.rkt, which re-provides them under the
;; same names, effectively shadowing these base-layer versions for all callers
;; that go through check-runtime.rkt.  types.rkt uses only the simpler base
;; versions here, which is correct (type-level operations do not interact with
;; runtime evidence environments).

(provide
 (struct-out named-value)
 (struct-out check-ok)
 (struct-out check-fail)
 (struct-out detached-proof)
 (struct-out packed-witness)
 (struct-out packed-exists)
 (struct-out runtime-binding)
 check-result?
 check-success?
 merge-bindings
 raw-value
 tesl-display-val
 facts-of
 ensure-named
 attach
 forget-proof)

;; Bindings map runtime names (symbols) to raw Tesl values.
(define-type Bindings (HashTable Any Any))

(struct named-value ([name : Any] [value : Any] [facts : (Listof Any)] [bindings : Bindings]) #:transparent)
(struct check-ok ([value : Any] [facts : (Listof Any)] [bindings : Bindings]) #:transparent)
(struct check-fail ([message : Any] [status : Any] [details : Any]) #:transparent)
(struct detached-proof ([fact : Any] [bindings : Bindings]) #:transparent)
(struct packed-witness ([public-name : Any] [value : Any]) #:transparent)
(struct packed-exists ([witnesses : Any] [body : Any]) #:transparent)
(struct runtime-binding ([name : Any] [raw : Any] [bindings : Bindings]) #:transparent)

(: check-result? (-> Any Boolean))
(define (check-result? value)
  (or (check-ok? value) (check-fail? value)))

(: check-success? (-> Any Boolean))
(define (check-success? value)
  (check-ok? value))

;; Base-layer raw-value: no environment lookup.
;; check-runtime.rkt provides an extended version with current-evidence-env support.
(: raw-value (-> Any Any))
(define (raw-value value)
  (cond
    [(named-value? value) (named-value-value value)]
    [(check-ok? value) (check-ok-value value)]
    [else value]))

;; Convert a Tesl value to its string representation for use in string
;; interpolation ("${expr}").  Booleans are rendered as "true"/"false"
;; (Tesl convention) rather than Racket's "#t"/"#f".
(: tesl-display-val (-> Any Any))
(define (tesl-display-val value)
  (let ([r (raw-value value)])
    (if (boolean? r)
        (if r "true" "false")
        r)))

;; Base-layer facts-of: no environment lookup.
;; check-runtime.rkt provides an extended version with current-evidence-env support.
(: facts-of (-> Any (Listof Any)))
(define (facts-of value)
  (cond
    [(named-value? value) (named-value-facts value)]
    [(check-ok? value) (check-ok-facts value)]
    [(detached-proof? value) (list (detached-proof-fact value))]
    [else '()]))

(: merge-bindings (-> Bindings Bindings Bindings))
(define (merge-bindings left right)
  (for/fold ([acc : Bindings left]) ([(key value) (in-hash right)])
    (hash-set acc key value)))

(: public-name-symbol? (-> Any Boolean))
(define (public-name-symbol? name)
  (and (symbol? name)
       (eq? (string->symbol (symbol->string name)) name)))

(: fresh-runtime-name (-> Any Symbol))
(define (fresh-runtime-name label)
  (cond
    [(symbol? label) (gensym label)]
    [else (gensym 'value)]))

(: normalize-runtime-name (-> Any Symbol))
(define (normalize-runtime-name name)
  (cond
    [(public-name-symbol? name) (fresh-runtime-name name)]
    [(symbol? name) name]
    [else (fresh-runtime-name name)]))

(: evidence->facts+bindings (-> Any (Values (Listof Any) Bindings)))
(define (evidence->facts+bindings evidence)
  (cond
    [(check-ok? evidence)
     (values (check-ok-facts evidence)
             (check-ok-bindings evidence))]
    [(named-value? evidence)
     (values (named-value-facts evidence)
             (named-value-bindings evidence))]
    [(detached-proof? evidence)
     (values (list (detached-proof-fact evidence))
             (detached-proof-bindings evidence))]
    [(and (list? evidence) (andmap detached-proof? evidence))
     (values (map detached-proof-fact evidence)
             (for/fold ([acc : Bindings (hash)]) ([proof (in-list evidence)])
               (merge-bindings acc (detached-proof-bindings proof))))]
    [else
     (values (list evidence) (hash))]))

;; Base-layer ensure-named: no #:subject keyword or environment lookup.
;; check-runtime.rkt provides the full version with #:subject support.
(: ensure-named (->* (Any Any) ((Listof Any) Bindings) named-value))
(define (ensure-named name value [facts '()] [bindings (hash)])
  (define effective-name
    (cond
      [(named-value? value)
       (if (public-name-symbol? name)
           (named-value-name value)
           name)]
      [else
       (normalize-runtime-name name)]))
  (define raw (raw-value value))
  (define base-bindings : Bindings
    (cond
      [(named-value? value) (named-value-bindings value)]
      [else (hash)]))
  (named-value effective-name
               raw
               (append (if (named-value? value)
                           (named-value-facts value)
                           '())
                       facts)
               (hash-set (merge-bindings base-bindings bindings)
                         effective-name
                         raw)))

(: attach (-> Any Any named-value))
(define (attach value evidence)
  (define-values (extra-facts extra-bindings)
    (evidence->facts+bindings evidence))
  (ensure-named
   (if (named-value? value)
       (named-value-name value)
       (gensym 'value))
   value
   extra-facts
   extra-bindings))

(: forget-proof (-> Any Any))
(define (forget-proof value)
  (cond
    [(named-value? value)
     (named-value (named-value-name value)
                  (named-value-value value)
                  '()
                  (named-value-bindings value))]
    [(check-ok? value)
     (check-ok (check-ok-value value)
               '()
               (check-ok-bindings value))]
    [else value]))
