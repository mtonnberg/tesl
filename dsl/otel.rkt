#lang racket

(require json
         racket/runtime-path
         (only-in "private/domain-registry.rkt" register-background-thread!)
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

(define (telemetry-key->json-key key)
  (cond
    [(symbol? key) key]
    [(keyword? key) (string->symbol (keyword->string key))]
    [(bytes? key) (string->symbol (bytes->string/utf-8 key))]
    [(string? key) (string->symbol key)]
    [else (string->symbol (~a key))]))

(define (telemetry-value->jsexpr value)
  (cond
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
    [else value]))

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
;; OTLP/HTTP+JSON, Logs signal only.  Spans/metrics/gRPC/protobuf are non-goals
;; for this cut (the flat event model has no start/end pair, so Logs is the
;; natural mapping — see the otlp_exporter roadmap item).
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

;; Convert one Tesl attribute value to an OTLP AnyValue jsexpr.  OTLP KeyValue
;; values are tagged unions: booleans → boolValue, exact integers → intValue
;; (as a STRING per the OTLP/JSON int64 convention), other reals → doubleValue,
;; everything else → stringValue (reusing telemetry-value->jsexpr's coercion for
;; symbols/keywords/bytes, then stringifying).  Bool is checked before number
;; because in Racket booleans are not numbers, but we make the ordering explicit.
(define (telemetry-value->otlp-any-value value)
  (cond
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

;; Build the OTLP KeyValue list for one event's attributes.
(define (telemetry-attributes->otlp-key-values attributes)
  (for/list ([entry (in-list attributes)])
    (hash 'key (symbol->string (telemetry-key->json-key (car entry)))
          'value (telemetry-value->otlp-any-value (cdr entry)))))

;; Pure, unit-testable mapping: a list of telemetry-event → one OTLP/HTTP+JSON
;; ExportLogsServiceRequest jsexpr.  The `service.name` resource attribute is
;; taken from the FIRST event's service-name (all events in a batch share the
;; ambient service name); each event becomes one logRecord with:
;;   timeUnixNano : (timestampMs * 1e6) as a decimal STRING (OTLP int64 rule)
;;   body         : { stringValue: message }
;;   attributes   : OTLP KeyValue list
;; An empty event list yields an empty resourceLogs array.
(define (telemetry-events->otlp-logs-jsexpr events #:service-name [service-name #f])
  (cond
    [(null? events) (hash 'resourceLogs '())]
    [else
     (define svc (or service-name (telemetry-event-service-name (car events))))
     (define log-records
       (for/list ([event (in-list events)])
         (define ts-ms (telemetry-event-timestamp-ms event))
         (define ts-nano (inexact->exact (round (* ts-ms 1000000.0))))
         (hash 'timeUnixNano (number->string ts-nano)
               'body (hash 'stringValue (telemetry-event-message event))
               'attributes (telemetry-attributes->otlp-key-values
                            (telemetry-event-attributes event)))))
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
    (parameterize ([cap-current (expand-caps (cons http-cap (cap-current)))])
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
    (define full?
      (with-lock
       (lambda ()
         (set! buffer (cons event buffer))
         (when (> (length buffer) max-buffer)
           ;; DROP-OLDEST: buffer is newest-first, so the LAST element is oldest.
           (set! buffer (take buffer max-buffer)))
         (>= (length buffer) batch-size))))
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
                             #:otlp-flush-interval-ms [otlp-flush-interval-ms 2000])
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
  (set-box! global-telemetry-log '())
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
                     (append (current-telemetry-context) attributes)
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
