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
