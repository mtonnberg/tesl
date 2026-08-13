package teslrt

import "testing"

// The zero value must be Nothing: emitted code relies on it (a struct literal that
// names only the tag leaves the payload zeroed), and a zero value that read as
// Something would hand out a fabricated payload.
func TestMaybeZeroValueIsNothing(t *testing.T) {
	var m Maybe[Int]
	if m.IsSomething() {
		t.Fatal("zero Maybe reported Something")
	}
	if _, ok := m.Value(); ok {
		t.Fatal("zero Maybe yielded a value")
	}
	if m.Tag != MaybeNothing {
		t.Fatalf("zero Maybe tag = %d, want %d", m.Tag, MaybeNothing)
	}
}

func TestMaybeSomethingRoundTrip(t *testing.T) {
	m := Something(FromInt64(42))
	if !m.IsSomething() {
		t.Fatal("Something reported Nothing")
	}
	value, ok := m.Value()
	if !ok {
		t.Fatal("Something yielded no value")
	}
	if !Equal(value, FromInt64(42)) {
		t.Fatalf("Something value = %s, want 42", value.String())
	}
}

// A present zero payload is still Something: presence is carried by the tag, never
// inferred from the payload.
func TestMaybeSomethingOfZeroIsPresent(t *testing.T) {
	for _, m := range []Maybe[Int]{Something(FromInt64(0)), Something(Int{})} {
		value, ok := m.Value()
		if !ok {
			t.Fatal("Something(zero) reported absent")
		}
		if !value.IsZero() {
			t.Fatalf("payload = %s, want 0", value.String())
		}
	}
	empty := Something("")
	if value, ok := empty.Value(); !ok || value != "" {
		t.Fatalf("Something(\"\") = %q, %v", value, ok)
	}
}

// Nothing must not leak a payload even when the type parameter has a non-trivial
// zero value.
func TestMaybeNothingHasNoPayload(t *testing.T) {
	m := Nothing[string]()
	if value, ok := m.Value(); ok || value != "" {
		t.Fatalf("Nothing yielded %q, %v", value, ok)
	}
	ints := Nothing[Int]()
	if value, ok := ints.Value(); ok || !value.IsZero() {
		t.Fatalf("Nothing[Int] yielded %s, %v", value.String(), ok)
	}
}

// The tag order is part of the emitted contract: the emitter writes
// teslrt.MaybeNothing / teslrt.MaybeSomething into switch cases, and renumbering
// them would silently reinterpret every stored tag.
func TestMaybeTagValuesArePinned(t *testing.T) {
	if MaybeNothing != 0 {
		t.Fatalf("MaybeNothing = %d, want 0", MaybeNothing)
	}
	if MaybeSomething != 1 {
		t.Fatalf("MaybeSomething = %d, want 1", MaybeSomething)
	}
}
