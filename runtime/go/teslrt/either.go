package teslrt

// Either is Tesl's `Either a b`: Left carries the error-ish side, Right the value.
// Like Maybe it lives in the runtime because an Either crosses module boundaries, and
// it uses the same flat tag+payload shape the emitter generates for a user ADT.
//
// The zero value is a Left holding the zero value of A, matching the tag order below.
// That is deliberate rather than incidental: a zero Either must not read as a Right
// and hand out a fabricated value.
type Either[A any, B any] struct {
	Tag        EitherTag
	LeftValue  A
	RightValue B
}

// EitherTag identifies which side an Either holds. The constants are an enum-like set
// so the `exhaustive` linter can verify a switch over them.
type EitherTag int

const (
	EitherLeft EitherTag = iota
	EitherRight
)

// Left and Right exist for hand-written runtime code and readable tests; emitted code
// writes the composite literal directly.
func Left[A any, B any](value A) Either[A, B] {
	return Either[A, B]{Tag: EitherLeft, LeftValue: value}
}

func Right[A any, B any](value B) Either[A, B] {
	return Either[A, B]{Tag: EitherRight, RightValue: value}
}

// IsRight reports which side is held.
func (e Either[A, B]) IsRight() bool {
	return e.Tag == EitherRight
}
