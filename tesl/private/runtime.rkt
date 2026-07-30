#lang racket
(require racket/string
         racket/random
         "../../dsl/types.rkt"
         (only-in "../../dsl/private/evidence.rkt" detached-proof)
         (only-in "../../dsl/private/check-runtime.rkt"
                  ensure-named named-value-name named-value-value named-value? attach
                  raw-value facts-of)
         "../../dsl/web.rkt")

(provide tesl-env
         tesl-env-raw
         tesl-env-string-raw
         tesl-env-int
         tesl-env-int-raw
         tesl-int-parse
         tesl-request-cookie
         tesl-generate-prefixed-id
         tesl-test-make-proof
         tesl-test-proof-field
         tesl-equal?
         tesl-lt? tesl-le? tesl-gt? tesl-ge?)

;; tesl-equal? — the fail-closed backstop for the `==`/`!=` operators (Eq/Ord
;; Stage-2 runtime guard).  A well-typed program never reaches here with a
;; function operand: the checker rejects a ground function comparison, and the
;; generic-comparison hole is closed statically (Eq/Ord constraint threading).
;; This guard exists only to turn a hypothetical checker BUG into a VISIBLE
;; error instead of `equal?`'s silent reference-identity result on procedures
;; (`(equal? f g)` → #f with no error — the one silent-wrong-answer case).
;;
;; It is deliberately a TOP-LEVEL operand check, not a deep structural scan.
;; A deep scan would have to walk transparent Tesl value structs, whose internal
;; metadata (e.g. a record-field-spec `checker`) can itself be a procedure — so a
;; deep "contains a procedure?" walk would FALSE-POSITIVE and crash valid record
;; equality.  Completeness for functions hidden inside composites is provided by
;; the static layer (which rejects them), not by this runtime guard.  Delegates
;; to `equal?` for the actual comparison so all structural semantics are
;; unchanged for every non-function value.
;; SECRET `==`.  `secret X = T` keeps Eq (unlike PasswordHash/Signature, whose
;; only legitimate comparison IS a verification) and lowers it to a
;; CONSTANT-TIME compare: `==` is the sanctioned way to check a secret, so an
;; early-exit `equal?` here would hand an attacker a byte-at-a-time oracle.
;; This is the single point — every `==`/`!=` in generated code routes here.
;; The compare is by (type-name, payload): two DIFFERENT secret types can never
;; be compared in a well-typed program (unify is nominal), so the type-name
;; check is a cheap non-secret discriminator, and only the payloads go through
;; the timing-safe path.
(define (tesl-equal? a b)
  (when (or (procedure? a) (procedure? b))
    (raise-user-error
     'comparison
     "functions cannot be compared for equality (== / !=); this indicates a checker bug — please report it"))
  (cond
    [(or (secret-value? a) (secret-value? b))
     (and (secret-value? a) (secret-value? b)
          (equal? (newtype-value-type-name a) (newtype-value-type-name b))
          (secret-constant-time-equal? (newtype-value-value a)
                                       (newtype-value-value b)))]
    [else (equal? a b)]))

(define (empty-string->false value)
  (if (and (string? value) (string=? (string-trim value) ""))
      #f
      value))

(define (tesl-env-raw name)
  (empty-string->false (getenv name)))

(define (tesl-env name)
  (define raw (tesl-env-raw name))
  (if raw
      (Something raw)
      Nothing))

;; envString: read an env var as a String, falling back to `default` when the
;; variable is unset or empty.  (Required, fail-fast reads use tesl-env-raw via
;; the config-block emitter; this is the with-default variant.)
(define (tesl-env-string-raw name default)
  (or (tesl-env-raw name) default))

(define (parse-integer-env name raw who)
  (define maybe-int (and raw (string->number raw)))
  (unless (and maybe-int (integer? maybe-int))
    (raise-user-error who
                      (format "invalid integer environment value ~a=~a"
                              name
                              raw)))
  maybe-int)

(define (tesl-env-int-raw name default)
  (define raw (tesl-env-raw name))
  (if raw
      (parse-integer-env name raw 'tesl-env-int)
      default))

(define (tesl-env-int name default)
  (define raw (tesl-env-raw name))
  (if raw
      (Something (parse-integer-env name raw 'tesl-env-int))
      Nothing))

(define (tesl-int-parse raw)
  (define maybe-int (and raw (string->number raw)))
  (if (and maybe-int (integer? maybe-int))
      (Something maybe-int)
      Nothing))

(define (tesl-request-cookie req key)
  (define cookie-header (or (request-header req "cookie" "") ""))
  (define maybe-value
    (for/first ([part (in-list (map string-trim (string-split cookie-header ";")))]
                #:when (string-prefix? part (format "~a=" key)))
      (substring part (+ 1 (string-length key)))))
  (if maybe-value
      (Something maybe-value)
      Nothing))

(define (tesl-generate-prefixed-id prefix)
  ;; Unguessable id: CSPRNG bytes rendered as hex.  The previous
  ;; `(current-seconds)` + `(random 1000000)` form was predictable/brute-forceable
  ;; (≤1e6 values per second), unsafe if an id is used as a token.  Mirrors the
  ;; crypto-random-bytes discipline in tesl/uuid.rkt.
  (define (byte->hex b)
    (define s (number->string b 16))
    (if (= (string-length s) 1) (string-append "0" s) s))
  (string-append prefix "-"
                 (apply string-append
                        (map byte->hex (bytes->list (crypto-random-bytes 16))))))

;; Test-only: create a named value with proof attached for property-based test generators.
;; This bypasses the normal trusted-proof boundary; it must only be used in test contexts.
(define (tesl-test-make-proof fact bindings)
  (detached-proof fact bindings))

;; Test-only: create a record field value with a fabricated proof.
;; given a field-name symbol, a raw value, and a proof-datum template,
;; returns a named value with the proof instantiated using the generated subject.
(define (tesl-test-proof-field field-name raw-value proof-datum)
  (define named (ensure-named field-name raw-value))
  (define subj (named-value-name named))
  (define instantiated-fact
    (instantiate-proof-template/runtime proof-datum (hash field-name subj)))
  (attach named (list (detached-proof instantiated-fact (hash subj (named-value-value named))))))

;; ── Ordered comparison: <  <=  >  >= ────────────────────────────────────────
;;
;; THE BUG THIS FIXES.  `Checker.ty_is_ord` admits `TCon ("Int"|"Float"|
;; "PosixMillis")` and every dimensioned quantity, but generated code used to
;; emit a BARE Racket `<`.  A `PosixMillis` is a `newtype-value` at runtime
;; (`tesl/time.rkt` wraps it — both `nowMillis` and `secondsToPosix` do), and
;; `raw-value` deliberately does NOT strip a newtype wrapper (the SQL layer
;; depends on that).  So `t1 < t2` on two timestamps typechecked and then died
;; with `<: contract violation; expected: real?  given: (newtype-value … )`.
;;
;; The language therefore advertised an ordering it could not perform. This is
;; issue #28's class at a second site: that issue fixed `>=`/`<=` on a newtype
;; column inside a SQL where-clause (`unwrap-non-null` in dsl/sql.rkt did not
;; strip `newtype-value` while `==` did) — the identical gap existed on the plain
;; expression path and was never closed, because `==` routes through
;; `tesl-equal?` (which unwraps) while the ordered operators did not route
;; anywhere at all.
;;
;; Fail-closed like `tesl-equal?`: a non-real operand raises a named error rather
;; than reaching Racket's contract check, so a future checker bug is a legible
;; message instead of a bare contract violation.
(define (tesl-ord-operand who v)
  (define u (if (newtype-value? v) (newtype-value-value v) v))
  (unless (real? u)
    (raise-user-error
     who
     (string-append
      "ordered comparison needs a number, got ~e. This is a compiler bug: the "
      "checker only admits Int, Float, PosixMillis and dimensioned quantities "
      "here, so reaching this point means an unordered type slipped through "
      "`ty_is_ord`. Please report it.")
     u))
  u)

(define (tesl-lt? a b) (< (tesl-ord-operand 'tesl-lt? a) (tesl-ord-operand 'tesl-lt? b)))
(define (tesl-le? a b) (<= (tesl-ord-operand 'tesl-le? a) (tesl-ord-operand 'tesl-le? b)))
(define (tesl-gt? a b) (> (tesl-ord-operand 'tesl-gt? a) (tesl-ord-operand 'tesl-gt? b)))
(define (tesl-ge? a b) (>= (tesl-ord-operand 'tesl-ge? a) (tesl-ord-operand 'tesl-ge? b)))
