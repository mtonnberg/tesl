#lang racket

(require json
         racket/runtime-path
         (only-in "private/domain-registry.rkt" register-background-thread!)
         ;; #22: install the framework-log -> telemetry bridge sink. logging.rkt
         ;; requires nothing, so this one-way edge introduces no require cycle.
         (only-in "../tesl/logging.rkt" set-telemetry-log-sink!)
         ;; Metrics signal (roadmap/next/opentelemetry_metrics.md): registry +
         ;; /v1/metrics exporter live in dsl/metrics.rkt (requires nothing of
         ;; ours, so no cycle); init-opentelemetry! is the single on/off switch.
         (only-in "metrics.rkt"
                  set-metrics-enabled! reset-metrics!
                  start-metrics-exporter! stop-metrics-exporter!
                  metrics-active? metric-counter-add!)
         ;; Traces signal (roadmap/completed/otel_trace_support.md).  Phase A —
         ;; trace-context.rkt — is what stamps trace.id/span.id onto every event
         ;; below; Phase B — traces.rkt — is span export, off unless asked for.
         ;; Neither requires anything of ours that could cycle back.
         (only-in "trace-context.rkt"
                  trace-context-attributes set-trace-sample-ratio! current-trace-ctx)
         (only-in "traces.rkt"
                  set-traces-enabled! reset-traces!
                  start-traces-exporter! stop-traces-exporter!)
         ;; The ONE OTLP attribute-value renderer (redaction included), shared
         ;; with dsl/traces.rkt so spans cannot become a sink that skips it.
         (only-in "otlp-value.rkt"
                  telemetry-key->json-key
                  telemetry-value->jsexpr
                  telemetry-value->otlp-any-value
                  attributes->otlp-key-values)
         (for-syntax racket/base syntax/parse))

(provide
 (struct-out telemetry-event)
 current-telemetry-context
 current-telemetry-events
 current-telemetry-service-name
 current-telemetry-endpoint
 current-telemetry-consumers
 make-console-telemetry-consumer
 make-otlp-http-consumer
 parse-otlp-headers-env
 merge-otlp-headers
 telemetry-events->otlp-logs-jsexpr
 telemetry-value->otlp-any-value
 ;; The console/consumer attribute serializer, exported so the `secret`
 ;; structural-redaction suite can measure it directly (a secret must redact at
 ;; every node of this walk while its siblings render normally).
 telemetry-value->jsexpr
 init-opentelemetry!
 call-with-telemetry-context
 telemetry-event!
 log-info!
 drain-telemetry!)

(struct telemetry-event (service-name endpoint message attributes timestamp-ms) #:transparent)

(define current-telemetry-context (make-parameter '()))
(define current-telemetry-events (make-parameter '()))
(define current-telemetry-service-name (make-parameter "tesl"))
(define current-telemetry-endpoint (make-parameter #f))
(define current-telemetry-consumers (make-parameter '()))
(define global-telemetry-log (box '()))

;; telemetry-key->json-key / telemetry-value->jsexpr / the OTLP AnyValue mapping
;; now live in dsl/otlp-value.rkt — ONE renderer for all three signals, so the
;; Traces sink cannot skip the `secret` redaction this walk performs.  They are
;; re-provided from here under their historical names.

(define (telemetry-event->jsexpr event)
  (hash 'service (telemetry-event-service-name event)
        'endpoint (or (telemetry-event-endpoint event) "")
        'message (telemetry-event-message event)
        'timestampMs (telemetry-event-timestamp-ms event)
        'attributes
        (for/hash ([entry (in-list (telemetry-event-attributes event))])
          (values (telemetry-key->json-key (car entry))
                  (telemetry-value->jsexpr (cdr entry))))))

(define (make-console-telemetry-consumer #:port [port (current-error-port)])
  (lambda (event)
    (displayln (jsexpr->string (telemetry-event->jsexpr event)) port)
    (flush-output port)))

;; ── OTLP/HTTP+JSON Logs exporter ──────────────────────────────────────────────
;;
;; A real telemetry exporter that ships events to a configured collector over
;; OTLP/HTTP+JSON.  THIS exporter is the Logs signal only — the flat event model
;; has no start/end pair, so Logs is its natural mapping (see the otlp_exporter
;; roadmap item).  The sibling signals live beside it: dsl/metrics.rkt
;; (/v1/metrics) and dsl/traces.rkt (/v1/traces, spans, off by default).
;; gRPC/protobuf remains a non-goal.
;;
;; SINGLE POST PATH.  The POST goes through tesl/http-client.rkt's `HttpClient.post`
;; — the same client every other outbound HTTP call uses — via `dynamic-require`
;; so dsl/otel.rkt takes no load-time dependency on the net/capability machinery
;; (and so telemetry with only a console consumer never touches net code).
;;
;; AMBIENT EGRESS.  Telemetry is the deliberate ambient exception (LANGUAGE-SPEC
;; §5.2): no capability is required to emit.  Because `HttpClient.post` guards on
;; the `httpClient` capability, the exporter grants it ambiently for the POST only
;; (by setting current-capabilities directly) — the egress is opt-in purely by the
;; PRESENCE of a configured endpoint, not by a user-declared capability.
;;
;; ASYNC + BOUNDED + RESILIENT.  Events are appended to a bounded in-memory queue.
;; A background timer thread flushes every `flush-interval-ms`; a full batch
;; (`batch-size` events) is flushed immediately by signalling the flusher.  The
;; POST is wrapped so an unreachable/erroring collector NEVER propagates — the
;; emit path is never blocked and never raised through.  On queue overflow the
;; DROP POLICY is DROP-OLDEST: the newest event is always retained (freshest
;; observability data), the oldest buffered-but-unflushed event is discarded.

;; Resolve http-client.rkt relative to THIS source file (dsl/otel.rkt sits in
;; dsl/, http-client.rkt in the sibling tesl/), matching tesl/agent-provider.rkt.
(define-runtime-path otlp-http-client-source "../tesl/http-client.rkt")

;; Pure, unit-testable mapping: a list of telemetry-event → one OTLP/HTTP+JSON
;; ExportLogsServiceRequest jsexpr.  The `service.name` resource attribute is
;; taken from the FIRST event's service-name (all events in a batch share the
;; ambient service name); each event becomes one logRecord with:
;;   timeUnixNano : (timestampMs * 1e6) as a decimal STRING (OTLP int64 rule)
;;   body         : { stringValue: message }
;;   attributes   : OTLP KeyValue list
;;   traceId/spanId/flags : LIFTED from the trace.id / span.id / trace.sampled
;;     attributes when the event was emitted inside a trace context.  These are
;;     first-class LogRecord FIELDS in OTLP, and they are what a collector uses to
;;     join a log line to a trace — an attribute of the same name would show up in
;;     the UI but would not correlate.  The attributes are kept as well, because
;;     they are what the console consumer prints and what a log-only backend can
;;     filter on.
;; An empty event list yields an empty resourceLogs array.
(define (attr-ref attributes key)
  (let ([hit (assq key attributes)])
    (and hit (cdr hit))))

(define (telemetry-events->otlp-logs-jsexpr events #:service-name [service-name #f])
  (cond
    [(null? events) (hash 'resourceLogs '())]
    [else
     (define svc (or service-name (telemetry-event-service-name (car events))))
     (define log-records
       (for/list ([event (in-list events)])
         (define ts-ms (telemetry-event-timestamp-ms event))
         (define ts-nano (inexact->exact (round (* ts-ms 1000000.0))))
         (define attrs (telemetry-event-attributes event))
         (define trace-id (attr-ref attrs 'trace.id))
         (define span-id (attr-ref attrs 'span.id))
         (define base
           (hash 'timeUnixNano (number->string ts-nano)
                 'body (hash 'stringValue (telemetry-event-message event))
                 'attributes (attributes->otlp-key-values attrs)))
         (cond
           [(and (string? trace-id) (string? span-id))
            (hash-set* base
                       'traceId trace-id
                       'spanId span-id
                       'flags (if (eq? (attr-ref attrs 'trace.sampled) #t) 1 0))]
           [else base])))
     (hash 'resourceLogs
           (list (hash 'resource
                       (hash 'attributes
                             (list (hash 'key "service.name"
                                         'value (hash 'stringValue svc))))
                       'scopeLogs
                       (list (hash 'scope (hash 'name "tesl")
                                   'logRecords log-records)))))]))

;; Normalize an endpoint to its /v1/logs URL.  A bare collector base
;; ("http://host:4318") gets "/v1/logs" appended; an endpoint that already ends
;; in /v1/logs is used as-is.  Trailing slashes are trimmed first.
(define (otlp-logs-url endpoint)
  (define trimmed (regexp-replace #rx"/+$" endpoint ""))
  (if (regexp-match? #rx"/v1/logs$" trimmed)
      trimmed
      (string-append trimmed "/v1/logs")))

;; Resolve dsl/capability.rkt beside this source file (dsl/), robust to launch dir.
(define-runtime-path otlp-capability-source "capability.rkt")

;; POST a batch of events to the collector.  NEVER raises: any failure (DNS,
;; refused connection, timeout, non-2xx, malformed anything) is swallowed so the
;; exporter degrades to a dropped batch rather than breaking the caller.  Runs
;; the shared HttpClient.post under an ambient httpClient capability grant.
(define (otlp-post-batch! endpoint headers events)
  (with-handlers ([(lambda (_) #t) (lambda (_) (void))])
    (define post     (dynamic-require otlp-http-client-source 'HttpClient.post))
    (define http-cap (dynamic-require otlp-http-client-source 'httpClient))
    (define cap-current  (dynamic-require otlp-capability-source 'current-capabilities))
    (define expand-caps  (dynamic-require otlp-capability-source 'expand-capabilities))
    (define body (jsexpr->string (telemetry-events->otlp-logs-jsexpr events)))
    (define url  (otlp-logs-url endpoint))
    (define header-list
      (cons (list "content-type" "application/json")
            (for/list ([h (in-list headers)]) (list (car h) (cdr h)))))
    ;; Grant the httpClient capability ambiently for this POST only.  We set the
    ;; parameter directly (rather than the `with-capabilities` macro) so this is a
    ;; plain runtime call independent of how capability.rkt was loaded.
    ;; …and with NO ambient trace context: the exporter's own POST must not be
    ;; instrumented as an outbound CLIENT span (see dsl/traces.rkt's
    ;; otlp-post-spans! for the loop that guards against).
    (parameterize ([cap-current (expand-caps (cons http-cap (cap-current)))]
                   [current-trace-ctx #f])
      (post url header-list body))
    (void)))

;; Parse the standard OTEL env var `OTEL_EXPORTER_OTLP_HEADERS` — a
;; comma-separated list of `key=value` pairs (e.g.
;; "x-oneuptime-token=abc,x-honeycomb-team=xyz") — into a list of (key . value)
;; string pairs.  This is how OTLP backends receive auth (OneUptime, Honeycomb,
;; Grafana Cloud, Dash0, …) without a collector in between (issue #14). Malformed
;; entries (no `=`, empty key) are skipped rather than aborting telemetry. Only
;; the first `=` splits, so values may contain `=`.
(define (parse-otlp-headers-env)
  (define raw (getenv "OTEL_EXPORTER_OTLP_HEADERS"))
  (if (or (not raw) (string=? (string-trim raw) ""))
      '()
      (filter-map
       (lambda (kv)
         (define t (string-trim kv))
         (define eq (for/first ([c (in-string t)] [i (in-naturals)] #:when (char=? c #\=)) i))
         (cond
           [(or (not eq) (= eq 0)) #f]
           [else (cons (string-trim (substring t 0 eq))
                       (string-trim (substring t (add1 eq))))]))
       (string-split raw ","))))

;; Merge explicit headers with env headers; explicit ones win on a
;; case-insensitive key clash (env is the fallback source).
(define (merge-otlp-headers explicit env-hdrs)
  (define (key h) (string-downcase (car h)))
  (define explicit-keys (map key explicit))
  (append explicit
          (filter (lambda (h) (not (member (key h) explicit-keys))) env-hdrs)))

(define (make-otlp-http-consumer #:endpoint endpoint
                                 #:headers [headers '()]
                                 #:timeout [_timeout-ms 5000]
                                 #:batch-size [batch-size 100]
                                 #:flush-interval-ms [flush-interval-ms 2000])
  ;; Bounded buffer: at most (max-buffer) events queued.  We keep it a small
  ;; multiple of batch-size so a slow/unreachable collector can never grow memory
  ;; without bound.  Drop policy: DROP-OLDEST (keep the freshest events).
  (define max-buffer (max 1 (* 10 batch-size)))
  (define lock (make-semaphore 1))          ; guards `buffer`
  (define wake (make-semaphore 0))          ; signals the flusher (batch-full)
  (define buffer '())                        ; newest-first list of events
  (define (with-lock thunk)
    (call-with-semaphore lock thunk))
  ;; Atomically take up to `n` oldest events off the buffer, returned oldest-first.
  (define (take-batch! n)
    (with-lock
     (lambda ()
       (cond
         [(null? buffer) '()]
         [else
          (define ordered (reverse buffer))       ; oldest-first
          (define count (min n (length ordered)))
          (define batch (take ordered count))
          (set! buffer (reverse (drop ordered count)))
          batch]))))
  ;; Flush every queued event in batch-size chunks; stops when the buffer empties.
  (define (flush-all!)
    (let loop ()
      (define batch (take-batch! batch-size))
      (unless (null? batch)
        (otlp-post-batch! endpoint headers batch)
        (loop))))
  ;; Background flusher: wakes on the timer OR when signalled (batch full), then
  ;; drains everything.  register-background-thread! records the handle for the
  ;; DAP debugger (no-op unless TESL_DEBUG is set); behaviour is unchanged.
  (register-background-thread!
   (thread
    (lambda ()
      (let loop ()
        ;; Wait for either the flush interval to elapse or a batch-full signal.
        (sync/timeout (/ flush-interval-ms 1000.0) (semaphore-peek-evt wake))
        ;; Drain the signal (coalesce multiple posts into one flush pass).
        (let drain () (when (semaphore-try-wait? wake) (drain)))
        (with-handlers ([(lambda (_) #t) (lambda (_) (void))]) (flush-all!))
        (loop)))))
  ;; The consumer: enqueue (bounded, drop-oldest) and signal a flush when full.
  (lambda (event)
    (define-values (full? dropped?)
      (with-lock
       (lambda ()
         (set! buffer (cons event buffer))
         (define overflow? (> (length buffer) max-buffer))
         (when overflow?
           ;; DROP-OLDEST: buffer is newest-first, so the LAST element is oldest.
           (set! buffer (take buffer max-buffer)))
         (values (>= (length buffer) batch-size) overflow?))))
    ;; Metrics self-observability: a rising dropped counter means the collector
    ;; cannot keep up (or is down) and log data is being lost.  Counted outside
    ;; the buffer lock — the metrics registry has its own.
    (when (and dropped? (metrics-active?))
      (metric-counter-add! "tesl.telemetry.dropped" 1
                           (list (cons "tesl.signal" "logs"))))
    (when full? (semaphore-post wake))
    (void)))

(define (init-opentelemetry! #:service-name service-name
                             #:endpoint [endpoint #f]
                             #:console? [console? #f]
                             #:console-port [console-port (current-error-port)]
                             #:consumers [consumers '()]
                             #:otlp-headers [otlp-headers '()]
                             #:otlp-timeout-ms [otlp-timeout-ms 5000]
                             #:otlp-batch-size [otlp-batch-size 100]
                             #:otlp-flush-interval-ms [otlp-flush-interval-ms 2000]
                             #:metrics? [metrics? 'auto]
                             #:metrics-interval-ms [metrics-interval-ms 60000]
                             #:traces? [traces? #f]
                             #:trace-ratio [trace-ratio 1.0]
                             #:traces-interval-ms [traces-interval-ms 2000])
  (current-telemetry-service-name service-name)
  (current-telemetry-endpoint endpoint)
  (current-telemetry-context '())
  (current-telemetry-events '())
  ;; Wire the (previously inert) endpoint to a real OTLP/HTTP+JSON Logs exporter.
  ;; A configured endpoint activates the exporter (opt-in by config); the sentinel
  ;; "in-memory" is treated as "no remote export" for local/example use.  Console
  ;; emission is independent and controlled by #:console?.
  ;; Fold in OTEL_EXPORTER_OTLP_HEADERS so token-gated OTLP backends authenticate
  ;; with no collector hop (issue #14). Explicit #:otlp-headers win over env.
  (define effective-otlp-headers (merge-otlp-headers otlp-headers (parse-otlp-headers-env)))
  (define otlp-consumers
    (if (and endpoint (not (member endpoint '("in-memory" ""))))
        (list (make-otlp-http-consumer #:endpoint endpoint
                                       #:headers effective-otlp-headers
                                       #:timeout otlp-timeout-ms
                                       #:batch-size otlp-batch-size
                                       #:flush-interval-ms otlp-flush-interval-ms))
        '()))
  (current-telemetry-consumers
   (append consumers
           otlp-consumers
           (if console?
               (list (make-console-telemetry-consumer #:port console-port))
               '())))
  ;; #22: bridge the framework's own HTTP/SQL/queue/pubsub instrumentation into
  ;; the telemetry pipeline when a real OTLP endpoint is configured, so remote
  ;; observability isn't near-empty unless every handler is hand-instrumented.
  ;; The sink funnels each framework log event through the SAME emit path as an
  ;; explicit `telemetry "…"` statement (reaching every configured consumer).
  ;; Gated on a real endpoint (otlp-consumers present); cleared for
  ;; in-memory/console-only/#f so the stderr-only path is preserved for local and
  ;; example use (and tests stay unaffected).
  (set-telemetry-log-sink!
   (if (pair? otlp-consumers)
       (lambda (category message attrs)
         (emit-telemetry-event! message (cons (cons 'log.category category) attrs)))
       #f))
  (set-box! global-telemetry-log '())
  ;; ── Metrics signal ──
  ;; Default ('auto): metrics record + export whenever a real OTLP endpoint is
  ;; configured, mirroring the logs sink.  `#:metrics? #t` with an in-memory
  ;; endpoint records into the registry with no exporter (tests, local dev);
  ;; `#:metrics? #f` disables recording entirely.  Re-init resets the registry
  ;; and replaces any previous exporter thread (same idempotence as the rest of
  ;; this function).
  (define real-endpoint? (pair? otlp-consumers))
  (define metrics-on? (if (eq? metrics? 'auto) real-endpoint? (and metrics? #t)))
  (reset-metrics!)
  (set-metrics-enabled! metrics-on?)
  (if (and metrics-on? real-endpoint?)
      (start-metrics-exporter! #:endpoint endpoint
                               #:headers effective-otlp-headers
                               #:interval-ms metrics-interval-ms
                               #:service-name-thunk
                               (lambda () (current-telemetry-service-name)))
      (stop-metrics-exporter!))
  ;; ── Traces signal ──
  ;; DEFAULT OFF, unlike metrics: spans are per-request and unaggregated, so the
  ;; volume and the (ambient, SEC-TELEMETRY) egress are orders of magnitude above
  ;; logs+metrics.  `#:traces? #t` records spans; with a real endpoint they are
  ;; also exported to <endpoint>/v1/traces, and with "in-memory" they stay in the
  ;; ring buffer (tests, local dev).
  ;;
  ;; Trace CONTEXT (Phase A — inbound traceparent parsing, log correlation,
  ;; outbound injection) is NOT gated on this: it costs nothing, exports nothing,
  ;; and its whole value is that it works in the default configuration.
  (set-trace-sample-ratio! trace-ratio)
  (define traces-on? (and traces? #t))
  (reset-traces!)
  (set-traces-enabled! traces-on?)
  (if (and traces-on? real-endpoint?)
      (start-traces-exporter! #:endpoint endpoint
                              #:headers effective-otlp-headers
                              #:interval-ms traces-interval-ms
                              #:service-name-thunk
                              (lambda () (current-telemetry-service-name)))
      (stop-traces-exporter!))
  (void))

(define (call-with-telemetry-context additions thunk)
  (parameterize ([current-telemetry-context
                  (append (current-telemetry-context) additions)])
    (thunk)))

(define (emit-telemetry-event! message attributes)
  (define event
    (telemetry-event (current-telemetry-service-name)
                     (current-telemetry-endpoint)
                     message
                     ;; Trace correlation (Phase A) is appended HERE, not baked
                     ;; into dispatch-request's route-context, for two reasons:
                     ;; the innermost ACTIVE span must win (a log emitted inside a
                     ;; db span belongs to that span, and route-context is built
                     ;; once per request), and an entry point that is not an HTTP
                     ;; request — a queue worker, an agent run — gets the same
                     ;; correlation with no second call site.  With no ambient
                     ;; trace context this appends '(), so a process that never
                     ;; sees a request emits byte-identical telemetry to before.
                     (append (current-telemetry-context)
                             attributes
                             (trace-context-attributes))
                     (current-inexact-milliseconds)))
  (current-telemetry-events (cons event (current-telemetry-events)))
  (set-box! global-telemetry-log (cons event (unbox global-telemetry-log)))
  (for ([consumer (in-list (current-telemetry-consumers))])
    (with-handlers ([exn:fail? (lambda (_exn) (void))])
      (consumer event)))
  event)

(define-syntax (telemetry-event! stx)
  (syntax-parse stx
    [(_ message:expr)
     #'(emit-telemetry-event! message '())]
    [(_ message:expr #:attributes ([key value] ...))
     (define keys (for/list ([k (syntax->list #'(key ...))])
                    (syntax->datum k)))
     (with-syntax ([(quoted-key ...)
                    (for/list ([k keys])
                      #`'#,k)])
       #'(emit-telemetry-event! message
                                (list (cons quoted-key value) ...)))]))

(define-syntax-rule (log-info! message rest ...)
  (telemetry-event! message rest ...))

(define (drain-telemetry!)
  (define events (reverse (unbox global-telemetry-log)))
  (set-box! global-telemetry-log '())
  events)
