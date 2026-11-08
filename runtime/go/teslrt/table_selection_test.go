package teslrt

import (
	"fmt"
	"math/rand"
	"reflect"
	"slices"
	"sync"
	"testing"
	"time"
)

type selectionRow struct{ ID, Key int }

func FuzzTableBoundedSelection(f *testing.F) {
	f.Add([]byte{}, uint16(0), uint8(1), false)
	f.Add([]byte{9, 3, 8, 3, 1, 7, 4, 2, 6, 8, 0, 5, 1, 9, 2, 7, 4, 6, 1, 3}, uint16(1), uint8(2), true)
	f.Fuzz(func(t *testing.T, data []byte, offset uint16, rawLimit uint8, descending bool) {
		if len(data) > 1024 {
			data = data[:1024]
		}
		rows := make([]selectionRow, len(data))
		for index, key := range data {
			rows[index] = selectionRow{ID: len(data) - index, Key: int(key)%13 - 6}
		}
		table := &Table[selectionRow]{rows: rows}
		match := func(row selectionRow) bool { return row.Key%3 != 0 }
		less := func(a, b selectionRow) bool {
			if descending {
				return a.Key > b.Key
			}
			return a.Key < b.Key
		}
		limit := int(rawLimit)
		if rawLimit == 255 {
			limit = -1
		}
		want := TableSelectSorted(table, match, less, int(offset), limit)
		if got := TableSelectTop(table, match, less, int(offset), limit); !reflect.DeepEqual(got, want) {
			t.Fatal("bounded ordering differs from stable reference", got, want)
		}
		want = sliceRange(TableSelect(table, match), int(offset), limit)
		if got := TableSelectRange(table, match, int(offset), limit); !reflect.DeepEqual(got, want) {
			t.Fatal("bounded range differs from reference", got, want)
		}
	})
}

func TestTableBoundedSelectionMatchesStableReference(t *testing.T) {
	rng := rand.New(rand.NewSource(6381)) // #nosec G404 -- deterministic regression data
	for _, size := range []int{0, 1, 2, 3, 8, 31, 128, 513} {
		rows := make([]selectionRow, size)
		ids := rng.Perm(size)
		for index := range rows {
			rows[index] = selectionRow{ID: ids[index], Key: rng.Intn(9) - 4}
		}
		original := slices.Clone(rows)
		table := &Table[selectionRow]{rows: rows}
		for _, descending := range []bool{false, true} {
			less := func(a, b selectionRow) bool {
				if descending {
					return a.Key > b.Key
				}
				return a.Key < b.Key
			}
			for _, divisor := range []int{1, 3, 1000} {
				match := func(row selectionRow) bool { return row.ID%divisor == 0 }
				for _, offset := range []int{0, 1, 5, size / 2, size, size + 3, int(^uint(0) >> 1)} {
					for _, limit := range []int{-1, 0, 1, 2, 7, size / 2, size, int(^uint(0) >> 1)} {
						want := TableSelectSorted(table, match, less, offset, limit)
						got := TableSelectTop(table, match, less, offset, limit)
						if !reflect.DeepEqual(got, want) {
							t.Fatalf("top size=%d desc=%t divisor=%d offset=%d limit=%d: got %v want %v", size, descending, divisor, offset, limit, got, want)
						}
						want = sliceRange(TableSelect(table, match), offset, limit)
						got = TableSelectRange(table, match, offset, limit)
						if !reflect.DeepEqual(got, want) {
							t.Fatalf("range size=%d offset=%d limit=%d: got %v want %v", size, offset, limit, got, want)
						}
						if limit >= 0 && cap(got) > limit {
							t.Fatal("bounded range retains an oversized result buffer", cap(got), limit)
						}
					}
				}
				if got, want := TableSelectOneTop(table, match, less), TableSelectOneSorted(table, match, less); got != want {
					t.Fatal("ordered selectOne differs", got, want)
				}
			}
		}
		if !reflect.DeepEqual(rows, original) && size != 0 {
			t.Fatal("selection mutated published table storage")
		}
	}
}

func TestTableTopOneUsesLinearComparisons(t *testing.T) {
	rows := make([]selectionRow, 10000)
	for index := range rows {
		rows[index] = selectionRow{ID: len(rows) - index, Key: (index*48271 + 17) % 100003}
	}
	table := &Table[selectionRow]{rows: rows}
	match := func(row selectionRow) bool { return row.ID%2 == 0 }
	comparisons := 0
	got := TableSelectOneTop(table, match, func(a, b selectionRow) bool { comparisons++; return a.Key < b.Key })
	want := TableSelectOneSorted(table, match, func(a, b selectionRow) bool { return a.Key < b.Key })
	if got != want || comparisons == 0 || comparisons > len(rows) {
		t.Fatal("ordered selectOne changed result or regained full-sort work", got, want, comparisons)
	}
}

func TestMemoryTopDispatchDoesNotEvaluateSQL(t *testing.T) {
	rows := make([]selectionRow, 100)
	for index := range rows {
		rows[index] = selectionRow{ID: index, Key: 100 - index}
	}
	table, database := &Table[selectionRow]{rows: rows}, &Database{}
	match := func(selectionRow) bool { return true }
	less := func(a, b selectionRow) bool { return a.Key < b.Key }
	arguments := func() []any { t.Fatal("Memory path evaluated SQL operands"); return nil }
	plan := PgSql("must not execute", arguments)
	query := PgRowQuery{args: arguments}
	want := []selectionRow{{99, 1}, {98, 2}, {97, 3}}
	if got := DbSelectTop(database, table, match, less, 0, 3, plan, nil); !reflect.DeepEqual(got, want) {
		t.Fatal("ordinary dispatcher changed Memory rows", got)
	}
	if got := DbRowSelectTop(nil, database, table, match, less, 0, 3, query); !reflect.DeepEqual(got, want) {
		t.Fatal("versioned dispatcher changed Memory rows", got)
	}
	if got := DbSelectOneTop(database, table, match, less, plan, nil); got != Something(want[0]) {
		t.Fatal("ordinary selectOne dispatcher changed Memory row", got)
	}
	if got := DbRowSelectOneTop(nil, database, table, match, less, query); got != Something(want[0]) {
		t.Fatal("versioned selectOne dispatcher changed Memory row", got)
	}
}

func TestTableBoundedNegativeOffsetKeepsFailureOrder(t *testing.T) {
	table := &Table[selectionRow]{rows: []selectionRow{{0, 1}, {1, 0}}}
	for _, ordered := range []bool{false, true} {
		seen := 0
		var failure any
		func() {
			defer func() { failure = recover() }()
			match := func(selectionRow) bool { seen++; return true }
			if ordered {
				TableSelectTop(table, match, func(a, b selectionRow) bool { return a.Key < b.Key }, -1, 1)
			} else {
				TableSelectRange(table, match, -1, 1)
			}
		}()
		if failure == nil || seen != 2 {
			t.Fatal("negative offset no longer fails after evaluating predicates", seen, failure)
		}
	}
}

func TestTableBoundedSelectionKeepsPredicateEffectsAndFailures(t *testing.T) {
	for _, ordered := range []bool{false, true} {
		for _, limit := range []int{0, 1, 4} {
			t.Run(fmt.Sprintf("ordered=%t/limit=%d", ordered, limit), func(t *testing.T) {
				table := &Table[selectionRow]{rows: []selectionRow{{0, 3}, {1, 2}, {2, 1}, {3, 0}}}
				var seen []int
				compared := false
				match := func(row selectionRow) bool {
					seen = append(seen, row.ID)
					if row.ID == 3 {
						panic("late predicate failure")
					}
					return true
				}
				less := func(a, b selectionRow) bool { compared = true; return a.Key < b.Key }
				var failure any
				func() {
					defer func() { failure = recover() }()
					if ordered {
						TableSelectTop(table, match, less, 0, limit)
					} else {
						TableSelectRange(table, match, 0, limit)
					}
				}()
				if failure != "late predicate failure" || !slices.Equal(seen, []int{0, 1, 2, 3}) || compared {
					t.Fatal("selection skipped/reordered predicates or compared before failure", seen, compared, failure)
				}
			})
		}
	}
}

func TestTableTopSnapshotReentrancyAndResultOwnership(t *testing.T) {
	rows := make([]selectionRow, 100)
	for index := range rows {
		rows[index] = selectionRow{ID: index, Key: 100 - index}
	}
	table := &Table[selectionRow]{rows: rows}
	seen := 0
	got := TableSelectTop(table, func(row selectionRow) bool {
		if seen == 0 {
			TableInsert(table, "selection", selectionRow{ID: 100, Key: -1}, func(a, b selectionRow) bool { return a.ID == b.ID })
		}
		if TableCount(table, func(selectionRow) bool { return true }).String() != "101" {
			t.Fatal("predicate cannot observe its own nested write")
		}
		seen++
		return true
	}, func(a, b selectionRow) bool {
		if seen != 100 {
			t.Fatal("comparison preceded predicate completion")
		}
		return a.Key < b.Key
	}, 0, 3)
	if !reflect.DeepEqual(got, []selectionRow{{99, 1}, {98, 2}, {97, 3}}) {
		t.Fatal("query abandoned its original snapshot", got)
	}
	got[0].Key = -1000
	stored := TableSelectOne(table, func(row selectionRow) bool { return row.ID == 99 })
	if stored.SomethingValue.Key != 1 {
		t.Fatal("result aliases stored rows")
	}
}

func TestTableBoundedSelectionsRespectTransactionRollback(t *testing.T) {
	for _, ordered := range []bool{false, true} {
		t.Run(fmt.Sprint(ordered), func(t *testing.T) {
			table := &Table[selectionRow]{rows: []selectionRow{{1, 1}}}
			ready, release, finished := make(chan struct{}), make(chan struct{}), make(chan struct{})
			resume := sync.OnceFunc(func() { close(release) })
			defer resume()
			go func() {
				defer close(finished)
				defer func() {
					if failure := recover(); failure != "rollback" {
						t.Errorf("unexpected transaction result: %v", failure)
					}
				}()
				WithMemoryTransaction(func() {
					TableUpdate(table, func(selectionRow) bool { return true }, func(row selectionRow) selectionRow { row.Key = -1; return row })
					close(ready)
					<-release
					panic("rollback")
				})
			}()
			<-ready
			started, result := make(chan struct{}), make(chan []selectionRow, 1)
			go func() {
				close(started)
				match := func(selectionRow) bool { return true }
				if ordered {
					result <- TableSelectTop(table, match, func(a, b selectionRow) bool { return a.Key < b.Key }, 0, 1)
				} else {
					result <- TableSelectRange(table, match, 0, 1)
				}
			}()
			<-started
			select {
			case rows := <-result:
				t.Fatal("reader crossed open transaction", rows)
			case <-time.After(30 * time.Millisecond):
			}
			resume()
			<-finished
			if rows := <-result; !reflect.DeepEqual(rows, []selectionRow{{1, 1}}) {
				t.Fatal("reader observed rolled-back data", rows)
			}
		})
	}
}
