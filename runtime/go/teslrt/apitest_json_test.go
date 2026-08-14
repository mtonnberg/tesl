package teslrt

import "testing"

const sampleBody = `{"userId":"user-1","count":3,"tags":["a","b"],"nested":{"ok":true},"nothing":null}`

// A field read inside an api-test is UNTYPED and a missing field is null, not an error —
// that is what lets `expect isNull resp.body.missing` be written at all.
func TestJsonFieldReadsAndNull(t *testing.T) {
	body := JsonParseBody(sampleBody)
	if !JsonEqual(JsonFieldOf(body, "userId"), "user-1") {
		t.Error("string field")
	}
	if !JsonEqual(JsonFieldOf(body, "count"), FromInt64(3)) {
		t.Error("number field compares against an Int")
	}
	if !JsonIsNull(JsonFieldOf(body, "missing")) {
		t.Error("a missing field must be null")
	}
	if !JsonIsNull(JsonFieldOf(body, "nothing")) {
		t.Error("an explicit JSON null must be null")
	}
	if !JsonIsNotNull(JsonFieldOf(body, "userId")) {
		t.Error("a present field must not be null")
	}
	// A field read on a non-object is null rather than a trap, as on Racket.
	if !JsonIsNull(JsonFieldOf(JsonFieldOf(body, "userId"), "nope")) {
		t.Error("a field read on a string must be null")
	}
	// An empty body is null: a 204 has nothing to inspect and that is not a failure.
	if !JsonIsNull(JsonParseBody("")) {
		t.Error("an empty body must be null")
	}
}

func TestJsonLengthAndShapePredicates(t *testing.T) {
	body := JsonParseBody(sampleBody)
	if n := JsonLength(JsonFieldOf(body, "tags")); n.String() != "2" {
		t.Errorf("array length = %s", n.String())
	}
	if n := JsonLength(JsonFieldOf(body, "userId")); n.String() != "6" {
		t.Errorf("string length = %s", n.String())
	}
	if n := JsonLength(body); n.String() != "5" {
		t.Errorf("object length = %s", n.String())
	}
	if !JsonHasLength(FromInt64(2), JsonFieldOf(body, "tags")) {
		t.Error("hasLength")
	}
	if JsonIsEmpty(JsonFieldOf(body, "tags")) || !JsonIsNotEmpty(JsonFieldOf(body, "tags")) {
		t.Error("isEmpty / isNotEmpty")
	}
	if !JsonHasField("userId", body) || JsonHasField("nope", body) {
		t.Error("hasField")
	}
	if !JsonEqual(JsonFieldAt("userId", body), "user-1") {
		t.Error("fieldAt")
	}
	if !JsonIsNull(JsonFieldAt("nope", body)) {
		t.Error("fieldAt of a missing key is null")
	}
	if !JsonEqual(JsonArrayAt(FromInt64(1), JsonFieldOf(body, "tags")), "b") {
		t.Error("arrayAt")
	}
	if !JsonEqual(JsonFieldOf(JsonFieldOf(body, "nested"), "ok"), true) {
		t.Error("nested object field")
	}
}

func TestJsonCoercingAccessors(t *testing.T) {
	body := JsonParseBody(sampleBody)
	if got := JsonAsString(JsonFieldOf(body, "userId")); got != "user-1" {
		t.Errorf("jsonString = %q", got)
	}
	if got := JsonAsInt(JsonFieldOf(body, "count")); got.String() != "3" {
		t.Errorf("jsonInt = %s", got.String())
	}
	if got := JsonAsBool(JsonFieldOf(JsonFieldOf(body, "nested"), "ok")); !got {
		t.Error("jsonBool")
	}
	// The wrong shape traps and names what it got.
	defer func() {
		message, ok := recover().(string)
		if !ok || !contains(message, "expected a JSON number") {
			t.Fatalf("jsonInt on a string must trap: %v", message)
		}
	}()
	JsonAsInt(JsonFieldOf(body, "userId"))
}

func contains(haystack, needle string) bool {
	return len(haystack) >= len(needle) && (func() bool {
		for at := 0; at+len(needle) <= len(haystack); at++ {
			if haystack[at:at+len(needle)] == needle {
				return true
			}
		}
		return false
	})()
}

func TestJsonEqualityIsStructural(t *testing.T) {
	body := JsonParseBody(sampleBody)
	// A whole object compares field-wise against an encoded Tesl value.
	if !JsonEqual(JsonFieldOf(body, "nested"), map[string]any{"ok": true}) {
		t.Error("object equality")
	}
	if JsonEqual(JsonFieldOf(body, "nested"), map[string]any{"ok": false}) {
		t.Error("object inequality")
	}
	if !JsonEqual(JsonFieldOf(body, "tags"), []any{"a", "b"}) {
		t.Error("array equality")
	}
	if JsonEqual(JsonFieldOf(body, "tags"), []any{"a"}) {
		t.Error("an array of a different length must not compare equal")
	}
	// Numbers compare by VALUE: 3 and 3.0 are the same JSON number, and exactness survives.
	if !JsonEqual(JsonParseBody(`{"n":3.0}`).field("n"), FromInt64(3)) {
		t.Error("3.0 == 3")
	}
	huge := MustParseDecimal("123456789012345678901234567890")
	if !JsonEqual(JsonParseBody(`{"n":123456789012345678901234567890}`).field("n"), huge) {
		t.Error("an exact integer past int64 must compare exactly")
	}
}

// field is a test-only shorthand.
func (value JsonValue) field(key string) JsonValue { return JsonFieldOf(value, key) }

func TestJsonContains(t *testing.T) {
	body := JsonParseBody(sampleBody)
	// Substring for two strings.
	if !JsonContains("user", JsonFieldOf(body, "userId")) {
		t.Error("substring")
	}
	if JsonContains("admin", JsonFieldOf(body, "userId")) {
		t.Error("substring miss")
	}
	// Containment for structures: the needle's fields must match, extras are fine.
	if !JsonContains(map[string]any{"userId": "user-1"}, body) {
		t.Error("object containment")
	}
	if JsonContains(map[string]any{"userId": "someone-else"}, body) {
		t.Error("object containment miss")
	}
	if !JsonContains([]any{"b"}, JsonFieldOf(body, "tags")) {
		t.Error("array membership")
	}
}
