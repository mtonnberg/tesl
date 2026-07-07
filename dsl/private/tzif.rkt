#lang racket

;;; Minimal IANA TZif reader — per-instant UTC offsets for named time zones.
;;;
;;; Why hand-rolled: the Tesl runtime needs `offset at instant` for the
;;; `TimeZone` zone constructors (DST-correct calendar bucketing, GitHub #29
;;; follow-up), Racket ships no tz package in this distribution, and the
;;; TZ-env/`seconds->date` trick silently returns UTC on this Racket.  The
;;; system tzdata (TZif v2/v3 files, RFC 8536) is authoritative and the SAME
;;; data PostgreSQL uses, so the two backends agree by data source; the
;;; PG-parity suite (tests/sql-group-by-pg-test.rkt) is the correctness oracle.
;;;
;;; Scope: `tzif-offset-seconds zone-name utc-seconds -> seconds east of UTC`.
;;;   - 64-bit transition table (v2/v3 data block) covers instants through the
;;;     last baked transition (tzdata bakes ~2037);
;;;   - beyond it, the POSIX TZ footer rule ("CET-1CEST,M3.5.0,M10.5.0/3") is
;;;     evaluated exactly (M-form day rules, custom /time, negative/large
;;;     times per v3);
;;;   - before the first transition, the first non-DST type (RFC 8536 §3.2).
;;; Unknown zone or unreadable file raises (fail closed).  Parsed zones are
;;; cached for the process lifetime.

(provide tzif-offset-seconds
         tzif-zone-exists?)

;; ── zoneinfo discovery ────────────────────────────────────────────────────

(define (zoneinfo-dir)
  (or (let ([d (getenv "TZDIR")]) (and d (directory-exists? d) d))
      (for/first ([d (in-list '("/usr/share/zoneinfo" "/etc/zoneinfo"
                                "/usr/lib/zoneinfo"))]
                  #:when (directory-exists? d))
        d)
      (error 'tzif "no zoneinfo directory found (set TZDIR)")))

(define (zone-path name)
  ;; zone names come from the compiler's baked table, but stay defensive: no
  ;; absolute names, no path escapes.
  (when (or (string-contains? name "..") (string-prefix? name "/"))
    (error 'tzif "invalid zone name: ~a" name))
  (build-path (zoneinfo-dir) name))

(define (tzif-zone-exists? name)
  (file-exists? (zone-path name)))

;; ── binary helpers ────────────────────────────────────────────────────────

(define (s32 bs off)
  (define u (integer-bytes->integer bs #f #t off (+ off 4)))
  (if (>= u #x80000000) (- u #x100000000) u))

(define (s64 bs off)
  (define u (integer-bytes->integer bs #f #t off (+ off 8)))
  (if (>= u #x8000000000000000) (- u #x10000000000000000) u))

(define (u32 bs off) (integer-bytes->integer bs #f #t off (+ off 4)))

;; ── TZif parsing (RFC 8536) ───────────────────────────────────────────────

(struct tz-data (transitions   ; vector of utc-seconds, ascending
                 trans-offsets ; vector of offset-seconds, same length
                 first-offset  ; offset before the first transition
                 footer)       ; parsed footer rule or #f
  #:transparent)

;; header at [off]: returns (values version isutcnt isstdcnt leapcnt timecnt typecnt charcnt)
(define (read-header bs off)
  (unless (equal? (subbytes bs off (+ off 4)) #"TZif")
    (error 'tzif "not a TZif file"))
  (values (bytes-ref bs (+ off 4))
          (u32 bs (+ off 20)) (u32 bs (+ off 24)) (u32 bs (+ off 28))
          (u32 bs (+ off 32)) (u32 bs (+ off 36)) (u32 bs (+ off 40))))

(define (data-block-size timecnt typecnt charcnt leapcnt isstdcnt isutcnt time-size)
  (+ (* timecnt time-size) timecnt (* typecnt 6) charcnt
     (* leapcnt (+ time-size 4)) isstdcnt isutcnt))

(define (parse-tzif bs)
  (define-values (v1-version isutcnt1 isstdcnt1 leapcnt1 timecnt1 typecnt1 charcnt1)
    (read-header bs 0))
  (define v1-end (+ 44 (data-block-size timecnt1 typecnt1 charcnt1 leapcnt1
                                        isstdcnt1 isutcnt1 4)))
  (cond
    [(< v1-version (char->integer #\2))
     ;; ancient v1-only file: 32-bit table, no footer
     (parse-block bs 44 timecnt1 typecnt1 charcnt1 4 #f)]
    [else
     (define-values (_v2 isutcnt2 isstdcnt2 leapcnt2 timecnt2 typecnt2 charcnt2)
       (read-header bs v1-end))
     (define block-start (+ v1-end 44))
     (define block-end (+ block-start (data-block-size timecnt2 typecnt2 charcnt2
                                                       leapcnt2 isstdcnt2 isutcnt2 8)))
     ;; footer: "\n<TZ string>\n"
     (define footer-str
       (let* ([rest (subbytes bs block-end)]
              [s (bytes->string/utf-8 rest)])
         (and (> (string-length s) 2)
              (char=? (string-ref s 0) #\newline)
              (let ([end (or (for/first ([i (in-range 1 (string-length s))]
                                         #:when (char=? (string-ref s i) #\newline))
                               i)
                             (string-length s))])
                (let ([tz (substring s 1 end)])
                  (and (positive? (string-length tz)) tz))))))
     (parse-block bs block-start timecnt2 typecnt2 charcnt2 8
                  (and footer-str (parse-posix-tz footer-str)))]))

(define (parse-block bs start timecnt typecnt charcnt time-size footer)
  (define times-off start)
  (define idx-off (+ times-off (* timecnt time-size)))
  (define types-off (+ idx-off timecnt))
  (define transitions
    (for/vector ([i (in-range timecnt)])
      (if (= time-size 8)
          (s64 bs (+ times-off (* i 8)))
          (s32 bs (+ times-off (* i 4))))))
  (define type-offsets
    (for/vector ([i (in-range typecnt)])
      (s32 bs (+ types-off (* i 6)))))
  (define type-isdst
    (for/vector ([i (in-range typecnt)])
      (bytes-ref bs (+ types-off (* i 6) 4))))
  (define trans-offsets
    (for/vector ([i (in-range timecnt)])
      (vector-ref type-offsets (bytes-ref bs (+ idx-off i)))))
  ;; RFC 8536 §3.2: before the first transition use the first non-DST type
  (define first-offset
    (or (for/first ([i (in-range typecnt)]
                    #:when (zero? (vector-ref type-isdst i)))
          (vector-ref type-offsets i))
        (if (positive? typecnt) (vector-ref type-offsets 0) 0)))
  (tz-data transitions trans-offsets first-offset footer))

;; ── POSIX TZ footer rules ("CET-1CEST,M3.5.0,M10.5.0/3") ─────────────────

(struct posix-tz (std-offset      ; seconds east of UTC
                  dst-offset      ; seconds east, or #f when no DST
                  start-rule      ; (month week day time-seconds) or #f
                  end-rule)
  #:transparent)

;; parse "name±hh[:mm[:ss]]" pieces; POSIX offsets are WEST-positive, so the
;; seconds-east offset is the NEGATION of the parsed value.
(define (parse-posix-tz s)
  (define pos (box 0))
  (define (peek) (and (< (unbox pos) (string-length s)) (string-ref s (unbox pos))))
  (define (advance!) (set-box! pos (add1 (unbox pos))))
  (define (parse-name!)
    (cond
      [(eqv? (peek) #\<)
       (advance!)
       (let loop () (unless (eqv? (peek) #\>) (advance!) (loop)))
       (advance!)]
      [else
       (let loop ()
         (when (and (peek) (char-alphabetic? (peek)))
           (advance!) (loop)))]))
  (define (parse-int!)
    (define start (unbox pos))
    (let loop () (when (and (peek) (char-numeric? (peek))) (advance!) (loop)))
    (string->number (substring s start (unbox pos))))
  (define (parse-time! #:default [default #f])   ; hh[:mm[:ss]], sign allowed
    (cond
      [(or (not (peek)) (memv (peek) '(#\, #\M #\J)))
       default]
      [else
       (define sign (cond [(eqv? (peek) #\-) (advance!) -1]
                          [(eqv? (peek) #\+) (advance!) 1]
                          [else 1]))
       (define h (parse-int!))
       (define m (if (eqv? (peek) #\:) (begin (advance!) (parse-int!)) 0))
       (define sec (if (eqv? (peek) #\:) (begin (advance!) (parse-int!)) 0))
       (* sign (+ (* h 3600) (* m 60) sec))]))
  (define (parse-rule-time!)
    (if (eqv? (peek) #\/)
        (begin (advance!) (parse-time! #:default 7200))
        7200))
  (define (parse-rule!)   ; M-form (Mm.w.d), J-form (Jn, no leap day), n-form (0-based day)
    (cond
      [(eqv? (peek) #\M)
       (advance!)
       (define month (parse-int!)) (advance!)   ; skip '.'
       (define week (parse-int!)) (advance!)    ; skip '.'
       (define day (parse-int!))
       (list 'M month week day (parse-rule-time!))]
      [(eqv? (peek) #\J)
       (advance!)
       (define n (parse-int!))
       (list 'J n (parse-rule-time!))]
      [(and (peek) (char-numeric? (peek)))
       (define n (parse-int!))
       (list 'N n (parse-rule-time!))]
      [else (error 'tzif "unsupported POSIX TZ rule form in ~s" s)]))
  (parse-name!)
  (define std-west (parse-time!))
  (unless std-west (error 'tzif "no std offset in POSIX TZ ~s" s))
  (define std-east (- std-west))
  (cond
    [(or (not (peek)) (eqv? (peek) #\,))
     (posix-tz std-east #f #f #f)]
    [else
     (parse-name!)
     (define dst-west (parse-time! #:default (- std-west 3600)))
     (define dst-east (- dst-west))
     (cond
       [(eqv? (peek) #\,)
        (advance!)
        (define start (parse-rule!))
        (unless (eqv? (peek) #\,) (error 'tzif "missing end rule in ~s" s))
        (advance!)
        (define end (parse-rule!))
        (posix-tz std-east dst-east start end)]
       [else (posix-tz std-east dst-east #f #f)])]))

;; civil helpers (Hinnant, same arithmetic as dsl/private/time-trunc.rkt)
(define (days-from-civil year month day)
  (define y (if (<= month 2) (- year 1) year))
  (define era (floor (/ y 400)))
  (define yoe (- y (* era 400)))
  (define mp (if (> month 2) (- month 3) (+ month 9)))
  (define doy (+ (quotient (+ (* 153 mp) 2) 5) (- day 1)))
  (define doe (+ (* yoe 365) (quotient yoe 4) (- (quotient yoe 100)) doy))
  (+ (* era 146097) doe -719468))

(define (civil-year-of-day d)
  (define z (+ d 719468))
  (define era (floor (/ z 146097)))
  (define doe (- z (* era 146097)))
  (define yoe (quotient (- doe (+ (quotient doe 1460)
                                  (- (quotient doe 36524))
                                  (quotient doe 146096))) 365))
  (define y (+ yoe (* era 400)))
  (define doy (- doe (+ (* 365 yoe) (quotient yoe 4) (- (quotient yoe 100)))))
  (define mp (quotient (+ (* 5 doy) 2) 153))
  (define month (if (< mp 10) (+ mp 3) (- mp 9)))
  (if (<= month 2) (+ y 1) y))

(define (days-in-month year month)
  (define next-first (if (= month 12)
                         (days-from-civil (+ year 1) 1 1)
                         (days-from-civil year (+ month 1) 1)))
  (- next-first (days-from-civil year month 1)))

;; day-of-week (0=Sunday) for a day count since the epoch (a Thursday)
(define (weekday-of-day d) (modulo (+ d 4) 7))

(define (leap-year? y)
  (and (zero? (modulo y 4)) (or (not (zero? (modulo y 100))) (zero? (modulo y 400)))))

;; A footer rule's day count since the epoch for [year].
;;   M-form: the [day]-weekday of week [week] in [month] (week 5 = last);
;;   J-form: one-based Julian day, Feb 29 never counted;
;;   N-form: zero-based day of year, leap day counted.
(define (rule-day year rule)
  (match rule
    [(list 'M month week day _)
     (define first (days-from-civil year month 1))
     (define first-dow (weekday-of-day first))
     (define first-match (+ first (modulo (- day first-dow) 7)))
     (define candidate (+ first-match (* 7 (sub1 week))))
     (define last-day (+ first (sub1 (days-in-month year month))))
     (if (> candidate last-day) (- candidate 7) candidate)]
    [(list 'J n _)
     (define n* (if (and (leap-year? year) (>= n 60)) (add1 n) n))
     (+ (days-from-civil year 1 1) (sub1 n*))]
    [(list 'N n _)
     (+ (days-from-civil year 1 1) n)]))

;; UTC instant of a footer rule for [year]: local wall time at [base-offset].
(define (rule-instant year rule base-offset)
  (define t (last rule))
  (- (+ (* (rule-day year rule) 86400) t) base-offset))

(define (footer-offset ftz t)
  (cond
    [(not (posix-tz-dst-offset ftz)) (posix-tz-std-offset ftz)]
    [(not (posix-tz-start-rule ftz)) (posix-tz-dst-offset ftz)]  ; perpetual DST
    [else
     (define year (civil-year-of-day (floor (/ (+ t (posix-tz-std-offset ftz)) 86400))))
     (define start (rule-instant year (posix-tz-start-rule ftz) (posix-tz-std-offset ftz)))
     (define end (rule-instant year (posix-tz-end-rule ftz) (posix-tz-dst-offset ftz)))
     (define dst?
       (if (< start end)
           (and (>= t start) (< t end))          ; northern hemisphere
           (or (>= t start) (< t end))))         ; southern hemisphere (wraps)
     (if dst? (posix-tz-dst-offset ftz) (posix-tz-std-offset ftz))]))

;; ── lookup ────────────────────────────────────────────────────────────────

(define cache (make-hash))
(define cache-sema (make-semaphore 1))

(define (zone-data name)
  (call-with-semaphore cache-sema
    (lambda ()
      (hash-ref! cache name
                 (lambda ()
                   (define p (zone-path name))
                   (unless (file-exists? p)
                     (error 'tzif "unknown time zone: ~a" name))
                   (parse-tzif (file->bytes p)))))))

;; offset (seconds east of UTC) in [name] at [t] (UTC seconds since the epoch)
(define (tzif-offset-seconds name t)
  (define z (zone-data name))
  (define trans (tz-data-transitions z))
  (define n (vector-length trans))
  (cond
    [(or (zero? n) (< t (vector-ref trans 0)))
     (tz-data-first-offset z)]
    [(and (tz-data-footer z) (>= t (vector-ref trans (sub1 n))))
     ;; at/after the last baked transition: the footer rule takes over exactly
     ;; there (the last transition is the hand-off point)
     (footer-offset (tz-data-footer z) t)]
    [else
     ;; binary search: greatest i with trans[i] <= t
     (let loop ([lo 0] [hi (sub1 n)])
       (if (>= lo hi)
           (vector-ref (tz-data-trans-offsets z) lo)
           (let ([mid (quotient (+ lo hi 1) 2)])
             (if (<= (vector-ref trans mid) t)
                 (loop mid hi)
                 (loop lo (sub1 mid))))))]))
