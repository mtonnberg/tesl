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
