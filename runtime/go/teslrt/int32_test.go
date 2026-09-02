package teslrt

import (
	"math"
	"testing"
)

// Every expectation here was read off `tesl/int32.rkt` rather than derived from the Go code:
// the whole point of Int32 is the range boundary, and a boundary that differs by one between
// the backends is exactly the kind of difference a wire format hides until production.

func i32(value int64) Int { return FromInt64(value) }

func mustSomething(t *testing.T, label string, answer Maybe[Int]) Int {
	t.Helper()
	if !answer.IsSomething() {
		t.Fatalf("%s answered Nothing", label)
	}
	return answer.SomethingValue
}

func mustNothing(t *testing.T, label string, answer Maybe[Int]) {
	t.Helper()
	if answer.IsSomething() {
		t.Fatalf("%s answered %s, want Nothing", label, answer.SomethingValue.String())
	}
}

func TestInt32Bounds(t *testing.T) {
	if !Equal(Int32MinValue, i32(-2147483648)) || !Equal(Int32MaxValue, i32(2147483647)) {
		t.Fatalf("the bounds are %s..%s", Int32MinValue.String(), Int32MaxValue.String())
	}
	// The boundary is inclusive at both ends, which is where an off-by-one would live.
	mustSomething(t, "fromInt min", Int32FromInt(i32(-2147483648)))
	mustSomething(t, "fromInt max", Int32FromInt(i32(2147483647)))
	mustNothing(t, "fromInt max+1", Int32FromInt(i32(2147483648)))
	mustNothing(t, "fromInt min-1", Int32FromInt(i32(-2147483649)))
}

func TestInt32Conversions(t *testing.T) {
	if got := Int32FromIntClamped(MustParseDecimal("99999999999")); !Equal(got, Int32MaxValue) {
		t.Fatalf("clamped high to %s", got.String())
	}
	if got := Int32FromIntClamped(MustParseDecimal("-99999999999")); !Equal(got, Int32MinValue) {
		t.Fatalf("clamped low to %s", got.String())
	}
	if got := mustSomething(t, "parse 42", Int32Parse("42")); !Equal(got, i32(42)) {
		t.Fatalf("parse gave %s", got.String())
	}
	// Out of range and not a number are the same answer: Nothing.
	mustNothing(t, "parse 99999999999", Int32Parse("99999999999"))
	mustNothing(t, "parse x", Int32Parse("x"))
	// Truncation is toward ZERO, so -3.9 is -3 rather than -4.
	if got := mustSomething(t, "fromFloat 3.9", Int32FromFloat(3.9)); !Equal(got, i32(3)) {
		t.Fatalf("3.9 truncated to %s", got.String())
	}
	if got := mustSomething(t, "fromFloat -3.9", Int32FromFloat(-3.9)); !Equal(got, i32(-3)) {
		t.Fatalf("-3.9 truncated to %s", got.String())
	}
	mustNothing(t, "fromFloat +Inf", Int32FromFloat(math.Inf(1)))
	mustNothing(t, "fromFloat NaN", Int32FromFloat(math.NaN()))
	if got := Int32ToFloat(i32(7)); got != 7.0 {
		t.Fatalf("toFloat gave %v", got)
	}
	if got := Int32ToString(i32(-5)); got != "-5" {
		t.Fatalf("toString gave %q", got)
	}
}

// The three operations that overflow on exactly one input, and the one that overflows on
// exactly one PAIR of inputs.
func TestInt32OverflowEdges(t *testing.T) {
	mustNothing(t, "negate min", Int32Negate(Int32MinValue))
	mustNothing(t, "abs min", Int32Abs(Int32MinValue))
	if got := mustSomething(t, "negate max", Int32Negate(Int32MaxValue)); !Equal(got, i32(-2147483647)) {
		t.Fatalf("negate max gave %s", got.String())
	}
	// -2^31 / -1 is 2^31, the single quotient that leaves the range.
	mustNothing(t, "min / -1", Int32Divide(Int32MinValue, i32(-1)))
	if got := mustSomething(t, "7 / 2", Int32Divide(i32(7), i32(2))); !Equal(got, i32(3)) {
		t.Fatalf("7/2 gave %s", got.String())
	}
	// Division truncates toward zero, so -7/2 is -3 rather than -4.
	if got := mustSomething(t, "-7 / 2", Int32Divide(i32(-7), i32(2))); !Equal(got, i32(-3)) {
		t.Fatalf("-7/2 gave %s", got.String())
	}
	mustSomething(t, "max + 0", Int32Add(Int32MaxValue, i32(0)))
	mustNothing(t, "max + 1", Int32Add(Int32MaxValue, i32(1)))
	mustNothing(t, "min - 1", Int32Subtract(Int32MinValue, i32(1)))
	mustNothing(t, "65536 * 65536", Int32Multiply(i32(65536), i32(65536)))
}

// The exponent is bounded BEFORE the power is taken, so a huge exponent is Nothing rather than
// a bignum the size of memory — but 0, 1 and -1 never leave the range, so they answer.
func TestInt32Pow(t *testing.T) {
	if got := mustSomething(t, "2^10", Int32Pow(i32(2), i32(10))); !Equal(got, i32(1024)) {
		t.Fatalf("2^10 gave %s", got.String())
	}
	mustNothing(t, "2^31", Int32Pow(i32(2), i32(31)))
	if got := mustSomething(t, "2^30", Int32Pow(i32(2), i32(30))); !Equal(got, i32(1073741824)) {
		t.Fatalf("2^30 gave %s", got.String())
	}
	mustNothing(t, "2^-1", Int32Pow(i32(2), i32(-1)))
	if got := mustSomething(t, "1^2000000000", Int32Pow(i32(1), i32(2000000000))); !Equal(got, i32(1)) {
		t.Fatalf("1^huge gave %s", got.String())
	}
	if got := mustSomething(t, "0^0", Int32Pow(i32(0), i32(0))); !Equal(got, i32(1)) {
		t.Fatalf("0^0 gave %s", got.String())
	}
}

func TestInt32ClosedOperations(t *testing.T) {
	if got := Int32Clamp(i32(50), i32(0), i32(10)); !Equal(got, i32(10)) {
		t.Fatalf("clamp gave %s", got.String())
	}
	// The remainder keeps the DIVIDEND's sign, as `remainder` does.
	if got := Int32Modulo(i32(-7), i32(3)); !Equal(got, i32(-1)) {
		t.Fatalf("-7 mod 3 gave %s", got.String())
	}
	if got := Int32Digits(i32(0)); !Equal(got, i32(1)) {
		t.Fatalf("digits 0 gave %s", got.String())
	}
	if got := Int32Digits(i32(-1234)); !Equal(got, i32(4)) {
		t.Fatalf("digits -1234 gave %s", got.String())
	}
	if got := Int32Sign(i32(-3)); !Equal(got, i32(-1)) {
		t.Fatalf("sign gave %s", got.String())
	}
}

// The divisor's `IsNonZero` proof ERASES, so the zero guard is what is left of it — and a
// program that reached it bypassed the check.
func TestInt32DivisionByZeroTraps(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("dividing by zero answered instead of trapping")
		}
	}()
	Int32Divide(i32(1), i32(0))
}

func TestInt32Checks(t *testing.T) {
	if Int32NonZero(i32(0)).OK() {
		t.Fatal("zero passed nonZero")
	}
	if got := Int32NonZero(i32(0)); got.Status() != 400 || got.Message() != "expected a non-zero Int32" {
		t.Fatalf("the refusal is %d %q", got.Status(), got.Message())
	}
	if !Int32NonZero(i32(-1)).OK() {
		t.Fatal("a negative value was refused as zero")
	}
	if Int32NonNegative(i32(-1)).OK() {
		t.Fatal("a negative value passed nonNegative")
	}
	if !Int32NonNegative(i32(0)).OK() {
		t.Fatal("zero was refused as negative")
	}
}
