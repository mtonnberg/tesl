package teslrt

import (
	"fmt"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

func insertManyPanic(body func()) (caught any) {
	defer func() { caught = recover() }()
	body()
	return
}

func insertManyIndexes() ([]UniqueIndex[row], []InsertIndex[row]) {
	title := UniqueIndexOf("Row", []string{"title"}, nil,
		func(a, b row) bool { return a.Title == b.Title }, func(r row) string { return "(" + r.Title + ")" })
	size := UniqueIndexOf("Row", []string{"size"}, nil,
		func(a, b row) bool { return Equal(a.Size, b.Size) }, func(r row) string { return "(" + r.Size.String() + ")" })
	return []UniqueIndex[row]{title, size}, []InsertIndex[row]{
		InsertIndexOf(title, InsertKeyOf(func(r row) string { return r.Title })),
		InsertIndexOf(size, InsertKeyOf(func(r row) IntKey { return r.Size.Key() })),
	}
}

// A failing batch's unused suffix forces the public hash path without changing
// the prefix/error being tested. Never use this for a successful operation.
func keyedFailureBatch[T any](rows []T) []T {
	return append(rows, make([]T, tableInsertManyScanLimit+1)...)
}

func keyedSuccessBatch(prefix string) []row {
	rows := make([]row, tableInsertManyScanLimit+1)
	for i := range rows {
		rows[i] = row{ID: fmt.Sprintf("%s%d", prefix, i), Title: fmt.Sprintf("%s%d", prefix, i), Size: FromInt64(int64(1000 + i))}
	}
	return rows
}

func TestTableInsertManyKeyedMatchesSequentialFailures(t *testing.T) {
	initial := row{ID: "1", Title: "used", Size: FromInt64(1)}
	prefix := row{ID: "2", Title: "new", Size: FromInt64(2)}
	legacy, keyed := insertManyIndexes()
	primary := InsertKeyOf(func(r row) string { return r.ID })
	for _, tc := range []struct {
		name string
		rows []row
		want string
	}{
		{"empty", nil, ""},
		{"singleton success", []row{prefix}, ""},
		{"success", []row{prefix, {ID: "3", Title: "third", Size: FromInt64(3)}}, ""},
		{"existing primary", []row{{ID: "1", Title: "different", Size: FromInt64(3)}, prefix}, "insert: entity Row already contains a row with that primary key"},
		{"batch primary", []row{prefix, {ID: "2", Title: "different", Size: FromInt64(3)}}, "insert: entity Row already contains a row with that primary key"},
		{"existing unique", []row{prefix, {ID: "3", Title: "used", Size: FromInt64(3)}}, "entity Row already contains a row with (title) = (used); the declared unique index on (title) forbids duplicates"},
		{"batch unique", []row{prefix, {ID: "3", Title: "new", Size: FromInt64(3)}}, "entity Row already contains a row with (title) = (new); the declared unique index on (title) forbids duplicates"},
		{"all violations", []row{prefix, initial}, "entity Row already contains a row with (title) = (used); the declared unique index on (title) forbids duplicates"},
		{"second unique before primary", []row{{ID: "1", Title: "different", Size: FromInt64(1)}, prefix}, "entity Row already contains a row with (size) = (1); the declared unique index on (size) forbids duplicates"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if tc.want != "" {
				tc.rows = keyedFailureBatch(tc.rows)
			} else if tc.name == "success" {
				tc.rows = append(tc.rows, keyedSuccessBatch("success")...)
			}
			old, fast := NewTable[row](), NewTable[row]()
			TableInsert(old, "Row", initial, sameID, legacy...)
			TableInsert(fast, "Row", initial, sameID, legacy...)
			snapshot, _ := fast.snapshot()
			a := insertManyPanic(func() { TableInsertMany(old, "Row", tc.rows, sameID, legacy...) })
			b := insertManyPanic(func() { TableInsertManyKeyed(fast, "Row", tc.rows, sameID, primary, keyed...) })
			if !reflect.DeepEqual(a, b) || (tc.want != "" && b != tc.want) || (tc.want == "" && b != nil) {
				t.Fatalf("legacy=%v keyed=%v want=%q", a, b, tc.want)
			}
			if !reflect.DeepEqual(old.rows, fast.rows) || old.version != fast.version {
				t.Fatalf("publication differs: legacy=%+v/%d keyed=%+v/%d", old.rows, old.version, fast.rows, fast.version)
			}
			if len(snapshot) != 1 || snapshot[0].ID != "1" {
				t.Fatal("old snapshot changed")
			}
		})
	}
}

func TestTableInsertManyKeyedNullableStructuredKeys(t *testing.T) {
	type item struct {
		ID int
		A  Maybe[string]
		B  string
		C  bool
	}
	type key struct {
		A, B string
		C    bool
	}
	index := UniqueIndexOf("Item", []string{"a", "b", "c"}, func(r item) bool { return r.A.IsSomething() },
		func(a, b item) bool {
			return a.A.IsSomething() && b.A.IsSomething() && a.A.SomethingValue == b.A.SomethingValue && a.B == b.B && a.C == b.C
		},
		func(r item) string { return fmt.Sprintf("(%s %s %v)", r.A.SomethingValue, r.B, r.C) })
	project := InsertKeyOf(func(r item) key {
		if !r.A.IsSomething() {
			panic("projected NULL")
		}
		return key{r.A.SomethingValue, r.B, r.C}
	})
	table := NewTable[item]()
	primary := InsertKeyOf(func(r item) int { return r.ID })
	conflicts := func(a, b item) bool { return a.ID == b.ID }
	constraint := InsertIndexOf(index, project)
	rows := []item{{1, Nothing[string](), "x", false}, {2, Nothing[string](), "x", false},
		{3, Something("a b"), "c", false}, {4, Something("a"), "b c", false},
		{5, Something("a"), "b c", true}}
	for i := range tableInsertManyScanLimit {
		rows = append(rows, item{ID: 100 + i, A: Nothing[string](), B: "x"})
	}
	TableInsertManyKeyed(table, "Item", rows[:2], conflicts, primary, constraint)
	TableInsertManyKeyed(table, "Item", rows[2:], conflicts, primary, constraint)
	if len(table.rows) != len(rows) {
		t.Fatal("NULL exemption, structured collision or Bool key lost")
	}
	err := insertManyPanic(func() {
		TableInsertManyKeyed(table, "Item", keyedFailureBatch([]item{{6, Something("a"), "b c", false}}), conflicts, primary, constraint)
	})
	if err != "entity Item already contains a row with (a b c) = (a b c false); the declared unique index on (a, b, c) forbids duplicates" {
		t.Fatalf("wrong composite error: %v", err)
	}
}

func TestTableInsertManyKeyedRollbackAndReinsert(t *testing.T) {
	table := NewTable[row]()
	primary := InsertKeyOf(func(r row) string { return r.ID })
	_, indexes := insertManyIndexes()
	initial := row{ID: "1", Title: "old", Size: FromInt64(1)}
	newRow := row{ID: "2", Title: "new", Size: FromInt64(2)}
	another := row{ID: "4", Title: "fourth", Size: FromInt64(4)}
	batch := append([]row{newRow, another}, keyedSuccessBatch("new")...)
	TableInsert(table, "Row", initial, sameID)
	var uncommitted []row
	err := insertManyPanic(func() {
		WithMemoryTransaction(func() {
			TableInsertManyKeyed(table, "Row", batch, sameID, primary, indexes...)
			uncommitted, _ = table.snapshot()
			TableInsertManyKeyed(table, "Row", keyedFailureBatch([]row{{ID: "3", Title: "other", Size: FromInt64(3)}, initial}), sameID, primary, indexes...)
		})
	})
	if err == nil || !reflect.DeepEqual(table.rows, []row{initial}) {
		t.Fatalf("rollback failed: %v %+v", err, table.rows)
	}
	WithMemoryTransaction(func() { TableInsertManyKeyed(table, "Row", batch, sameID, primary, indexes...) })
	wantRows := append([]row{initial}, batch...)
	if !reflect.DeepEqual(table.rows, wantRows) || !reflect.DeepEqual(uncommitted, wantRows) {
		t.Fatal("reinsertion or immutable uncommitted snapshot failed")
	}
	TableUpdate(table, func(r row) bool { return r.ID == newRow.ID }, func(r row) row {
		r.Title = "changed after rollback and reinsertion"
		return r
	})
	if !reflect.DeepEqual(uncommitted, wantRows) {
		t.Fatal("later write changed an uncommitted snapshot retained across rollback")
	}
	version := table.version
	insertManyPanic(func() {
		WithMemoryTransaction(func() {
			TableInsertManyKeyed(table, "Row", keyedFailureBatch([]row{initial}), sameID, primary, indexes...)
		})
	})
	if table.version != version {
		t.Fatal("refused first row recorded rollback/publication")
	}
}

func TestTableInsertManyKeyedConcurrentBatches(t *testing.T) {
	table := NewTable[row]()
	primary := InsertKeyOf(func(r row) string { return r.ID })
	var workers sync.WaitGroup
	for worker := range 8 {
		workers.Go(func() {
			rows := make([]row, 100)
			for i := range rows {
				rows[i].ID = fmt.Sprintf("%d/%d", worker, i)
			}
			TableInsertManyKeyed(table, "Row", rows, sameID, primary)
			TableSelect(table, every)
		})
	}
	workers.Wait()
	if len(table.rows) != 800 || table.version != 800 {
		t.Fatalf("lost publication: %d/%d", len(table.rows), table.version)
	}
	var successes int
	var mutex sync.Mutex
	for range 8 {
		workers.Go(func() {
			err := insertManyPanic(func() { TableInsertManyKeyed(table, "Row", keyedSuccessBatch("shared"), sameID, primary) })
			if err == nil {
				mutex.Lock()
				successes++
				mutex.Unlock()
			}
		})
	}
	workers.Wait()
	if successes != 1 || len(table.rows) != 800+tableInsertManyScanLimit+1 {
		t.Fatalf("duplicate publication: successes=%d rows=%d", successes, len(table.rows))
	}
}

func TestTableInsertManyLegacyCallbackEvaluation(t *testing.T) {
	table := NewTable[row]()
	var calls []string
	index := UniqueIndexOf("Row", []string{"title"}, func(r row) bool {
		calls = append(calls, "constrained:"+r.ID)
		return true
	}, func(a, b row) bool {
		calls = append(calls, "unique:"+a.ID+b.ID)
		return false
	}, func(row) string { panic("unexpected describe") })
	TableInsertMany(table, "Row", []row{{ID: "1"}, {ID: "2"}, {ID: "3"}}, func(a, b row) bool {
		calls = append(calls, "primary:"+a.ID+b.ID)
		return false
	}, index)
	want := "constrained:1,constrained:2,unique:12,primary:12,constrained:3,unique:13,unique:23,primary:13,primary:23"
	if strings.Join(calls, ",") != want {
		t.Fatalf("legacy callback order/count changed: %v", calls)
	}
}

func TestBoundDatabaseKeyedInsertManyKeepsSQLFailures(t *testing.T) {
	database := liveDatabase(t)
	table := NewTable[dbBook]()
	primary := InsertKeyOf(func(dbBook) string { t.Fatal("PostgreSQL evaluated a Memory key"); return "" })
	rows := []dbBook{{ID: "a", Title: "first", Pages: FromInt64(1)}, {ID: "b", Title: "second", Pages: FromInt64(2)}, {ID: "a", Title: "duplicate", Pages: FromInt64(3)}}
	WithDatabase(database, func() {
		for _, transaction := range []bool{false, true} {
			DbTruncate(database, table, "books")
			bound := []string{}
			body := func() {
				DbInsertManyKeyed(database, table, "Book", rows, bookConflicts, primary,
					`insert into "teslgotest"."books" (id,title,pages) values ($1,$2,$3)`,
					func(book dbBook) []any {
						bound = append(bound, book.ID)
						return []any{book.ID, book.Title, PgInt(book.Pages)}
					})
			}
			failure := insertManyPanic(func() {
				if transaction {
					WithTransaction(body)
				} else {
					body()
				}
			})
			if failure == nil || !reflect.DeepEqual(bound, []string{"a", "b", "a"}) {
				t.Fatal("SQL failure or binder order changed", transaction, failure, bound)
			}
			stored := DbSelect(database, table, allBooks, nil, 0, -1,
				PgSql(`select id,title,pages from "teslgotest"."books" order by id`, nil), scanDbBook)
			want := rows[:2]
			if transaction {
				want = []dbBook{}
			}
			if len(stored) != len(want) || len(want) > 0 && !reflect.DeepEqual(stored, want) {
				t.Fatal("SQL partial-publication/rollback changed", transaction, stored, want)
			}
			if len(table.rows) != 0 {
				t.Fatal("PostgreSQL modified Memory table")
			}
		}
	})
}

func TestTableInsertManyKeyedSmallBatchDoesNotProject(t *testing.T) {
	table := NewTable[row]()
	legacy, keyed := insertManyIndexes()
	primary := InsertKeyOf(func(row) string { panic("singleton projected primary") })
	for i := range keyed {
		keyed[i].key = InsertKeyOf(func(row) string { panic("singleton projected unique") })
	}
	initial := row{ID: "1", Title: "one", Size: FromInt64(1)}
	TableInsertManyKeyed(table, "Row", nil, sameID, primary, keyed...)
	TableInsertManyKeyed(table, "Row", []row{initial}, sameID, primary, keyed...)
	old := NewTable[row]()
	TableInsert(old, "Row", initial, sameID, legacy...)
	a := insertManyPanic(func() { TableInsertMany(old, "Row", []row{initial}, sameID, legacy...) })
	b := insertManyPanic(func() { TableInsertManyKeyed(table, "Row", []row{initial}, sameID, primary, keyed...) })
	if a == nil || a != b || table.version != 1 {
		t.Fatalf("singleton fallback changed failure/publication: %v / %v / %d", a, b, table.version)
	}
	TableInsertManyKeyed(table, "Row", keyedSuccessBatch("small")[:tableInsertManyScanLimit], sameID, primary, keyed...)
	if table.version != 1+tableInsertManyScanLimit {
		t.Fatal("small-batch publication count changed")
	}
}

func TestTableInsertManyKeyedUnboundDispatch(t *testing.T) {
	for _, versioned := range []bool{false, true} {
		t.Run(fmt.Sprintf("versioned=%v", versioned), func(t *testing.T) {
			table := NewTable[row]()
			primary := InsertKeyOf(func(r row) string { return r.ID })
			rows := keyedSuccessBatch("dispatch")
			database := &Database{}
			insert := func(batch []row) {
				if versioned {
					DbRowInsertManyKeyed(NewPgRowAccessSlot[row](), database, table, "Row", batch, sameID, primary)
				} else {
					DbInsertManyKeyed(database, table, "Row", batch, sameID, primary, "unused",
						func(row) []any { panic("PostgreSQL binder evaluated on Memory path") })
				}
			}
			WithMemoryTransaction(func() { insert(rows) })
			if len(table.rows) != len(rows) {
				t.Fatal("unbound dispatch failed to publish keyed batch")
			}
			err := insertManyPanic(func() {
				WithMemoryTransaction(func() { insert(keyedFailureBatch([]row{{ID: "new"}, rows[0]})) })
			})
			if err == nil || !reflect.DeepEqual(table.rows, rows) {
				t.Fatalf("dispatch rollback: %v %+v", err, table.rows)
			}
		})
	}
}

func TestTableInsertManyKeyedCaughtFailureInTransaction(t *testing.T) {
	for _, rollback := range []bool{false, true} {
		t.Run(fmt.Sprintf("rollback=%v", rollback), func(t *testing.T) {
			table := NewTable[row]()
			primary := InsertKeyOf(func(r row) string { return r.ID })
			initial := row{ID: "original"}
			TableInsert(table, "Row", initial, sameID)
			var own []row
			failure := insertManyPanic(func() {
				WithMemoryTransaction(func() {
					// First-row refusal must not register rollback or publish anything.
					err := insertManyPanic(func() {
						TableInsertManyKeyed(table, "Row", keyedFailureBatch([]row{initial}), sameID, primary)
					})
					transaction := currentMemoryTransaction()
					if err == nil || table.version != 1 || transaction == nil || len(transaction.recorded) != 0 {
						t.Fatal("refused first row changed transaction state")
					}
					err = insertManyPanic(func() {
						TableInsertManyKeyed(table, "Row", keyedFailureBatch([]row{{ID: "prefix"}, initial}), sameID, primary)
					})
					if err == nil {
						t.Fatal("missing duplicate")
					}
					own, _ = table.snapshot()
					if len(own) != 2 || own[1].ID != "prefix" {
						t.Fatal("caught failure lost own prefix")
					}
					TableInsertManyKeyed(table, "Row", keyedSuccessBatch("later"), sameID, primary)
					if rollback {
						panic("rollback after caught failure")
					}
				})
			})
			want := 2 + tableInsertManyScanLimit + 1
			if rollback {
				want = 1
			}
			if (failure != nil) != rollback || len(table.rows) != want || len(own) != 2 || own[1].ID != "prefix" {
				t.Fatalf("caught failure commit/rollback/snapshot: %v %+v %+v", failure, table.rows, own)
			}
		})
	}
}

func TestTableInsertManyKeyedTransactionExcludesReadersAndWriters(t *testing.T) {
	for _, rollback := range []bool{false, true} {
		t.Run(fmt.Sprintf("rollback=%v", rollback), func(t *testing.T) {
			table := NewTable[row]()
			primary := InsertKeyOf(func(r row) string { return r.ID })
			TableInsert(table, "Row", row{ID: "original"}, sameID)
			before, _ := table.snapshot()
			published, finish, done := make(chan struct{}), make(chan struct{}), make(chan any, 1)
			go func() {
				done <- insertManyPanic(func() {
					WithMemoryTransaction(func() {
						TableInsertManyKeyed(table, "Row", keyedSuccessBatch("tx"), sameID, primary)
						close(published)
						<-finish
						if rollback {
							panic("rollback")
						}
					})
				})
			}()
			<-published
			readStarted, writeStarted := make(chan struct{}), make(chan struct{})
			readDone, writeDone := make(chan []row, 1), make(chan struct{})
			go func() {
				close(readStarted)
				readDone <- TableSelect(table, every)
			}()
			go func() {
				close(writeStarted)
				TableInsertManyKeyed(table, "Row", keyedSuccessBatch("outside"), sameID, primary)
				close(writeDone)
			}()
			<-readStarted
			<-writeStarted
			var earlyRead []row
			earlyWrite := false
			select {
			case earlyRead = <-readDone:
			case <-writeDone:
				earlyWrite = true
			case <-time.After(25 * time.Millisecond):
			}
			close(finish)
			failure := <-done
			<-writeDone
			if earlyRead != nil || earlyWrite {
				t.Fatal("outside operation crossed open transaction")
			}
			observed := <-readDone
			hasTx := false
			for _, r := range observed {
				hasTx = hasTx || r.ID == "tx1"
			}
			want := 1 + 2*(tableInsertManyScanLimit+1)
			if rollback {
				want = 1 + tableInsertManyScanLimit + 1
			}
			if (failure != nil) != rollback || hasTx == rollback || len(table.rows) != want || len(before) != 1 || before[0].ID != "original" {
				t.Fatalf("isolation/rollback/snapshot: failure=%v observed=%+v final=%+v before=%+v", failure, observed, table.rows, before)
			}
		})
	}
}

// Dataset and spare backing storage are prepared outside timing. Each iteration
// starts at exactly the same published length; map setup remains inside timing.
func BenchmarkMemoryInsertManySmall(b *testing.B) {
	for _, existingCount := range []int{0, 8000} {
		for _, n := range []int{1, 2, 8, 32, 64} {
			all := make([]row, existingCount+n)
			for i := range all {
				all[i] = row{ID: fmt.Sprintf("id%06d", i), Title: fmt.Sprintf("v%06d", i)}
			}
			incoming := append([]row(nil), all[existingCount:]...)
			legacy, keyed := insertManyIndexes()
			primary := InsertKeyOf(func(r row) string { return r.ID })
			for _, fast := range []bool{false, true} {
				b.Run(fmt.Sprintf("existing=%d/n=%d/keyed=%v", existingCount, n, fast), func(b *testing.B) {
					b.ReportAllocs()
					for b.Loop() {
						table := &Table[row]{rows: all[:existingCount]}
						if fast {
							TableInsertManyKeyed(table, "Row", incoming, sameID, primary, keyed[0])
						} else {
							TableInsertMany(table, "Row", incoming, sameID, legacy[0])
						}
					}
				})
			}
		}
	}
}

func BenchmarkMemoryInsertManySingletonInt(b *testing.B) {
	rows := make([]row, 8001)
	for i := range rows {
		value, err := ParseDecimal(fmt.Sprintf("184467440737095516160%06d", i))
		if err != nil {
			b.Fatal(err)
		}
		rows[i].Size = value
	}
	incoming := []row{rows[8000]}
	conflicts := func(a, b row) bool { return Equal(a.Size, b.Size) }
	primary := InsertKeyOf(func(r row) IntKey { return r.Size.Key() })
	for _, fast := range []bool{false, true} {
		b.Run(fmt.Sprintf("keyed=%v", fast), func(b *testing.B) {
			b.ReportAllocs()
			for b.Loop() {
				table := &Table[row]{rows: rows[:8000]}
				if fast {
					TableInsertManyKeyed(table, "Row", incoming, conflicts, primary)
				} else {
					TableInsertMany(table, "Row", incoming, conflicts)
				}
			}
		})
	}
}

func TestTableInsertManyKeyedLargeFirstRowRefusalDoesNotProject(t *testing.T) {
	stored := make([]row, 16384)
	for i := range stored {
		stored[i] = row{ID: fmt.Sprint(i), Title: fmt.Sprint(i)}
	}
	primary := InsertKeyOf(func(row) string { panic("refused batch projected primary") })
	legacy, keyed := insertManyIndexes()
	keyed[0].key = InsertKeyOf(func(row) string { panic("refused batch projected unique") })
	for _, unique := range []bool{false, true} {
		t.Run(fmt.Sprintf("unique=%v", unique), func(t *testing.T) {
			old, fast := &Table[row]{rows: stored, version: 7}, &Table[row]{rows: stored, version: 7}
			var indexes []UniqueIndex[row]
			var keys []InsertIndex[row]
			if unique {
				indexes, keys = legacy[:1], keyed[:1]
			}
			batch := keyedFailureBatch([]row{stored[0]})
			want := insertManyPanic(func() { TableInsertMany(old, "Row", batch, sameID, indexes...) })
			WithMemoryTransaction(func() {
				got := insertManyPanic(func() { TableInsertManyKeyed(fast, "Row", batch, sameID, primary, keys...) })
				if got != want || got == nil {
					t.Fatalf("refusal changed: got %v want %v", got, want)
				}
				if len(currentMemoryTransaction().recorded) != 0 {
					t.Fatal("refused batch registered rollback")
				}
			})
			if fast.version != 7 || !reflect.DeepEqual(fast.rows, stored) {
				t.Fatal("refused batch published rows")
			}
		})
	}
}

type nullableInsertRow struct {
	ID    int
	Value Maybe[string]
}

func nullableInsertFixture(existing int) ([]nullableInsertRow, []nullableInsertRow) {
	all := make([]nullableInsertRow, existing+64)
	for i := range all {
		all[i] = nullableInsertRow{ID: i, Value: Nothing[string]()}
	}
	return all[:existing], append([]nullableInsertRow(nil), all[existing:]...)
}

func nullableInsertConstraint(constrained func(nullableInsertRow) bool, project func(nullableInsertRow) string) InsertIndex[nullableInsertRow] {
	return InsertIndexOf(UniqueIndexOf("Nullable", []string{"value"}, constrained,
		func(a, b nullableInsertRow) bool {
			return a.Value.IsSomething() && b.Value.IsSomething() && a.Value.SomethingValue == b.Value.SomethingValue
		}, func(r nullableInsertRow) string { return "(" + r.Value.SomethingValue + ")" }), InsertKeyOf(project))
}

func TestTableInsertManyKeyedAllNullResourceUse(t *testing.T) {
	primary := InsertKeyOf(func(r nullableInsertRow) int { return r.ID })
	conflicts := func(a, b nullableInsertRow) bool { return a.ID == b.ID }
	for _, existing := range []int{64, 16384} {
		t.Run(fmt.Sprintf("existing=%d", existing), func(t *testing.T) {
			stored, incoming := nullableInsertFixture(existing)
			checks := 0
			constraint := nullableInsertConstraint(func(r nullableInsertRow) bool {
				checks++
				return r.Value.IsSomething()
			}, func(nullableInsertRow) string { panic("projected NULL") })
			table := &Table[nullableInsertRow]{rows: stored}
			TableInsertManyKeyed(table, "Nullable", incoming, conflicts, primary, constraint)
			// First-row legacy validation and indexing each evaluate its exemption;
			// every other stored/incoming row needs only one evaluation.
			if checks > existing+len(incoming)+1 || table.version != uint64(len(incoming)) {
				t.Fatalf("redundant checks or publication: checks=%d version=%d", checks, table.version)
			}
			if !reflect.DeepEqual(table.rows[existing:], incoming) {
				t.Fatal("NULL rows lost during insertion")
			}
			measure := func(indexes ...InsertIndex[nullableInsertRow]) float64 {
				return testing.AllocsPerRun(3, func() {
					table := &Table[nullableInsertRow]{rows: stored}
					TableInsertManyKeyed(table, "Nullable", incoming, conflicts, primary, indexes...)
				})
			}
			// Allow fixed per-call metadata; an exempt unique index must not allocate
			// table-sized map storage. Compare against the identical primary map work.
			without, with := measure(), measure(constraint)
			if with-without > 8 {
				t.Fatalf("NULL index allocations scale with table: without=%g with=%g", without, with)
			}
		})
	}
}

func TestTableInsertManyKeyedNullableMapStartsWithIncomingKey(t *testing.T) {
	stored, incoming := nullableInsertFixture(64)
	incoming[1].Value = Something("new")
	incoming[2].Value = Something("new")
	constraint := nullableInsertConstraint(func(r nullableInsertRow) bool { return r.Value.IsSomething() },
		func(r nullableInsertRow) string { return r.Value.SomethingValue })
	primary := InsertKeyOf(func(r nullableInsertRow) int { return r.ID })
	conflicts := func(a, b nullableInsertRow) bool { return a.ID == b.ID }
	old, fast := &Table[nullableInsertRow]{rows: stored}, &Table[nullableInsertRow]{rows: stored}
	a := insertManyPanic(func() { TableInsertMany(old, "Nullable", incoming, conflicts, constraint.index) })
	b := insertManyPanic(func() { TableInsertManyKeyed(fast, "Nullable", incoming, conflicts, primary, constraint) })
	if a == nil || a != b || fast.version != 2 || !reflect.DeepEqual(old.rows, fast.rows) {
		t.Fatalf("lazy incoming index changed prefix/failure: legacy=%v keyed=%v version=%d", a, b, fast.version)
	}
}

func BenchmarkMemoryInsertManyAllNull(b *testing.B) {
	primary := InsertKeyOf(func(r nullableInsertRow) int { return r.ID })
	conflicts := func(a, b nullableInsertRow) bool { return a.ID == b.ID }
	constraint := nullableInsertConstraint(func(r nullableInsertRow) bool { return r.Value.IsSomething() },
		func(nullableInsertRow) string { panic("projected NULL") })
	for _, existing := range []int{64, 16384} {
		stored, incoming := nullableInsertFixture(existing)
		for _, indexed := range []bool{false, true} {
			b.Run(fmt.Sprintf("existing=%d/nullable=%v", existing, indexed), func(b *testing.B) {
				var indexes []InsertIndex[nullableInsertRow]
				if indexed {
					indexes = []InsertIndex[nullableInsertRow]{constraint}
				}
				b.ReportAllocs()
				for b.Loop() {
					table := &Table[nullableInsertRow]{rows: stored}
					TableInsertManyKeyed(table, "Nullable", incoming, conflicts, primary, indexes...)
				}
			})
		}
	}
}

func BenchmarkMemoryInsertManyRefusedExisting(b *testing.B) {
	primary := InsertKeyOf(func(r row) string { return r.ID })
	_, keyed := insertManyIndexes()
	for _, existing := range []int{1, 16384} {
		stored := make([]row, existing)
		for i := range stored {
			stored[i] = row{ID: fmt.Sprint(i), Title: fmt.Sprint(i)}
		}
		batch := keyedFailureBatch([]row{stored[0]})
		b.Run(fmt.Sprintf("existing=%d", existing), func(b *testing.B) {
			table := &Table[row]{rows: stored}
			b.ReportAllocs()
			for b.Loop() {
				if insertManyPanic(func() { TableInsertManyKeyed(table, "Row", batch, sameID, primary, keyed[0]) }) == nil {
					b.Fatal("expected first-row refusal")
				}
			}
		})
	}
}

func BenchmarkMemoryInsertManyRefusedSuffix(b *testing.B) {
	initial := row{ID: "duplicate", Title: "duplicate"}
	legacy, keyed := insertManyIndexes()
	primary := InsertKeyOf(func(r row) string { return r.ID })
	for _, size := range []int{64, 100000} {
		rows := make([]row, size)
		rows[0] = initial
		b.Run(fmt.Sprintf("incoming=%d", size), func(b *testing.B) {
			table := NewTable[row]()
			TableInsert(table, "Row", initial, sameID, legacy[0])
			b.ReportAllocs()
			for b.Loop() {
				if insertManyPanic(func() { TableInsertManyKeyed(table, "Row", rows, sameID, primary, keyed[0]) }) == nil {
					b.Fatal("expected first-row refusal")
				}
			}
		})
	}
}

func BenchmarkMemoryInsertMany(b *testing.B) {
	for _, n := range []int{1000, 8000} {
		rows := make([]row, n)
		for i := range rows {
			rows[i] = row{ID: fmt.Sprintf("id%06d", i), Title: fmt.Sprintf("v%06d", i)}
		}
		legacy, keyed := insertManyIndexes()
		primary := InsertKeyOf(func(r row) string { return r.ID })
		for _, transaction := range []bool{false, true} {
			for _, fast := range []bool{false, true} {
				b.Run(fmt.Sprintf("n=%d/tx=%v/keyed=%v", n, transaction, fast), func(b *testing.B) {
					b.ReportAllocs()
					for b.Loop() {
						table := NewTable[row]()
						body := func() {
							if fast {
								TableInsertManyKeyed(table, "Row", rows, sameID, primary, keyed[0])
							} else {
								TableInsertMany(table, "Row", rows, sameID, legacy[0])
							}
						}
						if transaction {
							WithMemoryTransaction(body)
						} else {
							body()
						}
					}
				})
			}
		}
	}
}
