#lang racket

;;; Verbose ambient logging for Tesl.
;;;
;;; Activate with the environment variable TESL_VERBOSE=1 (or any non-empty value).
;;; All logging goes to stderr in a structured line format.
;;;
;;; Design: tesl-verbose? is evaluated ONCE at module load time, so the only
;;; per-call cost is a single boolean read + branch when logging is disabled.
;;; String formatting only runs when logging is active.

(provide
 tesl-verbose?
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

;; ── Core logging ─────────────────────────────────────────────────────────────

(define (tesl-log! category message)
  (eprintf "[TESL][~a] ~a\n" category message))

;; ── HTTP request/response ────────────────────────────────────────────────────

(define (tesl-log-http-request! method path)
  (tesl-log! "HTTP" (format "→ ~a ~a" method path)))

(define (tesl-log-http-response! method path status elapsed-ms)
  (tesl-log! "HTTP" (format "← ~a ~a ~a (~ams)" status method path elapsed-ms)))

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
  (tesl-log! "SQL" (format "~a~a" one-line param-str)))

;; ── Queue operations ─────────────────────────────────────────────────────────

(define (tesl-log-enqueue! job-type job-id)
  (tesl-log! "QUEUE" (format "enqueue ~a id=~a" job-type job-id)))

(define (tesl-log-dequeue! job-type job-id attempt max-attempts)
  (tesl-log! "QUEUE" (format "dequeue ~a id=~a (attempt ~a/~a)"
                               job-type job-id attempt max-attempts)))

(define (tesl-log-worker-done! job-type job-id)
  (tesl-log! "QUEUE" (format "done ~a id=~a" job-type job-id)))

(define (tesl-log-worker-fail! job-type job-id attempt max-attempts error-msg)
  (tesl-log! "QUEUE" (format "fail ~a id=~a (attempt ~a/~a): ~a"
                               job-type job-id attempt max-attempts error-msg)))

;; ── Pub/sub events ───────────────────────────────────────────────────────────

(define (tesl-log-publish! channel-name key)
  (tesl-log! "PUBSUB" (format "publish ~a(~a)" channel-name key)))

(define (tesl-log-deliver! channel-name key outbox-id listener-count)
  (tesl-log! "PUBSUB" (format "deliver outbox#~a ~a(~a) → ~a listener(s)"
                                outbox-id channel-name key listener-count)))
