package teslrt

import (
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
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
		// `\` is the escape, as on the server: `\%` and `\_` are the literal characters and
		// `\\` a literal backslash. Without it a pattern could not name a percent sign at all.
		{"alpha%x", "alpha\\%%", false, true},
		{"alphax", "alpha\\%%", false, false},
		{"100%", "100\\%", false, true},
		{"1000", "100\\%", false, false},
		{"a_b", "a\\_b", false, true},
		{"axb", "a\\_b", false, false},
		{"axb", "a_b", false, true},
		{"a\\b", "a\\\\b", false, true},
		{"a\\b", "a\\\\%", false, true},
		{"ab", "a\\\\b", false, false},
		// An escaped ordinary character is that character.
		{"abc", "a\\bc", false, true},
		{"A%", "a\\%", true, true},
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

// `deleteAndReturnResult` draws the distinction a count does not: deleting nothing is a
// different OUTCOME from deleting rows, and the caller reads it as a case.
func TestTableDeleteResult(t *testing.T) {
	table := NewTable[string]()
	never := func(string, string) bool { return false }
	TableInsert(table, "Note", "a", never)
	TableInsert(table, "Note", "b", never)

	missed := TableDeleteResult(table, func(row string) bool { return row == "zz" })
	if missed.Tag != DeleteResultNoRowDeleted {
		t.Fatalf("a delete that matched nothing answered %+v", missed)
	}
	removed := TableDeleteResult(table, func(row string) bool { return row == "a" })
	if removed.Tag != DeleteResultRowsDeleted || !Equal(removed.RowsDeletedCount, FromInt64(1)) {
		t.Fatalf("a delete that removed one row answered %+v", removed)
	}
	if got := TableCount(table, func(string) bool { return true }); !Equal(got, FromInt64(1)) {
		t.Fatalf("%s rows remain", got.String())
	}
}

// `updateAndReturnOne` names ONE row. Two matches used to update the first and answer it,
// while Postgres updated both — a disagreement between the store tests run on and the store
// production runs on. Both now trap before changing anything.
func TestTableUpdateReturnOneRefusesAnAmbiguousPredicate(t *testing.T) {
	table := NewTable[row]()
	TableInsert(table, "Row", row{ID: "1", Title: "one", Size: FromInt64(1)}, sameID)
	TableInsert(table, "Row", row{ID: "2", Title: "two", Size: FromInt64(1)}, sameID)
	sizeOne := func(r row) bool { return Equal(r.Size, FromInt64(1)) }
	func() {
		defer func() {
			recovered := recover()
			if recovered == nil {
				t.Fatal("updateAndReturnOne over two matching rows must trap")
			}
			if recovered != updateReturnOneAmbiguous {
				t.Fatalf("trap = %v", recovered)
			}
		}()
		TableUpdateReturnOne(table, sizeOne, func(r row) row { r.Title = "edited"; return r })
	}()
	for _, stored := range TableSelect(table, func(row) bool { return true }) {
		if stored.Title == "edited" {
			t.Fatalf("a row was updated before the ambiguity was detected: %+v", stored)
		}
	}
}

// A pattern ending in a lone escape is the server's error, so the Memory store refuses it the
// same way rather than matching something.
func TestSqlLikeRefusesATrailingEscape(t *testing.T) {
	defer func() {
		if recovered := recover(); recovered == nil ||
			!strings.Contains(fmt.Sprint(recovered), "must not end with escape character") {
			t.Fatalf("trailing escape answered %v", recovered)
		}
	}()
	SqlLike("abc", "abc\\", false)
}

// completesWithin runs `work` and fails the test if it has not returned in time — which is how
// a deadlock shows up as a failure rather than as a hung test binary.
func completesWithin(t *testing.T, limit time.Duration, what string, work func()) {
	t.Helper()
	done := make(chan struct{})
	go func() {
		defer close(done)
		work()
	}()
	select {
	case <-done:
	case <-time.After(limit):
		t.Fatalf("%s did not complete within %v: the Memory store deadlocked", what, limit)
	}
}

// `update … set price = (selectCount …)` on the SAME table: the set value queries the table the
// update holds. Under the old model `apply` ran under the write lock and the nested count took
// the read lock — a wedge with no timeout. Now both `match` and `apply` run on a snapshot with
// no lock held.
func TestTableUpdateSetValueMayQueryTheSameTable(t *testing.T) {
	table := NewTable[row]()
	for _, id := range []string{"a", "b", "c"} {
		TableInsert(table, "Row", row{ID: id, Size: FromInt64(1)}, sameID)
	}
	completesWithin(t, 3*time.Second, "an update whose set value counts the same table", func() {
		TableUpdate(table, every, func(r row) row {
			r.Size = TableCount(table, every)
			return r
		})
	})
	for _, r := range TableSelect(table, every) {
		if !Equal(r.Size, FromInt64(3)) {
			t.Fatalf("row %s has size %s, expected the count 3", r.ID, r.Size.String())
		}
	}
	// The same shape through updateAndReturnOne and through a delete whose predicate queries.
	completesWithin(t, 3*time.Second, "updateAndReturnOne whose set value counts the table", func() {
		got := TableUpdateReturnOne(table, byID("a"), func(r row) row {
			r.Size = Add(TableCount(table, every), FromInt64(10))
			return r
		})
		if !Equal(got.Size, FromInt64(13)) {
			t.Errorf("updateAndReturnOne answered size %s", got.Size.String())
		}
	})
	completesWithin(t, 3*time.Second, "a delete whose predicate selects from the table", func() {
		TableDelete(table, func(r row) bool {
			return len(TableSelect(table, byID(r.ID))) == 1 && r.ID == "b"
		})
	})
	if remaining := TableSelect(table, every); len(remaining) != 2 {
		t.Fatalf("delete left %d rows", len(remaining))
	}
}

// A `where` operand that queries the same table, under a writer that keeps inserting: with
// the predicate evaluated under the read lock, the queued writer blocked every NEW reader —
// including the nested one — so the outer select could never finish. The predicate now runs on
// a snapshot, and the writer's appends never touch what the snapshot sees.
func TestTableSelectWithNestedQueryCompletesUnderAConcurrentWriter(t *testing.T) {
	table := NewTable[row]()
	for index := range 50 {
		TableInsert(table, "Row", row{ID: fmt.Sprint("seed-", index), Size: FromInt64(1)}, sameID)
	}
	stop := make(chan struct{})
	var writerDone sync.WaitGroup
	writerDone.Add(1)
	go func() {
		defer writerDone.Done()
		for counter := 0; ; counter++ {
			select {
			case <-stop:
				return
			default:
			}
			// Insert then delete, so the table churns (every write bumps the version) without
			// growing — the test is about locking, not about the size of the scan.
			id := fmt.Sprint("w-", counter)
			TableInsert(table, "Row", row{ID: id}, func(row, row) bool { return false })
			TableDelete(table, byID(id))
		}
	}()
	var evaluated atomic.Int64
	completesWithin(t, 5*time.Second, "a select whose predicate selects from the same table", func() {
		for range 20 {
			matched := TableSelect(table, func(r row) bool {
				evaluated.Add(1)
				return len(TableSelect(table, byID(r.ID))) > 0 && strings.HasPrefix(r.ID, "seed-")
			})
			if len(matched) != 50 {
				t.Errorf("nested select found %d seed rows, expected 50", len(matched))
			}
			_ = TableCount(table, func(r row) bool { return TableAny(table, byID(r.ID)) })
		}
	})
	close(stop)
	writerDone.Wait()
	if evaluated.Load() < 1000 {
		t.Fatalf("the predicate ran %d times, expected at least 20 × 50", evaluated.Load())
	}
}

// Evaluating `apply` off the lock must not LOSE writes: two updaters incrementing one row race
// to publish, and the one whose snapshot went stale has to recompute rather than overwrite. The
// version check is what makes the final count the sum of every increment.
func TestTableUpdateRetriesInsteadOfLosingAConcurrentWrite(t *testing.T) {
	table := NewTable[row]()
	TableInsert(table, "Row", row{ID: "counter", Size: FromInt64(0)}, sameID)
	const writers, increments = 8, 200
	var wait sync.WaitGroup
	for range writers {
		wait.Add(1)
		go func() {
			defer wait.Done()
			for range increments {
				TableUpdate(table, byID("counter"), func(r row) row {
					r.Size = Add(r.Size, FromInt64(1))
					return r
				})
			}
		}()
	}
	// Inserts and deletes of OTHER rows change the version too, so an updater must also
	// survive the table growing and shrinking under it without misplacing its replacement.
	wait.Add(1)
	go func() {
		defer wait.Done()
		for index := range increments {
			id := fmt.Sprint("noise-", index)
			TableInsert(table, "Row", row{ID: id}, sameID)
			TableDelete(table, byID(id))
		}
	}()
	wait.Wait()
	got := TableSelectOne(table, byID("counter"))
	if !got.IsSomething() || !Equal(got.SomethingValue.Size, FromInt64(writers*increments)) {
		t.Fatalf("counter = %+v, expected %d", got, writers*increments)
	}
	if rows := TableSelect(table, every); len(rows) != 1 {
		t.Fatalf("%d rows remain, expected the counter alone", len(rows))
	}
}

// The unique-index check runs under the write lock against the rows actually being published,
// so two concurrent updates cannot both move onto the same indexed value.
func TestTableUpdateUniqueCheckHoldsUnderConcurrency(t *testing.T) {
	table := NewTable[row]()
	for _, id := range []string{"a", "b"} {
		TableInsert(table, "Row", row{ID: id, Title: id}, sameID)
	}
	index := UniqueIndexOf("Row", []string{"title"}, nil,
		func(left, right row) bool { return left.Title == right.Title },
		func(r row) string { return "(" + r.Title + ")" })
	var wait sync.WaitGroup
	var refused atomic.Int64
	for _, id := range []string{"a", "b"} {
		wait.Add(1)
		go func() {
			defer wait.Done()
			defer func() {
				if recover() != nil {
					refused.Add(1)
				}
			}()
			TableUpdate(table, byID(id), func(r row) row {
				r.Title = "same"
				return r
			}, index)
		}()
	}
	wait.Wait()
	titled := TableCount(table, func(r row) bool { return r.Title == "same" })
	if !Equal(titled, FromInt64(1)) || refused.Load() != 1 {
		t.Fatalf("%s rows carry the title and %d updates were refused; expected 1 and 1",
			titled.String(), refused.Load())
	}
}
