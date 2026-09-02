package teslrt

import (
	"strings"
	"testing"
)

// The generators exist to search a range, so what is tested is the RANGE and the variety —
// a generator that answers one value would make every property vacuous.

func TestPropRandomStaysBelowItsBound(t *testing.T) {
	seen := map[int64]bool{}
	for range 500 {
		value, exact := PropRandom(FromInt64(10)).Int64()
		if !exact || value < 0 || value > 9 {
			t.Fatalf("PropRandom(10) answered %d", value)
		}
		seen[value] = true
	}
	if len(seen) < 8 {
		t.Fatalf("PropRandom(10) only ever answered %d distinct values", len(seen))
	}
}

func TestPropRandomRejectsANonPositiveBound(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("a zero bound was accepted")
		}
	}()
	PropRandom(FromInt64(0))
}

// Int is signed around zero: a property that only ever met positives would miss the case it
// most likely gets wrong.
func TestPropIntCoversBothSigns(t *testing.T) {
	negative, positive := false, false
	for range 500 {
		value, exact := PropInt().Int64()
		if !exact || value < -1_000_000 || value > 1_000_000 {
			t.Fatalf("PropInt answered %d, outside the Racket range", value)
		}
		if value < 0 {
			negative = true
		}
		if value > 0 {
			positive = true
		}
	}
	if !negative || !positive {
		t.Fatalf("PropInt produced negatives=%v positives=%v", negative, positive)
	}
}

func TestPropBoolProducesBoth(t *testing.T) {
	yes, no := false, false
	for range 200 {
		if PropBool() {
			yes = true
		} else {
			no = true
		}
	}
	if !yes || !no {
		t.Fatalf("PropBool produced true=%v false=%v", yes, no)
	}
}

func TestPropStringIsTheRacketShape(t *testing.T) {
	seen := map[string]bool{}
	for range 200 {
		value := PropString()
		if !strings.HasPrefix(value, "s") || len(value) < 2 {
			t.Fatalf("PropString answered %q", value)
		}
		seen[value] = true
	}
	if len(seen) < 100 {
		t.Fatalf("PropString only produced %d distinct values in 200 draws", len(seen))
	}
}

// A list generator that never produced the EMPTY list would skip the case a list property
// most often gets wrong.
func TestPropListCoversEmptyAndFull(t *testing.T) {
	empty, longest := false, 0
	for range 500 {
		values := PropList(func() Int { return PropInt() })
		if len(values) > 7 {
			t.Fatalf("PropList produced %d elements, more than Racket's 7", len(values))
		}
		if len(values) == 0 {
			empty = true
		}
		if len(values) > longest {
			longest = len(values)
		}
	}
	if !empty {
		t.Fatal("PropList never produced the empty list")
	}
	if longest != 7 {
		t.Fatalf("PropList never reached 7 elements (longest %d)", longest)
	}
}

func TestPropMaybeProducesBothVariants(t *testing.T) {
	nothing, something := false, false
	for range 200 {
		value := PropMaybe(func() string { return PropString() })
		if value.IsSomething() {
			something = true
			if !strings.HasPrefix(value.SomethingValue, "s") {
				t.Fatalf("PropMaybe wrapped %q", value.SomethingValue)
			}
		} else {
			nothing = true
		}
	}
	if !nothing || !something {
		t.Fatalf("PropMaybe produced Nothing=%v Something=%v", nothing, something)
	}
}
