package teslrt

import (
	"math"
	"testing"
)

// The expectations here were READ OFF the Racket runtime (tesl/units.rkt), bit for bit where
// the value is not exact: a conversion factor that differs in the last place is the kind of
// difference that only shows up in someone's invoice.

func TestUnitConstructorsMatchRacket(t *testing.T) {
	for _, want := range []struct {
		name     string
		got      float64
		expected float64
	}{
		{"Length.miles 3", LengthMiles(3), 4828.032},
		{"Length.inFeet 100", LengthInFeet(100), 328.0839895013123},
		{"Speed.kilometersPerHour 100", SpeedKilometersPerHour(100), 27.77777777777778},
		{"Speed.inKnots 10", SpeedInKnots(10), 19.438444924406046},
		{"Duration.hours 1.5", DurationHours(1.5), 5400.0},
		{"Volume.liters 2", VolumeLiters(2), 0.002},
		{"Area.acres 1", AreaAcres(1), 4046.8564224},
	} {
		if want.got != want.expected {
			t.Fatalf("%s = %v, Racket says %v", want.name, want.got, want.expected)
		}
	}
}

// Temperature is AFFINE: 0 °C is 273.15 K, so it cannot be converted by a factor. The
// Fahrenheit round trip lands on Racket's value including its float noise, which is the point
// — the two backends must agree on the arithmetic, not on a tidier answer.
func TestTemperatureIsAffine(t *testing.T) {
	if got := TemperatureCelsius(20); got != 293.15 {
		t.Fatalf("20 °C = %v K", got)
	}
	if got := TemperatureFahrenheit(98.6); got != 310.15 {
		t.Fatalf("98.6 °F = %v K", got)
	}
	if got := TemperatureInFahrenheit(310.15); got != 98.60000000000001 {
		t.Fatalf("310.15 K = %v °F, Racket says 98.60000000000001", got)
	}
	if got := TemperatureInCelsius(TemperatureCelsius(37)); math.Abs(got-37) > 1e-12 {
		t.Fatalf("37 °C round-tripped to %v", got)
	}
}

func TestPolymorphicUnitOperations(t *testing.T) {
	if got := UnitsMul(3, 4); got != 12 {
		t.Fatalf("mul = %v", got)
	}
	if got := UnitsDiv(10, 4); got != 2.5 {
		t.Fatalf("div = %v", got)
	}
	if got := UnitsSquare(3); got != 9 {
		t.Fatalf("square = %v", got)
	}
	if got := UnitsSqrt(2); got != 1.4142135623730951 {
		t.Fatalf("sqrt 2 = %v, Racket says 1.4142135623730951", got)
	}
	if got := UnitsAbs(-2.5); got != 2.5 {
		t.Fatalf("abs = %v", got)
	}
	if got := UnitsNegate(2.5); got != -2.5 {
		t.Fatalf("negate = %v", got)
	}
	if got := UnitsMin(2, 3); got != 2 {
		t.Fatalf("min = %v", got)
	}
	if got := UnitsMax(2, 3); got != 3 {
		t.Fatalf("max = %v", got)
	}
	if got := UnitsSum([]float64{1.5, 2.5, 3}); got != 7 {
		t.Fatalf("sum = %v", got)
	}
	// The empty sum is zero, not a trap: a total over no quantities is a legitimate answer.
	if got := UnitsSum(nil); got != 0 {
		t.Fatalf("the empty sum is %v", got)
	}
}

// The millisecond bridge rounds HALF-EVEN on the DECIMAL form, so 0.0015 s is 1.5 ms and
// lands on 2 — the binary value just under it would land on 1.
func TestDurationMillisBridge(t *testing.T) {
	for _, want := range []struct {
		seconds  float64
		expected int64
	}{
		{1.5, 1500},
		{0.0015, 2},
		{0.0025, 3},
	} {
		got, _ := DurationToMillis(want.seconds).Int64()
		if got != want.expected {
			t.Fatalf("%v s = %d ms, Racket says %d", want.seconds, got, want.expected)
		}
	}
	if got := DurationFromMillis(FromInt64(1500)); got != 1.5 {
		t.Fatalf("1500 ms = %v s", got)
	}
}

// A zero divisor is a value the CALLER sent, so it is a 422 rather than a crash — the same
// status and message Float's non-zero check answers with, because quantities erase to floats
// and share that predicate.
func TestUnitsRequireNonZero(t *testing.T) {
	rejected := UnitsRequireNonZero(0)
	if rejected.OK() {
		t.Fatal("zero passed the non-zero check")
	}
	if rejected.Status() != 422 || rejected.Message() != "expected a non-zero quantity" {
		t.Fatalf("the refusal is %d %q", rejected.Status(), rejected.Message())
	}
	if accepted := UnitsRequireNonZero(-0.5); !accepted.OK() {
		t.Fatal("a negative quantity was refused as zero")
	}
}
