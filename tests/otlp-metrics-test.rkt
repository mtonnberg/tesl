#lang racket

;;; OTLP Metrics tests (dsl/metrics.rkt + init-opentelemetry! wiring).
;;;
;;; Mirrors otlp-exporter-test.rkt's tiers, all offline and deterministic:
;;;
;;;   1. UNIT — the registry (counter/histogram/gauge accumulation, attr
;;;      normalization, kind separation, enabled gate, cardinality cap) and the
;;;      pure metrics-snapshot->otlp-jsexpr mapping (sum/gauge/histogram shapes,
;;;      int64-as-string, cumulative temporality, explicitBounds).
;;;
;;;   2. INTEGRATION — an in-process localhost sink must receive a periodic
;;;      POST to <endpoint>/v1/metrics with the right JSON.  Self-SKIPS if it
;;;      cannot bind a port.
;;;
;;;   3. RESILIENCE — an unreachable collector never breaks the record path.
;;;
;;;   4. GATES — metrics recording is independent of the verbose/log gate:
;;;      #:metrics? #t with an in-memory endpoint records with no exporter and
;;;      no log sink; the default is on-with-real-endpoint, off otherwise.
;;;
;;; Run:  raco test tests/otlp-metrics-test.rkt

(require racket/tcp
         json
         rackunit
         "../dsl/metrics.rkt"
         "../dsl/otel.rkt"
         (only-in "../tesl/telemetry.rkt" counter)
         (only-in "../tesl/logging.rkt" tesl-log-active?))

;; Every test starts from a clean, enabled registry unless it says otherwise.
(define (fresh! #:enabled? [enabled? #t])
  (stop-metrics-exporter!)
  (reset-metrics!)
  (set-metrics-enabled! enabled?))

;;; ── 1a. UNIT: registry behavior ───────────────────────────────────────────────

(test-case "counter accumulates per attr set; attr order does not split points"
  (fresh!)
  (metric-counter-add! "c" 1 (list (cons "a" "1") (cons "b" "2")))
  (metric-counter-add! "c" 2 (list (cons "b" "2") (cons "a" "1")))
  (define snap (metrics-snapshot))
  (check-equal? (length snap) 1)
  (define points (fifth (first snap)))
  (check-equal? (length points) 1 "one point despite different attr order")
  (check-equal? (cdr (first points)) 3))

(test-case "distinct attr values are distinct points"
  (fresh!)
  (metric-counter-add! "c" 1 (list (cons "route" "a")))
  (metric-counter-add! "c" 1 (list (cons "route" "b")))
  (define points (fifth (first (metrics-snapshot))))
  (check-equal? (length points) 2))

(test-case "gauge keeps the last value"
  (fresh!)
  (metric-gauge-set! "g" 5)
  (metric-gauge-set! "g" 2)
  (check-equal? (cdr (first (fifth (first (metrics-snapshot))))) 2))

(test-case "histogram buckets are upper-inclusive; sum and count accumulate"
  (fresh!)
  (metric-histogram-record! "h" 0.005 '() #:boundaries duration-histogram-boundaries)
  (metric-histogram-record! "h" 0.006 '() #:boundaries duration-histogram-boundaries)
  (metric-histogram-record! "h" 99.0  '() #:boundaries duration-histogram-boundaries)
  (define state (cdr (first (fifth (first (metrics-snapshot))))))
  (define buckets (vector-ref state 0))
  (check-equal? (vector-ref buckets 0) 1 "0.005 lands in the first bucket (<= bound)")
  (check-equal? (vector-ref buckets 1) 1 "0.006 lands in the second")
  (check-equal? (vector-ref buckets (sub1 (vector-length buckets))) 1
                "99.0 lands in the overflow bucket")
  (check-= (vector-ref state 1) 99.011 1e-9)
  (check-equal? (vector-ref state 2) 3))

(test-case "same name with different kinds yields independent instruments"
  (fresh!)
  (metric-counter-add! "x" 1)
  (metric-gauge-set! "x" 7)
  (check-equal? (length (metrics-snapshot)) 2))

(test-case "disabled gate: nothing records, nothing raises"
  (fresh! #:enabled? #f)
  (check-not-exn (lambda () (metric-counter-add! "c" 1)))
  (check-not-exn (lambda () (metric-histogram-record! "h" 1.0)))
  (check-not-exn (lambda () (metric-gauge-set! "g" 1)))
  (check-equal? (metrics-snapshot) '()))

(test-case "malformed attrs never raise (record path contract)"
  (fresh!)
  (check-not-exn (lambda () (metric-counter-add! "c" 1 (list (cons 'sym 42)))))
  (check-not-exn (lambda () (metric-counter-add! "c" 1 "not-even-a-list"))))

(test-case "cardinality cap: excess attr sets fold into the overflow point"
  (fresh!)
  (for ([i (in-range (+ metric-cardinality-limit 5))])
    (metric-counter-add! "burst" 1 (list (cons "id" (number->string i)))))
  (define points (fifth (first (metrics-snapshot))))
  (check-equal? (length points) (add1 metric-cardinality-limit)
                "limit real points + 1 overflow point")
  (define overflow
    (for/first ([p (in-list points)]
                #:when (equal? (car p) '(("otel.metric.overflow" . "true"))))
      (cdr p)))
  (check-equal? overflow 5 "the 5 excess sets all landed on the overflow point"))

;;; ── 1b. UNIT: OTLP mapping ────────────────────────────────────────────────────

(define (snapshot-jsexpr!)
  (metrics-snapshot->otlp-jsexpr (metrics-snapshot)
                                 #:service-name "map-svc"
                                 #:now-ms 1700000000500.0
                                 #:start-ms 1700000000000.0))

(define (metrics-of j)
  (hash-ref (first (hash-ref (first (hash-ref j 'resourceMetrics)) 'scopeMetrics))
            'metrics))

(test-case "counter maps to a monotonic cumulative sum with asInt-as-string"
  (fresh!)
  (metric-counter-add! "req.count" 3 (list (cons "route" "getTodo")) #:unit "1")
  (define m (first (metrics-of (snapshot-jsexpr!))))
  (check-equal? (hash-ref m 'name) "req.count")
  (check-equal? (hash-ref m 'unit) "1")
  (define sum (hash-ref m 'sum))
  (check-equal? (hash-ref sum 'aggregationTemporality) 2 "CUMULATIVE")
  (check-true (hash-ref sum 'isMonotonic))
  (define dp (first (hash-ref sum 'dataPoints)))
  (check-equal? (hash-ref dp 'asInt) "3" "int64 rendered as a decimal STRING")
  (check-equal? (hash-ref dp 'startTimeUnixNano) "1700000000000000000")
  (check-equal? (hash-ref dp 'timeUnixNano) "1700000000500000000")
  (define a (first (hash-ref dp 'attributes)))
  (check-equal? (hash-ref a 'key) "route")
  (check-equal? (hash-ref (hash-ref a 'value) 'stringValue) "getTodo"))

(test-case "gauge maps to gauge dataPoints; non-integer values use asDouble"
  (fresh!)
  (metric-gauge-set! "temp" 3.5)
  (define m (first (metrics-of (snapshot-jsexpr!))))
  (define dp (first (hash-ref (hash-ref m 'gauge) 'dataPoints)))
  (check-equal? (hash-ref dp 'asDouble) 3.5))

(test-case "histogram maps count/bucketCounts as strings + explicitBounds"
  (fresh!)
  (metric-histogram-record! "dur" 0.03 '()
                            #:unit "s" #:boundaries duration-histogram-boundaries)
  (define m (first (metrics-of (snapshot-jsexpr!))))
  (check-equal? (hash-ref m 'unit) "s")
  (define h (hash-ref m 'histogram))
  (check-equal? (hash-ref h 'aggregationTemporality) 2)
  (define dp (first (hash-ref h 'dataPoints)))
  (check-equal? (hash-ref dp 'count) "1")
  (check-= (hash-ref dp 'sum) 0.03 1e-9)
  (check-equal? (hash-ref dp 'explicitBounds)
                duration-histogram-boundaries)
  (check-equal? (length (hash-ref dp 'bucketCounts))
                (add1 (length duration-histogram-boundaries)))
  (check-true (andmap string? (hash-ref dp 'bucketCounts))
              "bucketCounts are uint64 strings"))

(test-case "the whole request round-trips through jsexpr->string (valid JSON)"
  (fresh!)
  (metric-counter-add! "a" 1)
  (metric-gauge-set! "b" 2.5)
  (metric-histogram-record! "c" 0.1)
  (define j (snapshot-jsexpr!))
  (check-not-exn (lambda () (string->jsexpr (jsexpr->string j)))))

(test-case "otlp-metrics-url appends /v1/metrics unless present"
  (check-equal? (otlp-metrics-url "http://c:4318") "http://c:4318/v1/metrics")
  (check-equal? (otlp-metrics-url "http://c:4318/") "http://c:4318/v1/metrics")
  (check-equal? (otlp-metrics-url "http://c:4318/v1/metrics") "http://c:4318/v1/metrics"))

;;; ── In-process sink (same shape as the logs exporter test's) ─────────────────

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

;;; ── 2. INTEGRATION: a configured endpoint receives the periodic snapshot ─────

(define (run-integration)
  (define-values (base recorded done stop!) (start-otlp-sink #:expect 1))
  (dynamic-wind
   void
   (lambda ()
     (init-opentelemetry! #:service-name "metrics-svc"
                          #:endpoint base
                          #:console? #f
                          #:metrics-interval-ms 200)
     (metric-counter-add! "integration.count" 7 (list (cons "k" "v")))
     (unless (sync/timeout 5 done)
       (error 'otlp-metrics-integration "sink never received a POST within 5s"))
     (match-define (list method path body) (first (unbox recorded)))
     (test-case "POST to /v1/metrics with a well-formed OTLP body"
       (check-equal? method "POST")
       (check-equal? path "/v1/metrics")
       (check-pred hash? body)
       (define rm (first (hash-ref body 'resourceMetrics)))
       (define svc (hash-ref (hash-ref (first (hash-ref (hash-ref rm 'resource) 'attributes))
                                       'value) 'stringValue))
       (check-equal? svc "metrics-svc")
       (define ms (hash-ref (first (hash-ref rm 'scopeMetrics)) 'metrics))
       (define m (for/first ([x (in-list ms)]
                             #:when (equal? (hash-ref x 'name) "integration.count"))
                   x))
       (check-pred hash? m "the recorded counter is in the export")
       (check-equal? (hash-ref (first (hash-ref (hash-ref m 'sum) 'dataPoints)) 'asInt)
                     "7")))
   (lambda ()
     (stop!)
     ;; do not leave the 200ms exporter running into later tests
     (init-opentelemetry! #:service-name "metrics-svc" #:endpoint "in-memory"))))

(define (integration-or-skip)
  (define can-bind?
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (define l (tcp-listen 0 4 #t "127.0.0.1"))
      (tcp-close l)
      #t))
  (cond
    [can-bind? (run-integration)]
    [else
     (displayln "SKIPPED: OTLP metrics integration test — cannot bind a localhost TCP port")]))

(integration-or-skip)

;;; ── 3. RESILIENCE: unreachable collector never breaks the record path ────────

(test-case "an unreachable endpoint does NOT propagate through record calls"
  (init-opentelemetry! #:service-name "resil"
                       #:endpoint "http://127.0.0.1:1/collector"
                       #:console? #f
                       #:metrics-interval-ms 100)
  (check-not-exn (lambda () (metric-counter-add! "r" 1)))
  (sleep 0.3) ; let the exporter attempt (and swallow) at least one failed POST
  (check-not-exn (lambda () (metric-counter-add! "r" 1)))
  (init-opentelemetry! #:service-name "resil" #:endpoint "in-memory"))

;;; ── 4. GATES: metrics vs logs are independent; defaults follow the endpoint ──

(test-case "default: metrics ON with a real endpoint, OFF with in-memory/#f"
  (init-opentelemetry! #:service-name "g" #:endpoint "http://127.0.0.1:9/x"
                       #:metrics-interval-ms 60000)
  (check-true (metrics-active?))
  (init-opentelemetry! #:service-name "g" #:endpoint "in-memory")
  (check-false (metrics-active?))
  (init-opentelemetry! #:service-name "g")
  (check-false (metrics-active?)))

(test-case "#:metrics? #t with in-memory records with NO exporter and NO log sink"
  (init-opentelemetry! #:service-name "g" #:endpoint "in-memory" #:metrics? #t)
  (check-true (metrics-active?))
  (check-false (tesl-log-active?)
               "the verbose/log gate stays off — metrics gating is separate")
  (metric-counter-add! "local.count" 2)
  (check-equal? (cdr (first (fifth (first (metrics-snapshot))))) 2))

(test-case "#:metrics? #f forces metrics off even with a real endpoint"
  (init-opentelemetry! #:service-name "g" #:endpoint "http://127.0.0.1:9/x"
                       #:metrics? #f)
  (check-false (metrics-active?))
  (init-opentelemetry! #:service-name "g" #:endpoint "in-memory"))

(test-case "re-init resets the registry"
  (init-opentelemetry! #:service-name "g" #:endpoint "in-memory" #:metrics? #t)
  (metric-counter-add! "stale" 1)
  (init-opentelemetry! #:service-name "g" #:endpoint "in-memory" #:metrics? #t)
  (check-equal? (metrics-snapshot) '()))

(test-case "reset advances the cumulative startTimeUnixNano (OTLP temporality rule)"
  (fresh!)
  (metric-counter-add! "c" 1)
  (define (default-start)
    (define j (metrics-snapshot->otlp-jsexpr (metrics-snapshot)
                                             #:service-name "s"))
    (string->number
     (hash-ref (first (hash-ref (hash-ref (first (metrics-of j)) 'sum) 'dataPoints))
               'startTimeUnixNano)))
  (define s1 (default-start))
  (sleep 0.01)
  (reset-metrics!)
  (metric-counter-add! "c" 1)
  (check-true (> (default-start) s1)
              "a registry reset must move the start time forward"))

(test-case "Tesl-surface recorders never raise and cost one flag read when off"
  (set-metrics-enabled! #f)
  ;; attrs is garbage — with metrics off it must not even be traversed
  (check-not-exn (lambda () (counter "n" 1 42)))
  (set-metrics-enabled! #t)
  ;; with metrics on, a malformed attrs value is swallowed, never raised
  (check-not-exn (lambda () (counter "n" 1 42)))
  (set-metrics-enabled! #f))

;;; ── 5. HTTP SURFACE: SSE endpoints stay OUT of http.server.request.duration ──
;;;
;;; SSE requests are long-lived streams: recording their lifetime into the
;;; request-duration histogram would poison every percentile (a single open
;;; stream "lasts" minutes-to-hours vs millisecond API calls).  The routing
;;; layer guarantees the exclusion — `serve` (dsl/web.rkt) matches the distinct
;;; SSE route table BEFORE dispatch-request, and neither handle-sse-request nor
;;; the stream teardown records the histogram.  SSE traffic is observable via
;;; its own catalog entries instead: tesl.sse.connections.active (gauge,
;;; per-channel) + tesl.sse.events.sent/dropped (counters).  This tier pins
;;; that contract end-to-end against a real `serve` socket: a normal request
;;; records exactly one histogram point; an SSE connect+disconnect adds NONE
;;; (neither at accept nor at stream end) while showing up in the SSE gauge.
;;; Self-SKIPs when no localhost port can be bound, like tier 2.

(require (only-in "../dsl/web.rkt"
                  define-handler define-api define-server serve)
         (only-in "../tesl/queue.rkt" define-channel))

(define (run-sse-http-surface)
  (define-channel SseMetricsProbeChannel)
  (define-handler (sse-metrics-ping) #:returns String "pong")
  (define-api SseMetricsProbeAPI
    [sse-metrics-ping : "ping" :> (Get JSON String)])
  (define-server SseMetricsProbeServer
    #:api SseMetricsProbeAPI
    [sse-metrics-ping sse-metrics-ping])
  ;; Same 5-element route shape the emitter produces for `sse "/events/:key"`.
  (define sse-routes
    (list (list (list "events" #f) #f SseMetricsProbeChannel 1 '())))
  ;; Grab a free port number (close the scout listener, then serve on it).
  (define scout (tcp-listen 0 4 #t "127.0.0.1"))
  (define-values (_la port _ra _rp) (tcp-addresses scout #t))
  (tcp-close scout)
  (fresh!)
  (define server-custodian (make-custodian))
  (parameterize ([current-custodian server-custodian])
    (thread
     (lambda ()
       (with-handlers ([exn:fail? void])
         (serve SseMetricsProbeServer #:port port #:sse-routes sse-routes)))))
  (define (try-connect)
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (define-values (in out) (tcp-connect "127.0.0.1" port))
      (cons in out)))
  (define (wait-until thunk #:timeout-ms [timeout-ms 10000] #:what [what "condition"])
    (let loop ([waited 0])
      (cond
        [(thunk) => values]
        [(>= waited timeout-ms) (error 'sse-http-surface "timed out waiting for ~a" what)]
        [else (sleep 0.1) (loop (+ waited 100))])))
  (define (snapshot-instrument kind name)
    (for/first ([entry (in-list (metrics-snapshot))]
                #:when (and (eq? (first entry) kind)
                            (equal? (second entry) name)))
      entry))
  (define (duration-histogram-total-count)
    (define entry (snapshot-instrument 'histogram "http.server.request.duration"))
    (if entry
        (for/sum ([p (in-list (fifth entry))])
          (vector-ref (cdr p) 2))
        0))
  (define (sse-active-gauge-value)
    (define entry (snapshot-instrument 'gauge "tesl.sse.connections.active"))
    (and entry
         (for/first ([p (in-list (fifth entry))]
                     #:when (equal? (car p)
                                    (list (cons "tesl.channel" "SseMetricsProbeChannel"))))
           (cdr p))))
  (dynamic-wind
   void
   (lambda ()
     ;; Wait for the server socket to accept.
     (let ([conn (wait-until try-connect #:what "server socket")])
       (close-output-port (cdr conn))
       (close-input-port (car conn)))
     ;; 1. Normal API request → exactly one histogram point, operation-labeled.
     (let-values ([(in out) (tcp-connect "127.0.0.1" port)])
       (write-string "GET /ping HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n" out)
       (flush-output out)
       (define status (read-line in 'return-linefeed))
       (check-true (and (string? status) (regexp-match? #rx"200" status))
                   "normal GET /ping answers 200")
       ;; drain until EOF so the request definitely completed server-side
       (let drain () (unless (eof-object? (read-line in 'return-linefeed)) (drain)))
       (close-output-port out)
       (close-input-port in))
     (wait-until (lambda () (= (duration-histogram-total-count) 1))
                 #:what "the /ping histogram record")
     (test-case "a normal request records http.server.request.duration"
       (define entry (snapshot-instrument 'histogram "http.server.request.duration"))
       (check-pred list? entry)
       (check-equal? (duration-histogram-total-count) 1)
       (check-true
        (for/or ([p (in-list (fifth entry))])
          (and (member (cons "tesl.operation" "sse-metrics-ping") (car p)) #t))
        "the point carries the route operation label"))
     ;; 2. SSE request: connect, see the stream headers, then disconnect.
     (define-values (sse-in sse-out) (tcp-connect "127.0.0.1" port))
     (write-string "GET /events/u1 HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n\r\n" sse-out)
     (flush-output sse-out)
     (define sse-status (read-line sse-in 'return-linefeed))
     (check-true (and (string? sse-status) (regexp-match? #rx"200" sse-status))
                 "SSE GET answers 200 (stream open)")
     (wait-until (lambda () (equal? (sse-active-gauge-value) 1))
                 #:what "tesl.sse.connections.active = 1")
     (test-case "an OPEN SSE stream counts in the SSE gauge, not the duration histogram"
       (check-equal? (sse-active-gauge-value) 1)
       (check-equal? (duration-histogram-total-count) 1
                     "no histogram point was recorded at SSE accept time"))
     ;; 3. Disconnect; stream teardown must not record a duration either.
     (close-output-port sse-out)
     (close-input-port sse-in)
     ;; The connection thread only notices the hangup at its next heartbeat
     ;; write (10 s cadence, tesl/sse.rkt) — give the janitor comfortably more
     ;; than one heartbeat interval before declaring the unregister missing.
     (wait-until (lambda ()
                   (define v (sse-active-gauge-value))
                   (or (equal? v 0) (equal? v #f)))
                 #:timeout-ms 30000
                 #:what "SSE janitor unregister after disconnect")
     (sleep 0.2) ; grace for any (buggy) teardown-time recording to land
     (test-case "SSE disconnect leaves http.server.request.duration untouched"
       (check-equal? (duration-histogram-total-count) 1)))
   (lambda ()
     (custodian-shutdown-all server-custodian)
     (set-metrics-enabled! #f)
     (reset-metrics!))))

(define (sse-http-surface-or-skip)
  (define can-bind?
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (define l (tcp-listen 0 4 #t "127.0.0.1"))
      (tcp-close l)
      #t))
  (cond
    [can-bind? (run-sse-http-surface)]
    [else
     (displayln "SKIPPED: SSE/http.server.request.duration surface test — cannot bind a localhost TCP port")]))

(sse-http-surface-or-skip)
