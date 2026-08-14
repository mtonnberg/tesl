package teslrt

import (
	"encoding/json"
	"fmt"
	"math/big"
	"sort"
	"strings"
)

// The api-test view of a JSON value.
//
// Inside an `api-test` block a response body is inspected WITHOUT types — `resp.body.userId`
// is deliberately untyped, and the checker types it as a fresh variable so the assertion
// reads like the JSON it is checking. That ergonomics is the point, so this type mirrors what
// the Racket api-test surface does rather than inventing a typed view: a field that is not
// there is NULL rather than an error (`api-test-field-access-ref` returns `'null`), and the
// predicates below are the same ones `tesl/api-test.rkt` exports, with the same argument
// order.
//
// `raw` holds the parsed shape: nil for JSON null or a missing field, `json.Number` for a
// number (so an exact integer stays exact), string, bool, `[]any`, `map[string]any`.
type JsonValue struct {
	raw any
}

func JsonNull() JsonValue { return JsonValue{} }

// JsonOf wraps an already-parsed shape.
func JsonOf(raw any) JsonValue { return JsonValue{raw: raw} }

// JsonRaw is for the runtime's own use (comparing, printing); emitted code goes through the
// helpers below.
func (value JsonValue) JsonRaw() any { return value.raw }

// JsonParseBody parses a response body for inspection. An empty body is JSON null — a
// handler that answered `204` has nothing to inspect, and that is not a test failure by
// itself. A malformed body traps: the test asked to look inside a body that is not JSON.
func JsonParseBody(body string) JsonValue {
	trimmed := strings.TrimSpace(body)
	if trimmed == "" {
		return JsonNull()
	}
	parsed, err := ParseJSON([]byte(trimmed))
	if err != nil {
		panic("api-test: response body is not JSON: " + err.Error())
	}
	return JsonOf(parsed)
}

// JsonFieldOf is `value.field` inside an api-test: a missing key — or a field read on
// anything that is not an object — is NULL, matching `api-test-field-access-ref`. That is
// what lets `expect isNull resp.body.missing` be written at all.
func JsonFieldOf(value JsonValue, key string) JsonValue {
	fields, ok := value.raw.(map[string]any)
	if !ok {
		return JsonNull()
	}
	found, present := fields[key]
	if !present {
		return JsonNull()
	}
	return JsonOf(found)
}

// ── The Tesl.ApiTest predicates, in Tesl's argument order ─────────────────────

func JsonIsNull(value JsonValue) bool {
	if value.raw == nil {
		return true
	}
	// Racket also treats the STRING "null" as null here, because a body that spelled null as
	// text would otherwise read as present.
	text, ok := value.raw.(string)
	return ok && text == "null"
}

func JsonIsNotNull(value JsonValue) bool { return !JsonIsNull(value) }

// JsonLength counts an array, an object's keys, or a string's characters; anything else is a
// trap naming what it got, as Racket's `jsonLength` does.
func JsonLength(value JsonValue) Int {
	switch typed := value.raw.(type) {
	case []any:
		return FromInt64(int64(len(typed)))
	case map[string]any:
		return FromInt64(int64(len(typed)))
	case string:
		return FromInt64(int64(len([]rune(typed))))
	default:
		panic(fmt.Sprintf("jsonLength: expected an array, object, or string, got %s",
			jsonTypeName(value.raw)))
	}
}

func JsonHasLength(expected Int, value JsonValue) bool {
	return Compare(expected, JsonLength(value)) == 0
}

func JsonIsEmpty(value JsonValue) bool {
	return Compare(JsonLength(value), FromInt64(0)) == 0
}

func JsonIsNotEmpty(value JsonValue) bool { return !JsonIsEmpty(value) }

func JsonHasField(key string, value JsonValue) bool {
	fields, ok := value.raw.(map[string]any)
	if !ok {
		panic("hasField: expected a JSON object, got " + jsonTypeName(value.raw))
	}
	_, present := fields[key]
	return present
}

// JsonFieldAt is `fieldAt`: like a field read, but it insists the value IS an object.
func JsonFieldAt(key string, value JsonValue) JsonValue {
	fields, ok := value.raw.(map[string]any)
	if !ok {
		panic("fieldAt: expected a JSON object, got " + jsonTypeName(value.raw))
	}
	found, present := fields[key]
	if !present {
		return JsonNull()
	}
	return JsonOf(found)
}

func JsonArrayAt(index Int, value JsonValue) JsonValue {
	elements, ok := value.raw.([]any)
	if !ok {
		panic("arrayAt: expected a JSON array, got " + jsonTypeName(value.raw))
	}
	at, exact := index.Int64()
	if !exact || at < 0 || at >= int64(len(elements)) {
		panic(fmt.Sprintf("arrayAt: index %s is out of range for array of length %d",
			index.String(), len(elements)))
	}
	return JsonOf(elements[at])
}

// ── The coercing accessors ────────────────────────────────────────────────────

func JsonAsInt(value JsonValue) Int {
	number, ok := value.raw.(json.Number)
	if !ok {
		panic("jsonInt: expected a JSON number, got " + jsonTypeName(value.raw))
	}
	parsed, valid := new(big.Int).SetString(number.String(), 10)
	if !valid {
		panic("jsonInt: expected an integer, got " + number.String())
	}
	return fromBig(parsed)
}

func JsonAsString(value JsonValue) string {
	text, ok := value.raw.(string)
	if !ok {
		panic("jsonString: expected a JSON string, got " + jsonTypeName(value.raw))
	}
	return text
}

func JsonAsBool(value JsonValue) bool {
	flag, ok := value.raw.(bool)
	if !ok {
		panic("jsonBool: expected a JSON boolean, got " + jsonTypeName(value.raw))
	}
	return flag
}

// ── Comparison ────────────────────────────────────────────────────────────────

// JsonEqual compares an untyped JSON value against an ENCODED Tesl value — the same `any`
// shape the response encoder builds, so the two directions cannot disagree about what a
// value looks like as JSON.
//
// This is what makes `expect resp.body.age == 7` work: on Racket both sides are ordinary
// values by then and `equal?` decides, so the comparison has to be structural here too.
func JsonEqual(value JsonValue, other any) bool {
	return jsonSame(value.raw, jsonNormalize(other))
}

// JsonContains is `jsonContains needle value`: substring for two strings, and otherwise
// "needle is contained in value" — every field the needle names matches, recursively.
func JsonContains(needle any, value JsonValue) bool {
	wanted := jsonNormalize(needle)
	if needleText, ok := wanted.(string); ok {
		if valueText, ok := value.raw.(string); ok {
			return strings.Contains(valueText, needleText)
		}
	}
	return jsonMatch(wanted, value.raw)
}

// jsonNormalize maps an encoded Tesl value onto the shapes a parsed body uses, so that an
// `Int` compares against a `json.Number` and a nested record against an object.
func jsonNormalize(value any) any {
	switch typed := value.(type) {
	case nil:
		return nil
	case JsonValue:
		return typed.raw
	case Int:
		return json.Number(typed.String())
	case json.Number, string, bool:
		return typed
	case float64:
		return json.Number(FormatFloat(typed))
	case []any:
		out := make([]any, len(typed))
		for index, element := range typed {
			out[index] = jsonNormalize(element)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(typed))
		for key, element := range typed {
			out[key] = jsonNormalize(element)
		}
		return out
	default:
		return typed
	}
}

func jsonSame(left, right any) bool {
	switch typedLeft := left.(type) {
	case nil:
		return right == nil
	case json.Number:
		return jsonNumbersEqual(typedLeft, right)
	case string:
		text, ok := right.(string)
		return ok && text == typedLeft
	case bool:
		flag, ok := right.(bool)
		return ok && flag == typedLeft
	case []any:
		other, ok := right.([]any)
		if !ok || len(other) != len(typedLeft) {
			return false
		}
		for index, element := range typedLeft {
			if !jsonSame(element, other[index]) {
				return false
			}
		}
		return true
	case map[string]any:
		other, ok := right.(map[string]any)
		if !ok || len(other) != len(typedLeft) {
			return false
		}
		for key, element := range typedLeft {
			counterpart, present := other[key]
			if !present || !jsonSame(element, counterpart) {
				return false
			}
		}
		return true
	default:
		return false
	}
}

// Numbers compare by VALUE, not by text: `1` and `1.0` are the same JSON number, and an
// exact integer beyond int64 still compares exactly.
func jsonNumbersEqual(left json.Number, right any) bool {
	other, ok := right.(json.Number)
	if !ok {
		return false
	}
	leftInt, leftExact := new(big.Int).SetString(left.String(), 10)
	rightInt, rightExact := new(big.Int).SetString(other.String(), 10)
	if leftExact && rightExact {
		return leftInt.Cmp(rightInt) == 0
	}
	leftFloat, leftErr := left.Float64()
	rightFloat, rightErr := other.Float64()
	return leftErr == nil && rightErr == nil && leftFloat == rightFloat
}

// jsonMatch is containment rather than equality: every key the needle names must match, and
// extra keys in the value are fine.
func jsonMatch(needle, value any) bool {
	switch typedNeedle := needle.(type) {
	case map[string]any:
		other, ok := value.(map[string]any)
		if !ok {
			return false
		}
		for key, element := range typedNeedle {
			counterpart, present := other[key]
			if !present || !jsonMatch(element, counterpart) {
				return false
			}
		}
		return true
	case []any:
		other, ok := value.([]any)
		if !ok {
			return false
		}
		// Every element of the needle must appear somewhere in the value, in any position:
		// an array assertion is about membership, not about the whole array.
		for _, element := range typedNeedle {
			found := false
			for _, candidate := range other {
				if jsonMatch(element, candidate) {
					found = true
					break
				}
			}
			if !found {
				return false
			}
		}
		return true
	default:
		return jsonSame(needle, value)
	}
}

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

// JsonListOf lifts a typed slice into the `any` shape `JsonEqual` compares against, so a
// list can be compared with a JSON array without the emitter building the conversion inline.
func JsonListOf[Element any](elements []Element) []any {
	out := make([]any, len(elements))
	for index, element := range elements {
		out[index] = element
	}
	return out
}

// JsonIncludesWhere is `includesWhere { "field": value, … } array`: does SOME element of the
// array match every field the pattern names? `excludesWhere` is its negation.
//
// The pattern is a containment test per element, not equality, so an element with extra fields
// still matches — an event stream carries ids and timestamps a test has no business pinning.
// What is NOT tolerated is a pattern field the element does not have at all: that is a typo in
// the test rather than a non-match, and reporting it as "no element matched" would send the
// author looking at the program instead of at the assertion.
func JsonIncludesWhere(pattern any, value JsonValue) bool {
	return jsonArrayMatches("includesWhere", pattern, value)
}

func JsonExcludesWhere(pattern any, value JsonValue) bool {
	return !jsonArrayMatches("excludesWhere", pattern, value)
}

func jsonArrayMatches(who string, pattern any, value JsonValue) bool {
	fields, ok := jsonNormalize(pattern).(map[string]any)
	if !ok {
		panic(fmt.Sprintf("%s: expected a `{ \"field\": value }` pattern, got %s",
			who, jsonTypeName(jsonNormalize(pattern))))
	}
	elements, ok := value.raw.([]any)
	if !ok {
		panic(fmt.Sprintf("%s: expected a JSON array, got %s", who, jsonTypeName(value.raw)))
	}
	matched := false
	for _, element := range elements {
		object, ok := element.(map[string]any)
		if !ok {
			panic(fmt.Sprintf("%s: expected every array element to be a JSON object, got %s",
				who, jsonTypeName(element)))
		}
		elementMatches := true
		for key, expected := range fields {
			found, present := object[key]
			if !present {
				names := make([]string, 0, len(object))
				for name := range object {
					names = append(names, name)
				}
				sort.Strings(names)
				panic(fmt.Sprintf(
					"%s: looking for field %q but element does not have it\n  element has: %s",
					who, key, strings.Join(names, ", ")))
			}
			if !jsonMatch(expected, found) {
				elementMatches = false
			}
		}
		if elementMatches {
			matched = true
		}
	}
	return matched
}
