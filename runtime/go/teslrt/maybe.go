package teslrt

// Maybe is Tesl's `Maybe a`. It lives in the runtime rather than being emitted per
// module because a `Maybe` crosses module boundaries: two emitted packages that
// each declared their own would produce incompatible Go types.
//
// The representation is the same flat tag+payload struct the emitter generates for
// a user ADT, and Tag is exported for exactly that reason — an emitted package in
// another module has to read it. The zero value is Nothing, matching Go's
// zero-value convention as well as the tag order below.
type Maybe[A any] struct {
	Tag            MaybeTag
	SomethingValue A
}

// MaybeTag identifies which variant a Maybe holds. The constants are an enum-like
// set so the `exhaustive` linter can verify a switch over them.
type MaybeTag int

const (
	MaybeNothing MaybeTag = iota
	MaybeSomething
)

// Nothing is the empty Maybe. Emitted code writes the composite literal directly;
// this exists for hand-written runtime code and for readable tests.
func Nothing[A any]() Maybe[A] {
	return Maybe[A]{Tag: MaybeNothing}
}

// Something wraps a present value.
func Something[A any](value A) Maybe[A] {
	return Maybe[A]{Tag: MaybeSomething, SomethingValue: value}
}

// IsSomething reports whether a value is present.
func (m Maybe[A]) IsSomething() bool {
	return m.Tag == MaybeSomething
}

// Value returns the wrapped value and whether it was present. The payload of a
// Nothing is the zero value of A and must not be read as data; this signature
// makes that impossible to do by accident.
func (m Maybe[A]) Value() (A, bool) {
	if m.Tag != MaybeSomething {
		var zero A
		return zero, false
	}
	return m.SomethingValue, true
}

// ── Maybe on the JSON wire ───────────────────────────────────────────────────
//
// On an HTTP body, an SSE payload or a tool result, `Maybe a` is JSON `null` for Nothing and
// the bare value for `Something v` — the shape the generated OpenAPI document, TypeScript and
// Elm clients have always declared (the runtime sent the generic ADT
// envelope instead, so a client decoding by the published contract silently read every
// populated value as Nothing). Stored JSON (a JSONB column, a queue or cache row) keeps the
// tagged envelope it always had, so nothing already persisted changes meaning.

// EncodeMaybeWire renders a Maybe for the wire: nil for Nothing, the encoded payload otherwise.
func EncodeMaybeWire[A any](value Maybe[A], encode func(A) any) any {
	if inner, present := value.Value(); present {
		return encode(inner)
	}
	return nil
}

// DecodeMaybeValue reads a Maybe from JSON. It accepts the wire shape — null (or an absent
// key, which a decoder sees as nil) for Nothing and the bare value for Something — and the
// stored envelope `{"tag":"Nothing"}` / `{"tag":"Something","fields":{"value":v}}`, so one
// decoder serves a request body and a row written before or after the wire change.
func DecodeMaybeValue[A any](raw any, decode func(any) (A, error)) (Maybe[A], error) {
	if raw == nil {
		return Nothing[A](), nil
	}
	if envelope, isObject := raw.(map[string]any); isObject && isMaybeEnvelope(envelope) {
		if envelope["tag"] == "Nothing" {
			return Nothing[A](), nil
		}
		fields, _ := envelope["fields"].(map[string]any)
		inner, err := decode(fields["value"])
		if err != nil {
			return Nothing[A](), err
		}
		return Something(inner), nil
	}
	inner, err := decode(raw)
	if err != nil {
		return Nothing[A](), err
	}
	return Something(inner), nil
}

// isMaybeEnvelope recognises exactly the two stored envelope shapes and nothing looser, so a
// record payload that merely has a `tag` field is still read as the record.
func isMaybeEnvelope(object map[string]any) bool {
	switch object["tag"] {
	case "Nothing":
		return len(object) == 1
	case "Something":
		fields, isObject := object["fields"].(map[string]any)
		if !isObject || len(object) != 2 || len(fields) != 1 {
			return false
		}
		_, hasValue := fields["value"]
		return hasValue
	default:
		return false
	}
}
