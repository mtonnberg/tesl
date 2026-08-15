package teslrt

import (
	"context"
	"math/big"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// The cluster-free half: everything that decides what a statement SAYS is testable without a
// server, and these are the parts a wrong answer would be silent in.

func TestQuoteIdentifierDoublesQuotes(t *testing.T) {
	if got := quoteIdentifier("books"); got != `"books"` {
		t.Fatalf("quoteIdentifier(books) = %s", got)
	}
	if got := quoteIdentifier(`we"ird`); got != `"we""ird"` {
		t.Fatalf("quoteIdentifier(we\"ird) = %s", got)
	}
}

func TestQualifiedTableUsesSchemaWhenPresent(t *testing.T) {
	withSchema := &PostgresDB{schema: "lesson41"}
	if got := withSchema.QualifiedTable("books"); got != `"lesson41"."books"` {
		t.Fatalf("qualified = %s", got)
	}
	bare := &PostgresDB{}
	if got := bare.QualifiedTable("books"); got != `"books"` {
		t.Fatalf("qualified = %s", got)
	}
}

func TestPostgresDSNPrefersEnvironment(t *testing.T) {
	t.Setenv("PGPASSWORD", "from-env")
	t.Setenv("PGHOST", "db.internal")
	t.Setenv("PGPORT", "6543")
	dsn := postgresDSN(PostgresConfig{
		DBName: "shop", User: "shop", Password: "declared", Host: "localhost", Port: 5432,
	})
	want := "dbname=shop user=shop password=from-env host=db.internal port=6543"
	if dsn != want {
		t.Fatalf("dsn = %q, want %q", dsn, want)
	}
}

// A socket connection ignores host and port, which is what `SocketConnection { path: … }` means.
func TestPostgresDSNSocketIgnoresHostAndPort(t *testing.T) {
	t.Setenv("PGHOST", "")
	t.Setenv("PGPORT", "")
	t.Setenv("PGPASSWORD", "")
	dsn := postgresDSN(PostgresConfig{
		DBName: "shop", User: "shop", Host: "localhost", Port: 5432, SocketDir: "/tmp/pg",
	})
	if dsn != "dbname=shop user=shop host=/tmp/pg" {
		t.Fatalf("dsn = %q", dsn)
	}
}

// An Int is unbounded, and NUMERIC is the column that keeps it so: the round trip has to hold at a
// magnitude int64 cannot express, or the mapping is lossy exactly where it matters.
func TestPgIntRoundTripsBeyondInt64(t *testing.T) {
	huge := MustParseDecimal("170141183460469231731687303715884105727000")
	bound := PgInt(huge)
	if !bound.Valid || bound.Int == nil || bound.Exp != 0 {
		t.Fatalf("PgInt produced %+v", bound)
	}
	if got := PgIntOf(bound); !Equal(got, huge) {
		t.Fatalf("round trip gave %s, want %s", got.String(), huge.String())
	}
}

// A NUMERIC read back can carry a positive scale (12E+2); it is still an integer, so it reads as
// one rather than being refused.
func TestPgIntOfScalesPositiveExponent(t *testing.T) {
	scaled := pgtype.Numeric{Int: big.NewInt(12), Exp: 2, Valid: true}
	if got := PgIntOf(scaled); !Equal(got, FromInt64(1200)) {
		t.Fatalf("PgIntOf(12E+2) = %s", got.String())
	}
}

// A fractional NUMERIC is NOT an Int, and answering a truncated one would be a silent wrong
// answer — so it traps.
func TestPgIntOfRefusesFraction(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("a fractional NUMERIC read as an Int without complaint")
		}
	}()
	PgIntOf(pgtype.Numeric{Int: big.NewInt(125), Exp: -1, Valid: true})
}

func TestPgIntOfNullIsZero(t *testing.T) {
	if got := PgIntOf(pgtype.Numeric{}); !Equal(got, FromInt64(0)) {
		t.Fatalf("PgIntOf(NULL) = %s", got.String())
	}
}

func TestPgBigintRefusesWhatDoesNotFit(t *testing.T) {
	if got := PgBigint(FromInt64(1754000000000)); got != 1754000000000 {
		t.Fatalf("PgBigint = %d", got)
	}
	defer func() {
		if recover() == nil {
			t.Fatal("an out-of-range value was bound to a BIGINT column")
		}
	}()
	PgBigint(MustParseDecimal("99999999999999999999999999"))
}

// ── Against a live cluster ────────────────────────────────────────────────────
//
// Same environment the Racket Postgres tests read (tests/private/postgres-test-support.rkt), so
// one cluster started by ci.sh serves both backends. Absent, these skip: a developer without a
// server still gets the half above.

func liveCluster(t *testing.T) PostgresConfig {
	t.Helper()
	host := os.Getenv("TESL_TEST_POSTGRES_SHARED_HOST")
	port := os.Getenv("TESL_TEST_POSTGRES_SHARED_PORT")
	user := os.Getenv("TESL_TEST_POSTGRES_SHARED_USER")
	if host == "" || port == "" || user == "" {
		t.Skip("no shared PostgreSQL cluster configured (TESL_TEST_POSTGRES_SHARED_*)")
	}
	parsed, err := strconv.Atoi(port)
	if err != nil {
		t.Skipf("TESL_TEST_POSTGRES_SHARED_PORT is not a port: %v", err)
	}
	database := os.Getenv("TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE")
	if database == "" {
		database = "postgres"
	}
	config := PostgresConfig{DBName: database, User: user, Host: host, Port: parsed,
		Schema: "teslgotest"}
	waitForCluster(t, config)
	return config
}

// waitForCluster bounds the wait for a cluster that is still starting: ci.sh boots one in the
// background and reaches the Go gates before it is accepting connections, so a test that
// connected immediately would fail on TIMING rather than on behaviour. A cluster that never
// answers is a skip, not a failure — the same reading as one that was never configured, and
// ci.sh reports a cluster that failed to start on its own.
func waitForCluster(t *testing.T, config PostgresConfig) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	var lastErr error
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		connection, err := pgx.Connect(ctx, postgresDSN(config))
		if err == nil {
			lastErr = connection.Ping(ctx)
			_ = connection.Close(ctx)
			cancel()
			if lastErr == nil {
				return
			}
		} else {
			lastErr = err
			cancel()
		}
		time.Sleep(500 * time.Millisecond)
	}
	t.Skipf("PostgreSQL at %s:%d is not accepting connections: %v", config.Host, config.Port,
		lastErr)
}

type liveBook struct {
	id    string
	title string
	pages Int
}

func scanBook(row pgx.CollectableRow) (liveBook, error) {
	book := liveBook{}
	pages := pgtype.Numeric{}
	if err := row.Scan(&book.id, &book.title, &pages); err != nil {
		return book, err
	}
	book.pages = PgIntOf(pages)
	return book, nil
}

func liveBooks(t *testing.T) *PostgresDB {
	t.Helper()
	config := liveCluster(t)
	db := OpenPostgres(config, []PostgresTable{{
		Name: "books",
		Columns: []PostgresColumn{
			{Name: "id", Type: "text", PrimaryKey: true},
			{Name: "title", Type: "text"},
			{Name: "pages", Type: "numeric"},
		},
	}})
	PgTruncate(db, "books")
	return db
}

func TestPostgresBootstrapAndQuery(t *testing.T) {
	db := liveBooks(t)
	table := db.QualifiedTable("books")

	if touched := PgExec(db, "insert into "+table+" (id, title, pages) values ($1, $2, $3)",
		[]any{"book-1", "The Art of Tesl", PgInt(FromInt64(320))}); touched != 1 {
		t.Fatalf("insert touched %d rows", touched)
	}
	if touched := PgExec(db, "insert into "+table+" (id, title, pages) values ($1, $2, $3)",
		[]any{"book-2", "Proofs in Practice", PgInt(FromInt64(210))}); touched != 1 {
		t.Fatalf("insert touched %d rows", touched)
	}

	rows := PgQuery(db, "select id, title, pages from "+table+" order by id asc", nil, scanBook)
	if len(rows) != 2 {
		t.Fatalf("select gave %d rows", len(rows))
	}
	if rows[0].id != "book-1" || rows[0].title != "The Art of Tesl" ||
		!Equal(rows[0].pages, FromInt64(320)) {
		t.Fatalf("first row = %+v", rows[0])
	}

	if got := PgCount(db, "select count(*) from "+table, nil); !Equal(got, FromInt64(2)) {
		t.Fatalf("count = %s", got.String())
	}

	found := PgQueryOne(db, "select id, title, pages from "+table+" where id = $1 limit 1",
		[]any{"book-2"}, scanBook)
	if !found.IsSomething() {
		t.Fatal("selectOne found no row for book-2")
	}
	if found.SomethingValue.title != "Proofs in Practice" {
		t.Fatalf("selectOne gave %+v", found.SomethingValue)
	}

	missing := PgQueryOne(db, "select id, title, pages from "+table+" where id = $1 limit 1",
		[]any{"book-404"}, scanBook)
	if missing.IsSomething() {
		t.Fatal("selectOne invented a row")
	}

	PgTruncate(db, "books")
	if got := PgCount(db, "select count(*) from "+table, nil); !Equal(got, FromInt64(0)) {
		t.Fatalf("count after truncate = %s", got.String())
	}
}

// A NUMERIC column keeps an Int of any magnitude — the property the column type was chosen for.
func TestPostgresKeepsUnboundedInt(t *testing.T) {
	db := liveBooks(t)
	table := db.QualifiedTable("books")
	huge := MustParseDecimal("123456789012345678901234567890")
	PgExec(db, "insert into "+table+" (id, title, pages) values ($1, $2, $3)",
		[]any{"book-big", "Big", PgInt(huge)})
	rows := PgQuery(db, "select id, title, pages from "+table+" where id = $1", []any{"book-big"},
		scanBook)
	if len(rows) != 1 || !Equal(rows[0].pages, huge) {
		t.Fatalf("rows = %+v", rows)
	}
	PgTruncate(db, "books")
}

// Opening the same configuration twice answers the same pool: a program with several call sites
// on one database opens one pool, not one per site.
func TestOpenPostgresIsIdempotent(t *testing.T) {
	config := liveCluster(t)
	tables := []PostgresTable{{Name: "books", Columns: []PostgresColumn{
		{Name: "id", Type: "text", PrimaryKey: true},
		{Name: "title", Type: "text"},
		{Name: "pages", Type: "numeric"},
	}}}
	first := OpenPostgres(config, tables)
	second := OpenPostgres(config, tables)
	if first != second {
		t.Fatal("a second OpenPostgres for one configuration opened a second pool")
	}
	// And the bootstrap is `if not exists` throughout, so it survives being run twice.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	first.bootstrap(ctx, tables)
}
