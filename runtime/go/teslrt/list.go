package teslrt

import (
	"slices"
	"strings"
)

// Tesl's `List a` is a Go slice, which buys idiomatic, readable emitted code. A Tesl
// list is immutable, and nothing in a Tesl program can mutate one, so aliasing is
// only ever observable if a function in THIS FILE writes into a backing array some
// other Tesl value can still see. That gives the one invariant this file must never
// break:
//
//	ONLY WRITERS ALLOCATE. READERS MAY ALIAS.
//
// So Take/Drop/Tail return plain sub-slice views in O(1), while the writers —
// anything append-like, plus SortBy, which sorts in place — build a fresh array
// first. The combination that would be a soundness bug is a zero-copy view PLUS a
// capacity-reusing append: `append(xs[:2], v)` writes index 2, which a longer live
// value still sees. Since both halves live here, forbidding capacity reuse in the
// writers is sufficient, and copying in the readers would be redundant.
//
// Any list writer added later must honour the same rule.
//
// Views are BOUNDED, because a slice keeps its whole backing array alive: a
// `List.take 1` of a 10,000-row query result would otherwise pin all 10,000 rows for
// as long as that one-element value lives. See boundedView.
//
// Remaining consequence, accepted deliberately: this is an invariant of the runtime,
// not of the emitted module code. A Go author who sheds Tesl and appends to a Take
// result reintroduces the classic aliasing bug — out of scope by design, rather than
// paid for with O(n) on every read.
//
// Functions needing equality or ordering take it as a parameter. A generic Go
// function cannot compare a `T` — `teslrt.Int` is deliberately non-comparable — but
// the EMITTER knows the concrete element type at every call site and passes the
// comparison in.
func ListLength[T any](xs []T) Int {
	return FromInt64(int64(len(xs)))
}

func ListIsEmpty[T any](xs []T) bool {
	return len(xs) == 0
}

// ListHead is Nothing for an empty list rather than a panic: Tesl's `List.head`
// returns `Maybe a`.
func ListHead[T any](xs []T) Maybe[T] {
	if len(xs) == 0 {
		return Nothing[T]()
	}
	return Something(xs[0])
}

// ListTail drops the first element, or Nothing when there is none. The result is a
// (bounded) view: no writer can reach the shared array — see the invariant above.
func ListTail[T any](xs []T) Maybe[[]T] {
	if len(xs) == 0 {
		return Nothing[[]T]()
	}
	return Something(boundedView(xs[1:], xs))
}

func ListLast[T any](xs []T) Maybe[T] {
	if len(xs) == 0 {
		return Nothing[T]()
	}
	return Something(xs[len(xs)-1])
}

// ListAppend is a WRITER, so it allocates: appending into either input's spare
// capacity is exactly the mutation the invariant above forbids.
func ListAppend[T any](left, right []T) []T {
	out := make([]T, 0, len(left)+len(right))
	out = append(out, left...)
	out = append(out, right...)
	return out
}

// ListTake and ListDrop are READERS: they return bounded views, clamping the count to
// the list length. A negative count is a programming error the Racket backend rejects
// at runtime, so it panics here rather than silently behaving like zero.
func ListTake[T any](count Int, xs []T) []T {
	return boundedView(xs[:clampCount("List.take", count, len(xs))], xs)
}

func ListDrop[T any](count Int, xs []T) []T {
	return boundedView(xs[clampCount("List.drop", count, len(xs)):], xs)
}

// viewSlack is the array size a view may pin outright. Below it the retention is
// irrelevant and a copy would be pure overhead.
const viewSlack = 32

// boundedView keeps a reader O(1) while capping how much array a small result can
// pin: past the slack, a view may retain at most twice its own length, and otherwise
// copies. The copy costs O(len(out)) — by construction less than half the memory it
// releases — so this cannot turn a cheap read into an expensive one.
func boundedView[T any](out, source []T) []T {
	if cap(source) > viewSlack && cap(source) > 2*len(out) {
		return cloneExact(out)
	}
	return out
}

func clampCount(who string, count Int, length int) int {
	if count.Sign() < 0 {
		panic(who + ": count must be non-negative")
	}
	value, ok := count.Int64()
	if !ok || value > int64(length) {
		return length
	}
	return int(value)
}

func ListReverse[T any](xs []T) []T {
	out := make([]T, len(xs))
	for index, value := range xs {
		out[len(xs)-1-index] = value
	}
	return out
}

func ListSum(xs []Int) Int {
	total := FromInt64(0)
	for _, value := range xs {
		total = Add(total, value)
	}
	return total
}

func ListMemberBy[T any](needle T, xs []T, equal func(T, T) bool) bool {
	for _, value := range xs {
		if equal(needle, value) {
			return true
		}
	}
	return false
}

// ListUniqueBy keeps the FIRST occurrence and preserves order, matching Racket's
// hash-based `List.unique`. It writes only into its own fresh array.
func ListUniqueBy[T any](xs []T, equal func(T, T) bool) []T {
	out := make([]T, 0, len(xs))
	for _, value := range xs {
		if !ListMemberBy(value, out, equal) {
			out = append(out, value)
		}
	}
	return out
}

// ListSortBy is STABLE, matching Racket's `sort`, and sorts a copy so the input
// value is untouched.
func ListSortBy[T any](xs []T, less func(T, T) bool) []T {
	out := cloneExact(xs)
	slices.SortStableFunc(out, func(left, right T) int {
		switch {
		case less(left, right):
			return -1
		case less(right, left):
			return 1
		default:
			return 0
		}
	})
	return out
}

func ListEqualBy[T any](left, right []T, equal func(T, T) bool) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if !equal(left[index], right[index]) {
			return false
		}
	}
	return true
}

// cloneExact gives a writer a private array to work in.
func cloneExact[T any](xs []T) []T {
	out := make([]T, len(xs))
	copy(out, xs)
	return out
}

// StringSplit matches Racket's `string-split` with #:trim? #f: separators are not
// collapsed, leading and trailing empties are kept, and splitting "" yields [""].
func StringSplit(s, sep string) []string {
	if s == "" {
		return []string{""}
	}
	return strings.Split(s, sep)
}

func StringJoin(parts []string, sep string) string {
	return strings.Join(parts, sep)
}

// exactCount converts a proven-non-negative Int to a length. The frontend has already
// discharged `IsNonNegative`, so a negative value here means the emitter let an unproven
// call through; a count that does not fit cannot be allocated at all, and Racket would
// exhaust memory attempting it, so both panic rather than silently truncating to a
// wrong-length list.
func exactCount(who string, count Int) int {
	if count.Sign() < 0 {
		panic(who + ": count must be non-negative")
	}
	value, ok := count.Int64()
	if !ok || value > int64(maxAllocElements) {
		panic(who + ": count is too large to allocate")
	}
	return int(value)
}

// maxAllocElements bounds a single constructed list. Not a language limit — the point
// past which the allocation cannot succeed anyway, reported as a clear panic rather than
// an out-of-memory kill.
const maxAllocElements = 1 << 31

// ListRange is start INCLUSIVE to end EXCLUSIVE, matching `for/list ([i (in-range …)])`
// in tesl/list.rkt, and empty when start >= end.
func ListRange(start, end Int) []Int {
	if Compare(start, end) >= 0 {
		return []Int{}
	}
	span := exactCount("List.range", Sub(end, start))
	out := make([]Int, span)
	current := start
	for index := range out {
		out[index] = current
		current = Add(current, FromInt64(1))
	}
	return out
}

// ListRepeat holds n copies of one value. `n` carries an IsNonNegative proof, so the
// check here is containment rather than the enforcement.
func ListRepeat[T any](value T, n Int) []T {
	out := make([]T, exactCount("List.repeat", n))
	for index := range out {
		out[index] = value
	}
	return out
}

// ListConcat flattens ONE level, like `List.concat`/`List.flatten`. It sizes the result
// first, so a list of n lists costs one allocation rather than n appends.
func ListConcat[T any](xss [][]T) []T {
	total := 0
	for _, xs := range xss {
		total += len(xs)
	}
	out := make([]T, 0, total)
	for _, xs := range xss {
		out = append(out, xs...)
	}
	return out
}

// ListMaximum and ListMinimum are Nothing for the empty list. Ordering comes in from the
// emitter, which knows the concrete element type at each call site.
func ListMaximum[T any](xs []T, less func(T, T) bool) Maybe[T] {
	if len(xs) == 0 {
		return Nothing[T]()
	}
	best := xs[0]
	for _, value := range xs[1:] {
		if less(best, value) {
			best = value
		}
	}
	return Something(best)
}

func ListMinimum[T any](xs []T, less func(T, T) bool) Maybe[T] {
	if len(xs) == 0 {
		return Nothing[T]()
	}
	best := xs[0]
	for _, value := range xs[1:] {
		if less(value, best) {
			best = value
		}
	}
	return Something(best)
}
