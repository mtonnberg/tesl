package teslrt

import (
	"math/big"
	"time"
)

// PosixMillis is Tesl's canonical instant: milliseconds since the Unix epoch, UTC.
//
// It is a NEWTYPE over the exact integer, not an int64 — `tesl/time.rkt` defines it as
// `(define-newtype PosixMillis Integer)` and Racket's integers are exact and unbounded, so
// arithmetic on a timestamp cannot silently wrap here either. The type lives in the runtime
// rather than being emitted per module for the reason `Maybe` does: an instant crosses
// module boundaries, and two packages declaring their own would be different Go types.
type PosixMillis struct {
	Value Int
}

// NowMillis reads the clock. Tesl gates this behind the `time` capability, which the
// checker enforces; nothing about that survives to run time.
func NowMillis() PosixMillis {
	return PosixMillis{Value: FromInt64(time.Now().UnixMilli())}
}

// PosixToSeconds truncates toward zero, which is what Racket's `quotient` does — NOT floor,
// so an instant before the epoch rounds up toward it on both backends.
func PosixToSeconds(instant PosixMillis) Int {
	return MustQuo(instant.Value, FromInt64(1000))
}

func SecondsToPosix(seconds Int) PosixMillis {
	return PosixMillis{Value: Mul(seconds, FromInt64(1000))}
}

func AddMs(instant PosixMillis, delta Int) PosixMillis {
	return PosixMillis{Value: Add(instant.Value, delta)}
}

func SubtractMs(instant PosixMillis, delta Int) PosixMillis {
	return PosixMillis{Value: Sub(instant.Value, delta)}
}

// DiffMs is later minus earlier, in the argument order Tesl uses: `diffMs a b` = b - a.
func DiffMs(earlier, later PosixMillis) Int {
	return Sub(later.Value, earlier.Value)
}

// DurationMs is how long ago an instant was, clamped at zero — a clock that went backwards
// must not produce a negative age (Racket clamps with `max` for the same reason).
func DurationMs(past PosixMillis) Int {
	elapsed := DiffMs(past, NowMillis())
	if Compare(elapsed, FromInt64(0)) < 0 {
		return FromInt64(0)
	}
	return elapsed
}

// The units-typed instant surface: `Time.add ts (Duration.hours 2.0)`. The millisecond forms
// (`addMs`, `diffMs`) stay canonical — they are exact integer arithmetic — and these convert a
// Duration, which is SI SECONDS as a float, into that exact millisecond count.
//
// Seconds → milliseconds rounds HALF-EVEN on the exact rational, the same stance Money takes,
// so an instant cannot drift by a millisecond over a long series of additions.
func TimeAdd(instant PosixMillis, duration float64) PosixMillis {
	return PosixMillis{Value: Add(instant.Value, DurationToMillis(duration))}
}

func TimeSubtract(instant PosixMillis, duration float64) PosixMillis {
	return PosixMillis{Value: Sub(instant.Value, DurationToMillis(duration))}
}

// TimeDiff answers (later - earlier) as a Duration in seconds — the typed counterpart of
// `diffMs`.
func TimeDiff(earlier, later PosixMillis) float64 {
	difference := Sub(later.Value, earlier.Value)
	value, _ := new(big.Rat).SetInt(difference.bigInt()).Float64()
	return value / 1000.0
}
