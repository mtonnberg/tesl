package teslrt

import (
	"fmt"
	"math/big"
	"strconv"
	"strings"
)

// `Tesl.Money` — money as EXACT MINOR UNITS plus a currency, never as a float.
//
// The whole point of the type is that an amount cannot drift: cents are integers, arithmetic
// on them is exact, and the only operations that round say so in their name. Where a rounding
// does happen — a fractional scale, a currency conversion, a rate materialising into an amount
// — it is ROUND HALF EVEN on an exact rational, which is what `tesl/money.rkt` does, so the
// same program lands on the same cent on both backends.
//
// Two rules that look small and are not:
//
//   - a float factor is exactified DECIMAL-FAITHFULLY (0.9155 becomes 1831/2000, not the
//     binary-float 0.91549999…). Without it, 1000 × 0.9155 = 915.4999… quietly rounds DOWN and
//     the half-even contract is dodged;
//   - `minorDigits` is per currency and load-bearing: it drives display AND the digit shift
//     when converting between currencies with different scales (JPY has 0, USD has 2, BHD 3).

type Currency struct {
	Code        string
	MinorDigits int
}

type Money struct {
	MinorUnits Int
	Currency   Currency
}

// ExchangeRate carries PROVENANCE (`AsOf`) beside the rate, because a rate without a time is
// not a fact about anything. The rate itself is stored as an exact rational: conversion math
// never touches a float.
type ExchangeRate struct {
	From Currency
	To   Currency
	Rate *big.Rat
	AsOf PosixMillis
}

// MoneyRate is money PER quantity — an hourly rate, a price per kilogram. The algebra runs on
// `PerCanonical` (minor units per SI-canonical denominator unit: per second, per kilogram);
// the label pair is presentation, and the boundary unit a rate quantizes to.
type MoneyRate struct {
	PerCanonical *big.Rat
	Currency     Currency
	LabelFactor  *big.Rat
	Label        string
}

// MoneyOf is what a `Money.usd 1000` constructor becomes. The code and the digit count are
// baked in by the emitter from the same ISO table the Racket constructors come from, and they
// come LAST so the emitted call reads argument-then-constants.
func MoneyOf(minorUnits Int, code string, minorDigits int) Money {
	return Money{MinorUnits: minorUnits, Currency: Currency{Code: code, MinorDigits: minorDigits}}
}

// CurrencyOf is a `Usd` / `Sek` constructor: the currency itself, with no amount.
func CurrencyOf(code string, minorDigits int) Currency {
	return Currency{Code: code, MinorDigits: minorDigits}
}

func MoneyMinorUnits(money Money) Int    { return money.MinorUnits }
func MoneyCurrency(money Money) Currency { return money.Currency }

func CurrencyCode(currency Currency) string     { return currency.Code }
func CurrencyMinorDigits(currency Currency) Int { return FromInt64(int64(currency.MinorDigits)) }

// CurrencyFromCode resolves an ISO 4217 code at run time — the one place a currency is chosen
// rather than written. An unknown code is Nothing, not a trap: the string usually came from
// outside the program.
func CurrencyFromCode(code string) Maybe[Currency] {
	if currency, found := currencyTable[code]; found {
		return Something(currency)
	}
	return Nothing[Currency]()
}

// MoneyFromMinorUnits builds an amount in a currency chosen at run time.
func MoneyFromMinorUnits(currency Currency, minorUnits Int) Money {
	return Money{MinorUnits: minorUnits, Currency: currency}
}

// ── Arithmetic ────────────────────────────────────────────────────────────────

// MoneyScale multiplies by an exact integer — quantity × unit price stays exact, so it never
// rounds and needs no rounding rule.
func MoneyScale(money Money, factor Int) Money {
	return Money{MinorUnits: Mul(money.MinorUnits, factor), Currency: money.Currency}
}

// MoneyScaleBy multiplies by a FRACTIONAL factor (interest, VAT, a discount): the factor is
// exactified decimal-faithfully, the multiplication runs exact, and the result rounds half-even
// back to whole minor units. It is deliberately not `*`: fractional money scaling rounds, so it
// has to be a named, visible operation.
func MoneyScaleBy(money Money, factor float64) Money {
	scaled := new(big.Rat).Mul(ratOfInt(money.MinorUnits), ratOfFloat("Money.scaleBy", factor))
	return Money{MinorUnits: fromBig(roundHalfEven(scaled)), Currency: money.Currency}
}

func MoneyNegate(money Money) Money {
	return Money{MinorUnits: Sub(FromInt64(0), money.MinorUnits), Currency: money.Currency}
}

func MoneyAbs(money Money) Money {
	if Compare(money.MinorUnits, FromInt64(0)) < 0 {
		return MoneyNegate(money)
	}
	return money
}

func MoneyIsZero(money Money) bool { return Compare(money.MinorUnits, FromInt64(0)) == 0 }

func MoneyIsNegative(money Money) bool { return Compare(money.MinorUnits, FromInt64(0)) < 0 }

// MoneyAdd and MoneySubtract are SAME-CURRENCY operations. A mismatch traps rather than
// picking a side: the checker's `SameCurrency` proof is what makes them total, so reaching
// here with two currencies means that proof was bypassed.
func MoneyAdd(left, right Money) Money {
	requireSameCurrency("Money.add", left, right)
	return Money{MinorUnits: Add(left.MinorUnits, right.MinorUnits), Currency: left.Currency}
}

func MoneySubtract(left, right Money) Money {
	requireSameCurrency("Money.subtract", left, right)
	return Money{MinorUnits: Sub(left.MinorUnits, right.MinorUnits), Currency: left.Currency}
}

// MoneyCompare answers -1 / 0 / 1 on minor units, which are comparable because the currency
// is the same.
func MoneyCompare(left, right Money) Int {
	requireSameCurrency("Money.compare", left, right)
	return FromInt64(int64(Compare(left.MinorUnits, right.MinorUnits)))
}

func requireSameCurrency(who string, left, right Money) {
	if left.Currency.Code != right.Currency.Code {
		panic(fmt.Sprintf("%s: expected amounts in the same currency, got %s vs %s",
			who, left.Currency.Code, right.Currency.Code))
	}
}

// ── Display ───────────────────────────────────────────────────────────────────

// symbolPrefix is the handful of currencies conventionally written symbol-first; everything
// else renders amount-then-code ("10.50 SEK").
var symbolPrefix = map[string]string{"USD": "$", "EUR": "€", "GBP": "£", "JPY": "¥"}

// MoneyDisplay renders an amount the way `tesl-money-display` does, digits driven by the
// currency: USD 1000 → "$10.00", JPY 1000 → "¥1000", SEK 1050 → "10.50 SEK", and a negative
// amount keeps its sign in front of the symbol.
func MoneyDisplay(money Money) string {
	magnitude := MoneyAbs(money).MinorUnits
	amount := magnitude.String()
	if money.Currency.MinorDigits > 0 {
		divisor := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(money.Currency.MinorDigits)), nil)
		major, minor := new(big.Int).QuoRem(magnitude.bigInt(), divisor, new(big.Int))
		minorText := minor.String()
		padding := money.Currency.MinorDigits - len(minorText)
		amount = major.String() + "." + strings.Repeat("0", padding) + minorText
	}
	sign := ""
	if MoneyIsNegative(money) {
		sign = "-"
	}
	if prefix, found := symbolPrefix[money.Currency.Code]; found {
		return sign + prefix + amount
	}
	return sign + amount + " " + money.Currency.Code
}

// ── Exchange rates and conversion ─────────────────────────────────────────────

func ExchangeRateMake(from, to Currency, rate float64, asOf PosixMillis) ExchangeRate {
	return ExchangeRate{From: from, To: to, Rate: ratOfFloat("ExchangeRate.make", rate), AsOf: asOf}
}

func ExchangeRateFromCurrency(rate ExchangeRate) Currency { return rate.From }
func ExchangeRateToCurrency(rate ExchangeRate) Currency   { return rate.To }
func ExchangeRateAsOf(rate ExchangeRate) PosixMillis      { return rate.AsOf }

// ExchangeRateRate answers the rate as a Float — a lossy view of an exact value, which is why
// the conversion math never goes through it.
func ExchangeRateRate(rate ExchangeRate) float64 {
	value, _ := rate.Rate.Float64()
	return value
}

// convertedMinorUnits is
//
//	minor_dst = round-half-even(minor_src × rate × 10^(digits_dst − digits_src))
//
// on exact rationals throughout. The digit shift rescales between minor-unit magnitudes, so
// converting JPY (0 digits) into USD (2 digits) multiplies by 100 rather than losing the cents.
func convertedMinorUnits(rate ExchangeRate, money Money) Int {
	shift := new(big.Rat).SetInt(new(big.Int).Exp(big.NewInt(10),
		big.NewInt(int64(abs(rate.To.MinorDigits-rate.From.MinorDigits))), nil))
	if rate.To.MinorDigits < rate.From.MinorDigits {
		shift = new(big.Rat).Inv(shift)
	}
	product := new(big.Rat).Mul(ratOfInt(money.MinorUnits), rate.Rate)
	product = product.Mul(product, shift)
	return fromBig(roundHalfEven(product))
}

func abs(value int) int {
	if value < 0 {
		return -value
	}
	return value
}

// MoneyConvert is the UNPROVEN path: a rate whose FROM currency is not the amount's is an Err
// the caller has to handle, not a trap.
func MoneyConvert(rate ExchangeRate, money Money) Result[Money, string] {
	if rate.From.Code != money.Currency.Code {
		return MakeErr[Money, string](fmt.Sprintf("exchange rate is FROM %s but amount is in %s",
			rate.From.Code, money.Currency.Code))
	}
	return MakeOk[Money, string](Money{MinorUnits: convertedMinorUnits(rate, money), Currency: rate.To})
}

// MoneyConvertChecked is the proof-gated path: `RateFor r m` guarantees the currencies match,
// so this is total given the proof. A mismatch here means the proof layer was bypassed, and it
// fails loudly rather than converting at a rate that does not apply.
func MoneyConvertChecked(rate ExchangeRate, money Money) Money {
	if rate.From.Code != money.Currency.Code {
		panic(fmt.Sprintf("Money.convertChecked: exchange rate is FROM %s but amount is in %s"+
			" — this needs a RateFor proof (use `check Money.requireRateFor(r, m)` first)",
			rate.From.Code, money.Currency.Code))
	}
	return Money{MinorUnits: convertedMinorUnits(rate, money), Currency: rate.To}
}

// ── The checks that mint the proofs ───────────────────────────────────────────
//
// Each answers the value the proof is about, so the caller binds it and carries the proof; the
// proof itself erases here, and what survives is the validation and its 400.

func MoneyRequireNonNegative(money Money) Check[Money] {
	if MoneyIsNegative(money) {
		return Reject[Money](400, "amount must be non-negative")
	}
	return Accept(money)
}

func MoneyRequireSameCurrency(left, right Money) Check[Money] {
	if left.Currency.Code != right.Currency.Code {
		return Reject[Money](400, fmt.Sprintf(
			"expected amounts in the same currency, got %s vs %s",
			left.Currency.Code, right.Currency.Code))
	}
	return Accept(right)
}

func MoneyRequireRateFor(rate ExchangeRate, money Money) Check[Money] {
	if rate.From.Code != money.Currency.Code {
		return Reject[Money](400, fmt.Sprintf(
			"exchange rate is FROM %s but amount is in %s",
			rate.From.Code, money.Currency.Code))
	}
	return Accept(money)
}

// ── Money per quantity ────────────────────────────────────────────────────────

// MoneyRateOf is a fixed-denominator constructor (`MoneyRate.perHour`): the amount IS the price
// per label unit, so per-canonical is that amount divided by the canonical units in one label
// unit — 3600 for an hour, 1/1000 for a litre.
func MoneyRateOf(money Money, canonicalPerLabel *big.Rat, label string) MoneyRate {
	return MoneyRate{
		PerCanonical: new(big.Rat).Quo(ratOfInt(money.MinorUnits), canonicalPerLabel),
		Currency:     money.Currency,
		LabelFactor:  canonicalPerLabel,
		Label:        label,
	}
}

// MoneyRateOfLabel and MoneyRateDivLabel are the shapes EMITTED code calls: the label factor
// arrives as a fraction of plain integers, so an emitted module needs no big-number import of
// its own for what is a compile-time constant.
func MoneyRateOfLabel(money Money, labelNum, labelDen int64, label string) MoneyRate {
	return MoneyRateOf(money, big.NewRat(labelNum, labelDen), label)
}

func MoneyRateDivLabel(money Money, quantity float64, labelNum, labelDen int64,
	label string) MoneyRate {
	return MoneyRateDiv(money, quantity, big.NewRat(labelNum, labelDen), label)
}

// MoneyRateDiv is `money / quantity`. The label pair comes from the checker's type, so a rate
// displays and quantizes per HOUR rather than per second — a realistic hourly rate would
// otherwise quantize to zero at a boundary.
func MoneyRateDiv(money Money, quantity float64, canonicalPerLabel *big.Rat, label string) MoneyRate {
	if quantity == 0 {
		panic("MoneyRate: division by a zero quantity")
	}
	return MoneyRate{
		PerCanonical: new(big.Rat).Quo(ratOfInt(money.MinorUnits),
			ratOfFloat("MoneyRate", quantity)),
		Currency:    money.Currency,
		LabelFactor: canonicalPerLabel,
		Label:       label,
	}
}

// MoneyRateMul is `rate × quantity` — the ONE place a rate becomes an amount, and so the one
// half-even rounding in the algebra.
func MoneyRateMul(rate MoneyRate, quantity float64) Money {
	product := new(big.Rat).Mul(rate.PerCanonical, ratOfFloat("MoneyRate", quantity))
	return Money{MinorUnits: fromBig(roundHalfEven(product)), Currency: rate.Currency}
}

// MoneyRateScale rescales a rate by a scalar, exactly: nothing rounds until an amount
// materialises.
func MoneyRateScale(rate MoneyRate, factor float64) MoneyRate {
	return MoneyRate{
		PerCanonical: new(big.Rat).Mul(rate.PerCanonical, ratOfFloat("MoneyRate", factor)),
		Currency:     rate.Currency,
		LabelFactor:  rate.LabelFactor,
		Label:        rate.Label,
	}
}

func MoneyRateCurrency(rate MoneyRate) Currency { return rate.Currency }

// MoneyRateDisplay renders the rate's amount per DISPLAY unit — "950.00 SEK/h", "$0.25/kg".
// The rounding is for rendering only; the stored rate stays exact.
func MoneyRateDisplay(rate MoneyRate) string {
	perLabel := new(big.Rat).Mul(rate.PerCanonical, rate.LabelFactor)
	amount := Money{MinorUnits: fromBig(roundHalfEven(perLabel)), Currency: rate.Currency}
	return MoneyDisplay(amount) + "/" + rate.Label
}

// ── Exact-rational helpers ────────────────────────────────────────────────────

func ratOfInt(value Int) *big.Rat {
	return new(big.Rat).SetInt(value.bigInt())
}

// ratOfFloat exactifies a float DECIMAL-FAITHFULLY: the shortest round-trip decimal of a
// float64 is exactly the decimal the author wrote, so 0.9155 becomes 1831/2000 rather than the
// binary-float value just under it. Racket reaches for the same trick
// (`number->string` + `decimal-as-exact`), and for the same reason: without it a rate of
// 0.9155 applied to 1000 lands on 915.4999… and rounds DOWN, dodging the half-even contract.
func ratOfFloat(who string, value float64) *big.Rat {
	text := strconv.FormatFloat(value, 'g', -1, 64)
	rat, ok := new(big.Rat).SetString(text)
	if !ok {
		panic(who + ": factor must be a finite number, got " + text)
	}
	return rat
}

// roundHalfEven rounds an exact rational to an integer, breaking a tie toward the EVEN
// neighbour — the rule Racket's `round` follows on exact rationals, and the one that does not
// bias a long series of roundings upward.
func roundHalfEven(value *big.Rat) *big.Int {
	quotient, remainder := new(big.Int).QuoRem(value.Num(), value.Denom(), new(big.Int))
	if remainder.Sign() == 0 {
		return quotient
	}
	// Compare |remainder| with half the denominator, without leaving the integers.
	twiceRemainder := new(big.Int).Abs(remainder)
	twiceRemainder.Lsh(twiceRemainder, 1)
	comparison := twiceRemainder.Cmp(value.Denom())
	roundAway := comparison > 0
	if comparison == 0 {
		// A tie goes to the even neighbour: away from zero only when truncation left an odd
		// quotient.
		roundAway = quotient.Bit(0) == 1
	}
	if !roundAway {
		return quotient
	}
	if value.Sign() < 0 {
		return quotient.Sub(quotient, big.NewInt(1))
	}
	return quotient.Add(quotient, big.NewInt(1))
}
