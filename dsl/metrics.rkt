#lang racket

;;; OpenTelemetry Metrics for Tesl — in-process pre-aggregating registry +
;;; periodic OTLP/HTTP+JSON exporter (Metrics signal, /v1/metrics).
;;;
;;; Sibling of dsl/otel.rkt (Logs signal).  Same transport rules: OTLP/HTTP+JSON
;;; only, POST via the shared tesl/http-client.rkt under an ambient httpClient
;;; grant, and the export path NEVER raises — a dead collector degrades to a
;;; missed interval, and because aggregation is CUMULATIVE the next successful
;;; export carries the full state anyway (no buffer, no drop policy needed).
;;;
;;; RECORD PATH.  metric-counter-add! / metric-histogram-record! /
;;; metric-gauge-set! are O(1) hash updates under one semaphore and never raise.
;;; All three no-op unless metrics are enabled (init-opentelemetry! #:metrics?),
;;; so instrumentation sites pay one unbox when metrics are off.
;;;
;;; CARDINALITY.  Per (kind . name) instrument, at most metric-cardinality-limit
;;; distinct attribute sets are kept (OTel SDK default 2000).  Overflow points
;;; fold into the spec's {otel.metric.overflow = "true"} set instead of growing
;;; without bound — the SaaS-at-scale containment for an ID leaking into attrs.
;;;
;;; Dependency direction: like tesl/logging.rkt this module requires only
;;; racket/json/runtime-path + the domain registry, so logging.rkt, dsl/web.rkt,
;;; dsl/sql.rkt, tesl/queue.rkt, tesl/sse.rkt, tesl/agent-provider.rkt and
;;; dsl/otel.rkt can all require it with no cycle.

(require json
         racket/runtime-path
         (only-in ffi/unsafe/atomic call-as-atomic)
         (only-in "private/domain-registry.rkt" register-background-thread!))

(provide metrics-active?
         set-metrics-enabled!
         metric-counter-add!
         metric-histogram-record!
         metric-gauge-set!
         metrics-snapshot
         reset-metrics!
         metrics-snapshot->otlp-jsexpr
         otlp-metrics-url
         start-metrics-exporter!
         stop-metrics-exporter!
         metric-cardinality-limit
         duration-histogram-boundaries
         default-histogram-boundaries)

;; ── Enabled flag ─────────────────────────────────────────────────────────────

(define metrics-enabled-box (box #f))

(define (metrics-active?) (unbox metrics-enabled-box))

(define (set-metrics-enabled! on?) (set-box! metrics-enabled-box (and on? #t)))

;; ── Registry ─────────────────────────────────────────────────────────────────
;;
;; instruments : hash of (cons kind name) → instrument
;;   kind ∈ 'counter 'histogram 'gauge (a name used with two kinds yields two
;;   independent instruments rather than a runtime error).
;; Each instrument owns its points hash: normalized-attrs → point state.
;;   counter   point: box of running sum (exact or inexact number)
;;   gauge     point: box of last value
;;   histogram point: hist struct (mutable bucket counts vector + sum + count)
;; Timestamps: process start is the cumulative startTimeUnixNano for every
;; point; export stamps timeUnixNano at snapshot time.

(struct instrument (kind name unit boundaries points) #:transparent)
;; points: mutable hash attrs → point
(struct hist (bucket-counts [sum #:mutable] [count #:mutable]) #:transparent)

;; KILL-SAFETY: record paths run on web-server connection threads, which the
;; server kills at ARBITRARY points (custodian shutdown on client disconnect /
;; response timeout — the same hazard tesl/sse.rkt documents).  A semaphore
;; here would leak forever if a kill landed inside the critical section, after
;; which every recorder in the process would block — so the registry uses
;; ATOMIC MODE instead: thread swaps (and therefore kills) are deferred until
;; the section exits, and there is no lock object to strand.  Sections must be
;; tiny and non-blocking; every one below is O(1) hash/vector work except the
;; snapshot copy (exporter-thread only, size-capped by the cardinality limit).
(define (with-registry thunk) (call-as-atomic thunk))
(define instruments (make-hash))
;; Cumulative startTimeUnixNano.  A box, not a constant: reset-metrics! must
;; ADVANCE it — OTLP cumulative streams that restart from zero without a new
;; start time are rejected (or mis-rated) by collectors.
(define start-ms-box (box (current-inexact-milliseconds)))

(define metric-cardinality-limit 2000)
(define overflow-attrs '(("otel.metric.overflow" . "true")))

;; OTel spec default explicit bucket boundaries (generic magnitudes).
(define default-histogram-boundaries
  '(0.0 5.0 10.0 25.0 50.0 75.0 100.0 250.0 500.0 750.0 1000.0 2500.0 5000.0 7500.0 10000.0))
;; Semconv-recommended boundaries for durations measured in SECONDS
;; (http.server.request.duration et al).
(define duration-histogram-boundaries
  '(0.005 0.01 0.025 0.05 0.075 0.1 0.25 0.5 0.75 1.0 2.5 5.0 7.5 10.0))

;; Normalize an attribute list to a canonical, comparable key: string keys and
;; string values, sorted by key.  Accepts (k . v) pairs with symbol/string keys
;; and any display-able values.  Sorted so {a=1,b=2} and {b=2,a=1} are one point.
(define (normalize-attrs attrs)
  (sort
   (for/list ([entry (in-list attrs)])
     (cons (if (string? (car entry)) (car entry) (~a (car entry)))
           (if (string? (cdr entry)) (cdr entry) (~a (cdr entry)))))
   string<? #:key car))

(define (instrument-ref! kind name unit boundaries)
  (hash-ref! instruments (cons kind name)
             (lambda ()
               (instrument kind name unit
                           (and boundaries (map exact->inexact boundaries))
                           (make-hash)))))

;; Look up (creating if within the cardinality limit) the point key for the
;; PRE-NORMALIZED attrs on `inst`.  Past the limit, new attribute sets fold
;; into the overflow set.  Takes normalized attrs so the callers' atomic
;; sections do no string formatting.
(define (point-attrs-for* inst norm)
  (if (or (hash-has-key? (instrument-points inst) norm)
          (< (hash-count (instrument-points inst)) metric-cardinality-limit))
      norm
      normalized-overflow-attrs))
(define normalized-overflow-attrs (normalize-attrs overflow-attrs))

;; All three recorders: no-op when disabled, never raise (a malformed attr value
;; must not take down a request handler — same bar as the logs emit path).

(define (metric-counter-add! name value [attrs '()] #:unit [unit #f])
  (when (metrics-active?)
    (with-handlers ([(lambda (_) #t) (lambda (_) (void))])
      ;; Normalize OUTSIDE the atomic section — ~a on arbitrary values may
      ;; allocate/raise; the atomic body stays pure hash/arithmetic work.
      (define norm (normalize-attrs attrs))
      (with-registry
        (lambda ()
          (define inst (instrument-ref! 'counter name unit #f))
          (define key (point-attrs-for* inst norm))
          (define b (hash-ref! (instrument-points inst) key (lambda () (box 0))))
          (set-box! b (+ (unbox b) value)))))))

(define (metric-gauge-set! name value [attrs '()] #:unit [unit #f])
  (when (metrics-active?)
    (with-handlers ([(lambda (_) #t) (lambda (_) (void))])
      (define norm (normalize-attrs attrs))
      (with-registry
        (lambda ()
          (define inst (instrument-ref! 'gauge name unit #f))
          (define key (point-attrs-for* inst norm))
          (define b (hash-ref! (instrument-points inst) key (lambda () (box 0))))
          (set-box! b value))))))

(define (metric-histogram-record! name value [attrs '()]
                                  #:unit [unit #f]
                                  #:boundaries [boundaries #f])
  (when (metrics-active?)
    (with-handlers ([(lambda (_) #t) (lambda (_) (void))])
      (define norm (normalize-attrs attrs))
      (define v (exact->inexact value))
      (with-registry
        (lambda ()
          ;; First record wins the boundary/unit choice for this instrument.
          (define inst (instrument-ref! 'histogram name unit
                                        (or boundaries default-histogram-boundaries)))
          (define bounds (instrument-boundaries inst))
          (define key (point-attrs-for* inst norm))
          (define h (hash-ref! (instrument-points inst) key
                               (lambda ()
                                 (hist (make-vector (add1 (length bounds)) 0) 0.0 0))))
          ;; Bucket index: first boundary >= v (upper-inclusive per OTLP).
          (define idx
            (let loop ([bs bounds] [i 0])
              (cond [(null? bs) i]
                    [(<= v (car bs)) i]
                    [else (loop (cdr bs) (add1 i))])))
          (vector-set! (hist-bucket-counts h) idx
                       (add1 (vector-ref (hist-bucket-counts h) idx)))
          (set-hist-sum! h (+ (hist-sum h) v))
          (set-hist-count! h (add1 (hist-count h))))))))

;; Deep-copy the registry state so export/serialization runs outside the lock.
;; Returns a list of (list kind name unit boundaries (list (cons attrs state)…))
;; where state is a number (counter/gauge) or (vector bucket-counts sum count).
(define (metrics-snapshot)
  (with-registry
    (lambda ()
      (for/list ([(k inst) (in-hash instruments)])
        (list (instrument-kind inst)
              (instrument-name inst)
              (instrument-unit inst)
              (instrument-boundaries inst)
              (for/list ([(attrs point) (in-hash (instrument-points inst))])
                (cons attrs
                      (match (instrument-kind inst)
                        [(or 'counter 'gauge) (unbox point)]
                        ['histogram (vector (vector-copy (hist-bucket-counts point))
                                            (hist-sum point)
                                            (hist-count point))]))))))))

(define (reset-metrics!)
  (with-registry
    (lambda ()
      (hash-clear! instruments)
      ;; Cumulative reset ⇒ new startTimeUnixNano (OTLP temporality rule).
      (set-box! start-ms-box (current-inexact-milliseconds)))))

;; ── OTLP mapping (pure, unit-testable) ───────────────────────────────────────
;;
;; snapshot → one ExportMetricsServiceRequest jsexpr.  Follows the OTLP/JSON
;; encoding rules already proven for the Logs signal: int64/uint64 fields are
;; decimal STRINGS, timestamps are epoch-nanos strings, enums are their proto
;; numbers (AGGREGATION_TEMPORALITY_CUMULATIVE = 2).

(define (ms->nano-string ms)
  (number->string (inexact->exact (round (* ms 1000000.0)))))

(define (attrs->otlp-key-values attrs)
  (for/list ([entry (in-list attrs)])
    (hash 'key (car entry)
          'value (hash 'stringValue (cdr entry)))))

(define (number->otlp-point-value v)
  ;; asInt for exact integers (as a string, int64 rule), asDouble otherwise.
  (if (exact-integer? v)
      (cons 'asInt (number->string v))
      (cons 'asDouble (exact->inexact v))))

(define (metrics-snapshot->otlp-jsexpr snapshot
                                       #:service-name service-name
                                       #:now-ms [now-ms (current-inexact-milliseconds)]
                                       #:start-ms [start-ms (unbox start-ms-box)])
  (define start-nano (ms->nano-string start-ms))
  (define now-nano (ms->nano-string now-ms))
  (define (base-point attrs)
    (hash 'startTimeUnixNano start-nano
          'timeUnixNano now-nano
          'attributes (attrs->otlp-key-values attrs)))
  (define metrics
    (for/list ([entry (in-list snapshot)])
      (match-define (list kind name unit boundaries points) entry)
      (define body
        (match kind
          ['counter
           (hash 'dataPoints
                 (for/list ([p (in-list points)])
                   (define kv (number->otlp-point-value (cdr p)))
                   (hash-set (base-point (car p)) (car kv) (cdr kv)))
                 'aggregationTemporality 2
                 'isMonotonic #t)]
          ['gauge
           (hash 'dataPoints
                 (for/list ([p (in-list points)])
                   (define kv (number->otlp-point-value (cdr p)))
                   (hash-set (base-point (car p)) (car kv) (cdr kv))))]
          ['histogram
           (hash 'dataPoints
                 (for/list ([p (in-list points)])
                   (define state (cdr p))
                   (define buckets (vector-ref state 0))
                   (define sum (vector-ref state 1))
                   (define count (vector-ref state 2))
                   (hash-set* (base-point (car p))
                              'count (number->string count)
                              'sum (exact->inexact sum)
                              'bucketCounts (for/list ([c (in-vector buckets)])
                                              (number->string c))
                              'explicitBounds (or boundaries '())))
                 'aggregationTemporality 2)]))
      (define tagged
        (hash (match kind ['counter 'sum] ['gauge 'gauge] ['histogram 'histogram])
              body
              'name name))
      (if unit (hash-set tagged 'unit unit) tagged)))
  (hash 'resourceMetrics
        (list (hash 'resource
                    (hash 'attributes
                          (list (hash 'key "service.name"
                                      'value (hash 'stringValue service-name))))
                    'scopeMetrics
                    (list (hash 'scope (hash 'name "tesl")
                                'metrics metrics))))))

;; ── Exporter ─────────────────────────────────────────────────────────────────

;; Normalize an endpoint to its /v1/metrics URL (same trimming rules as the
;; logs exporter's otlp-logs-url).
(define (otlp-metrics-url endpoint)
  (define trimmed (regexp-replace #rx"/+$" endpoint ""))
  (if (regexp-match? #rx"/v1/metrics$" trimmed)
      trimmed
      (string-append trimmed "/v1/metrics")))

(define-runtime-path metrics-http-client-source "../tesl/http-client.rkt")
(define-runtime-path metrics-capability-source "capability.rkt")

;; POST one snapshot.  NEVER raises (same contract as otlp-post-batch! in
;; dsl/otel.rkt); on failure the cumulative state simply rides the next tick.
(define (otlp-post-metrics! endpoint headers jsexpr)
  (with-handlers ([(lambda (_) #t) (lambda (_) (void))])
    (define post (dynamic-require metrics-http-client-source 'HttpClient.post))
    (define http-cap (dynamic-require metrics-http-client-source 'httpClient))
    (define cap-current (dynamic-require metrics-capability-source 'current-capabilities))
    (define expand-caps (dynamic-require metrics-capability-source 'expand-capabilities))
    (define header-list
      (cons (list "content-type" "application/json")
            (for/list ([h (in-list headers)]) (list (car h) (cdr h)))))
    (parameterize ([cap-current (expand-caps (cons http-cap (cap-current)))])
      (post (otlp-metrics-url endpoint) header-list (jsexpr->string jsexpr)))
    (void)))

;; One exporter at a time: init-opentelemetry! may run more than once (tests,
;; re-init).  Shutdown is COOPERATIVE — bumping the generation makes a stale
;; exporter loop exit after its current sleep — because kill-thread would
;; require the killer's custodian to manage the thread, and re-init can happen
;; under a different custodian than the one that started the exporter.
(define exporter-generation (box 0))

(define (stop-metrics-exporter!)
  (set-box! exporter-generation (add1 (unbox exporter-generation))))

(define (start-metrics-exporter! #:endpoint endpoint
                                 #:headers [headers '()]
                                 #:interval-ms [interval-ms 60000]
                                 #:service-name-thunk service-name-thunk)
  (stop-metrics-exporter!)
  (define my-generation (unbox exporter-generation))
  ;; Clamp: the surface type is a bare Int, so a negative value would make the
  ;; very first (sleep …) raise and silently kill the exporter thread, and 0
  ;; would busy-loop POSTing every scheduler tick.  1s is the floor a collector
  ;; can reasonably be asked to ingest at.
  (define safe-interval-ms
    (if (and (real? interval-ms) (>= interval-ms 1000)) interval-ms 1000))
  (register-background-thread!
   (thread
    (lambda ()
      (let loop ()
        (sleep (/ safe-interval-ms 1000.0))
        (when (= my-generation (unbox exporter-generation))
          (with-handlers ([(lambda (_) #t) (lambda (_) (void))])
            (define snapshot (metrics-snapshot))
            (unless (null? snapshot)
              (otlp-post-metrics!
               endpoint headers
               (metrics-snapshot->otlp-jsexpr snapshot
                                              #:service-name (service-name-thunk)))))
          (loop))))))
  (void))
