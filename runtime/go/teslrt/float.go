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
