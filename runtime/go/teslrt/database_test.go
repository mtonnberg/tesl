package teslrt

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// The dispatch is the whole point of the file under test: the SAME query has to read the
// in-memory table when nothing is connected and the server when something is, and the two have
// to agree about what it answers. So every live test here runs its assertions twice — once
// unbound, once inside `WithDatabase` — rather than testing the server path alone.

type dbBook struct {
	ID    string
	Title string
	Pages Int
}

func scanDbBook(row pgx.CollectableRow) (dbBook, error) {
	book := dbBook{}
	pages := pgtype.Numeric{}
	if err := row.Scan(&book.ID, &book.Title, &pages); err != nil {
		return book, err
	}
	book.Pages = PgIntOf(pages)
	return book, nil
}

func bookConflicts(existing, inserted dbBook) bool { return existing.ID == inserted.ID }

func allBooks(dbBook) bool { return true }

// liveDatabase is the emitted shape: one `Database` value per declaration, holding what a
// connection needs and the tables the bootstrap creates.
func liveDatabase(t *testing.T) *Database {
	t.Helper()
	return &Database{
		Name:   "Library",
		Config: liveCluster(t),
		Tables: []PostgresTable{{
			Name: "books",
			Columns: []PostgresColumn{
				{Name: "id", Type: "TEXT", PrimaryKey: true},
				{Name: "title", Type: "TEXT"},
				{Name: "pages", Type: "NUMERIC"},
			},
		}},
	}
}

func bookPlan(database *Database, statement string, arguments ...any) PgPlan {
	return PgSql(strings.ReplaceAll(statement, "@books", `"teslgotest"."books"`),
		func() []any { return arguments })
}

// An unbound database reads the in-memory table, with no server involved at all — which is what
// lets a `test` block exercise a Postgres-backed entity on a machine with no cluster.
func TestUnboundDatabaseReadsTheMemoryTable(t *testing.T) {
	database := &Database{Name: "Library"}
	table := NewTable[dbBook]()
	DbInsert(database, table, "Book", dbBook{ID: "a", Title: "Alpha", Pages: FromInt64(10)},
		bookConflicts, "insert into nowhere", func(dbBook) []any { return nil })
	rows := DbSelect(database, table, allBooks, nil, 0, -1,
		PgSql("select from nowhere", nil), scanDbBook)
	if len(rows) != 1 || rows[0].Title != "Alpha" {
		t.Fatalf("the memory path answered %+v", rows)
	}
	if got := DbCount(database, table, allBooks, PgSql("count from nowhere", nil)); !Equal(got, FromInt64(1)) {
		t.Fatalf("count = %s", got.String())
	}
}

// The same four shapes, bound. Each is asserted against the memory answer for the same rows, so
// a divergence shows up as a disagreement rather than as a Go-only expectation.
func TestBoundDatabaseAgreesWithTheMemoryTable(t *testing.T) {
	database := liveDatabase(t)
	table := NewTable[dbBook]()
	WithDatabase(database, func() {
		DbTruncate(database, table, "books")

		insert := func(id, title string, pages int64) {
			DbInsert(database, table, "Book", dbBook{ID: id, Title: title, Pages: FromInt64(pages)},
				bookConflicts,
				`insert into "teslgotest"."books" ("id", "title", "pages") values ($1, $2, $3)`,
				func(book dbBook) []any { return []any{book.ID, book.Title, PgInt(book.Pages)} })
		}
		insert("a", "Alpha", 100)
		insert("b", "Beta", 220)
		insert("c", "Gamma", 220)

		rows := DbSelect(database, table, allBooks, nil, 0, -1,
			bookPlan(database, `select "id", "title", "pages" from @books order by "id" ASC`),
			scanDbBook)
		if len(rows) != 3 || rows[0].ID != "a" || rows[2].ID != "c" {
			t.Fatalf("select answered %+v", rows)
		}
		if !Equal(rows[1].Pages, FromInt64(220)) {
			t.Fatalf("pages came back as %s", rows[1].Pages.String())
		}

		one := DbSelectOne(database, table, func(book dbBook) bool { return book.ID == "b" }, nil,
			bookPlan(database, `select "id", "title", "pages" from @books where "id" = $1 limit 1`, "b"),
			scanDbBook)
		if !one.IsSomething() || one.SomethingValue.Title != "Beta" {
			t.Fatalf("selectOne answered %+v", one)
		}
		missing := DbSelectOne(database, table, func(book dbBook) bool { return book.ID == "zz" }, nil,
			bookPlan(database, `select "id", "title", "pages" from @books where "id" = $1 limit 1`, "zz"),
			scanDbBook)
		if missing.IsSomething() {
			t.Fatal("selectOne invented a row")
		}

		if got := DbCount(database, table, allBooks,
			bookPlan(database, `select count(*) from @books`)); !Equal(got, FromInt64(3)) {
			t.Fatalf("count = %s", got.String())
		}

		sum := DbSum(database, table, allBooks,
			func(book dbBook) Int { return book.Pages }, Add, FromInt64(0),
			bookPlan(database, `select coalesce(sum("pages"), 0) from @books`),
			func(row pgx.Row) (Int, error) {
				total := pgtype.Numeric{}
				err := row.Scan(&total)
				return PgIntOf(total), err
			})
		if !Equal(sum, FromInt64(540)) {
			t.Fatalf("sum = %s", sum.String())
		}

		biggest := DbExtreme(database, table, allBooks,
			func(book dbBook) Int { return book.Pages },
			func(left, right Int) bool { return Compare(left, right) > 0 },
			bookPlan(database, `select max("pages") from @books`),
			func(row pgx.Row) (Maybe[Int], error) {
				found := pgtype.Numeric{}
				if err := row.Scan(&found); err != nil {
					return Nothing[Int](), err
				}
				if !found.Valid {
					return Nothing[Int](), nil
				}
				return Something(PgIntOf(found)), nil
			})
		if !biggest.IsSomething() || !Equal(biggest.SomethingValue, FromInt64(220)) {
			t.Fatalf("max answered %+v", biggest)
		}

		DbUpdate(database, table, func(book dbBook) bool { return book.ID == "a" },
			func(book dbBook) dbBook { book.Title = "Alpha II"; return book },
			bookPlan(database, `update @books set "title" = $1 where "id" = $2`, "Alpha II", "a"))
		renamed := DbSelectOne(database, table, func(book dbBook) bool { return book.ID == "a" }, nil,
			bookPlan(database, `select "id", "title", "pages" from @books where "id" = $1 limit 1`, "a"),
			scanDbBook)
		if !renamed.IsSomething() || renamed.SomethingValue.Title != "Alpha II" {
			t.Fatalf("update left %+v", renamed)
		}

		DbDelete(database, table, func(book dbBook) bool { return book.ID == "c" },
			bookPlan(database, `delete from @books where "id" = $1`, "c"))
		if got := DbCount(database, table, allBooks,
			bookPlan(database, `select count(*) from @books`)); !Equal(got, FromInt64(2)) {
			t.Fatalf("count after delete = %s", got.String())
		}
	})
}

// An aggregate over NO rows: SQL answers NULL, and the two shapes disagree about what that
// means — a sum is zero, a max is Nothing. Both are asserted because a wrong one is silent.
func TestBoundAggregatesOverAnEmptyTable(t *testing.T) {
	database := liveDatabase(t)
	table := NewTable[dbBook]()
	WithDatabase(database, func() {
		DbTruncate(database, table, "books")
		sum := DbSum(database, table, allBooks,
			func(book dbBook) Int { return book.Pages }, Add, FromInt64(0),
			bookPlan(database, `select coalesce(sum("pages"), 0) from @books`),
			func(row pgx.Row) (Int, error) {
				total := pgtype.Numeric{}
				err := row.Scan(&total)
				return PgIntOf(total), err
			})
		if !Equal(sum, FromInt64(0)) {
			t.Fatalf("the empty sum is %s", sum.String())
		}
		biggest := DbExtreme(database, table, allBooks,
			func(book dbBook) Int { return book.Pages },
			func(left, right Int) bool { return Compare(left, right) > 0 },
			bookPlan(database, `select max("pages") from @books`),
			func(row pgx.Row) (Maybe[Int], error) {
				found := pgtype.Numeric{}
				if err := row.Scan(&found); err != nil {
					return Nothing[Int](), err
				}
				if !found.Valid {
					return Nothing[Int](), nil
				}
				return Something(PgIntOf(found)), nil
			})
		if biggest.IsSomething() {
			t.Fatalf("max over no rows answered %+v", biggest)
		}
	})
}

// The duplicate primary key is refused on both paths — the server's constraint on one, the
// emitted comparison on the other — which is what keeps the two backends agreeing about which
// programs run rather than only about what they answer.
func TestBoundInsertRefusesADuplicateKey(t *testing.T) {
	database := liveDatabase(t)
	table := NewTable[dbBook]()
	WithDatabase(database, func() {
		DbTruncate(database, table, "books")
		insert := func() {
			DbInsert(database, table, "Book", dbBook{ID: "a", Title: "Alpha", Pages: FromInt64(1)},
				bookConflicts,
				`insert into "teslgotest"."books" ("id", "title", "pages") values ($1, $2, $3)`,
				func(book dbBook) []any { return []any{book.ID, book.Title, PgInt(book.Pages)} })
		}
		insert()
		defer func() {
			if recover() == nil {
				t.Fatal("a duplicate primary key was accepted")
			}
		}()
		insert()
	})
}

// ── Transactions ─────────────────────────────────────────────────────────────

func TestTransactionOnAnUnboundDatabaseIsTheBody(t *testing.T) {
	ran := false
	WithTransaction(func() { ran = true })
	if !ran {
		t.Fatal("the body did not run")
	}
}

// WithDatabase has a process-wide API, so overlapping scopes are serialized. The second
// scope cannot clear the first one's binding, and begins only after the first restored it.
func TestOverlappingWithDatabaseScopesAreSerialized(t *testing.T) {
	firstDatabase := liveDatabase(t)
	secondDatabase := liveDatabase(t)
	firstEntered := make(chan struct{})
	releaseFirst := make(chan struct{})
	secondAttempted := make(chan struct{})
	secondEntered := make(chan struct{})
	done := make(chan struct{}, 2)

	go func() {
		WithDatabase(firstDatabase, func() {
			close(firstEntered)
			<-releaseFirst
			if firstDatabase.bound() == nil || boundDatabase.Load() != firstDatabase {
				t.Error("the first scope lost its binding while the second waited")
			}
		})
		done <- struct{}{}
	}()
	<-firstEntered
	go func() {
		close(secondAttempted)
		WithDatabase(secondDatabase, func() {
			if secondDatabase.bound() == nil || boundDatabase.Load() != secondDatabase {
				t.Error("the second scope was not bound when it entered")
			}
			close(secondEntered)
		})
		done <- struct{}{}
	}()
	<-secondAttempted
	select {
	case <-secondEntered:
		t.Fatal("overlapping WithDatabase scopes ran concurrently")
	case <-time.After(100 * time.Millisecond):
	}
	close(releaseFirst)
	select {
	case <-secondEntered:
	case <-time.After(5 * time.Second):
		t.Fatal("the second WithDatabase scope did not enter after the first exited")
	}
	<-done
	<-done
	if firstDatabase.bound() != nil || secondDatabase.bound() != nil || boundDatabase.Load() != nil {
		t.Fatal("a serialized scope left a stale binding")
	}
}

func TestDatabaseBindingSerializerIsRaceSafeAndReentrant(t *testing.T) {
	acquireDatabaseBinding()
	acquireDatabaseBinding()
	secondEntered := make(chan struct{})
	done := make(chan struct{})
	go func() {
		acquireDatabaseBinding()
		close(secondEntered)
		releaseDatabaseBinding()
		close(done)
	}()
	enteredWhileNested := false
	select {
	case <-secondEntered:
		enteredWhileNested = true
	case <-time.After(25 * time.Millisecond):
	}
	releaseDatabaseBinding()
	enteredBeforeOutermostRelease := false
	select {
	case <-secondEntered:
		enteredBeforeOutermostRelease = true
	case <-time.After(25 * time.Millisecond):
	}
	releaseDatabaseBinding()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("waiting binding did not enter after release")
	}
	if enteredWhileNested || enteredBeforeOutermostRelease {
		t.Fatal("another goroutine entered before the outermost binding was released")
	}
}

// A panic through a transaction rolls it back: a check failure halfway through must leave
// nothing behind, which is the only reason the block exists.
func TestTransactionRollsBackOnPanic(t *testing.T) {
	database := liveDatabase(t)
	table := NewTable[dbBook]()
	WithDatabase(database, func() {
		DbTruncate(database, table, "books")
		func() {
			defer func() { _ = recover() }()
			WithTransaction(func() {
				PgExec(database.bound(),
					`insert into "teslgotest"."books" ("id", "title", "pages") values ($1, $2, $3)`,
					[]any{"rolled", "Rolled Back", PgInt(FromInt64(1))})
				panic("the body failed")
			})
		}()
		if got := DbCount(database, table, allBooks,
			bookPlan(database, `select count(*) from @books`)); !Equal(got, FromInt64(0)) {
			t.Fatalf("%s rows survived a rolled-back transaction", got.String())
		}
	})
}

func TestTransactionCommits(t *testing.T) {
	database := liveDatabase(t)
	table := NewTable[dbBook]()
	WithDatabase(database, func() {
		DbTruncate(database, table, "books")
		WithTransaction(func() {
			PgExec(database.bound(),
				`insert into "teslgotest"."books" ("id", "title", "pages") values ($1, $2, $3)`,
				[]any{"kept", "Committed", PgInt(FromInt64(1))})
		})
		if got := DbCount(database, table, allBooks,
			bookPlan(database, `select count(*) from @books`)); !Equal(got, FromInt64(1)) {
			t.Fatalf("count after commit = %s", got.String())
		}
	})
}

// The reason the open transaction is keyed by GOROUTINE and not held on the database: two
// requests in two transactions must not see each other's uncommitted rows. A package-level
// handle passes every other test in this file and fails this one.
func TestConcurrentTransactionsAreIsolated(t *testing.T) {
	database := liveDatabase(t)
	table := NewTable[dbBook]()
	WithDatabase(database, func() {
		DbTruncate(database, table, "books")
		release := make(chan struct{})
		peeked := make(chan Int, 1)
		var waiting sync.WaitGroup
		waiting.Add(2)

		go func() {
			defer waiting.Done()
			WithTransaction(func() {
				PgExec(database.bound(),
					`insert into "teslgotest"."books" ("id", "title", "pages") values ($1, $2, $3)`,
					[]any{"mine", "Uncommitted", PgInt(FromInt64(1))})
				<-release
			})
		}()
		go func() {
			defer waiting.Done()
			WithTransaction(func() {
				peeked <- PgCount(database.bound(), `select count(*) from "teslgotest"."books"`, nil)
			})
			close(release)
		}()
		waiting.Wait()

		if seen := <-peeked; !Equal(seen, FromInt64(0)) {
			t.Fatalf("the other transaction saw %s uncommitted rows", seen.String())
		}
	})
}

// A nested transaction would silently commit the outer one at its own end, so it is refused
// until savepoints are built rather than answered with weaker atomicity than it claims.
func TestNestedTransactionIsRefused(t *testing.T) {
	database := liveDatabase(t)
	WithDatabase(database, func() {
		defer func() {
			recovered := recover()
			if recovered == nil {
				t.Fatal("a nested transaction was accepted")
			}
			if !strings.Contains(fmt.Sprint(recovered), "already open") {
				t.Fatalf("the refusal reads %v", recovered)
			}
		}()
		WithTransaction(func() {
			WithTransaction(func() {})
		})
	})
}

// Two goroutines have different ids and one goroutine keeps its own; both are what the
// transaction registry is keyed on.
func TestGoroutineIDIsPerGoroutine(t *testing.T) {
	mine := goroutineID()
	if mine == 0 {
		t.Fatal("this goroutine has no id")
	}
	if goroutineID() != mine {
		t.Fatal("the id changed between two calls on one goroutine")
	}
	other := make(chan uint64, 1)
	go func() { other <- goroutineID() }()
	if <-other == mine {
		t.Fatal("another goroutine reported the same id")
	}
}

// `innerJoin` becomes an `exists (…)` subquery rather than a real INNER JOIN: the clause
// filters the MAIN entity to rows with a counterpart, and the result is still a list of that
// entity — a join would DUPLICATE a main row for every counterpart, which the declared type
// cannot hold. This runs the statement the emitter builds, because a subquery that names its
// tables wrongly reads perfectly well in an assertion and fails only when PostgreSQL parses it
// (which is exactly how Racket's join builder has been broken: it qualifies the ON columns with
// the snake-cased ENTITY name instead of the declared table name).
func TestBoundInnerJoinExists(t *testing.T) {
	database := liveDatabase(t)
	table := NewTable[dbBook]()
	WithDatabase(database, func() {
		connection := database.bound()
		if _, err := connection.pool.Exec(context.Background(),
			`create table if not exists "teslgotest"."authors" ("id" TEXT PRIMARY KEY)`); err != nil {
			t.Fatalf("cannot create the joined table: %v", err)
		}
		PgTruncate(connection, "authors")
		DbTruncate(database, table, "books")
		PgExec(connection, `insert into "teslgotest"."authors" ("id") values ($1)`, []any{"a-1"})

		insert := func(id, author string) {
			PgExec(connection,
				`insert into "teslgotest"."books" ("id", "title", "pages") values ($1, $2, $3)`,
				[]any{id, author, PgInt(FromInt64(1))})
		}
		insert("b-1", "a-1")
		insert("b-2", "ghost")

		// The book's `title` stands in for the foreign key here, which keeps the fixture to the
		// three columns `liveDatabase` declares.
		joined := DbSelect(database, table, allBooks, nil, 0, -1,
			bookPlan(database, `select "id", "title", "pages" from @books`+
				` where exists (select 1 from "teslgotest"."authors"`+
				` where "teslgotest"."authors"."id" = "teslgotest"."books"."title")`+
				` order by "id" ASC`),
			scanDbBook)
		if len(joined) != 1 || joined[0].ID != "b-1" {
			t.Fatalf("the join answered %+v, want only b-1", joined)
		}
	})
}

// ── Grouped aggregates ───────────────────────────────────────────────────────

type dbHit struct {
	ID string
	At Int // a PosixMillis-shaped BIGINT column value
}

func allHits(dbHit) bool { return true }

func scanHitCount(row pgx.CollectableRow) (Tuple2[PosixMillis, Int], error) {
	var bucket int64
	var counted int64
	if err := row.Scan(&bucket, &counted); err != nil {
		return Tuple2[PosixMillis, Int]{}, err
	}
	return Tuple2[PosixMillis, Int]{
		Tuple2First:  PosixMillis{Value: FromInt64(bucket)},
		Tuple2Second: FromInt64(counted),
	}, nil
}

// The grouped aggregate is the query where the two backends are most tempted to disagree,
// because they bucket differently: the memory store folds runs of sorted keys, the server
// GROUP BY … ORDER BY 1s. Both must answer ascending buckets with identical counts — the
// order is part of the contract (a chart's series is only a series if its points are in
// order), so it is asserted rather than sorted away.
func TestBoundGroupFoldAgreesWithTheMemoryTable(t *testing.T) {
	database := liveDatabase(t)
	table := NewTable[dbBook]()
	key := func(book dbBook) Int { return book.Pages }
	less := func(left, right Int) bool { return Compare(left, right) < 0 }
	equal := func(left, right Int) bool { return Equal(left, right) }
	step := func(total Int, _ dbBook) Int { return Add(total, FromInt64(1)) }
	scanPages := func(row pgx.CollectableRow) (Tuple2[Int, Int], error) {
		pages := pgtype.Numeric{}
		var counted int64
		if err := row.Scan(&pages, &counted); err != nil {
			return Tuple2[Int, Int]{}, err
		}
		return Tuple2[Int, Int]{Tuple2First: PgIntOf(pages), Tuple2Second: FromInt64(counted)}, nil
	}

	insert := func(id string, pages int64) {
		DbInsert(database, table, "Book", dbBook{ID: id, Title: id, Pages: FromInt64(pages)},
			bookConflicts,
			`insert into "teslgotest"."books" ("id", "title", "pages") values ($1, $2, $3)`,
			func(book dbBook) []any { return []any{book.ID, book.Title, PgInt(book.Pages)} })
	}

	// Memory answer first, unbound.
	insert("a", 100)
	insert("b", 220)
	insert("c", 220)
	want := TableGroupFold(table, allBooks, key, less, equal, step, FromInt64(0))

	// The same rows on the server, answered by GROUP BY.
	WithDatabase(database, func() {
		DbTruncate(database, table, "books")
		insert("a", 100)
		insert("b", 220)
		insert("c", 220)
		got := DbGroupFold(database, table, allBooks, key, less, equal, step, FromInt64(0),
			PgGroupPlan{
				Aggregate: `count(*)`,
				Table:     `"teslgotest"."books"`,
				Column:    `"pages"`,
			},
			scanPages)
		if len(got) != len(want) {
			t.Fatalf("the server answered %d buckets, memory answered %d", len(got), len(want))
		}
		for index, pair := range got {
			if !Equal(pair.Tuple2First, want[index].Tuple2First) ||
				!Equal(pair.Tuple2Second, want[index].Tuple2Second) {
				t.Fatalf("bucket %d = (%s × %s), want (%s × %s)", index,
					pair.Tuple2First.String(), pair.Tuple2Second.String(),
					want[index].Tuple2First.String(), want[index].Tuple2Second.String())
			}
		}
	})
}

// A temporal bucket is where a silent unit mismatch would be worst: the SQL side floors the
// millisecond column through date_trunc (named zone) or integer arithmetic (fixed offset),
// while the memory side calls TimeTruncDay. The two must agree about where a day STARTS —
// including for an instant before the epoch, where SQL's sign-keeping `%` would misfloor a
// naive implementation. Both zone shapes of PgGroupPlan.statement get exercised, because the
// statement TEXT is built per shape and only PostgreSQL can prove it parses.
func TestBoundGroupFoldDayBucketsAgreeWithTimeTrunc(t *testing.T) {
	database := liveDatabase(t)
	table := NewTable[dbHit]()
	zone := FixedOffsetZone(FromInt64(60)) // +01:00, so its days start at 23:00 UTC.

	// Two hits inside one +01:00 day, one in the next, and one before the epoch.
	instants := []int64{
		time.Date(2024, 3, 10, 8, 0, 0, 0, time.UTC).UnixMilli(),
		time.Date(2024, 3, 10, 22, 30, 0, 0, time.UTC).UnixMilli(), // next +01:00 day at 23:30 UTC
		time.Date(2024, 3, 11, 6, 0, 0, 0, time.UTC).UnixMilli(),
		time.Date(1965, 7, 1, 0, 30, 0, 0, time.UTC).UnixMilli(), // negative millis
	}
	keyAt := func(at Int) PosixMillis { return PosixMillis{Value: at} }

	run := func(zone PgGroupZone, truncDay func(PosixMillis) PosixMillis) {
		got := DbGroupFold(database, table, allHits,
			func(hit dbHit) PosixMillis { return truncDay(keyAt(hit.At)) },
			func(left, right PosixMillis) bool { return Compare(left.Value, right.Value) < 0 },
			func(left, right PosixMillis) bool { return Equal(left.Value, right.Value) },
			func(total Int, _ dbHit) Int { return Add(total, FromInt64(1)) },
			FromInt64(0),
			PgGroupPlan{
				Aggregate: `count(*)`,
				Table:     `"teslgotest"."hits"`,
				Column:    `"at"`,
				Unit:      "day",
				Zone:      zone,
			},
			scanHitCount)
		wantBuckets := map[int64]int64{}
		for _, at := range instants {
			bucket, _ := truncDay(PosixMillis{Value: FromInt64(at)}).Value.Int64()
			wantBuckets[bucket]++
		}
		if len(got) != len(wantBuckets) {
			t.Fatalf("zone %+v: %d buckets, want %d", zone, len(got), len(wantBuckets))
		}
		for _, pair := range got {
			bucket, _ := pair.Tuple2First.Value.Int64()
			count, _ := pair.Tuple2Second.Int64()
			if wantBuckets[bucket] != count {
				t.Fatalf("zone %+v: bucket %d counted %d, want %d", zone, bucket, count, wantBuckets[bucket])
			}
		}
	}

	WithDatabase(database, func() {
		connection := database.bound()
		if _, err := connection.pool.Exec(context.Background(),
			`create table if not exists "teslgotest"."hits" ("id" TEXT PRIMARY KEY, "at" BIGINT)`); err != nil {
			t.Fatalf("cannot create the hits table: %v", err)
		}
		PgTruncate(connection, "hits")
		for index, at := range instants {
			PgExec(connection, `insert into "teslgotest"."hits" ("id", "at") values ($1, $2)`,
				[]any{fmt.Sprintf("hit-%d", index), PgBigint(FromInt64(at))})
		}

		// Fixed-offset zone: integer arithmetic in SQL against TimeTruncDay here. What the
		// assertion checks is that the server's bucket arithmetic puts the same instants in
		// the same buckets TimeTruncDay does.
		run(PgZoneOf(zone), func(at PosixMillis) PosixMillis { return TimeTruncDay(zone, at) })

		// Named zone: date_trunc in PG against TimeTruncDay under UTC.
		utc := TimeZone{Name: "UTC"}
		run(PgZoneOf(utc), func(at PosixMillis) PosixMillis { return TimeTruncDay(utc, at) })
	})
}

// ── Money sums ───────────────────────────────────────────────────────────────

type dbInvoice struct {
	ID         string
	MinorUnits Int
	Currency   string
}

func allInvoices(dbInvoice) bool { return true }

func moneyDatabase(t *testing.T) *Database {
	t.Helper()
	return &Database{
		Name:   "Billing",
		Config: liveCluster(t),
		Tables: []PostgresTable{{
			Name: "invoices",
			Columns: []PostgresColumn{
				{Name: "id", Type: "TEXT", PrimaryKey: true},
				{Name: "minor_units", Type: "NUMERIC"},
				{Name: "currency", Type: "TEXT"},
			},
		}},
	}
}

func invoicePlan(_ *Database, statement string) PgPlan {
	return PgSql(strings.ReplaceAll(statement, "@invoices", `"teslgotest"."invoices"`), nil)
}

func insertInvoice(database *Database, table *Table[dbInvoice], id string, units int64, code string) {
	invoice := dbInvoice{ID: id, MinorUnits: FromInt64(units), Currency: code}
	DbInsert(database, table, "Invoice", invoice,
		func(existing, inserted dbInvoice) bool { return existing.ID == inserted.ID },
		`insert into "teslgotest"."invoices" ("id", "minor_units", "currency") values ($1, $2, $3)`,
		func(invoice dbInvoice) []any {
			return []any{invoice.ID, PgInt(invoice.MinorUnits), invoice.Currency}
		})
}

// sumInvoices is the ONE call both backends answer, asserted twice per case: once unbound
// (memory folds the rows and adopts the first row's currency) and once bound (the server sums
// NUMERIC minor units and reports the distinct currencies). A disagreement about totals, or
// about WHICH programs trap, shows up as a failed case rather than as a drift.
func sumInvoices(database *Database, table *Table[dbInvoice], match func(dbInvoice) bool) (answer Money, panicValue any) {
	defer func() { panicValue = recover() }()
	project := func(invoice dbInvoice) Money {
		known := CurrencyFromCode(invoice.Currency)
		if !known.IsSomething() {
			panic("test fixture stored unknown currency " + invoice.Currency)
		}
		return MoneyFromMinorUnits(known.SomethingValue, invoice.MinorUnits)
	}
	return DbSumMoney(database, table, match, project, "Invoice", "amount",
		invoicePlan(database, `select coalesce(sum("minor_units"), 0), count(distinct "currency"), min("currency") from @invoices`)), nil
}

func TestBoundMoneySumAgreesWithTheMemoryTable(t *testing.T) {
	database := moneyDatabase(t)
	table := NewTable[dbInvoice]()

	// Single currency: both paths total the minor units exactly and carry USD out.
	memoryAnswer, memoryPanic := func() (Money, any) {
		insertInvoice(database, table, "in-1", 1050, "USD")
		insertInvoice(database, table, "in-2", 250, "USD")
		return sumInvoices(database, table, allInvoices)
	}()
	if memoryPanic != nil || !Equal(memoryAnswer.MinorUnits, FromInt64(1300)) ||
		memoryAnswer.Currency.Code != "USD" {
		t.Fatalf("memory sum = %+v (panic %v)", memoryAnswer, memoryPanic)
	}

	WithDatabase(database, func() {
		connection := database.bound()
		PgTruncate(connection, "invoices")
		PgExec(connection, `insert into "teslgotest"."invoices" ("id", "minor_units", "currency") values ($1, $2, $3)`, []any{"in-1", PgInt(FromInt64(1050)), "USD"})
		PgExec(connection, `insert into "teslgotest"."invoices" ("id", "minor_units", "currency") values ($1, $2, $3)`, []any{"in-2", PgInt(FromInt64(250)), "USD"})
		serverAnswer, serverPanic := sumInvoices(database, table, allInvoices)
		if serverPanic != nil || !Equal(serverAnswer.MinorUnits, memoryAnswer.MinorUnits) ||
			serverAnswer.Currency.Code != memoryAnswer.Currency.Code {
			t.Fatalf("server sum = %+v (panic %v), memory summed to %+v", serverAnswer, serverPanic, memoryAnswer)
		}

		// Mixed currencies: refused with the count named, on both paths — a SUM may not
		// invent an exchange rate.
		PgExec(connection, `insert into "teslgotest"."invoices" ("id", "minor_units", "currency") values ($1, $2, $3)`, []any{"in-3", PgInt(FromInt64(1)), "EUR"})
		if _, mixed := sumInvoices(database, table, allInvoices); mixed == nil ||
			!strings.Contains(fmt.Sprint(mixed), "(found 2)") {
			t.Fatalf("mixed-currency server sum panicked with %v", mixed)
		}

		// Empty set: no currency for the zero total, so both paths refuse rather than
		// fabricate $0.00.
		PgTruncate(connection, "invoices")
		if _, empty := sumInvoices(database, table, allInvoices); empty == nil ||
			!strings.Contains(fmt.Sprint(empty), "empty row set") {
			t.Fatalf("empty-set server sum panicked with %v", empty)
		}

		// Corrupt data: a code no ISO 4217 table knows is a trap, not a half-formed Money.
		PgExec(connection, `insert into "teslgotest"."invoices" ("id", "minor_units", "currency") values ($1, $2, $3)`, []any{"bad", PgInt(FromInt64(5)), "XXY"})
		if _, corrupt := sumInvoices(database, table, allInvoices); corrupt == nil ||
			!strings.Contains(fmt.Sprint(corrupt), "not a known ISO 4217 currency") {
			t.Fatalf("corrupt-currency server sum panicked with %v", corrupt)
		}
	})

	// The same two refusals on the memory path.
	if _, mixed := func() (Money, any) {
		TableTruncate(table)
		insertInvoice(database, table, "usd", 1, "USD")
		insertInvoice(database, table, "eur", 1, "EUR")
		return sumInvoices(database, table, allInvoices)
	}(); mixed == nil || !strings.Contains(fmt.Sprint(mixed), "(found 2)") {
		t.Fatalf("mixed-currency memory sum panicked with %v", mixed)
	}
	if _, empty := func() (Money, any) {
		TableTruncate(table)
		return sumInvoices(database, table, allInvoices)
	}(); empty == nil || !strings.Contains(fmt.Sprint(empty), "empty row set") {
		t.Fatalf("empty-set memory sum panicked with %v", empty)
	}
}

// ── Pool saturation ──────────────────────────────────────────────────────────

// A pool smaller than the demand on it must QUEUE, not deadlock: six concurrent statements
// against a two-connection pool all complete, and the pool keeps answering after the burst.
// This pins the pgxpool configuration path (MaxConns from poolSize) against a regression
// where a saturated pool silently stopped serving.
func TestPostgresPoolSaturatesAndRecovers(t *testing.T) {
	config := liveCluster(t)
	config.PoolSize = 2
	db := OpenPostgres(config, nil)

	const burst = 6
	var waiting sync.WaitGroup
	waiting.Add(burst)
	for range burst {
		go func() {
			defer waiting.Done()
			if got := PgCount(db, `select 1`, nil); !Equal(got, FromInt64(1)) {
				t.Errorf("saturated pool answered %s", got.String())
			}
		}()
	}
	waiting.Wait()
	if got := PgCount(db, `select 1`, nil); !Equal(got, FromInt64(1)) {
		t.Fatalf("pool stopped serving after saturation: %s", got.String())
	}
}

// The bound half of the same rule: the emitted statement guards on the match count, so two
// matches update nothing, and the plan's probe lets the runtime raise the Memory table's trap.
func TestBoundUpdateReturnOneRefusesAnAmbiguousPredicate(t *testing.T) {
	database := liveDatabase(t)
	table := NewTable[dbBook]()
	WithDatabase(database, func() {
		DbTruncate(database, table, "books")
		for _, book := range []dbBook{
			{ID: "a", Title: "Alpha", Pages: FromInt64(100)},
			{ID: "b", Title: "Beta", Pages: FromInt64(100)},
			{ID: "c", Title: "Gamma", Pages: FromInt64(7)},
		} {
			DbInsert(database, table, "Book", book, bookConflicts,
				`insert into "teslgotest"."books" ("id", "title", "pages") values ($1, $2, $3)`,
				func(book dbBook) []any { return []any{book.ID, book.Title, PgInt(book.Pages)} })
		}
		hundredPages := func(book dbBook) bool { return Equal(book.Pages, FromInt64(100)) }
		rename := func(book dbBook) dbBook { book.Title = "Renamed"; return book }
		ambiguous := PgSqlProbed(
			strings.ReplaceAll(`update @books set "title" = $1 where "pages" = $2 and (select count(*) from @books where "pages" = $2) = 1 returning "id", "title", "pages"`, "@books", `"teslgotest"."books"`),
			func() []any { return []any{"Renamed", PgInt(FromInt64(100))} },
			strings.ReplaceAll(`select count(*) from @books where "pages" = $1`, "@books", `"teslgotest"."books"`),
			func() []any { return []any{PgInt(FromInt64(100))} })
		func() {
			defer func() {
				recovered := recover()
				if recovered == nil {
					t.Fatal("updateAndReturnOne over two matching rows must trap on Postgres too")
				}
				if recovered != updateReturnOneAmbiguous {
					t.Fatalf("trap = %v", recovered)
				}
			}()
			DbUpdateReturnOne(database, table, hundredPages, rename, ambiguous, scanDbBook)
		}()
		renamed := DbSelect(database, table, func(book dbBook) bool { return book.Title == "Renamed" },
			nil, 0, -1, bookPlan(database, `select "id", "title", "pages" from @books where "title" = $1`, "Renamed"),
			scanDbBook)
		if len(renamed) != 0 {
			t.Fatalf("rows were updated before the ambiguity was detected: %+v", renamed)
		}
		one := PgSqlProbed(
			strings.ReplaceAll(`update @books set "title" = $1 where "pages" = $2 and (select count(*) from @books where "pages" = $2) = 1 returning "id", "title", "pages"`, "@books", `"teslgotest"."books"`),
			func() []any { return []any{"Renamed", PgInt(FromInt64(7))} },
			strings.ReplaceAll(`select count(*) from @books where "pages" = $1`, "@books", `"teslgotest"."books"`),
			func() []any { return []any{PgInt(FromInt64(7))} })
		updated := DbUpdateReturnOne(database, table,
			func(book dbBook) bool { return Equal(book.Pages, FromInt64(7)) }, rename, one, scanDbBook)
		if updated.ID != "c" || updated.Title != "Renamed" {
			t.Fatalf("the single match was not updated: %+v", updated)
		}
	})
}

// ── Memory transactions ──────────────────────────────────────────────────────

// The spec says a transaction rolls back on any exception and does not exempt the Memory
// store; `tesl test` runs there, so a test asserting atomicity has to see what production sees.
// Insert, update, delete and a second table all return to their pre-transaction rows.
func TestMemoryTransactionRollsBackOnPanic(t *testing.T) {
	database := &Database{Name: "Library"}
	books := NewTable[dbBook]()
	notes := NewTable[row]()
	DbInsert(database, books, "Book", dbBook{ID: "kept", Title: "Kept", Pages: FromInt64(10)},
		bookConflicts, "insert into nowhere", func(dbBook) []any { return nil })
	TableInsert(notes, "Row", row{ID: "n1", Title: "before"}, sameID)

	recovered := func() (recovered any) {
		defer func() { recovered = recover() }()
		WithTransaction(func() {
			DbInsert(database, books, "Book", dbBook{ID: "new", Title: "New", Pages: FromInt64(1)},
				bookConflicts, "insert into nowhere", func(dbBook) []any { return nil })
			DbUpdate(database, books, func(book dbBook) bool { return book.ID == "kept" },
				func(book dbBook) dbBook { book.Title = "Renamed"; return book }, PgSql("update nowhere", nil))
			TableDelete(notes, byID("n1"))
			TableInsert(notes, "Row", row{ID: "n2"}, sameID)
			panic("the second statement failed its check")
		})
		return nil
	}()
	if recovered == nil {
		t.Fatal("the trap did not propagate out of the transaction")
	}
	rows := DbSelect(database, books, allBooks, nil, 0, -1, PgSql("select from nowhere", nil), scanDbBook)
	if len(rows) != 1 || rows[0].ID != "kept" || rows[0].Title != "Kept" {
		t.Fatalf("the books table after rollback: %+v", rows)
	}
	if remaining := TableSelect(notes, every); len(remaining) != 1 || remaining[0].Title != "before" {
		t.Fatalf("the notes table after rollback: %+v", remaining)
	}
	// The store keeps working afterwards, and a later transaction is not confused by the
	// rolled-back one: nothing about the first is left registered.
	WithTransaction(func() {
		TableInsert(notes, "Row", row{ID: "n3"}, sameID)
	})
	if remaining := TableSelect(notes, every); len(remaining) != 2 {
		t.Fatalf("a committed transaction after a rolled-back one left %+v", remaining)
	}
}

// A body that returns commits: the writes stay, and the rollback record is discarded.
func TestMemoryTransactionCommits(t *testing.T) {
	table := NewTable[row]()
	WithTransaction(func() {
		TableInsert(table, "Row", row{ID: "a"}, sameID)
		TableUpdate(table, byID("a"), func(r row) row { r.Title = "committed"; return r })
	})
	rows := TableSelect(table, every)
	if len(rows) != 1 || rows[0].Title != "committed" {
		t.Fatalf("after commit: %+v", rows)
	}
	if memoryTransactionsOpen.Load() != 0 {
		t.Fatalf("%d Memory transactions still registered after commit", memoryTransactionsOpen.Load())
	}
}

// Rollback restores the FIRST state the transaction saw, not the state before the last
// statement: three writes to one table undo as one.
func TestMemoryTransactionRollsBackToTheStateBeforeTheBlock(t *testing.T) {
	table := NewTable[row]()
	TableInsert(table, "Row", row{ID: "a", Size: FromInt64(1)}, sameID)
	func() {
		defer func() { _ = recover() }()
		WithTransaction(func() {
			TableUpdate(table, byID("a"), func(r row) row { r.Size = FromInt64(2); return r })
			TableUpdate(table, byID("a"), func(r row) row { r.Size = FromInt64(3); return r })
			TableTruncate(table)
			panic("trap")
		})
	}()
	got := TableSelectOne(table, byID("a"))
	if !got.IsSomething() || !Equal(got.SomethingValue.Size, FromInt64(1)) {
		t.Fatalf("after rollback: %+v", got)
	}
}

// Nesting is refused on the Memory store exactly as on Postgres, so a program cannot pass its
// tests with a shape that traps in production.
func TestMemoryTransactionRefusesNesting(t *testing.T) {
	recovered := func() (recovered any) {
		defer func() { recovered = recover() }()
		WithTransaction(func() {
			WithTransaction(func() {})
		})
		return nil
	}()
	if recovered == nil || !strings.Contains(fmt.Sprint(recovered), "already open") {
		t.Fatalf("nested Memory transaction answered %v", recovered)
	}
	if memoryTransactionsOpen.Load() != 0 {
		t.Fatal("the refused nesting left a Memory transaction registered")
	}
}

// A goroutine started inside the body does not join the transaction — the Postgres rule — but
// its Memory write waits for rollback to finish. It then commits against the restored rows, so
// rollback cannot erase a concurrent request's completed write.
func TestMemoryTransactionBlocksConcurrentWriterUntilAfterRollback(t *testing.T) {
	table := NewTable[row]()
	TableInsert(table, "Row", row{ID: "before"}, sameID)
	writerStarted := make(chan struct{})
	writerEnteredTable := make(chan struct{})
	writerCommitted := make(chan struct{})
	var enteredOnce sync.Once
	recovered := func() (recovered any) {
		defer func() { recovered = recover() }()
		WithTransaction(func() {
			TableInsert(table, "Row", row{ID: "inside"}, sameID)
			go func() {
				close(writerStarted)
				TableInsert(table, "Row", row{ID: "outside"}, func(row, row) bool {
					enteredOnce.Do(func() { close(writerEnteredTable) })
					return false
				})
				close(writerCommitted)
			}()
			<-writerStarted
			select {
			case <-writerEnteredTable:
				t.Error("the concurrent writer entered the table operation before rollback")
			case <-time.After(100 * time.Millisecond):
			}
			panic("trap")
		})
		return nil
	}()
	if recovered != "trap" {
		t.Fatalf("transaction answered %v, expected its trap", recovered)
	}
	select {
	case <-writerCommitted:
	case <-time.After(5 * time.Second):
		t.Fatal("the concurrent writer did not commit after rollback released it")
	}
	rows := TableSelect(table, every)
	if len(rows) != 2 || rows[0].ID != "before" || rows[1].ID != "outside" {
		t.Fatalf("after rollback: %+v", rows)
	}
	if memoryTransactionsOpen.Load() != 0 {
		t.Fatal("a Memory transaction is still registered")
	}
}

// ── Pool lease ───────────────────────────────────────────────────────────────

// The documented lease: a request that cannot get a connection within
// TESL_PG_POOL_LEASE_TIMEOUT_MS is answered 503 "database busy", not held for 30 s and then
// reported as a 500. Two held transactions saturate a pool of two; the third statement is
// rejected within roughly the lease; releasing the transactions makes the pool serve again.
func TestPoolLeaseTimesOutWithA503(t *testing.T) {
	config := liveCluster(t)
	config.PoolSize = 2
	db := OpenPostgres(config, nil)
	t.Setenv("TESL_PG_POOL_LEASE_TIMEOUT_MS", "400")

	held := make([]pgx.Tx, 0, 2)
	for range 2 {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		transaction, err := db.pool.Begin(ctx)
		cancel()
		if err != nil {
			t.Fatalf("cannot hold a connection: %v", err)
		}
		held = append(held, transaction)
	}
	release := func() {
		for _, transaction := range held {
			_ = transaction.Rollback(context.Background())
		}
		held = nil
	}
	defer release()

	started := time.Now()
	recovered := func() (recovered any) {
		defer func() { recovered = recover() }()
		PgCount(db, `select 1`, nil)
		return nil
	}()
	waited := time.Since(started)
	rejection, isRejection := recovered.(RequestRejection)
	if !isRejection || rejection.Status != 503 || rejection.Message != "database busy, try again" {
		t.Fatalf("a saturated pool answered %#v after %v", recovered, waited)
	}
	if waited < 300*time.Millisecond || waited > 3*time.Second {
		t.Fatalf("the rejection took %v, expected about the 400 ms lease", waited)
	}

	// The same bound and answer for `transaction { }` itself, whose BEGIN needs a connection.
	database := &Database{Name: "Library", Config: config}
	database.mutex.Lock()
	database.open = db
	database.mutex.Unlock()
	previous := boundDatabase.Swap(database)
	defer boundDatabase.Store(previous)
	recovered = func() (recovered any) {
		defer func() { recovered = recover() }()
		WithTransaction(func() { t.Error("the body ran without a connection") })
		return nil
	}()
	if rejection, isRejection := recovered.(RequestRejection); !isRejection || rejection.Status != 503 {
		t.Fatalf("transaction on a saturated pool answered %#v", recovered)
	}

	release()
	if got := PgCount(db, `select 1`, nil); !Equal(got, FromInt64(1)) {
		t.Fatalf("pool did not recover after the lease timeout: %s", got.String())
	}
}

// `updateAndReturnOne` once selected its row by ctid through a scalar subquery; a concurrent
// writer moved the row to a new ctid between the subquery and the outer TID lookup and the
// statement found nothing — 148 spurious "no row matched" traps in 400 contended calls
// (whitebox campaign, 2026-09-02). The count-guarded form re-checks the predicate on the
// row's latest version, so every contended call lands.
func TestBoundUpdateReturnOneIsExactUnderContention(t *testing.T) {
	database := liveDatabase(t)
	table := NewTable[dbBook]()
	// One binding for the whole test, as a served program has: `WithDatabase` swaps the
	// database's connection in and restores the previous one on exit, so concurrent
	// `WithDatabase` calls on one Database would unbind each other.
	WithDatabase(database, func() {
		DbTruncate(database, table, "books")
		DbInsert(database, table, "Book", dbBook{ID: "hot", Title: "0", Pages: FromInt64(0)}, bookConflicts,
			`insert into "teslgotest"."books" ("id", "title", "pages") values ($1, $2, $3)`,
			func(book dbBook) []any { return []any{book.ID, book.Title, PgInt(book.Pages)} })
		const writers, rounds = 4, 50
		var wait sync.WaitGroup
		var traps atomic.Int64
		for writer := 0; writer < writers; writer++ {
			wait.Add(1)
			go func() {
				defer wait.Done()
				for round := 0; round < rounds; round++ {
					func() {
						defer func() {
							if recovered := recover(); recovered != nil {
								traps.Add(1)
								t.Logf("trap: %v", recovered)
							}
						}()
						plan := PgSqlProbed(
							strings.ReplaceAll(`update @books set "pages" = "pages" + 1 where "id" = $1 and (select count(*) from @books where "id" = $1) = 1 returning "id", "title", "pages"`, "@books", `"teslgotest"."books"`),
							func() []any { return []any{"hot"} },
							strings.ReplaceAll(`select count(*) from @books where "id" = $1`, "@books", `"teslgotest"."books"`),
							func() []any { return []any{"hot"} })
						DbUpdateReturnOne(database, table,
							func(book dbBook) bool { return book.ID == "hot" },
							func(book dbBook) dbBook { book.Pages = Add(book.Pages, FromInt64(1)); return book },
							plan, scanDbBook)
					}()
				}
			}()
		}
		wait.Wait()
		if got := traps.Load(); got != 0 {
			t.Fatalf("%d contended updateAndReturnOne calls trapped on a row that exists", got)
		}
		final := DbSelectOne(database, table, func(book dbBook) bool { return book.ID == "hot" }, nil,
			bookPlan(database, `select "id", "title", "pages" from @books where "id" = $1 limit 1`, "hot"),
			scanDbBook)
		if !final.IsSomething() || !Equal(final.SomethingValue.Pages, FromInt64(writers*rounds)) {
			t.Fatalf("final pages = %+v, want %d", final, writers*rounds)
		}
	})
}

// A `Maybe` column compares as a value on the Memory store (`Nothing == Nothing`), and the
// emitter now renders that equality as `is not distinct from` so the server agrees: `=`
// against a NULL parameter is never true in SQL, which made `where s.revokedAt == none`
// revoke every session in the test store and none in production (whitebox campaign,
// 2026-09-02). Pinned here on the server; the emitted text is pinned by the OCaml test
// test_sql_maybe_equality.ml.
func TestBoundMaybeEqualityIsNullSafe(t *testing.T) {
	database := &Database{
		Name:   "Sessions",
		Config: liveCluster(t),
		Tables: []PostgresTable{{
			Name: "sessions",
			Columns: []PostgresColumn{
				{Name: "id", Type: "TEXT", PrimaryKey: true},
				{Name: "revoked_at", Type: "TEXT", Nullable: true},
			},
		}},
	}
	type session struct {
		ID        string
		RevokedAt Maybe[string]
	}
	table := NewTable[session]()
	scan := func(row pgx.CollectableRow) (session, error) {
		found := session{}
		var revoked *string
		if err := row.Scan(&found.ID, &revoked); err != nil {
			return found, err
		}
		found.RevokedAt = MaybeOfPointer(revoked, func() string { return *revoked })
		return found, nil
	}
	plan := func(statement string, arguments ...any) PgPlan {
		return PgSql(strings.ReplaceAll(statement, "@sessions", `"teslgotest"."sessions"`),
			func() []any { return arguments })
	}
	WithDatabase(database, func() {
		DbTruncate(database, table, "sessions")
		revoked := "2026-01-01"
		for _, row := range []struct {
			id      string
			revoked *string
		}{{"live", nil}, {"gone", &revoked}} {
			DbInsert(database, table, "Session",
				session{ID: row.id, RevokedAt: MaybeOfPointer(row.revoked, func() string { return *row.revoked })},
				func(a, b session) bool { return a.ID == b.ID },
				`insert into "teslgotest"."sessions" ("id", "revoked_at") values ($1, $2)`,
				func(s session) []any { return []any{s.ID, row.revoked} })
		}
		var none *string
		live := DbSelect(database, table,
			func(s session) bool { return !s.RevokedAt.IsSomething() }, nil, 0, -1,
			plan(`select "id", "revoked_at" from @sessions where "revoked_at" is not distinct from $1`, none),
			scan)
		if len(live) != 1 || live[0].ID != "live" {
			t.Fatalf("null-safe equality against Nothing matched %+v, want the unrevoked row", live)
		}
		notNone := DbSelect(database, table,
			func(s session) bool { return s.RevokedAt.IsSomething() }, nil, 0, -1,
			plan(`select "id", "revoked_at" from @sessions where "revoked_at" is distinct from $1`, none),
			scan)
		if len(notNone) != 1 || notNone[0].ID != "gone" {
			t.Fatalf("null-safe inequality against Nothing matched %+v, want the revoked row", notNone)
		}
		// The plain operator is the bug: `= NULL` is never true.
		plain := DbSelect(database, table,
			func(s session) bool { return !s.RevokedAt.IsSomething() }, nil, 0, -1,
			plan(`select "id", "revoked_at" from @sessions where "revoked_at" = $1`, none),
			scan)
		if len(plain) != 0 {
			t.Fatalf("`= NULL` matched %+v; the test documents why the emitter avoids it", plain)
		}
	})
}

// A `secret` column's bound value reaches the server as plaintext (storage is the one
// legitimate disclosure) while everything that renders the parameter sees the redaction
// (whitebox campaign, 2026-09-02: the `--debug` SQL preview showed the plaintext).
func TestBoundSecretParamStoresPlaintextAndRendersRedacted(t *testing.T) {
	database := liveDatabase(t)
	table := NewTable[dbBook]()
	WithDatabase(database, func() {
		DbTruncate(database, table, "books")
		secret := MakeSecret("api-key-SECRET-999")
		DbInsert(database, table, "Book", dbBook{ID: "k", Title: secret.Reveal(), Pages: FromInt64(1)},
			bookConflicts,
			`insert into "teslgotest"."books" ("id", "title", "pages") values ($1, $2, $3)`,
			func(book dbBook) []any { return []any{book.ID, PgSecret(secret), PgInt(book.Pages)} })
		stored := DbSelectOne(database, table, func(book dbBook) bool { return book.ID == "k" }, nil,
			bookPlan(database, `select "id", "title", "pages" from @books where "id" = $1 limit 1`, "k"),
			scanDbBook)
		if !stored.IsSomething() || stored.SomethingValue.Title != "api-key-SECRET-999" {
			t.Fatalf("the secret's plaintext must reach storage, got %+v", stored)
		}
	})
	rendered := fmt.Sprintf("%v %s %d %+v %#v", PgSecret(MakeSecret("api-key-SECRET-999")),
		PgSecret(MakeSecret("api-key-SECRET-999")), PgSecret(MakeSecret("api-key-SECRET-999")),
		PgSecret(MakeSecret("api-key-SECRET-999")), PgSecret(MakeSecret("api-key-SECRET-999")))
	if strings.Contains(rendered, "SECRET-999") {
		t.Fatalf("a SecretParam rendered its plaintext: %s", rendered)
	}
}
