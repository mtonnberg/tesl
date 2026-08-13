package teslrt

import "testing"

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
