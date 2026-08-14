package teslrt

import "testing"

func TestPosixMillisConversions(t *testing.T) {
	if got := PosixToSeconds(PosixMillis{Value: FromInt64(1500)}); got.String() != "1" {
		t.Errorf("posixToSeconds(1500) = %s", got.String())
	}
	// Truncation is toward ZERO, matching Racket's quotient — not floor.
	if got := PosixToSeconds(PosixMillis{Value: FromInt64(-1500)}); got.String() != "-1" {
		t.Errorf("posixToSeconds(-1500) = %s", got.String())
	}
	if got := SecondsToPosix(FromInt64(7)); got.Value.String() != "7000" {
		t.Errorf("secondsToPosix(7) = %s", got.Value.String())
	}
	// An instant is an EXACT integer: a value far outside int64 survives.
	huge := MustParseDecimal("123456789012345678901234567890")
	if got := SecondsToPosix(huge); got.Value.String() != "123456789012345678901234567890000" {
		t.Errorf("secondsToPosix over int64 = %s", got.Value.String())
	}
}

func TestPosixMillisArithmetic(t *testing.T) {
	base := SecondsToPosix(FromInt64(10))
	if got := AddMs(base, FromInt64(250)); got.Value.String() != "10250" {
		t.Errorf("addMs = %s", got.Value.String())
	}
	if got := SubtractMs(base, FromInt64(250)); got.Value.String() != "9750" {
		t.Errorf("subtractMs = %s", got.Value.String())
	}
	// `diffMs a b` is b - a.
	if got := DiffMs(base, AddMs(base, FromInt64(40))); got.String() != "40" {
		t.Errorf("diffMs = %s", got.String())
	}
	if got := DiffMs(AddMs(base, FromInt64(40)), base); got.String() != "-40" {
		t.Errorf("diffMs backwards = %s", got.String())
	}
}

// A future instant has age ZERO rather than a negative one.
func TestDurationMsClampsAtZero(t *testing.T) {
	future := AddMs(NowMillis(), FromInt64(60_000))
	if got := DurationMs(future); got.String() != "0" {
		t.Errorf("durationMs of a future instant = %s", got.String())
	}
	past := SubtractMs(NowMillis(), FromInt64(5_000))
	if Compare(DurationMs(past), FromInt64(5_000)) < 0 {
		t.Errorf("durationMs of a past instant = %s", DurationMs(past).String())
	}
}
