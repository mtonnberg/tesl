#lang racket

;;; TimeZone ADT ⇄ tzdata seam (GitHub #29 follow-up).
;;;
;;; The Tesl `TimeZone` zone constructors are BAKED into the compiler
;;; (compiler/lib/tz_zones.ml, generated from the system zoneinfo tree by
;;; scripts/gen-tz-zones.py); the runtime resolves each constructor's IANA name
;;; against the system tzdata at query time (dsl/private/tzif.rkt).  This test
;;; is the drift seam: every baked constructor must resolve on THIS system —
;;; a tzdata upgrade that drops a zone, or a generator bug, fails here instead
;;; of at some user's first query.

(require rackunit
         racket/runtime-path
         "../dsl/private/tzif.rkt"
         "../dsl/private/time-trunc.rkt")

(define-runtime-path tz-zones-ml "../compiler/lib/tz_zones.ml")

;; parse the generated OCaml table: lines of  ("Ctor", "IANA/Name");
(define pairs
  (for/list ([line (in-list (file->lines tz-zones-ml))]
             #:when (regexp-match? #px"^  \\(\"" line))
    (match (regexp-match #px"\\(\"([^\"]+)\", \"([^\"]+)\"\\)" line)
      [(list _ ctor iana) (cons ctor iana)]
      [_ (error 'timezone-zones-test "unparseable line: ~a" line)])))

(check-true (> (length pairs) 400)
            "the baked zone table has a plausible size")

(check-equal? (length (remove-duplicates (map car pairs)))
              (length pairs)
              "constructor names are unique")

;; The familiar link names must be present (zone1970.tab alone loses them —
;; Europe/Stockholm is a link to Europe/Berlin in modern tzdata).
(for ([must '(("EuropeStockholm" . "Europe/Stockholm")
              ("EuropeOslo" . "Europe/Oslo")
              ("AmericaNewYork" . "America/New_York")
              ("AsiaKolkata" . "Asia/Kolkata"))])
  (check-equal? (assoc (car must) pairs) must
                (format "baked table contains ~a" (car must))))

;; Every baked zone resolves against the system tzdata, and its offset at two
;; instants (winter/summer 2023) is a sane sub-day quantity on a whole minute.
(for ([p (in-list pairs)])
  (define iana (cdr p))
  (check-true (tzif-zone-exists? iana) (format "~a exists in tzdata" iana))
  (define tz (tesl-tz-named iana))
  (for ([ms (in-list '(1673000000000 1689000000000))])
    (define off (tesl-tz-offset-minutes tz ms))
    (check-true (and (exact-integer? off) (< (abs off) 1440))
                (format "~a offset sane at ~a (got ~a)" iana ms off))))

(printf "timezone-zones-test: ~a zones verified against system tzdata\n"
        (length pairs))
