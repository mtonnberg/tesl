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
