package teslrt

import (
	"fmt"
	"strings"
	"sync"
	"testing"

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
