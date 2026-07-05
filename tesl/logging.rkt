#lang racket

;;; Ambient logging + telemetry bridge for Tesl.
;;;
;;; Two independent sinks for the framework's own HTTP/SQL/queue/pubsub trace:
;;;
;;;   1. stderr, gated by TESL_VERBOSE=1 (local-dev console output).
;;;   2. the telemetry pipeline (OTLP export), gated by a sink that dsl/otel.rkt
;;;      installs when a real OTLP endpoint is configured (#22).
;;;
;;; Before #22 the framework trace was eprintf-to-stderr ONLY, so a configured
;;; OTLP endpoint received just the explicit `telemetry "…" { }` events and none
;;; of the automatic HTTP/SQL/queue/pubsub instrumentation.  Now each log helper
;;; routes through `tesl-emit!`, which writes to stderr (when verbose) AND to the
;;; telemetry sink (when installed), carrying structured attributes.
;;;
;;; Dependency direction: this module requires NOTHING, so dsl/otel.rkt can
;;; require it and install the sink with no require cycle.

(provide
 tesl-verbose?
 tesl-log-active?
 set-telemetry-log-sink!
 tesl-log!
 tesl-log-http-request!
 tesl-log-http-response!
 tesl-log-sql!
 tesl-log-enqueue!
 tesl-log-dequeue!
 tesl-log-worker-done!
 tesl-log-worker-fail!
 tesl-log-publish!
 tesl-log-deliver!)

;; ── Enabled flag ─────────────────────────────────────────────────────────────
;;
;; Checked once at module load; no per-call overhead when disabled.
;; Set TESL_VERBOSE=1 (or any non-empty string) before starting the app.

(define tesl-verbose?
  (let ([v (getenv "TESL_VERBOSE")])
    (and v (not (string=? v "")) #t)))

;; ── Telemetry sink (#22) ─────────────────────────────────────────────────────
;;
;; A box (not a parameter) so every request/worker thread observes the same sink
;; regardless of parameterization.  dsl/otel.rkt sets it in init-opentelemetry!
;; to a `(category message attributes) -> void` procedure when a real OTLP
;; endpoint is configured, and clears it (#f) otherwise.
(define telemetry-sink-box (box #f))

(define (set-telemetry-log-sink! sink)
  (set-box! telemetry-sink-box sink))

;; Framework instrumentation should run when EITHER the stderr path (verbose) or
;; the telemetry path (sink installed) is active.  Call sites gate their
;; instrumentation (including timing capture) on this instead of `tesl-verbose?`.
(define (tesl-log-active?)
  (or tesl-verbose? (and (unbox telemetry-sink-box) #t)))

;; ── Core emit ────────────────────────────────────────────────────────────────
;;
;; stderr when verbose; telemetry sink when installed.  `attrs` is an assoc list
;; of (symbol . jsexpr-able-value) carried as OTLP log-record attributes.
(define (tesl-emit! category message [attrs '()])
  (when tesl-verbose?
    (eprintf "[TESL][~a] ~a\n" category message))
  (define sink (unbox telemetry-sink-box))
  (when sink
    (with-handlers ([exn:fail? (lambda (_e) (void))])
      (sink category message attrs))))

(define (tesl-log! category message)
  (tesl-emit! category message '()))

;; ── HTTP request/response ────────────────────────────────────────────────────

(define (tesl-log-http-request! method path)
  (tesl-emit! "HTTP" (format "→ ~a ~a" method path)
              (list (cons 'http.method method)
                    (cons 'http.path path))))

(define (tesl-log-http-response! method path status elapsed-ms)
  (tesl-emit! "HTTP" (format "← ~a ~a ~a (~ams)" status method path elapsed-ms)
              (list (cons 'http.method method)
                    (cons 'http.path path)
                    (cons 'http.status status)
                    (cons 'http.duration_ms elapsed-ms))))

;; ── SQL queries ──────────────────────────────────────────────────────────────
;;
;; sql  — the SQL string with $1, $2, … placeholders
;; params — the bound parameter values (never user-interpolated into SQL)

(define (tesl-log-sql! sql params)
  ;; Condense multi-line SQL to one line for readability
  (define one-line
    (regexp-replace* #px"\\s+" (string-trim sql) " "))
  (define param-str
    (if (null? params)
        ""
        (format " [~a]" (string-join (map ~a params) ", "))))
  (tesl-emit! "SQL" (format "~a~a" one-line param-str)
              (list (cons 'db.statement one-line)
                    (cons 'db.param_count (length params)))))

;; ── Queue operations ─────────────────────────────────────────────────────────

(define (tesl-log-enqueue! job-type job-id)
  (tesl-emit! "QUEUE" (format "enqueue ~a id=~a" job-type job-id)
              (list (cons 'messaging.operation "enqueue")
                    (cons 'messaging.job_type (~a job-type))
                    (cons 'messaging.job_id (~a job-id)))))

(define (tesl-log-dequeue! job-type job-id attempt max-attempts)
  (tesl-emit! "QUEUE" (format "dequeue ~a id=~a (attempt ~a/~a)"
                              job-type job-id attempt max-attempts)
              (list (cons 'messaging.operation "dequeue")
                    (cons 'messaging.job_type (~a job-type))
                    (cons 'messaging.job_id (~a job-id))
                    (cons 'messaging.attempt attempt)
                    (cons 'messaging.max_attempts max-attempts))))

(define (tesl-log-worker-done! job-type job-id)
  (tesl-emit! "QUEUE" (format "done ~a id=~a" job-type job-id)
              (list (cons 'messaging.operation "done")
                    (cons 'messaging.job_type (~a job-type))
                    (cons 'messaging.job_id (~a job-id)))))

(define (tesl-log-worker-fail! job-type job-id attempt max-attempts error-msg)
  (tesl-emit! "QUEUE" (format "fail ~a id=~a (attempt ~a/~a): ~a"
                              job-type job-id attempt max-attempts error-msg)
              (list (cons 'messaging.operation "fail")
                    (cons 'messaging.job_type (~a job-type))
                    (cons 'messaging.job_id (~a job-id))
                    (cons 'messaging.attempt attempt)
                    (cons 'messaging.max_attempts max-attempts)
                    (cons 'error.message (~a error-msg)))))

;; ── Pub/sub events ───────────────────────────────────────────────────────────

(define (tesl-log-publish! channel-name key)
  (tesl-emit! "PUBSUB" (format "publish ~a(~a)" channel-name key)
              (list (cons 'messaging.operation "publish")
                    (cons 'messaging.channel (~a channel-name))
                    (cons 'messaging.key (~a key)))))

(define (tesl-log-deliver! channel-name key outbox-id listener-count)
  (tesl-emit! "PUBSUB" (format "deliver outbox#~a ~a(~a) → ~a listener(s)"
                              outbox-id channel-name key listener-count)
              (list (cons 'messaging.operation "deliver")
                    (cons 'messaging.channel (~a channel-name))
                    (cons 'messaging.key (~a key))
                    (cons 'messaging.outbox_id (~a outbox-id))
                    (cons 'messaging.listener_count listener-count))))
