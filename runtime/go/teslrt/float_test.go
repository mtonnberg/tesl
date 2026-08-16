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

// The Float KEY comparator. Dict and Set derive key equivalence from the comparator, so
// these are lookup-correctness tests, not ordering-taste tests.
func floatKeyCorpus() []float64 {
	return []float64{
		math.NaN(),
		-math.NaN(),
		math.Float64frombits(0x7FF8000000000001), // a NaN with a different payload
		math.Float64frombits(0xFFF8000000000001), // negative sign, different payload
		math.Inf(-1), -math.MaxFloat64, -1e308, -1.5, -1, -math.SmallestNonzeroFloat64,
		math.Copysign(0, -1), 0, math.SmallestNonzeroFloat64, 1, 1.5, 1e308,
		math.MaxFloat64, math.Inf(1),
	}
}

// The defining law: the comparator's equivalence classes must be exactly FloatEqual's.
func TestFloatKeyLessMatchesFloatEqual(t *testing.T) {
	corpus := floatKeyCorpus()
	for _, left := range corpus {
		for _, right := range corpus {
			equivalent := !FloatKeyLess(left, right) && !FloatKeyLess(right, left)
			if equivalent != FloatEqual(left, right) {
				t.Errorf("FloatKeyLess equivalence for (%v, %v) = %v, FloatEqual = %v",
					left, right, equivalent, FloatEqual(left, right))
			}
		}
	}
}

func TestFloatKeyLessIsStrictWeakOrder(t *testing.T) {
	corpus := floatKeyCorpus()
	for _, value := range corpus {
		if FloatKeyLess(value, value) {
			t.Errorf("FloatKeyLess(%v, %v) must be false (irreflexive)", value, value)
		}
	}
	for _, left := range corpus {
		for _, right := range corpus {
			if FloatKeyLess(left, right) && FloatKeyLess(right, left) {
				t.Errorf("FloatKeyLess is not asymmetric at (%v, %v)", left, right)
			}
		}
	}
	// Transitivity of both `less` and of the induced equivalence.
	for _, a := range corpus {
		for _, b := range corpus {
			for _, c := range corpus {
				if FloatKeyLess(a, b) && FloatKeyLess(b, c) && !FloatKeyLess(a, c) {
					t.Errorf("FloatKeyLess is not transitive at (%v, %v, %v)", a, b, c)
				}
				equal := func(x, y float64) bool { return !FloatKeyLess(x, y) && !FloatKeyLess(y, x) }
				if equal(a, b) && equal(b, c) && !equal(a, c) {
					t.Errorf("key equivalence is not transitive at (%v, %v, %v)", a, b, c)
				}
			}
		}
	}
}

func TestFloatKeyLessSignedZeroAndNaNPlacement(t *testing.T) {
	negZero := math.Copysign(0, -1)
	if !FloatKeyLess(negZero, 0) {
		t.Error("-0.0 must sort before +0.0, since FloatEqual distinguishes them")
	}
	if FloatKeyLess(0, negZero) {
		t.Error("+0.0 must not sort before -0.0")
	}
	// All NaNs are one class, and it sits before every number.
	for _, number := range []float64{math.Inf(-1), -1, negZero, 0, 1, math.Inf(1)} {
		if !FloatKeyLess(math.NaN(), number) {
			t.Errorf("the NaN class must sort before %v", number)
		}
		if FloatKeyLess(number, math.NaN()) {
			t.Errorf("%v must not sort before the NaN class", number)
		}
	}
	if FloatKeyLess(math.NaN(), -math.NaN()) || FloatKeyLess(-math.NaN(), math.NaN()) {
		t.Error("all NaNs are one key-equivalence class")
	}
}

// The bugs that motivated the comparator, as Set/Dict operations.
func TestFloatKeyedCollectionsUseTheKeyComparator(t *testing.T) {
	nan, negZero := math.NaN(), math.Copysign(0, -1)
	set := SetFromList([]float64{1, 2, 3}, FloatKeyLess)
	if SetMember(nan, set, FloatKeyLess) {
		t.Error("NaN must not be a member of {1,2,3}")
	}
	withNaN := SetInsert(nan, set, FloatKeyLess)
	if got := SetSize(withNaN).String(); got != "4" {
		t.Errorf("inserting NaN gave size %s, want 4", got)
	}
	if !SetMember(nan, withNaN, FloatKeyLess) {
		t.Error("NaN must be found once inserted")
	}
	// Idempotent: NaN is one key.
	if got := SetSize(SetInsert(-nan, withNaN, FloatKeyLess)).String(); got != "4" {
		t.Errorf("re-inserting a differently-signed NaN gave size %s, want 4", got)
	}
	zeros := SetInsert(0, SetSingleton(negZero), FloatKeyLess)
	if got := SetSize(zeros).String(); got != "2" {
		t.Errorf("-0.0 and +0.0 are distinct keys (FloatEqual says so), got size %s", got)
	}
	// Set algebra over the same values.
	left := SetFromList([]float64{nan, negZero, 1}, FloatKeyLess)
	right := SetFromList([]float64{nan, 0, 1}, FloatKeyLess)
	if got := SetSize(SetIntersection(left, right, FloatKeyLess)).String(); got != "2" {
		t.Errorf("intersection should keep NaN and 1, got size %s", got)
	}
	if got := SetSize(SetUnion(left, right, FloatKeyLess)).String(); got != "4" {
		t.Errorf("union should hold NaN, -0.0, +0.0 and 1, got size %s", got)
	}
	if got := SetSize(SetDifference(left, right, FloatKeyLess)).String(); got != "1" {
		t.Errorf("difference should keep only -0.0, got size %s", got)
	}
	if !SetIsSubset(SetSingleton(nan), left, FloatKeyLess) {
		t.Error("a NaN singleton is a subset of a set containing NaN")
	}
	// Dict lookup and replacement.
	dict := DictInsert(DictEmpty[float64, string](), nan, "nan", FloatKeyLess)
	dict = DictInsert(dict, negZero, "neg", FloatKeyLess)
	dict = DictInsert(dict, 0, "pos", FloatKeyLess)
	if got := DictSize(dict).String(); got != "3" {
		t.Errorf("NaN, -0.0 and +0.0 are three keys, got size %s", got)
	}
	for _, probe := range []struct {
		key  float64
		want string
	}{{nan, "nan"}, {negZero, "neg"}, {0, "pos"}} {
		switch found := DictLookup(dict, probe.key, FloatKeyLess); found.Tag {
		case MaybeSomething:
			if found.SomethingValue != probe.want {
				t.Errorf("lookup %v = %q, want %q", probe.key, found.SomethingValue, probe.want)
			}
		case MaybeNothing:
			t.Errorf("lookup %v found nothing, want %q", probe.key, probe.want)
		}
	}
	replaced := DictInsert(dict, -nan, "again", FloatKeyLess)
	if got := DictSize(replaced).String(); got != "3" {
		t.Errorf("re-inserting a NaN key must replace, got size %s", got)
	}
}

// Float.pow is the one transcendental in the surface, and the interesting half of it is where
// there is no REAL result: Racket's `expt` answers a complex number there (a bug this port
// found and fixed) and C's `pow` answers 1 or +Inf for two "even infinity" cases. Both are NaN
// here, and every expectation below was read off the fixed Racket runtime.
func TestFloatPowMatchesRacket(t *testing.T) {
	for _, want := range []struct {
		base     float64
		exponent float64
		expected float64
	}{
		{2, 10, 1024},
		{2, 0.5, 1.4142135623730951},
		{0, 0, 1},
		{-2, 3, -8},
		{-1, -3, -1},
		{-1, 1e300, 1}, // 1e300 IS an integer float, so the result is real
		{0, -1, math.Inf(1)},
		{math.Copysign(0, -1), -3, math.Inf(-1)},
		{1e308, 2, math.Inf(1)},
		{math.Copysign(0, -1), 0.5, 0}, // -0.0 is not negative, so this one has a real result
	} {
		if got := FloatPow(want.base, want.exponent); got != want.expected {
			t.Fatalf("%v ^ %v = %v, Racket says %v", want.base, want.exponent, got, want.expected)
		}
	}
	// No real result: a negative base with a non-integer exponent, ±Inf and NaN included.
	for _, want := range [][2]float64{
		{-8, 1.0 / 3.0}, {-2, 2.5}, {-1, math.Inf(1)}, {-1, math.Inf(-1)},
		{-4, math.Inf(1)}, {-1, math.NaN()},
	} {
		if got := FloatPow(want[0], want[1]); !math.IsNaN(got) {
			t.Fatalf("%v ^ %v = %v, want NaN", want[0], want[1], got)
		}
	}
	// A NaN base is not negative, so the ordinary rules apply.
	if got := FloatPow(math.NaN(), 0); got != 1 {
		t.Fatalf("NaN ^ 0 = %v, Racket says 1.0", got)
	}
}

// ── The transcendentals ──────────────────────────────────────────────────────

// Go's math.Log answers -709.0895657128241 for EVERY subnormal input, which is both
// indistinguishable and wrong. The expected values here were read off the Racket runtime
// (`(log 5e-324)` and `(log 2.5e-323)`), so this pins the agreement rather than the wrapper.
func TestFloatLogDistinguishesSubnormals(t *testing.T) {
	cases := []struct {
		input float64
		want  float64
	}{
		{5e-324, -744.4400719213812},
		{2.5e-323, -742.8306340089471},
	}
	for _, testCase := range cases {
		if got := FloatLog(testCase.input); got != testCase.want {
			t.Fatalf("FloatLog(%v) = %v, want %v", testCase.input, got, testCase.want)
		}
	}
	// The bug this guards against is not "slightly off" but "the same for both".
	if FloatLog(5e-324) == FloatLog(2.5e-323) {
		t.Fatal("two different subnormals answered the same logarithm")
	}
}

// Everything at or above the smallest normal forwards unchanged, so the wrapper must not
// perturb the ordinary range.
func TestFloatLogForwardsOutsideTheSubnormalRange(t *testing.T) {
	for _, input := range []float64{
		smallestNormalFloat, 1e-300, 0.5, 1.0, 2.718281828459045, 1e300,
	} {
		if got, want := FloatLog(input), math.Log(input); got != want {
			t.Fatalf("FloatLog(%v) = %v, want the unwrapped %v", input, got, want)
		}
	}
}

// Zero and negatives have no logarithm; both backends say so with -Inf and NaN.
func TestFloatLogOfZeroAndNegatives(t *testing.T) {
	if got := FloatLog(0); !math.IsInf(got, -1) {
		t.Fatalf("FloatLog(0) = %v, want -Inf", got)
	}
	if got := FloatLog(-1); !math.IsNaN(got) {
		t.Fatalf("FloatLog(-1) = %v, want NaN", got)
	}
}

// The exact points, which are the ones both backends agree on to the bit. Everything else
// may differ by up to an ulp and is recorded as a known divergence rather than pinned.
func TestTranscendentalsAtTheirExactPoints(t *testing.T) {
	if got := FloatSin(0); got != 0 {
		t.Fatalf("FloatSin(0) = %v", got)
	}
	if got := FloatCos(0); got != 1 {
		t.Fatalf("FloatCos(0) = %v", got)
	}
	if got := FloatTan(0); got != 0 {
		t.Fatalf("FloatTan(0) = %v", got)
	}
	if got := FloatExp(0); got != 1 {
		t.Fatalf("FloatExp(0) = %v", got)
	}
}

func TestTranscendentalsPropagateNaN(t *testing.T) {
	for name, answer := range map[string]float64{
		"sin": FloatSin(math.NaN()),
		"cos": FloatCos(math.NaN()),
		"tan": FloatTan(math.NaN()),
		"exp": FloatExp(math.NaN()),
		"log": FloatLog(math.NaN()),
	} {
		if !math.IsNaN(answer) {
			t.Fatalf("%s(NaN) = %v, want NaN", name, answer)
		}
	}
}
