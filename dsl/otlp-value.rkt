#lang racket

;;; The ONE OTLP attribute-value renderer, shared by every signal.
;;;
;;; Extracted from dsl/otel.rkt when the Traces signal (dsl/traces.rkt) arrived.
;;; The reason it is one module and not one copy per signal is `secret`: an OTLP
;;; attribute value is a RENDERING sink, so every signal that formats one has to
;;; redact, and roadmap/completed/otel_trace_support.md names the failure mode
;;; exactly — "spans become the one sink that leaks a `secret` column".  A signal that
;;; formats its own values is a redaction hole waiting to be added; a signal that
;;; calls this module cannot be.
;;;
;;; dsl/otel.rkt re-provides `telemetry-value->jsexpr` and
;;; `telemetry-value->otlp-any-value` under their historical names, so the
;;; `secret` structural-redaction suite keeps measuring them where it always did.
;;;
;;; Dependency direction: requires only json + dsl/types.rkt (which requires
;;; nothing but dsl/private/*), so every signal module can require it.

(require json
         (only-in "types.rkt"
                  secret-value? secret-header-value? secret-redaction-text
                  current-redact-secrets? runtime-value->jsexpr
                  record-value? adt-value? newtype-value?))

(provide telemetry-key->json-key
         telemetry-value->jsexpr
         telemetry-value->otlp-any-value
         attributes->otlp-key-values
         ms->nano-string)

(define (telemetry-key->json-key key)
  (cond
    [(symbol? key) key]
    [(keyword? key) (string->symbol (keyword->string key))]
    [(bytes? key) (string->symbol (bytes->string/utf-8 key))]
    [(string? key) (string->symbol key)]
    [else (string->symbol (~a key))]))

(define (telemetry-value->jsexpr value)
  (cond
    ;; ── Redaction, FIRST ──────────────────────────────────────────────────
    ;; Telemetry is a rendering sink, and this walk is structural (hash / list /
    ;; vector recurse through this same function), so asking the question here —
    ;; at every node — is what makes a secret nested in a record inside a List
    ;; inside a Maybe redact while its siblings render normally.
    [(secret-value? value) secret-redaction-text]
    [(secret-header-value? value) secret-redaction-text]
    [(hash? value)
     (for/hash ([(key item) (in-hash value)])
       (values (telemetry-key->json-key key)
               (telemetry-value->jsexpr item)))]
    [(list? value)
     (map telemetry-value->jsexpr value)]
    [(vector? value)
     (list->vector (map telemetry-value->jsexpr (vector->list value)))]
    [(symbol? value)
     (symbol->string value)]
    [(keyword? value)
     (keyword->string value)]
    [(bytes? value)
     (bytes->string/utf-8 value)]
    ;; Tesl VALUE STRUCTS (record / ADT / newtype, and everything reachable from
    ;; them) had no arm here and fell through `[else value]`, so a record-valued
    ;; telemetry attribute produced a raw struct — not a jsexpr at all.  Delegate
    ;; to the ONE total structural walk, with redaction switched ON for this
    ;; sink; the parameterize covers every node it reaches, including the
    ;; siblings of a redacted secret, which still render normally.
    [(or (record-value? value) (adt-value? value) (newtype-value? value))
     (parameterize ([current-redact-secrets? #t])
       (runtime-value->jsexpr value))]
    [else value]))

;; Convert one Tesl attribute value to an OTLP AnyValue jsexpr.  OTLP KeyValue
;; values are tagged unions: booleans → boolValue, exact integers → intValue
;; (as a STRING per the OTLP/JSON int64 convention), other reals → doubleValue,
;; everything else → stringValue (reusing telemetry-value->jsexpr's coercion for
;; symbols/keywords/bytes, then stringifying).  Bool is checked before number
;; because in Racket booleans are not numbers, but we make the ordering explicit.
(define (telemetry-value->otlp-any-value value)
  (cond
    ;; Its OWN guard, not just the shared coercion's: the string?/boolean?/
    ;; integer? arms below short-circuit before delegating, so a redaction check
    ;; that lived only in telemetry-value->jsexpr would be bypassed here.
    [(or (secret-value? value) (secret-header-value? value))
     (hash 'stringValue secret-redaction-text)]
    [(boolean? value) (hash 'boolValue value)]
    [(exact-integer? value) (hash 'intValue (number->string value))]
    [(and (real? value) (rational? value)) (hash 'doubleValue (exact->inexact value))]
    [(string? value) (hash 'stringValue value)]
    [else
     ;; Reuse the console serializer's coercion (symbol/keyword/bytes/list/hash),
     ;; then render any non-string result as a JSON string so the AnyValue stays
     ;; well-formed regardless of the attribute's runtime shape.
     (define coerced (telemetry-value->jsexpr value))
     (hash 'stringValue (if (string? coerced) coerced (jsexpr->string coerced)))]))

;; Build the OTLP KeyValue list for one attribute assoc list.
(define (attributes->otlp-key-values attributes)
  (for/list ([entry (in-list attributes)])
    (hash 'key (symbol->string (telemetry-key->json-key (car entry)))
          'value (telemetry-value->otlp-any-value (cdr entry)))))

;; Epoch milliseconds → the OTLP/JSON epoch-nanoseconds decimal STRING (int64).
(define (ms->nano-string ms)
  (number->string (inexact->exact (round (* ms 1000000.0)))))
