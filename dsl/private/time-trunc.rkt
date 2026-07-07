#lang racket

;;; Calendar truncation engine (GitHub #29) — dependency-free on purpose: both
;;; the Tesl.Time surface functions (tesl/time.rkt) and the query DSL's Memory
;;; backend (dsl/sql.rkt) call THIS function, and the PostgreSQL bucket
;;; expressions the emitter generates are tested against it.  One semantic
;;; reference, three consumers.
;;;
;;; tesl-time-trunc : unit × offsetMinutes × ms -> bucket-start ms
;;;   unit ∈ 'hour 'day 'week 'month 'year; all exact-integer arithmetic
;;;   (floor division; Howard Hinnant's public-domain civil_from_days /
;;;   days_from_civil for month/year).  Week = ISO week (Monday start).
;;;   Proleptic Gregorian, no leap seconds — the civil calendar, like elm/time.

(require "tzif.rkt")

(provide tesl-time-trunc
         tesl-tz-utc tesl-tz-fixed tesl-tz-named
         tesl-tz? tesl-tz-kind tesl-tz-payload
         tesl-tz-offset-minutes)

(define ms/hour 3600000)
(define ms/day 86400000)
(define ms/week 604800000)

;; floor v to a multiple of n (exact floor division — correct for pre-1970 too)
(define (floor-to v n) (* (floor (/ v n)) n))

;; Hinnant civil_from_days: day count since 1970-01-01 -> (values year month day)
(define (civil-from-days d)
  (define z (+ d 719468))
  (define era (floor (/ z 146097)))
  (define doe (- z (* era 146097)))
  (define yoe (quotient (- doe (+ (quotient doe 1460)
                                  (- (quotient doe 36524))
                                  (quotient doe 146096))) 365))
  (define y (+ yoe (* era 400)))
  (define doy (- doe (+ (* 365 yoe) (quotient yoe 4) (- (quotient yoe 100)))))
  (define mp (quotient (+ (* 5 doy) 2) 153))
  (define day (+ (- doy (quotient (+ (* 153 mp) 2) 5)) 1))
  (define month (if (< mp 10) (+ mp 3) (- mp 9)))
  (values (if (<= month 2) (+ y 1) y) month day))

;; Hinnant days_from_civil: civil (year, month, day) -> day count since epoch
(define (days-from-civil year month day)
  (define y (if (<= month 2) (- year 1) year))
  (define era (floor (/ y 400)))
  (define yoe (- y (* era 400)))
  (define mp (if (> month 2) (- month 3) (+ month 9)))
  (define doy (+ (quotient (+ (* 153 mp) 2) 5) (- day 1)))
  (define doe (+ (* yoe 365) (quotient yoe 4) (- (quotient yoe 100)) doy))
  (+ (* era 146097) doe -719468))

;; ── TimeZone runtime values ──────────────────────────────────────────────────
;; The Tesl `TimeZone` ADT lowers to these: `Utc`, `FixedOffset n` (minutes east
;; of UTC), and one constructor per baked IANA zone (lowered to its zone name).
;; Named zones resolve their offset PER INSTANT through the system tzdata
;; (tzif.rkt) — DST-correct without the developer tracking summer/winter time.

(struct tesl-tz (kind payload) #:transparent)   ; kind ∈ 'utc 'fixed 'named

(define (tesl-tz-utc) (tesl-tz 'utc 0))

(define (tesl-tz-fixed minutes)
  (unless (exact-integer? minutes)
    (raise-user-error 'FixedOffset "offset must be an Int (minutes east of UTC), got ~e" minutes))
  (tesl-tz 'fixed minutes))

(define (tesl-tz-named name)
  (unless (tzif-zone-exists? name)
    (raise-user-error 'TimeZone
                      "time zone ~a is not in this system's tzdata (check TZDIR)" name))
  (tesl-tz 'named name))

;; offset (minutes east of UTC) of [tz] at instant [ms]
(define (tesl-tz-offset-minutes tz ms)
  (case (tesl-tz-kind tz)
    [(utc) 0]
    [(fixed) (tesl-tz-payload tz)]
    [(named) (quotient (tzif-offset-seconds (tesl-tz-payload tz)
                                            (floor (/ ms 1000)))
                       60)]
    [else (error 'tesl-tz-offset-minutes "unknown TimeZone kind: ~a" (tesl-tz-kind tz))]))

;; unit × TimeZone × ms -> the bucket-start instant in ms.
;;
;; Named zones follow PostgreSQL's two-step semantics exactly (the parity suite
;; is the oracle): instant -> local wall clock at offset(instant); truncate on
;; the civil calendar; local bucket start -> instant using the offset AT THE
;; BUCKET START (re-resolved, with one fixup iteration) — so a bucket that
;; straddles a DST transition still starts at the true local midnight.
(define (tesl-time-trunc unit tz ms)
  (define off1-min
    (if (tesl-tz? tz) (tesl-tz-offset-minutes tz ms) tz)) ; raw minutes accepted internally
  (define local-start (local-trunc unit (+ ms (* off1-min 60000))))
  (cond
    [(and (tesl-tz? tz) (eq? (tesl-tz-kind tz) 'named))
     ;; re-resolve the offset at the candidate instant (fall/spring fixups)
     (define cand (- local-start (* off1-min 60000)))
     (define off2 (tesl-tz-offset-minutes tz cand))
     (define cand2 (- local-start (* off2 60000)))
     (define off3 (tesl-tz-offset-minutes tz cand2))
     (- local-start (* off3 60000))]
    [else (- local-start (* off1-min 60000))]))

;; civil truncation of a LOCAL wall-clock milliseconds value
(define (local-trunc unit local)
  (case unit
    [(hour) (floor-to local ms/hour)]
    [(day)  (floor-to local ms/day)]
    ;; ISO week starts Monday; epoch day 0 (1970-01-01) is a Thursday, so
    ;; shifting by +3 days aligns Monday to a multiple of a week.
    [(week) (- (floor-to (+ local (* 3 ms/day)) ms/week) (* 3 ms/day))]
    [(month)
     (define-values (y m _d) (civil-from-days (floor (/ local ms/day))))
     (* (days-from-civil y m 1) ms/day)]
    [(year)
     (define-values (y _m _d) (civil-from-days (floor (/ local ms/day))))
     (* (days-from-civil y 1 1) ms/day)]
    [else (error 'tesl-time-trunc "unknown unit: ~a" unit)]))
