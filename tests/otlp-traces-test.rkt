#lang racket

;;; OTLP Traces tests (dsl/traces.rkt + the initTelemetry wiring + the framework
;;; span sites).  Phase B of roadmap/completed/otel_trace_support.md.
;;;
;;; Tiers mirror otlp-metrics-test.rkt, all offline and deterministic:
;;;
;;;   1. UNIT — recording gates (traces off / no context / unsampled), the
;;;      parent-child shape, error status, and the ring buffer's drop-oldest bound.
;;;   2. UNIT — the pure spans->otlp-jsexpr mapping (hex ids, SpanKind numbers,
;;;      nano-string timestamps, status codes, JSON validity).
;;;   3. END-TO-END — a real `dispatch-request` with an inbound `traceparent`
;;;      produces a SERVER span parented on the caller's span, with the outbound
;;;      HTTP call and the cache lookup as CHILD spans of it.  This is the tree
;;;      the N+1 question is answered from.
;;;   4. INTEGRATION — an in-process localhost sink must receive a POST to
;;;      <endpoint>/v1/traces with a well-formed body.  Self-SKIPS if it cannot
;;;      bind a port.
;;;   5. RESILIENCE — an unreachable collector never breaks the record path.
;;;   6. GATES — traces default OFF even with a real endpoint (unlike metrics);
;;;      `traces True` + "in-memory" records with no exporter; re-init resets.
;;;   7. SECRETS — a span is a rendering sink, so a `secret` attribute value must
;;;      redact, and the db span must never carry bound parameters.
;;;
;;; Run:  raco test tests/otlp-traces-test.rkt

(require racket/tcp
         json
         rackunit
         "../dsl/traces.rkt"
         "../dsl/trace-context.rkt"
         (only-in "../dsl/otel.rkt" init-opentelemetry!)
         (only-in "../dsl/metrics.rkt" metrics-active?)
         (only-in "../dsl/types.rkt"
                  define-secret-newtype secret-redaction-text)
         (only-in "../dsl/capability.rkt" current-capabilities)
         (only-in "../tesl/http-client.rkt" httpClient HttpClient.get)
         (only-in "../tesl/private/http-stub.rkt" current-outbound-http-hook))

(define SAMPLE-TP "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")

;; Declared through the real macro, so `secret-value?` recognizes it (a
;; hand-built newtype-value carries a bare symbol and would make the redaction
;; assertions below pass for the wrong reason — see tests/secret-runtime-tests.rkt).
(define-secret-newtype TraceProbeToken String)

;; Every test starts from a clean, enabled recorder unless it says otherwise.
(define (fresh! #:enabled? [enabled? #t])
  (stop-traces-exporter!)
  (reset-traces!)
  (set-traces-enabled! enabled?))

;; Run `thunk` inside a sampled trace that STARTS here (no remote parent).
(define (in-local-trace thunk)
  (call-with-trace-ctx (make-root-trace-ctx #:ratio 1.0) thunk))

;;; ── 1. UNIT: recording gates and span shape ──────────────────────────────────

(test-case "traces OFF: no span, and neither the name nor the attributes are evaluated"
  ;; The default configuration must cost one flag read at an instrumented call
  ;; site — no formatting, no list allocation.  A side effect in the name/attr
  ;; expressions is how that is measured.
  (fresh! #:enabled? #f)
  (define evaluated (box 0))
  (define (bump! v) (set-box! evaluated (add1 (unbox evaluated))) v)
  (define r
    (in-local-trace
     (lambda ()
       (with-span (sp (bump! "name") 'internal (bump! '())) 'body-ran))))
  (check-equal? r 'body-ran "the instrumented body still runs")
  (check-equal? (unbox evaluated) 0 "nothing about the span was computed")
  (check-equal? (spans-snapshot) '()))

(test-case "traces ON but no ambient trace context: no span (spans are rooted)"
  (fresh!)
  (check-equal? (with-span (sp "orphan" 'internal '()) 42) 42)
  (check-equal? (spans-snapshot) '()))

(test-case "an UNSAMPLED context records nothing (traceRatio costs nothing downstream)"
  (fresh!)
  (call-with-trace-ctx
   (make-root-trace-ctx #:traceparent
                        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00")
   (lambda () (with-span (sp "dropped" 'client '()) (void))))
  (check-equal? (spans-snapshot) '()))

(test-case "a sampled context records one span with ids, kind, timing and attrs"
  (fresh!)
  (in-local-trace
   (lambda () (with-span (sp "db.query notes" 'client (list (cons 'tesl.table "notes")))
                (void))))
  (define spans (spans-snapshot))
  (check-equal? (length spans) 1)
  (define sp (first spans))
  (check-equal? (recorded-span-name sp) "db.query notes")
  (check-equal? (recorded-span-kind sp) 'client)
  (check-equal? (string-length (recorded-span-trace-id sp)) 32)
  (check-equal? (string-length (recorded-span-span-id sp)) 16)
  (check-true (>= (recorded-span-end-ms sp) (recorded-span-start-ms sp))
              "monotonic-ish clock: a duration is never negative")
  (check-equal? (cdr (assq 'tesl.table (recorded-span-attributes sp))) "notes")
  (check-equal? (recorded-span-status sp) 'unset))

(test-case "a root span ADOPTS a locally minted span-id and claims NO parent"
  ;; Otherwise the exported root would point at a span nobody ever sent.
  (fresh!)
  (define root-ctx (make-root-trace-ctx #:ratio 1.0))
  (call-with-trace-ctx
   root-ctx
   (lambda () (with-server-span (sp "GET" 'server '()) (void))))
  (define sp (first (spans-snapshot)))
  (check-false (recorded-span-parent-span-id sp))
  (check-equal? (recorded-span-span-id sp) (trace-ctx-span-id root-ctx)
                "logs already stamped with that id name the root span"))

(test-case "a CONTINUED trace parents the root span on the caller's span"
  (fresh!)
  (call-with-trace-ctx
   (make-root-trace-ctx #:traceparent SAMPLE-TP)
   (lambda () (with-server-span (sp "POST" 'server '()) (void))))
  (define sp (first (spans-snapshot)))
  (check-equal? (recorded-span-trace-id sp) "4bf92f3577b34da6a3ce929d0e0e4736")
  (check-equal? (recorded-span-parent-span-id sp) "00f067aa0ba902b7")
  (check-not-equal? (recorded-span-span-id sp) "00f067aa0ba902b7"
                    "our span is a NEW span, not the caller's"))

(test-case "children nest: each span's parent is the innermost enclosing span"
  (fresh!)
  (call-with-trace-ctx
   (make-root-trace-ctx #:traceparent SAMPLE-TP)
   (lambda ()
     (with-server-span (root "POST /notes" 'server '())
       (with-span (a "db.query notes" 'client '()) (void))
       (with-span (b "POST billing" 'client '())
         (with-span (c "db.query audit" 'client '()) (void))))))
  (define spans (spans-snapshot))
  (check-equal? (length spans) 4)
  (define (by-name n) (for/first ([s spans] #:when (equal? (recorded-span-name s) n)) s))
  (define root (by-name "POST /notes"))
  (define a (by-name "db.query notes"))
  (define b (by-name "POST billing"))
  (define c (by-name "db.query audit"))
  (check-true (for/and ([s spans])
                (equal? (recorded-span-trace-id s) "4bf92f3577b34da6a3ce929d0e0e4736"))
              "one trace id across the whole tree")
  (check-equal? (recorded-span-parent-span-id a) (recorded-span-span-id root))
  (check-equal? (recorded-span-parent-span-id b) (recorded-span-span-id root))
  (check-equal? (recorded-span-parent-span-id c) (recorded-span-span-id b)
                "a grandchild parents on its own enclosing span, not the root")
  ;; children finish before their parent
  (check-true (<= (recorded-span-end-ms c) (recorded-span-end-ms b)))
  (check-true (<= (recorded-span-end-ms b) (recorded-span-end-ms root))))

(test-case "a failing body marks the span ERROR and re-raises UNCHANGED"
  (fresh!)
  (check-exn
   #rx"boom"
   (lambda ()
     (in-local-trace
      (lambda () (with-span (sp "will fail" 'client '()) (error 'x "boom"))))))
  (define sp (first (spans-snapshot)))
  (check-equal? (recorded-span-status sp) 'error)
  (check-true (regexp-match? #rx"boom" (recorded-span-status-message sp)))
  (check-true (real? (recorded-span-end-ms sp)) "a failed span is still closed"))

(test-case "the instrumented body runs EXACTLY ONCE, on the success AND failure paths"
  ;; The span bracket guards SETUP (a name-thunk that raises must degrade to no
  ;; span, not to a failed call) but must NOT guard the body: one `with-handlers`
  ;; around both would catch the body's exception and its "degrade to no span"
  ;; recovery would re-run the body — a duplicate POST or a duplicate INSERT.
  (fresh!)
  (define runs (box 0))
  (in-local-trace
   (lambda () (with-span (sp "ok path" 'client '()) (set-box! runs (add1 (unbox runs))))))
  (check-equal? (unbox runs) 1 "success path")
  (set-box! runs 0)
  (with-handlers ([exn:fail? void])
    (in-local-trace
     (lambda ()
       (with-span (sp "failure path" 'client '())
         (set-box! runs (add1 (unbox runs)))
         (error 'x "boom")))))
  (check-equal? (unbox runs) 1 "failure path — the body is NOT retried")
  ;; …and the same for the root bracket
  (set-box! runs 0)
  (with-handlers ([exn:fail? void])
    (in-local-trace
     (lambda ()
       (with-server-span (sp "root failure" 'server '())
         (set-box! runs (add1 (unbox runs)))
         (error 'x "boom")))))
  (check-equal? (unbox runs) 1 "root bracket, failure path"))

(test-case "a span-name thunk that RAISES degrades to no span, and the body still runs once"
  (fresh!)
  (define runs (box 0))
  (define r
    (in-local-trace
     (lambda ()
       (with-span (sp (error 'x "name blew up") 'client '())
         (set-box! runs (add1 (unbox runs)))
         'done))))
  (check-equal? r 'done "instrumentation never turns a working call into a failure")
  (check-equal? (unbox runs) 1)
  (check-equal? (spans-snapshot) '()))

(test-case "the mutators tolerate #f (an un-recorded span needs no `when` at the call site)"
  (check-not-exn (lambda () (span-set-name! #f "x")))
  (check-not-exn (lambda () (span-add-attributes! #f (list (cons 'a 1)))))
  (check-not-exn (lambda () (span-mark-error! #f "x"))))

(test-case "the buffer is bounded and drops the OLDEST span"
  (fresh!)
  (in-local-trace
   (lambda ()
     (for ([i (in-range (+ span-buffer-limit 5))])
       (with-span (sp (format "s~a" i) 'internal '()) (void)))))
  (define spans (spans-snapshot))
  (check-equal? (length spans) span-buffer-limit)
  (check-false (for/or ([s spans]) (equal? (recorded-span-name s) "s0"))
               "the oldest span is the one dropped")
  (check-true (for/or ([s spans])
                (equal? (recorded-span-name s)
                        (format "s~a" (+ span-buffer-limit 4))))
              "the newest span is always kept"))

;;; ── 2. UNIT: OTLP mapping ────────────────────────────────────────────────────

(define (export-jsexpr)
  (spans->otlp-jsexpr (spans-snapshot) #:service-name "trace-svc"))

(define (spans-of j)
  (hash-ref (first (hash-ref (first (hash-ref j 'resourceSpans)) 'scopeSpans)) 'spans))

(test-case "an empty span list yields an empty resourceSpans array"
  (fresh!)
  (check-equal? (spans->otlp-jsexpr '() #:service-name "s") (hash 'resourceSpans '())))

(test-case "OTLP shape: hex ids, SpanKind numbers, nano-string timestamps, service.name"
  (fresh!)
  (call-with-trace-ctx
   (make-root-trace-ctx #:traceparent SAMPLE-TP)
   (lambda ()
     (with-server-span (root "POST /notes" 'server (list (cons 'http.request.method "POST")))
       (with-span (child "db.query notes" 'client (list (cons 'db.param_count 2))) (void)))))
  (define j (export-jsexpr))
  (check-equal?
   (hash-ref (hash-ref (first (hash-ref (hash-ref (first (hash-ref j 'resourceSpans))
                                                  'resource)
                                        'attributes))
                       'value)
             'stringValue)
   "trace-svc")
  (define spans (spans-of j))
  (check-equal? (length spans) 2)
  (define server (for/first ([s spans] #:when (= (hash-ref s 'kind) 2)) s))
  (define client (for/first ([s spans] #:when (= (hash-ref s 'kind) 3)) s))
  (check-pred hash? server "SPAN_KIND_SERVER = 2")
  (check-pred hash? client "SPAN_KIND_CLIENT = 3")
  (check-equal? (hash-ref server 'traceId) "4bf92f3577b34da6a3ce929d0e0e4736")
  (check-equal? (hash-ref server 'parentSpanId) "00f067aa0ba902b7")
  (check-equal? (hash-ref client 'parentSpanId) (hash-ref server 'spanId))
  (check-true (string? (hash-ref server 'startTimeUnixNano)))
  (check-true (regexp-match? #rx"^[0-9]+$" (hash-ref server 'endTimeUnixNano))
              "epoch nanos as a decimal STRING (OTLP int64 rule)")
  (check-equal? (hash-ref (hash-ref server 'status) 'code) 0 "STATUS_CODE_UNSET")
  ;; attribute AnyValue tagging comes from the shared renderer
  (define kv (first (hash-ref client 'attributes)))
  (check-equal? (hash-ref kv 'key) "db.param_count")
  (check-equal? (hash-ref (hash-ref kv 'value) 'intValue) "2"))

(test-case "a root span has NO parentSpanId key at all (not an empty string)"
  (fresh!)
  (in-local-trace (lambda () (with-server-span (sp "GET" 'server '()) (void))))
  (check-false (hash-ref (first (spans-of (export-jsexpr))) 'parentSpanId #f)))

(test-case "an error span maps to STATUS_CODE_ERROR with its message"
  (fresh!)
  (with-handlers ([exn:fail? void])
    (in-local-trace
     (lambda () (with-span (sp "bad" 'client '()) (error 'x "kaput")))))
  (define st (hash-ref (first (spans-of (export-jsexpr))) 'status))
  (check-equal? (hash-ref st 'code) 2)
  (check-true (regexp-match? #rx"kaput" (hash-ref st 'message))))

(test-case "every SpanKind maps to its proto number"
  (fresh!)
  (in-local-trace
   (lambda ()
     (with-span (a "i" 'internal '()) (void))
     (with-span (b "p" 'producer '()) (void))
     (with-span (c "q" 'consumer '()) (void))))
  (define kinds (sort (map (lambda (s) (hash-ref s 'kind)) (spans-of (export-jsexpr))) <))
  (check-equal? kinds '(1 4 5)))

(test-case "the whole request round-trips through jsexpr->string (valid JSON)"
  (fresh!)
  (in-local-trace
   (lambda ()
     (with-server-span (root "GET /x" 'server (list (cons 'ok #t) (cons 'ratio 0.5)))
       (with-span (c "child" 'client '()) (void)))))
  (check-not-exn (lambda () (string->jsexpr (jsexpr->string (export-jsexpr))))))

(test-case "otlp-traces-url appends /v1/traces unless present"
  (check-equal? (otlp-traces-url "http://c:4318") "http://c:4318/v1/traces")
  (check-equal? (otlp-traces-url "http://c:4318/") "http://c:4318/v1/traces")
  (check-equal? (otlp-traces-url "http://c:4318/v1/traces") "http://c:4318/v1/traces"))

;;; ── 3. END-TO-END: a real request produces the tree ──────────────────────────

(require (only-in "../dsl/web.rkt"
                  define-handler define-api define-server dispatch-request
                  make-request))

;; Wrapped outside the handler: `define-handler` rewrites dotted identifiers in
;; its body as Tesl field access, so `HttpClient.get` cannot appear there directly.
(define (probe-outbound-call!)
  (HttpClient.get "https://billing.internal/invoice/42" '()))

(define-handler (traced-ping)
  #:returns String
  (let ([_ (probe-outbound-call!)])
    "pong"))

(define-api TracedProbeAPI
  [traced-ping : "ping" :> (Get JSON String)])

(define-server TracedProbeServer
  #:api TracedProbeAPI
  [traced-ping traced-ping])

(test-case "an inbound traceparent yields a SERVER span with an outbound CLIENT child"
  (fresh!)
  (parameterize ([current-outbound-http-hook
                  (lambda (_mode _method _url _headers _body)
                    (hash 'status 200 'body "" 'headers '()))])
    (dispatch-request TracedProbeServer
                      (make-request 'GET '("ping")
                                    #:headers (hash "traceparent" SAMPLE-TP))
                      #:capabilities (list httpClient)))
  (define spans (spans-snapshot))
  (check-equal? (length spans) 2 "one SERVER span, one CLIENT span")
  (define server (for/first ([s spans] #:when (eq? (recorded-span-kind s) 'server)) s))
  (define client (for/first ([s spans] #:when (eq? (recorded-span-kind s) 'client)) s))
  (check-pred recorded-span? server)
  (check-pred recorded-span? client)
  ;; the caller's trace is CONTINUED, and the caller's span is our parent
  (check-equal? (recorded-span-trace-id server) "4bf92f3577b34da6a3ce929d0e0e4736")
  (check-equal? (recorded-span-parent-span-id server) "00f067aa0ba902b7")
  ;; the span name is refined to METHOD + operation, never the raw path
  (check-equal? (recorded-span-name server) "GET traced-ping")
  (check-equal? (cdr (assq 'tesl.operation (recorded-span-attributes server)))
                "traced-ping")
  (check-equal? (cdr (assq 'http.response.status_code (recorded-span-attributes server)))
                200)
  ;; …and the outbound call is a CHILD of the request span
  (check-equal? (recorded-span-parent-span-id client) (recorded-span-span-id server))
  (check-equal? (recorded-span-name client) "GET billing.internal")
  (check-equal? (cdr (assq 'server.address (recorded-span-attributes client)))
                "billing.internal")
  (check-equal? (cdr (assq 'url.path (recorded-span-attributes client)))
                "/invoice/42"))

(test-case "with traces off the SAME request records nothing"
  (fresh! #:enabled? #f)
  (parameterize ([current-outbound-http-hook
                  (lambda (_mode _method _url _headers _body)
                    (hash 'status 200 'body "" 'headers '()))])
    (dispatch-request TracedProbeServer
                      (make-request 'GET '("ping")
                                    #:headers (hash "traceparent" SAMPLE-TP))
                      #:capabilities (list httpClient)))
  (check-equal? (spans-snapshot) '()))

(test-case "an UNSAMPLED inbound request records nothing but still responds"
  (fresh!)
  (define response
    (parameterize ([current-outbound-http-hook
                    (lambda (_mode _method _url _headers _body)
                      (hash 'status 200 'body "" 'headers '()))])
      (dispatch-request TracedProbeServer
                        (make-request 'GET '("ping")
                                      #:headers
                                      (hash "traceparent"
                                            "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00"))
                        #:capabilities (list httpClient))))
  (check-pred procedure? void)
  (check-equal? (spans-snapshot) '())
  (check-true (and response #t)))

;;; ── 3b. QUEUE PROPAGATION: the job joins the trace that enqueued it ──────────
;;;
;;; A worker outlives the request that enqueued to it (and usually runs in another
;;; process), so the link is carried in DATA — the enqueuer's `traceparent` rides
;;; the job payload envelope — never by ambient context.  Letting a stale ambient
;;; parent leak in is how a worker's span ends up attached to an unrelated request.

(require (only-in "../tesl/queue.rkt"
                  define-queue enqueue! process-next-job! queueRead queueWrite)
         (only-in "../dsl/types.rkt" define-record))

(define-record TraceProbeJob [note : String])

(define-queue TraceProbeJobs
  #:job-types (TraceProbeJob)
  #:max-attempts 3
  #:backoff exponential
  #:initial-delay 5)

(test-case "a queued job's span is a CHILD of the request that enqueued it"
  (fresh!)
  (define job-trace-ids (box '()))
  (parameterize ([current-capabilities (list queueRead queueWrite)])
    ;; enqueue inside a sampled request trace…
    (call-with-trace-ctx
     (make-root-trace-ctx #:traceparent SAMPLE-TP)
     (lambda ()
       (with-server-span (root "POST /notes" 'server '())
         (enqueue! TraceProbeJobs (TraceProbeJob #:note "hello")))))
    (define enqueue-span (first (spans-snapshot)))
    ;; …then drain it with NO ambient context at all, as a worker thread would
    (process-next-job! TraceProbeJobs
                       (lambda (_job)
                         (set-box! job-trace-ids
                                   (cons (current-trace-ctx) (unbox job-trace-ids)))
                         'ok))
    (define spans (spans-snapshot))
    (define job-span
      (for/first ([s spans] #:when (eq? (recorded-span-kind s) 'consumer)) s))
    (check-pred recorded-span? job-span "the job attempt produced a CONSUMER span")
    (check-equal? (recorded-span-trace-id job-span)
                  "4bf92f3577b34da6a3ce929d0e0e4736"
                  "same trace as the request that enqueued it")
    (check-equal? (recorded-span-parent-span-id job-span)
                  (recorded-span-span-id enqueue-span)
                  "parented on the ENQUEUER's span, carried through the job row")
    (check-equal? (cdr (assq 'tesl.queue (recorded-span-attributes job-span)))
                  "TraceProbeJobs")
    ;; the handler body sees the trace context, so its logs correlate too
    (define handler-ctx (first (unbox job-trace-ids)))
    (check-pred trace-ctx? handler-ctx)
    (check-equal? (trace-ctx-trace-id handler-ctx)
                  "4bf92f3577b34da6a3ce929d0e0e4736")))

(test-case "a job enqueued OUTSIDE a trace starts its own trace, not a dangling one"
  (fresh!)
  (parameterize ([current-capabilities (list queueRead queueWrite)])
    (enqueue! TraceProbeJobs (TraceProbeJob #:note "untraced"))
    (process-next-job! TraceProbeJobs (lambda (_job) 'ok)))
  (define job-span
    (for/first ([s (spans-snapshot)] #:when (eq? (recorded-span-kind s) 'consumer)) s))
  (check-pred recorded-span? job-span)
  (check-false (recorded-span-parent-span-id job-span)
               "no enqueuer span to point at, so the job IS the root"))

(test-case "the job payload round-trips unchanged with the trace envelope attached"
  (fresh!)
  (define seen (box #f))
  (parameterize ([current-capabilities (list queueRead queueWrite)])
    (call-with-trace-ctx
     (make-root-trace-ctx #:traceparent SAMPLE-TP)
     (lambda () (enqueue! TraceProbeJobs (TraceProbeJob #:note "payload intact"))))
    (process-next-job! TraceProbeJobs
                       (lambda (job) (set-box! seen job) 'ok)))
  (check-true (and (unbox seen) #t) "the handler received its job"))

;;; ── 3c. THE DB SPAN: the one that answers the N+1 question ───────────────────
;;;
;;; `with-sql-capture` is the seam every postgres-* execution flows through, so it
;;; is where the per-statement span comes from.  Driving it directly (rather than
;;; through a live PostgreSQL) is what makes the attribute discipline testable in
;;; the offline gate — and that discipline is a SECURITY property, not a cosmetic
;;; one: a bound parameter of a `secret` column really is the secret (storage is
;;; not rendering), and a span travels further than a log line.

(require (only-in "../dsl/sql.rkt" with-sql-capture))

(test-case "one CLIENT span per statement, with operation + table + row count"
  (fresh!)
  (define rows '("a" "b" "c"))
  (define result
    (in-local-trace
     (lambda ()
       (with-sql-capture "select id from notes where owner_id = $1" '("u_7")
                         "notes" 'select-many
                         (lambda () rows)
                         (lambda (rs) (length rs))))))
  (check-equal? result rows "the query result flows through untouched")
  (define spans (spans-snapshot))
  (check-equal? (length spans) 1)
  (define sp (first spans))
  (check-equal? (recorded-span-name sp) "db.query notes")
  (check-equal? (recorded-span-kind sp) 'client)
  (define attrs (recorded-span-attributes sp))
  (check-equal? (cdr (assq 'db.operation.name attrs)) "select-many")
  (check-equal? (cdr (assq 'tesl.table attrs)) "notes")
  (check-equal? (cdr (assq 'db.param_count attrs)) 1)
  (check-equal? (cdr (assq 'db.response.returned_rows attrs)) 3))

(test-case "N identical statements produce N sibling spans — the N+1 shape"
  (fresh!)
  (call-with-trace-ctx
   (make-root-trace-ctx #:traceparent SAMPLE-TP)
   (lambda ()
     (with-server-span (root "POST /notes" 'server '())
       (for ([i (in-range 40)])
         (with-sql-capture "select id from tags where note_id = $1" (list i)
                           "tags" 'select-many
                           (lambda () '("t")) (lambda (rs) (length rs)))))))
  (define spans (spans-snapshot))
  (define root (for/first ([s spans] #:when (eq? (recorded-span-kind s) 'server)) s))
  (define children (filter (lambda (s) (eq? (recorded-span-kind s) 'client)) spans))
  (check-equal? (length children) 40)
  (check-true (for/and ([c children])
                (equal? (recorded-span-parent-span-id c) (recorded-span-span-id root)))
              "all 40 hang off the request span, which is what makes the tree readable"))

(test-case "the db span carries NO bound parameters — not even a secret one"
  (fresh!)
  (in-local-trace
   (lambda ()
     (with-sql-capture "insert into users (email, api_key) values ($1, $2)"
                       (list "a@b.c" (TraceProbeToken "hunter2"))
                       "users" 'insert-one!
                       (lambda () 1) (lambda (_) 1))))
  (define body (jsexpr->string (export-jsexpr)))
  (check-false (regexp-match? #rx"hunter2" body)
               "a secret bound parameter must not reach the collector")
  (check-false (regexp-match? #rx"a@b.c" body)
               "…and neither does an ordinary parameter: shape, not payload")
  ;; the statement itself is off by default too
  (check-false (regexp-match? #rx"insert into users" body)
               "db.statement is opt-in (TESL_TRACE_DB_STATEMENT)"))

(test-case "TESL_TRACE_DB_STATEMENT=1 adds the parameterized statement, condensed"
  (fresh!)
  (putenv "TESL_TRACE_DB_STATEMENT" "1")
  (in-local-trace
   (lambda ()
     (with-sql-capture "select id\n   from notes\n   where owner_id = $1" '("u_7")
                       "notes" 'select-many
                       (lambda () '()) (lambda (rs) (length rs)))))
  (putenv "TESL_TRACE_DB_STATEMENT" "")
  (define stmt (cdr (assq 'db.statement (recorded-span-attributes (first (spans-snapshot))))))
  (check-equal? stmt "select id from notes where owner_id = $1"
                "whitespace-condensed, placeholders intact, no values")
  ;; and it goes back off with the env var cleared
  (fresh!)
  (in-local-trace
   (lambda ()
     (with-sql-capture "select 1" '() "notes" 'select-many
                       (lambda () '()) (lambda (rs) (length rs)))))
  (check-false (assq 'db.statement (recorded-span-attributes (first (spans-snapshot))))))

(test-case "with traces off the seam still records the row count for SQL capture"
  ;; `count-of` is now called ONCE inside the span body and shared with
  ;; sql-capture-executed!.  With traces off that body still runs, so the capture
  ;; behaviour every PostgreSQL-backed test depends on is unchanged.
  (fresh! #:enabled? #f)
  (define calls (box 0))
  (define result
    (with-sql-capture "select 1" '() "notes" 'select-many
                      (lambda () '("r"))
                      (lambda (rs) (set-box! calls (add1 (unbox calls))) (length rs))))
  (check-equal? result '("r"))
  (check-equal? (unbox calls) 1 "counted exactly once, not once per consumer")
  (check-equal? (spans-snapshot) '()))

;;; ── 4. INTEGRATION: a configured endpoint receives the batch ─────────────────
;;;
;;; Same in-process sink shape as the logs/metrics exporter tests.

(define (start-otlp-sink #:expect [expect 1])
  (define listener (tcp-listen 0 8 #t "127.0.0.1"))
  (define-values (_la port _ra _rp) (tcp-addresses listener #t))
  (define recorded (box '()))
  (define done (make-semaphore 0))
  (define server
    (thread
     (lambda ()
       (with-handlers ([exn:fail? void])
         (for ([_ (in-range expect)])
           (define-values (in out) (tcp-accept listener))
           (define first-line (read-line in 'any))
           (define parts (string-split (or (and (string? first-line) first-line) "") " "))
           (define method (if (pair? parts) (first parts) ""))
           (define path   (if (>= (length parts) 2) (second parts) ""))
           (define clen 0)
           (let loop ()
             (define line (read-line in 'any))
             (unless (or (eof-object? line) (string=? line ""))
               (when (regexp-match? #rx"^(?i:content-length):" line)
                 (define n (string->number
                            (string-trim (second (regexp-split #rx":" line)))))
                 (when n (set! clen n)))
               (loop)))
           (define body-str (if (> clen 0) (bytes->string/utf-8 (read-bytes clen in)) ""))
           (define body-json
             (with-handlers ([exn:fail? (lambda (_) #f)])
               (and (> (string-length body-str) 0) (string->jsexpr body-str))))
           (set-box! recorded (append (unbox recorded) (list (list method path body-json))))
           (define payload #"{}")
           (fprintf out
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ~a\r\nConnection: close\r\n\r\n"
                    (bytes-length payload))
           (write-bytes payload out)
           (flush-output out)
           (close-output-port out)
           (close-input-port in)
           (semaphore-post done))))))
  (define base-url (format "http://127.0.0.1:~a" port))
  (define (stop!)
    (kill-thread server)
    (with-handlers ([exn:fail? void]) (tcp-close listener)))
  (values base-url recorded done stop!))

(define (run-integration)
  (define-values (base recorded done stop!) (start-otlp-sink #:expect 1))
  (dynamic-wind
   void
   (lambda ()
     (init-opentelemetry! #:service-name "traces-svc"
                          #:endpoint base
                          #:console? #f
                          #:traces? #t
                          #:traces-interval-ms 100)
     (call-with-trace-ctx
      (make-root-trace-ctx #:traceparent SAMPLE-TP)
      (lambda ()
        (with-server-span (root "POST /notes" 'server '())
          (with-span (c "db.query notes" 'client '()) (void)))))
     (unless (sync/timeout 5 done)
       (error 'otlp-traces-integration "sink never received a POST within 5s"))
     (match-define (list method path body) (first (unbox recorded)))
     (test-case "POST to /v1/traces with a well-formed OTLP body"
       (check-equal? method "POST")
       (check-equal? path "/v1/traces")
       (check-pred hash? body)
       (define rs (first (hash-ref body 'resourceSpans)))
       (check-equal? (hash-ref (hash-ref (first (hash-ref (hash-ref rs 'resource)
                                                         'attributes))
                                         'value)
                               'stringValue)
                     "traces-svc")
       (define spans (hash-ref (first (hash-ref rs 'scopeSpans)) 'spans))
       (check-equal? (length spans) 2)
       (define server (for/first ([s spans] #:when (= (hash-ref s 'kind) 2)) s))
       (define client (for/first ([s spans] #:when (= (hash-ref s 'kind) 3)) s))
       (check-equal? (hash-ref server 'name) "POST /notes")
       (check-equal? (hash-ref client 'parentSpanId) (hash-ref server 'spanId))))
   (lambda ()
     (stop!)
     ;; do not leave the 100ms exporter running into later tests
     (init-opentelemetry! #:service-name "traces-svc" #:endpoint "in-memory"))))

(define (integration-or-skip)
  (define can-bind?
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (define l (tcp-listen 0 4 #t "127.0.0.1"))
      (tcp-close l)
      #t))
  (cond
    [can-bind? (run-integration)]
    [else
     (displayln "SKIPPED: OTLP traces integration test — cannot bind a localhost TCP port")]))

(integration-or-skip)

;;; ── 5. RESILIENCE ────────────────────────────────────────────────────────────

(test-case "an unreachable endpoint does NOT propagate through the record path"
  (init-opentelemetry! #:service-name "resil"
                       #:endpoint "http://127.0.0.1:1/collector"
                       #:console? #f
                       #:traces? #t
                       #:traces-interval-ms 100)
  (check-not-exn
   (lambda ()
     (in-local-trace (lambda () (with-span (sp "s" 'client '()) (void))))))
  (sleep 0.3) ; let the exporter attempt (and swallow) at least one failed POST
  (check-not-exn
   (lambda ()
     (in-local-trace (lambda () (with-span (sp "s" 'client '()) (void))))))
  (init-opentelemetry! #:service-name "resil" #:endpoint "in-memory"))

;;; ── 6. GATES ─────────────────────────────────────────────────────────────────

(test-case "traces default OFF — even with a real endpoint (unlike metrics)"
  (init-opentelemetry! #:service-name "g" #:endpoint "http://127.0.0.1:9/x")
  (check-false (traces-active?)
               "per-request span volume and egress are opt-in")
  (check-true (metrics-active?) "…while metrics still default on with an endpoint")
  (init-opentelemetry! #:service-name "g" #:endpoint "in-memory"))

(test-case "`traces True` with in-memory records with NO exporter"
  (init-opentelemetry! #:service-name "g" #:endpoint "in-memory" #:traces? #t)
  (check-true (traces-active?))
  (in-local-trace (lambda () (with-span (sp "local" 'internal '()) (void))))
  (check-equal? (length (spans-snapshot)) 1))

(test-case "re-init resets the span buffer"
  (init-opentelemetry! #:service-name "g" #:endpoint "in-memory" #:traces? #t)
  (in-local-trace (lambda () (with-span (sp "stale" 'internal '()) (void))))
  (init-opentelemetry! #:service-name "g" #:endpoint "in-memory" #:traces? #t)
  (check-equal? (spans-snapshot) '()))

(test-case "traceRatio reaches the sampler through initTelemetry"
  (init-opentelemetry! #:service-name "g" #:endpoint "in-memory"
                       #:traces? #t #:trace-ratio 0.0)
  (check-equal? (trace-sample-ratio) 0.0)
  (reset-traces!)
  ;; a trace that STARTS here is dropped by the ratio…
  (call-with-trace-ctx
   (make-root-trace-ctx #:ratio (trace-sample-ratio))
   (lambda () (with-span (sp "dropped" 'client '()) (void))))
  (check-equal? (spans-snapshot) '())
  ;; …but an inbound sampled decision is still respected
  (call-with-trace-ctx
   (make-root-trace-ctx #:traceparent SAMPLE-TP #:ratio (trace-sample-ratio))
   (lambda () (with-span (sp "kept" 'client '()) (void))))
  (check-equal? (length (spans-snapshot)) 1)
  (init-opentelemetry! #:service-name "g" #:endpoint "in-memory"))

;;; ── 7. SECRETS ───────────────────────────────────────────────────────────────

(test-case "a `secret` span attribute value REDACTS in the OTLP export"
  ;; Spans are a new rendering sink, and the roadmap named this as the risk:
  ;; "spans become the one sink that leaks a `secret` column".  They cannot,
  ;; because they render through dsl/otlp-value.rkt like every other signal.
  (fresh!)
  (in-local-trace
   (lambda ()
     (with-span (sp "leaky?" 'client
                    (list (cons 'db.token (TraceProbeToken "hunter2"))
                          (cons 'plain "visible")))
       (void))))
  (define attrs (hash-ref (first (spans-of (export-jsexpr))) 'attributes))
  (define (value-of key)
    (for/first ([kv (in-list attrs)] #:when (equal? (hash-ref kv 'key) key))
      (hash-ref (hash-ref kv 'value) 'stringValue #f)))
  (check-equal? (value-of "db.token") secret-redaction-text)
  (check-equal? (value-of "plain") "visible" "siblings render normally")
  (check-false (regexp-match? #rx"hunter2" (jsexpr->string (export-jsexpr)))
               "the plaintext appears NOWHERE in the exported body"))

(test-case "a nested secret redacts too (the renderer is structural)"
  (fresh!)
  (in-local-trace
   (lambda ()
     (with-span (sp "nested" 'client
                    (list (cons 'payload (list "a" (TraceProbeToken "s3cret") "b"))))
       (void))))
  (check-false (regexp-match? #rx"s3cret" (jsexpr->string (export-jsexpr)))))
