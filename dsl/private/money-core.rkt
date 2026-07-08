#lang racket/base

;;; Money core (First-Class Units, phase 1) — the tesl-currency / tesl-money
;;; structs and the `define-currencies` macro that the GENERATED
;;; dsl/private/currency-data.rkt invokes with the baked ISO 4217 table.
;;;
;;; Layering (mirrors time-trunc.rkt / tzif.rkt):
;;;   money-core.rkt      (hand)      structs + macro, no data
;;;   currency-data.rkt   (generated) (define-currencies ("USD" 2 Money.usd) ...)
;;;   tesl/money.rkt      (hand)      surface ops, proofs, display, convert
;;;
;;; A currency's minor_digits is load-bearing (rounding + display): USD=2,
;;; JPY=0, BHD=3.  Money amounts are ALWAYS exact-integer minor units — money
;;; never touches a float.

(require (for-syntax racket/base))

(provide (struct-out tesl-currency)
         (struct-out tesl-money)
         (struct-out tesl-exchange-rate)
         tesl-currency-of
         tesl-currency-table
         tesl-money-display
         define-currencies)

;; code = ISO 4217 alpha code string ("USD"); minor-digits = exact int (2/0/3)
(struct tesl-currency (code minor-digits) #:transparent)

;; minor-units = exact integer (cents / öre / yen); currency = tesl-currency
(struct tesl-money (minor-units currency) #:transparent)

;; from/to = tesl-currency; rate = EXACT rational (inexact->exact at
;; construction — conversion math never touches a float); asOf = the
;; provenance PosixMillis, stored as given.  Lives here (not tesl/money.rkt)
;; so dsl/types.rkt can encode it without requiring the surface module.
(struct tesl-exchange-rate (from to rate asOf) #:transparent)

;; Populated once by the define-currencies expansion in currency-data.rkt.
(define tesl-currency-table (make-hash))

;; Resolve an ISO code ("USD") to its baked tesl-currency, #f if unknown —
;; the runtime seam behind Currency constructor lowering and JSON decode.
(define (tesl-currency-of code)
  (hash-ref tesl-currency-table code #f))

;; The handful of currencies conventionally written symbol-FIRST; everything
;; else renders amount-then-code ("10.50 SEK").
(define symbol-prefix-table
  (hash "USD" "$" "EUR" "€" "GBP" "£" "JPY" "¥"))

;; Human-readable rendering of a tesl-money, digits driven by the currency's
;; minor-digits: USD 1000 → "$10.00"; JPY 1000 → "¥1000"; SEK 1050 →
;; "10.50 SEK"; negative → "-$10.00".  Lives here (not tesl/money.rkt) so
;; dsl/types.rkt can enrich agent-facing JSON without requiring the surface
;; module; Money.display wraps it.
(define (tesl-money-display m)
  (define cur (tesl-money-currency m))
  (define code (tesl-currency-code cur))
  (define digits (tesl-currency-minor-digits cur))
  (define units (tesl-money-minor-units m))
  (define magnitude (abs units))
  (define amount
    (if (zero? digits)
        (number->string magnitude)
        (let*-values ([(major minor) (quotient/remainder magnitude (expt 10 digits))])
          (define minor-str (number->string minor))
          (define padded
            (string-append (make-string (- digits (string-length minor-str)) #\0)
                           minor-str))
          (format "~a.~a" major padded))))
  (define sign (if (negative? units) "-" ""))
  (define prefix (hash-ref symbol-prefix-table code #f))
  (if prefix
      (string-append sign prefix amount)
      (string-append sign amount " " code)))

;; (define-currencies ("USD" 2 Money.usd) ("EUR" 2 Money.eur) ...)
;; expands to: table entries + one per-currency Money constructor each taking
;; exact-integer minor units, all provided (static provides so the stdlib
;; binding-existence seam test sees real bindings).
(define-syntax (define-currencies stx)
  (syntax-case stx ()
    [(_ (code digits ctor-id) ...)
     #'(begin
         (begin
           (hash-set! tesl-currency-table code (tesl-currency code digits))
           (define (ctor-id n)
             (unless (exact-integer? n)
               (error 'ctor-id
                      "Money constructors take exact-integer MINOR units (cents/öre/yen), got: ~e"
                      n))
             (tesl-money n (tesl-currency code digits)))
           (provide ctor-id)) ...)]))
