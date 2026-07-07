#lang racket

;;; GitHub #29 — PostgreSQL ⇄ reference-engine parity for grouped aggregates.
;;;
;;; The Memory backend buckets through `tesl-time-trunc` (dsl/private/
;;; time-trunc.rkt) — the single semantic reference.  On PostgreSQL the emitter
;;; ships SQL bucket expressions (integer floor arithmetic for hour/day/week,
;;; date_trunc on a UTC-shifted timestamp for month/year).  This test proves the
;;; TWO implementations agree on a REAL (temporary) PostgreSQL across boundary
;;; instants (epoch, pre-1970, leap day, late-evening zone rollovers) and
;;; offsets (UTC, +2h, -8h, +5:30), through the actual select-count-by /
;;; select-sum-by runtime path (params, GROUP BY, key decode included).
;;;
;;; Skips cleanly when initdb/pg_ctl are absent.

(require rackunit
         "../dsl/capability.rkt"
         "../dsl/check.rkt"
         "../dsl/sql.rkt"
         "../dsl/types.rkt"
         "../dsl/private/time-trunc.rkt"
         (only-in "../tesl/time.rkt" PosixMillis)
         (only-in "../tesl/tuple.rkt" Tuple2.first Tuple2.second)
         "private/postgres-test-support.rkt")

;; TimeZone values under test: fixed offsets exercise the integer SQL path;
;; NAMED zones exercise the AT TIME ZONE path (PostgreSQL's own tzdata) against
;; the tzif.rkt engine.  Named-zone instants stay in FROZEN history (≤ 2025):
;; future rules can differ between PG's bundled tzdata and the system tzdata
;; (e.g. tzdata 2026b makes British Columbia permanent MST from 2026-11) — the
;; parity contract is about the arithmetic, not about political forecasts.

(define-entity ParityRow
  #:table parity_rows
  #:primary-key id
  [Id id : String]
  [Minutes minutes : Integer]
  [StartedAt startedAt : PosixMillis])

;; (seconds, minutes-value) rows: epoch; one second before the epoch (pre-1970
;; floor direction); leap day 2020-02-29; 2023-11-14T22:13:20Z; a 23:30Z
;; late-evening instant (rolls forward at +offsets); a 00:30Z early-morning
;; instant (rolls back at -offsets).
(define seed-rows
  '((0           . 1)
    (-1          . 2)
    (1582934400  . 4)
    (1700000000  . 8)
    (1772407800  . 16)
    (1775003400  . 32)))

(define fixed-zones
  (list (cons "utc" (tesl-tz-utc))
        (cons "+120" (tesl-tz-fixed 120))
        (cons "-480" (tesl-tz-fixed -480))
        (cons "+330" (tesl-tz-fixed 330))))
(define named-zones
  '("Europe/Stockholm" "America/New_York" "Asia/Kolkata"
    "America/Santiago" "Australia/Lord_Howe"))
(define units '(hour day week month year))

(define (strip v)
  (let loop ([x (raw-value v)])
    (if (newtype-value? x) (loop (newtype-value-value x)) x)))

(define (expected-groups unit tz agg-of)
  ;; reference: bucket each seeded row with tesl-time-trunc, aggregate per
  ;; bucket, sort by bucket — exactly what the SQL must produce.
  (define groups (make-hash))
  (for ([r (in-list seed-rows)])
    (define k (tesl-time-trunc unit tz (* (car r) 1000)))
    (hash-update! groups k (lambda (l) (cons r l)) '()))
  (for/list ([k (in-list (sort (hash-keys groups) <))])
    (cons k (agg-of (hash-ref groups k)))))

(define (run-group-by-parity-tests cfg)
  (define host (hash-ref cfg 'host))
  (define port (hash-ref cfg 'port))
  (define db-name (hash-ref cfg 'database))
  (define user (hash-ref cfg 'user))

  (define-database ParityDb
    #:backend postgres
    #:database db-name
    #:user user
    #:server host
    #:port port
    #:schema group_by_parity
    #:entities ParityRow)

  (call-with-database
   ParityDb
   (lambda ()
     (with-capabilities (db-read db-write)
       (for ([r (in-list seed-rows)]
             [i (in-naturals)])
         (insert-one! ParityRow
                      (hash 'id (format "r~a" i)
                            'minutes (cdr r)
                            'startedAt (* (car r) 1000))))

       ;; count-by and sum-by, every unit × zone, versus the reference engine
       (define (check-zone-parity unit tz label)
         (define key (sql-group-key unit tz (entity-field-ref ParityRow 'startedAt)))
         (define got-counts
           (for/list ([row (in-list (select-count-by key (from ParityRow)))])
             (cons (strip (Tuple2.first row)) (strip (Tuple2.second row)))))
         (check-equal? got-counts (expected-groups unit tz length)
                       (format "count-by parity: ~a" label))
         (define got-sums
           (for/list ([row (in-list (select-sum-by key
                                                   (entity-field-ref ParityRow 'minutes)
                                                   (from ParityRow)))])
             (cons (strip (Tuple2.first row)) (strip (Tuple2.second row)))))
         (check-equal? got-sums
                       (expected-groups unit tz
                                        (lambda (rs) (for/sum ([r rs]) (cdr r))))
                       (format "sum-by parity: ~a" label)))
       (for* ([unit (in-list units)]
              [z (in-list fixed-zones)])
         (check-zone-parity unit (cdr z) (format "~a @ ~a" unit (car z))))
       (for* ([unit (in-list units)]
              [zn (in-list named-zones)])
         (check-zone-parity unit (tesl-tz-named zn) (format "~a @ ~a" unit zn)))

       ;; plain-column key on PostgreSQL too (GROUP BY the column itself)
       (define per-min
         (for/list ([row (in-list (select-count-by
                                   (sql-group-key 'field 0 (entity-field-ref ParityRow 'minutes))
                                   (from ParityRow)))])
           (cons (strip (Tuple2.first row)) (strip (Tuple2.second row)))))
       (check-equal? per-min
                     (for/list ([r (in-list (sort (map cdr seed-rows) <))]) (cons r 1))
                     "plain-column group key")))))

(define (run-all)
  (if (not (postgres-tooling-available?))
      (displayln "Skipping sql-group-by-pg-test.rkt because initdb/pg_ctl are not available")
      (call-with-temporary-postgres run-group-by-parity-tests)))

(run-all)
