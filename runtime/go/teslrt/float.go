package teslrt

import (
	"math"
	"strconv"
)

// Tesl's Float is Go's float64. Two things about it are NOT the Go default, and both
// are decided in roadmap/next/migrate_to_golang.md ("Float decisions"):
//
//   - Rendering adopts Go's shortest-round-trip digits and layout, plus one deviation:
//     a `.0` is appended when the result carries neither `.` nor `e`. Tesl has both
//     arbitrary-precision Int and Float, so a bare `1` would make the two
//     indistinguishable in logs, interpolation, and test expectations.
//   - Equality is STRUCTURAL, not IEEE: NaN equals NaN and 0.0 does not equal -0.0,
//     matching Racket's `equal?`. IEEE `==` is not an equivalence relation, which
//     would cost a record or Dict key holding NaN its own reflexivity. Postgres
//     independently agrees that NaN = NaN.
//
// Ordering, by contrast, IS plain IEEE in both backends, so it needs no helper here.
func FormatFloat(value float64) string {
	switch {
	case math.IsNaN(value):
		return "NaN"
	case math.IsInf(value, 1):
		return "+Inf"
	case math.IsInf(value, -1):
		return "-Inf"
	}
	rendered := strconv.FormatFloat(value, 'g', -1, 64)
	for index := 0; index < len(rendered); index++ {
		if rendered[index] == '.' || rendered[index] == 'e' {
			return rendered
		}
	}
	return rendered + ".0"
}

// FloatEqual is Racket `equal?` on flonums: reflexive for NaN, and distinguishing the
// two zeros. Both differ from Go's `==`.
func FloatEqual(left, right float64) bool {
	if math.IsNaN(left) || math.IsNaN(right) {
		return math.IsNaN(left) && math.IsNaN(right)
	}
	if left == 0 && right == 0 {
		return math.Signbit(left) == math.Signbit(right)
	}
	return left == right
}

// FloatKeyLess is the ordering Dict and Set use for Float KEYS, and it is deliberately
// NOT the IEEE ordering that user-visible comparisons and List.sort use.
//
// Dict and Set are sorted, so their binary search derives key equivalence from the
// comparator: "neither side is less" means "same key". Native `<` breaks that in two
// ways, and both are real lookup bugs rather than output-order quirks:
//
//   - Every comparison involving NaN is false, so a NaN key looks equivalent to whatever
//     value the search happens to probe. `SetMember(NaN, {1,2,3})` returned TRUE with the
//     native comparator, and inserting NaN was a no-op.
//   - Native ordering treats -0.0 and +0.0 as equal, while FloatEqual deliberately
//     distinguishes them, so the two collapsed into one key.
//
// The law this function must satisfy, and which float_test.go checks exhaustively:
//
//	FloatEqual(a, b)  ==  !FloatKeyLess(a, b) && !FloatKeyLess(b, a)
//
// All NaNs form ONE key-equivalence class (matching FloatEqual) and sort before every
// number; -0.0 sorts immediately before +0.0. Where the NaN class sits is internal and is
// not Tesl language semantics — only the equivalence classes are.
func FloatKeyLess(left, right float64) bool {
	leftIsNaN, rightIsNaN := math.IsNaN(left), math.IsNaN(right)
	if leftIsNaN || rightIsNaN {
		return leftIsNaN && !rightIsNaN
	}
	if left == right {
		// Only -0.0 and +0.0 reach here as distinct values.
		return math.Signbit(left) && !math.Signbit(right)
	}
	return left < right
}

// ParseFloat accepts what Tesl's `Float.parse` accepts: a decimal float, with no
// leading or trailing space and no Racket reader syntax.
func ParseFloat(text string) Maybe[float64] {
	value, err := strconv.ParseFloat(text, 64)
	if err != nil {
		return Nothing[float64]()
	}
	return Something(value)
}

func FloatAbs(value float64) float64 {
	return math.Abs(value)
}

// FloatMin and FloatMax propagate NaN and distinguish the zeros, matching Racket's
// `min`/`max` on flonums rather than Go's built-in min/max.
func FloatMin(left, right float64) float64 {
	return math.Min(left, right)
}

func FloatMax(left, right float64) float64 {
	return math.Max(left, right)
}

// FloatFloor, FloatCeil, and FloatRound return an INT, not a Float: tesl/float.rkt
// wraps each in `inexact->exact`, and their declared Tesl signatures are
// `Float -> Int`. FloatRound rounds HALF TO EVEN, because that is what Racket's
// `round` does on a flonum — `math.Round` would round half away from zero and disagree
// on every exact .5.
//
// NaN and infinity have no integer value. Racket RAISES there (`inexact->exact` has no
// exact representation for them) and the declared Tesl signature is `Float -> Int`
// rather than `-> Maybe Int`, so these panic rather than inventing a value or widening
// the type.
func FloatFloor(value float64) Int {
	return mustExactInt("Float.floor", math.Floor(value))
}

func FloatCeil(value float64) Int {
	return mustExactInt("Float.ceil", math.Ceil(value))
}

func FloatRound(value float64) Int {
	return mustExactInt("Float.round", math.RoundToEven(value))
}

func mustExactInt(who string, value float64) Int {
	converted, err := FromFloat64(value)
	if err != nil {
		panic(who + ": no exact integer for NaN or infinity")
	}
	return converted
}

func FloatClamp(value, low, high float64) float64 {
	return math.Max(low, math.Min(high, value))
}

// FloatSqrt is bit-identical to Racket's, since both defer to the IEEE-exact
// operation. The other transcendentals are NOT: they are rejected in the emitter
// rather than emitted divergent.
func FloatSqrt(value float64) float64 {
	return math.Sqrt(value)
}

// FloatPow answers NaN wherever the result has no REAL value, which is every negative base with
// a non-integer exponent. Racket's `expt` returns a COMPLEX number there — a value no Tesl Float
// can hold, and a bug this port found in `tesl/float.rkt` (fixed to answer NaN as well).
//
// The guard is not decoration: C's `pow`, which `math.Pow` follows, makes two deliberate
// exceptions — `pow(-1, ±Inf)` is 1 and `pow(-4, +Inf)` is +Inf — on the grounds that ±Inf is
// "even". A Tesl Float is a real number and (-1)^∞ has no real value, so those answer NaN here
// too, and the two backends agree at every input rather than at most of them.
func FloatPow(base, exponent float64) float64 {
	nonInteger := math.IsInf(exponent, 0) || math.IsNaN(exponent) ||
		exponent != math.Trunc(exponent)
	if base < 0 && nonInteger {
		return math.NaN()
	}
	return math.Pow(base, exponent)
}

// FloatFromInt is exact up to 2^53 and rounds beyond it, like Racket's exact->inexact.
func FloatFromInt(value Int) float64 {
	return value.Float64()
}

// FloatToInt truncates toward zero. NaN and infinity are not integers, so this
// mirrors Int.fromFloat by refusing them.
func FloatToInt(value float64) Maybe[Int] {
	converted, err := FromFloat64(value)
	if err != nil {
		return Nothing[Int]()
	}
	return Something(converted)
}

// FloatRequireNonZero is Tesl's `Float.requireNonZero` check: the proof erases, the
// rejection does not. Negative zero is zero.
func FloatRequireNonZero(value float64) Check[float64] {
	if value == 0 {
		return Reject[float64](400, "expected a non-zero float")
	}
	return Accept(value)
}

// FloatToIntTruncating is Tesl's `Float.toInt`, whose declared signature is
// `Float -> Int`: it truncates toward zero and panics on NaN or infinity, exactly where
// Racket's `inexact->exact` raises. FloatToInt above is the Maybe-returning form used
// by hand-written runtime code.
func FloatToIntTruncating(value float64) Int {
	return mustExactInt("Float.toInt", math.Trunc(value))
}

// FloatRequireNonNegative is Tesl's `Float.requireNonNegative`, the check that
// discharges `Float.sqrt`'s FloatNonNegative obligation. Zero is accepted: sqrt(0) is
// 0, so requiring strict positivity would reject a well-defined call.
func FloatRequireNonNegative(value float64) Check[float64] {
	if math.IsNaN(value) || value < 0 {
		return Reject[float64](422, "expected a non-negative float")
	}
	return Accept(value)
}

// The Float ARITHMETIC surface (`Float.add` and friends), for code that prefers named
// operations to operators. Plain IEEE arithmetic — the same thing `a + b` emits.
func FloatAdd(left, right float64) float64 { return left + right }

func FloatSub(left, right float64) float64 { return left - right }

func FloatMul(left, right float64) float64 { return left * right }

// FloatDiv's divisor carries a `FloatNonZero` proof, which erases; division by zero would
// otherwise be ±Inf, which is what Racket's `/` on a flonum gives too. No guard is added
// here: adding one would make the emitted program behave differently from `a / b`, and the
// proof is the enforcement.
func FloatDiv(left, right float64) float64 { return left / right }

// The predicates. NaN is its own case in every one of them: `Float.isNaN x` is the only way to
// ask, because every comparison with NaN is false — which is exactly why `isPositive`,
// `isNegative` and `isZero` all answer false for it rather than one of them accidentally
// answering true.
func FloatIsNaN(value float64) bool { return math.IsNaN(value) }

func FloatIsInfinite(value float64) bool { return math.IsInf(value, 0) }

func FloatIsPositive(value float64) bool { return value > 0 }

func FloatIsNegative(value float64) bool { return value < 0 }

func FloatIsZero(value float64) bool { return value == 0 }

// FloatSign answers a FLOAT (1.0, -1.0, 0.0), not an Int: it composes with float arithmetic,
// which is what a sign is used for. NaN has no sign, and answering 0.0 for it would claim it is
// zero — so it answers NaN, which propagates the way every other NaN operation does.
func FloatSign(value float64) float64 {
	switch {
	case math.IsNaN(value):
		return value
	case value > 0:
		return 1.0
	case value < 0:
		return -1.0
	default:
		return 0.0
	}
}

// FloatInfinity and FloatNaN are the two named constants. They are functions rather than package
// variables so nothing can assign to them.
func FloatInfinity() float64 { return math.Inf(1) }

func FloatNaN() float64 { return math.NaN() }

// ── The transcendentals ──────────────────────────────────────────────────────
//
// These forward to Go's `math`, and they DIVERGE from the Racket runtime: sin, cos and tan
// differ on 22 %, 22 % and 34 % of inputs respectively (up to 9,214 ulps near a zero of the
// function), and exp on 0.09 %. That divergence rate says the two implementations differ,
// not which is right — ulp-of-result exaggerates a small absolute error near a zero — and
// deciding needs a correctly-rounded reference rather than a diff against Racket. The
// maintainer's call (2026-08-12) is to use Go's and record the divergence, not to block on
// it, so a program that computes a sine gets an answer here instead of a refusal.
//
// FloatLog is the one that does NOT forward, because Go's math.Log is wrong rather than
// merely different; see its own note.

func FloatSin(value float64) float64 { return math.Sin(value) }

func FloatCos(value float64) float64 { return math.Cos(value) }

func FloatTan(value float64) float64 { return math.Tan(value) }

func FloatExp(value float64) float64 { return math.Exp(value) }

// FloatLog wraps math.Log rather than forwarding to it. Go's returns
// -709.0895657128241 for EVERY subnormal input — Log(5e-324) and Log(2.5e-323) give the
// same answer, and both are wrong (the true values are about -744.44 and -742.83). Scaling
// a subnormal into the normal range and subtracting the scale back out reproduces both
// exactly. Everything else forwards unchanged.
func FloatLog(value float64) float64 {
	if value > 0 && value < smallestNormalFloat {
		return math.Log(value*subnormalLogScale) - subnormalLogShift
	}
	return math.Log(value)
}

const (
	// The smallest positive NORMAL float64: below this the mantissa loses bits, which is
	// exactly where math.Log stops distinguishing inputs.
	smallestNormalFloat = 2.2250738585072014e-308
	// 2^100, and 100·ln2 — the scale up and the amount to take back off.
	subnormalLogScale = 1267650600228229401496703205376.0
	subnormalLogShift = 69.31471805599453
)
