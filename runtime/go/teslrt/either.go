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

// EitherPartition splits a list of Either into its Left payloads and its Right payloads, in
// input order, as `Either.partition` does in tesl/either.rkt. It answers the two lists as a
// Tuple2 rather than two values, because Tesl has no multiple return.
func EitherPartition[A any, B any](values []Either[A, B]) Tuple2[[]A, []B] {
	lefts := make([]A, 0, len(values))
	rights := make([]B, 0, len(values))
	for _, value := range values {
		if value.Tag == EitherRight {
			rights = append(rights, value.RightValue)
		} else {
			lefts = append(lefts, value.LeftValue)
		}
	}
	return Tuple2[[]A, []B]{Tuple2First: lefts, Tuple2Second: rights}
}

// The Either combinators, as tesl/either.tesl writes them. The ones taking a FUNCTION
// (`map`, `mapLeft`, `andThen`) are emitted inline instead — the emitter inlines a callback
// rather than passing a Go func value, which is the same rule the list leaves follow.

func EitherIsLeft[A any, B any](value Either[A, B]) bool {
	return value.Tag == EitherLeft
}

func EitherIsRight[A any, B any](value Either[A, B]) bool {
	return value.Tag == EitherRight
}

func EitherFromLeft[A any, B any](value Either[A, B]) Maybe[A] {
	if value.Tag == EitherLeft {
		return Something(value.LeftValue)
	}
	return Nothing[A]()
}

func EitherFromRight[A any, B any](value Either[A, B]) Maybe[B] {
	if value.Tag == EitherRight {
		return Something(value.RightValue)
	}
	return Nothing[B]()
}

// EitherWithDefault takes the default FIRST, as the Tesl signature does.
func EitherWithDefault[A any, B any](fallback B, value Either[A, B]) B {
	if value.Tag == EitherRight {
		return value.RightValue
	}
	return fallback
}

// EitherToMaybe forgets WHICH left it was: a Left becomes Nothing.
func EitherToMaybe[A any, B any](value Either[A, B]) Maybe[B] {
	if value.Tag == EitherRight {
		return Something(value.RightValue)
	}
	return Nothing[B]()
}

// EitherFromMaybe supplies the left a Nothing has no value for.
func EitherFromMaybe[A any, B any](leftValue A, value Maybe[B]) Either[A, B] {
	if value.Tag == MaybeSomething {
		return Right[A, B](value.SomethingValue)
	}
	return Left[A, B](leftValue)
}
