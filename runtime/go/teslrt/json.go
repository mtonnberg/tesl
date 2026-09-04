package teslrt

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
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
//
// The body must be EXACTLY ONE JSON value. `json.Decoder` reads a stream, so on its own it
// would accept `{"n":1} garbage` and `{"n":1}{"n":2}` and answer the first document — which
// is not what Racket's `string->jsexpr` does (it rejects trailing content) and is the seam a
// proxy or WAF that parsed the same bytes as "malformed" would disagree with the app across.
// The check is a second Decode that must hit EOF: `decoder.More()` is not enough because it
// answers false for a stray `}` as well as for the end of input.
func ParseJSON(data []byte) (any, error) {
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return nil, errors.New("unexpected content after the JSON value")
	}
	return value, nil
}

// maxJSONIntegerDigits bounds the decimal literal an `Int` field accepts. `big.Int.SetString`
// is quadratic in the digit count, so a 1 MiB body of digits — inside the body cap — costs
// about two seconds of CPU per request: an amplification vector rather than a hang, closed
// by refusing the literal before the conversion starts. 4096 digits is ~13600 bits, far past
// any quantity a program models as an Int.
const maxJSONIntegerDigits = maxDecimalDigits

// parseJSONInteger is the one place a JSON number becomes an `Int`, for the field and value
// decoders alike. The messages name the SHAPE of what arrived and never echo it: a decode
// error is answered to the client as the 400 body, and reflecting a 1 MiB submitted value
// (in Go `map[...]` syntax, no less) back at it is noise at best.
func parseJSONInteger(raw any) (Int, error) {
	number, ok := raw.(json.Number)
	if !ok {
		return Int{}, fmt.Errorf("expected JSON integer, got %s", jsonTypeName(raw))
	}
	digits := number.String()
	if len(digits) > maxJSONIntegerDigits {
		return Int{}, fmt.Errorf("JSON integer has %d digits; at most %d are accepted",
			len(digits), maxJSONIntegerDigits)
	}
	value, ok := new(big.Int).SetString(digits, 10)
	if !ok {
		return Int{}, errors.New("expected JSON integer, got a non-integer number")
	}
	return fromBig(value), nil
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
		return "", fmt.Errorf("expected JSON string, got %s", jsonTypeName(raw))
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
	return parseJSONInteger(raw)
}

func DecodeBoolField(object any, key string) (bool, error) {
	raw, err := jsonField(object, key)
	if err != nil {
		return false, err
	}
	flag, ok := raw.(bool)
	if !ok {
		return false, fmt.Errorf("expected JSON boolean, got %s", jsonTypeName(raw))
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
		return 0, fmt.Errorf("expected JSON number, got %s", jsonTypeName(raw))
	}
	return number.Float64()
}

// DecodeStringValue decodes an already-extracted value, for a nested codec whose field
// was read by the caller (an `adtJson` type decodes from a bare JSON string).
func DecodeStringValue(raw any) (string, error) {
	text, ok := raw.(string)
	if !ok {
		return "", fmt.Errorf("expected JSON string, got %s", jsonTypeName(raw))
	}
	return text, nil
}

func JSONFieldValue(object any, key string) (any, error) {
	return jsonField(object, key)
}

// jsonTypeName names a parsed JSON shape for an error message. It lives HERE rather than beside
// the api-test assertions because `json.go` ships with every program while the api-test half
// does not, and the ADT tag decoder below needs it.
func jsonTypeName(raw any) string {
	switch raw.(type) {
	case nil:
		return "null"
	case json.Number:
		return "number"
	case string:
		return "string"
	case bool:
		return "boolean"
	case []any:
		return "array"
	case map[string]any:
		return "object"
	default:
		return fmt.Sprintf("%T", raw)
	}
}

// DecodeAdtTag reads the constructor name an `adtJson` codec decodes from. Racket's generated
// decoder accepts BOTH shapes — `{"tag": "Ctor"}`, which is what its encoder writes, and a bare
// "Ctor" string, which is what an Elm or hand-written client may send — so this does too.
func DecodeAdtTag(raw any) (string, error) {
	switch typed := raw.(type) {
	case string:
		return typed, nil
	case map[string]any:
		found, present := typed["tag"]
		if !present {
			return "", fmt.Errorf("expected {\"tag\": ...} or a string, got an object with no tag")
		}
		name, ok := found.(string)
		if !ok {
			return "", fmt.Errorf("expected a string tag, got %s", jsonTypeName(found))
		}
		return name, nil
	default:
		return "", fmt.Errorf("expected {\"tag\": ...} or a string, got %s", jsonTypeName(raw))
	}
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
//
// A NON-FINITE Float TRAPS. JSON has no NaN or infinity, and `FormatFloat` — the display
// formatter — spells them `NaN`/`+Inf`/`-Inf`, which a client's JSON parser rejects: a handler
// answering `Float.exp 1000.0` would send a `200 application/json` whose body is not JSON.
// Racket's `jsexpr->string` raises on `+inf.0`, and this is that raise; `writeResponse` turns
// it into the sanitized 500 every other trap becomes. `null` was the alternative and is worse:
// it would let the overflow pass as "no value" and be stored or summed downstream.
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
		if math.IsNaN(typed) || math.IsInf(typed, 0) {
			panic("codec: a Float " + FormatFloat(typed) + " cannot be encoded as JSON")
		}
		return FormatFloat(typed)
	default:
		encoded, err := json.Marshal(typed)
		if err != nil {
			panic("codec: value cannot be encoded as JSON")
		}
		return string(encoded)
	}
}

// DecodeObjectShape is the shape check a DERIVED record decoder runs before reading any
// field: a record with no `codec` block still decodes from JSON, and the rule it follows is
// the Racket runtime's generic decode (dsl/types.rkt `jsexpr->typed-value`) — the object's
// keys must be EXACTLY the record's fields. A missing field is a 400 because the field has no
// value to take, and an EXTRA field is a 400 too, which is the surprising half: silently
// ignoring unknown keys is how a typo'd field name becomes a silent default.
func DecodeObjectShape(raw any, typeName string, expected []string) (map[string]any, error) {
	fields, ok := raw.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("expected record JSON for type %s, got %s", typeName, jsonTypeName(raw))
	}
	missing := make([]string, 0, len(expected))
	for _, name := range expected {
		if _, present := fields[name]; !present {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("record JSON for type %s is missing field%s (%s)",
			typeName, plural(len(missing)), strings.Join(missing, " "))
	}
	extra := make([]string, 0, len(fields))
	for name := range fields {
		if !containsName(expected, name) {
			extra = append(extra, name)
		}
	}
	if len(extra) > 0 {
		sort.Strings(extra)
		return nil, fmt.Errorf("record JSON for type %s has unexpected field%s (%s)",
			typeName, plural(len(extra)), strings.Join(extra, " "))
	}
	return fields, nil
}

func plural(count int) string {
	if count == 1 {
		return ""
	}
	return "s"
}

func containsName(names []string, wanted string) bool {
	for _, name := range names {
		if name == wanted {
			return true
		}
	}
	return false
}

// The value-level counterparts of the DecodeXField helpers, for a derived decoder that has
// already taken the object apart (and for a list element, which has no key at all).

func DecodeIntValue(raw any) (Int, error) {
	return parseJSONInteger(raw)
}

func DecodeBoolValue(raw any) (bool, error) {
	flag, ok := raw.(bool)
	if !ok {
		return false, fmt.Errorf("expected JSON boolean, got %s", jsonTypeName(raw))
	}
	return flag, nil
}

func DecodeFloatValue(raw any) (float64, error) {
	number, ok := raw.(json.Number)
	if !ok {
		return 0, fmt.Errorf("expected JSON number, got %s", jsonTypeName(raw))
	}
	return number.Float64()
}

// DecodeListValue decodes a JSON array element-wise through `element`, so a derived decoder
// composes over `List T` without the emitter writing the loop at every use.
func DecodeListValue[Element any](raw any, element func(any) (Element, error)) ([]Element, error) {
	items, ok := raw.([]any)
	if !ok {
		return nil, fmt.Errorf("expected JSON array, got %s", jsonTypeName(raw))
	}
	out := make([]Element, 0, len(items))
	for _, item := range items {
		decoded, err := element(item)
		if err != nil {
			return nil, err
		}
		out = append(out, decoded)
	}
	return out, nil
}

// CheckedDecoder adapts a codec's `Check`-answering decoder to the `(value, error)` shape
// the container readers walk with, so one loop decodes a list of scalars and a list of
// records alike. The check's own message is carried through, which is what the client sees.
func CheckedDecoder[T any](decode func(any) Check[T]) func(any) (T, error) {
	return func(raw any) (T, error) {
		result := decode(raw)
		value, ok := result.Value()
		if !ok {
			return value, errors.New(result.Message())
		}
		return value, nil
	}
}

// The column-decoder half of the ADT wire shape: reading a stored `{"tag": …, "fields": {…}}`
// back into the value it was written from.
//
// Each of these PANICS on a mismatch rather than answering a zero value. A column holds data
// this build wrote, so a field of the wrong shape is corruption or an incompatible schema —
// the same line the tag switch takes for a tag it has no constructor for. A request body is
// the opposite case and goes through the `Decode*` functions above, which answer an error.

// ParseColumnJSON parses the text of a jsonb column that holds an ADT.
//
// It accepts BOTH shapes a Tesl backend writes there. This backend writes a JSON object.
// `dsl/sql.rkt` binds the serialised value as a STRING parameter, so a row written by the
// Racket backend holds a jsonb string whose contents are that object — `"{\"tag\":\"Low\"}"`
// rather than `{"tag": "Low"}`. The Racket reader accepts either, and this one has to as well:
// a service being ported reads the rows it already has, and refusing the incumbent shape would
// make every existing ADT column unreadable.
//
// Exactly ONE layer is unwrapped. A stored value that is a string all the way down is not an
// ADT under either backend's encoding, and unwrapping repeatedly would turn a corrupt column
// into a plausible one.
func ParseColumnJSON(data []byte) (any, error) {
	parsed, err := ParseJSON(data)
	if err != nil {
		return nil, err
	}
	text, isText := parsed.(string)
	if !isText {
		return parsed, nil
	}
	return ParseJSON([]byte(text))
}

// MustJSONFields is the `fields` object of a stored variant.
func MustJSONFields(parsed any, typeName, variant string) any {
	object, isObject := parsed.(map[string]any)
	if !isObject {
		panic("database: a " + typeName + " column does not hold a JSON object")
	}
	fields, present := object["fields"]
	if !present {
		panic("database: a " + typeName + " column's " + variant + " carries fields, but the " +
			"stored value has no \"fields\" object")
	}
	return fields
}

// MustJSONField is one labelled field of that object.
func MustJSONField(fields any, label string) any {
	object, isObject := fields.(map[string]any)
	if !isObject {
		panic("database: a stored variant's \"fields\" is not a JSON object")
	}
	value, present := object[label]
	if !present {
		panic("database: a stored variant is missing the field " + label)
	}
	return value
}

func MustDecodeString(raw any) string {
	value, err := DecodeStringValue(raw)
	if err != nil {
		panic("database: " + err.Error())
	}
	return value
}

func MustDecodeInt(raw any) Int {
	value, err := DecodeIntValue(raw)
	if err != nil {
		panic("database: " + err.Error())
	}
	return value
}

func MustDecodeFloat(raw any) float64 {
	number, isNumber := raw.(json.Number)
	if !isNumber {
		panic("database: expected a stored number")
	}
	value, err := number.Float64()
	if err != nil {
		panic("database: " + err.Error())
	}
	return value
}

func MustDecodeBool(raw any) bool {
	value, isBool := raw.(bool)
	if !isBool {
		panic("database: expected a stored boolean")
	}
	return value
}

// MustEncodeJSON re-serialises a decoded sub-value, so a NESTED ADT field can go through the
// same column decoder its own type already has rather than needing a second one.
func MustEncodeJSON(raw any) []byte {
	encoded, err := json.Marshal(raw)
	if err != nil {
		panic("database: a stored value does not re-encode: " + err.Error())
	}
	return encoded
}

// MaybeOfJSON reads a stored `Maybe` field.
//
// A `Maybe` inside a variant is written as the TAGGED shape every other ADT gets —
// `{"tag":"Nothing"}` / `{"tag":"Something","fields":{"value":…}}` — because that is what the
// value encoder and `dsl/types.rkt` both write for it. It is NOT a JSON null: null is what a
// nullable COLUMN holds, and a field inside a stored variant is not a column.
func MaybeOfJSON[A any](raw any, decode func(any) A) Maybe[A] {
	object, isObject := raw.(map[string]any)
	if !isObject {
		panic("database: a stored Maybe field is not a JSON object")
	}
	tag, _ := object["tag"].(string)
	switch tag {
	case "Nothing":
		return Nothing[A]()
	case "Something":
		return Something(decode(MustJSONField(MustJSONFields(raw, "Maybe", "Something"), "value")))
	default:
		panic("database: a stored Maybe field holds an unknown tag " + tag)
	}
}
