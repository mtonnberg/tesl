package teslrt

import "testing"

func TestCheckResult(t *testing.T) {
	t.Parallel()

	accepted := Accept(FromInt64(42))
	if !accepted.OK() {
		t.Fatal("accepted check reports rejection")
	}
	value, ok := accepted.Value()
	if !ok || !Equal(value, FromInt64(42)) {
		t.Fatal("accepted check lost its value")
	}
	if !Equal(MustCheck(accepted), FromInt64(42)) {
		t.Fatal("MustCheck returned wrong value")
	}

	rejected := Reject[Int](422, "invalid")
	if rejected.OK() {
		t.Fatal("rejected check reports success")
	}
	if rejected.Status() != 422 || rejected.Message() != "invalid" {
		t.Fatalf("rejection = (%d, %q)", rejected.Status(), rejected.Message())
	}
}

// A shape rejection is a 400 on the wire, not a sentinel status. The distinction between
// "not this shape" and "this value is invalid" is a FLAG, because a decoder with no
// alternatives behind it — a derived record decoder — answers the client with its rejection
// directly, and a status of 0 there is not a response at all (`WriteHeader(0)` panics).
func TestShapeRejectionCarriesFourHundred(t *testing.T) {
	rejected := RejectShape[int]("record JSON for type X is missing field (a)")
	if rejected.OK() {
		t.Fatal("a shape rejection reported OK")
	}
	if rejected.Status() != 400 {
		t.Fatalf("status = %d, want 400", rejected.Status())
	}
	if !rejected.IsShapeMismatch() {
		t.Fatal("a shape rejection did not report a shape mismatch")
	}
	// A VALIDATION failure that happens to carry 400 is still not a shape mismatch, or a
	// codec's first real 400 would be replaced by the last alternative's shape complaint.
	validation := Reject[int](400, "too short")
	if validation.IsShapeMismatch() {
		t.Fatal("a validation failure reported a shape mismatch")
	}
}
