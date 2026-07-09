#lang racket

(require "../capability.rkt"
         "evidence.rkt"
         "proof-utils.rkt"
         "../types.rkt"
         racket/list
         racket/match
         racket/stxparam
         (for-syntax racket/base
                     racket/list
                     racket/string
                     racket/syntax
                     syntax/parse
                     "../types.rkt")
         (for-meta 2 racket/base
                     racket/list
                     racket/syntax
                     syntax/parse))

(provide
 (all-from-out "../types.rkt")
 (struct-out named-value)
 (struct-out check-ok)
 (struct-out check-fail)
 (struct-out detached-proof)
 (struct-out packed-witness)
 (struct-out packed-exists)
 (struct-out runtime-binding)
 check-result?
 check-success?
 current-name-env
 current-proof-env
 current-evidence-env
 current-type-env
 raw-value
 tesl-display-val
 forget-proof
 merge-bindings
 instantiate-proof-template
 runtime-bind
 runtime-bind+evidence
 extend-name-env
 extend-proof-env
 extend-evidence-env
 extend-type-env
 validate-runtime-argument
 value-field-access-type
 tesl-dot/runtime
 facts-of
 ensure-named
 restrict-bindings-to-fact
 attach
 attach-proof
 accept/value
 detach-proof
 detach-all-proof
 intro-and
 and-left
 and-right
 pack
 unpack
 let-exists
 define-checker
 define-auther
 accept
 reject
 let/check
 if/check
 check-and
 tesl-establish-param-proof
 current-let-check-fail-behavior
 handle-check-fail-in-let
 current-in-forall-filter)

(define current-name-env (make-parameter (hash)))
(define current-proof-env (make-parameter (hash)))
(define current-evidence-env (make-parameter (hash)))

; When set to a procedure, handle-check-fail-in-let calls it instead of
; returning the check-fail value.  Set by define/pow and define-trusted so
; that accidental check-fail propagation through let bindings (as opposed to
; explicit let/check propagation) raises a runtime error.
(define current-let-check-fail-behavior (make-parameter #f))

;; Set to #t inside List.filterCheck / List.allCheck so that proof-annotated
;; check-function parameters skip runtime proof validation on plain elements.
;; The compile-time ForAll annotation already guarantees the proof requirement;
;; raw list elements don't carry runtime proof structs (ForAll is zero-cost).
(define current-in-forall-filter (make-parameter #f))

(define (handle-check-fail-in-let cf)
  (define handler (current-let-check-fail-behavior))
  (if handler (handler cf) cf))
(define current-type-env (make-parameter (hash)))
(define current-check-default-value (make-parameter #f))
(define current-check-input-facts (make-parameter (list)))

(define (raw-value value)
  (cond
    [(and (symbol? value)
          (hash-has-key? (current-evidence-env) value))
     (raw-value (hash-ref (current-evidence-env) value))]
    [(named-value? value) (named-value-value value)]
    [(check-ok? value) (raw-value (check-ok-value value))]
    ;; Exists-pack projection (matrix proof/existpack): the checker types an
    ;; exists-returning fn's result as its UNDERLYING type, so value-position
    ;; consumption (`String.length tok`) must see the packed body — otherwise
    ;; the raw packed-exists struct escapes into prims ("string-length:
    ;; contract violation … given: (packed-exists …)").  The existential hides
    ;; witness NAMES only; facts-of stays '() for a packed value, so proof
    ;; hiding is preserved (unpack still goes through resolve-packed-exists).
    [(packed-exists? value) (raw-value (packed-exists-body value))]
    [else value]))


(define (facts-of value)
  (cond
    [(and (symbol? value)
          (hash-has-key? (current-evidence-env) value))
     (facts-of (hash-ref (current-evidence-env) value))]
    [(named-value? value) (named-value-facts value)]
    [(check-ok? value) (check-ok-facts value)]
    [(detached-proof? value) (list (detached-proof-fact value))]
    [else '()]))

(define (public-name-symbol? name)
  (and (symbol? name)
       (eq? (string->symbol (symbol->string name)) name)))

(define (fresh-runtime-name label)
  (cond
    [(symbol? label) (gensym label)]
    [else (gensym 'value)]))

(define (normalize-runtime-name name)
  (cond
    [(public-name-symbol? name) (fresh-runtime-name name)]
    [(symbol? name) name]
    [else (fresh-runtime-name name)]))

(define (runtime-evidence public-name value)
  (value->packed-witness public-name value))

(define (runtime-bind+evidence public-name value)
  (define named (runtime-evidence public-name value))
  (values named
          (runtime-binding (named-value-name named)
                           (named-value-value named)
                           (named-value-bindings named))))

(define (runtime-bind public-name value)
  (define-values (_named binding)
    (runtime-bind+evidence public-name value))
  binding)

(define (extend-name-env env public-names bindings)
  (for/fold ([acc env]) ([public-name (in-list public-names)]
                         [binding (in-list bindings)])
    (hash-set acc public-name (runtime-binding-name binding))))

(define (extend-proof-env env bindings)
  (for/fold ([acc env]) ([binding (in-list bindings)])
    (merge-bindings acc (runtime-binding-bindings binding))))

(define (extend-evidence-env env evidence-values)
  (for/fold ([acc env]) ([evidence-value (in-list evidence-values)])
    (hash-set acc (named-value-name evidence-value) evidence-value)))

(define (extend-type-env env bindings types)
  (for/fold ([acc env]) ([binding (in-list bindings)]
                         [type-datum (in-list types)])
    (if type-datum
        (hash-set acc (runtime-binding-name binding) type-datum)
        acc)))

(define (value-field-access-type value)
  (cond
    [(named-value? value)
     (or (hash-ref (current-type-env) (named-value-name value) #f)
         (field-access-type-for-value (named-value-value value)))]
    [(runtime-binding? value)
     (or (hash-ref (current-type-env) (runtime-binding-name value) #f)
         (field-access-type-for-value (runtime-binding-raw value)))]
    [(symbol? value)
     (or (hash-ref (current-type-env) value #f)
         (and (hash-has-key? (current-evidence-env) value)
              (field-access-type-for-value (raw-value (hash-ref (current-evidence-env) value))))
         (and (hash-has-key? (current-proof-env) value)
              (field-access-type-for-value (hash-ref (current-proof-env) value))))]
    [(check-ok? value)
     (field-access-type-for-value (check-ok-value value))]
    [else
     (field-access-type-for-value (raw-value value))]))

;; [type-hint], when non-#f, is the statically-resolved record/entity type of
;; [target] (emitted by the compiler from the checker's field_accesses, GitHub
;; #26).  It OVERRIDES the structural `value-field-access-type` fallback, which
;; returns #f (→ ambiguous) when a row satisfies more than one entity type
;; (entity predicates are superset checks, so a Project row also matches an
;; Organization{id,name}).  With the hint the declared type disambiguates.
(define (tesl-dot/runtime target field-name [type-hint #f])
  (define-values (raw expected-type)
    (cond
      [(named-value? target)
       (values (named-value-value target)
               (value-field-access-type target))]
      [(symbol? target)
       (cond
         [(hash-has-key? (current-evidence-env) target)
          (values (raw-value (hash-ref (current-evidence-env) target))
                  (value-field-access-type target))]
         [(hash-has-key? (current-proof-env) target)
          (values (hash-ref (current-proof-env) target)
                  (value-field-access-type target))]
         [else
          (values target #f)])]
      [else
       (values (raw-value target)
               (value-field-access-type target))]))
  (field-access-ref raw field-name (or type-hint expected-type) 'dot))

(define (instantiate-proof-template datum [name-env (current-name-env)])
  (cond
    [(and (symbol? datum) (hash-has-key? name-env datum))
     (hash-ref name-env datum)]
    [(list? datum)
     (map (lambda (item)
            (instantiate-proof-template item name-env))
          datum)]
    [else datum]))

(define (datum-symbols datum)
  (cond
    [(symbol? datum) (list datum)]
    [(list? datum) (apply append (map datum-symbols datum))]
    [else '()]))

(define (check-ok-primary-name default-name result)
  (define bindings (check-ok-bindings result))
  (or (for*/first ([fact (in-list (check-ok-facts result))]
                   [subject (in-list (remove-duplicates (datum-symbols fact)))]
                   #:when (and (hash-has-key? bindings subject)
                               (equal? (hash-ref bindings subject)
                                       (check-ok-value result))))
        subject)
      default-name))

(define (restrict-bindings-to-fact bindings fact)
  (define referenced (remove-duplicates (datum-symbols fact)))
  (for/hash ([(key value) (in-hash bindings)]
             #:when (member key referenced))
    (values key value)))

(define (evidence->facts+bindings who evidence)
  (cond
    [(check-ok? evidence)
     (values (check-ok-facts evidence)
             (check-ok-bindings evidence))]
    [(named-value? evidence)
     (values (named-value-facts evidence)
             (named-value-bindings evidence))]
    [(and (symbol? evidence)
          (hash-has-key? (current-evidence-env) evidence))
     (define named (hash-ref (current-evidence-env) evidence))
     (values (named-value-facts named)
             (named-value-bindings named))]
    [(and (symbol? evidence)
          (hash-has-key? (current-proof-env) evidence))
     (define raw (hash-ref (current-proof-env) evidence))
     (values '()
             (hash evidence raw))]
    [(detached-proof? evidence)
     (values (list (detached-proof-fact evidence))
             (detached-proof-bindings evidence))]
    [(and (list? evidence) (andmap detached-proof? evidence))
     (values (map detached-proof-fact evidence)
             (for/fold ([acc (hash)]) ([proof (in-list evidence)])
               (merge-bindings acc (detached-proof-bindings proof))))]
    [else
     (raise-user-error who "expected proof-bearing evidence, got ~e" evidence)]))

(define (ensure-named name value [facts '()] [bindings (hash)] #:subject [pre-subject #f])
  (define effective-name
    (cond
      [(named-value? value)
       (if (public-name-symbol? name)
           (named-value-name value)
           name)]
      [pre-subject pre-subject]
      [else
       (normalize-runtime-name name)]))
  (define raw (raw-value value))
  (define base-bindings
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

(define (attach value evidence)
  (define-values (extra-facts extra-bindings)
    (evidence->facts+bindings 'attach evidence))
  ;; Normalize check-ok to named-value so its existing subject and facts are preserved.
  (define val
    (if (check-ok? value)
        (value->packed-witness (check-ok-primary-name (gensym 'value) value) value)
        value))
  (define effective-name
    (cond
      [(named-value? val)
       (named-value-name val)]
      [(and (symbol? val)
            (or (hash-has-key? (current-evidence-env) val)
                (hash-has-key? (current-proof-env) val)))
       val]
      [else
       (gensym 'value)]))
  (ensure-named effective-name
                val
                extra-facts
                extra-bindings))

(define (value->packed-witness public-name value)
  (cond
    [(named-value? value)
     (ensure-named public-name value)]
    [(check-ok? value)
     (ensure-named (check-ok-primary-name public-name value)
                   (check-ok-value value)
                   (check-ok-facts value)
                   (check-ok-bindings value))]
    [(runtime-binding? value)
     (ensure-named (runtime-binding-name value)
                   (runtime-binding-raw value)
                   '()
                   (runtime-binding-bindings value))]
    [(and (symbol? value)
          (hash-has-key? (current-evidence-env) value))
     (ensure-named public-name (hash-ref (current-evidence-env) value))]
    [(and (symbol? value)
          (hash-has-key? (current-proof-env) value))
     (define raw (hash-ref (current-proof-env) value))
     (ensure-named value raw '() (hash value raw))]
    [else
     (ensure-named public-name value)]))

(define (pack/runtime public-names witness-values body)
  (unless (= (length public-names) (length witness-values))
    (raise-user-error 'pack "mismatched existential binder names and witness values"))
  (define duplicates
    (remove-duplicates
     (for/list ([name (in-list public-names)]
                #:when (> (length (filter (lambda (other) (eq? other name)) public-names)) 1))
       name)
     eq?))
  (when (pair? duplicates)
    (raise-user-error 'pack "duplicate existential binder name~a: ~a"
                      (if (= (length duplicates) 1) "" "s")
                      duplicates))
  (packed-exists
   (for/list ([public-name (in-list public-names)]
              [value (in-list witness-values)])
     (packed-witness public-name
                     (value->packed-witness public-name value)))
   body))

(define (ensure-packed-exists who value)
  (if (packed-exists? value)
      value
      (raise-user-error who "expected a packed existential value, got ~a" value)))

(define (packed-witness-table who packed)
  (for/fold ([acc (hash)]) ([witness (in-list (packed-exists-witnesses packed))])
    (define public-name (packed-witness-public-name witness))
    (when (hash-has-key? acc public-name)
      (raise-user-error who "packed existential contains duplicate witness name ~a" public-name))
    (hash-set acc public-name (packed-witness-value witness))))

(define (resolve-packed-exists who packed-value public-names)
  (define packed (ensure-packed-exists who packed-value))
  (define witness-table (packed-witness-table who packed))
  (define actual-names (hash-keys witness-table))
  (define missing-names
    (filter (lambda (name)
              (not (hash-has-key? witness-table name)))
            public-names))
  (define extra-names
    (filter (lambda (name)
              (not (member name public-names)))
            actual-names))
  (when (pair? missing-names)
    (raise-user-error who
                      "packed existential is missing witness name~a ~a"
                      (if (= (length missing-names) 1) "" "s")
                      missing-names))
  (when (pair? extra-names)
    (raise-user-error who
                      "packed existential contains unexpected witness name~a ~a"
                      (if (= (length extra-names) 1) "" "s")
                      extra-names))
  (define ordered-witnesses
    (for/list ([name (in-list public-names)])
      (define witness-value (hash-ref witness-table name))
      (unless (named-value? witness-value)
        (raise-user-error who "packed witness ~a is not a named value" name))
      witness-value))
  (values packed ordered-witnesses (packed-exists-body packed)))

(define (scan-opaque-escape? value)
  (cond
    [(procedure? value) #t]
    [(null? value) #f]
    [(pair? value)
     (or (scan-opaque-escape? (car value))
         (scan-opaque-escape? (cdr value)))]
    [(vector? value)
     (for/or ([item (in-vector value)])
       (scan-opaque-escape? item))]
    [(box? value)
     (scan-opaque-escape? (unbox value))]
    [(hash? value)
     (for/or ([(key item) (in-hash value)])
       (or (scan-opaque-escape? key)
           (scan-opaque-escape? item)))]
    [(packed-exists? value)
     (or (for/or ([witness (in-list (packed-exists-witnesses value))])
           (scan-opaque-escape? (packed-witness-value witness)))
         (scan-opaque-escape? (packed-exists-body value)))]
    [(packed-witness? value)
     (scan-opaque-escape? (packed-witness-value value))]
    [(named-value? value)
     (or (scan-opaque-escape? (named-value-value value))
         (scan-opaque-escape? (named-value-facts value))
         (scan-opaque-escape? (named-value-bindings value)))]
    [(check-ok? value)
     (or (scan-opaque-escape? (check-ok-value value))
         (scan-opaque-escape? (check-ok-facts value))
         (scan-opaque-escape? (check-ok-bindings value)))]
    [(check-fail? value)
     (or (scan-opaque-escape? (check-fail-message value))
         (scan-opaque-escape? (check-fail-details value)))]
    [(detached-proof? value)
     (or (scan-opaque-escape? (detached-proof-fact value))
         (scan-opaque-escape? (detached-proof-bindings value)))]
    [(runtime-binding? value)
     (or (scan-opaque-escape? (runtime-binding-raw value))
         (scan-opaque-escape? (runtime-binding-bindings value)))]
    [(struct? value)
     (with-handlers ([exn:fail? (lambda (_exn) #t)])
       (for/or ([item (in-list (cdr (vector->list (struct->vector value))))])
         (scan-opaque-escape? item)))]
    [else #f]))

(define (escaped-skolem-names value forbidden-name-map [bound-names '()])
  (define (forbidden-name? symbol current-bound)
    (and (hash-has-key? forbidden-name-map symbol)
         (not (member symbol current-bound))))
  (define (scan current current-bound)
    (cond
      [(symbol? current)
       (if (forbidden-name? current current-bound)
           (list current)
           '())]
      [(null? current) '()]
      [(pair? current)
       (append (scan (car current) current-bound)
               (scan (cdr current) current-bound))]
      [(vector? current)
       (append-map (lambda (item)
                     (scan item current-bound))
                   (vector->list current))]
      [(box? current)
       (scan (unbox current) current-bound)]
      [(hash? current)
       (append-map (lambda (entry)
                     (append (scan (car entry) current-bound)
                             (scan (cdr entry) current-bound)))
                   (hash->list current))]
      [(packed-exists? current)
       (define nested-bound
         (append current-bound
                 (for/list ([witness (in-list (packed-exists-witnesses current))])
                   (named-value-name (packed-witness-value witness)))))
       (append
        (append-map (lambda (witness)
                      (scan (packed-witness-value witness) nested-bound))
                    (packed-exists-witnesses current))
        (scan (packed-exists-body current) nested-bound))]
      [(packed-witness? current)
       (scan (packed-witness-value current) current-bound)]
      [(named-value? current)
       (append
        (if (forbidden-name? (named-value-name current) current-bound)
            (list (named-value-name current))
            '())
        (scan (named-value-value current) current-bound)
        (scan (named-value-facts current) current-bound)
        (scan (named-value-bindings current) current-bound))]
      [(check-ok? current)
       (append (scan (check-ok-value current) current-bound)
               (scan (check-ok-facts current) current-bound)
               (scan (check-ok-bindings current) current-bound))]
      [(check-fail? current)
       (append (scan (check-fail-message current) current-bound)
               (scan (check-fail-details current) current-bound))]
      [(detached-proof? current)
       (append (scan (detached-proof-fact current) current-bound)
               (scan (detached-proof-bindings current) current-bound))]
      [(runtime-binding? current)
       (append
        (if (forbidden-name? (runtime-binding-name current) current-bound)
            (list (runtime-binding-name current))
            '())
        (scan (runtime-binding-raw current) current-bound)
        (scan (runtime-binding-bindings current) current-bound))]
      [(struct? current)
       (with-handlers ([exn:fail? (lambda (_exn) '())])
         (append-map (lambda (item)
                       (scan item current-bound))
                     (cdr (vector->list (struct->vector current)))))]
      [else '()]))
  (remove-duplicates (scan value bound-names) eq?))

(define (ensure-no-skolem-escape who result packed-value)
  (define packed (ensure-packed-exists who packed-value))
  (when (scan-opaque-escape? result)
    (raise-user-error who
                      "cannot return an unpacked existential result through procedures or opaque values"))
  (define hidden->public
    (for/hash ([witness (in-list (packed-exists-witnesses packed))])
      (values (named-value-name (packed-witness-value witness))
              (packed-witness-public-name witness))))
  (define escaped-hidden-names
    (escaped-skolem-names result hidden->public))
  (when (pair? escaped-hidden-names)
    (define escaped-public-names
      (remove-duplicates
       (for/list ([hidden-name (in-list escaped-hidden-names)])
         (hash-ref hidden->public hidden-name hidden-name))))
    (raise-user-error who
                      "Skolem escape: existential witness name~a would escape scope: ~a"
                      (if (= (length escaped-public-names) 1) "" "s")
                      escaped-public-names)))

(define (ensure-detached-proof-list who proofish)
  (cond
    [(detached-proof? proofish) (list proofish)]
    [(and (list? proofish) (andmap detached-proof? proofish)) proofish]
    [else
     (raise-user-error who "expected a detached proof or list of detached proofs")]))

(define (ensure-detached-proof who proof)
  (if (detached-proof? proof)
      proof
      (raise-user-error who "expected a detached proof")))

(define (proof-infix-datum op items)
  (cond
    [(null? items) '()]
    [(null? (cdr items)) (car items)]
    [else
     (let loop ([remaining (cdr items)]
                [acc (list (car items))])
       (if (null? remaining)
           acc
           (loop (cdr remaining)
                 (append acc (list op (car remaining))))))]))

(define (flatten-proof-conjunction-facts facts)
  (remove-duplicates
   (append-map
    (lambda (fact)
      (define items (proof-infix-operands fact '&&))
      (if items
          (flatten-proof-conjunction-facts items)
          (list fact)))
    facts)
   equal?))

(define (make-detached-proof fact bindings)
  (detached-proof fact
                  (restrict-bindings-to-fact bindings fact)))

(define (detach-proof/default-runtime evidence)
  (define-values (facts bindings)
    (evidence->facts+bindings 'detach-proof evidence))
  (cond
    [(null? facts)
     (raise-user-error 'detach-proof "no proof is attached to the given value")]
    [(null? (cdr facts))
     (detached-proof (car facts)
                     (restrict-bindings-to-fact bindings (car facts)))]
    [else
     ;; Multiple proofs accumulated — combine into a conjunction, same as detachAllFact.
     ;; This lets `detachFact` work on values that passed through several check chains
     ;; without requiring the caller to use detach-proof with an explicit selector.
     (define combined-fact (normalize-gdp-expr (proof-infix-datum '&& facts)))
     (make-detached-proof combined-fact bindings)]))

(define (detach-proof/select-runtime evidence expected-fact)
  (define runtime-expected (instantiate-proof-template expected-fact))
  (define-values (facts bindings)
    (evidence->facts+bindings 'detach-proof evidence))
  (if (proof-satisfied? runtime-expected facts (hash))
      (make-detached-proof runtime-expected bindings)
      (raise-user-error 'detach-proof
                        (format "proof ~a is not attached to the given value" runtime-expected))))

(define (detach-all-proof/runtime evidence)
  (define-values (facts bindings)
    (evidence->facts+bindings 'detach-all-proof evidence))
  (cond
    [(null? facts)
     (raise-user-error 'detach-all-proof "no proof is attached to the given value")]
    [else
     (define combined-fact (normalize-gdp-expr (proof-infix-datum '&& facts)))
     (make-detached-proof combined-fact bindings)]))

(define (intro-and/runtime left-proof right-proof)
  (define left (ensure-detached-proof 'intro-and left-proof))
  (define right (ensure-detached-proof 'intro-and right-proof))
  (define combined-fact
    (normalize-gdp-expr
     (proof-infix-datum '&& (list (detached-proof-fact left)
                                  (detached-proof-fact right)))))
  (make-detached-proof combined-fact
                       (merge-bindings (detached-proof-bindings left)
                                       (detached-proof-bindings right))))

(define (conjunction-proof-items who proof)
  (define prepared (ensure-detached-proof who proof))
  (define items (proof-infix-operands (detached-proof-fact prepared) '&&))
  (if (and items (pair? (cdr items)))
      (values prepared items)
      (raise-user-error who "expected a conjunction proof")))

(define (and-left/runtime proof)
  (define-values (prepared items)
    (conjunction-proof-items 'and-left proof))
  (make-detached-proof (car items)
                       (detached-proof-bindings prepared)))

(define (and-right/runtime proof)
  (define-values (prepared items)
    (conjunction-proof-items 'and-right proof))
  (define rest-items (cdr items))
  (define right-fact
    (normalize-gdp-expr (proof-infix-datum '&& rest-items)))
  (make-detached-proof right-fact
                       (detached-proof-bindings prepared)))

(define (attach-proof/runtime value proofish)
  (define proofs (ensure-detached-proof-list 'attach-proof proofish))
  (attach value proofs))

;; Establish a proof on a GDP-tracked lambda parameter.
;; Used in lambda bodies where a proof annotation is declared but the call-site
;; passes a plain value (e.g., from a ForAll-annotated list).  The proof is
;; asserted without re-checking — correctness is guaranteed by the compile-time
;; type system (ForAll proof on the enclosing list).
;; subject: the GDP gensym (e.g. the `n` gensym from define/pow binding)
;; raw-val: the raw Racket value (the *n raw value)
;; proof-fact: a fully-instantiated fact datum, e.g. '(IsPositive n-gensym)
(define (tesl-establish-param-proof subject raw-val proof-fact [all-bindings (hash)])
  ;; named-value-facts holds plain datums, not detached-proof objects.
  ;; [all-bindings] carries the sibling parameters' (public-name → raw) bindings so a
  ;; CROSS-PARAMETER proof (e.g. `HasKey key dict`, consumed at runtime by a proof-total
  ;; stdlib like Dict.get) can resolve its other subjects — mirroring the non-erased
  ;; path's all-arg-bindings.  A single-arg proof (e.g. IsNonZero) is unaffected.
  (named-value subject raw-val
               (list proof-fact)
               (hash-set all-bindings subject raw-val)))

(define (normalize-typecheck-value value)
  (cond
    [(and (symbol? value)
          (hash-has-key? (current-evidence-env) value))
     (normalize-typecheck-value (hash-ref (current-evidence-env) value))]
    [(named-value? value)
     (normalize-typecheck-value (named-value-value value))]
    [(check-ok? value)
     (normalize-typecheck-value (check-ok-value value))]
    [(runtime-binding? value)
     (normalize-typecheck-value (runtime-binding-raw value))]
    [(list? value)
     (map normalize-typecheck-value value)]
    [else value]))

;; proof-infix-operands is shared via private/proof-utils.rkt (the only helper
;; that is byte-identical AND dependency-free across check-runtime.rkt and
;; web.rkt; see proof-utils.rkt for why the other 4 candidates stay duplicated).

;; Structural proof match that allows free interned symbols in `template` to act
;; as wildcards when the corresponding position in `fact` holds an uninterned
;; gensym.  This is needed for worker proofs like (FromQueue (Id == jobId) job)
;; where `jobId` is a phantom witness name — not a function parameter — so it
;; is never substituted into the template, yet the fact's job-id slot holds a
;; freshly generated gensym.  A value without a FromQueue fact at all still
;; fails because the predicate name and arity must match exactly.
(define (proof-fact-matches? template fact [bindings (hash)])
  (cond
    [(equal? template fact) #t]
    [(and (pair? template) (pair? fact))
     (and (proof-fact-matches? (car template) (car fact) bindings)
          (proof-fact-matches? (cdr template) (cdr fact) bindings))]
    ;; Interned symbol in template, uninterned gensym in fact → wildcard
    [(and (symbol? template) (symbol-interned? template)
          (symbol? fact)     (not (symbol-interned? fact)))
     #t]
    ;; Uninterned gensym in template, interned symbol in fact → also wildcard.
    ;; This covers facts created via accept/value with an interned placeholder
    ;; subject (e.g. `(ValidUserId u)` where u was not in the proof env),
    ;; allowing `(ValidUserId uid-gensym)` in the template to match.
    [(and (symbol? template) (not (symbol-interned? template))
          (symbol? fact)     (symbol-interned? fact))
     #t]
    ;; Two uninterned gensyms: match if they map to the same raw value in bindings
    [(and (symbol? template) (not (symbol-interned? template))
          (symbol? fact)     (not (symbol-interned? fact)))
     (let ([t-val (hash-ref bindings template #f)]
           [f-val (hash-ref bindings fact #f)])
       (and t-val f-val (equal? (raw-value t-val) (raw-value f-val))))]
    ;; Literal value in template (integer/string), gensym in fact:
    ;; match if the gensym's binding equals the literal.
    ;; This handles predicates like (Clamped 1 100 n) where 1 and 100
    ;; are literals but lo-gensym/hi-gensym carry those values in bindings.
    [(and (not (symbol? template))
          (symbol? fact) (not (symbol-interned? fact)))
     (let ([f-val (hash-ref bindings fact #f)])
       (and f-val (equal? template (raw-value f-val))))]
    ;; Uninterned gensym in template, literal in fact: same as above but reversed.
    [(and (symbol? template) (not (symbol-interned? template))
          (not (symbol? fact)))
     (let ([t-val (hash-ref bindings template #f)])
       (and t-val (equal? (raw-value t-val) fact)))]
    [else #f]))

(define (proof-satisfied? proof-datum facts name-env [bindings (hash)])
  (define actual-facts (flatten-proof-conjunction-facts facts))
  (define instantiated (instantiate-proof-template proof-datum name-env))
  (cond
    [(eq? instantiated #t) #t]
    [(eq? instantiated #f) #f]
    [(ormap (lambda (f) (proof-fact-matches? instantiated f bindings)) actual-facts) #t]
    [(proof-infix-operands instantiated '&&)
     => (lambda (items)
          (andmap (lambda (item)
                    (proof-satisfied? item actual-facts name-env bindings))
                  items))]
    [else #f]))


;; A2 — Tesl-level failure rendering (reject / type / proof path).
;; The runtime intentionally does not know .tesl positions (those are resolved by
;; the OCaml `tesl-sourcemap render` step from the trace + compile-time map).  We
;; DO know the originating construct (`who`/`subject`/`public-name`) and the
;; expected type/proof, so we lead the message with a stable, classifiable
;; "expected …" headline naming the construct.  The trailing "does not satisfy
;; declared type/proof <X>" fragment is preserved verbatim so the OCaml failure
;; classifier (and any existing matchers) keep working.  Verbose under
;; TESL_VERBOSE.  Read once at load (mirrors tesl/logging.rkt's tesl-verbose?).
(define tesl-verbose?
  (let ([v (getenv "TESL_VERBOSE")]) (and v (not (string=? v "")))))

(define (validate-runtime-argument who subject public-name value expected-type [expected-proof #f] [name-env #f] [extra-bindings (hash)])
  (define evidence
    (if (named-value? value)
        value
        (runtime-evidence public-name value)))
  (unless (runtime-type-satisfied? expected-type (normalize-typecheck-value evidence))
    (raise-user-error who
                      "expected ~a for ~a~a: ~a argument ~a does not satisfy declared type ~a"
                      (type-datum-display expected-type)
                      public-name
                      (if tesl-verbose? (format " (construct ~a)" who) "")
                      subject
                      public-name
                      (type-datum-display expected-type)))
  (when expected-proof
    (define actual-facts (facts-of evidence))
    ;; Inside List.filterCheck / List.allCheck, ForAll is a compile-time-only
    ;; annotation.  Elements are plain Racket values with no runtime proof structs.
    ;; If the call site is in a ForAll-filter context AND the element carries no
    ;; facts, trust the compile-time guarantee and skip the runtime proof check.
    (unless (and (current-in-forall-filter) (null? actual-facts))
      (define effective-name-env
        (hash-set (if name-env name-env (hash))
                  public-name
                  (named-value-name evidence)))
      ;; Merge evidence's own bindings with extra-bindings from other arguments.
      ;; This allows proof-fact-matches? to compare gensyms from different parameters
      ;; by looking up both in the combined bindings hash and comparing their raw values.
      (define bindings (merge-bindings
                         (if (named-value? evidence) (named-value-bindings evidence) (hash))
                         extra-bindings))
      (unless (proof-satisfied? expected-proof actual-facts effective-name-env bindings)
        (raise-user-error who
                          "expected proof ~a for ~a~a: ~a argument ~a does not satisfy declared proof ~a"
                          expected-proof
                          public-name
                          (if tesl-verbose? (format " (construct ~a)" who) "")
                          subject
                          public-name
                          expected-proof))))
  evidence)

;; Compose two check functions left-to-right.
;; (check-and f g) returns a check function that runs f first; if it passes,
;; runs g on the full check-ok result (preserving the gensym subject so both
;; checks share the same GDP identity). The final result merges facts and
;; bindings from both checks. If either fails the failure propagates.
;;
;; Passing the full check-ok to g (instead of the raw value) causes
;; runtime-bind+evidence → value->packed-witness to reuse f's gensym,
;; so IsPositive and IsSmall end up indexed by the same symbol.
;;
;; Intended for use with check-composition and List.filterCheck / List.allCheck:
;;   (List.filterCheck (check-and checkIsPositive checkIsLessThan100) xs)
(define (check-and f g)
  (lambda (x)
    (define r1 (f x))
    (if (check-ok? r1)
        (let ([r2 (g r1)])
          (if (check-ok? r2)
              (let* ([all-facts (append (check-ok-facts r1) (check-ok-facts r2))]
                     ;; Combine all facts into a single && conjunction so that
                     ;; the result has exactly one attached proof.  This lets
                     ;; detachFact work without specifying a selector, while
                     ;; keeping the Racket-level detach-proof selector contract
                     ;; intact for values with genuinely separate proofs.
                     [combined (list (normalize-gdp-expr (proof-infix-datum '&& all-facts)))])
                (check-ok (check-ok-value r2)
                          combined
                          (merge-bindings (check-ok-bindings r1) (check-ok-bindings r2))))
              r2))
        r1)))

(define (accept/default proof-datum)
  (define new-fact (instantiate-proof-template proof-datum))
  (define carried (current-check-input-facts))
  ;; Append new fact LAST so that oldest proofs come first in the conjunction.
  ;; This makes `detach-all-proof` produce (A && B) for checkB(checkA(x)),
  ;; so andLeft returns A (the first/oldest proof) as users expect.
  (check-ok (current-check-default-value)
            (append carried (list new-fact))
            (current-proof-env)))

(define (accept/value proof-datum value)
  (define new-fact (instantiate-proof-template proof-datum))
  (define carried (current-check-input-facts))
  (check-ok value
            (append carried (list new-fact))
            (current-proof-env)))

(define-syntax (accept/trusted stx)
  (syntax-parse stx
    [(_ proof)
     (validate-proof-template-stx! 'accept stx #'proof)
     (define proof-datum (normalize-gdp-expr (syntax->datum #'proof)))
     #`(accept/default '#,proof-datum)]
    [(_ proof #:value value-expr)
     (validate-proof-template-stx! 'accept stx #'proof)
     (define proof-datum (normalize-gdp-expr (syntax->datum #'proof)))
     #`(accept/value '#,proof-datum
                     #,(transform-body-expr #'value-expr (body-bound-names stx)))]))

(define-syntax-parameter accept
  (lambda (stx)
    (raise-syntax-error 'accept
                        "only allowed inside define-checker and define-auther; handlers, define/pow, and ordinary code must use trusted proof-producing helpers instead"
                        stx)))

;; NOTE on begin-for-syntax duplication (issue 3.3):
;; This begin-for-syntax block shares structural helpers with web.rkt
;; (wrap-runtime-named-binding, transform-body-expr, transform-body-sequence,
;; and several binding/name utilities).  Factoring into a shared
;; dsl/private/body-transform.rkt is feasible in principle — the generated
;; code references only phase-0 runtime bindings (current-name-env,
;; runtime-bind+evidence, etc.) which stay in the requiring module, so the
;; syntax-generating helpers themselves have no phase-0 dependencies that
;; would break after relocation.
;;
;; However, the two copies are NOT byte-for-byte identical:
;;  • transform-body-expr here expands `(accept ...)` and `(detach-proof ...)`
;;    sub-forms recursively (checker/auther bodies need to see accept with
;;    #:value and detach-proof with an evidence argument transformed);
;;    web.rkt's version leaves those forms opaque (handlers never contain
;;    bare `accept`).
;;  • validate-return-stx! here has no allow-qform? parameter; web.rkt's
;;    version adds it for define-handler which permits `(? ...)` return syntax.
;;  • wrap-runtime-evidence-binding differs between the two files.
;;  • This file has validate-proof-template-stx! and build-check-like-expansion;
;;    web.rkt has build-executable-expansion and the define-api/define-capture
;;    infrastructure.
;;
;; Extracting the common subset would yield a module that is smaller than
;; either file's begin-for-syntax block, making both files harder to read
;; standalone.  Given the semantic divergence, the duplication is intentional
;; and should be maintained in sync rather than mechanically merged.
(begin-for-syntax
  ;; ── Zero-cost proofs ───────────────────────────────────────────────────────
  ;; The param-binding macros below generate the ERASED expansion — no
  ;; runtime-bind+evidence, no validate-runtime-argument, no env parameterize.
  ;; For a SOUND static checker the runtime proof structs are pure redundancy:
  ;; the proof carried by a binding is type-level information known at compile
  ;; time (exactly what --type-at / hover report).  The static checker is the
  ;; sole guarantor of the declared proofs.
  ;;
  ;; The debugger needs no runtime structs: its Variables panel shows the RAW
  ;; value (the *x binding), and proof/type display is sourced from compile-time
  ;; type information.  Breakpoint checkpoints (thsl-src!) are emitted separately
  ;; by the OCaml emitter and are unaffected by erasure.

  (define-syntax-class typed-binding
    (pattern [name:id (~datum :) type:expr (~datum :::) proof:expr])
    (pattern [name:id (~datum :) type:expr]))

  (define (star-id id)
    (format-id id "*~a" (syntax-e id)))

  (define (literal-id? stx sym)
    (and (identifier? stx)
         (eq? (syntax-e stx) sym)))

  (define (binding-parts binding-stx)
    (define parts (syntax->list binding-stx))
    (unless (and parts (or (= (length parts) 3) (= (length parts) 5)))
      (raise-syntax-error 'define-checker
                          "expected [name : Type] or [name : Type ::: Proof]"
                          binding-stx))
    (define name-id (first parts))
    (unless (identifier? name-id)
      (raise-syntax-error 'define-checker "binding name must be an identifier" binding-stx name-id))
    (unless (literal-id? (second parts) ':)
      (raise-syntax-error 'define-checker "expected `:` in typed binding" binding-stx (second parts)))
    (define type-stx (third parts))
    (define proof-stx
      (cond
        [(= (length parts) 3) #f]
        [(literal-id? (fourth parts) ':::) (fifth parts)]
        [else
         (raise-syntax-error 'define-checker
                             "expected `:::` before the proof expression"
                             binding-stx
                             (fourth parts))]))
    (values name-id type-stx proof-stx))

  (define (binding-name-id binding-stx)
    (define-values (name-id _type-stx _proof-stx) (binding-parts binding-stx))
    name-id)

  (define (binding-name-symbol binding-stx)
    (syntax-e (binding-name-id binding-stx)))

  (define (duplicate-names names)
    (reverse
     (for/fold ([seen '()] [duplicates '()] #:result duplicates)
               ([name (in-list names)])
       (cond
         [(member name seen)
          (values seen (if (member name duplicates) duplicates (cons name duplicates)))]
         [else
          (values (cons name seen) duplicates)]))))

  (define (report-duplicate-binding-names! who binding-stxs)
    (define duplicates (duplicate-names (map binding-name-symbol binding-stxs)))
    (when (pair? duplicates)
      (raise-syntax-error who
                          (format "duplicate binding name~a: ~a"
                                  (if (= (length duplicates) 1) "" "s")
                                  duplicates)
                          (car binding-stxs))))

  (define (binding-type-datum binding-stx)
    (define-values (_name-id type-stx _proof-stx) (binding-parts binding-stx))
    (normalize-type-stx type-stx))

  (define (report-unbound-names! who context-stx label missing)
    (when (pair? missing)
      (raise-syntax-error who
                          (format "unbound GDP name~a in ~a: ~a"
                                  (if (= (length missing) 1) "" "s")
                                  label
                                  missing)
                          context-stx)))

  (define (validate-binding-stx! who binding-stx outer-bound-names)
    (report-unbound-names! who
                           binding-stx
                           "typed binding"
                           (binding-unbound-names (syntax->datum binding-stx)
                                                  outer-bound-names))
    (binding-name-symbol binding-stx))

  (define (validate-binding-sequence! who binding-stxs [initial-bound-names '()] [all-bound-names #f])
    (report-duplicate-binding-names! who binding-stxs)
    (define visible-names
      (and all-bound-names
           (append initial-bound-names all-bound-names)))
    (for/fold ([bound-names initial-bound-names])
              ([binding-stx (in-list binding-stxs)])
      (define available-names (or visible-names bound-names))
      (append bound-names
              (list (validate-binding-stx! who binding-stx available-names)))))

  (define (validate-return-stx! who return-stx bound-names)
    (report-unbound-names! who
                           return-stx
                           "return annotation"
                           (return-unbound-names (syntax->datum return-stx)
                                                 bound-names)))

  (define body-bound-names-key 'tesl-body-bound-names)

  (define (annotate-body-scope stx bound-names)
    (if bound-names
        (syntax-property stx body-bound-names-key bound-names)
        stx))

  (define (body-bound-names stx)
    (syntax-property stx body-bound-names-key))

  (define (extend-bound-names bound-names new-names)
    (if bound-names
        (append bound-names new-names)
        new-names))

  (define (dotted-identifier-parts id-stx)
    (and (identifier? id-stx)
         (let ([value (syntax-e id-stx)])
           (and (symbol? value)
                (let ([parts (string-split (symbol->string value) ".")])
                  (and (> (length parts) 1)
                       (andmap (lambda (part)
                                 (not (string=? part "")))
                               parts)
                       (map string->symbol parts)))))))

  (define (expand-dotted-identifier id-stx bound-names)
    (define parts (dotted-identifier-parts id-stx))
    (define base-id (datum->syntax id-stx (car parts) id-stx))
    (for/fold ([expanded (transform-body-expr base-id bound-names)])
              ([part (in-list (cdr parts))])
      #`(tesl-dot/runtime #,expanded '#,part)))

  (define (validate-proof-template-stx! who use-stx proof-stx [bound-names #f])
    (define effective-bound-names
      (or bound-names (body-bound-names use-stx)))
    (when effective-bound-names
      (report-unbound-names! who
                             use-stx
                             "proof template"
                             (proof-unbound-names (normalize-gdp-expr (syntax->datum proof-stx))
                                                  effective-bound-names))))

  ;; wrap-runtime-named-binding binds a GDP let/lambda local: *x (raw value) and
  ;; x (the proof-carrying value, or raw if none).  #:erasable? (default #t)
  ;; controls whether the binding drops the wrap/parameterize machinery.
  ;; pack/unpack witness binders pass #:erasable? #f because their values ARE the
  ;; proof carrier (a packed witness) that later code structurally depends on —
  ;; see callers at the pack/unpack sites.
  (define (wrap-runtime-named-binding name-id expr-stx body-stx #:erasable? [erasable? #t])
    (define star-name-id (star-id name-id))
    (define value-id (format-id name-id "~a-runtime-value" (syntax-e name-id)))
    (define evidence-id (format-id name-id "~a-runtime-evidence" (syntax-e name-id)))
    (define binding-id (format-id name-id "~a-runtime-binding" (syntax-e name-id)))
    (define type-id (format-id name-id "~a-runtime-type" (syntax-e name-id)))
    (if erasable?
        ;; ── ERASED: no runtime-bind+evidence / parameterize ───────────────────
        ;; Preserve the check-fail? short-circuit (control flow, not a proof net).
        ;; Bind *x to the raw value; bind x to the value itself when it is a
        ;; proof-carrying structure (check-ok / named-value / detached-proof /
        ;; packed-* / procedure / boolean — exactly the net-on predicate set) so
        ;; detach/attach/forget on x still resolve structurally, and to the raw
        ;; value otherwise (the proof-free common case → zero allocation).
        #`(let ([#,value-id #,expr-stx])
            (if (check-fail? #,value-id)
                #,value-id
                (let ([#,star-name-id (raw-value #,value-id)]
                      [#,name-id (if (or (named-value? #,value-id)
                                         (check-result? #,value-id)
                                         (runtime-binding? #,value-id)
                                         (detached-proof? #,value-id)
                                         (packed-witness? #,value-id)
                                         (packed-exists? #,value-id)
                                         (procedure? #,value-id)
                                         (boolean? #,value-id))
                                     #,value-id
                                     (raw-value #,value-id))])
                  #,body-stx)))
        ;; ── DEFAULT: runtime safety net on ────────────────────────────────────
        #`(let* ([#,value-id #,expr-stx]
                 [#,type-id (value-field-access-type #,value-id)])
            (if (check-fail? #,value-id)
                #,value-id
                (let-values ([(#,evidence-id #,binding-id)
                              (runtime-bind+evidence '#,(syntax-e name-id) #,value-id)])
                  (parameterize ([current-name-env
                                  (extend-name-env (current-name-env)
                                                   '(#,(syntax-e name-id))
                                                   (list #,binding-id))]
                                 [current-proof-env
                                  (extend-proof-env (current-proof-env)
                                                    (list #,binding-id))]
                                 [current-evidence-env
                                  (extend-evidence-env (current-evidence-env)
                                                       (list #,evidence-id))]
                                 [current-type-env
                                  (extend-type-env (current-type-env)
                                                   (list #,binding-id)
                                                   (list #,type-id))])
                    (let ([#,star-name-id (runtime-binding-raw #,binding-id)]
                          [#,name-id (if (or (named-value? #,value-id)
                                             (check-result? #,value-id)
                                             (runtime-binding? #,value-id)
                                             (detached-proof? #,value-id)
                                             (packed-witness? #,value-id)
                                             (packed-exists? #,value-id)
                                             (procedure? #,value-id)
                                             (boolean? #,value-id))
                                         #,value-id
                                         (runtime-binding-name #,binding-id))])
                      #,body-stx)))))))

  (define (wrap-runtime-evidence-binding name-id expr-stx body-stx)
    (define star-name-id (star-id name-id))
    (define value-id (format-id name-id "~a-runtime-value" (syntax-e name-id)))
    (define evidence-id (format-id name-id "~a-runtime-evidence" (syntax-e name-id)))
    (define binding-id (format-id name-id "~a-runtime-binding" (syntax-e name-id)))
    (define type-id (format-id name-id "~a-runtime-type" (syntax-e name-id)))
    #`(let* ([#,value-id #,expr-stx]
             [#,type-id (value-field-access-type #,value-id)])
        (let-values ([(#,evidence-id #,binding-id)
                      (runtime-bind+evidence '#,(syntax-e name-id) #,value-id)])
          (parameterize ([current-name-env
                          (extend-name-env (current-name-env)
                                           '(#,(syntax-e name-id))
                                           (list #,binding-id))]
                         [current-proof-env
                          (extend-proof-env (current-proof-env)
                                            (list #,binding-id))]
                         [current-evidence-env
                          (extend-evidence-env (current-evidence-env)
                                               (list #,evidence-id))]
                         [current-type-env
                          (extend-type-env (current-type-env)
                                           (list #,binding-id)
                                           (list #,type-id))])
            (let ([#,name-id #,value-id]
                  [#,star-name-id (raw-value #,value-id)])
              #,body-stx)))))

  (define (wrap-runtime-named-bindings name-ids expr-stxs body-stx)
    (for/fold ([expanded body-stx])
              ([name-id (in-list (reverse name-ids))]
               [expr-stx (in-list (reverse expr-stxs))])
      (wrap-runtime-named-binding name-id expr-stx expanded)))

  (define (transform-body-expr expr-stx [bound-names #f])
    (define (annotate stx)
      (annotate-body-scope stx bound-names))
    (annotate
     (syntax-parse expr-stx
       #:datum-literals (begin begin0 if lambda let let* let-values quote quasiquote quote-syntax
                               accept attach-proof detach-proof trusted-proof
                               pack unpack let-exists let/check if/check)
       [id:id
        #:when (dotted-identifier-parts #'id)
        (expand-dotted-identifier #'id bound-names)]
       [(quote _datum) expr-stx]
       [(quasiquote _datum) expr-stx]
       [(quote-syntax _datum) expr-stx]
       [(begin form:expr ...+)
        (transform-body-sequence (syntax->list #'(form ...)) bound-names)]
       [(begin0 first-form:expr rest-form:expr ...+)
        #`(begin0 #,(transform-body-expr #'first-form bound-names)
                  #,@(for/list ([item (in-list (syntax->list #'(rest-form ...)))])
                       (transform-body-expr item bound-names)))]
       [(if test-expr:expr then-expr:expr else-expr:expr)
        #`(if #,(transform-body-expr #'test-expr bound-names)
              #,(transform-body-expr #'then-expr bound-names)
              #,(transform-body-expr #'else-expr bound-names))]
       [(accept proof)
        expr-stx]
       [(accept proof #:value value-expr:expr)
        #`(accept proof #:value #,(transform-body-expr #'value-expr bound-names))]
       [(trusted-proof proof)
        expr-stx]
       [(detach-proof evidence:expr)
        #`(detach-proof #,(transform-body-expr #'evidence bound-names))]
       [(detach-proof evidence:expr proof)
        #`(detach-proof #,(transform-body-expr #'evidence bound-names) proof)]
       [(attach-proof value:expr proofish:expr)
        #`(attach-proof #,(transform-body-expr #'value bound-names)
                        #,(transform-body-expr #'proofish bound-names))]
       [(pack _ ...+)
        expr-stx]
       [(unpack _ ...+)
        expr-stx]
       [(let-exists _ ...+)
        expr-stx]
       [(let/check _ ...+)
        expr-stx]
       [(if/check _ ...+)
        expr-stx]
       [(lambda (arg:id ...) body:expr ...+)
        (define arg-names (map syntax-e (syntax->list #'(arg ...))))
        #`(lambda (arg ...)
            #,(wrap-runtime-named-bindings
               (syntax->list #'(arg ...))
               (syntax->list #'(arg ...))
               (transform-body-sequence (syntax->list #'(body ...))
                                        (extend-bound-names bound-names arg-names))))]
       [(lambda rest:id body:expr ...+)
        #`(lambda rest
            #,(wrap-runtime-named-binding
               #'rest
               #'rest
               (transform-body-sequence (syntax->list #'(body ...))
                                        (extend-bound-names bound-names (list (syntax-e #'rest))))))]
       [(lambda (arg:id ... . rest:id) body:expr ...+)
        (define arg-ids (append (syntax->list #'(arg ...)) (list #'rest)))
        (define arg-names (map syntax-e arg-ids))
        #`(lambda (arg ... . rest)
            #,(wrap-runtime-named-bindings
               arg-ids
               arg-ids
               (transform-body-sequence (syntax->list #'(body ...))
                                        (extend-bound-names bound-names arg-names))))]
       [(let ([name:id rhs:expr] ...) body:expr ...+)
        (define name-ids (syntax->list #'(name ...)))
        (define name-symbols (map syntax-e name-ids))
        (define temp-ids
          (for/list ([name-id (in-list name-ids)])
            (datum->syntax name-id (gensym (syntax-e name-id)))))
        (define transformed-rhss
          (for/list ([rhs-stx (in-list (syntax->list #'(rhs ...)))])
            (transform-body-expr rhs-stx bound-names)))
        (define wrapped-body
          (wrap-runtime-named-bindings
           name-ids
           temp-ids
           (transform-body-sequence (syntax->list #'(body ...))
                                    (extend-bound-names bound-names name-symbols))))
        (with-syntax ([(temp-id ...) temp-ids]
                      [(rhs-expr ...) transformed-rhss]
                      [wrapped-body-expr wrapped-body])
          #'(let ([temp-id rhs-expr] ...)
              wrapped-body-expr))]
       [(let* () body:expr ...+)
        (transform-body-sequence (syntax->list #'(body ...)) bound-names)]
       [(let* ([name:id rhs:expr] more-binding ...) body:expr ...+)
        (define temp-id (datum->syntax #'name (gensym (syntax-e #'name))))
        (define transformed-rhs (transform-body-expr #'rhs bound-names))
        (define transformed-rest
          (transform-body-expr #'(let* (more-binding ...) body ...)
                               (extend-bound-names bound-names (list (syntax-e #'name)))))
        (with-syntax ([temp-id temp-id]
                      [rhs-expr transformed-rhs]
                      [wrapped-body-expr
                       (wrap-runtime-named-binding #'name #'temp-id transformed-rest)])
          #'(let ([temp-id rhs-expr])
              wrapped-body-expr))]
       [(let-values ([(name:id ...+) rhs:expr] ...) body:expr ...+)
        (define name-groups
          (for/list ([group-stx (in-list (syntax->list #'((name ...) ...)))])
            (syntax->list group-stx)))
        (define flat-name-ids (append* name-groups))
        (define flat-name-symbols (map syntax-e flat-name-ids))
        (define temp-groups
          (for/list ([group (in-list name-groups)])
            (for/list ([name-id (in-list group)])
              (datum->syntax name-id (gensym (syntax-e name-id))))))
        (define value-clauses
          (for/list ([temp-group (in-list temp-groups)]
                     [rhs-stx (in-list (syntax->list #'(rhs ...)))])
            #`[(#,@temp-group) #,(transform-body-expr rhs-stx bound-names)]))
        (define wrapped-body
          (wrap-runtime-named-bindings
           flat-name-ids
           (append* temp-groups)
           (transform-body-sequence (syntax->list #'(body ...))
                                    (extend-bound-names bound-names flat-name-symbols))))
        (with-syntax ([(value-clause ...) value-clauses]
                      [wrapped-body-expr wrapped-body])
          #'(let-values (value-clause ...)
              wrapped-body-expr))]
       [_
        (define parts (syntax->list expr-stx))
        (if parts
            #`(#,@(for/list ([part (in-list parts)])
                    (transform-body-expr part bound-names)))
            expr-stx)])))

  (define (transform-body-sequence body-stxs [bound-names #f])
    (cond
      [(null? body-stxs) (annotate-body-scope #'(void) bound-names)]
      [else
       (define first-form (car body-stxs))
       (define rest-forms (cdr body-stxs))
       (syntax-parse first-form
         #:datum-literals (define)
         [(define local-name:id local-expr:expr)
          (wrap-runtime-named-binding #'local-name
                                      (transform-body-expr #'local-expr bound-names)
                                      (transform-body-sequence rest-forms
                                                               (extend-bound-names bound-names
                                                                   (list (syntax-e #'local-name)))))]
         [_
          (define transformed-first (transform-body-expr first-form bound-names))
          (if (null? rest-forms)
              transformed-first
              #`(begin #,transformed-first #,(transform-body-sequence rest-forms bound-names)))])]))

  (define (binding->arg-spec-expr binding-stx)
    (define-values (name-id type-stx proof-stx) (binding-parts binding-stx))
    (define type-datum (normalize-gdp-expr (syntax->datum type-stx)))
    (define proof-datum (and proof-stx (normalize-gdp-expr (syntax->datum proof-stx))))
    #`(arg-spec '#,(syntax-e name-id)
                '#,type-datum
                '#,proof-datum
                '#,(syntax->datum binding-stx)))

  (define (build-check-like-expansion kind whole-stx name-id binding-stxs cap-stxs returns-stx body-stxs)
    (define who
      (case kind
        [(checker) 'define-checker]
        [(auther) 'define-auther]
        [else 'dsl]))
    (define arg-name-ids (map binding-name-id binding-stxs))
    (define arg-name-symbols (map binding-name-symbol binding-stxs))
    (define final-bound-names (validate-binding-sequence! who binding-stxs '() arg-name-symbols))
    (validate-return-stx! who returns-stx final-bound-names)
    (define star-ids (map star-id arg-name-ids))
    (define arg-spec-exprs (map binding->arg-spec-expr binding-stxs))
    (define signature-id (format-id name-id "~a-signature" (syntax-e name-id)))
    (define kind-id (datum->syntax whole-stx kind))
    (define returns-datum (normalize-type-return-stx returns-stx))
    (define returns-expr #`'#,returns-datum)
    (define raw-expr #`'#,(syntax->datum whole-stx))
    (define transformed-body (transform-body-sequence body-stxs final-bound-names))
    (define trusted-body
      #`(syntax-parameterize ([accept (make-rename-transformer #'accept/trusted)])
          #,transformed-body))
    ;; The raw value of the single argument, read directly off the incoming
    ;; parameter (no runtime-binding allocated) — `accept`'s implicit value.
    (define default-expr-erased (if (= (length arg-name-ids) 1)
                                    #`(raw-value #,(car arg-name-ids))
                                    #'#f))
    (define input-facts-expr (if (= (length arg-name-ids) 1)
                               #`(facts-of #,(car arg-name-ids))
                               #'(list)))
    ;; Erased binding clauses: bind *arg and arg to the raw incoming value (no
    ;; allocation).  A checker/auther body reads its inputs through *arg and
    ;; produces proofs via `accept` (the proof FACTORY, kept below); it never
    ;; decomposes a proof off its own parameter, so the raw value suffices.
    (define erased-arg-clauses
      (append*
       (for/list ([arg-id   (in-list arg-name-ids)]
                  [star-arg (in-list star-ids)])
         (list #`[#,star-arg (raw-value #,arg-id)]
               #`[#,arg-id #,star-arg]))))
    (with-syntax ([(arg-id ...) arg-name-ids]
                  [(arg-spec-expr ...) arg-spec-exprs]
                  [(erased-arg-clause ...) erased-arg-clauses]
                  [signature-id signature-id]
                  [name name-id]
                  [(cap-id ...) cap-stxs]
                  [kind-id kind-id]
                  [returns-expr returns-expr]
                  [raw-expr raw-expr]
                  [default-expr-erased default-expr-erased]
                  [input-facts-expr input-facts-expr]
                  [body-expr trusted-body])
      #`(begin
          (define signature-id
            (signature-spec 'kind-id
                            'name
                            (list arg-spec-expr ...)
                            '(cap-id ...)
                            returns-expr
                            raw-expr))
          ;; ── ERASED expansion (zero-cost: the static checker is the sole
          ;; guarantor of the declared proofs) ───────────────────────────────
          ;; No runtime-bind+evidence, no validate-runtime-argument, no
          ;; env-extension parameterizes.  KEEP the check proof factory: the
          ;; accept→accept/trusted rename (in body-expr) plus the two check
          ;; parameters accept/reject read (current-check-default-value for
          ;; `accept`'s implicit value, current-check-input-facts for carrying
          ;; chained input proofs).  input-facts-expr reads the INCOMING argument
          ;; before it is rebound to raw, so check chaining (checkB (checkA x))
          ;; still accumulates facts.
          (define (name arg-id ...)
            (call-with-declared-capabilities
             (list cap-id ...)
             (lambda ()
               (parameterize ([current-check-default-value default-expr-erased]
                              [current-check-input-facts input-facts-expr])
                 (let* (erased-arg-clause ...)
                   body-expr))))))))) ; close (define name), (begin), (with-syntax …), (build-check-like-expansion), (begin-for-syntax …)


(define-syntax (reject stx)
  (syntax-parse stx
    [(_ message:expr)
     #'(check-fail message 400 '())]
    [(_ message:expr #:http-code code:expr)
     #'(check-fail message code '())]
    [(_ message:expr #:details details:expr)
     #'(check-fail message 400 details)]
    [(_ message:expr #:http-code code:expr #:details details:expr)
     #'(check-fail message code details)]))

(define-syntax (detach-proof stx)
  (syntax-parse stx
    [(_ evidence:expr)
     #`(detach-proof/default-runtime #,(transform-body-expr #'evidence (body-bound-names stx)))]
    [(_ evidence:expr proof)
     (validate-proof-template-stx! 'detach-proof stx #'proof)
     (define proof-datum (normalize-gdp-expr (syntax->datum #'proof)))
     #`(detach-proof/select-runtime #,(transform-body-expr #'evidence (body-bound-names stx))
                                    '#,proof-datum)]))

(define-syntax (detach-all-proof stx)
  (syntax-parse stx
    [(_ evidence:expr)
     #`(detach-all-proof/runtime #,(transform-body-expr #'evidence (body-bound-names stx)))]))

(define-syntax (intro-and stx)
  (syntax-parse stx
    [(_ left-proof:expr right-proof:expr)
     #`(intro-and/runtime #,(transform-body-expr #'left-proof (body-bound-names stx))
                          #,(transform-body-expr #'right-proof (body-bound-names stx)))]))

(define-syntax (and-left stx)
  (syntax-parse stx
    [(_ proof:expr)
     #`(and-left/runtime #,(transform-body-expr #'proof (body-bound-names stx)))]))

(define-syntax (and-right stx)
  (syntax-parse stx
    [(_ proof:expr)
     #`(and-right/runtime #,(transform-body-expr #'proof (body-bound-names stx)))]))

(define-syntax (attach-proof stx)
  (syntax-parse stx
    [(_ value:expr proofish:expr)
     #`(attach-proof/runtime #,(transform-body-expr #'value (body-bound-names stx))
                             #,(transform-body-expr #'proofish (body-bound-names stx)))]))

(begin-for-syntax
  (define (pack-binding-parts binding-stx)
    (syntax-parse binding-stx
      [[name:id witness:expr]
       (values #'name #'witness #t)]
      [[name:id]
       (values #'name #'name #f)]
      [_
       (raise-syntax-error 'pack
                           "expected existential witness bindings of the form [name] or [name witness-expr]"
                           binding-stx)]))

  (define (unpack-pattern-parts who pattern-stx)
    (syntax-parse pattern-stx
      [([witness:id ...+] body-name:id)
       (values (syntax->list #'(witness ...)) #'body-name)]
      [_
       (raise-syntax-error who
                           "expected an existential unpack pattern of the form ([witness ...] body-name)"
                           pattern-stx)]))

  (define (build-unpack-expansion who packed-expr pattern-stx body-stxs [outer-bound-names '()])
    (define-values (witness-ids body-name-id)
      (unpack-pattern-parts who pattern-stx))
    (define duplicate-id (check-duplicates witness-ids free-identifier=?))
    (when duplicate-id
      (raise-syntax-error who
                          (format "duplicate existential binder ~a" (syntax-e duplicate-id))
                          pattern-stx
                          duplicate-id))
    (define transformed-packed-expr
      (transform-body-expr packed-expr outer-bound-names))
    (define transformed-body
      (transform-body-sequence body-stxs
                               (append outer-bound-names
                                       (map syntax-e witness-ids)
                                       (list (syntax-e body-name-id)))))
    (define packed-id (datum->syntax pattern-stx (gensym 'packed-exists)))
    (define witness-values-id (datum->syntax pattern-stx (gensym 'packed-witness-values)))
    (define body-value-id (datum->syntax pattern-stx (gensym 'packed-body-value)))
    (define result-id (datum->syntax pattern-stx (gensym 'unpack-result)))
    (define witness-value-ids
      (for/list ([witness-id (in-list witness-ids)])
        (format-id witness-id "~a-packed-value" (syntax-e witness-id))))
    (define wrapped-body
      (wrap-runtime-evidence-binding body-name-id body-value-id transformed-body))
    (define wrapped-with-witnesses
      (for/fold ([expanded wrapped-body])
                ([witness-id (in-list (reverse witness-ids))]
                 [witness-value-id (in-list (reverse witness-value-ids))])
        ;; #:erasable? #f — existential witness binders carry the hidden packed
        ;; witness that ensure-no-skolem-escape and the body structurally depend
        ;; on; never erase their wrapping (carve-out).
        (wrap-runtime-named-binding witness-id witness-value-id expanded #:erasable? #f)))
    (define witness-binding-exprs
      (for/list ([witness-value-id (in-list witness-value-ids)]
                 [index (in-naturals)])
        #`[#,witness-value-id (list-ref #,witness-values-id #,index)]))
    (with-syntax ([(public-name ...)
                   (for/list ([witness-id (in-list witness-ids)])
                     #`'#,(syntax-e witness-id))]
                  [packed-id packed-id]
                  [witness-values-id witness-values-id]
                  [body-value-id body-value-id]
                  [result-id result-id]
                  [(witness-binding ...) witness-binding-exprs]
                  [wrapped-body-expr wrapped-with-witnesses])
      #`(let-values ([(packed-id witness-values-id body-value-id)
                      (resolve-packed-exists '#,who #,transformed-packed-expr (list public-name ...))])
          (let (witness-binding ...)
            (let ([result-id wrapped-body-expr])
              (ensure-no-skolem-escape '#,who result-id packed-id)
              result-id)))))

  (define-syntax-class check-binding
    (pattern [name:id expr:expr])))

(define-syntax (pack stx)
  (syntax-parse stx
    [(_ (binding ...+) body:expr ...+)
     (define binding-stxs (syntax->list #'(binding ...)))
     (define binder-ids
       (for/list ([binding-stx (in-list binding-stxs)])
         (define-values (binder-id _witness-expr _introduce?)
           (pack-binding-parts binding-stx))
         binder-id))
     (define duplicate-id (check-duplicates binder-ids free-identifier=?))
     (when duplicate-id
       (raise-syntax-error 'pack
                           (format "duplicate existential binder ~a" (syntax-e duplicate-id))
                           stx
                           duplicate-id))
     (define outer-bound-names (or (body-bound-names stx) '()))
     (define transformed-body
       (transform-body-sequence (syntax->list #'(body ...))
                                (append outer-bound-names (map syntax-e binder-ids))))
     (define transformed-bindings
       (let loop ([remaining binding-stxs]
                  [current-bound outer-bound-names]
                  [acc '()])
         (cond
           [(null? remaining) (reverse acc)]
           [else
            (define binding-stx (car remaining))
            (define-values (binder-id witness-expr introduce?)
              (pack-binding-parts binding-stx))
            (define transformed-witness-expr
              (and introduce?
                   (transform-body-expr witness-expr current-bound)))
            (loop (cdr remaining)
                  (append current-bound (list (syntax-e binder-id)))
                  (cons (list binder-id transformed-witness-expr introduce?) acc))])))
     (define final-body
       (with-syntax ([(public-name ...)
                      (for/list ([binder-id (in-list binder-ids)])
                        #`'#,(syntax-e binder-id))]
                     [(binder-id ...) binder-ids]
                     [transformed-body-expr transformed-body])
         #'(pack/runtime (list public-name ...)
                         (list binder-id ...)
                         transformed-body-expr)))
     (for/fold ([expanded final-body])
               ([entry (in-list (reverse transformed-bindings))])
       (define binder-id (first entry))
       (define transformed-witness-expr (second entry))
       (define introduce? (third entry))
       (if introduce?
           ;; #:erasable? #f — a pack witness binder introduces the hidden
           ;; witness value the existential package carries; keep it wrapped.
           (wrap-runtime-named-binding binder-id transformed-witness-expr expanded #:erasable? #f)
           expanded))]))

(define-syntax (unpack stx)
  (syntax-parse stx
    [(_ packed-expr:expr pattern body:expr ...+)
     (build-unpack-expansion 'unpack
                             #'packed-expr
                             #'pattern
                             (syntax->list #'(body ...))
                             (or (body-bound-names stx) '()))]))

(define-syntax (let-exists stx)
  (syntax-parse stx
    [(_ () body:expr ...+)
     (transform-body-sequence (syntax->list #'(body ...))
                              (or (body-bound-names stx) '()))]
    [(_ ([pattern packed-expr:expr] more ...) body:expr ...+)
     (define outer-bound-names (or (body-bound-names stx) '()))
     (define-values (witness-ids body-name-id)
       (unpack-pattern-parts 'let-exists #'pattern))
     (define nested-bound-names
       (append outer-bound-names
               (map syntax-e witness-ids)
               (list (syntax-e body-name-id))))
     #`(unpack #,(transform-body-expr #'packed-expr outer-bound-names)
               pattern
               #,(annotate-body-scope #'(let-exists (more ...) body ...)
                                      nested-bound-names))]))

(define-syntax (let/check stx)
  (syntax-parse stx
    [(_ () body:expr ...+)
     (transform-body-sequence (syntax->list #'(body ...))
                              (or (body-bound-names stx) '()))]
    [(_ (binding:check-binding more:check-binding ...) body:expr ...+)
     (define outer-bound-names (or (body-bound-names stx) '()))
     (define nested-bound-names
       (append outer-bound-names (list (syntax-e #'binding.name))))
     #`(let ([result #,(transform-body-expr #'binding.expr outer-bound-names)])
         (if (check-fail? result)
             result
             (let ([binding.name result])
               #,(annotate-body-scope #'(let/check (more ...) body ...)
                                      nested-bound-names))))]))

(define-syntax (if/check stx)
  (syntax-parse stx
    [(_ [name:id expr:expr] then-branch:expr else-branch:expr)
     (define outer-bound-names (or (body-bound-names stx) '()))
     (define then-bound-names
       (append outer-bound-names (list (syntax-e #'name))))
     #`(let ([result #,(transform-body-expr #'expr outer-bound-names)])
         (if (check-fail? result)
             #,(transform-body-expr #'else-branch outer-bound-names)
             (let ([name result])
               #,(transform-body-expr #'then-branch then-bound-names))))]))

(define-syntax (define-checker stx)
  (syntax-parse stx
    [(_ (name:id arg:typed-binding ...) #:capabilities [cap:id ...] #:returns ret:expr body:expr ...+)
     (build-check-like-expansion 'checker
                                 stx
                                 #'name
                                 (syntax->list #'(arg ...))
                                 (syntax->list #'(cap ...))
                                 #'ret
                                 (syntax->list #'(body ...)))]
    [(_ (name:id arg:typed-binding ...) #:returns ret:expr body:expr ...+)
     (build-check-like-expansion 'checker
                                 stx
                                 #'name
                                 (syntax->list #'(arg ...))
                                 '()
                                 #'ret
                                 (syntax->list #'(body ...)))]))

(define-syntax (define-auther stx)
  (syntax-parse stx
    [(_ (name:id arg:typed-binding ...) #:capabilities [cap:id ...] #:returns ret:expr body:expr ...+)
     (build-check-like-expansion 'auther
                                 stx
                                 #'name
                                 (syntax->list #'(arg ...))
                                 (syntax->list #'(cap ...))
                                 #'ret
                                 (syntax->list #'(body ...)))]
    [(_ (name:id arg:typed-binding ...) #:returns ret:expr body:expr ...+)
     (build-check-like-expansion 'auther
                                 stx
                                 #'name
                                 (syntax->list #'(arg ...))
                                 '()
                                 #'ret
                                 (syntax->list #'(body ...)))]))
