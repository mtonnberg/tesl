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

func TestMaybeWireEncoding(t *testing.T) {
	encodeInt := func(value Int) any { return value }
	if got := EncodeMaybeWire(Nothing[Int](), encodeInt); got != nil {
		t.Fatalf("Nothing encoded as %v, want nil", got)
	}
	if got := EncodeJSONValue(EncodeMaybeWire(Something(FromInt64(5)), encodeInt)); got != "5" {
		t.Fatalf("Something 5 encoded as %s, want 5", got)
	}
}

func TestDecodeMaybeValueAcceptsWireAndStoredShapes(t *testing.T) {
	parse := func(text string) any {
		value, err := ParseJSON([]byte(text))
		if err != nil {
			t.Fatal(err)
		}
		return value
	}
	cases := []struct {
		raw  string
		want Maybe[Int]
	}{
		{`null`, Nothing[Int]()},
		{`5`, Something(FromInt64(5))},
		{`{"tag":"Nothing"}`, Nothing[Int]()},
		{`{"tag":"Something","fields":{"value":7}}`, Something(FromInt64(7))},
	}
	for _, c := range cases {
		got, err := DecodeMaybeValue(parse(c.raw), DecodeIntValue)
		if err != nil {
			t.Fatalf("decode %v: %v", c.raw, err)
		}
		gotValue, gotPresent := got.Value()
		wantValue, wantPresent := c.want.Value()
		if gotPresent != wantPresent || (gotPresent && !Equal(gotValue, wantValue)) {
			t.Fatalf("decode %v = %v, want %v", c.raw, got, c.want)
		}
	}
	if got, err := DecodeMaybeValue(nil, DecodeIntValue); err != nil || got.IsSomething() {
		t.Fatal("an absent key must read as Nothing")
	}
	if _, err := DecodeMaybeValue("five", DecodeIntValue); err == nil {
		t.Fatal("a wrongly typed payload must still be refused")
	}
}

// A record that merely has a `tag` field is a record, not an envelope.
func TestDecodeMaybeValueDoesNotMistakeARecordForAnEnvelope(t *testing.T) {
	record := map[string]any{"tag": "Something", "fields": map[string]any{"value": 1.0}, "extra": true}
	got, err := DecodeMaybeValue(record, func(raw any) (map[string]any, error) {
		return raw.(map[string]any), nil
	})
	if err != nil {
		t.Fatal(err)
	}
	inner, present := got.Value()
	if !present || inner["extra"] != true {
		t.Fatalf("the record was unwrapped as an envelope: %v", got)
	}
}

func TestDecodeObjectShapeOptionalAllowsAbsentMaybeKeys(t *testing.T) {
	if _, err := DecodeObjectShapeOptional(map[string]any{"a": 1.0}, "R", []string{"a", "b"}, []string{"b"}); err != nil {
		t.Fatalf("absent optional key refused: %v", err)
	}
	if _, err := DecodeObjectShapeOptional(map[string]any{"b": 1.0}, "R", []string{"a", "b"}, []string{"b"}); err == nil {
		t.Fatal("absent required key accepted")
	}
	if _, err := DecodeObjectShapeOptional(map[string]any{"a": 1.0, "c": 1.0}, "R", []string{"a", "b"}, []string{"b"}); err == nil {
		t.Fatal("unexpected key accepted")
	}
}
