package teslrt

import (
	"math/big"
	"testing"
)

// The parity targets come from Racket, printed with `jsexpr->string`:
//
//	{"a":1.0,"b":0.1,"c":1e+30,"d":12345678901234567890123}
//
// and its reader returns EXACT integers, so a bignum survives a round trip.

func TestJSONIntegerPrecision(t *testing.T) {
	const huge = "123456789012345678901234567890"
	parsed, err := ParseJSON([]byte(`{"count": ` + huge + `}`))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	value, err := DecodeIntField(parsed, "count")
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	// The whole point: a float64 would read 1.2345678901234568e+29 here.
	if value.String() != huge {
		t.Errorf("decoded %s, want %s", value.String(), huge)
	}
	if got := EncodeJSON(map[string]any{"count": value}); got != `{"count":`+huge+`}` {
		t.Errorf("re-encoded %s", got)
	}
}

func TestJSONKeyOrderIsSorted(t *testing.T) {
	// Racket's jsexpr->string sorts keys; a Go struct would emit field order, so the
	// encoder takes a map.
	got := EncodeJSON(map[string]any{"zebra": FromInt64(1), "alpha": FromInt64(2), "middle": FromInt64(3)})
	if got != `{"alpha":2,"middle":3,"zebra":1}` {
		t.Errorf("key order = %s", got)
	}
}

func TestJSONValueRenderingMatchesRacket(t *testing.T) {
	got := EncodeJSON(map[string]any{
		"a": 1.0,
		"b": 0.1,
		"c": 1e30,
		"d": MustParseDecimal("12345678901234567890123"),
	})
	want := `{"a":1.0,"b":0.1,"c":1e+30,"d":12345678901234567890123}`
	if got != want {
		t.Errorf("rendering =\n  %s\nwant\n  %s", got, want)
	}
}

func TestJSONFieldErrors(t *testing.T) {
	parsed, err := ParseJSON([]byte(`{"name": "ok", "n": 3}`))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if _, err := DecodeStringField(parsed, "missing"); err == nil {
		t.Error("a missing field must fail")
	}
	if _, err := DecodeIntField(parsed, "name"); err == nil {
		t.Error("a type mismatch must fail")
	}
	if _, err := DecodeStringField(parsed, "n"); err == nil {
		t.Error("an int is not a string")
	}
	if !HasJSONField(parsed, "name") || HasJSONField(parsed, "missing") {
		t.Error("HasJSONField")
	}
	// Malformed input is the caller's 400, not a panic.
	if _, err := ParseJSON([]byte(`{"a":`)); err == nil {
		t.Error("malformed JSON must fail")
	}
}

func TestJSONNestedAndArrays(t *testing.T) {
	got := EncodeJSON(map[string]any{
		"outer": map[string]any{"z": FromInt64(1), "a": "x"},
		"list":  []any{FromInt64(1), "two", true},
	})
	want := `{"list":[1,"two",true],"outer":{"a":"x","z":1}}`
	if got != want {
		t.Errorf("nested = %s want %s", got, want)
	}
	_ = big.NewInt(0)
}
