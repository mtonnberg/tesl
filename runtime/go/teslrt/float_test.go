package teslrt

import (
	"math"
	"strconv"
	"testing"
)

// Rendering is Go's shortest-round-trip digits and layout, plus one deviation: a `.0`
// when the result has neither `.` nor `e`, so a Float is never mistaken for an Int.
// The rows marked DIVERGES are deliberate, decided departures from the Racket backend
// (verified against real Racket output), not accidents.
func TestFormatFloat(t *testing.T) {
	// Held in variables on purpose: Go folds UNTYPED constant arithmetic exactly, so a
	// literal `0.1 + 0.2` here would be 0.3 and would not exercise per-op rounding at
	// all. This is the same hazard that forces the emitter to emit typed float values
	// rather than bare literals.
	tenth, fifth := 0.1, 0.2
	for _, row := range []struct {
		value float64
		want  string
		note  string
	}{
		{0, "0.0", ""},
		{1, "1.0", ""},
		{-1, "-1.0", ""},
		{100, "100.0", ""},
		{0.5, "0.5", ""},
		{tenth + fifth, "0.30000000000000004", "per-op rounding, same as Racket"},
		{0.0001, "0.0001", ""},
		{1e21, "1e+21", ""},
		{math.Copysign(0, -1), "-0.0", "negative zero survives"},
		{1e7, "1e+07", "DIVERGES: Racket prints 10000000.0"},
		{1e-5, "1e-05", "DIVERGES: Racket prints 1e-5 (one-digit exponent)"},
		{math.NaN(), "NaN", "DIVERGES: Racket prints +nan.0"},
		{math.Inf(1), "+Inf", "DIVERGES: Racket prints +inf.0"},
		{math.Inf(-1), "-Inf", "DIVERGES: Racket prints -inf.0"},
		{1.0 / 3.0, "0.3333333333333333", ""},
	} {
		if got := FormatFloat(row.value); got != row.want {
			t.Errorf("FormatFloat(%v) = %q, want %q (%s)", row.value, got, row.want, row.note)
		}
	}
}

// Whatever the layout, the digits must round-trip: a renderer that loses precision
// would corrupt every Float that crosses a log or a response.
func TestFormatFloatRoundTrips(t *testing.T) {
	for _, value := range []float64{
		0, 1, -1, 0.1, 0.5, 1e7, 1e-5, 1e21, 1e-300, 1e300, math.Pi,
		math.SmallestNonzeroFloat64, math.MaxFloat64,
	} {
		text := FormatFloat(value)
		parsed, err := strconv.ParseFloat(text, 64)
		if err != nil {
			t.Errorf("FormatFloat(%v) = %q, which does not parse: %v", value, text, err)
			continue
		}
		if math.Float64bits(parsed) != math.Float64bits(value) {
			t.Errorf("FormatFloat(%v) = %q, which parses back as %v", value, text, parsed)
		}
	}
}

// Equality is Racket `equal?`, NOT IEEE `==`: reflexive for NaN, and the two zeros are
// distinct. Both are inverted from Go's `==`, and both are load-bearing — IEEE equality
// would cost a record or Dict key holding NaN its own reflexivity.
func TestFloatEqualIsStructuralNotIEEE(t *testing.T) {
	negativeZero := math.Copysign(0, -1)
	otherNaN := math.Float64frombits(math.Float64bits(math.NaN()) | 1)
	for _, row := range []struct {
		left, right float64
		want        bool
		note        string
	}{
		{math.NaN(), math.NaN(), true, "inverted from Go =="},
		{math.NaN(), otherNaN, true, "any NaN payload"},
		{math.NaN(), 1, false, ""},
		{0, negativeZero, false, "inverted from Go =="},
		{negativeZero, negativeZero, true, ""},
		{0, 0, true, ""},
		{1, 1, true, ""},
		{1, 2, false, ""},
		{math.Inf(1), math.Inf(1), true, ""},
		{math.Inf(1), math.Inf(-1), false, ""},
	} {
		if got := FloatEqual(row.left, row.right); got != row.want {
			t.Errorf("FloatEqual(%v, %v) = %v, want %v (%s)",
				row.left, row.right, got, row.want, row.note)
		}
	}
	// Ordering, unlike equality, IS plain IEEE in both backends and needs no helper —
	// the emitter emits `<`/`<=` directly.  `0.0 <= -0.0` holding is the observable
	// consequence worth pinning here; that every NaN comparison is false is Go's own
	// semantics rather than anything this file implements (and asserting it trips
	// staticcheck SA4012, correctly).
	if !(0.0 <= negativeZero) {
		t.Error("ordering should be IEEE: 0.0 <= -0.0")
	}
}

// Racket's `round` on a flonum rounds HALF TO EVEN; math.Round would round half away
// from zero and disagree on every exact .5. Verified against Racket: 2.5 -> 2, 3.5 -> 4,
// -2.5 -> -2.
func TestFloatRoundIsHalfToEven(t *testing.T) {
	for _, row := range []struct {
		value float64
		want  int64
	}{
		{2.5, 2}, {3.5, 4}, {-2.5, -2}, {-3.5, -4}, {2.4, 2}, {2.6, 3}, {0, 0},
	} {
		if got := FloatRound(row.value); !Equal(got, FromInt64(row.want)) {
			t.Errorf("FloatRound(%v) = %s, want %d", row.value, got.String(), row.want)
		}
	}
	if got := FloatFloor(-2.5); !Equal(got, FromInt64(-3)) {
		t.Errorf("FloatFloor(-2.5) = %s, want -3", got.String())
	}
	if got := FloatCeil(-2.5); !Equal(got, FromInt64(-2)) {
		t.Errorf("FloatCeil(-2.5) = %s, want -2", got.String())
	}
	// Beyond int64 the result must stay exact rather than saturate.
	if got := FloatFloor(1e30); got.String() != "1000000000000000019884624838656" {
		t.Errorf("FloatFloor(1e30) = %s", got.String())
	}
}

// Racket raises on `inexact->exact` of a non-finite value, and the declared Tesl
// signature is `Float -> Int`, so these panic rather than widening the type.
func TestFloatToIntegerRejectsNonFinite(t *testing.T) {
	for name, call := range map[string]func(){
		"round": func() { FloatRound(math.NaN()) },
		"floor": func() { FloatFloor(math.Inf(1)) },
		"ceil":  func() { FloatCeil(math.Inf(-1)) },
	} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("%s of a non-finite value did not panic", name)
				}
			}()
			call()
		}()
	}
	// FloatToInt, whose signature IS a Maybe, refuses them without panicking.
	if _, ok := FloatToInt(math.NaN()).Value(); ok {
		t.Error("FloatToInt(NaN) yielded a value")
	}
	value, ok := FloatToInt(3.7).Value()
	if !ok || !Equal(value, FromInt64(3)) {
		t.Errorf("FloatToInt(3.7) = %s, %v (want 3, truncating)", value.String(), ok)
	}
	if value, _ := FloatToInt(-3.7).Value(); !Equal(value, FromInt64(-3)) {
		t.Errorf("FloatToInt(-3.7) = %s, want -3", value.String())
	}
}

func TestFloatArithmeticHelpers(t *testing.T) {
	if FloatAbs(-2.5) != 2.5 || FloatAbs(math.Copysign(0, -1)) != 0 {
		t.Error("FloatAbs")
	}
	if FloatMin(1, 2) != 1 || FloatMax(1, 2) != 2 {
		t.Error("FloatMin/FloatMax")
	}
	// Racket's min/max propagate NaN; Go's builtin min/max do too, but math.Min/Max are
	// what this uses, so pin it.
	if !math.IsNaN(FloatMin(math.NaN(), 1)) || !math.IsNaN(FloatMax(math.NaN(), 1)) {
		t.Error("min/max should propagate NaN")
	}
	if FloatClamp(5, 0, 1) != 1 || FloatClamp(-5, 0, 1) != 0 || FloatClamp(0.5, 0, 1) != 0.5 {
		t.Error("FloatClamp")
	}
	// sqrt is the one transcendental that is bit-identical to Racket's. Racket returns a
	// COMPLEX number for a negative input (verified: (sqrt -1.0) is 0.0+1.0i), which
	// Tesl's Float type cannot hold; NaN is the defensible answer here.
	if FloatSqrt(4) != 2 || !math.IsNaN(FloatSqrt(-1)) {
		t.Error("FloatSqrt")
	}
}

func TestFloatParseAndRequireNonZero(t *testing.T) {
	value, ok := ParseFloat("1.5").Value()
	if !ok || value != 1.5 {
		t.Errorf("ParseFloat(1.5) = %v, %v", value, ok)
	}
	for _, text := range []string{"", " 1.5", "1.5 ", "abc", "1/2"} {
		if _, ok := ParseFloat(text).Value(); ok {
			t.Errorf("ParseFloat(%q) accepted", text)
		}
	}
	if !FloatRequireNonZero(1).OK() {
		t.Error("non-zero rejected")
	}
	// Negative zero is zero.
	for _, zero := range []float64{0, math.Copysign(0, -1)} {
		rejected := FloatRequireNonZero(zero)
		if rejected.OK() {
			t.Errorf("zero %v accepted", zero)
		}
		if rejected.Status() != 400 || rejected.Message() != "expected a non-zero float" {
			t.Errorf("rejection = %d %q", rejected.Status(), rejected.Message())
		}
	}
}
