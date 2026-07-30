#lang racket

;;; OpenTelemetry Traces for Tesl — in-process span recorder + OTLP/HTTP+JSON
;;; exporter (Traces signal, /v1/traces).
;;;
;;; Sibling of dsl/otel.rkt (Logs) and dsl/metrics.rkt (Metrics), and the Phase-B
;;; half of roadmap/completed/otel_trace_support.md.  The developer-facing
;;; surface is ONE keyword — `traces True` on `initTelemetry` — because every span
;;; worth having is a framework span and the framework already brackets it:
;;; `with-sql-capture`, `do-http-request`, the queue handler wrap,
;;; `call-provider`, `run-tool-call`.
;;; There is deliberately NO user-facing `span` API (see that item's Non-goals);
;;; an inner boundary is a `telemetry` event, which Phase A stamps with
;;; trace.id/span.id so it lands inside the enclosing span anyway.
;;;
;;; DEFAULT OFF.  Unlike metrics, traces are per-request and unaggregated, so the
;;; volume and egress are orders of magnitude above logs+metrics.  Enabling is an
;;; explicit `traces True`, and `traceRatio` head-samples on top of that.
;;;
;;; PARENT-RESPECTING SAMPLING.  Nothing is recorded unless the ambient
;;; trace context (dsl/trace-context.rkt) says `sampled`.  An inbound
;;; `traceparent` decision is never second-guessed — that is what keeps a
;;; distributed trace whole — so `traceRatio` only decides for traces that start
;;; here.
;;;
;;; RECORD PATH: never raises, never blocks.  `with-span` reads one flag when
;;; traces are off and evaluates NEITHER the span name nor its attributes, so an
;;; instrumented call site costs one unbox in the default configuration.  Span
;;; buffering runs in atomic mode (not under a semaphore) for the same
;;; kill-safety reason dsl/metrics.rkt documents: request threads are killed at
;;; arbitrary points and a stranded lock would block every recorder in the
;;; process.
;;;
;;; ATTRIBUTE DISCIPLINE.  Span attributes are rendered by dsl/otlp-value.rkt —
;;; the ONE OTLP value renderer, which redacts `secret` at every node.  A span
;;; must never format its own values, or spans become the one sink that leaks a
;;; `secret` column.
;;;
;;; Dependency direction: requires only json/runtime-path + the domain registry +
;;; dsl/trace-context.rkt + dsl/otlp-value.rkt, so dsl/web.rkt, dsl/sql.rkt,
;;; tesl/http-client.rkt, tesl/queue.rkt, tesl/agent*.rkt and dsl/otel.rkt can
;;; all require it with no cycle.

(require json
         racket/runtime-path
         (only-in ffi/unsafe/atomic call-as-atomic)
         (only-in "private/domain-registry.rkt" register-background-thread!)
         ;; Self-observability only (a rising drop counter means the collector
         ;; cannot keep up).  metrics.rkt requires nothing of ours that could
         ;; cycle back, exactly as its own header states.
         (only-in "metrics.rkt" metrics-active? metric-counter-add!)
         (only-in "otlp-value.rkt" attributes->otlp-key-values ms->nano-string)
         (only-in "trace-context.rkt"
                  trace-ctx? trace-ctx-trace-id trace-ctx-span-id
                  trace-ctx-sampled? trace-ctx-remote-parent?
                  current-trace-ctx new-span-id call-with-child-span-id))

(provide traces-active?
         set-traces-enabled!
         reset-traces!
         with-span
         with-server-span
         call-with-span
         call-with-server-span
         span-set-name!
         span-add-attributes!
         span-mark-error!
         span-buffer-limit
         spans-snapshot
         spans->otlp-jsexpr
         otlp-traces-url
         start-traces-exporter!
         stop-traces-exporter!
         (struct-out recorded-span))

;; ── Enabled flag ─────────────────────────────────────────────────────────────

(define traces-enabled-box (box #f))

(define (traces-active?) (unbox traces-enabled-box))

(define (set-traces-enabled! on?) (set-box! traces-enabled-box (and on? #t)))

;; ── Span record + buffer ─────────────────────────────────────────────────────
;;
;; kind ∈ 'server 'client 'internal 'producer 'consumer  (OTLP SpanKind)
;; status: 'unset | 'error   ('ok is deliberately unused: OTel says a server/
;; client span should stay UNSET on success so a consumer's own judgement of
;; "was this ok" is not overridden.)
(struct recorded-span (trace-id
                       span-id
                       parent-span-id
                       [name #:mutable]
                       kind
                       start-ms
                       [end-ms #:mutable]
                       [attributes #:mutable]
                       [status #:mutable]
                       [status-message #:mutable])
  #:transparent)

;; Bounded, DROP-OLDEST, same policy as the logs exporter's queue: a slow or
;; unreachable collector must never grow memory, and the freshest spans are the
;; ones worth keeping.  Held newest-first, with the length carried alongside so a
;; push is O(1) (the buffer is 2048 deep — re-measuring it per span would make
;; the record path scale with the backlog).
(define span-buffer-limit 2048)
(define span-buffer (box '()))
(define span-buffer-count (box 0))

(define (with-buffer thunk) (call-as-atomic thunk))

;; Returns #t iff this push dropped the oldest span.  The drop is COUNTED OUTSIDE
;; the atomic section (the metrics registry has its own), exactly as the logs
;; consumer counts its own drops.
(define (buffer-span!* sp)
  (with-buffer
    (lambda ()
      (cond
        [(>= (unbox span-buffer-count) span-buffer-limit)
         ;; newest-first, so dropping the oldest is dropping the LAST element
         (set-box! span-buffer (cons sp (take (unbox span-buffer)
                                              (sub1 span-buffer-limit))))
         #t]
        [else
         (set-box! span-buffer (cons sp (unbox span-buffer)))
         (set-box! span-buffer-count (add1 (unbox span-buffer-count)))
         #f]))))

(define (buffer-span! sp)
  (when (buffer-span!* sp)
    (when (metrics-active?)
      (metric-counter-add! "tesl.telemetry.dropped" 1
                           (list (cons "tesl.signal" "traces"))))))

;; Take every buffered span, oldest-first.  Exporter-thread only.
(define (drain-spans!)
  (with-buffer
    (lambda ()
      (define all (unbox span-buffer))
      (set-box! span-buffer '())
      (set-box! span-buffer-count 0)
      (reverse all))))

;; Read-only copy, oldest-first (tests).
(define (spans-snapshot)
  (with-buffer (lambda () (reverse (unbox span-buffer)))))

(define (reset-traces!)
  (with-buffer
    (lambda ()
      (set-box! span-buffer '())
      (set-box! span-buffer-count 0))))

;; ── Recording ────────────────────────────────────────────────────────────────

;; Mutators, used by a call site that only learns an attribute AFTER the span
;; starts (dispatch-request does not know the route operation until the match
;; loop runs).  All tolerate #f — the handle is #f whenever the span was not
;; recorded, so a call site needs no `when`.
(define (span-set-name! sp name)
  (when (recorded-span? sp) (set-recorded-span-name! sp name)))

(define (span-add-attributes! sp attrs)
  (when (and (recorded-span? sp) (list? attrs))
    (set-recorded-span-attributes! sp (append (recorded-span-attributes sp) attrs))))

(define (span-mark-error! sp message)
  (when (recorded-span? sp)
    (set-recorded-span-status! sp 'error)
    (set-recorded-span-status-message! sp (if (string? message) message (~a message)))))

;; Should this call site record at all?  Traces enabled AND an ambient trace
;; context AND that context sampled.  The sampled check here is what makes
;; `traceRatio` cost nothing on an unsampled request: no span object, no
;; attribute list, no buffer traffic.
(define (recording?)
  (and (traces-active?)
       (let ([ctx (current-trace-ctx)])
         (and (trace-ctx? ctx) (trace-ctx-sampled? ctx) ctx))))

;; Timing uses `current-inexact-milliseconds` (the metrics choice too): a wall
;; clock step between start and end would produce a negative duration, which
;; collectors reject.
(define (start-span ctx span-id parent-span-id name kind attrs)
  (recorded-span (trace-ctx-trace-id ctx)
                 span-id
                 parent-span-id
                 name
                 kind
                 (current-inexact-milliseconds)
                 #f
                 (if (list? attrs) attrs '())
                 'unset
                 #f))

;; Never raises: closing a span is bookkeeping, and a failure here would surface
;; as a failure of the instrumented operation.
(define (finish-span! sp)
  (with-handlers ([(lambda (_) #t) (lambda (_) (void))])
    (set-recorded-span-end-ms! sp (current-inexact-milliseconds))
    (buffer-span! sp)))

;; Build the span for this call site, or #f if anything about the span itself
;; fails (a name-thunk that raises, an id source that fails): instrumentation
;; degrades to no span, never to a failed call.
;;
;; This is SEPARATE from running the body on purpose.  A single `with-handlers`
;; around both would catch the body's own exception, and its "degrade to no span"
;; recovery would then run the body A SECOND TIME — for an outbound POST or an
;; INSERT, a duplicate effect.  Setup is guarded; the body is not.
(define (make-span-for ctx sid parent name-thunk kind attrs-thunk)
  (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
    (start-span ctx sid parent (name-thunk) kind (attrs-thunk))))

;; Run `proc` with `sp` open, closing it exactly once on either path.  The body
;; runs EXACTLY ONCE, and a failure is re-raised UNCHANGED — instrumentation
;; never swallows an error and never invents one.
(define (call-with-open-span sid sp proc)
  (call-with-child-span-id
   sid
   (lambda ()
     (with-handlers ([(lambda (_) #t)
                      (lambda (e)
                        (span-mark-error! sp (if (exn? e) (exn-message e) (~a e)))
                        (finish-span! sp)
                        (raise e))])
       (define result (proc sp))
       (finish-span! sp)
       result))))

;; The general child-span bracket.  `name-thunk` / `attrs-thunk` are thunks so a
;; call site pays nothing to format a span name that will not be recorded.
;;
;; `proc` receives the span handle (or #f), so it can refine the name/attributes
;; once it knows more.
(define (call-with-span name-thunk kind attrs-thunk proc)
  (define ctx (recording?))
  (cond
    [(not ctx) (proc #f)]
    [else
     (define sid (new-span-id))
     (define sp (make-span-for ctx sid (trace-ctx-span-id ctx) name-thunk kind attrs-thunk))
     (if sp (call-with-open-span sid sp proc) (proc #f))]))

;; The ROOT bracket, for an entry point (an HTTP request, a queue job).  It
;; differs from `call-with-span` in exactly one way, and that way matters: the
;; root may only claim a `parentSpanId` that actually exists.
;;
;;   - continued trace (inbound `traceparent`): the ambient span-id is the
;;     CALLER's real span, so it becomes our parent and we mint a fresh id;
;;   - trace that starts here: the ambient span-id was minted locally and never
;;     exported, so the root span ADOPTS it (no parent) rather than pointing at a
;;     span nobody sent.  Logs already stamped with that id therefore name the
;;     root span, which is what the trace UI should show.
(define (call-with-server-span name-thunk kind attrs-thunk proc)
  (define ctx (recording?))
  (cond
    [(not ctx) (proc #f)]
    [else
     (define remote? (trace-ctx-remote-parent? ctx))
     (define sid (if remote? (new-span-id) (trace-ctx-span-id ctx)))
     (define parent (and remote? (trace-ctx-span-id ctx)))
     (define sp (make-span-for ctx sid parent name-thunk kind attrs-thunk))
     (if sp (call-with-open-span sid sp proc) (proc #f))]))

;; The call-site forms.  The `traces-active?` test is in the MACRO so that with
;; traces off (the default) neither the name nor the attribute expressions are
;; evaluated — no formatting, no list allocation, one unbox.
(define-syntax-rule (with-span (sp name-expr kind attrs-expr) body ...)
  (if (traces-active?)
      (call-with-span (lambda () name-expr) kind (lambda () attrs-expr)
                      (lambda (sp) body ...))
      (let ([sp #f]) body ...)))

(define-syntax-rule (with-server-span (sp name-expr kind attrs-expr) body ...)
  (if (traces-active?)
      (call-with-server-span (lambda () name-expr) kind (lambda () attrs-expr)
                             (lambda (sp) body ...))
      (let ([sp #f]) body ...)))

;; ── OTLP mapping (pure, unit-testable) ───────────────────────────────────────
;;
;; spans → one ExportTraceServiceRequest jsexpr, following the OTLP/JSON
;; encoding rules already proven for Logs and Metrics: int64/uint64 fields are
;; decimal STRINGS, timestamps are epoch-nanos strings, enums are their proto
;; numbers, and trace/span ids are lowercase hex strings.

(define (span-kind->otlp kind)
  (case kind
    [(internal) 1]
    [(server) 2]
    [(client) 3]
    [(producer) 4]
    [(consumer) 5]
    [else 0]))

(define (span-status->otlp sp)
  ;; STATUS_CODE_UNSET = 0, OK = 1, ERROR = 2
  (if (eq? (recorded-span-status sp) 'error)
      (let ([m (recorded-span-status-message sp)])
        (if m (hash 'code 2 'message m) (hash 'code 2)))
      (hash 'code 0)))

(define (span->otlp-jsexpr sp)
  (define base
    (hash 'traceId (recorded-span-trace-id sp)
          'spanId (recorded-span-span-id sp)
          'name (recorded-span-name sp)
          'kind (span-kind->otlp (recorded-span-kind sp))
          'startTimeUnixNano (ms->nano-string (recorded-span-start-ms sp))
          'endTimeUnixNano (ms->nano-string (or (recorded-span-end-ms sp)
                                                (recorded-span-start-ms sp)))
          'attributes (attributes->otlp-key-values (recorded-span-attributes sp))
          'status (span-status->otlp sp)))
  (if (recorded-span-parent-span-id sp)
      (hash-set base 'parentSpanId (recorded-span-parent-span-id sp))
      base))

(define (spans->otlp-jsexpr spans #:service-name service-name)
  (cond
    [(null? spans) (hash 'resourceSpans '())]
    [else
     (hash 'resourceSpans
           (list (hash 'resource
                       (hash 'attributes
                             (list (hash 'key "service.name"
                                         'value (hash 'stringValue service-name))))
                       'scopeSpans
                       (list (hash 'scope (hash 'name "tesl")
                                   'spans (map span->otlp-jsexpr spans))))))]))

;; ── Exporter ─────────────────────────────────────────────────────────────────

;; Normalize an endpoint to its /v1/traces URL (same trimming rules as
;; otlp-logs-url / otlp-metrics-url).
(define (otlp-traces-url endpoint)
  (define trimmed (regexp-replace #rx"/+$" endpoint ""))
  (if (regexp-match? #rx"/v1/traces$" trimmed)
      trimmed
      (string-append trimmed "/v1/traces")))

(define-runtime-path traces-http-client-source "../tesl/http-client.rkt")
(define-runtime-path traces-capability-source "capability.rkt")

;; POST one batch.  NEVER raises (same contract as otlp-post-batch! in
;; dsl/otel.rkt); a dead collector degrades to a dropped batch.  Telemetry egress
;; is the deliberate ambient exception (LANGUAGE-SPEC §5.2), so the httpClient
;; capability is granted for this POST only.
(define (otlp-post-spans! endpoint headers jsexpr)
  (with-handlers ([(lambda (_) #t) (lambda (_) (void))])
    (define post (dynamic-require traces-http-client-source 'HttpClient.post))
    (define http-cap (dynamic-require traces-http-client-source 'httpClient))
    (define cap-current (dynamic-require traces-capability-source 'current-capabilities))
    (define expand-caps (dynamic-require traces-capability-source 'expand-capabilities))
    (define header-list
      (cons (list "content-type" "application/json")
            (for/list ([h (in-list headers)]) (list (car h) (cdr h)))))
    ;; NO ambient trace context for the exporter's own POST.  Without this, the
    ;; export call would itself be instrumented as a CLIENT span, which buffers a
    ;; span, which the next flush exports — a self-feeding loop that reports
    ;; nothing but its own existence.  The exporter thread is created at init (so
    ;; it inherits #f anyway); this makes the property explicit rather than
    ;; incidental, and holds even if init runs inside a traced request.
    (parameterize ([cap-current (expand-caps (cons http-cap (cap-current)))]
                   [current-trace-ctx #f])
      (post (otlp-traces-url endpoint) header-list (jsexpr->string jsexpr)))
    (void)))

;; One exporter at a time, shut down COOPERATIVELY by generation bump — same
;; reasoning as dsl/metrics.rkt: re-init can happen under a different custodian
;; than the one that started the thread, so kill-thread is not available.
(define exporter-generation (box 0))

(define (stop-traces-exporter!)
  (set-box! exporter-generation (add1 (unbox exporter-generation))))

(define (start-traces-exporter! #:endpoint endpoint
                                #:headers [headers '()]
                                #:interval-ms [interval-ms 2000]
                                #:batch-size [batch-size 512]
                                #:service-name-thunk service-name-thunk)
  (stop-traces-exporter!)
  (define my-generation (unbox exporter-generation))
  ;; Clamp: a non-positive interval would busy-loop POSTing every scheduler tick
  ;; (and a negative one raises inside `sleep`, silently killing the thread).
  (define safe-interval-ms
    (if (and (real? interval-ms) (>= interval-ms 100)) interval-ms 100))
  (define safe-batch (if (and (exact-integer? batch-size) (> batch-size 0)) batch-size 512))
  (register-background-thread!
   (thread
    (lambda ()
      (let loop ()
        (sleep (/ safe-interval-ms 1000.0))
        (when (= my-generation (unbox exporter-generation))
          (with-handlers ([(lambda (_) #t) (lambda (_) (void))])
            (define batch (drain-spans!))
            (unless (null? batch)
              (let chunk ([rest batch])
                (unless (null? rest)
                  (define n (min safe-batch (length rest)))
                  (otlp-post-spans! endpoint headers
                                    (spans->otlp-jsexpr (take rest n)
                                                        #:service-name (service-name-thunk)))
                  (chunk (drop rest n))))))
          (loop))))))
  (void))
