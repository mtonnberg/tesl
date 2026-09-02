package teslrt

import (
	"math"
	"math/big"
)

// `Tesl.Units` — dimensioned quantities.
//
// A quantity ERASES to a plain float64: the DIMENSION lives in the compiler's type layer, which
// is where `meters / seconds = meters per second` is checked and where adding a length to a mass
// is rejected. Nothing about that survives to run time, so everything here is ordinary
// arithmetic — the value is already in SI-canonical units by the time it gets here.
//
// The per-unit conversions live in units_data.go, generated from `tesl/units.rkt` so the factors
// have ONE source. What is written by hand is what is not a factor: the affine temperature
// scales, the polymorphic operations, and the non-zero check.

// Temperature is AFFINE, not a scale factor: 0 °C is 273.15 K, so a Celsius value cannot be
// converted by multiplying. The resulting quantity is absolute kelvin.
//
// (Adding two absolute temperatures type-checks — same dimension — and is rarely meaningful;
// the manual says so, and the type system deliberately does not try to encode the difference
// between an absolute temperature and a temperature INTERVAL.)
func TemperatureKelvin(value float64) float64 { return value }

func TemperatureCelsius(value float64) float64 { return value + 273.15 }

func TemperatureFahrenheit(value float64) float64 {
	return (value-32.0)*(5.0/9.0) + 273.15
}

func TemperatureInKelvin(quantity float64) float64 { return quantity }

func TemperatureInCelsius(quantity float64) float64 { return quantity - 273.15 }

func TemperatureInFahrenheit(quantity float64) float64 {
	return (quantity-273.15)*1.8 + 32.0
}

// The polymorphic dimension operations. Each application site is dimension-checked by the
// compiler — `Units.mul` on a length and a length is an area there — so at run time they are
// the obvious float operations.

func UnitsMul(left, right float64) float64 { return left * right }

func UnitsDiv(left, right float64) float64 { return left / right }

func UnitsSquare(value float64) float64 { return value * value }

func UnitsSqrt(value float64) float64 { return math.Sqrt(value) }

func UnitsAbs(value float64) float64 { return math.Abs(value) }

func UnitsNegate(value float64) float64 { return -value }

func UnitsMin(left, right float64) float64 { return math.Min(left, right) }

func UnitsMax(left, right float64) float64 { return math.Max(left, right) }

func UnitsSum(values []float64) float64 {
	total := 0.0
	for _, value := range values {
		total += value
	}
	return total
}

// DurationToMillis and DurationFromMillis bridge a typed Duration and the exact-Int
// milliseconds `PosixMillis` arithmetic speaks. `toMillis` rounds HALF-EVEN on the exact
// rational — the Money stance, and the reason a duration that lands exactly between two
// milliseconds does not drift upward over a long series.
//
// The conversion goes through the float's BINARY value, not its shortest decimal — the
// opposite of what the Money paths do, and deliberately so: `tesl/units.rkt` writes
// `inexact->exact` here while `tesl/money.rkt` exactifies decimal-faithfully. The difference
// is observable, so it is matched rather than tidied: 0.0025 s is a hair ABOVE 2.5 ms in
// binary, so it rounds to 3, where the decimal reading would tie and round to the even 2.
func DurationToMillis(quantity float64) Int {
	exact := new(big.Rat).SetFloat64(quantity)
	if exact == nil {
		// NaN and the infinities have no exact value to round; a duration that is one of
		// them is a bug upstream, and answering some millisecond count would hide it.
		panic("Duration.toMillis: expected a finite duration")
	}
	scaled := new(big.Rat).Mul(exact, big.NewRat(1000, 1))
	return fromBig(roundHalfEven(scaled))
}

func DurationFromMillis(millis Int) float64 {
	value, _ := new(big.Rat).SetInt(millis.bigInt()).Float64()
	return value / 1000.0
}

// UnitsRequireNonZero is the divisor check: quantities erase to floats, so the SAME
// `FloatNonZero` predicate that guards float division guards quantity division — `d / t`
// demands a non-zero divisor proof exactly like every other `/`.
//
// The 422 is Racket's: a zero divisor is a value the caller sent, not a broken server.
func UnitsRequireNonZero(quantity float64) Check[float64] {
	if quantity == 0 {
		return Reject[float64](422, "expected a non-zero quantity")
	}
	return Accept(quantity)
}
