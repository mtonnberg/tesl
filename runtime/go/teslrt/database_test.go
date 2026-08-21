package teslrt

import (
	"context"
	"fmt"
	"strings"
	"sync"
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
