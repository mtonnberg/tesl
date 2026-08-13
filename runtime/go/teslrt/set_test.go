package teslrt

import "testing"

func setOf(values ...int64) Set[Int] {
	return SetFromList(ints(values...), intLess)
}

func requireSet(t *testing.T, label string, got Set[Int], want ...int64) {
	t.Helper()
	requireInts(t, label, SetToList(got), want...)
}

// Elements are stored sorted and deduplicated, which is what makes every operation
// below a single ordered pass rather than n lookups.
func TestSetFromListSortsAndDeduplicates(t *testing.T) {
	requireSet(t, "fromList", setOf(3, 1, 2, 1, 3), 1, 2, 3)
	requireSet(t, "fromList empty", setOf())
	requireSet(t, "singleton", SetSingleton(FromInt64(7)), 7)
	if !SetIsEmpty(SetEmpty[Int]()) || !Equal(SetSize(setOf(1, 2)), FromInt64(2)) {
		t.Error("size/isEmpty")
	}
}

func TestSetMembershipAndWrites(t *testing.T) {
	base := setOf(1, 3)
	if !SetMember(FromInt64(3), base, intLess) || SetMember(FromInt64(2), base, intLess) {
		t.Error("member")
	}
	requireSet(t, "insert middle", SetInsert(FromInt64(2), base, intLess), 1, 2, 3)
	requireSet(t, "insert low", SetInsert(FromInt64(0), base, intLess), 0, 1, 3)
	requireSet(t, "insert high", SetInsert(FromInt64(9), base, intLess), 1, 3, 9)
	// Inserting a present element changes nothing — a set has no duplicates.
	requireSet(t, "insert duplicate", SetInsert(FromInt64(3), base, intLess), 1, 3)
	requireSet(t, "remove", SetRemove(FromInt64(1), base, intLess), 3)
	requireSet(t, "remove missing", SetRemove(FromInt64(5), base, intLess), 1, 3)
	// Immutability: every write leaves the original alone.
	requireSet(t, "base after writes", base, 1, 3)
}

// A returned list must not share storage with the set, or appending to it would edit
// the set — the same rule list.go states for slices.
func TestSetToListDoesNotShareStorage(t *testing.T) {
	base := setOf(1, 2, 3)
	list := SetToList(base)
	list[0] = FromInt64(99)
	requireSet(t, "base after mutating the list", base, 1, 2, 3)
}

func TestSetAlgebra(t *testing.T) {
	left, right := setOf(1, 2, 3), setOf(3, 4)
	requireSet(t, "union", SetUnion(left, right, intLess), 1, 2, 3, 4)
	requireSet(t, "intersection", SetIntersection(left, right, intLess), 3)
	requireSet(t, "difference", SetDifference(left, right, intLess), 1, 2)
	requireSet(t, "reverse difference", SetDifference(right, left, intLess), 4)
	// Disjoint and empty operands are the cases a merge loop gets wrong.
	requireSet(t, "disjoint union", SetUnion(setOf(1), setOf(2), intLess), 1, 2)
	requireSet(t, "disjoint intersection", SetIntersection(setOf(1), setOf(2), intLess))
	requireSet(t, "union with empty", SetUnion(left, setOf(), intLess), 1, 2, 3)
	requireSet(t, "intersection with empty", SetIntersection(left, setOf(), intLess))
	requireSet(t, "difference with empty", SetDifference(left, setOf(), intLess), 1, 2, 3)
	requireSet(t, "empty minus", SetDifference(setOf(), left, intLess))
	// Operands must survive: these are reads.
	requireSet(t, "left after algebra", left, 1, 2, 3)
	requireSet(t, "right after algebra", right, 3, 4)
}

func TestSetIsSubset(t *testing.T) {
	for _, row := range []struct {
		left, right Set[Int]
		want        bool
	}{
		{setOf(), setOf(), true},
		{setOf(), setOf(1), true},
		{setOf(1), setOf(), false},
		{setOf(1, 2), setOf(1, 2, 3), true},
		{setOf(1, 3), setOf(1, 2), false},
		{setOf(2), setOf(1, 2, 3), true},
		{setOf(0), setOf(1, 2), false},
		{setOf(4), setOf(1, 2), false},
	} {
		if got := SetIsSubset(row.left, row.right, intLess); got != row.want {
			t.Errorf("SetIsSubset(%v, %v) = %v, want %v",
				SetToList(row.left), SetToList(row.right), got, row.want)
		}
	}
}

func TestSetEqualBy(t *testing.T) {
	intEq := func(left, right Int) bool { return Equal(left, right) }
	for _, row := range []struct {
		left, right Set[Int]
		want        bool
	}{
		{setOf(), setOf(), true},
		{setOf(1, 2), setOf(2, 1), true},
		{setOf(1, 2), setOf(1), false},
		{setOf(1), setOf(2), false},
	} {
		if got := SetEqualBy(row.left, row.right, intEq); got != row.want {
			t.Errorf("SetEqualBy(%v, %v) = %v, want %v",
				SetToList(row.left), SetToList(row.right), got, row.want)
		}
	}
}
