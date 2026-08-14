package teslrt

import (
	"encoding/hex"
	"testing"
)

func TestRandomIntStaysInRange(t *testing.T) {
	low, high := FromInt64(5), FromInt64(9)
	seen := map[string]bool{}
	for i := 0; i < 300; i++ {
		got := RandomInt(low, high)
		if Compare(got, low) < 0 || Compare(got, high) >= 0 {
			t.Fatalf("randomInt out of [5, 9): %s", got.String())
		}
		seen[got.String()] = true
	}
	// [lo, hi) is half-open, so 9 must never appear and all four others should.
	if len(seen) != 4 || seen["9"] {
		t.Errorf("draws = %v", seen)
	}
}

// A range that holds no value is a trap, not a silent `low`.
func TestRandomIntTrapsOnEmptyRange(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("expected a trap on an empty range")
		}
	}()
	RandomInt(FromInt64(3), FromInt64(3))
}

// An exact-integer range wider than int64 still works.
func TestRandomIntBeyondInt64(t *testing.T) {
	low := MustParseDecimal("100000000000000000000")
	high := MustParseDecimal("100000000000000000010")
	got := RandomInt(low, high)
	if Compare(got, low) < 0 || Compare(got, high) >= 0 {
		t.Fatalf("randomInt out of range: %s", got.String())
	}
}

func TestRandomFloatIsInUnitInterval(t *testing.T) {
	distinct := map[float64]bool{}
	for i := 0; i < 300; i++ {
		got := RandomFloat()
		if got < 0 || got >= 1 {
			t.Fatalf("randomFloat out of [0, 1): %v", got)
		}
		distinct[got] = true
	}
	if len(distinct) < 100 {
		t.Errorf("randomFloat looks stuck: %d distinct values in 300 draws", len(distinct))
	}
}

func TestGeneratedIdsAreUnguessableAndShaped(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		id := GeneratePrefixedId("task")
		if len(id) != len("task-")+32 {
			t.Fatalf("id has the wrong shape: %q", id)
		}
		if id[:5] != "task-" {
			t.Fatalf("id lost its prefix: %q", id)
		}
		if _, err := hex.DecodeString(id[5:]); err != nil {
			t.Fatalf("id tail is not hex: %q", id)
		}
		if seen[id] {
			t.Fatalf("id repeated: %q", id)
		}
		seen[id] = true
	}
	// An unprefixed id keeps the separator, as it does on Racket.
	if bare := GenerateId(); len(bare) != 33 || bare[0] != '-' {
		t.Errorf("generateId = %q", bare)
	}
}
