package teslrt

import (
	"encoding/json"
	"fmt"
	"math/big"
	"sort"
	"strings"
)

// JSON decoding for codecs.
//
// The one non-obvious requirement is INTEGER PRECISION. Tesl's Int is arbitrary
// precision and Racket's JSON reader returns exact integers, so `{"n": 1234567890123
// 45678901234567890}` round-trips there. Go's encoding/json decodes a number into
// float64 when the target is `any`, which would silently round that to
// 1.2345678901234568e+29 — wrong, and only for values above 2^53, so small tests would
// never catch it. Every parse therefore goes through UseNumber and integers are read
// from the decimal digits.
//
// Object key ORDER on the way out is alphabetical, matching Racket's `jsexpr->string`
// (verified: it sorts). Go's own map marshalling sorts too, but a struct would emit in
// field-declaration order, so encoding goes through a map rather than a generated
// struct — the response bytes are observable and the two backends must agree.

// ParseJSON parses a request body. A parse failure is the caller's to report, matching
// the "Malformed JSON payload" 400 the Racket server produces.
func ParseJSON(data []byte) (any, error) {
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	return value, nil
}

// jsonField returns the raw value at key. A missing field is an error rather than a
// zero value: Racket raises `codec: required field "x" not found in JSON` here, and the
// server turns any decode exception into a generic 400 — so the TEXT is not observable
// by default, but the failure must still happen.
func jsonField(object any, key string) (any, error) {
	fields, ok := object.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("codec: expected a JSON object")
	}
	value, present := fields[key]
	if !present {
		return nil, fmt.Errorf("codec: required field %q not found in JSON", key)
	}
	return value, nil
}

// HasJSONField reports whether a key is present, for an alternative that only applies
// when a field exists.
func HasJSONField(object any, key string) bool {
	fields, ok := object.(map[string]any)
	if !ok {
		return false
	}
	_, present := fields[key]
	return present
}

func DecodeStringField(object any, key string) (string, error) {
	raw, err := jsonField(object, key)
	if err != nil {
		return "", err
	}
	text, ok := raw.(string)
	if !ok {
		return "", fmt.Errorf("expected JSON string, got %v", raw)
	}
	return text, nil
}

// DecodeIntField reads the decimal digits rather than a float64, so an integer wider
// than 2^53 survives.
func DecodeIntField(object any, key string) (Int, error) {
	raw, err := jsonField(object, key)
	if err != nil {
		return Int{}, err
	}
	number, ok := raw.(json.Number)
	if !ok {
		return Int{}, fmt.Errorf("expected JSON integer, got %v", raw)
	}
	digits := number.String()
	value, ok := new(big.Int).SetString(digits, 10)
	if !ok {
		return Int{}, fmt.Errorf("expected JSON integer, got %v", digits)
	}
	return fromBig(value), nil
}

func DecodeBoolField(object any, key string) (bool, error) {
	raw, err := jsonField(object, key)
	if err != nil {
		return false, err
	}
	flag, ok := raw.(bool)
	if !ok {
		return false, fmt.Errorf("expected JSON boolean, got %v", raw)
	}
	return flag, nil
}

func DecodeFloatField(object any, key string) (float64, error) {
	raw, err := jsonField(object, key)
	if err != nil {
		return 0, err
	}
	number, ok := raw.(json.Number)
	if !ok {
		return 0, fmt.Errorf("expected JSON number, got %v", raw)
	}
	return number.Float64()
}

// DecodeStringValue decodes an already-extracted value, for a nested codec whose field
// was read by the caller (an `adtJson` type decodes from a bare JSON string).
func DecodeStringValue(raw any) (string, error) {
	text, ok := raw.(string)
	if !ok {
		return "", fmt.Errorf("expected JSON string, got %v", raw)
	}
	return text, nil
}

func JSONFieldValue(object any, key string) (any, error) {
	return jsonField(object, key)
}

// EncodeJSON renders an object. Keys are emitted in sorted order to match Racket, which
// is why this takes a map rather than marshalling a generated struct.
func EncodeJSON(fields map[string]any) string {
	var builder strings.Builder
	builder.WriteByte('{')
	keys := make([]string, 0, len(fields))
	for key := range fields {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for index, key := range keys {
		if index > 0 {
			builder.WriteByte(',')
		}
		name, _ := json.Marshal(key)
		builder.Write(name)
		builder.WriteByte(':')
		builder.WriteString(EncodeJSONValue(fields[key]))
	}
	builder.WriteByte('}')
	return builder.String()
}

// EncodeJSONValue renders one value. `Int` is rendered from its decimal digits so a
// bignum is not routed through a float, and a nested object keeps the sorted-key rule.
func EncodeJSONValue(value any) string {
	switch typed := value.(type) {
	case Int:
		return typed.String()
	case map[string]any:
		return EncodeJSON(typed)
	case []any:
		parts := make([]string, len(typed))
		for index, element := range typed {
			parts[index] = EncodeJSONValue(element)
		}
		return "[" + strings.Join(parts, ",") + "]"
	case float64:
		return FormatFloat(typed)
	default:
		encoded, err := json.Marshal(typed)
		if err != nil {
			panic("codec: value cannot be encoded as JSON")
		}
		return string(encoded)
	}
}
