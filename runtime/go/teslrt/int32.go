package teslrt

import "math/big"

// `Tesl.Int32` — a JS-safe, 32-bit-bounded integer for wire and storage boundaries.
//
// `Int32` is NOMINAL at the type level (it does not unify with `Int`) and at run time it IS its
// underlying integer — `tesl/int32.rkt` says exactly that, and the Go emitter follows by
// rendering the type as `teslrt.Int`. Nothing here carries a wrapper, so an Int32 crossing into
// `Int` arithmetic costs nothing and the two backends store the same value.
//
// The split that makes the type worth having: an operation that CANNOT leave [-2^31, 2^31)
// answers the value, and one that CAN answers a `Maybe`. That is a property of the operation,
// not of the inputs, so it is visible in the signature rather than discovered at run time.
var (
	int32Low  = FromInt64(-2147483648)
	int32High = FromInt64(2147483647)
)

// Int32InRange is the ONE range decision every operation below funnels through.
func Int32InRange(value Int) bool {
	return Compare(value, int32Low) >= 0 && Compare(value, int32High) <= 0
}

func int32Narrow(value Int) Maybe[Int] {
	if Int32InRange(value) {
		return Something(value)
	}
	return Nothing[Int]()
}

// Int32MinValue and Int32MaxValue are the bounds, as values rather than calls — that is how
// `Int32.minValue` reads in Tesl.
var (
	Int32MinValue = int32Low
	Int32MaxValue = int32High
)

// ── Conversions ──────────────────────────────────────────────────────────────

func Int32FromInt(value Int) Maybe[Int] { return int32Narrow(value) }

// Int32ToInt is total: widening always fits.
func Int32ToInt(value Int) Int { return value }

// Int32FromIntClamped saturates. Total, and explicit in the name that it CHANGES the value —
// use `Int32.fromInt` where out-of-range has to be visible.
func Int32FromIntClamped(value Int) Int {
	return Max(int32Low, Min(int32High, value))
}

func Int32Parse(text string) Maybe[Int] {
	parsed := StringToInt(text)
	if !parsed.IsSomething() {
		return Nothing[Int]()
	}
	return int32Narrow(parsed.SomethingValue)
}

// Int32FromFloat truncates toward zero, then range-checks. A NaN or an infinity has no integer
// truncation, so it is Nothing rather than a trap.
func Int32FromFloat(value float64) Maybe[Int] {
	truncated := FloatToInt(value)
	if !truncated.IsSomething() {
		return Nothing[Int]()
	}
	return int32Narrow(truncated.SomethingValue)
}

func Int32ToFloat(value Int) float64 { return value.Float64() }

func Int32ToString(value Int) string { return value.String() }

// ── Range-closed operations ──────────────────────────────────────────────────

func Int32Min(left, right Int) Int { return Min(left, right) }

func Int32Max(left, right Int) Int { return Max(left, right) }

func Int32Clamp(value, low, high Int) Int { return Max(low, Min(high, value)) }

// Int32Modulo is the remainder, which |b| ≤ 2^31 keeps in range. The divisor carries an
// `IsNonZero` proof, which erases — so the zero guard here is what is left of it, and it traps
// with the message `tesl/int32.rkt` raises.
func Int32Modulo(dividend, divisor Int) Int {
	if divisor.IsZero() {
		panic("Int32.modulo: division by zero — use `check Int32.nonZero(b)` before calling Int32.modulo")
	}
	return MustRem(dividend, divisor)
}

// ── Operations that can leave the range ──────────────────────────────────────

func Int32Add(left, right Int) Maybe[Int] { return int32Narrow(Add(left, right)) }

func Int32Subtract(left, right Int) Maybe[Int] { return int32Narrow(Sub(left, right)) }

func Int32Multiply(left, right Int) Maybe[Int] { return int32Narrow(Mul(left, right)) }

// Negate and Abs overflow on exactly one input: -2^31 has no positive counterpart.
func Int32Negate(value Int) Maybe[Int] { return int32Narrow(Neg(value)) }

func Int32Abs(value Int) Maybe[Int] { return int32Narrow(Abs(value)) }

// Int32Pow answers Nothing for a negative exponent (an integer power would be fractional) and
// for an out-of-range result. The exponent is bounded BEFORE the power is taken: 2^2000000000
// cannot fit either way, and computing that bignum first would burn memory to reach the same
// Nothing. |base| > 1 needs at most 31 doublings to leave the range; 0, 1 and -1 never do.
func Int32Pow(base, exponent Int) Maybe[Int] {
	if exponent.Sign() < 0 {
		return Nothing[Int]()
	}
	if Compare(Abs(base), FromInt64(1)) > 0 && Compare(exponent, FromInt64(31)) > 0 {
		return Nothing[Int]()
	}
	raised, err := Pow(base, exponent)
	if err != nil {
		return Nothing[Int]()
	}
	return int32Narrow(raised)
}

// Int32Divide is integer division truncating toward zero. The divisor carries an `IsNonZero`
// proof; Nothing covers the single overflowing quotient, -2^31 / -1 = 2^31.
func Int32Divide(dividend, divisor Int) Maybe[Int] {
	if divisor.IsZero() {
		panic("Int32.divide: division by zero — use `check Int32.nonZero(b)` before calling Int32.divide")
	}
	return int32Narrow(MustQuo(dividend, divisor))
}

// ── Predicates and queries ───────────────────────────────────────────────────

func Int32IsPositive(value Int) bool { return value.IsPositive() }

func Int32IsNegative(value Int) bool { return value.IsNegative() }

func Int32IsZero(value Int) bool { return value.IsZero() }

func Int32IsEven(value Int) bool { return value.IsEven() }

func Int32IsOdd(value Int) bool { return value.IsOdd() }

// Int32Sign answers an `Int` rather than an Int32, so it composes with Int arithmetic and
// compares against Int literals — the shape `Int.sign` has.
func Int32Sign(value Int) Int { return FromInt64(int64(value.Sign())) }

// Int32Digits counts the digits of the magnitude, so zero has one.
func Int32Digits(value Int) Int {
	return FromInt64(int64(len(new(big.Int).Abs(value.bigInt()).String())))
}

// ── Proof-minting checks ─────────────────────────────────────────────────────
//
// The proofs erase, so what is left is the predicate and its refusal.

func Int32NonZero(value Int) Check[Int] {
	if value.IsZero() {
		return Reject[Int](400, "expected a non-zero Int32")
	}
	return Accept(value)
}

func Int32NonNegative(value Int) Check[Int] {
	if value.IsNegative() {
		return Reject[Int](400, "expected a non-negative Int32")
	}
	return Accept(value)
}
