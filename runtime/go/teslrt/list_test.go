package teslrt

import (
	"math"
	"testing"
	"time"
)

func intEqual(left, right Int) bool { return Equal(left, right) }

func intLess(left, right Int) bool { return Compare(left, right) < 0 }

func ints(values ...int64) []Int {
	out := make([]Int, 0, len(values))
	for _, value := range values {
		out = append(out, FromInt64(value))
	}
	return out
}

func requireInts(t *testing.T, label string, got []Int, want ...int64) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("%s: length %d, want %d", label, len(got), len(want))
	}
	for index := range want {
		if !Equal(got[index], FromInt64(want[index])) {
			t.Fatalf("%s: [%d] = %s, want %d", label, index, got[index].String(), want[index])
		}
	}
}

// THE invariant of this representation: ONLY WRITERS ALLOCATE, READERS MAY ALIAS.
// Views are fine and deliberate (Take/Drop/Tail are O(1)); what must never happen is
// a writer reaching a backing array another live value can see. So this checks
// behavior — "did any input change?" — rather than representation.
func TestListWritersNeverDisturbALiveValue(t *testing.T) {
	// Spare capacity is the whole hazard: a capacity-reusing append would write past
	// the view's length, into an element the longer value still sees.  The view is
	// built directly rather than through ListTake, because a writer must tolerate an
	// aliasing input whatever produced it — and a small-slack list yields exactly this.
	source := make([]Int, 3, 64)
	copy(source, ints(1, 2, 3))
	view := source[:2]
	if cap(view) <= len(view) {
		t.Fatal("the aliasing hazard this test guards is absent")
	}

	// Every writer, run against that deliberately-aliasing view.
	appended := ListAppend(view, ints(99))
	requireInts(t, "source after append", source, 1, 2, 3)
	requireInts(t, "appended", appended, 1, 2, 99)
	requireInts(t, "view after append", view, 1, 2)

	sorted := ListSortBy(view, func(left, right Int) bool { return Compare(left, right) > 0 })
	requireInts(t, "source after sort", source, 1, 2, 3)
	requireInts(t, "sorted", sorted, 2, 1)

	requireInts(t, "unique", ListUniqueBy(view, intEqual), 1, 2)
	requireInts(t, "source after unique", source, 1, 2, 3)

	requireInts(t, "reverse", ListReverse(view), 2, 1)
	requireInts(t, "source after reverse", source, 1, 2, 3)

	// Two appends off the same view must not see each other's writes.
	first := ListAppend(view, ints(7))
	second := ListAppend(view, ints(8))
	requireInts(t, "first append", first, 1, 2, 7)
	requireInts(t, "second append", second, 1, 2, 8)
	requireInts(t, "source after both", source, 1, 2, 3)
}

// Readers stay O(1) views for ordinary lists — that is what this representation buys,
// so pin it, or a later "defensive copy" would silently make every read O(n).
func TestListReadersReturnViewsForOrdinaryLists(t *testing.T) {
	source := ints(1, 2, 3)
	if take := ListTake(FromInt64(2), source); &take[0] != &source[0] {
		t.Error("Take copied a small list instead of returning a view")
	}
	if drop := ListDrop(FromInt64(1), source); &drop[0] != &source[1] {
		t.Error("Drop copied a small list instead of returning a view")
	}
	if tail, ok := ListTail(source).Value(); !ok || &tail[0] != &source[1] {
		t.Error("Tail copied a small list instead of returning a view")
	}
}

// A slice keeps its whole backing array alive, so a tiny result must not pin a large
// one: `List.take 1` of a 10,000-row query result would otherwise hold all 10,000
// rows for as long as that one element lives.
func TestSmallReadsDoNotPinALargeArray(t *testing.T) {
	large := make([]Int, 4096)
	for index := range large {
		large[index] = FromInt64(int64(index))
	}

	first := ListTake(FromInt64(1), large)
	requireInts(t, "take 1", first, 0)
	if cap(first) > 2*len(first)+viewSlack {
		t.Errorf("take 1 of 4096 pinned cap %d for len %d", cap(first), len(first))
	}

	last := ListDrop(FromInt64(4095), large)
	requireInts(t, "drop 4095", last, 4095)
	if cap(last) > 2*len(last)+viewSlack {
		t.Errorf("drop 4095 of 4096 pinned cap %d for len %d", cap(last), len(last))
	}

	// A result that is most of the source still aliases: copying it would cost as much
	// as the memory it releases.
	most := ListDrop(FromInt64(1), large)
	if &most[0] != &large[1] {
		t.Error("drop 1 of 4096 copied instead of aliasing")
	}
}

func TestListLengthAndEmptiness(t *testing.T) {
	if !Equal(ListLength(ints()), FromInt64(0)) {
		t.Error("length of empty")
	}
	if !Equal(ListLength(ints(1, 2, 3)), FromInt64(3)) {
		t.Error("length of three")
	}
	if !ListIsEmpty(ints()) || ListIsEmpty(ints(1)) {
		t.Error("isEmpty")
	}
	// A nil slice is a legitimate empty list, not a separate case.
	var missing []Int
	if !ListIsEmpty(missing) || !Equal(ListLength(missing), FromInt64(0)) {
		t.Error("nil slice is not empty")
	}
}

func TestListHeadTailLastAreMaybe(t *testing.T) {
	if _, ok := ListHead(ints()).Value(); ok {
		t.Error("head of empty yielded a value")
	}
	if _, ok := ListTail(ints()).Value(); ok {
		t.Error("tail of empty yielded a value")
	}
	if _, ok := ListLast(ints()).Value(); ok {
		t.Error("last of empty yielded a value")
	}
	head, ok := ListHead(ints(7, 8)).Value()
	if !ok || !Equal(head, FromInt64(7)) {
		t.Errorf("head = %s, %v", head.String(), ok)
	}
	last, ok := ListLast(ints(7, 8)).Value()
	if !ok || !Equal(last, FromInt64(8)) {
		t.Errorf("last = %s, %v", last.String(), ok)
	}
	tail, ok := ListTail(ints(7, 8, 9)).Value()
	if !ok {
		t.Fatal("tail of non-empty yielded nothing")
	}
	requireInts(t, "tail", tail, 8, 9)
	// Tail of a one-element list is the empty list, not Nothing.
	one, ok := ListTail(ints(7)).Value()
	if !ok || len(one) != 0 {
		t.Errorf("tail of single = %v, %v", one, ok)
	}
}

func TestListTakeDropClampToLength(t *testing.T) {
	xs := ints(1, 2, 3)
	requireInts(t, "take 0", ListTake(FromInt64(0), xs))
	requireInts(t, "take 2", ListTake(FromInt64(2), xs), 1, 2)
	requireInts(t, "take 99", ListTake(FromInt64(99), xs), 1, 2, 3)
	requireInts(t, "take huge", ListTake(MustParseDecimal("99999999999999999999"), xs), 1, 2, 3)
	requireInts(t, "drop 0", ListDrop(FromInt64(0), xs), 1, 2, 3)
	requireInts(t, "drop 2", ListDrop(FromInt64(2), xs), 3)
	requireInts(t, "drop 99", ListDrop(FromInt64(99), xs))
	requireInts(t, "drop huge", ListDrop(MustParseDecimal("99999999999999999999"), xs))
}

// A negative count is a programming error the Racket backend rejects at runtime; it
// must not quietly behave like zero.
func TestListTakeDropRejectNegativeCounts(t *testing.T) {
	for name, call := range map[string]func(){
		"take": func() { ListTake(FromInt64(-1), ints(1, 2)) },
		"drop": func() { ListDrop(FromInt64(-1), ints(1, 2)) },
	} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("%s: negative count did not panic", name)
				}
			}()
			call()
		}()
	}
}

func TestListReverseAndSum(t *testing.T) {
	requireInts(t, "reverse", ListReverse(ints(1, 2, 3)), 3, 2, 1)
	requireInts(t, "reverse empty", ListReverse(ints()))
	if !Equal(ListSum(ints()), FromInt64(0)) {
		t.Error("sum of empty is not 0")
	}
	if !Equal(ListSum(ints(1, 2, 3)), FromInt64(6)) {
		t.Error("sum")
	}
	// Summation must stay exact past int64.
	big := MustParseDecimal("9223372036854775807")
	if got := ListSum([]Int{big, FromInt64(1)}); got.String() != "9223372036854775808" {
		t.Errorf("sum across the int64 boundary = %s", got.String())
	}
}

func TestListMemberUniqueUseTheSuppliedEquality(t *testing.T) {
	xs := ints(1, 2, 2, 3, 1)
	if !ListMemberBy(FromInt64(2), xs, intEqual) {
		t.Error("member present")
	}
	if ListMemberBy(FromInt64(9), xs, intEqual) {
		t.Error("member absent")
	}
	if ListMemberBy(FromInt64(1), ints(), intEqual) {
		t.Error("member of empty")
	}
	// unique keeps the FIRST occurrence and preserves order.
	requireInts(t, "unique", ListUniqueBy(xs, intEqual), 1, 2, 3)
	requireInts(t, "unique empty", ListUniqueBy(ints(), intEqual))
}

// Stability is observable: equal keys must keep their original relative order.
func TestListSortByIsStable(t *testing.T) {
	requireInts(t, "sort", ListSortBy(ints(3, 1, 2), intLess), 1, 2, 3)
	requireInts(t, "sort empty", ListSortBy(ints(), intLess))

	type row struct {
		key   int64
		order int
	}
	rows := []row{{1, 0}, {0, 1}, {1, 2}, {0, 3}, {1, 4}}
	sorted := ListSortBy(rows, func(left, right row) bool { return left.key < right.key })
	want := []int{1, 3, 0, 2, 4}
	for index, expected := range want {
		if sorted[index].order != expected {
			t.Fatalf("stable sort: [%d] = %d, want %d", index, sorted[index].order, expected)
		}
	}
}

func TestListEqualByComparesElementwise(t *testing.T) {
	for _, row := range []struct {
		left, right []Int
		want        bool
	}{
		{ints(), ints(), true},
		{ints(1, 2), ints(1, 2), true},
		{ints(1, 2), ints(2, 1), false},
		{ints(1), ints(1, 2), false},
		{ints(1, 2), ints(1), false},
		{ints(), ints(1), false},
	} {
		if got := ListEqualBy(row.left, row.right, intEqual); got != row.want {
			t.Errorf("ListEqualBy(%v, %v) = %v, want %v", row.left, row.right, got, row.want)
		}
	}
}

// Racket's string-split with #:trim? #f keeps empties and does not collapse runs.
func TestStringSplitAndJoin(t *testing.T) {
	for _, row := range []struct {
		s, sep string
		want   []string
	}{
		{"a,b,c", ",", []string{"a", "b", "c"}},
		{"", ",", []string{""}},
		{"a,,b", ",", []string{"a", "", "b"}},
		{",a", ",", []string{"", "a"}},
		{"a,", ",", []string{"a", ""}},
		{"abc", ",", []string{"abc"}},
		{"雪だるま", "だ", []string{"雪", "るま"}},
	} {
		got := StringSplit(row.s, row.sep)
		if len(got) != len(row.want) {
			t.Errorf("StringSplit(%q, %q) = %q, want %q", row.s, row.sep, got, row.want)
			continue
		}
		for index := range row.want {
			if got[index] != row.want[index] {
				t.Errorf("StringSplit(%q, %q) = %q, want %q", row.s, row.sep, got, row.want)
				break
			}
		}
	}
	if got := StringJoin([]string{"a", "b"}, "-"); got != "a-b" {
		t.Errorf("StringJoin = %q", got)
	}
	if got := StringJoin(nil, "-"); got != "" {
		t.Errorf("StringJoin(nil) = %q", got)
	}
}

func TestListRange(t *testing.T) {
	toInts := func(xs []Int) []int64 {
		out := make([]int64, len(xs))
		for index, value := range xs {
			v, _ := value.Int64()
			out[index] = v
		}
		return out
	}
	// start inclusive, end exclusive — and empty rather than reversed when start >= end.
	for _, row := range []struct {
		start, end int64
		want       []int64
	}{
		{1, 5, []int64{1, 2, 3, 4}},
		{0, 1, []int64{0}},
		{3, 3, []int64{}},
		{5, 1, []int64{}},
		{-2, 2, []int64{-2, -1, 0, 1}},
	} {
		got := toInts(ListRange(FromInt64(row.start), FromInt64(row.end)))
		if len(got) != len(row.want) {
			t.Fatalf("ListRange(%d, %d) = %v, want %v", row.start, row.end, got, row.want)
		}
		for index := range got {
			if got[index] != row.want[index] {
				t.Errorf("ListRange(%d, %d) = %v, want %v", row.start, row.end, got, row.want)
				break
			}
		}
	}
}

func TestListRepeat(t *testing.T) {
	got := ListRepeat("x", FromInt64(3))
	if len(got) != 3 || got[0] != "x" || got[2] != "x" {
		t.Errorf("ListRepeat(x, 3) = %v", got)
	}
	if len(ListRepeat("x", FromInt64(0))) != 0 {
		t.Error("ListRepeat(x, 0) must be empty")
	}
	// The IsNonNegative proof is discharged by the frontend; this is containment.
	func() {
		defer func() {
			if recover() == nil {
				t.Error("a negative count must panic")
			}
		}()
		ListRepeat("x", FromInt64(-1))
	}()
	// A count no allocation could satisfy is reported, not truncated.
	func() {
		defer func() {
			if recover() == nil {
				t.Error("an unallocatable count must panic")
			}
		}()
		ListRepeat("x", MustParseDecimal("99999999999999999999"))
	}()
}

// The element cap must be a recoverable panic decided BEFORE `make`, not an out-of-memory
// kill inside it: 1<<31 Ints was 32 GiB, which the allocator refuses fatally rather than
// the runtime refusing cleanly. Both constructors share exactCount, so both are pinned.
func TestListConstructorsRefuseOversizedCountsBeforeAllocating(t *testing.T) {
	if maxAllocElements > 1<<26 {
		t.Fatalf("maxAllocElements = %d; must stay small enough to refuse rather than OOM", maxAllocElements)
	}
	overCap := FromInt64(int64(maxAllocElements) + 1)
	for name, build := range map[string]func(){
		"List.repeat": func() { ListRepeat("x", overCap) },
		"List.range":  func() { ListRange(FromInt64(0), overCap) },
	} {
		started := time.Now()
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("%s over the cap must panic", name)
				}
			}()
			build()
		}()
		if elapsed := time.Since(started); elapsed > 10*time.Millisecond {
			t.Errorf("%s over the cap took %v; the refusal must precede any allocation", name, elapsed)
		}
	}
}

func TestListConcat(t *testing.T) {
	got := ListConcat([][]int{{1, 2}, {}, {3}})
	want := []int{1, 2, 3}
	if len(got) != len(want) {
		t.Fatalf("ListConcat = %v, want %v", got, want)
	}
	for index := range got {
		if got[index] != want[index] {
			t.Errorf("ListConcat = %v, want %v", got, want)
			break
		}
	}
	if len(ListConcat([][]int{})) != 0 {
		t.Error("concat of no lists is empty")
	}
	if len(ListConcat([][]int{{}, {}})) != 0 {
		t.Error("concat of empty lists is empty")
	}
	// A writer: the result must not alias either input's array.
	first := []int{1, 2}
	out := ListConcat([][]int{first, {3}})
	out[0] = 99
	if first[0] != 1 {
		t.Error("ListConcat must not alias its input")
	}
}

func TestListMaximumMinimum(t *testing.T) {
	less := func(a, b int) bool { return a < b }
	if ListMaximum([]int{}, less).Tag != MaybeNothing {
		t.Error("maximum of the empty list is Nothing")
	}
	if ListMinimum([]int{}, less).Tag != MaybeNothing {
		t.Error("minimum of the empty list is Nothing")
	}
	if got := ListMaximum([]int{3, 9, 2}, less); got.Tag != MaybeSomething || got.SomethingValue != 9 {
		t.Errorf("maximum = %v", got)
	}
	if got := ListMinimum([]int{3, 9, 2}, less); got.Tag != MaybeSomething || got.SomethingValue != 2 {
		t.Errorf("minimum = %v", got)
	}
	if got := ListMaximum([]int{7}, less); got.SomethingValue != 7 {
		t.Errorf("single element = %v", got)
	}
}

// ── `List.unique`: the keyed path answers exactly what the closure path answers ──
//
// The keyed form is an optimisation, so the property that matters is that it is not also a
// behaviour change. Every element type the emitter can key gets checked BOTH ways here, and the
// two must agree on the value AND the order (first occurrence wins, order preserved).

func TestListUniqueKeyedAgreesWithTheClosurePath(t *testing.T) {
	strings := []string{"b", "a", "b", "c", "a", ""}
	if got, want := ListUniqueKeyed(strings, func(s string) string { return s }),
		ListUniqueBy(strings, func(a, b string) bool { return a == b }); !slicesEqual(got, want) {
		t.Errorf("String: keyed %v, closure %v", got, want)
	}

	bools := []bool{true, false, true, true}
	if got, want := ListUniqueKeyed(bools, func(b bool) bool { return b }),
		ListUniqueBy(bools, func(a, b bool) bool { return a == b }); !slicesEqual(got, want) {
		t.Errorf("Bool: keyed %v, closure %v", got, want)
	}

	ints := []Int{FromInt64(3), FromInt64(1), FromInt64(3), MustParseDecimal("99999999999999999999"),
		FromInt64(1), MustParseDecimal("99999999999999999999")}
	keyed := ListUniqueKeyed(ints, func(n Int) IntKey { return n.Key() })
	closure := ListUniqueBy(ints, Equal)
	if len(keyed) != len(closure) {
		t.Fatalf("Int: keyed %v, closure %v", keyed, closure)
	}
	for index := range keyed {
		if !Equal(keyed[index], closure[index]) {
			t.Errorf("Int at %d: keyed %v, closure %v", index, keyed[index], closure[index])
		}
	}
}

// Float is where a naive key would change the answer: the language makes every NaN equal to every
// other and -0.0 distinct from +0.0, which is the opposite of what `float64` as a map key does on
// both counts.
func TestListUniqueKeyedMatchesFloatEquality(t *testing.T) {
	nan := math.NaN()
	otherNaN := math.Float64frombits(math.Float64bits(nan) | 0x3) // a different NaN payload
	negativeZero := math.Copysign(0, -1)
	values := []float64{1.5, nan, negativeZero, 0, nan, otherNaN, 1.5, negativeZero}

	keyed := ListUniqueKeyed(values, FloatKey)
	closure := ListUniqueBy(values, FloatEqual)
	if len(keyed) != len(closure) {
		t.Fatalf("keyed %v, closure %v", keyed, closure)
	}
	for index := range keyed {
		if !FloatEqual(keyed[index], closure[index]) {
			t.Errorf("at %d: keyed %v, closure %v", index, keyed[index], closure[index])
		}
	}
	// Spelled out, because this is the case a raw-bits key would get wrong: one NaN survives, and
	// BOTH zeros do.
	if len(keyed) != 4 {
		t.Errorf("keyed = %v, want [1.5 NaN -0 0]", keyed)
	}
	if !math.IsNaN(keyed[1]) {
		t.Errorf("the second unique value is %v, want a NaN", keyed[1])
	}
	if !math.Signbit(keyed[2]) || math.Signbit(keyed[3]) {
		t.Errorf("the zeros did not survive as two values: %v", keyed)
	}
}

// FloatKey's contract, directly: equal keys iff FloatEqual.
func TestFloatKeyMatchesFloatEqual(t *testing.T) {
	nan := math.NaN()
	otherNaN := math.Float64frombits(math.Float64bits(nan) | 0x7)
	negativeZero := math.Copysign(0, -1)
	corpus := []float64{0, negativeZero, 1, -1, 1.5, math.Inf(1), math.Inf(-1), nan, otherNaN,
		math.MaxFloat64, math.SmallestNonzeroFloat64}
	for _, left := range corpus {
		for _, right := range corpus {
			if (FloatKey(left) == FloatKey(right)) != FloatEqual(left, right) {
				t.Errorf("FloatKey disagrees with FloatEqual on (%v, %v)", left, right)
			}
		}
	}
}

// The keyed path preserves ORDER, which is the half a map could plausibly lose.
func TestListUniqueKeyedPreservesFirstOccurrenceOrder(t *testing.T) {
	input := []string{"z", "y", "z", "x", "y", "w"}
	got := ListUniqueKeyed(input, func(s string) string { return s })
	want := []string{"z", "y", "x", "w"}
	if !slicesEqual(got, want) {
		t.Errorf("ListUniqueKeyed = %v, want %v", got, want)
	}
}

// The input value is untouched: a writer works in its own array.
func TestListUniqueKeyedDoesNotWriteItsInput(t *testing.T) {
	input := []string{"b", "a", "b"}
	_ = ListUniqueKeyed(input, func(s string) string { return s })
	if !slicesEqual(input, []string{"b", "a", "b"}) {
		t.Errorf("the input was rewritten to %v", input)
	}
}

func slicesEqual[T comparable](left, right []T) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}
