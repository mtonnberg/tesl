package teslrt

// If evaluates and returns only the branch selected by condition.
func If[T any](condition bool, whenTrue, whenFalse func() T) T {
	if condition {
		return whenTrue()
	}
	return whenFalse()
}

// Boxed holds a value behind a pointer, and Unboxed reads it back.
//
// A RECURSIVE ADT is why these exist: `type Expr = Lit Int | Add Expr Expr` cannot hold an
// Expr by value in Go (a struct containing itself has no finite size), so a self-referential
// payload field is a pointer and the emitter goes through these two functions at every
// construction and every read. Keeping the indirection in one pair of named functions is
// what makes it invisible in the emitted code's SHAPE: a pattern binding still reads as one
// call, not as a nil test the reader has to trust.
//
// Unboxed traps on a nil pointer rather than answering a zero value. Nothing the emitter
// produces can construct one — every boxed field is filled by Boxed at construction — so a
// nil here is a broken invariant, and a fabricated zero Expr would turn it into a silently
// wrong answer somewhere further along.
func Boxed[T any](value T) *T {
	return &value
}

func Unboxed[T any](boxed *T) T {
	if boxed == nil {
		panic("recursive value: a payload field was never filled")
	}
	return *boxed
}

// BoolRank orders a Bool: false before true, which is how Racket sorts `#f` and `#t`. It
// exists because Go has no `<` on bools and an `order p.done asc` column needs one.
func BoolRank(value bool) int {
	if value {
		return 1
	}
	return 0
}

// ── Partial application ──────────────────────────────────────────────────────
//
// `add 1` in Tesl is a function of the remaining argument. Go has no partial application,
// so the emitter goes through these: each supplies the leading arguments and hands back a
// closure over the rest.
//
// They are named functions rather than inline literals for the reason the comparators are:
// go/printer decides whether a function literal fits on one line by a threshold the emitter
// cannot predict, so an inline closure reformats under gofmt at some sizes and not others —
// and a gofmt diff on emitted code is an emitter bug. A call to one of these is one
// expression at every size.
//
// The family stops at three parameters because that is what the surface reaches for; a
// wider one is refused at emission rather than answered by a guess.

func Apply1Of2[A, B, R any](fn func(A, B) R, first A) func(B) R {
	return func(second B) R { return fn(first, second) }
}

// Apply1Of3 answers a CHAIN of one-argument functions, not a two-argument one: Tesl's
// partial application is curried, so `blend 1` is a function of `b` that answers a function
// of `c`. The Racket runtime is curried the same way, and a flat `withA 2 3` is an arity
// error there — so the shape here is the surface's, not Go's convenience.
func Apply1Of3[A, B, C, R any](fn func(A, B, C) R, first A) func(B) func(C) R {
	return func(second B) func(C) R {
		return func(third C) R { return fn(first, second, third) }
	}
}

func Apply2Of3[A, B, C, R any](fn func(A, B, C) R, first A, second B) func(C) R {
	return func(third C) R { return fn(first, second, third) }
}
