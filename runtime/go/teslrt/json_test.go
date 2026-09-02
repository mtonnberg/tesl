package teslrt

import (
	"math"
	"math/big"
	"strings"
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

// JSON has no NaN or infinity. `FormatFloat` spells them for DISPLAY, and reusing it here sent
// `{"value":+Inf}` as a 200 application/json body a client cannot parse (review M3). Racket's
// `jsexpr->string` raises; so does this, naming the value kind.
func TestEncodeJSONValueRefusesNonFiniteFloats(t *testing.T) {
	for _, testCase := range []struct {
		value float64
		kind  string
	}{
		{math.NaN(), "NaN"},
		{math.Inf(1), "+Inf"},
		{math.Inf(-1), "-Inf"},
	} {
		mustPanic(t, "Float "+testCase.kind+" cannot be encoded as JSON", func() {
			EncodeJSONValue(map[string]any{"value": testCase.value})
		})
		mustPanic(t, testCase.kind, func() { EncodeJSONValue([]any{testCase.value}) })
	}
	// A finite float is untouched by the check.
	if got := EncodeJSONValue(1.5); got != "1.5" {
		t.Errorf("finite float = %q", got)
	}
}

// Exactly one JSON value: Racket's `string->jsexpr` rejects trailing content, and a body a
// proxy parsed as malformed must not be one the app parses as fine.
func TestParseJSONRejectsTrailingContent(t *testing.T) {
	for _, body := range []string{`{"n":1} x`, `{"n":1}{"n":2}`, `{"n":1}}`, `[1] 2`} {
		if _, err := ParseJSON([]byte(body)); err == nil {
			t.Errorf("ParseJSON(%q) accepted trailing content", body)
		}
	}
	for _, body := range []string{`{"n":1}`, ` {"n":1} `, "{\"n\":1}\n", `7`} {
		if _, err := ParseJSON([]byte(body)); err != nil {
			t.Errorf("ParseJSON(%q) = %v, want a single value accepted", body, err)
		}
	}
}

// A decode error is the client's 400 body. It names the JSON type that arrived, never the
// value: reflecting a 1 MiB object in Go's `map[...]` syntax is noise, and a wrong-typed field
// is described completely by "got object".
func TestDecodeErrorsNameTheTypeNotTheValue(t *testing.T) {
	parsed, err := ParseJSON([]byte(`{"n": {"nested": "SECRET-MARKER"}, "s": 42, "b": "yes", "f": true}`))
	if err != nil {
		t.Fatal(err)
	}
	check := func(who string, err error, wantType string) {
		t.Helper()
		if err == nil {
			t.Fatalf("%s: expected an error", who)
		}
		if !strings.Contains(err.Error(), "got "+wantType) {
			t.Errorf("%s: message %q does not name the type %q", who, err.Error(), wantType)
		}
		if strings.Contains(err.Error(), "SECRET-MARKER") || strings.Contains(err.Error(), "42") ||
			strings.Contains(err.Error(), "map[") {
			t.Errorf("%s: message %q echoes the submitted value", who, err.Error())
		}
	}
	_, err = DecodeIntField(parsed, "n")
	check("DecodeIntField", err, "object")
	_, err = DecodeStringField(parsed, "s")
	check("DecodeStringField", err, "number")
	_, err = DecodeBoolField(parsed, "b")
	check("DecodeBoolField", err, "string")
	_, err = DecodeFloatField(parsed, "f")
	check("DecodeFloatField", err, "boolean")
	_, err = DecodeIntValue(parsed)
	check("DecodeIntValue", err, "object")
	_, err = DecodeStringValue(true)
	check("DecodeStringValue", err, "boolean")
	_, err = DecodeBoolValue("x")
	check("DecodeBoolValue", err, "string")
	_, err = DecodeFloatValue([]any{})
	check("DecodeFloatValue", err, "array")
	_, err = DecodeListValue(parsed, DecodeIntValue)
	check("DecodeListValue", err, "object")
	_, err = DecodeObjectShape("SECRET-MARKER", "Note", []string{"title"})
	check("DecodeObjectShape", err, "string")
	// A number that is not an integer is still described, not echoed.
	nonInteger, _ := ParseJSON([]byte(`{"n": 1.5}`))
	_, err = DecodeIntField(nonInteger, "n")
	if err == nil || strings.Contains(err.Error(), "1.5") {
		t.Errorf("non-integer number: %v", err)
	}
}

// `big.Int.SetString` is quadratic in the digit count, so a 1 MiB literal of digits cost about
// two seconds of CPU per request. The literal is refused by length before the conversion runs.
func TestDecodeIntRejectsOverlongLiteral(t *testing.T) {
	accepted, err := ParseJSON([]byte(`{"n": ` + strings.Repeat("9", maxJSONIntegerDigits) + `}`))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeIntField(accepted, "n"); err != nil {
		t.Errorf("a %d-digit integer must decode: %v", maxJSONIntegerDigits, err)
	}
	refused, err := ParseJSON([]byte(`{"n": ` + strings.Repeat("9", maxJSONIntegerDigits+1) + `}`))
	if err != nil {
		t.Fatal(err)
	}
	_, err = DecodeIntField(refused, "n")
	if err == nil || !strings.Contains(err.Error(), "digits") {
		t.Errorf("a %d-digit integer must be refused by length, got %v", maxJSONIntegerDigits+1, err)
	}
	if _, err := DecodeIntValue(refused.(map[string]any)["n"]); err == nil {
		t.Error("DecodeIntValue must apply the same cap")
	}
}
