#lang racket

;;; OTLP/HTTP+JSON Logs exporter tests (dsl/otel.rkt make-otlp-http-consumer).
;;;
;;; Three tiers, all offline and deterministic:
;;;
;;;   1. UNIT — telemetry-events->otlp-logs-jsexpr maps events to the OTLP
;;;      ExportLogsServiceRequest shape: service.name resource attr, per-record
;;;      body/timeUnixNano, and the AnyValue attribute-type tagging
;;;      (stringValue / intValue-as-string / doubleValue / boolValue).
;;;
;;;   2. INTEGRATION — a tiny in-process localhost HTTP sink records POSTed bodies;
;;;      init-opentelemetry! with that endpoint + emitted events must produce a
;;;      batch POST to <endpoint>/v1/logs with the right JSON.  Self-SKIPS (prints
;;;      SKIPPED, exits 0) if it cannot bind a port — like the MailHog email test.
;;;
;;;   3. RESILIENCE — pointing the endpoint at a closed port must NOT break the
;;;      emit path: emit-telemetry-event! returns normally and nothing escapes.
;;;
;;; Run (collections `tesl`/`dsl` on PLTCOLLECTS, or from the repo root):
;;;     raco test tests/otlp-exporter-test.rkt

(require racket/tcp
         json
         rackunit
         "../dsl/otel.rkt"
         (only-in "../tesl/logging.rkt"
                  tesl-log-active? tesl-log-http-response! tesl-log-sql!))

;;; ── 1. UNIT: pure event → OTLP/JSON mapping ──────────────────────────────────

(define ev-a
  (telemetry-event "checkout-svc" "http://collector:4318"
                   "order.placed"
                   (list (cons 'user.id "u-42")
                         (cons 'items 3)
                         (cons 'paid #t)
                         (cons 'amount 12.5))
                   1700000000000.0))

(define ev-b
  (telemetry-event "checkout-svc" "http://collector:4318"
                   "order.shipped"
                   (list (cons 'tracking "TESL-1"))
                   1700000000500.0))

(test-case "empty event list yields an empty resourceLogs array"
  (define j (telemetry-events->otlp-logs-jsexpr '()))
  (check-equal? (hash-ref j 'resourceLogs) '()))

(test-case "service.name is a resource attribute taken from the events"
  (define j (telemetry-events->otlp-logs-jsexpr (list ev-a)))
  (define rl (first (hash-ref j 'resourceLogs)))
  (define attrs (hash-ref (hash-ref rl 'resource) 'attributes))
  (check-equal? (length attrs) 1)
  (define a (first attrs))
  (check-equal? (hash-ref a 'key) "service.name")
  (check-equal? (hash-ref (hash-ref a 'value) 'stringValue) "checkout-svc"))

(test-case "each event becomes one logRecord under scopeLogs, in order"
  (define j (telemetry-events->otlp-logs-jsexpr (list ev-a ev-b)))
  (define rl (first (hash-ref j 'resourceLogs)))
  (define sl (first (hash-ref rl 'scopeLogs)))
  (define recs (hash-ref sl 'logRecords))
  (check-equal? (length recs) 2)
  (check-equal? (hash-ref (hash-ref (first recs) 'body) 'stringValue) "order.placed")
  (check-equal? (hash-ref (hash-ref (second recs) 'body) 'stringValue) "order.shipped"))

(test-case "timeUnixNano is (timestampMs * 1e6) rendered as a decimal STRING"
  (define j (telemetry-events->otlp-logs-jsexpr (list ev-a)))
  (define rec (first (hash-ref (first (hash-ref (first (hash-ref j 'resourceLogs)) 'scopeLogs))
                               'logRecords)))
  (define t (hash-ref rec 'timeUnixNano))
  (check-pred string? t "timeUnixNano must be a string (OTLP int64 JSON rule)")
  (check-equal? t "1700000000000000000"))

(test-case "attribute AnyValue tagging: string / int / bool / double"
  (define j (telemetry-events->otlp-logs-jsexpr (list ev-a)))
  (define rec (first (hash-ref (first (hash-ref (first (hash-ref j 'resourceLogs)) 'scopeLogs))
                               'logRecords)))
  (define attrs (hash-ref rec 'attributes))
  ;; index by key for order-independent assertions
  (define by-key
    (for/hash ([kv (in-list attrs)]) (values (hash-ref kv 'key) (hash-ref kv 'value))))
  (check-equal? (hash-ref by-key "user.id") (hash 'stringValue "u-42")
                "string attribute -> stringValue")
  (check-equal? (hash-ref by-key "items") (hash 'intValue "3")
                "exact integer -> intValue as a STRING")
  (check-equal? (hash-ref by-key "paid") (hash 'boolValue #t)
                "boolean -> boolValue (checked before number)")
  (check-equal? (hash-ref by-key "amount") (hash 'doubleValue 12.5)
                "non-integer real -> doubleValue"))

(test-case "AnyValue helper coerces symbols/keywords to stringValue"
  (check-equal? (telemetry-value->otlp-any-value 'ok) (hash 'stringValue "ok"))
  (check-equal? (telemetry-value->otlp-any-value '#:kw) (hash 'stringValue "kw"))
  ;; nested list/hash values render as a JSON string, never a raw jsexpr
  (define v (telemetry-value->otlp-any-value (list 1 2 3)))
  (check-pred string? (hash-ref v 'stringValue)))

;;; Structural jsexpr equality ignoring hash KIND (hash vs hasheq): string->jsexpr
;;; yields hasheq objects while (hash ...) literals are equal?-keyed, so they are
;;; not `equal?` even with identical contents.  Same helper as the provider test.
(define (jsexpr=? a b)
  (cond
    [(and (hash? a) (hash? b))
     (and (= (hash-count a) (hash-count b))
          (for/and ([(k v) (in-hash a)])
            (and (hash-has-key? b k) (jsexpr=? v (hash-ref b k)))))]
    [(and (list? a) (list? b))
     (and (= (length a) (length b)) (andmap jsexpr=? a b))]
    [else (equal? a b)]))

(test-case "the whole batch round-trips through jsexpr->string (valid JSON)"
  (define j (telemetry-events->otlp-logs-jsexpr (list ev-a ev-b)))
  (define s (jsexpr->string j))
  (check-true (jsexpr=? (string->jsexpr s) j) "serialize/parse is stable"))

;;; ── In-process OTLP sink (records POSTed request lines + bodies) ─────────────
;;;
;;; Binds an ephemeral localhost port and serves N requests, capturing each
;;; request's start-line (method + path) and JSON body into `recorded`.  Returns
;;; (values base-url recorded-box stop!) — recorded-box holds a list of
;;; (list method path jsexpr), newest appended last.
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

;;; ── 2. INTEGRATION: a configured endpoint actually receives the batch ────────

(define (run-integration)
  (define-values (base recorded done stop!)
    (start-otlp-sink #:expect 1))
  (dynamic-wind
   void
   (lambda ()
     ;; batch-size 2 + short flush interval so the two events flush promptly.
     (init-opentelemetry! #:service-name "integration-svc"
                          #:endpoint base
                          #:console? #f
                          #:otlp-batch-size 2
                          #:otlp-flush-interval-ms 200)
     (telemetry-event! "sink.first"  #:attributes ([user.id "abc"] [n 1]))
     (telemetry-event! "sink.second" #:attributes ([flag #t]))
     ;; wait (bounded) for the sink to record the POST
     (unless (sync/timeout 5 done)
       (error 'otlp-integration "sink never received a POST within 5s"))
     (define reqs (unbox recorded))
     (test-case "sink received exactly one batch POST"
       (check-equal? (length reqs) 1))
     (match-define (list method path body) (first reqs))
     (test-case "POST to /v1/logs with a well-formed OTLP body"
       (check-equal? method "POST")
       (check-equal? path "/v1/logs")
       (check-pred hash? body "body parsed as JSON")
       (define rl (first (hash-ref body 'resourceLogs)))
       (define svc (hash-ref (hash-ref (first (hash-ref (hash-ref rl 'resource) 'attributes))
                                       'value) 'stringValue))
       (check-equal? svc "integration-svc")
       (define recs (hash-ref (first (hash-ref rl 'scopeLogs)) 'logRecords))
       (check-equal? (length recs) 2 "both events in the batch")
       (define bodies (for/list ([r (in-list recs)])
                        (hash-ref (hash-ref r 'body) 'stringValue)))
       (check-true (and (member "sink.first" bodies) #t))
       (check-true (and (member "sink.second" bodies) #t))))
   (lambda () (stop!))))

;;; Self-skip if we cannot bind a listener (locked-down sandbox), mirroring the
;;; MailHog email integration test's skip discipline: print SKIPPED, do not fail.
(define (integration-or-skip)
  (define can-bind?
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (define l (tcp-listen 0 4 #t "127.0.0.1"))
      (tcp-close l)
      #t))
  (cond
    [can-bind? (run-integration)]
    [else
     (displayln "SKIPPED: OTLP integration test — cannot bind a localhost TCP port")]))

(integration-or-skip)

;;; ── 3. RESILIENCE: unreachable collector never breaks the emit path ──────────

(test-case "an unreachable endpoint does NOT propagate through emit"
  ;; Port 1 is (almost certainly) closed; batch-size 1 forces an immediate flush
  ;; attempt on the background thread.  The EMIT itself must return normally.
  (init-opentelemetry! #:service-name "resil-svc"
                       #:endpoint "http://127.0.0.1:1/collector"
                       #:console? #f
                       #:otlp-batch-size 1
                       #:otlp-flush-interval-ms 100)
  (check-not-exn
   (lambda () (telemetry-event! "resil.event" #:attributes ([x 1]))))
  ;; give the flusher a moment to attempt (and swallow) the failed POST
  (sleep 0.3)
  ;; a second emit must still work — the failed POST didn't wedge anything
  (check-not-exn
   (lambda () (telemetry-event! "resil.event2" #:attributes ([y 2])))))

(test-case "in-memory / empty endpoints register NO OTLP consumer (no export)"
  (init-opentelemetry! #:service-name "s" #:endpoint "in-memory" #:console? #f)
  (check-equal? (length (current-telemetry-consumers)) 0)
  (init-opentelemetry! #:service-name "s" #:endpoint #f #:console? #t)
  (check-equal? (length (current-telemetry-consumers)) 1 "only the console consumer"))

;;; ── 4. #22: framework HTTP/SQL/queue/pubsub logs bridge to telemetry ──────────
;;;
;;; With a real OTLP endpoint configured, the framework's own instrumentation
;;; (previously eprintf-to-stderr only) must flow through the SAME emit path as
;;; an explicit `telemetry "…"` statement, so it reaches every consumer. With an
;;; in-memory/console-only endpoint it must NOT (stderr-only, tests unaffected).
;;; The endpoint here is unreachable (127.0.0.1:9) — the OTLP consumer's POST
;;; fails harmlessly; a custom capture consumer proves the bridge synchronously.

(test-case "framework logs bridge to telemetry on a real endpoint (#22)"
  (define captured (box '()))
  (init-opentelemetry!
   #:service-name "fw" #:endpoint "http://127.0.0.1:9/otlp"
   #:consumers (list (lambda (ev) (set-box! captured (cons ev (unbox captured))))))
  (check-true (tesl-log-active?) "bridge active when a real endpoint is configured")
  (tesl-log-http-response! "GET" "/ping" 200 5)
  (tesl-log-sql! "select 1" '())
  (define evs (reverse (unbox captured)))
  (check-equal? (length evs) 2 "both framework events reached the pipeline")
  (define http-ev (first evs))
  (define attrs (telemetry-event-attributes http-ev))
  (check-equal? (cdr (assq 'log.category attrs)) "HTTP")
  (check-equal? (cdr (assq 'http.status attrs)) 200)
  (check-equal? (cdr (assq 'log.category (telemetry-event-attributes (second evs)))) "SQL"))

(test-case "framework logs do NOT bridge under in-memory (#22)"
  (init-opentelemetry! #:service-name "fw" #:endpoint "in-memory" #:console? #f)
  (drain-telemetry!) ; clear
  (tesl-log-http-response! "GET" "/ping" 200 5)
  (tesl-log-sql! "select 1" '())
  (check-equal? (length (drain-telemetry!)) 0
                "no framework events recorded when no real endpoint is configured"))
