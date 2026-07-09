#lang racket

;;; Tesl.Money — First-Class Units, phase 1: exact-integer minor-unit money
;;; with an intrinsic ISO 4217 currency qualifier.
;;;
;;; Money NEVER touches a float: amounts are exact-integer MINOR units
;;; (cents / öre / yen) and conversion math runs on exact rationals with a
;;; single round-half-even at the end.  Same-currency safety is proof-layer:
;;; Money.add / Money.subtract / Money.compare statically require a
;;; SameCurrency proof (minted by `check Money.requireSameCurrency(a, b)`);
;;; the runtime checks here are defense in depth, not the safety story.
;;; Cross-currency conversion is EXPLICIT — a runtime-supplied ExchangeRate
;;; with provenance (asOf), never an ambient default rate.
;;;
;;; Layering (mirrors time-trunc.rkt / tzif.rkt):
;;;   dsl/private/money-core.rkt      structs + display + define-currencies
;;;   dsl/private/currency-data.rkt   GENERATED baked ISO 4217 table
;;;   tesl/money.rkt                  surface ops, proofs, convert (this file)
;;;
;;; Usage:
;;;   import Tesl.Money exposing [Money, Currency, Money.usd, Money.add, ...]
;;;   let price = Money.usd(1050)        -- $10.50, minor units
;;;
;;; Pure module: no capability.

(require "../dsl/check.rkt"
         "../dsl/types.rkt"
         "../dsl/private/money-core.rkt"
         "../dsl/private/currency-data.rkt"
         (only-in "../dsl/private/evidence.rkt" detached-proof check-ok check-fail)
         (only-in "../dsl/private/check-runtime.rkt" attach validate-runtime-argument))

(provide
 ;; type-name symbols (mirrors Dict/Maybe: the imported type names are values)
 Money
 Currency
 ExchangeRate
 MoneyPerDuration
 MoneyPerMass
 MoneyPerLength
 MoneyPerArea
 MoneyPerVolume
 ;; proof predicates
 SameCurrency
 NonNegativeMoney
 RateFor
 ;; construction + accessors
 Money.fromMinorUnits
 Money.minorUnits
 Money.currency
 Money.scale
 Money.scaleBy
 Money.negate
 Money.abs
 Money.isZero
 Money.isNegative
 Money.display
 ;; same-currency arithmetic (proof-gated at compile time)
 Money.add
 Money.subtract
 Money.compare
 ;; check functions (proof mints)
 Money.requireSameCurrency
 Money.requireNonNegative
 Money.requireRateFor
 ;; explicit cross-currency conversion
 Money.convert
 Money.convertChecked
 Currency.code
 Currency.minorDigits
 Currency.fromCode
 ExchangeRate.make
 ExchangeRate.fromCurrency
 ExchangeRate.toCurrency
 ExchangeRate.rate
 ExchangeRate.asOf
 ;; per-currency constructors (Money.usd … Money.zwg) from the generated table
 (all-from-out "../dsl/private/currency-data.rkt")
 ;; runtime seam for the emitted Currency-constructor lowering
 ;; (`Usd` → `(__tmoney_tesl-currency-of "USD")`, like tesl-tz-* in time.rkt)
 tesl-currency-of
 (struct-out tesl-money)
 (struct-out tesl-currency)
 (struct-out tesl-exchange-rate))

;; ── Type-name symbols ────────────────────────────────────────────────────────

(define Money 'Money)
(define Currency 'Currency)
(define ExchangeRate 'ExchangeRate)

;; MoneyRate alias type names: they appear verbatim in emitted type positions
;; (handler #:returns / endpoint types), so they must be require-bound in the
;; importing module or the minted type-ref is keyed to the emitting file and
;; cross-module server wiring rejects it (issue #42).
(define MoneyPerDuration 'MoneyPerDuration)
(define MoneyPerMass 'MoneyPerMass)
(define MoneyPerLength 'MoneyPerLength)
(define MoneyPerArea 'MoneyPerArea)
(define MoneyPerVolume 'MoneyPerVolume)

;; ── Proof predicates ─────────────────────────────────────────────────────────

(define SameCurrency 'SameCurrency)
(define NonNegativeMoney 'NonNegativeMoney)
(define RateFor 'RateFor)

;; ── Internal helpers ─────────────────────────────────────────────────────────

;; Arguments may arrive wrapped in named-values / check-oks (proof plumbing);
;; unwrap to the raw struct, failing with a clear who-tagged error.

(define (money-raw who v)
  (define raw (raw-value v))
  (unless (tesl-money? raw)
    (raise-user-error who "expected a Money value, got ~e" raw))
  raw)

(define (currency-raw who v)
  (define raw (raw-value v))
  (unless (tesl-currency? raw)
    (raise-user-error who "expected a Currency value, got ~e" raw))
  raw)

(define (rate-raw who v)
  (define raw (raw-value v))
  (unless (tesl-exchange-rate? raw)
    (raise-user-error who "expected an ExchangeRate value, got ~e" raw))
  raw)

(define (money-code m) (tesl-currency-code (tesl-money-currency m)))

;; Defense in depth for the same-currency ops: the SameCurrency proof normally
;; rules a mismatch out at compile time; a runtime mismatch means the proof
;; layer was bypassed, so fail loudly rather than add öre to yen.
(define (same-currency-values who a b)
  (define ra (money-raw who a))
  (define rb (money-raw who b))
  (define code-a (money-code ra))
  (define code-b (money-code rb))
  (unless (string=? code-a code-b)
    (raise-user-error who
                      "currency mismatch: ~a vs ~a — same-currency arithmetic requires a SameCurrency proof (use `check Money.requireSameCurrency(a, b)` first)"
                      code-a code-b))
  (values ra rb))

;; ── Construction + accessors ─────────────────────────────────────────────────

;; Build a Money from a Currency and exact-integer MINOR units.
(define (Money.fromMinorUnits currency n)
  (define cur (currency-raw 'Money.fromMinorUnits currency))
  (define units (raw-value n))
  (unless (exact-integer? units)
    (raise-user-error 'Money.fromMinorUnits
                      "Money amounts are exact-integer MINOR units (cents/öre/yen), got: ~e"
                      units))
  (tesl-money units cur))

(define (Money.minorUnits m)
  (tesl-money-minor-units (money-raw 'Money.minorUnits m)))

(define (Money.currency m)
  (tesl-money-currency (money-raw 'Money.currency m)))

;; Scale by an exact integer factor (quantity × unit price stays exact).
(define (Money.scale m k)
  (define raw (money-raw 'Money.scale m))
  (define factor (raw-value k))
  (unless (exact-integer? factor)
    (raise-user-error 'Money.scale
                      "scale factor must be an exact integer, got: ~e" factor))
  (tesl-money (* (tesl-money-minor-units raw) factor)
              (tesl-money-currency raw)))

;; Scale by a FRACTIONAL factor (interest, VAT, discounts): the factor is
;; exactified decimal-faithfully (1.055 → 211/200, the same rate->exact used
;; by ExchangeRate), the multiplication runs exact, and the result rounds
;; HALF-EVEN back to integer minor units.  The Money invariant holds: amounts
;; never live as floats — the factor is transient.  Deliberately NOT `*`:
;; fractional money scaling rounds, so it must be a named, visible operation.
(define (Money.scaleBy m factor)
  (define raw (money-raw 'Money.scaleBy m))
  (define f (raw-value factor))
  (unless (rational? f) ; finite real — rules out +inf.0 / +nan.0
    (raise-user-error 'Money.scaleBy
                      "scale factor must be a finite number, got: ~e" f))
  (tesl-money (round (* (tesl-money-minor-units raw) (rate->exact f)))
              (tesl-money-currency raw)))

(define (Money.negate m)
  (define raw (money-raw 'Money.negate m))
  (tesl-money (- (tesl-money-minor-units raw)) (tesl-money-currency raw)))

(define (Money.abs m)
  (define raw (money-raw 'Money.abs m))
  (tesl-money (abs (tesl-money-minor-units raw)) (tesl-money-currency raw)))

(define (Money.isZero m)
  (zero? (tesl-money-minor-units (money-raw 'Money.isZero m))))

(define (Money.isNegative m)
  (negative? (tesl-money-minor-units (money-raw 'Money.isNegative m))))

;; Human-readable rendering — the ONE display definition lives in money-core
;; (tesl-money-display) so the agent-boundary enrichment in dsl/types.rkt
;; shows byte-identical text.
(define (Money.display m)
  (tesl-money-display (money-raw 'Money.display m)))

;; ── Same-currency arithmetic ─────────────────────────────────────────────────

(define (Money.add a b)
  (define-values (ra rb) (same-currency-values 'Money.add a b))
  (tesl-money (+ (tesl-money-minor-units ra) (tesl-money-minor-units rb))
              (tesl-money-currency ra)))

(define (Money.subtract a b)
  (define-values (ra rb) (same-currency-values 'Money.subtract a b))
  (tesl-money (- (tesl-money-minor-units ra) (tesl-money-minor-units rb))
              (tesl-money-currency ra)))

;; -1 / 0 / 1 on minor units (same currency, so minor units are comparable).
(define (Money.compare a b)
  (define-values (ra rb) (same-currency-values 'Money.compare a b))
  (define ua (tesl-money-minor-units ra))
  (define ub (tesl-money-minor-units rb))
  (cond [(< ua ub) -1]
        [(> ua ub) 1]
        [else 0]))

;; ── Currency ─────────────────────────────────────────────────────────────────

(define (Currency.code c)
  (tesl-currency-code (currency-raw 'Currency.code c)))

(define (Currency.minorDigits c)
  (tesl-currency-minor-digits (currency-raw 'Currency.minorDigits c)))

;; Resolve an ISO 4217 code at runtime: Something(currency) or Nothing.
(define (Currency.fromCode s)
  (define code (raw-value s))
  (define cur (and (string? code) (tesl-currency-of code)))
  (if cur (Something cur) Nothing))

;; ── ExchangeRate ─────────────────────────────────────────────────────────────

;; Exactify a rate DECIMAL-faithfully: a flonum's shortest round-trip print
;; form is exactly the decimal the user wrote (0.9155 → 1831/2000), whereas a
;; raw `inexact->exact` keeps the binary-float noise (0.91549999999…), which
;; would turn 1000 × 0.9155 = 915.5 into 915.4999… and silently dodge the
;; round-half-even contract.  Exact inputs pass through untouched.
(define (rate->exact r)
  (if (exact? r)
      r
      (or (string->number (number->string r) 10 'number-or-false 'decimal-as-exact)
          (inexact->exact r))))

;; Rate data always carries provenance (asOf); the rate is converted to an
;; EXACT rational at construction so all conversion math stays exact.
(define (ExchangeRate.make from to rate asOf)
  (define from-cur (currency-raw 'ExchangeRate.make from))
  (define to-cur (currency-raw 'ExchangeRate.make to))
  (define r (raw-value rate))
  (unless (rational? r) ; finite real — rules out +inf.0 / +nan.0
    (raise-user-error 'ExchangeRate.make "rate must be a finite number, got: ~e" r))
  (tesl-exchange-rate from-cur to-cur (rate->exact r) (raw-value asOf)))

(define (ExchangeRate.fromCurrency r)
  (tesl-exchange-rate-from (rate-raw 'ExchangeRate.fromCurrency r)))

(define (ExchangeRate.toCurrency r)
  (tesl-exchange-rate-to (rate-raw 'ExchangeRate.toCurrency r)))

(define (ExchangeRate.rate r)
  (exact->inexact (tesl-exchange-rate-rate (rate-raw 'ExchangeRate.rate r))))

(define (ExchangeRate.asOf r)
  (tesl-exchange-rate-asOf (rate-raw 'ExchangeRate.asOf r)))

;; ── Conversion ───────────────────────────────────────────────────────────────

;; minor_dst = round-half-even(minor_src × rate × 10^(dig_dst − dig_src)),
;; computed entirely on exact rationals — Racket's `round` on an exact
;; rational IS round-half-even (banker's rounding), and the result is an
;; exact integer.  The digit-shift term rescales between minor-unit
;; magnitudes (JPY 0 digits → USD 2 digits multiplies by 100).
(define (converted-minor-units rr rm)
  (define to-cur (tesl-exchange-rate-to rr))
  (define from-cur (tesl-exchange-rate-from rr))
  (round (* (tesl-money-minor-units rm)
            (tesl-exchange-rate-rate rr)
            (expt 10 (- (tesl-currency-minor-digits to-cur)
                        (tesl-currency-minor-digits from-cur))))))

;; Result-typed conversion: Err when the rate's FROM currency does not match
;; the amount's currency (the un-proven path).
(define (Money.convert r m)
  (define rr (rate-raw 'Money.convert r))
  (define rm (money-raw 'Money.convert m))
  (define from-code (tesl-currency-code (tesl-exchange-rate-from rr)))
  (define amount-code (money-code rm))
  (if (string=? from-code amount-code)
      (Ok (tesl-money (converted-minor-units rr rm) (tesl-exchange-rate-to rr)))
      (Err (format "exchange rate is FROM ~a but amount is in ~a"
                   from-code amount-code))))

;; Proof-gated conversion: `RateFor r m` (minted by Money.requireRateFor)
;; guarantees the currencies match, so this is total given the proof; a
;; runtime mismatch means the proof layer was bypassed — fail loudly.
(define (Money.convertChecked r m)
  (define rr (rate-raw 'Money.convertChecked r))
  (define rm (money-raw 'Money.convertChecked m))
  (define from-code (tesl-currency-code (tesl-exchange-rate-from rr)))
  (define amount-code (money-code rm))
  (unless (string=? from-code amount-code)
    (raise-user-error 'Money.convertChecked
                      "exchange rate is FROM ~a but amount is in ~a — Money.convertChecked requires a RateFor proof (use `check Money.requireRateFor(r, m)` first)"
                      from-code amount-code))
  (tesl-money (converted-minor-units rr rm) (tesl-exchange-rate-to rr)))

;; ── Check functions (proof mints) ────────────────────────────────────────────

;; Helper: attach NonNegativeMoney proof to a value (uuid.rkt's single-subject
;; attach-uuid-proof pattern).
(define (attach-non-negative-proof value raw)
  (define nv (ensure-named 'NonNegativeMoney value))
  (define subj (named-value-name nv))
  (attach nv (list (detached-proof `(NonNegativeMoney ,subj) (hash subj raw)))))

;; Validate an amount is >= 0 minor units.
;; Returns check-ok with NonNegativeMoney proof on success, check-fail otherwise.
(define (Money.requireNonNegative m)
  (define raw (money-raw 'Money.requireNonNegative m))
  (if (>= (tesl-money-minor-units raw) 0)
      (let* ([nv (attach-non-negative-proof m raw)]
             [subj (named-value-name nv)]
             [fact `(NonNegativeMoney ,subj)])
        (check-ok nv (list fact) (hash subj raw)))
      (check-fail "amount must be non-negative" 400 #f)))

;; Validate two amounts share a currency, minting the two-subject fact
;; `(SameCurrency a b)` (the Dict.requireKey HasKey shape).  The returned
;; value is B carrying the proof; both subjects land in the bindings via
;; attach, so cross-parameter proof matching sees both raw values.
(define (Money.requireSameCurrency a b)
  (define checked-a
    (validate-runtime-argument 'Money.requireSameCurrency "check" 'a a 'Any))
  (define checked-b
    (validate-runtime-argument 'Money.requireSameCurrency "check" 'b b 'Any))
  (define ra (money-raw 'Money.requireSameCurrency checked-a))
  (define rb (money-raw 'Money.requireSameCurrency checked-b))
  (define code-a (money-code ra))
  (define code-b (money-code rb))
  (if (string=? code-a code-b)
      (let* ([subj-a (named-value-name checked-a)]
             [subj-b (named-value-name checked-b)]
             [proof (detached-proof `(SameCurrency ,subj-a ,subj-b)
                                    (hash subj-a ra
                                          subj-b rb))]
             [b-with-proof (attach checked-b (list proof))])
        (check-ok b-with-proof
                  (facts-of b-with-proof)
                  (named-value-bindings b-with-proof)))
      (check-fail (format "expected amounts in the same currency, got ~a vs ~a"
                          code-a code-b)
                  400 #f)))

;; Validate a rate's FROM currency matches the amount's currency, minting the
;; two-subject fact `(RateFor r m)` — the proof Money.convertChecked requires.
;; The returned value is the AMOUNT carrying the proof.
(define (Money.requireRateFor r m)
  (define checked-r
    (validate-runtime-argument 'Money.requireRateFor "check" 'r r 'Any))
  (define checked-m
    (validate-runtime-argument 'Money.requireRateFor "check" 'm m 'Any))
  (define rr (rate-raw 'Money.requireRateFor checked-r))
  (define rm (money-raw 'Money.requireRateFor checked-m))
  (define from-code (tesl-currency-code (tesl-exchange-rate-from rr)))
  (define amount-code (money-code rm))
  (if (string=? from-code amount-code)
      (let* ([subj-r (named-value-name checked-r)]
             [subj-m (named-value-name checked-m)]
             [proof (detached-proof `(RateFor ,subj-r ,subj-m)
                                    (hash subj-r rr
                                          subj-m rm))]
             [m-with-proof (attach checked-m (list proof))])
        (check-ok m-with-proof
                  (facts-of m-with-proof)
                  (named-value-bindings m-with-proof)))
      (check-fail (format "exchange rate is FROM ~a but amount is in ~a"
                          from-code amount-code)
                  400 #f)))

;; ── Money rates: money PER quantity (First-Class Units) ─────────────────────
;; Construction: `money / quantity` (lowered to tesl-money-rate-div) or a
;; fixed-denominator constructor below.  Consumption: `rate * quantity`
;; (lowered to tesl-money-rate-mul) — dimensions cancel in the CHECKER; here
;; both sides are already erased floats/structs.  The rate stores an EXACT
;; rational (minor units per SI-canonical denominator unit); the ONE
;; half-even rounding happens when Money materializes.

(define (money-rate-raw who v)
  (define raw (raw-value v))
  (unless (tesl-money-rate? raw)
    (raise-user-error who "expected a MoneyRate value, got ~e" raw))
  raw)

;; money ÷ quantity → rate.  label-factor + label = the denominator's DEFAULT
;; boundary unit (per h / per kg / …), emitted by the compiler from the
;; checker's type — drives display AND boundary quantization (per-hour, never
;; per-second, so realistic rates never quantize to 0).
(define (tesl-money-rate-div m q label-factor label)
  (define raw (money-raw 'MoneyRate m))
  (define qty (exact->inexact (raw-value q)))
  (when (zero? qty)
    (raise-user-error 'MoneyRate "division by a zero quantity"))
  (tesl-money-rate (/ (tesl-money-minor-units raw) (inexact->exact qty))
                   (tesl-money-currency raw)
                   label-factor label))

;; rate × quantity → Money (either argument order; the checker guarantees the
;; dimensions match).  ONE half-even rounding, here.
(define (tesl-money-rate-mul a b)
  (define ra (raw-value a))
  (define rb (raw-value b))
  (define-values (rate qty)
    (if (tesl-money-rate? ra) (values ra rb) (values rb ra)))
  (define r (money-rate-raw 'MoneyRate rate))
  (tesl-money (round (* (tesl-money-rate-per-canonical r)
                        (inexact->exact (exact->inexact (raw-value qty)))))
              (tesl-money-rate-currency r)))

;; rate × Float scalar → rate (exact rescale, decimal-faithful factor — the
;; Money.scaleBy stance; no rounding until Money materializes).
(define (tesl-money-rate-scale a b)
  (define ra (raw-value a))
  (define rb (raw-value b))
  (define-values (rate factor)
    (if (tesl-money-rate? ra) (values ra rb) (values rb ra)))
  (define r (money-rate-raw 'MoneyRate rate))
  (define f (raw-value factor))
  (unless (rational? f)
    (raise-user-error 'MoneyRate "rescale factor must be a finite number, got: ~e" f))
  (tesl-money-rate (* (tesl-money-rate-per-canonical r) (rate->exact f))
                   (tesl-money-rate-currency r)
                   (tesl-money-rate-label-factor r)
                   (tesl-money-rate-label r)))

;; Fixed-denominator constructors: the Money amount IS the per-<label> price;
;; per-canonical = minor / (canonical units per label unit), all exact.
(define (make-money-rate who m canonical-per-label label)
  (define raw (money-raw who m))
  (tesl-money-rate (/ (tesl-money-minor-units raw) canonical-per-label)
                   (tesl-money-currency raw)
                   canonical-per-label label))

(define (|MoneyRate.perHour| m)        (make-money-rate 'MoneyRate.perHour m 3600 "h"))
(define (|MoneyRate.perDay| m)         (make-money-rate 'MoneyRate.perDay m 86400 "day"))
(define (|MoneyRate.perKilogram| m)    (make-money-rate 'MoneyRate.perKilogram m 1 "kg"))
(define (|MoneyRate.perLiter| m)       (make-money-rate 'MoneyRate.perLiter m 1/1000 "L"))
(define (|MoneyRate.perSquareMeter| m) (make-money-rate 'MoneyRate.perSquareMeter m 1 "m^2"))

(define (|MoneyRate.currency| r)
  (tesl-money-rate-currency (money-rate-raw 'MoneyRate.currency r)))

(define (|MoneyRate.display| r)
  (tesl-money-rate-display (money-rate-raw 'MoneyRate.display r)))

(provide tesl-money-rate-div tesl-money-rate-mul tesl-money-rate-scale
         (struct-out tesl-money-rate)
         |MoneyRate.perHour| |MoneyRate.perDay| |MoneyRate.perKilogram|
         |MoneyRate.perLiter| |MoneyRate.perSquareMeter|
         |MoneyRate.currency| |MoneyRate.display|)
