#lang racket

;;; W3C trace-context tests (dsl/trace-context.rkt + the Phase-A wiring).
;;;
;;; Phase A of roadmap/completed/otel_trace_support.md exports no spans; what it
;;; promises is narrower and entirely testable offline:
;;;
;;;   1. PARSE/FORMAT — `traceparent` is attacker-controlled input, so the parser
;;;      must be TOTAL over arbitrary strings: every malformed shape answers #f
;;;      (start a fresh trace) and NOTHING raises.
;;;   2. IDS — 16/8 crypto-random bytes as lowercase hex, never all-zero.  This is
;;;      the weakness `request.id` has (`(random 1000000)`, identically seeded per
;;;      replica) and the reason trace ids are not derived from it.
;;;   3. SAMPLING — parent-respecting: an inbound decision is never overridden,
;;;      whatever `traceRatio` says.
;;;   4. LOG CORRELATION — every telemetry event gains trace.id/span.id/
;;;      trace.sampled with no new call sites, and the OTLP log record LIFTS them
;;;      into the first-class traceId/spanId/flags fields a collector joins on.
;;;   5. OUTBOUND PROPAGATION — every HttpClient verb carries `traceparent`
;;;      (+ inbound `tracestate`), and a caller-supplied one is never overwritten.
;;;
;;; Run:  raco test tests/trace-context-test.rkt

(require rackunit
         json
         (only-in "../dsl/capability.rkt" current-capabilities)
         "../dsl/trace-context.rkt"
         (only-in "../dsl/otel.rkt"
                  init-opentelemetry! telemetry-event! drain-telemetry!
                  telemetry-event-attributes
                  telemetry-events->otlp-logs-jsexpr)
         (only-in "../tesl/http-client.rkt" httpClient HttpClient.get HttpClient.post)
         (only-in "../tesl/private/http-stub.rkt" current-outbound-http-hook))

(define SAMPLE-TP "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")

;;; ── 1. PARSE ─────────────────────────────────────────────────────────────────

(test-case "a valid version-00 traceparent parses, sampled flag and all"
  (define ctx (parse-traceparent SAMPLE-TP))
  (check-pred trace-ctx? ctx)
  (check-equal? (trace-ctx-trace-id ctx) "4bf92f3577b34da6a3ce929d0e0e4736")
  (check-equal? (trace-ctx-span-id ctx) "00f067aa0ba902b7")
  (check-true (trace-ctx-sampled? ctx))
  (check-true (trace-ctx-remote-parent? ctx)
              "the parsed span-id is the CALLER's span, so it may be a parent"))

(test-case "flags 00 means not sampled"
  (check-false (trace-ctx-sampled?
                (parse-traceparent
                 "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00"))))

(test-case "surrounding whitespace is tolerated"
  (check-pred trace-ctx? (parse-traceparent (string-append "  " SAMPLE-TP "\t"))))

(test-case "every malformed shape answers #f and never raises"
  (for ([bad (in-list
              (list ""
                    "garbage"
                    "00"
                    "00-4bf92f3577b34da6a3ce929d0e0e4736"
                    ;; too-short / too-long ids
                    "00-4bf92f3577b34da6a3ce929d0e0e473-00f067aa0ba902b7-01"
                    "00-4bf92f3577b34da6a3ce929d0e0e47366-00f067aa0ba902b7-01"
                    "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b-01"
                    ;; UPPERCASE hex is invalid per the recommendation
                    "00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01"
                    ;; non-hex characters
                    "00-4bf92f3577b34da6a3ce929d0e0e473g-00f067aa0ba902b7-01"
                    ;; all-zero ids are invalid
                    "00-00000000000000000000000000000000-00f067aa0ba902b7-01"
                    "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01"
                    ;; version ff is reserved/invalid
                    "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
                    ;; version 00 must have EXACTLY four fields
                    "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra"
                    ;; empty fields
                    "00--00f067aa0ba902b7-01"
                    ;; malformed flags
                    "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-0"
                    "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-zz"))])
    (check-false (parse-traceparent bad) (format "must reject ~s" bad))))

(test-case "non-string input is rejected, not raised on"
  (check-false (parse-traceparent #f))
  (check-false (parse-traceparent 42))
  (check-false (parse-traceparent '("00" "aa"))))

(test-case "an UNKNOWN FUTURE version is accepted with extra fields ignored"
  ;; The W3C forward-compatibility rule.  Dropping it would make us the service
  ;; that breaks every trace the day a version 01 exists.
  (define ctx (parse-traceparent
               "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-somethingnew"))
  (check-pred trace-ctx? ctx)
  (check-equal? (trace-ctx-trace-id ctx) "4bf92f3577b34da6a3ce929d0e0e4736"))

;;; ── 2. IDS + FORMAT ──────────────────────────────────────────────────────────

(test-case "ids are lowercase hex of the right length, and distinct"
  (define t (new-trace-id))
  (define s (new-span-id))
  (check-equal? (string-length t) 32)
  (check-equal? (string-length s) 16)
  (check-true (regexp-match? #rx"^[0-9a-f]+$" t))
  (check-true (regexp-match? #rx"^[0-9a-f]+$" s))
  ;; crypto-random, so a collision across 200 draws would be a real defect
  (check-equal? (length (remove-duplicates (for/list ([_ 200]) (new-trace-id)))) 200))

(test-case "format is version-00 and round-trips through parse"
  (define ctx (parse-traceparent SAMPLE-TP))
  (check-equal? (format-traceparent ctx) SAMPLE-TP)
  (define back (parse-traceparent (format-traceparent ctx)))
  (check-equal? (trace-ctx-trace-id back) (trace-ctx-trace-id ctx))
  (check-equal? (trace-ctx-span-id back) (trace-ctx-span-id ctx)))

(test-case "an unsampled context formats with flags 00"
  (define ctx (trace-ctx "4bf92f3577b34da6a3ce929d0e0e4736" "00f067aa0ba902b7" #f #f #t))
  (check-equal? (format-traceparent ctx)
                "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00"))

(test-case "tracestate is shape-gated (length, printable ASCII, no CR/LF)"
  (check-true (valid-tracestate? "congo=t61rcWkgMzE"))
  (check-false (valid-tracestate? ""))
  (check-false (valid-tracestate? #f))
  (check-false (valid-tracestate? (make-string 513 #\a)))
  (check-false (valid-tracestate? "congo=t61\r\nX-Injected: 1")))

;;; ── 3. SAMPLING ──────────────────────────────────────────────────────────────

(test-case "ratio endpoints are exact"
  (check-false (sampled-by-ratio? 0.0))
  (check-true (sampled-by-ratio? 1.0))
  (check-false (sampled-by-ratio? -1.0))
  (check-true (sampled-by-ratio? 2.0)))

(test-case "a ratio in between samples SOME but not all"
  (define hits (for/sum ([_ 400]) (if (sampled-by-ratio? 0.5) 1 0)))
  (check-true (< 100 hits 300) (format "0.5 over 400 draws gave ~a" hits)))

(test-case "an inbound decision is RESPECTED, whatever the local ratio says"
  ;; parent-respecting head sampling: this is what keeps a distributed trace whole
  (define kept
    (make-root-trace-ctx #:traceparent SAMPLE-TP #:ratio 0.0))
  (check-true (trace-ctx-sampled? kept) "inbound 01 wins over ratio 0.0")
  (define dropped
    (make-root-trace-ctx
     #:traceparent "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00"
     #:ratio 1.0))
  (check-false (trace-ctx-sampled? dropped) "inbound 00 wins over ratio 1.0"))

(test-case "a continued trace keeps the caller's trace id and tracestate"
  (define ctx (make-root-trace-ctx #:traceparent SAMPLE-TP
                                   #:tracestate "congo=t61rcWkgMzE"))
  (check-equal? (trace-ctx-trace-id ctx) "4bf92f3577b34da6a3ce929d0e0e4736")
  (check-equal? (trace-ctx-tracestate ctx) "congo=t61rcWkgMzE")
  (check-true (trace-ctx-remote-parent? ctx)))

(test-case "a malformed tracestate is DROPPED, not sanitized or propagated"
  (define ctx (make-root-trace-ctx #:traceparent SAMPLE-TP
                                   #:tracestate "bad=\r\nX-Injected: 1"))
  (check-false (trace-ctx-tracestate ctx)))

(test-case "with no inbound header a fresh trace is minted; ids differ per request"
  (define a (make-root-trace-ctx))
  (define b (make-root-trace-ctx))
  (check-equal? (string-length (trace-ctx-trace-id a)) 32)
  (check-false (trace-ctx-remote-parent? a)
               "a locally minted span-id is NOT a usable parent")
  (check-not-equal? (trace-ctx-trace-id a) (trace-ctx-trace-id b)))

(test-case "the sampled bit is a PROPAGATION decision, not `will we export a span`"
  ;; Span export off (the default) must NOT stamp flags 00 on the way out: a Tesl
  ;; app in the path would then tell every parent-respecting service downstream to
  ;; drop the trace too, silencing other teams' tracing by being in the middle.
  ;; The ratio decides; whether WE record is dsl/traces.rkt's separate question.
  (set-trace-sample-ratio! 1.0)
  (define ctx (make-root-trace-ctx #:ratio (trace-sample-ratio)))
  (check-equal? (string-length (trace-ctx-trace-id ctx)) 32
                "correlation works with span export off — that is the point")
  (check-true (trace-ctx-sampled? ctx))
  ;; …and an explicit traceRatio 0 does suppress it downstream, as consistent head
  ;; sampling requires.
  (check-false (trace-ctx-sampled? (make-root-trace-ctx #:ratio 0.0))))

(test-case "the ratio box clamps instead of raising (deployment config, emit path)"
  (set-trace-sample-ratio! 0.25)
  (check-equal? (trace-sample-ratio) 0.25)
  (set-trace-sample-ratio! -3)
  (check-equal? (trace-sample-ratio) 0.0)
  (set-trace-sample-ratio! 99)
  (check-equal? (trace-sample-ratio) 1.0)
  (set-trace-sample-ratio! "nonsense")
  (check-equal? (trace-sample-ratio) 1.0))

;;; ── 4. LOG CORRELATION ───────────────────────────────────────────────────────

(test-case "with no ambient context the attribute list is EMPTY"
  ;; A process that never sees a request must emit byte-identical telemetry to
  ;; what it emitted before traces existed.
  (check-equal? (trace-context-attributes) '())
  (init-opentelemetry! #:service-name "corr" #:endpoint "in-memory")
  (void (drain-telemetry!))
  (telemetry-event! "no trace here")
  (define ev (last (drain-telemetry!)))
  (check-false (assq 'trace.id (telemetry-event-attributes ev))))

(test-case "every event inside a trace context gains trace.id/span.id/trace.sampled"
  (init-opentelemetry! #:service-name "corr" #:endpoint "in-memory")
  (void (drain-telemetry!))
  (define ctx (make-root-trace-ctx #:traceparent SAMPLE-TP))
  (call-with-trace-ctx ctx (lambda () (telemetry-event! "note created")))
  (define attrs (telemetry-event-attributes (last (drain-telemetry!))))
  (check-equal? (cdr (assq 'trace.id attrs)) "4bf92f3577b34da6a3ce929d0e0e4736")
  (check-equal? (cdr (assq 'span.id attrs)) "00f067aa0ba902b7")
  (check-equal? (cdr (assq 'trace.sampled attrs)) #t))

(test-case "the INNERMOST span wins: a child span rebinds span.id, not trace.id"
  (init-opentelemetry! #:service-name "corr" #:endpoint "in-memory")
  (void (drain-telemetry!))
  (call-with-trace-ctx
   (make-root-trace-ctx #:traceparent SAMPLE-TP)
   (lambda ()
     (call-with-child-span-id "aaaaaaaaaaaaaaaa"
                              (lambda () (telemetry-event! "inside a child")))))
  (define attrs (telemetry-event-attributes (last (drain-telemetry!))))
  (check-equal? (cdr (assq 'trace.id attrs)) "4bf92f3577b34da6a3ce929d0e0e4736")
  (check-equal? (cdr (assq 'span.id attrs)) "aaaaaaaaaaaaaaaa"))

(test-case "the OTLP log record LIFTS trace ids into traceId/spanId/flags"
  ;; Attributes alone would show in a UI but would not CORRELATE — the join is on
  ;; the first-class LogRecord fields.
  (init-opentelemetry! #:service-name "corr" #:endpoint "in-memory")
  (void (drain-telemetry!))
  (call-with-trace-ctx (make-root-trace-ctx #:traceparent SAMPLE-TP)
                       (lambda () (telemetry-event! "joinable")))
  (define j (telemetry-events->otlp-logs-jsexpr (drain-telemetry!)))
  (define rec
    (last (hash-ref (first (hash-ref (first (hash-ref j 'resourceLogs)) 'scopeLogs))
                    'logRecords)))
  (check-equal? (hash-ref rec 'traceId) "4bf92f3577b34da6a3ce929d0e0e4736")
  (check-equal? (hash-ref rec 'spanId) "00f067aa0ba902b7")
  (check-equal? (hash-ref rec 'flags) 1)
  (check-not-exn (lambda () (string->jsexpr (jsexpr->string j)))))

(test-case "a record emitted outside a trace has NO traceId field at all"
  (init-opentelemetry! #:service-name "corr" #:endpoint "in-memory")
  (void (drain-telemetry!))
  (telemetry-event! "untraced")
  (define j (telemetry-events->otlp-logs-jsexpr (drain-telemetry!)))
  (define rec
    (last (hash-ref (first (hash-ref (first (hash-ref j 'resourceLogs)) 'scopeLogs))
                    'logRecords)))
  (check-false (hash-ref rec 'traceId #f)))

;;; ── 5. OUTBOUND PROPAGATION ──────────────────────────────────────────────────
;;;
;;; The outbound test double (`current-outbound-http-hook`) sees the header list
;;; the client is about to send, so this pins propagation without a network.

(define (headers-of-outbound-call thunk)
  (define seen (box #f))
  (parameterize ([current-capabilities (list httpClient)]
                 [current-outbound-http-hook
                  (lambda (_mode _method _url headers _body)
                    (set-box! seen headers)
                    (hash 'status 200 'body "" 'headers '()))])
    (thunk))
  (unbox seen))

(define (header-value headers name)
  (for/or ([h (in-list headers)])
    (and (list? h) (= (length h) 2)
         (string? (first h))
         (string-ci=? (first h) name)
         (second h))))

(test-case "an outbound call carries traceparent from the ambient context"
  (define ctx (make-root-trace-ctx #:traceparent SAMPLE-TP))
  (define headers
    (call-with-trace-ctx
     ctx
     (lambda ()
       (headers-of-outbound-call
        (lambda () (HttpClient.get "https://billing.internal/invoice/42" '()))))))
  (check-equal? (header-value headers "traceparent")
                (format-traceparent ctx)
                "the downstream service continues OUR trace")
  (check-true (regexp-match? #rx"^00-4bf92f3577b34da6a3ce929d0e0e4736-"
                             (header-value headers "traceparent"))))

(test-case "an inbound tracestate rides along, unmodified"
  (define headers
    (call-with-trace-ctx
     (make-root-trace-ctx #:traceparent SAMPLE-TP #:tracestate "congo=t61rcWkgMzE")
     (lambda ()
       (headers-of-outbound-call
        (lambda () (HttpClient.post "https://x.internal/y" '() "{}"))))))
  (check-equal? (header-value headers "tracestate") "congo=t61rcWkgMzE"))

(test-case "a CALLER-SUPPLIED traceparent WINS and is never overwritten"
  (define mine "00-11111111111111111111111111111111-2222222222222222-01")
  (define headers
    (call-with-trace-ctx
     (make-root-trace-ctx #:traceparent SAMPLE-TP #:tracestate "congo=t61")
     (lambda ()
       (headers-of-outbound-call
        (lambda () (HttpClient.get "https://x.internal/y"
                                   (list (list "traceparent" mine))))))))
  (check-equal? (header-value headers "traceparent") mine)
  (check-false (header-value headers "tracestate")
               "tracestate belongs to the traceparent it travels with"))

(test-case "with no ambient trace nothing is injected"
  (define headers
    (headers-of-outbound-call
     (lambda () (HttpClient.get "https://x.internal/y" '()))))
  (check-false (header-value headers "traceparent")))

(test-case "existing headers are preserved alongside the injected ones"
  (define headers
    (call-with-trace-ctx
     (make-root-trace-ctx #:traceparent SAMPLE-TP)
     (lambda ()
       (headers-of-outbound-call
        (lambda () (HttpClient.get "https://x.internal/y"
                                   (list (list "x-custom" "kept"))))))))
  (check-equal? (header-value headers "x-custom") "kept")
  (check-true (string? (header-value headers "traceparent"))))
