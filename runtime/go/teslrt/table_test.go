package teslrt

import (
	"strings"
	"sync"
	"testing"
)

type row struct {
	ID    string
	Title string
	Size  Int
}

// The emitter always passes a primary-key comparison; these tests use the ID.
func sameID(existing, inserted row) bool { return existing.ID == inserted.ID }

func byID(id string) func(row) bool {
	return func(r row) bool { return r.ID == id }
}

func every(row) bool { return true }

func TestTableBasics(t *testing.T) {
	table := NewTable[row]()
	TableInsert(table, "Row", row{ID: "1", Title: "one"}, sameID)
	TableInsert(table, "Row", row{ID: "2", Title: "two"}, sameID)

	// selectOne yields Maybe: "no row" is a value, not an error.
	found := TableSelectOne(table, byID("2"))
	if found.Tag != MaybeSomething || found.SomethingValue.Title != "two" {
		t.Errorf("selectOne = %+v", found)
	}
	if missing := TableSelectOne(table, byID("nope")); missing.Tag != MaybeNothing {
		t.Errorf("a missing row must be Nothing, got %+v", missing)
	}
	if n := TableCount(table, byID("2")); n.String() != "1" {
		t.Errorf("count = %s", n.String())
	}
	TableUpdate(table, byID("1"), func(r row) row { r.Title = "edited"; return r })
	if got := TableSelectOne(table, byID("1")); got.SomethingValue.Title != "edited" {
		t.Errorf("update did not apply: %+v", got)
	}
	if n := TableDeleteCount(table, byID("2")); n.String() != "1" {
		t.Errorf("delete count = %s", n.String())
	}
	if n := TableCount(table, every); n.String() != "1" {
		t.Errorf("remaining = %s", n.String())
	}
}

// A duplicate primary key is an ERROR, as it is on the Racket memory backend — a table
// that accepted two rows with one key would answer selectOne differently there.
func TestTableInsertRejectsDuplicateKey(t *testing.T) {
	table := NewTable[row]()
	TableInsert(table, "Row", row{ID: "1"}, sameID)
	defer func() {
		recovered := recover()
		message, ok := recovered.(string)
		if !ok || !strings.Contains(message, "already contains a row") {
			t.Fatalf("expected a duplicate-key trap, got %v", recovered)
		}
	}()
	TableInsert(table, "Row", row{ID: "1"}, sameID)
}

// insertMany is a loop over insert, so a batch that conflicts with itself is caught too.
func TestTableInsertManyChecksWithinTheBatch(t *testing.T) {
	table := NewTable[row]()
	TableInsertMany(table, "Row", []row{{ID: "1"}, {ID: "2"}}, sameID)
	if n := TableCount(table, every); n.String() != "2" {
		t.Fatalf("count = %s", n.String())
	}
	defer func() {
		if recover() == nil {
			t.Fatal("expected a duplicate-key trap inside the batch")
		}
		// The rows inserted before the conflict stay: Racket inserts one at a time.
		if n := TableCount(table, every); n.String() != "3" {
			t.Errorf("count after the failed batch = %s", n.String())
		}
	}()
	TableInsertMany(table, "Row", []row{{ID: "3"}, {ID: "3"}}, sameID)
}

func TestTableOrderLimitOffset(t *testing.T) {
	table := NewTable[row]()
	for _, r := range []row{
		{ID: "a", Size: FromInt64(3)},
		{ID: "b", Size: FromInt64(1)},
		{ID: "c", Size: FromInt64(2)},
	} {
		TableInsert(table, "Row", r, sameID)
	}
	ascending := func(left, right row) bool { return Compare(left.Size, right.Size) < 0 }
	ids := func(rows []row) string {
		var out strings.Builder
		for _, r := range rows {
			out.WriteString(r.ID)
		}
		return out.String()
	}
	if got := ids(TableSelectSorted(table, every, ascending, 0, -1)); got != "bca" {
		t.Errorf("sorted = %s", got)
	}
	if got := ids(TableSelectSorted(table, every, ascending, 1, 1)); got != "c" {
		t.Errorf("sorted with offset+limit = %s", got)
	}
	// Un-ordered limit/offset keeps insertion order.
	if got := ids(TableSelectRange(table, every, 1, 5)); got != "bc" {
		t.Errorf("range = %s", got)
	}
	if got := ids(TableSelectRange(table, every, 9, -1)); got != "" {
		t.Errorf("range past the end = %s", got)
	}
	first := TableSelectOneSorted(table, every, ascending)
	if first.Tag != MaybeSomething || first.SomethingValue.ID != "b" {
		t.Errorf("selectOne ordered = %+v", first)
	}
	if empty := TableSelectOneSorted(NewTable[row](), every, ascending); empty.Tag != MaybeNothing {
		t.Errorf("selectOne ordered over no rows = %+v", empty)
	}
}

// An aggregate over no rows is the ZERO, which is what makes `selectSum` total: Tesl types
// it as the column type, not as a Maybe.
func TestTableFold(t *testing.T) {
	table := NewTable[row]()
	TableInsert(table, "Row", row{ID: "a", Size: FromInt64(3)}, sameID)
	TableInsert(table, "Row", row{ID: "b", Size: FromInt64(4)}, sameID)
	size := func(r row) Int { return r.Size }
	if got := TableFold(table, every, size, Add, FromInt64(0)); got.String() != "7" {
		t.Errorf("sum = %s", got.String())
	}
	if got := TableFold(table, byID("nope"), size, Add, FromInt64(0)); got.String() != "0" {
		t.Errorf("sum over no rows = %s", got.String())
	}
}

func TestTableUpdateReturnOne(t *testing.T) {
	table := NewTable[row]()
	TableInsert(table, "Row", row{ID: "1", Title: "one"}, sameID)
	updated := TableUpdateReturnOne(table, byID("1"), func(r row) row { r.Title = "edited"; return r })
	if updated.Title != "edited" {
		t.Errorf("updateAndReturnOne = %+v", updated)
	}
	defer func() {
		if recover() == nil {
			t.Fatal("updateAndReturnOne over no matching row must trap")
		}
	}()
	TableUpdateReturnOne(table, byID("nope"), func(r row) row { return r })
}

// A read must not hand back the table's own storage, and concurrent access must be safe:
// an HTTP server serves each request on its own goroutine, so two handlers touching one
// table race by construction. `go test -race` is what proves this.
func TestTableConcurrencyAndAliasing(t *testing.T) {
	table := NewTable[row]()
	var wait sync.WaitGroup
	for i := 0; i < 8; i++ {
		wait.Add(1)
		go func(n int) {
			defer wait.Done()
			TableInsert(table, "Row", row{ID: "x", Title: "t"}, func(row, row) bool { return false })
			_ = TableSelect(table, byID("x"))
		}(i)
	}
	wait.Wait()
	rows := TableSelect(table, every)
	if len(rows) != 8 {
		t.Fatalf("expected 8 rows, got %d", len(rows))
	}
	rows[0].Title = "mutated"
	again := TableSelect(table, every)
	if again[0].Title == "mutated" {
		t.Error("a read must not alias the table's storage")
	}
}

func TestSqlLike(t *testing.T) {
	cases := []struct {
		value, pattern string
		fold, want     bool
	}{
		{"widget", "widget", false, true},
		{"widget", "wid%", false, true},
		{"widget", "%get", false, true},
		{"widget", "%dg%", false, true},
		{"widget", "w_dget", false, true},
		{"widget", "w_dge", false, false},
		{"widget", "WID%", false, false},
		{"widget", "WID%", true, true},
		{"widget", "%", false, true},
		{"", "%", false, true},
		{"", "_", false, false},
		// A pattern is DATA: regex metacharacters match themselves.
		{"a.c", "a.c", false, true},
		{"abc", "a.c", false, false},
		{"a+b", "a+b", false, true},
		// Backtracking: the first `%` must give a character back.
		{"aaab", "%ab", false, true},
		{"aaa", "%ab", false, false},
	}
	for _, c := range cases {
		if got := SqlLike(c.value, c.pattern, c.fold); got != c.want {
			t.Errorf("SqlLike(%q, %q, %v) = %v", c.value, c.pattern, c.fold, got)
		}
	}
}

// MAX/MIN answer a Maybe: no matching row has no maximum, and there is no identity to fall
// back on the way `selectSum` has zero.
func TestTableExtreme(t *testing.T) {
	table := NewTable[row]()
	TableInsert(table, "Row", row{ID: "a", Size: FromInt64(3)}, sameID)
	TableInsert(table, "Row", row{ID: "b", Size: FromInt64(9)}, sameID)
	TableInsert(table, "Row", row{ID: "c", Size: FromInt64(5)}, sameID)
	size := func(r row) Int { return r.Size }
	bigger := func(left, right Int) bool { return Compare(left, right) > 0 }
	smaller := func(left, right Int) bool { return Compare(left, right) < 0 }

	biggest := TableExtreme(table, every, size, bigger)
	if biggest.Tag != MaybeSomething || biggest.SomethingValue.String() != "9" {
		t.Errorf("max = %+v", biggest)
	}
	smallest := TableExtreme(table, every, size, smaller)
	if smallest.Tag != MaybeSomething || smallest.SomethingValue.String() != "3" {
		t.Errorf("min = %+v", smallest)
	}
	if none := TableExtreme(table, byID("nope"), size, bigger); none.Tag != MaybeNothing {
		t.Errorf("max over no matching row = %+v", none)
	}
}
