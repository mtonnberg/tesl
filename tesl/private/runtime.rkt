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
         tesl-cli-args
         tesl-lookup-port-argument
         tesl-int-parse
         tesl-request-cookie
         tesl-generate-prefixed-id
         tesl-test-make-proof
         tesl-test-proof-field)

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

(define (tesl-cli-args)
  (vector->list (current-command-line-arguments)))

(define (tesl-lookup-port-argument [args (tesl-cli-args)])
  (let loop ([remaining args])
    (cond
      [(null? remaining) Nothing]
      [(string-prefix? (car remaining) "--port=")
       (Something (substring (car remaining) (string-length "--port=")))]
      [(equal? (car remaining) "--port")
       (cond
         [(null? (cdr remaining))
          (raise-user-error 'tesl "`--port` requires a value")]
         [else
          (Something (cadr remaining))])]
      [else
       (loop (cdr remaining))])))

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
