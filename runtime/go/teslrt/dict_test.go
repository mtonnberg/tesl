package teslrt

import "testing"

func stringLess(left, right string) bool { return left < right }

func dictOf(pairs ...Tuple2[string, Int]) Dict[string, Int] {
	return DictFromList(pairs, stringLess)
}

func pair(key string, value int64) Tuple2[string, Int] {
	return Tuple2[string, Int]{Tuple2First: key, Tuple2Second: FromInt64(value)}
}

// Iteration order is the reason this representation exists: Go randomises map order
// per run, so a map-backed Dict would make the SAME binary print different output on
// different runs. Sorted order is deterministic across runs and backends.
func TestDictIteratesInKeyOrder(t *testing.T) {
	d := dictOf(pair("c", 3), pair("a", 1), pair("b", 2))
	keys := DictKeys(d)
	want := []string{"a", "b", "c"}
	for index := range want {
		if keys[index] != want[index] {
			t.Fatalf("keys = %v, want %v", keys, want)
		}
	}
	values := DictValues(d)
	for index, expected := range []int64{1, 2, 3} {
		if !Equal(values[index], FromInt64(expected)) {
			t.Fatalf("values[%d] = %s, want %d", index, values[index].String(), expected)
		}
	}
	entries := DictToList(d)
	if entries[0].Tuple2First != "a" || !Equal(entries[2].Tuple2Second, FromInt64(3)) {
		t.Fatalf("toList = %v", entries)
	}
}

func TestDictLookupAndMember(t *testing.T) {
	d := dictOf(pair("a", 1), pair("b", 2))
	value, ok := DictLookup(d, "b", stringLess).Value()
	if !ok || !Equal(value, FromInt64(2)) {
		t.Fatalf("lookup b = %s, %v", value.String(), ok)
	}
	if _, ok := DictLookup(d, "zz", stringLess).Value(); ok {
		t.Error("lookup of a missing key yielded a value")
	}
	if !DictMember(d, "a", stringLess) || DictMember(d, "zz", stringLess) {
		t.Error("member")
	}
	// An empty dict must be safe to search, not just non-nil.
	empty := DictEmpty[string, Int]()
	if _, ok := DictLookup(empty, "a", stringLess).Value(); ok {
		t.Error("lookup in an empty dict yielded a value")
	}
	if !DictIsEmpty(empty) || !Equal(DictSize(empty), FromInt64(0)) {
		t.Error("empty dict size")
	}
}

// A Dict is immutable, so a write must leave every earlier value untouched — the same
// rule list.go states for slices.
func TestDictWritesDoNotDisturbTheOriginal(t *testing.T) {
	original := dictOf(pair("a", 1), pair("b", 2))
	inserted := DictInsert(original, "c", FromInt64(3), stringLess)
	replaced := DictInsert(original, "a", FromInt64(99), stringLess)
	removed := DictRemove(original, "a", stringLess)

	if !Equal(DictSize(original), FromInt64(2)) {
		t.Fatalf("original size changed to %s", DictSize(original).String())
	}
	value, _ := DictLookup(original, "a", stringLess).Value()
	if !Equal(value, FromInt64(1)) {
		t.Fatalf("original a = %s, want 1", value.String())
	}
	if !Equal(DictSize(inserted), FromInt64(3)) {
		t.Errorf("inserted size = %s", DictSize(inserted).String())
	}
	replacedValue, _ := DictLookup(replaced, "a", stringLess).Value()
	if !Equal(replacedValue, FromInt64(99)) {
		t.Errorf("replace did not take: %s", replacedValue.String())
	}
	if !Equal(DictSize(replaced), FromInt64(2)) {
		t.Errorf("replace changed the size: %s", DictSize(replaced).String())
	}
	if DictMember(removed, "a", stringLess) {
		t.Error("remove did not take")
	}
	if !DictMember(original, "a", stringLess) {
		t.Error("remove disturbed the original")
	}
	// Removing a key that is not present returns an equivalent dict, not a panic.
	if !Equal(DictSize(DictRemove(original, "zz", stringLess)), FromInt64(2)) {
		t.Error("removing a missing key changed the size")
	}
}

// tesl/dict.rkt builds with `for/hash`, so LATER duplicates win.
func TestDictFromListLetsLaterDuplicatesWin(t *testing.T) {
	d := dictOf(pair("a", 1), pair("a", 2), pair("b", 3))
	value, _ := DictLookup(d, "a", stringLess).Value()
	if !Equal(value, FromInt64(2)) {
		t.Fatalf("a = %s, want 2 (later duplicate)", value.String())
	}
	if !Equal(DictSize(d), FromInt64(2)) {
		t.Fatalf("size = %s, want 2", DictSize(d).String())
	}
}

// Int keys are the case a Go map cannot express at all, since teslrt.Int is
// deliberately non-comparable.
func TestDictSupportsIntKeys(t *testing.T) {
	less := func(left, right Int) bool { return Compare(left, right) < 0 }
	d := DictEmpty[Int, string]()
	for _, row := range []struct {
		key   int64
		value string
	}{{3, "c"}, {1, "a"}, {2, "b"}} {
		d = DictInsert(d, FromInt64(row.key), row.value, less)
	}
	keys := DictKeys(d)
	for index, expected := range []int64{1, 2, 3} {
		if !Equal(keys[index], FromInt64(expected)) {
			t.Fatalf("keys[%d] = %s, want %d", index, keys[index].String(), expected)
		}
	}
	// A key beyond int64 must order correctly rather than wrap.
	huge := MustParseDecimal("99999999999999999999")
	d = DictInsert(d, huge, "huge", less)
	last := DictKeys(d)[len(DictKeys(d))-1]
	if !Equal(last, huge) {
		t.Fatalf("largest key = %s, want %s", last.String(), huge.String())
	}
}

func TestDictEqualByComparesInOnePass(t *testing.T) {
	intEq := func(left, right Int) bool { return Equal(left, right) }
	strEq := func(left, right string) bool { return left == right }
	for _, row := range []struct {
		left, right Dict[string, Int]
		want        bool
	}{
		{dictOf(), dictOf(), true},
		{dictOf(pair("a", 1)), dictOf(pair("a", 1)), true},
		{dictOf(pair("a", 1)), dictOf(pair("a", 2)), false},
		{dictOf(pair("a", 1)), dictOf(pair("b", 1)), false},
		{dictOf(pair("a", 1)), dictOf(pair("a", 1), pair("b", 2)), false},
		// Insertion order must not matter: both are stored sorted.
		{dictOf(pair("a", 1), pair("b", 2)), dictOf(pair("b", 2), pair("a", 1)), true},
	} {
		if got := DictEqualBy(row.left, row.right, strEq, intEq); got != row.want {
			t.Errorf("DictEqualBy(%v, %v) = %v, want %v",
				DictKeys(row.left), DictKeys(row.right), got, row.want)
		}
	}
}
