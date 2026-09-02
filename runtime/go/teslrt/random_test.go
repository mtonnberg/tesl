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

// A v4 UUID is random; what is fixed is its SHAPE and its version/variant nibbles, which is
// what every reader of one relies on.
func TestUUIDv4Shape(t *testing.T) {
	seen := map[string]bool{}
	for range 64 {
		id := UUIDv4()
		if !ValidUUID(id) {
			t.Fatalf("UUIDv4 produced %q", id)
		}
		if id[14] != '4' {
			t.Fatalf("version digit = %q in %q", id[14], id)
		}
		if variant := id[19]; variant != '8' && variant != '9' && variant != 'a' && variant != 'b' {
			t.Fatalf("variant digit = %q in %q", variant, id)
		}
		if seen[id] {
			t.Fatalf("UUIDv4 repeated %q", id)
		}
		seen[id] = true
	}
}

func TestUUIDv7IsTimeOrdered(t *testing.T) {
	first := UUIDv7()
	second := UUIDv7()
	if !ValidUUID(first) || first[14] != '7' {
		t.Fatalf("UUIDv7 produced %q", first)
	}
	// Time-ordered means the 48-bit millisecond PREFIX never goes backwards — that is what
	// makes "oldest job first" recoverable from the id alone. Within one millisecond the
	// remaining bits are random, so the whole strings need not be ordered, and asserting
	// that they are would be a flake waiting for two ids minted in the same tick.
	if first[:13] > second[:13] {
		t.Fatalf("%q has a later timestamp than %q", first, second)
	}
}

func TestValidUUIDAcceptsEitherCase(t *testing.T) {
	for _, valid := range []string{
		"a8098c1a-f86e-4f11-8d1c-6e9e14b9d8e2",
		"A8098C1A-F86E-4F11-8D1C-6E9E14B9D8E2",
		"00000000-0000-0000-0000-000000000000",
	} {
		if !ValidUUID(valid) {
			t.Fatalf("rejected %q", valid)
		}
	}
	for _, invalid := range []string{
		"", "not-a-uuid", "a8098c1a-f86e-4f11-8d1c",
		"a8098c1a-f86e-4f11-8d1c-6e9e14b9d8e2-extra",
		"g8098c1a-f86e-4f11-8d1c-6e9e14b9d8e2",
		"a8098c1a f86e-4f11-8d1c-6e9e14b9d8e2",
	} {
		if ValidUUID(invalid) {
			t.Fatalf("accepted %q", invalid)
		}
	}
}

// The validator is a CHECK: a rejection carries the 400 the request answers with.
func TestUUIDValidateRejectsWith400(t *testing.T) {
	ok := UUIDValidate("a8098c1a-f86e-4f11-8d1c-6e9e14b9d8e2")
	if value, fine := ok.Value(); !fine || value != "a8098c1a-f86e-4f11-8d1c-6e9e14b9d8e2" {
		t.Fatalf("accepted check gave %q, %v", value, fine)
	}
	rejected := UUIDValidate("nope")
	if rejected.OK() {
		t.Fatal("an invalid UUID was accepted")
	}
	if rejected.Status() != 400 {
		t.Fatalf("rejection status = %d", rejected.Status())
	}
}
