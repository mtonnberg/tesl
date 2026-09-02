package teslrt

import "testing"

// The zero value must be a Left: a zero Either that read as a Right would hand out a
// fabricated value, and the emitter relies on the tag order when it writes literals.
func TestEitherZeroValueIsLeft(t *testing.T) {
	var either Either[string, Int]
	if either.IsRight() {
		t.Fatal("zero Either reported Right")
	}
	if either.Tag != EitherLeft {
		t.Fatalf("zero tag = %d, want %d", either.Tag, EitherLeft)
	}
	if either.LeftValue != "" {
		t.Fatalf("zero LeftValue = %q", either.LeftValue)
	}
}

func TestEitherCarriesTheSideItWasGiven(t *testing.T) {
	left := Left[string, Int]("boom")
	if left.IsRight() || left.LeftValue != "boom" {
		t.Fatalf("left = %v", left)
	}
	right := Right[string, Int](FromInt64(7))
	if !right.IsRight() || !Equal(right.RightValue, FromInt64(7)) {
		t.Fatalf("right = %v", right)
	}
	// A Right of a zero value is still a Right: presence is the tag, never the payload.
	zero := Right[string, Int](Int{})
	if !zero.IsRight() {
		t.Fatal("Right(zero) reported Left")
	}
}

// The tag values are part of the emitted contract: the emitter writes
// teslrt.EitherLeft / teslrt.EitherRight into switch cases and literals.
func TestEitherTagValuesArePinned(t *testing.T) {
	if EitherLeft != 0 || EitherRight != 1 {
		t.Fatalf("tags = %d, %d, want 0, 1", EitherLeft, EitherRight)
	}
}
