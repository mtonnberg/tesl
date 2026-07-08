#lang racket

(require racket/list
         racket/match
         racket/set
         "private/evidence.rkt"
         ;; Money structs + display live in the private core (NOT tesl/money.rkt
         ;; — that surface module requires THIS file); the generated currency
         ;; table is instantiated for effect so tesl-currency-of resolves codes
         ;; on decode paths even before tesl/money.rkt is loaded.
         "private/money-core.rkt"
         (only-in "private/currency-data.rkt")
         (for-syntax racket/base
                     racket/list
                     racket/syntax
                     syntax/parse))

(provide
 gdp-expr?
 normalize-gdp-binding
 normalize-gdp-expr
 normalize-gdp-return
 gdp-expr->datum
 binding-unbound-names
 proof-unbound-names
 return-unbound-names
 canonicalize-gdp-expr
 canonicalize-gdp-binding
 canonicalize-gdp-return
 register-runtime-type!
 register-runtime-type/runtime!
 runtime-type-predicate
 define-newtype
 define-type-alias
 newtype-value?
 newtype-value-type-name
 newtype-value-value
 newtype-registry
 define-record
 define-adt
 lookup-record-spec
 tesl-record-update
 lookup-adt-spec
 instantiate-adt-field-template
 adt-application-spec
 register-field-access!
 lookup-field-access-spec
 field-access-type-for-value
 field-access-ref
 instantiate-proof-template/runtime
 record-invariant-registry
 runtime-type-satisfied?
 runtime-value->jsexpr
 current-agent-posix-enrichment?
 posix-millis-agent-jsexpr
 posix-millis-newtype?
 current-agent-money-enrichment?
 money-agent-jsexpr
 jsexpr->typed-value
 jsexpr->typed-value/result
 type-datum-display
 (struct-out record-spec)
 (struct-out record-field-spec)
 record-value
 record-value?
 record-value-type
 record-value-fields
 (struct-out field-access-spec)
 (struct-out adt-spec)
 (struct-out adt-variant-spec)
 (struct-out adt-field-spec)
 adt-value
 adt-value?
 adt-value-type
 adt-value-variant
 adt-value-fields
 Maybe?
 Nothing
 Nothing?
 Something
 Something?
 Something-value
 Result?
 Ok
 Ok?
 Ok-value
 Err
 Err?
 Err-error
 DeleteResult?
 NoRowDeleted
 NoRowDeleted?
 RowsDeleted
 RowsDeleted?
 RowsDeleted-count
 (struct-out arg-spec)
 (struct-out signature-spec)
 (struct-out auth-spec)
 (struct-out capture-spec)
 (struct-out payload-spec)
 (struct-out api-endpoint-spec)
 (struct-out api-spec)
 (struct-out route-spec)
 (struct-out server-spec)
 endpoint-argument-count
 register-type-codec!
 tesl-type-codec-decode
 tesl-json-string-codec
 tesl-json-int-codec
 tesl-json-int32-codec
 tesl-json-bool-codec
 tesl-json-float-codec
 tesl-json-posix-millis-codec
 tesl-json-money-codec
 tesl-json-list-codec
 tesl-json-dict-codec
 tesl-json-set-codec
 ;; specialized primitive encode/decode helpers (single source of truth;
 ;; the emitter inlines direct calls to these from per-type codecs)
 tesl-encode-prim-string
 tesl-encode-prim-int
 tesl-encode-prim-int32
 tesl-encode-prim-bool
 tesl-encode-prim-float
 tesl-encode-prim-posix-millis
 tesl-encode-prim-money
 tesl-encode-prim-list
 tesl-encode-prim-dict
 tesl-encode-prim-set
 tesl-decode-prim-string
 tesl-decode-prim-int
 tesl-decode-prim-int32
 tesl-decode-prim-bool
 tesl-decode-prim-float
 tesl-decode-prim-posix-millis
 tesl-decode-prim-money
 tesl-decode-prim-list
 tesl-decode-prim-dict
 tesl-decode-prim-set
 tesl-codec-encode-field
 tesl-codec-decode-field
 tesl-decode-prim-field
 (for-syntax normalize-type-stx
             normalize-type-binding-stx
             normalize-type-return-stx))

(define built-in-type-names
  '(Any Boolean Bytes Char Hash HttpRequest Integer Keyword List Maybe Null Number Fact Real Result String Symbol Vector))

(define (built-in-type-name? name)
  (and (symbol? name)
       (member name built-in-type-names eq?)))

(struct type-ref (owner name) #:prefab)

(begin-for-syntax
  (define built-in-type-names
    '(Any Boolean Bytes Char Hash HttpRequest Integer Keyword List Maybe Null Number Fact Real Result String Symbol Vector))

  (define (built-in-type-name? name)
    (and (symbol? name)
         (member name built-in-type-names eq?)))

  (struct type-ref (owner name) #:prefab)

  (define (module-owner-key stx)
    (define source-path (syntax-source stx))
    (define source-module (syntax-source-module stx))
    (define resolved-module
      (and source-module
           (resolved-module-path-name (module-path-index-resolve source-module))))
    (cond
      [(path? source-path) source-path]
      [(path? resolved-module) resolved-module]
      [resolved-module resolved-module]
      [else 'interactive]))

  (define (binding-owner-key binding id-stx)
    (define resolved
      (resolved-module-path-name (module-path-index-resolve (first binding))))
    (cond
      [(path? resolved) resolved]
      [(path? (syntax-source id-stx)) (syntax-source id-stx)]
      [resolved resolved]
      [else 'interactive]))

  (define (binding-form-stx? stx)
    (define parts (syntax->list stx))
    (and parts
         (or (= (length parts) 3)
             (= (length parts) 5))
         (identifier? (first parts))
         (identifier? (second parts))
         (eq? (syntax-e (second parts)) ':)))

  (define (type-token owner name bound-type-names)
    (cond
      [(member name bound-type-names eq?) name]
      [(built-in-type-name? name) name]
      [else (type-ref owner name)]))

  (define (normalize-type-identifier id-stx [bound-type-names '()])
    (define binding (and (identifier? id-stx) (identifier-binding id-stx)))
    (cond
      [binding
       (type-token (binding-owner-key binding id-stx)
                   (second binding)
                   bound-type-names)]
      [else
       (type-token (module-owner-key id-stx)
                   (syntax-e id-stx)
                   bound-type-names)]))

  (define (normalize-quoted-type-name stx)
    (syntax-parse stx
      #:datum-literals (quote)
      [(quote name:id)
       (type-token (module-owner-key stx)
                   (syntax-e #'name)
                   '())]
      [_ #f]))

  (define (normalize-type-binding-stx binding-stx [bound-type-names '()])
    (define parts (syntax->list binding-stx))
    (define binder-name (syntax-e (first parts)))
    (define type-stx (third parts))
    (define normalized-type (normalize-type-stx type-stx bound-type-names))
    (cond
      [(= (length parts) 3)
       (list binder-name ': normalized-type)]
      [else
       (list binder-name
             ':
             normalized-type
             ':::
             (syntax->datum (fifth parts)))]))

  (define (normalize-type-return-stx return-stx [bound-type-names '()])
    (if (binding-form-stx? return-stx)
        (normalize-type-binding-stx return-stx bound-type-names)
        (normalize-type-stx return-stx bound-type-names)))

  (define (normalize-type-stx stx [bound-type-names '()])
    (cond
      [(identifier? stx)
       (normalize-type-identifier stx bound-type-names)]
      [(binding-form-stx? stx)
       (normalize-type-binding-stx stx bound-type-names)]
      [else
       (let ([parts (syntax->list stx)])
         (cond
           [(not parts)
            (syntax->datum stx)]
           [(and (= (length parts) 3)
                 (identifier? (second parts))
                 (eq? (syntax-e (second parts)) ':::))
            (list (normalize-type-stx (first parts) bound-type-names)
                  ':::
                  (syntax->datum (third parts)))]
           [(and (pair? parts)
                 (identifier? (first parts))
                 (eq? (syntax-e (first parts)) '?))
            (cond
              [(= (length parts) 3)
               (list '?
                     (normalize-type-stx (second parts) bound-type-names)
                     (syntax-e (third parts)))]
              [(= (length parts) 5)
               (list '?
                     (normalize-type-stx (second parts) bound-type-names)
                     (syntax-e (third parts))
                     ':::
                     (syntax->datum (fifth parts)))]
              [else
               (syntax->datum stx)])]
           [(and (pair? parts)
                 (identifier? (first parts))
                 (eq? (syntax-e (first parts)) 'Exists)
                 (>= (length parts) 3))
            (append (list 'Exists)
                    (map (lambda (binding-stx)
                           (normalize-type-binding-stx binding-stx bound-type-names))
                         (drop-right (rest parts) 1))
                    (list (normalize-type-stx (last parts) bound-type-names)))]
           [else
            (map (lambda (part)
                   (normalize-type-stx part bound-type-names))
                 parts)]))]))

  (define (literal-type-key stx)
    (or (normalize-quoted-type-name stx)
        (and (identifier? stx)
             (normalize-type-identifier stx '())))))

(struct runtime-type-entry (name predicate) #:transparent)
(define runtime-type-registry (make-hash))
(struct newtype-value (type-name value) #:transparent)
(define newtype-registry (make-hash))

(define built-in-runtime-type-registry
  (hash 'Any (lambda (_value) #t)
        'Boolean boolean?
        'Bytes bytes?
        'Char char?
        'Hash hash?
        'Integer exact-integer?
        'Keyword keyword?
        'List list?
        'Null null?
        'Number number?
        'Real real?
        'String string?
        'Symbol symbol?
        'Vector vector?
        ;; S13: surface aliases that hand-written stdlib .rkt files pass as bare
        ;; symbols (Int from tesl/list.rkt & tesl/int.rkt; Bool/Float analogues).
        ;; Map to the SAME predicate as their canonical form so semantics are
        ;; identical.  Without these the fail-closed default below would reject
        ;; valid stdlib boundary args (e.g. List.repeat's `n : Int`).
        ;; NT-07: `Int` is EXACT — `(integer? 2.0)` is #t in Racket, so plain
        ;; `integer?` let a flonum masquerade as an Int (conflating Int/Float).
        ;; `exact-integer?` rejects 2.0 while accepting bignums of any magnitude.
        'Int exact-integer?
        'Bool boolean?
        'Float real?
        ;; S13: genuinely-unconstrained types whose runtime value is a
        ;; side-effect result or an erased proof — register an explicit
        ;; always-true predicate so they fail OPEN by intent, not by default.
        ;;   Unit  — `-> Unit` fns return (void)/DB-op results, not a 'Unit value.
        ;;   Fact  — carries a detached (erased) proof; re-verifying it would
        ;;           violate the proof-erasure discipline.
        'Unit (lambda (_value) #t)
        'Fact (lambda (_value) #t)
        ;; Money (First-Class Units): struct-backed built-ins from
        ;; private/money-core.rkt — without these rows the fail-CLOSED
        ;; no-predicate default would reject every Money-typed boundary
        ;; argument (PosixMillis gets its predicate via define-newtype in
        ;; tesl/time.rkt; structs need explicit rows).
        'Money tesl-money?
        'Currency tesl-currency?
        'ExchangeRate tesl-exchange-rate?))

(define (type-key? value)
  (or (symbol? value)
      (type-ref? value)))

(define (type-key-name value)
  (cond
    [(type-ref? value) (type-ref-name value)]
    [else value]))

;; S13: a type KEY is a type VARIABLE when its resolved name is lowercase-initial
;; (e.g. `a`, `b`).  The parser guarantees uppercase-initial = concrete type and
;; lowercase-initial = polymorphic type variable, so this decides over the
;; resolved type-key-name, not a spelling heuristic on user text.  Type variables
;; are unconstrained at runtime, so runtime-type-satisfied? keeps them fail-open.
(define (type-variable-key? k)
  (and (type-key? k)
       (let* ([name (type-key-name k)])
         (and (symbol? name)
              (let ([s (symbol->string name)])
                (and (> (string-length s) 0)
                     (char-lower-case? (string-ref s 0))))))))

(define (type-datum-display datum)
  (cond
    [(type-ref? datum) (type-ref-name datum)]
    [(binding-form-datum? datum)
     (match datum
       [(list name ': type)
        (list name ': (type-datum-display type))]
       [(list name ': type '::: proof)
        (list name ': (type-datum-display type) '::: (type-datum-display proof))]
       [_ datum])]
    [(list? datum)
     (map type-datum-display datum)]
    [else datum]))

(define (registry-sort-key name)
  (symbol->string (type-key-name name)))

(define (unique-match-by-name values target-name public-name-of who kind)
  (define matches
    (for/list ([value (in-list values)]
               #:when (equal? (public-name-of value) target-name))
      value))
  (cond
    [(null? matches) #f]
    [(null? (cdr matches)) (car matches)]
    [else
     (raise-user-error who
                       "ambiguous ~a name ~a across modules"
                       kind
                       target-name)]))

(define (register-runtime-type/runtime! name predicate)
  (unless (type-key? name)
    (raise-user-error 'register-runtime-type! "expected a symbol or module-scoped type name, got ~a" name))
  (unless (procedure? predicate)
    (raise-user-error 'register-runtime-type! "expected a predicate procedure, got ~a" predicate))
  (hash-set! runtime-type-registry name (runtime-type-entry (type-key-name name) predicate))
  (void))

(define-syntax (register-runtime-type! stx)
  (syntax-parse stx
    [(_ name predicate)
     (define maybe-key (literal-type-key #'name))
     (if maybe-key
         #`(register-runtime-type/runtime! '#,maybe-key predicate)
         #'(register-runtime-type/runtime! name predicate))]))

(define (runtime-type-predicate type-name)
  ;; S13: a type KEY reaching here is either a bare symbol (built-in/stdlib
  ;; surface type, e.g. `Integer`, `Int`, `Unit`) or a `type-ref` struct (every
  ;; USER record/ADT/newtype/alias, plus the built-in ADTs like DeleteResult that
  ;; are `define-adt`'d inside this module).  The runtime registry stores each
  ;; entry's NAME as the bare symbol (`type-key-name`), but a type-ref carries a
  ;; module OWNER: a handler-return / param type-ref emitted by the compiler has a
  ;; different owner than the registration site, so a raw `hash-ref` by the struct
  ;; MISSES.  Resolving to the bare name first lets the name-indexed fallback find
  ;; the registered predicate for a type-ref, turning those (previously dormant)
  ;; record/ADT/newtype runtime checks ON.
  (define resolved-name (type-key-name type-name))
  (define direct-entry (hash-ref runtime-type-registry type-name #f))
  (cond
    [direct-entry (runtime-type-entry-predicate direct-entry)]
    [(and (symbol? resolved-name)
          (hash-has-key? built-in-runtime-type-registry resolved-name))
     (hash-ref built-in-runtime-type-registry resolved-name)]
    [(symbol? resolved-name)
     (define match
       (unique-match-by-name (hash-values runtime-type-registry)
                             resolved-name
                             runtime-type-entry-name
                             'runtime-type-predicate
                             'runtime-type))
     (and match (runtime-type-entry-predicate match))]
    [else #f]))

(define adt-registry (make-hash))
(define record-registry (make-hash))
(define field-access-registry (make-hash))

(struct record-spec (name identity fields raw) #:transparent)
(struct record-field-spec (name type proof checker raw) #:transparent)
(struct record-value-data (type identity fields) #:transparent)
(struct field-access-spec (type-name identity fields getter) #:transparent)

(struct adt-spec (name identity parameters variants raw) #:transparent)
(struct adt-variant-spec (name fields raw) #:transparent)
(struct adt-field-spec (label template raw) #:transparent)
(struct adt-value-data (type identity variant fields) #:transparent)

;; Registry for record-level invariant checks
(define record-invariant-registry (make-hash))

(define (record-value type identity-or-fields [maybe-fields #f])
  (define-values (public-type identity fields)
    (cond
      [maybe-fields
       (values type identity-or-fields maybe-fields)]
      [else
       (define spec
         (or (lookup-record-spec type #f)
             (raise-user-error 'record-value
                               "expected a declared record type, got ~a"
                               (type-datum-display type))))
       (values (record-spec-name spec)
               (record-spec-identity spec)
               identity-or-fields)]))
  (define result (record-value-data public-type identity fields))
  ;; Run registered invariant check if any
  (define invariant-check (hash-ref record-invariant-registry public-type #f))
  (when invariant-check
    (invariant-check result))
  result)

(define record-value? record-value-data?)
(define (record-value-type value) (record-value-data-type value))
(define (record-value-identity value) (record-value-data-identity value))
(define (record-value-fields value) (record-value-data-fields value))

(define (adt-value type identity-or-variant variant-or-fields [maybe-fields #f])
  (define-values (public-type identity variant fields)
    (cond
      [maybe-fields
       (values type identity-or-variant variant-or-fields maybe-fields)]
      [else
       (define spec
         (or (lookup-adt-spec type #f)
             (raise-user-error 'adt-value
                               "expected a declared ADT type, got ~a"
                               (type-datum-display type))))
       (values (adt-spec-name spec)
               (adt-spec-identity spec)
               identity-or-variant
               variant-or-fields)]))
  (adt-value-data public-type identity variant fields))

(define adt-value? adt-value-data?)
(define (adt-value-type value) (adt-value-data-type value))
(define (adt-value-identity value) (adt-value-data-identity value))
(define (adt-value-variant value) (adt-value-data-variant value))
(define (adt-value-fields value) (adt-value-data-fields value))

(define (register-record! spec)
  (unless (record-spec? spec)
    (raise-user-error 'define-record "expected a record-spec, got ~a" spec))
  (define identity (record-spec-identity spec))
  (when (hash-has-key? record-registry identity)
    (raise-user-error 'define-record "Record ~a is already defined" (record-spec-name spec)))
  (validate-record-spec! spec)
  (hash-set! record-registry identity spec)
  (void))

(define (lookup-record-spec name [default #f])
  (or (hash-ref record-registry name #f)
      (and (symbol? name)
           (unique-match-by-name (hash-values record-registry)
                                 name
                                 record-spec-name
                                 'lookup-record-spec
                                 'record))
      default))

(define (register-field-access! type-name fields getter)
  (unless (type-key? type-name)
    (raise-user-error 'register-field-access! "expected a symbol or module-scoped type name, got ~a" type-name))
  (unless (and (list? fields) (andmap symbol? fields))
    (raise-user-error 'register-field-access! "expected a list of field symbols, got ~a" fields))
  (unless (procedure? getter)
    (raise-user-error 'register-field-access! "expected a field getter procedure, got ~a" getter))
  (hash-set! field-access-registry type-name
             (field-access-spec (type-key-name type-name)
                                type-name
                                (remove-duplicates fields)
                                getter))
  (void))

(define (lookup-field-access-spec type-name [default #f])
  (or (hash-ref field-access-registry type-name #f)
      (and (symbol? type-name)
           (unique-match-by-name (hash-values field-access-registry)
                                 type-name
                                 field-access-spec-type-name
                                 'lookup-field-access-spec
                                 'record/entity-type))
      default))

(define (register-adt! spec)
  (unless (adt-spec? spec)
    (raise-user-error 'define-adt "expected an adt-spec, got ~a" spec))
  (define identity (adt-spec-identity spec))
  (when (hash-has-key? adt-registry identity)
    (raise-user-error 'define-adt "ADT ~a is already defined" (adt-spec-name spec)))
  (hash-set! adt-registry identity spec)
  (void))

(define (lookup-adt-spec name [default #f])
  (or (hash-ref adt-registry name #f)
      (and (symbol? name)
           (unique-match-by-name (hash-values adt-registry)
                                 name
                                 adt-spec-name
                                 'lookup-adt-spec
                                 'adt))
      default))

(define (instantiate-adt-field-template template param-env)
  (cond
    [(and (symbol? template)
          (hash-has-key? param-env template))
     (hash-ref param-env template)]
    [(list? template)
     (map (lambda (item)
            (instantiate-adt-field-template item param-env))
          template)]
    [else template]))

(define (adt-application-spec normalized-type)
  (and (list? normalized-type)
       (pair? normalized-type)
       (type-key? (first normalized-type))
       (lookup-adt-spec (first normalized-type) #f)))

(define (adt-type-spec normalized-type)
  (cond
    [(and (type-key? normalized-type)
          (lookup-adt-spec normalized-type #f))
     (lookup-adt-spec normalized-type #f)]
    [else
     (adt-application-spec normalized-type)]))

(define (adt-type-arguments normalized-type)
  (if (list? normalized-type)
      (rest normalized-type)
      '()))

(define (type-constructor-name=? value expected-name)
  (and (type-key? value)
       (eq? (type-key-name value) expected-name)))

(define (list-type-argument normalized-type)
  (and (list? normalized-type)
       (= (length normalized-type) 2)
       (type-constructor-name=? (first normalized-type) 'List)
       (second normalized-type)))

(define (dict-type-arguments normalized-type)
  (and (list? normalized-type)
       (= (length normalized-type) 3)
       (type-constructor-name=? (first normalized-type) 'Dict)
       (list (second normalized-type) (third normalized-type))))

(define (tuple2-type-arguments normalized-type)
  (and (list? normalized-type)
       (= (length normalized-type) 3)
       (type-constructor-name=? (first normalized-type) 'Tuple2)
       (list (second normalized-type) (third normalized-type))))

(define (tuple3-type-arguments normalized-type)
  (and (list? normalized-type)
       (= (length normalized-type) 4)
       (type-constructor-name=? (first normalized-type) 'Tuple3)
       (list (second normalized-type) (third normalized-type) (fourth normalized-type))))

(define (set-type-argument normalized-type)
  (and (list? normalized-type)
       (= (length normalized-type) 2)
       (type-constructor-name=? (first normalized-type) 'Set)
       (second normalized-type)))

(define (runtime-dict-json-key->typed-key key-type raw-key who)
  (define key-name
    (and (type-key? key-type)
         (type-key-name key-type)))
  (define raw-string
    (cond
      [(string? raw-key) raw-key]
      [(symbol? raw-key) (symbol->string raw-key)]
      [else
       (raise-user-error who
                         "expected a JSON object key for Dict ~a to be a string-compatible key, got ~a"
                         (type-datum-display key-type)
                         raw-key)]))
  (cond
    [(or (eq? key-name 'String)
         (eq? key-name 'Any))
     raw-string]
    [(eq? key-name 'Symbol)
     (string->symbol raw-string)]
    [(eq? key-name 'Keyword)
     (string->keyword raw-string)]
    [else
     (raise-user-error who
                       "JSON object representation for Dict ~a only supports String, Symbol, Keyword, or Any keys; got ~a"
                       (type-datum-display (cons 'Dict (list key-type '...)))
                       (type-datum-display key-type))]))

(define (normalize-json-dict-pair who pair)
  (unless (and (list? pair) (= (length pair) 2))
    (raise-user-error who
                      "expected Dict JSON array entries to be [key, value] pairs, got ~a"
                      pair))
  pair)

(define (adt-variant-by-name spec variant-name)
  (for/first ([candidate (in-list (adt-spec-variants spec))]
              #:when (eq? (adt-variant-spec-name candidate) variant-name))
    candidate))

;; ── Agent-facing PosixMillis enrichment ──────────────────────────────────────
;; A bare epoch-millis integer in a tool result makes the model guess the
;; calendar date from the digits and hallucinate (the date-confusion class from
;; issue #30's user workarounds).  At the AGENT boundary only — never HTTP
;; responses, whose wire format is developer-owned — a PosixMillis value is
;; rendered as a self-describing object carrying both the raw integer and its
;; UTC ISO-8601 rendering.  Opt-in via this parameter, set by the agent tool
;; result encoders (serverTools dispatch, asTool result path).  Limitation:
;; a record with a user-written `codec` block keeps its authored wire shape —
;; only the generic (entity / codec-less record / list / ADT) walk enriches.
(define current-agent-posix-enrichment? (make-parameter #f))

(define (posix-ms->iso-utc ms)
  (define s (floor (/ ms 1000)))
  (define d (seconds->date s #f))
  (define (pad2 n) (if (< n 10) (format "0~a" n) (number->string n)))
  (format "~a-~a-~aT~a:~a:~aZ"
          (date-year d) (pad2 (date-month d)) (pad2 (date-day d))
          (pad2 (date-hour d)) (pad2 (date-minute d)) (pad2 (date-second d))))

(define (posix-millis-agent-jsexpr ms)
  (hash 'epochMillis ms 'iso (posix-ms->iso-utc ms)))

;; A newtype's type token is either a bare symbol or a `type-ref` carrying the
;; defining module — compare by resolved NAME so both spellings match.
(define (posix-millis-newtype? value)
  (and (newtype-value? value)
       (eq? (type-key-name (newtype-value-type-name value)) 'PosixMillis)))

;; ── Agent-facing Money enrichment ────────────────────────────────────────────
;; A bare `{minorUnits: 1050, currency: "SEK"}` in a tool result makes the model
;; do the minor-unit arithmetic itself and misstate amounts (the same
;; digits-confusion class as PosixMillis above).  At the AGENT boundary only —
;; never HTTP responses, whose wire format is developer-owned — a Money value
;; additionally carries its canonical human rendering (`display`, from
;; tesl-money-display, the ONE display definition).  Opt-in via this parameter,
;; set by the agent tool result encoders (serverTools dispatch, asTool result
;; path).  Limitation: a record with a user-written `codec` block keeps its
;; authored wire shape — only the generic walk enriches.
(define current-agent-money-enrichment? (make-parameter #f))

(define (money-agent-jsexpr m)
  (hash 'minorUnits (tesl-money-minor-units m)
        'currency (tesl-currency-code (tesl-money-currency m))
        'display (tesl-money-display m)))

(define (runtime-value->jsexpr value)
  (cond
    [(named-value? value)
     (runtime-value->jsexpr (named-value-value value))]
    [(check-ok? value)
     (runtime-value->jsexpr (check-ok-value value))]
    [(and (posix-millis-newtype? value)
          (current-agent-posix-enrichment?)
          (exact-integer? (newtype-value-value value)))
     (posix-millis-agent-jsexpr (newtype-value-value value))]
    [(newtype-value? value)
     (runtime-value->jsexpr (newtype-value-value value))]
    ;; Money wire shape (HTTP + agent): always `{minorUnits, currency}` — the
    ;; agent boundary (parameter above) additionally carries `display`.
    [(tesl-money? value)
     (if (current-agent-money-enrichment?)
         (money-agent-jsexpr value)
         (hash 'minorUnits (tesl-money-minor-units value)
               'currency (tesl-currency-code (tesl-money-currency value))))]
    ;; A Currency is its ISO 4217 code on the wire.
    [(tesl-currency? value)
     (tesl-currency-code value)]
    ;; ExchangeRate rarely crosses the wire, but the walk stays total: the
    ;; exact-rational rate is rendered as a JSON number (floats never enter
    ;; money ARITHMETIC; this is presentation only).
    [(tesl-exchange-rate? value)
     (hash 'from (tesl-currency-code (tesl-exchange-rate-from value))
           'to (tesl-currency-code (tesl-exchange-rate-to value))
           'rate (exact->inexact (tesl-exchange-rate-rate value))
           'asOf (runtime-value->jsexpr (tesl-exchange-rate-asOf value)))]
    [(adt-value? value)
     (define prepared-fields
       (for/hash ([(key item) (in-hash (adt-value-fields value))])
         (values key (runtime-value->jsexpr item))))
     (if (zero? (hash-count prepared-fields))
         (hash 'tag (symbol->string (adt-value-variant value)))
         (hash 'tag (symbol->string (adt-value-variant value))
               'fields prepared-fields))]
    [(record-value? value)
     (define _rv-type (record-value-type value))
     (define _rv-entry (hash-ref type-codec-registry _rv-type #f))
     (if _rv-entry
         ((car _rv-entry) value)
         (for/hash ([(key item) (in-hash (record-value-fields value))])
           (values key (runtime-value->jsexpr item))))]
    [(set? value)
     (map runtime-value->jsexpr (set->list value))]
    [(hash? value)
     (define entries (hash->list value))
     (if (for/and ([entry (in-list entries)])
           (define key (car entry))
           (or (string? key) (symbol? key) (keyword? key)))
         (for/hash ([entry (in-list entries)])
           (define key (car entry))
           (define item (cdr entry))
           (values (if (keyword? key) (keyword->string key) key)
                   (runtime-value->jsexpr item)))
         (for/list ([entry (in-list entries)])
           (list (runtime-value->jsexpr (car entry))
                 (runtime-value->jsexpr (cdr entry)))))]
    [(list? value)
     (map runtime-value->jsexpr value)]
    [(vector? value)
     (list->vector (map runtime-value->jsexpr (vector->list value)))]
    [(symbol? value)
     (symbol->string value)]
    [else value]))

(define (jsexpr-object-ref object key [default #f])
  (cond
    [(and (hash? object) (hash-has-key? object key))
     (hash-ref object key)]
    [(and (hash? object)
          (symbol? key)
          (hash-has-key? object (symbol->string key)))
     (hash-ref object (symbol->string key))]
    [(and (hash? object)
          (string? key)
          (hash-has-key? object (string->symbol key)))
     (hash-ref object (string->symbol key))]
    [else default]))

(define (normalize-jsexpr-object object who)
  (unless (hash? object)
    (raise-user-error who "expected a JSON object, got ~a" object))
  (for/hash ([(key value) (in-hash object)])
    (values (cond
              [(symbol? key) key]
              [(string? key) (string->symbol key)]
              [else
               (raise-user-error who
                                 "expected JSON object keys to be strings or symbols, got ~a"
                                 key)])
            value)))

(define (instantiate-proof-template/runtime datum name-env)
  (cond
    [(and (symbol? datum) (hash-has-key? name-env datum))
     (hash-ref name-env datum)]
    [(list? datum)
     (map (lambda (item)
            (instantiate-proof-template/runtime item name-env))
          datum)]
    [else datum]))

(define (datum-symbols/runtime datum)
  (cond
    [(symbol? datum) (list datum)]
    [(list? datum) (append-map datum-symbols/runtime datum)]
    [else '()]))

(define (check-ok-primary-name field-spec result)
  (define bindings (check-ok-bindings result))
  (or (for*/first ([fact (in-list (check-ok-facts result))]
                   [subject (in-list (remove-duplicates (datum-symbols/runtime fact)))]
                   #:when (and (hash-has-key? bindings subject)
                               (equal? (hash-ref bindings subject)
                                       (check-ok-value result))))
        subject)
      (record-field-spec-name field-spec)))

(define (record-field-evidence-value field-spec value)
  (cond
    [(named-value? value) value]
    [(check-ok? value)
     (ensure-named (check-ok-primary-name field-spec value)
                   (check-ok-value value)
                   (check-ok-facts value)
                   (check-ok-bindings value))]
    [else #f]))

(define (flatten-record-proof-facts facts)
  (append-map
   (lambda (fact)
     (define items (infix-operands fact '&&))
     (if items
         (flatten-record-proof-facts items)
         (list fact)))
   facts))

(define (record-proof-fact-matches? expected actual bindings)
  (cond
    [(equal? expected actual) #t]
    [(and (pair? expected) (pair? actual))
     (and (record-proof-fact-matches? (car expected) (car actual) bindings)
          (record-proof-fact-matches? (cdr expected) (cdr actual) bindings))]
    [(and (symbol? expected)
          (symbol? actual)
          (hash-has-key? bindings expected)
          (hash-has-key? bindings actual)
          (equal? (hash-ref bindings expected)
                  (hash-ref bindings actual)))
     #t]
    [else #f]))

(define (record-field-proof-satisfied? field-spec value)
  (define proof-datum (record-field-spec-proof field-spec))
  (cond
    [(not proof-datum) #t]
    [else
     (define named (record-field-evidence-value field-spec value))
     (and named
          (let ([actual-facts (flatten-record-proof-facts (facts-of named))]
                [bindings (named-value-bindings named)]
                [expected (instantiate-proof-template/runtime
                           proof-datum
                           (hash (record-field-spec-name field-spec)
                                 (named-value-name named)))])
            (let loop ([proof expected])
              (cond
                [(eq? proof #t) #t]
                [(eq? proof #f) #f]
                [(infix-operands proof '&&)
                 => (lambda (items)
                      (andmap loop items))]
                [else
                 (ormap (lambda (fact)
                          (record-proof-fact-matches? proof fact bindings))
                        actual-facts)]))))]))

(define (record-field-value-matches-spec? field-spec value)
  ;; ::: proof annotations without a #:check are compile-time only (zero runtime cost).
  ;; Only validate the runtime type; proof satisfaction is only checked when a checker exists.
  (define type-ok (runtime-type-satisfied? (record-field-spec-type field-spec) (raw-value value)))
  (if (record-field-spec-checker field-spec)
      (and type-ok (record-field-proof-satisfied? field-spec value))
      type-ok))

(define (validate-record-field-spec! record-name field-spec)
  (define field-name (record-field-spec-name field-spec))
  (define proof-datum (record-field-spec-proof field-spec))
  (define checker (record-field-spec-checker field-spec))
  (when (and checker (not proof-datum))
    (raise-user-error 'define-record
                      "field ~a on record ~a cannot use #:check without a ::: proof annotation"
                      field-name
                      record-name))
  (when proof-datum
    (define unbound-names
      (proof-unbound-names proof-datum (list field-name)))
    (when (pair? unbound-names)
      (raise-user-error 'define-record
                        "field ~a on record ~a may only reference its own binder in ::: proofs; unbound names: ~a"
                        field-name
                        record-name
                        unbound-names))))

(define (validate-record-spec! spec)
  (for ([field-spec (in-list (record-spec-fields spec))])
    (validate-record-field-spec! (record-spec-name spec) field-spec)))

(define (run-record-field-checker record-name field-spec value)
  (define result ((record-field-spec-checker field-spec) (raw-value value)))
  (cond
    [(check-fail? result)
     (raise-user-error record-name
                       "field ~a on record ~a failed proof check: ~a"
                       (record-field-spec-name field-spec)
                       record-name
                       (check-fail-message result))]
    [(check-ok? result)
     (record-field-evidence-value field-spec result)]
    [(named-value? result)
     (ensure-named (record-field-spec-name field-spec) result)]
    [else
     (raise-user-error record-name
                       "checker for field ~a on record ~a did not return a check result"
                       (record-field-spec-name field-spec)
                       record-name)]))

(define (coerce-record-field-value record-name field-spec value)
  (define proof-datum (record-field-spec-proof field-spec))
  (define checker (record-field-spec-checker field-spec))
  (define prepared
    (cond
      [(and proof-datum checker
            (record-field-proof-satisfied? field-spec value))
       (record-field-evidence-value field-spec value)]
      [checker
       (run-record-field-checker record-name field-spec value)]
      [else value]))
  (define field-type (record-field-spec-type field-spec))
  (define raw (raw-value prepared))
  ;; Auto-coerce: if the raw value doesn't satisfy the declared type but the
  ;; field type is a newtype wrapping the raw value's type, wrap automatically.
  (define effective-raw
    (cond
      [(runtime-type-satisfied? field-type raw) raw]
      [else
       (define base (hash-ref newtype-registry field-type #f))
       (if (and base (runtime-type-satisfied? base raw))
           (jsexpr->typed-value field-type raw 'record-field)
           raw)]))
  ;; If a field value is a check-fail struct (from a fn that returns check-fail via
  ;; let/check), raise a clean validation error instead of leaking Racket struct
  ;; representation (#(struct:check-fail ...)) in the type-mismatch message.
  (when (check-fail? effective-raw)
    (raise-user-error record-name
                      "field ~a on record ~a: validation failed — ~a"
                      (record-field-spec-name field-spec)
                      record-name
                      (check-fail-message effective-raw)))
  (unless (runtime-type-satisfied? field-type effective-raw)
    (raise-user-error record-name
                      "expected field ~a on record ~a to satisfy type ~a, got ~a"
                      (record-field-spec-name field-spec)
                      record-name
                      field-type
                      raw))
  (cond
    [checker
     ;; Fields with explicit checkers: use the checker-prepared value (has GDP facts)
     ;; These are the only fields that store proof-carrying named-values at runtime.
     (define named (record-field-evidence-value field-spec prepared))
     (unless (record-field-proof-satisfied? field-spec named)
       (raise-user-error record-name
                         "expected field ~a on record ~a to carry proof ~a, got ~a"
                         (record-field-spec-name field-spec)
                         record-name
                         proof-datum
                         value))
     named]
    [proof-datum
     ;; No checker, but ::: proof annotation present.
     ;; If the caller passes a value already carrying the required proof (check-ok or
     ;; named-value), preserve it as a named-value — this enables proof transport
     ;; through record fields (GDP pattern: check-at-construction, carry-proof-inside).
     ;; If a plain value is passed, store raw (zero runtime cost — proof is compile-time).
     (define evidence (record-field-evidence-value field-spec value))
     (if (and evidence (record-field-proof-satisfied? field-spec evidence))
         evidence
         effective-raw)]
    [else
     ;; No checker, no proof annotation: store raw value.
     effective-raw]))

(define (record-value-matches-spec? spec value)
  (and (record-value? value)
       (equal? (record-value-identity value) (record-spec-identity spec))
       (let* ([expected-fields (record-spec-fields spec)]
              [actual-fields (record-value-fields value)]
              [expected-labels (map record-field-spec-name expected-fields)]
              [actual-labels (hash-keys actual-fields)])
         (and (equal? (sort expected-labels symbol<?)
                      (sort actual-labels symbol<?))
              (for/and ([field-spec (in-list expected-fields)])
                (record-field-value-matches-spec? field-spec
                                                  (hash-ref actual-fields
                                                            (record-field-spec-name field-spec))))))))

(define (tesl-record-update value updates [who 'tesl-record-update])
  (unless (hash? updates)
    (raise-user-error who "expected a hash of field updates, got ~a" updates))
  (cond
    [(record-value? value)
     (define spec
       (or (lookup-record-spec (record-value-identity value) #f)
           (raise-user-error who
                             "record update syntax expects a known record type, got ~a"
                             (record-value-type value))))
     (define allowed-fields
       (map record-field-spec-name (record-spec-fields spec)))
     (for ([field-name (in-hash-keys updates)])
       (unless (member field-name allowed-fields)
         (raise-user-error who
                           "unknown field ~a for record type ~a"
                           field-name
                           (record-spec-name spec))))
     (record-value
      (record-spec-name spec)
      (record-spec-identity spec)
      (for/hash ([field-spec (in-list (record-spec-fields spec))])
        (define field-name (record-field-spec-name field-spec))
        (define next-value
          (if (hash-has-key? updates field-name)
              (hash-ref updates field-name)
              (hash-ref (record-value-fields value) field-name)))
        (values field-name
                (coerce-record-field-value (record-spec-name spec)
                                           field-spec
                                           next-value))))]
    [(hash? value)
     (for/fold ([current value]) ([(field-name next-value) (in-hash updates)])
       (hash-set current field-name next-value))]
    [else
     (raise-user-error who "record update syntax expects a record or hash value, got ~a" value)]))

(define (field-access-type-for-value value)
  (define matches
    (sort
     (for/list ([(type-name spec) (in-hash field-access-registry)]
                #:when (and (field-access-spec? spec)
                            (runtime-type-satisfied? type-name value)))
       type-name)
     string<?
     #:key registry-sort-key))
  (and (= (length matches) 1)
       (car matches)))

(define (field-access-ref value field-name [expected-type #f] [who 'tesl-dot])
  (define unwrapped (raw-value value))
  (define field-symbol
    (cond
      [(symbol? field-name) field-name]
      [(string? field-name) (string->symbol field-name)]
      [else
       (raise-user-error who "expected a field name symbol or string, got ~a" field-name)]))
  (define expected-spec
    (and expected-type (lookup-field-access-spec expected-type #f)))
  (cond
    [expected-spec
     (unless (runtime-type-satisfied? expected-type unwrapped)
       (raise-user-error who
                         "expected a value satisfying record/entity type ~a for dot access, got ~a"
                         (type-datum-display expected-type)
                         value))
     (unless (member field-symbol (field-access-spec-fields expected-spec))
       (raise-user-error who
                         "unknown field ~a for record/entity type ~a"
                         field-symbol
                         (field-access-spec-type-name expected-spec)))
     ((field-access-spec-getter expected-spec) unwrapped field-symbol)]
    [(and (newtype-value? unwrapped) (eq? field-symbol 'value))
     (newtype-value-value unwrapped)]
    [else
     (define matching-specs
       (sort
        (for/list ([(type-name spec) (in-hash field-access-registry)]
                   #:when (and (field-access-spec? spec)
                               (runtime-type-satisfied? type-name unwrapped)))
          spec)
        string<?
        #:key (lambda (spec)
                (registry-sort-key (field-access-spec-identity spec)))))
     (cond
       [(null? matching-specs)
        (raise-user-error who
                          "dot access is only supported on declared record/entity values, got ~a"
                          value)]
       [else
        (define field-specs
          (filter (lambda (spec)
                    (member field-symbol (field-access-spec-fields spec)))
                  matching-specs))
        (cond
          [(null? field-specs)
           (raise-user-error who
                             "unknown field ~a for record/entity type~a ~a"
                             field-symbol
                             (if (= (length matching-specs) 1) "" "s")
                             (map field-access-spec-type-name matching-specs))]
          [(pair? (cdr field-specs))
           (raise-user-error who
                             "ambiguous dot access for field ~a; candidate record/entity types: ~a"
                             field-symbol
                             (map field-access-spec-type-name field-specs))]
          [else
           ((field-access-spec-getter (car field-specs)) unwrapped field-symbol)])])]))

(define (runtime-type-satisfied? type-datum value)
  (define maybe-adt-spec (adt-type-spec type-datum))
  (define maybe-record-spec (lookup-record-spec type-datum #f))
  (define maybe-list-type (list-type-argument type-datum))
  (define maybe-dict-types (dict-type-arguments type-datum))
  (define maybe-tuple2-types (tuple2-type-arguments type-datum))
  (define maybe-tuple3-types (tuple3-type-arguments type-datum))
  (define maybe-set-type (set-type-argument type-datum))
  (cond
    [(or (named-value? value) (check-ok? value))
     (runtime-type-satisfied? type-datum (raw-value value))]
    [maybe-tuple2-types
     (cond
       [(and (list? value) (= (length value) 2))
        (and (runtime-type-satisfied? (first maybe-tuple2-types) (first value))
             (runtime-type-satisfied? (second maybe-tuple2-types) (second value)))]
       [(and (adt-value? value)
             (equal? (adt-value-type value) 'Tuple2)
             (eq? (adt-value-variant value) 'Tuple2))
        (define actual-fields (adt-value-fields value))
        (and (runtime-type-satisfied? (first maybe-tuple2-types) (hash-ref actual-fields 'first))
             (runtime-type-satisfied? (second maybe-tuple2-types) (hash-ref actual-fields 'second)))]
       [else #f])]
    [maybe-tuple3-types
     (cond
       [(and (list? value) (= (length value) 3))
        (and (runtime-type-satisfied? (first maybe-tuple3-types) (first value))
             (runtime-type-satisfied? (second maybe-tuple3-types) (second value))
             (runtime-type-satisfied? (third maybe-tuple3-types) (third value)))]
       [(and (adt-value? value)
             (equal? (adt-value-type value) 'Tuple3)
             (eq? (adt-value-variant value) 'Tuple3))
        (define actual-fields (adt-value-fields value))
        (and (runtime-type-satisfied? (first maybe-tuple3-types) (hash-ref actual-fields 'first))
             (runtime-type-satisfied? (second maybe-tuple3-types) (hash-ref actual-fields 'second))
             (runtime-type-satisfied? (third maybe-tuple3-types) (hash-ref actual-fields 'third)))]
       [else #f])]
    [maybe-adt-spec
     (define adt-name (adt-spec-name maybe-adt-spec))
     (define type-args (adt-type-arguments type-datum))
     (and (adt-value? value)
          (or (equal? (adt-value-identity value) (adt-spec-identity maybe-adt-spec))
              (equal? (adt-value-type value) adt-name))
          (= (length (adt-spec-parameters maybe-adt-spec))
             (length type-args))
          (let ([variant-spec
                 (adt-variant-by-name maybe-adt-spec
                                      (adt-value-variant value))])
            (and variant-spec
                 (let* ([expected-fields (adt-variant-spec-fields variant-spec)]
                        [actual-fields (adt-value-fields value)]
                        [expected-labels (map adt-field-spec-label expected-fields)]
                        [actual-labels (hash-keys actual-fields)]
                        [param-env
                         (for/hash ([param (in-list (adt-spec-parameters maybe-adt-spec))]
                                    [arg (in-list type-args)])
                           (values param arg))])
                   (and (equal? (sort expected-labels symbol<?)
                                (sort actual-labels symbol<?))
                        (for/and ([field-spec (in-list expected-fields)])
                          (define label (adt-field-spec-label field-spec))
                          (runtime-type-satisfied?
                           (instantiate-adt-field-template (adt-field-spec-template field-spec)
                                                           param-env)
                           (hash-ref actual-fields label))))))))]
    [maybe-record-spec
     (record-value-matches-spec? maybe-record-spec value)]
    [maybe-list-type
     (and (list? value)
          (for/and ([item (in-list value)])
            (runtime-type-satisfied? maybe-list-type item)))]
    [maybe-dict-types
     (define key-type (first maybe-dict-types))
     (define value-type (second maybe-dict-types))
     (and (hash? value)
          (for/and ([(key item) (in-hash value)])
            (and (runtime-type-satisfied? key-type key)
                 (runtime-type-satisfied? value-type item))))]
    [maybe-set-type
     (and (set? value)
          (for/and ([item (in-set value)])
            (runtime-type-satisfied? maybe-set-type item)))]
    [(type-key? type-datum)
     (define predicate (runtime-type-predicate type-datum))
     (cond
       [predicate (predicate value)]
       ;; S13: type VARIABLES (lowercase-initial names like `a`, `b`) are
       ;; polymorphic parameters with no runtime constraint; keep fail-open by
       ;; construction.  These are the stdlib return heads (list-derived.rkt
       ;; maximum/minimum/foldr `#:returns a|b`) that a naive flip broke.
       [(type-variable-key? type-datum) #t]
       ;; S13 (full): fail-CLOSED is now LIVE for the no-predicate case.  This was
       ;; previously retained fail-OPEN because `runtime-type-predicate` resolved
       ;; ONLY bare symbols and NOT a `type-ref` struct — so every type-ref (Unit,
       ;; DeleteResult, and every user record/ADT/newtype) reached here with no
       ;; predicate even though one was registered under its name, and closing
       ;; would have rejected valid returns.  `runtime-type-predicate` now resolves
       ;; a type-ref to its bare NAME first (see above), so a registered
       ;; record/ADT/newtype/built-in predicate IS found and taken via the
       ;; `[predicate ...]` branch above.  Only a genuinely UNKNOWN concrete type
       ;; (no registered predicate, not a type variable) falls through here, and it
       ;; now fails CLOSED — the residual §7.10 boundary hole is shut.
       [else #f])]
    ;; Compound datums (binding-forms `[n : T ::: P]`, `?`-forms, `Exists`, and
    ;; `Fact (Pred ...)` applications) fall through here.  These are handled by
    ;; dedicated validators (validate-exists-return, validate-adt-return, the
    ;; checker/auther) or are erased-proof payloads; failing them closed here
    ;; would over-reject and re-introduce proof re-verification.  Retained.
    [else #t]))

;; JSON nesting-depth cap (DoS): the typed decoder recurses once per nested
;; container; attacker JSON nested thousands deep can exhaust the stack.  A
;; dynamic depth counter (incremented per call via the wrapper below) bounds it.
;; Configurable via TESL_MAX_JSON_DEPTH; default 64, far above any real payload.
(define max-json-decode-depth
  (let ([v (getenv "TESL_MAX_JSON_DEPTH")])
    (or (and v (let ([n (string->number v)]) (and (exact-positive-integer? n) n)))
        64)))
(define current-json-decode-depth (make-parameter 0))

;; Wrapper: checks/raises on excessive depth, then recurses into the real body.
;; Every recursive call in the body targets `jsexpr->typed-value` (this wrapper),
;; so the dynamic counter increments at each level without threading a param
;; through the many call sites.  jsexpr->typed-value/result catches the raise and
;; renders it as a clean 400.
(define (jsexpr->typed-value type-datum value [who 'types])
  (define depth (current-json-decode-depth))
  (when (> depth max-json-decode-depth)
    (error who "JSON nesting too deep (max ~a levels)" max-json-decode-depth))
  (parameterize ([current-json-decode-depth (add1 depth)])
    (jsexpr->typed-value* type-datum value who)))

(define (jsexpr->typed-value* type-datum value who)
  (define maybe-adt-spec (adt-type-spec type-datum))
  (define maybe-record-spec (lookup-record-spec type-datum #f))
  (define maybe-list-type (list-type-argument type-datum))
  (define maybe-dict-types (dict-type-arguments type-datum))
  (define maybe-set-type (set-type-argument type-datum))
  (cond
    [maybe-adt-spec
     (define normalized (normalize-jsexpr-object value who))
     (define raw-tag (jsexpr-object-ref normalized 'tag #f))
     (unless (string? raw-tag)
       (raise-user-error who
                         "expected an ADT JSON object with a string tag for type ~a, got ~a"
                         (type-datum-display type-datum)
                         value))
     (define variant-name (string->symbol raw-tag))
     (define variant-spec (adt-variant-by-name maybe-adt-spec variant-name))
     (unless variant-spec
       (raise-user-error who
                         "unknown ADT variant ~a for type ~a"
                         variant-name
                         (type-datum-display type-datum)))
     (define expected-fields (adt-variant-spec-fields variant-spec))
     (define raw-fields
       (jsexpr-object-ref normalized 'fields (hash)))
     (define actual-fields (normalize-jsexpr-object raw-fields who))
     (define expected-labels (map adt-field-spec-label expected-fields))
     (define actual-labels (hash-keys actual-fields))
     (define missing-labels
       (filter (lambda (label)
                 (not (member label actual-labels)))
               expected-labels))
     (define extra-labels
       (filter (lambda (label)
                 (not (member label expected-labels)))
               actual-labels))
     (when (pair? missing-labels)
       (raise-user-error who
                         "ADT JSON for type ~a is missing field label~a ~a"
                         (type-datum-display type-datum)
                         (if (= (length missing-labels) 1) "" "s")
                         missing-labels))
     (when (pair? extra-labels)
       (raise-user-error who
                         "ADT JSON for type ~a has unexpected field label~a ~a"
                         (type-datum-display type-datum)
                         (if (= (length extra-labels) 1) "" "s")
                         extra-labels))
     (define param-env
       (for/hash ([param (in-list (adt-spec-parameters maybe-adt-spec))]
                  [arg (in-list (adt-type-arguments type-datum))])
         (values param arg)))
     (adt-value (adt-spec-name maybe-adt-spec)
                (adt-spec-identity maybe-adt-spec)
                variant-name
                (for/hash ([field-spec (in-list expected-fields)])
                  (define label (adt-field-spec-label field-spec))
                  (values label
                          (jsexpr->typed-value
                           (instantiate-adt-field-template (adt-field-spec-template field-spec)
                                                           param-env)
                           (hash-ref actual-fields label)
                           who))))]
    [maybe-record-spec
     (define _rec-type-name (record-spec-name maybe-record-spec))
     (define _rec-codec-entry (hash-ref type-codec-registry _rec-type-name #f))
     (cond
       [_rec-codec-entry
        ;; Use registered codec: try decoders in order, first success wins
        (tesl-type-codec-decode _rec-type-name value)]
       [else
        (define normalized (normalize-jsexpr-object value who))
        (define expected-fields (record-spec-fields maybe-record-spec))
        (define expected-labels (map record-field-spec-name expected-fields))
        (define actual-labels (hash-keys normalized))
        (define missing-labels
          (filter (lambda (label)
                    (not (member label actual-labels)))
                  expected-labels))
        (define extra-labels
          (filter (lambda (label)
                    (not (member label expected-labels)))
                  actual-labels))
        (when (pair? missing-labels)
          (raise-user-error who
                            "record JSON for type ~a is missing field~a ~a"
                            (type-datum-display type-datum)
                            (if (= (length missing-labels) 1) "" "s")
                            missing-labels))
        (when (pair? extra-labels)
          (raise-user-error who
                            "record JSON for type ~a has unexpected field~a ~a"
                            (type-datum-display type-datum)
                            (if (= (length extra-labels) 1) "" "s")
                            extra-labels))
        (record-value (record-spec-name maybe-record-spec)
                      (record-spec-identity maybe-record-spec)
                      (for/hash ([field-spec (in-list expected-fields)])
                        (define label (record-field-spec-name field-spec))
                        (when (and (record-field-spec-proof field-spec)
                                   (not (record-field-spec-checker field-spec)))
                          (raise-user-error who
                                            "record JSON for type ~a cannot decode proof-annotated field ~a without an explicit #:check"
                                            (type-datum-display type-datum)
                                            label))
                        (define decoded
                          (jsexpr->typed-value (record-field-spec-type field-spec)
                                               (hash-ref normalized label)
                                               who))
                        (values label
                                (coerce-record-field-value (record-spec-name maybe-record-spec)
                                                           field-spec
                                                           decoded))))])]
    [maybe-dict-types
     (define key-type (first maybe-dict-types))
     (define value-type (second maybe-dict-types))
     (cond
       [(hash? value)
        (for/hash ([(raw-key raw-item) (in-hash value)])
          (values (runtime-dict-json-key->typed-key key-type raw-key who)
                  (jsexpr->typed-value value-type raw-item who)))]
       [(list? value)
        (for/hash ([raw-pair (in-list value)])
          (define pair (normalize-json-dict-pair who raw-pair))
          (values (jsexpr->typed-value key-type (first pair) who)
                  (jsexpr->typed-value value-type (second pair) who)))]
       [else
        (raise-user-error who
                          "expected Dict JSON for type ~a to be an object or list of [key, value] pairs, got ~a"
                          (type-datum-display type-datum)
                          value)])]
    [maybe-set-type
     (unless (list? value)
       (raise-user-error who
                         "expected Set JSON for type ~a to be a list, got ~a"
                         (type-datum-display type-datum)
                         value))
     (list->set (for/list ([item (in-list value)])
                  (jsexpr->typed-value maybe-set-type item who)))]
    ;; Money / Currency are struct-backed built-ins (not records/newtypes, so
    ;; no spec matches): decode through the same single-source helpers as the
    ;; codec path so wire shape and error text cannot drift.
    [(and (type-key? type-datum) (eq? (type-key-name type-datum) 'Money))
     (tesl-decode-prim-money value)]
    [(and (type-key? type-datum) (eq? (type-key-name type-datum) 'Currency))
     (unless (string? value)
       (raise-user-error who
                         "expected a JSON string ISO 4217 code for type Currency, got ~a"
                         value))
     (or (tesl-currency-of value)
         (raise-user-error who "unknown ISO 4217 currency code ~a" value))]
    [else
     (define maybe-newtype-base (hash-ref newtype-registry type-datum #f))
     (if maybe-newtype-base
         (let ([base-value (jsexpr->typed-value maybe-newtype-base value who)])
           (newtype-value type-datum base-value))
         (let ([converted
                (cond
                  [(and (eq? type-datum 'Symbol) (string? value))
                   (string->symbol value)]
                  [(and (eq? type-datum 'Keyword) (string? value))
                   (string->keyword value)]
                  [else value])])
           (unless (runtime-type-satisfied? type-datum converted)
             (raise-user-error who
                               "expected a JSON value satisfying type ~a, got ~a"
                               (type-datum-display type-datum)
                               value))
           converted))]))

(define (jsexpr->typed-value/result type-datum value [who 'types])
  (define result
    (with-handlers ([exn:fail? (lambda (exn)
                                 (check-fail (exn-message exn) 400 '()))])
      (jsexpr->typed-value type-datum value who)))
  ;; If jsexpr->typed-value returned a check-fail (from codec decoder), pass it through
  ;; directly so the original HTTP status code is preserved.
  result)

(define (normalize-adt-field-template datum)
  (cond
    [(or (symbol? datum) (type-ref? datum)) datum]
    [(binding-form-datum? datum) (normalize-gdp-binding datum)]
    [else
     (error 'define-adt "invalid ADT field template ~a; expected an identifier or typed binding" datum)]))

(begin-for-syntax
  (define-syntax-class typed-binding
    (pattern [name:id (~datum :) type:expr (~datum :::) proof:expr])
    (pattern [name:id (~datum :) type:expr]))

  (define-syntax-class record-field
    (pattern [name:id (~datum :) type:expr (~datum :::) proof:expr (~datum #:check) checker:expr]
             #:attr proof-datum (syntax->datum #'proof)
             #:attr checker-stx #'checker)
    (pattern [name:id (~datum :) type:expr (~datum :::) proof:expr]
             #:attr proof-datum (syntax->datum #'proof)
             #:attr checker-stx #'#f)
    (pattern [name:id (~datum :) type:expr]
             #:attr proof-datum #f
             #:attr checker-stx #'#f))

  (define-syntax-class adt-field-template
    (pattern name:id
             #:attr label-id #'name
             #:attr template-stx #'name)
    (pattern binding:typed-binding
             #:attr label-id #'binding.name
             #:attr template-stx #'binding))

  (define-syntax-class adt-head
    (pattern name:id
             #:attr type-name #'name
             #:attr param-ids '())
    (pattern (name:id param:id ...)
             #:attr type-name #'name
             #:attr param-ids (syntax->list #'(param ...)))))

(define-syntax (define-newtype stx)
  (syntax-parse stx
    [(_ name:id base-type:expr)
     (define type-token (normalize-type-stx #'name))
     (define base-type-datum (normalize-type-stx #'base-type))
     #`(begin
         (define (name v)
           (unless (runtime-type-satisfied? '#,base-type-datum v)
             (raise-user-error 'name "expected a value of type ~a, got ~a" '#,base-type-datum v))
           (newtype-value '#,type-token v))
         (register-runtime-type! '#,type-token
                                 (lambda (value)
                                   (and (newtype-value? value)
                                        (equal? (newtype-value-type-name value) '#,type-token))))
         (hash-set! newtype-registry '#,type-token '#,base-type-datum))]))

;; Transparent alias: the constructor validates and returns the value as-is (no newtype-value wrap).
;; The type predicate delegates to the base type, so operators like > and == work directly.
(define-syntax (define-type-alias stx)
  (syntax-parse stx
    [(_ name:id base-type:expr)
     (define type-token (normalize-type-stx #'name))
     (define base-type-datum (normalize-type-stx #'base-type))
     #`(begin
         ;; Constructor: validate then return raw value — no wrapping.
         (define (name v)
           (define raw (if (newtype-value? v) (newtype-value-value v) v))
           (unless (runtime-type-satisfied? '#,base-type-datum raw)
             (raise-user-error 'name "expected a value of type ~a, got ~a" '#,base-type-datum raw))
           raw)
         ;; Type predicate: check base type directly (alias is transparent at runtime).
         (register-runtime-type! '#,type-token
                                 (lambda (value)
                                   (runtime-type-satisfied? '#,base-type-datum value))))]))

(define-syntax (define-record stx)
  (syntax-parse stx
    [(_ record-name:id field:record-field ...+
        (~optional (~seq #:invariant invariant:expr)))
     (define field-ids (syntax->list #'(field.name ...)))
     (define field-symbols (map syntax-e field-ids))
     (define duplicate-field (check-duplicates field-symbols))
     (when duplicate-field
       (raise-syntax-error 'define-record
                           (format "duplicate field ~a in record ~a"
                                   duplicate-field
                                   (syntax-e #'record-name))
                           stx))
     (define record-type-datum (normalize-type-stx #'record-name))
     (define predicate-id (format-id #'record-name "~a?" (syntax-e #'record-name)))
     (define spec-id (format-id #'record-name "~a-spec" (syntax-e #'record-name)))
     (define invariant-expr-stx (or (attribute invariant) #'#f))
     (define keyword-stxs
       (for/list ([field-id (in-list field-ids)])
         (datum->syntax field-id (string->keyword (symbol->string (syntax-e field-id))))))
     (define field-type-datums
       (for/list ([field-type (in-list (syntax->list #'(field.type ...)))])
         (normalize-type-stx field-type)))
     (define field-proof-datums (attribute field.proof-datum))
     (define field-checker-stxs (attribute field.checker-stx))
     (define field-raw-datums (map syntax->datum (syntax->list #'(field ...))))
     (define constructor-arg-stxs
       (append-map (lambda (keyword-stx field-id)
                     (list keyword-stx field-id))
                   keyword-stxs
                   field-ids))
     (define field-spec-exprs
       (for/list ([field-id (in-list field-ids)]
                  [field-type-datum (in-list field-type-datums)]
                  [field-proof-datum (in-list field-proof-datums)]
                  [field-checker-stx (in-list field-checker-stxs)]
                  [field-raw-datum (in-list field-raw-datums)])
         #`(record-field-spec '#,(syntax-e field-id)
                              '#,field-type-datum
                              '#,field-proof-datum
                              #,field-checker-stx
                              '#,field-raw-datum)))
     (define constructor-hash-entry-stxs
       (append-map (lambda (field-id field-spec-expr)
                     (list #`'#,(syntax-e field-id)
                           #`(coerce-record-field-value
                              '#,(syntax-e #'record-name)
                              #,field-spec-expr
                              #,field-id)))
                   field-ids
                   field-spec-exprs))
     (with-syntax ([(constructor-arg ...) constructor-arg-stxs]
                   [(constructor-hash-entry ...) constructor-hash-entry-stxs]
                   [predicate-id predicate-id]
                   [spec-id spec-id]
                   [(field-spec-expr ...) field-spec-exprs]
                   [raw-datum #`'#,(syntax->datum stx)]
                   [invariant-expr invariant-expr-stx])
       #`(begin
           (define (record-name constructor-arg ...)
             (record-value '#,(syntax-e #'record-name)
                           '#,record-type-datum
                           (hash constructor-hash-entry ...)))
           (define spec-id
             (record-spec '#,(syntax-e #'record-name)
                          '#,record-type-datum
                          (list field-spec-expr ...)
                          raw-datum))
           (define (predicate-id value)
             (record-value-matches-spec? spec-id value))
           (register-runtime-type! '#,record-type-datum predicate-id)
           (register-record! spec-id)
           (when invariant-expr
             (hash-set! record-invariant-registry '#,(syntax-e #'record-name) invariant-expr))
           (register-field-access! '#,record-type-datum
                                   '(field.name ...)
                                   (lambda (value field-name)
                                     (hash-ref (record-value-fields value) field-name)))
           (void)))]))

(define-syntax (define-adt stx)
  (syntax-parse stx
    [(_ head:adt-head variant ...+)
     (define type-name-id #'head.type-name)
     (define type-name-symbol (syntax-e type-name-id))
     (define type-name-datum (normalize-type-stx type-name-id))
     (define param-ids (attribute head.param-ids))
     (define param-symbols (map syntax-e param-ids))
     (define duplicate-param (check-duplicates param-symbols))
     (when duplicate-param
       (raise-syntax-error 'define-adt
                           (format "duplicate ADT parameter ~a" duplicate-param)
                           stx))
     (define variant-stxs (syntax->list #'(variant ...)))
     (define variant-symbols
       (for/list ([variant-stx (in-list variant-stxs)])
         (syntax-parse variant-stx
           [[variant-name:id _ ...]
            (syntax-e #'variant-name)])))
     (define duplicate-variant (check-duplicates variant-symbols))
     (when duplicate-variant
       (raise-syntax-error 'define-adt
                           (format "duplicate ADT variant ~a" duplicate-variant)
                           stx))
     (define root-predicate-id (format-id type-name-id "~a?" type-name-symbol))
     (define variant-definition-stxs
       (for/list ([variant-stx (in-list variant-stxs)])
         (syntax-parse variant-stx
           [[variant-name:id field:adt-field-template ...]
            (define field-ids (attribute field.label-id))
            (define field-symbols (map syntax-e field-ids))
            (define duplicate-field (check-duplicates field-symbols))
            (when duplicate-field
              (raise-syntax-error 'define-adt
                                  (format "duplicate field label ~a in variant ~a"
                                          duplicate-field
                                          (syntax-e #'variant-name))
                                  variant-stx))
            (define predicate-id (format-id #'variant-name "~a?" (syntax-e #'variant-name)))
            (define accessor-ids
              (for/list ([field-id (in-list field-ids)])
                (format-id field-id "~a-~a" (syntax-e #'variant-name) (syntax-e field-id))))
            (define constructor-def
              (if (null? field-ids)
                  #`(define variant-name
                      (adt-value '#,type-name-symbol
                                 '#,type-name-datum
                                 '#,(syntax-e #'variant-name)
                                 (hash)))
                  #`(define (variant-name #,@field-ids)
                      (adt-value '#,type-name-symbol
                                 '#,type-name-datum
                                 '#,(syntax-e #'variant-name)
                                 (hash #,@(append-map (lambda (field-id)
                                                        (list #`'#,(syntax-e field-id)
                                                              field-id))
                                                      field-ids))))))
            (define accessor-defs
              (for/list ([field-id (in-list field-ids)]
                         [accessor-id (in-list accessor-ids)])
                #`(define (#,accessor-id value)
                    (unless (#,predicate-id value)
                      (raise-user-error '#,(syntax-e accessor-id)
                                        "expected a value produced by constructor ~a, got ~a"
                                        '#,(syntax-e #'variant-name)
                                        value))
                    (hash-ref (adt-value-fields value) '#,(syntax-e field-id)))))
            #`(begin
                #,constructor-def
                (define (#,predicate-id value)
                  (and (adt-value? value)
                       (equal? (adt-value-identity value) '#,type-name-datum)
                       (eq? (adt-value-variant value) '#,(syntax-e #'variant-name))))
                #,@accessor-defs)])))
     (define variant-spec-stxs
       (for/list ([variant-stx (in-list variant-stxs)])
         (syntax-parse variant-stx
           [[variant-name:id field:adt-field-template ...]
            (define template-datums
              (for/list ([template-stx (in-list (attribute field.template-stx))])
                (normalize-type-stx template-stx param-symbols)))
            (with-syntax ([(field-label ...) (for/list ([field-id (in-list (attribute field.label-id))])
                                               #`'#,(syntax-e field-id))]
                          [(field-template ...) (for/list ([template-datum (in-list template-datums)])
                                                  #`'#,template-datum)])
              #`(adt-variant-spec '#,(syntax-e #'variant-name)
                                  (list (adt-field-spec field-label
                                                        (normalize-adt-field-template field-template)
                                                        field-template) ...)
                                  '#,(syntax->datum variant-stx)))])))
     (with-syntax ([(variant-definition ...) variant-definition-stxs]
                   [(variant-spec ...) variant-spec-stxs]
                   [(param-symbol ...) (for/list ([param-symbol (in-list param-symbols)])
                                         #`'#,(datum->syntax stx param-symbol))]
                   [type-name-id type-name-id]
                   [root-predicate-id root-predicate-id]
                   [raw-datum #`'#,(syntax->datum stx)])
       #`(begin
           (define type-name-id '#,type-name-symbol)
           variant-definition ...
           (define (root-predicate-id value)
             (and (adt-value? value)
                  (equal? (adt-value-identity value) '#,type-name-datum)))
           (register-runtime-type! '#,type-name-datum root-predicate-id)
           (register-adt! (adt-spec '#,type-name-symbol
                                    '#,type-name-datum
                                    (list param-symbol ...)
                                    (list variant-spec ...)
                                    raw-datum))))]))

(define (gdp-atom? value)
  (or (symbol? value)
      (type-ref? value)
      (string? value)
      (number? value)
      (boolean? value)
      (bytes? value)
      (char? value)
      (keyword? value)
      (null? value)))

(define (gdp-expr? value)
  (or (gdp-atom? value)
      (and (list? value)
           (andmap gdp-expr? value))))

(define (binding-form-datum? datum)
  (and (list? datum)
       (or (= (length datum) 3)
           (= (length datum) 5))
       (symbol? (second datum))
       (eq? (second datum) ':)))

(define (infix-operands datum op)
  (and (list? datum)
       (>= (length datum) 3)
       (odd? (length datum))
       (for/and ([index (in-range 1 (length datum) 2)])
         (eq? (list-ref datum index) op))
       (for/list ([index (in-range 0 (length datum) 2)])
         (list-ref datum index))))

(define (normalize-and-items items)
  (define flat
    (append-map
     (lambda (item)
       (define normalized (normalize-gdp-expr item))
       (if (and (list? normalized)
                (infix-operands normalized '&&))
           (infix-operands normalized '&&)
           (list normalized)))
     items))
  (define deduped (remove-duplicates flat equal?))
  (cond
    [(null? deduped) #t]
    [(null? (cdr deduped)) (car deduped)]
    [else (infix-datum '&& deduped)]))

(define (normalize-attach subject proof)
  (define normalized-subject (normalize-gdp-expr subject))
  (define normalized-proof (normalize-gdp-expr proof))
  (match normalized-subject
    [(list inner-subject '::: inner-proof)
     (normalize-attach inner-subject
                       (normalize-and-items (list inner-proof normalized-proof)))]
    [(list '? type name)
     (list '?
           type
           name
           ':::
           normalized-proof)]
    [(list '? type name '::: inner-proof)
     (list '?
           type
           name
           ':::
           (normalize-and-items (list inner-proof normalized-proof)))]
    [_
     (list normalized-subject '::: normalized-proof)]))

(define (normalize-gdp-binding datum)
  (cond
    [(binding-form-datum? datum)
     (match datum
       [(list name ': type)
        (list name
              ':
              (normalize-gdp-expr type))]
       [(list name ': type '::: proof)
        (list name
              ':
              (normalize-gdp-expr type)
              ':::
              (normalize-gdp-expr proof))]
       [_
        (error 'normalize-gdp-binding "invalid binding datum: ~a" datum)])]
    [else
     (error 'normalize-gdp-binding "expected a binding datum, got ~a" datum)]))

(define (normalize-gdp-expr datum)
  (cond
    [(gdp-atom? datum) datum]
    [(binding-form-datum? datum)
     (normalize-gdp-binding datum)]
    [(infix-operands datum '&&)
     => normalize-and-items]
    [(and (list? datum)
          (= (length datum) 3)
          (eq? (second datum) ':::))
     (normalize-attach (first datum) (third datum))]
    [(and (list? datum)
          (= (length datum) 3)
          (eq? (second datum) '==))
     (list (normalize-gdp-expr (first datum))
           '==
           (normalize-gdp-expr (third datum)))]
    [(and (list? datum)
          (pair? datum)
          (eq? (first datum) '?))
     (match datum
       [(list '? type name)
        (list '?
              (normalize-gdp-expr type)
              name)]
       [(list '? type name '::: proof)
        (normalize-attach (list '? (normalize-gdp-expr type) name)
                          proof)]
       [_
        (error 'normalize-gdp-expr "invalid ? form: ~a" datum)])]
    [(and (list? datum)
          (pair? datum)
          (eq? (first datum) 'Exists)
          (>= (length datum) 3))
     (define body (last datum))
     (define bindings (drop-right (rest datum) 1))
     (append (list 'Exists)
             (map normalize-gdp-binding bindings)
             (list (normalize-gdp-expr body)))]
    [(list? datum)
     (map normalize-gdp-expr datum)]
    [else datum]))

(define (normalize-gdp-return datum)
  (if (binding-form-datum? datum)
      (normalize-gdp-binding datum)
      (normalize-gdp-expr datum)))

(define (dedupe-symbols items)
  (remove-duplicates items eq?))

(define (eq-term-unbound-names datum bound)
  (cond
    [(or (gdp-atom? datum) (symbol? datum)) '()]
    [(binding-form-datum? datum) (binding-unbound-names datum bound)]
    [(list? datum)
     (append-map (lambda (item)
                   (eq-term-unbound-names item bound))
                 datum)]
    [else '()]))

;; A raw-value variable `*x` (the runtime raw value of a bound GDP name `x`) is
;; bound exactly when `x` is.  A computed proof subject such as `ValidScore (n / 2)`
;; lowers to `(quotient *n 2)`, so the proof template legitimately mentions `*n`;
;; it is a runtime raw-value binding, NOT an unbound GDP name.
(define (raw-value-var-of-bound? datum bound)
  (and (symbol? datum)
       (let ([s (symbol->string datum)])
         (and (> (string-length s) 1)
              (char=? (string-ref s 0) #\*)
              (member (string->symbol (substring s 1)) bound)))))

(define (proof-arg-unbound-names datum bound)
  (cond
    [(symbol? datum)
     (if (or (member datum bound) (raw-value-var-of-bound? datum bound))
         '()
         (list datum))]
    [(gdp-atom? datum) '()]
    [(binding-form-datum? datum) (binding-unbound-names datum bound)]
    [(and (list? datum)
          (= (length datum) 3)
          (eq? (second datum) '==))
     (append (eq-term-unbound-names (first datum) bound)
             (eq-term-unbound-names (third datum) bound))]
    [(list? datum) (proof-unbound-names datum bound)]
    [else '()]))

(define (qform-unbound-names datum bound)
  (match datum
    [(list '? type name)
     ; name is a fresh binder introduced by ?, not a reference — not reported as unbound
     (type-unbound-names type bound)]
    [(list '? type name '::: proof)
     ; name is a fresh binder introduced by ?; proof is checked with name in scope
     (define extended-bound (if (symbol? name) (cons name bound) bound))
     (append (type-unbound-names type bound)
             (proof-unbound-names proof extended-bound))]
    [_ '()]))

(define (exists-unbound-names datum bound)
  (define body (last datum))
  (define bindings (drop-right (rest datum) 1))
  (define-values (all-bound extra)
    (for/fold ([current-bound bound]
               [acc '()])
              ([binding (in-list bindings)])
      (define normalized-binding (normalize-gdp-binding binding))
      (define missing (binding-unbound-names normalized-binding current-bound))
      (values (append current-bound (list (first normalized-binding)))
              (append acc missing))))
  (append extra (return-unbound-names body all-bound)))

(define (type-unbound-names datum [bound '()])
  (dedupe-symbols
   (cond
     [(or (gdp-atom? datum) (symbol? datum)) '()]
     [(binding-form-datum? datum) (binding-unbound-names datum bound)]
     [(and (list? datum)
           (pair? datum)
           (eq? (first datum) '?))
      (qform-unbound-names datum bound)]
     [(and (list? datum)
           (pair? datum)
           (eq? (first datum) 'Exists)
           (>= (length datum) 3))
      (exists-unbound-names datum bound)]
     [(list? datum)
      (append-map (lambda (item)
                    (type-unbound-names item bound))
                  datum)]
     [else '()])))

(define (proof-unbound-names datum [bound '()])
  (dedupe-symbols
   (cond
     [(or (gdp-atom? datum) (symbol? datum)) '()]
     [(binding-form-datum? datum) (binding-unbound-names datum bound)]
     [(infix-operands datum '&&)
      => (lambda (items)
           (append-map (lambda (item)
                         (proof-unbound-names item bound))
                       items))]
     [(and (list? datum)
           (= (length datum) 3)
           (eq? (second datum) '==))
      (append (eq-term-unbound-names (first datum) bound)
              (eq-term-unbound-names (third datum) bound))]
     [(and (list? datum)
           (pair? datum)
           (eq? (first datum) '?))
      (qform-unbound-names datum bound)]
     [(and (list? datum)
           (pair? datum)
           (eq? (first datum) 'Exists)
           (>= (length datum) 3))
      (exists-unbound-names datum bound)]
     [(list? datum)
      (append-map (lambda (item)
                    (proof-arg-unbound-names item bound))
                  (rest datum))]
     [else '()])))

(define (binding-unbound-names datum [outer-bound '()])
  (define normalized (normalize-gdp-binding datum))
  (match normalized
    [(list name ': type)
     (type-unbound-names type (append outer-bound (list name)))]
    [(list name ': type '::: proof)
     (append (type-unbound-names type (append outer-bound (list name)))
             (proof-unbound-names proof (append outer-bound (list name))))]
    [_ '()]))

(define (return-unbound-names datum [bound '()])
  (define normalized (normalize-gdp-return datum))
  (dedupe-symbols
   (cond
     [(binding-form-datum? normalized) (binding-unbound-names normalized bound)]
     [(and (list? normalized)
           (pair? normalized)
           (eq? (first normalized) '?))
      (qform-unbound-names normalized bound)]
     [(and (list? normalized)
           (pair? normalized)
           (eq? (first normalized) 'Exists)
           (>= (length normalized) 3))
      (exists-unbound-names normalized bound)]
     [else
      (type-unbound-names normalized bound)])))

(define (canonical-name index)
  (string->symbol (format "$~a" index)))

(define (temporary-import-type-ref? datum)
  (and (type-ref? datum)
       (path? (type-ref-owner datum))
       (regexp-match? #rx"(^|/)tesl-compiled-import-[0-9a-f]+[.]rkt$"
                      (path->string (type-ref-owner datum)))))

(define (canonicalize-symbol datum env)
  (cond
    [(temporary-import-type-ref? datum)
     (type-ref 'tesl-compiled-import (type-ref-name datum))]
    [(and (symbol? datum)
          (hash-has-key? env datum))
     (hash-ref env datum)]
    [else datum]))

(define (canonicalize-items items env next-index)
  (for/fold ([acc '()]
             [current-index next-index])
            ([item (in-list items)])
    (define-values (canonical-item next-item-index)
      (canonicalize-gdp-expr item env current-index))
    (values (append acc (list canonical-item))
            next-item-index)))

(define (canonicalize-gdp-expr datum [env (hash)] [next-index 0])
  (cond
    [(or (gdp-atom? datum) (symbol? datum))
     (values (canonicalize-symbol datum env)
             next-index)]
    [(binding-form-datum? datum)
     (define-values (canonical-binding _canonical-env next-binding-index)
       (canonicalize-gdp-binding datum env next-index))
     (values canonical-binding next-binding-index)]
    [(infix-operands datum '&&)
     => (lambda (items)
          (define-values (canonical-items next-item-index)
            (canonicalize-items items env next-index))
          (values (infix-datum '&& canonical-items)
                  next-item-index))]
    [(and (list? datum)
          (= (length datum) 3)
          (eq? (second datum) '==))
     (define-values (canonical-left next-left-index)
       (canonicalize-gdp-expr (first datum) env next-index))
     (define-values (canonical-right next-right-index)
       (canonicalize-gdp-expr (third datum) env next-left-index))
     (values (list canonical-left '== canonical-right)
             next-right-index)]
    [(and (list? datum)
          (pair? datum)
          (eq? (first datum) '?))
     (match datum
       [(list '? type name)
        ; name is a fresh binder introduced by ?; canonicalize it like a binding name
        (define canonical-binder-name (canonical-name next-index))
        (define next-env (if (symbol? name) (hash-set env name canonical-binder-name) env))
        (define-values (canonical-type next-type-index)
          (canonicalize-gdp-expr type next-env (add1 next-index)))
        (values (list '?
                      canonical-type
                      canonical-binder-name)
                next-type-index)]
       [(list '? type name '::: proof)
        ; name is a fresh binder introduced by ?; add it to env for proof canonicalization
        (define canonical-binder-name (canonical-name next-index))
        (define next-env (if (symbol? name) (hash-set env name canonical-binder-name) env))
        (define-values (canonical-type next-type-index)
          (canonicalize-gdp-expr type next-env (add1 next-index)))
        (define-values (canonical-proof next-proof-index)
          (canonicalize-gdp-expr proof next-env next-type-index))
        (values (list '?
                      canonical-type
                      canonical-binder-name
                      ':::
                      canonical-proof)
                next-proof-index)]
       [_
        (values datum next-index)])]
    [(and (list? datum)
          (pair? datum)
          (eq? (first datum) 'Exists)
          (>= (length datum) 3))
     (define body (last datum))
     (define bindings (drop-right (rest datum) 1))
     (define-values (canonical-bindings canonical-env next-binding-index)
       (for/fold ([acc '()]
                  [current-env env]
                  [current-index next-index])
                 ([binding (in-list bindings)])
         (define-values (canonical-binding next-env next-item-index)
           (canonicalize-gdp-binding binding current-env current-index))
         (values (append acc (list canonical-binding))
                 next-env
                 next-item-index)))
     (define-values (canonical-body next-body-index)
       (canonicalize-gdp-expr body canonical-env next-binding-index))
     (values (append (list 'Exists)
                     canonical-bindings
                     (list canonical-body))
             next-body-index)]
    [(list? datum)
     (define-values (canonical-items next-item-index)
       (canonicalize-items datum env next-index))
     (values canonical-items next-item-index)]
    [else
     (values datum next-index)]))

(define (canonicalize-gdp-binding datum [env (hash)] [next-index 0])
  (define normalized (normalize-gdp-binding datum))
  (match normalized
    [(list name ': type)
     (define canonical-binding-name (canonical-name next-index))
     (define next-env (hash-set env name canonical-binding-name))
     (define-values (canonical-type next-type-index)
       (canonicalize-gdp-expr type next-env (add1 next-index)))
     (values (list canonical-binding-name
                   ':
                   canonical-type)
             next-env
             next-type-index)]
    [(list name ': type '::: proof)
     (define canonical-binding-name (canonical-name next-index))
     (define next-env (hash-set env name canonical-binding-name))
     (define-values (canonical-type next-type-index)
       (canonicalize-gdp-expr type next-env (add1 next-index)))
     (define-values (canonical-proof next-proof-index)
       (canonicalize-gdp-expr proof next-env next-type-index))
     (values (list canonical-binding-name
                   ':
                   canonical-type
                   ':::
                   canonical-proof)
             next-env
             next-proof-index)]
    [_
     (error 'canonicalize-gdp-binding "invalid binding datum: ~a" datum)]))

(define (canonicalize-gdp-return datum [env (hash)] [next-index 0])
  (canonicalize-gdp-expr (normalize-gdp-return datum) env next-index))

(define (infix-datum op items)
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

(define (gdp-expr->datum expr)
  expr)

(struct arg-spec (name type proof raw) #:transparent)
(struct signature-spec (kind name args capabilities returns raw) #:transparent)

(struct auth-spec (binder type proof via raw) #:transparent)
(struct capture-spec (name type proof parser checker raw) #:transparent)
(struct payload-spec (name type proof format wire-type decoder checker raw) #:transparent)

(struct api-endpoint-spec (name auth segments method format returns response-wire-type response-encoder raw) #:transparent)
(struct api-spec (name endpoints raw) #:transparent)

(struct route-spec (operation method format auth segments handler returns response-wire-type response-encoder) #:transparent)
(struct server-spec (name api bindings routes raw) #:transparent)

(define (endpoint-argument-count endpoint)
  (+ (if (api-endpoint-spec-auth endpoint) 1 0)
     (for/sum ([segment (in-list (api-endpoint-spec-segments endpoint))])
       (if (or (capture-spec? segment)
               (payload-spec? segment))
           1
           0))))


;; ============================================================
;; JSON Codec registry (Elm-inspired type-level codecs)
;; ============================================================

;; Registry: type-name (symbol) -> (cons encoder (listof decoder))
;; encoder: (tesl-value -> jsexpr)
;; decoder: (jsexpr -> tesl-value-or-raises)
(define type-codec-registry (make-hash))

(define (register-type-codec! type-name encoder decoders)
  (hash-set! type-codec-registry type-name (cons encoder decoders)))

;; Try each decoder in order; return the first successful result.
;; check-fail? results (from via validation) are returned directly to preserve HTTP status codes.
(define (tesl-type-codec-decode type-name jsexpr)
  (define entry (hash-ref type-codec-registry type-name #f))
  (unless entry
    (raise-user-error 'codec "no codec registered for type ~a" type-name))
  (define decoders (cdr entry))
  (define first-fail #f)
  (define result
    (for/or ([d (in-list decoders)])
      (with-handlers ([exn:fail? (lambda (e) #f)])
        (let ([v (d jsexpr)])
          (cond
            [(check-fail? v)
             ;; Via-check validation failure: remember first, keep trying other decoders
             (unless first-fail
               (set! first-fail v))
             #f]
            [else v])))))
  (cond
    [result result]
    [first-fail first-fail]  ; return check-fail directly, preserving HTTP status code
    [else
     (raise-user-error 'codec "no decoder succeeded for type ~a on JSON: ~a" type-name jsexpr)]))

;; ── Specialized primitive codec helpers (compile_time_specialization) ────────
;; These are the SINGLE SOURCE OF TRUTH for primitive encode/decode behaviour.
;; The primitive codec PAIRS below are built from them (so the runtime
;; `tesl-codec-encode-field`/`tesl-codec-decode-field` interpreter path stays
;; behaviour-identical), AND the emitter inlines DIRECT calls to these from a
;; type's specialized encoder/decoder — skipping the codec-spec `cond` dispatch
;; and the indirect `(car/cdr codec-spec)` call.  Inlining a named call and
;; routing through the registry therefore produce byte-identical jsexpr and
;; byte-identical error text on every branch by construction.
;;
;; NOTE: `error` here treats the first arg as a message PREFIX, not a format
;; string — `(error "expected String, got ~a" v)` prints "expected String,
;; got ~a <printed-v>".  This (pre-existing) text is reproduced verbatim.

;; Encoders: raw Tesl value -> jsexpr-compatible (raises on type mismatch).
(define (tesl-encode-prim-string v)
  (if (string? (raw-value v)) (raw-value v) (error "expected String, got ~a" v)))
(define (tesl-encode-prim-int v)
  (if (integer? (raw-value v)) (raw-value v) (error "expected Int, got ~a" v)))
;; Int32: JS-safe 32-bit-bounded integer. Same wire shape as Int (a JSON number),
;; but the decode boundary REJECTS values outside [-2^31, 2^31) rather than
;; silently wrapping — mirroring int32? in tesl/int32.rkt (constants inlined here
;; because int32.rkt requires this file, so the dependency cannot be reversed).
(define TESL-INT32-MIN (- (expt 2 31)))
(define TESL-INT32-MAX (sub1 (expt 2 31)))
(define (tesl-int32-in-range? n) (and (exact-integer? n) (>= n TESL-INT32-MIN) (<= n TESL-INT32-MAX)))
(define (tesl-encode-prim-int32 v)
  (define raw (raw-value v))
  (if (tesl-int32-in-range? raw) raw (error "expected Int32 (in [-2^31, 2^31)), got ~a" v)))
(define (tesl-encode-prim-bool v)
  (if (boolean? (raw-value v)) (raw-value v) (error "expected Bool, got ~a" v)))
(define (tesl-encode-prim-float v)
  (if (real? (raw-value v)) (raw-value v) (error "expected Float, got ~a" v)))
(define (tesl-encode-prim-posix-millis v)
  (define raw (raw-value v))
  (if (integer? raw) raw (error "expected PosixMillis (integer), got ~a" v)))
;; Money encodes as its unconditional wire shape `{minorUnits, currency}` —
;; agent enrichment (display) is a boundary concern, never a codec one, so an
;; authored codec and the generic walk agree on the persisted/HTTP shape.
(define (tesl-encode-prim-money v)
  (define raw (raw-value v))
  (if (tesl-money? raw)
      (hash 'minorUnits (tesl-money-minor-units raw)
            'currency (tesl-currency-code (tesl-money-currency raw)))
      (error "expected Money, got ~a" v)))
(define (tesl-encode-prim-list v)
  (define raw (raw-value v))
  (if (list? raw) (map runtime-value->jsexpr raw) (error "expected List, got ~a" v)))
(define (tesl-encode-prim-dict v)
  (define raw (raw-value v))
  (if (hash? raw)
      (for/hash ([(k item) (in-hash raw)]) (values k (runtime-value->jsexpr item)))
      (error "expected Dict, got ~a" v)))
(define (tesl-encode-prim-set v)
  (define raw (raw-value v))
  (if (set? raw) (map runtime-value->jsexpr (set->list raw)) (error "expected Set, got ~a" v)))

;; Decoders: jsexpr-compatible -> raw value (raises on type mismatch).
(define (tesl-decode-prim-string j)
  (if (string? j) j (error "expected JSON string, got ~a" j)))
(define (tesl-decode-prim-int j)
  (if (integer? j) j (error "expected JSON integer, got ~a" j)))
(define (tesl-decode-prim-int32 j)
  (cond
    [(not (integer? j)) (error "expected JSON integer for Int32, got ~a" j)]
    [(not (tesl-int32-in-range? j)) (error "expected Int32 in [-2^31, 2^31), got ~a" j)]
    [else j]))
(define (tesl-decode-prim-bool j)
  (if (boolean? j) j (error "expected JSON boolean, got ~a" j)))
(define (tesl-decode-prim-float j)
  (if (real? j) j (error "expected JSON number, got ~a" j)))
(define (tesl-decode-prim-posix-millis j)
  (if (integer? j) j (error "expected JSON integer for PosixMillis, got ~a" j)))
;; Money decode: `{minorUnits: <int>, currency: <known ISO code>}` → tesl-money.
;; Extra keys (e.g. an agent-enriched `display` echoed back) are tolerated;
;; an unknown currency code or a non-integer amount is a clear error.
(define (tesl-decode-prim-money j)
  (unless (hash? j)
    (error "expected JSON object {minorUnits, currency} for Money, got ~a" j))
  (define units (jsexpr-object-ref j 'minorUnits 'TESL-MISSING))
  (define code (jsexpr-object-ref j 'currency 'TESL-MISSING))
  (when (or (eq? units 'TESL-MISSING) (eq? code 'TESL-MISSING))
    (error "expected JSON object with minorUnits and currency for Money, got ~a" j))
  (unless (exact-integer? units)
    (error "expected integer minorUnits for Money, got ~a" units))
  (unless (string? code)
    (error "expected string currency code for Money, got ~a" code))
  (define cur (tesl-currency-of code))
  (unless cur
    (error "unknown ISO 4217 currency code for Money: ~a" code))
  (tesl-money units cur))
(define (tesl-decode-prim-list j)
  (if (list? j) j (error "expected JSON array for List, got ~a" j)))
(define (tesl-decode-prim-dict j)
  (if (hash? j) j (error "expected JSON object for Dict, got ~a" j)))
(define (tesl-decode-prim-set j)
  (if (list? j) (list->set j) (error "expected JSON array for Set, got ~a" j)))

;; Primitive codec pairs (cons encoder decoder) — built from the helpers above
;; so the interpreter path and the inlined path share one definition.
;; encoder: raw Tesl value -> jsexpr-compatible
;; decoder: jsexpr-compatible -> raw value (raises on type mismatch)
(define tesl-json-string-codec       (cons tesl-encode-prim-string       tesl-decode-prim-string))
(define tesl-json-int-codec          (cons tesl-encode-prim-int          tesl-decode-prim-int))
(define tesl-json-int32-codec        (cons tesl-encode-prim-int32        tesl-decode-prim-int32))
(define tesl-json-bool-codec         (cons tesl-encode-prim-bool         tesl-decode-prim-bool))
(define tesl-json-float-codec        (cons tesl-encode-prim-float        tesl-decode-prim-float))
(define tesl-json-posix-millis-codec (cons tesl-encode-prim-posix-millis tesl-decode-prim-posix-millis))
(define tesl-json-money-codec        (cons tesl-encode-prim-money        tesl-decode-prim-money))
(define tesl-json-list-codec         (cons tesl-encode-prim-list         tesl-decode-prim-list))
(define tesl-json-dict-codec         (cons tesl-encode-prim-dict         tesl-decode-prim-dict))
(define tesl-json-set-codec          (cons tesl-encode-prim-set          tesl-decode-prim-set))

;; Encode a single field value using a codec-spec.
;; codec-spec: either a primitive (cons encode decode) or a type-name symbol
(define (tesl-codec-encode-field value codec-spec)
  (cond
    [(pair? codec-spec)
     ((car codec-spec) value)]
    [(symbol? codec-spec)
     (define entry (hash-ref type-codec-registry codec-spec #f))
     (if entry
         ((car entry) value)
         (runtime-value->jsexpr value))]
    [else (runtime-value->jsexpr value)]))

;; Look up `json-key` in `jsexpr`, raising the localized 'codec missing-field
;; error if absent.  SINGLE SOURCE of the missing-field error string, shared by
;; every decode path (generic primitive, generic user-type, and the emitter's
;; inlined specialized primitive decoder via tesl-decode-prim-field).
(define (jsexpr-required-field jsexpr json-key)
  (define raw (jsexpr-object-ref jsexpr json-key 'TESL-MISSING))
  (when (eq? raw 'TESL-MISSING)
    (raise-user-error 'codec "required field \"~a\" not found in JSON" json-key))
  raw)

;; Decode a PRIMITIVE field from a JSON object: (1) the missing-field check
;; (the shared localized 'codec error) and (2) the primitive type-mismatch
;; decode via the supplied `prim-decoder` (one of the `tesl-decode-prim-*`
;; helpers above).  The type-mismatch error string is owned by `prim-decoder`;
;; the missing-field string by `jsexpr-required-field`.  The generic
;; `tesl-codec-decode-field` routes its primitive (pair codec-spec) branch
;; through here, and the emitter inlines DIRECT calls to this from a type's
;; specialized decoder — so the inlined path and the generic path produce
;; byte-identical decoded values AND byte-identical error text on every branch
;; (missing field, wrong primitive type) by construction.
(define (tesl-decode-prim-field jsexpr json-key prim-decoder)
  (prim-decoder (jsexpr-required-field jsexpr json-key)))

;; Decode a field from a JSON object using a codec-spec.
;; jsexpr: JSON hash  json-key: string  codec-spec: pair or type-name symbol
(define (tesl-codec-decode-field jsexpr json-key codec-spec)
  (cond
    [(pair? codec-spec)
     ;; Primitive: missing-field check + type-mismatch decode share ONE
     ;; definition with the inlined specialized path (tesl-decode-prim-field).
     (tesl-decode-prim-field jsexpr json-key (cdr codec-spec))]
    [(symbol? codec-spec)
     (tesl-type-codec-decode codec-spec (jsexpr-required-field jsexpr json-key))]
    [else
     (jsexpr-required-field jsexpr json-key)]))


(define-adt (Maybe value)
  [Nothing]
  [Something value])

(define-adt (Result value error)
  [Ok value]
  [Err error])

(define-adt (DeleteResult)
  [NoRowDeleted]
  [RowsDeleted count])
