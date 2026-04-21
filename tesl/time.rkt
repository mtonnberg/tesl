#lang racket

(require "../dsl/capability.rkt"
         "../dsl/check.rkt"
         "../dsl/types.rkt"
         "private/runtime.rkt")

;; PosixMillis — the canonical Tesl timestamp type.
;; Wraps an Integer that represents milliseconds since the Unix epoch (UTC).
;; Stored as BIGINT in PostgreSQL (no @db annotation needed thanks to
;; the PosixMillis entry in sql.rkt's built-in-db-type-registry).
;;
;; All time functions in Tesl.Time return and accept PosixMillis.
;; Use .value to extract the raw integer when you need plain arithmetic.
(define-newtype PosixMillis Integer)

(provide time nowMillis PosixMillis formatTime durationMs addMs subtractMs diffMs
         Time.posixToSeconds Time.secondsToPosix)

(define-capability time)

;; Helper: unwrap PosixMillis (or plain Int) to a Racket exact integer.
(define (posix-ms-value v)
  (define raw (raw-value v))
  (if (newtype-value? raw) (newtype-value-value raw) raw))

;; Returns current POSIX time in *milliseconds* as a PosixMillis value.
(define (nowMillis)
  (require-capabilities! (list time))
  (PosixMillis (inexact->exact (floor (current-inexact-milliseconds)))))

;; Convert PosixMillis to POSIX seconds (plain integer)
(define (Time.posixToSeconds ms)
  (quotient (posix-ms-value ms) 1000))

;; Convert POSIX seconds to PosixMillis
(define (Time.secondsToPosix s)
  (PosixMillis (* (raw-value s) 1000)))

;; Duration since a past PosixMillis timestamp (always >= 0, plain integer).
;; Requires the time capability because it reads the current clock.
(define (durationMs past-ms)
  (require-capabilities! (list time))
  (max 0 (- (posix-ms-value (nowMillis)) (posix-ms-value past-ms))))

;; Add milliseconds to a PosixMillis timestamp, returning a new PosixMillis.
(define (addMs ts delta-ms)
  (PosixMillis (+ (posix-ms-value ts) (raw-value delta-ms))))

;; Subtract milliseconds from a PosixMillis timestamp.
(define (subtractMs ts delta-ms)
  (PosixMillis (- (posix-ms-value ts) (raw-value delta-ms))))

;; Difference between two PosixMillis timestamps (b - a), as a plain integer.
(define (diffMs a-ms b-ms)
  (- (posix-ms-value b-ms) (posix-ms-value a-ms)))

;; Format a PosixMillis timestamp as a human-readable string.
;;
;; posix-ms : PosixMillis
;; timezone : String — e.g. "UTC", "Europe/Stockholm", "America/New_York"
;;            (uses local timezone if #f or "local")
;; fmt-str  : String — strftime-style format codes:
;;   %Y   four-digit year
;;   %m   month (01-12)
;;   %d   day (01-31)
;;   %H   hour 24h (00-23)
;;   %M   minute (00-59)
;;   %S   second (00-59)
;;   %3N  milliseconds within second (000-999)
;;   %z   UTC offset (+0000)
;;   %Z   timezone abbreviation
;;   %%   literal percent
(define (formatTime posix-ms timezone fmt-str)
  (define ms  (posix-ms-value posix-ms))
  (define tz  (let ([tv (raw-value timezone)])
                (if (or (not tv) (equal? tv "local")) #f tv)))
  (define fmt (raw-value fmt-str))
  (define seconds (quotient ms 1000))
  (define millis  (remainder ms 1000))
  (define d
    (cond
      [(and tz (not (string=? tz "UTC")) (not (string=? tz "utc")))
       (define saved-tz (getenv "TZ"))
       (dynamic-wind
         (lambda () (putenv "TZ" tz))
         (lambda () (seconds->date seconds #t))
         (lambda () (if saved-tz (putenv "TZ" saved-tz) (putenv "TZ" ""))))]
      [else
       (seconds->date seconds #t)]))
  (define (zero-pad n width)
    (define s (number->string n))
    (string-append (make-string (max 0 (- width (string-length s))) #\0) s))
  (define (utc-offset)
    (define offset (date-time-zone-offset d))
    (define sign (if (>= offset 0) "+" "-"))
    (define abs-off (abs offset))
    (define hrs (quotient abs-off 3600))
    (define mins (quotient (remainder abs-off 3600) 60))
    (format "~a~a~a" sign (zero-pad hrs 2) (zero-pad mins 2)))
  (regexp-replace* #px"%(Y|m|d|H|M|S|3N|z|Z|%)" fmt
    (lambda (match code)
      (case code
        [("Y")  (zero-pad (date-year d) 4)]
        [("m")  (zero-pad (date-month d) 2)]
        [("d")  (zero-pad (date-day d) 2)]
        [("H")  (zero-pad (date-hour d) 2)]
        [("M")  (zero-pad (date-minute d) 2)]
        [("S")  (zero-pad (date-second d) 2)]
        [("3N") (zero-pad millis 3)]
        [("z")  (utc-offset)]
        [("Z")  (if (date*? d) (date*-time-zone-name d) "UTC")]
        [("%")  "%"]
        [else match]))))
