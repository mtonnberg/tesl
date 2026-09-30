package teslrt

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"os"
	"strconv"
	"strings"
	"sync"
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

func TestPostgresPoolSizeDefaultsToTen(t *testing.T) {
	config := postgresPoolConfig(PostgresConfig{}, "")
	if config.MaxConns != 10 {
		t.Fatalf("default MaxConns = %d, want 10", config.MaxConns)
	}
}

func TestPostgresPoolSizeLiteral(t *testing.T) {
	config := postgresPoolConfig(PostgresConfig{PoolSize: 25}, "")
	if config.MaxConns != 25 {
		t.Fatalf("literal MaxConns = %d, want 25", config.MaxConns)
	}
}

func TestPgPoolSizeReadsEnvironmentAndFallback(t *testing.T) {
	t.Setenv("TESL_TEST_PG_POOL_SIZE", "41")
	if got := PgPoolSize("TESL_TEST_PG_POOL_SIZE", 7); got != 41 {
		t.Fatalf("environment pool size = %d, want 41", got)
	}
	if got := PgPoolSize("TESL_TEST_PG_POOL_SIZE_MISSING", 7); got != 7 {
		t.Fatalf("fallback pool size = %d, want 7", got)
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

// A NULL in a column Tesl typed as plain `Int` is a trap, not a zero: the only way one arrives
// here is schema drift or a row another tool wrote, and 0 would be a fabricated balance. The
// `Maybe Int` path never calls this on a NULL (`MaybeOfPointer` skips the decode).
func TestPgIntOfNullTraps(t *testing.T) {
	defer func() {
		recovered := recover()
		if recovered == nil {
			t.Fatal("PgIntOf(NULL) answered instead of trapping")
		}
		message := fmt.Sprint(recovered)
		if !strings.Contains(message, "NUMERIC") || !strings.Contains(message, "NULL") ||
			!strings.Contains(message, "Maybe Int") {
			t.Fatalf("the trap does not name the column type and the remedy: %s", message)
		}
	}()
	PgIntOf(pgtype.Numeric{})
}

// The lease knob: unset is the documented 10 s, a value is milliseconds, and garbage is refused
// rather than silently replaced by the default.
func TestPgLeaseTimeoutReadsTheEnvironment(t *testing.T) {
	t.Setenv("TESL_PG_POOL_LEASE_TIMEOUT_MS", "")
	if got := pgLeaseTimeout(); got != 10*time.Second {
		t.Fatalf("default lease = %v", got)
	}
	t.Setenv("TESL_PG_POOL_LEASE_TIMEOUT_MS", " 250 ")
	if got := pgLeaseTimeout(); got != 250*time.Millisecond {
		t.Fatalf("lease from environment = %v", got)
	}
	for _, bad := range []string{"0", "-5", "soon", "1.5"} {
		t.Setenv("TESL_PG_POOL_LEASE_TIMEOUT_MS", bad)
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("TESL_PG_POOL_LEASE_TIMEOUT_MS=%q was accepted", bad)
				}
			}()
			pgLeaseTimeout()
		}()
	}
}

// Only the lease running out becomes the 503 rejection; any other driver error keeps its text
// for the operator log, under the caller's prefix.
func TestPgFailureMapsOnlyTheLeaseTo503(t *testing.T) {
	if got, ok := pgFailure("database", context.DeadlineExceeded).(RequestRejection); !ok ||
		got.Status != 503 {
		t.Fatalf("deadline mapped to %#v", pgFailure("database", context.DeadlineExceeded))
	}
	wrapped := fmt.Errorf("acquire: %w", context.DeadlineExceeded)
	if got, ok := pgFailure("database", wrapped).(RequestRejection); !ok || got.Status != 503 {
		t.Fatalf("wrapped deadline mapped to %#v", pgFailure("database", wrapped))
	}
	if got := pgFailure("transaction: cannot begin", errors.New("boom")); got != "transaction: cannot begin: boom" {
		t.Fatalf("ordinary error mapped to %#v", got)
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

// The first open of one configuration is a single flight: every concurrent caller gets the
// same pool and table bootstrap is serialized behind it.
func TestOpenPostgresConcurrentInitializationUsesOnePool(t *testing.T) {
	config := liveCluster(t)
	config.Schema = uniqueName("open_once")
	tables := []PostgresTable{{Name: "items", Columns: []PostgresColumn{
		{Name: "id", Type: "text", PrimaryKey: true},
	}}}
	const callers = 32
	start := make(chan struct{})
	results := make(chan *PostgresDB, callers)
	failures := make(chan any, callers)
	var wait sync.WaitGroup
	wait.Add(callers)
	for range callers {
		go func() {
			defer wait.Done()
			defer func() {
				if failure := recover(); failure != nil {
					failures <- failure
				}
			}()
			<-start
			results <- OpenPostgres(config, tables)
		}()
	}
	close(start)
	wait.Wait()
	close(results)
	close(failures)
	for failure := range failures {
		t.Errorf("concurrent initialization trapped: %v", failure)
	}
	var first *PostgresDB
	for db := range results {
		if first == nil {
			first = db
		} else if db != first {
			t.Fatal("one configuration produced more than one pool")
		}
	}
	if first == nil {
		t.Fatal("no concurrent caller returned a pool")
	}
	if got := PgCount(first, "select count(*) from "+first.QualifiedTable("items"), nil); !Equal(got, FromInt64(0)) {
		t.Fatalf("bootstrapped table count = %s", got.String())
	}
}

// A bootstrap failure is not cached. The candidate pool is closed by initialization and a
// later valid open of the same configuration can create a fresh pool.
func TestOpenPostgresFailureCanBeRetried(t *testing.T) {
	config := liveCluster(t)
	config.Schema = uniqueName("open_retry")
	invalid := []PostgresTable{{Name: "broken", Columns: []PostgresColumn{
		{Name: "id", Type: "tesl_type_that_does_not_exist", PrimaryKey: true},
	}}}
	recovered := func() (failure any) {
		defer func() { failure = recover() }()
		OpenPostgres(config, invalid)
		return nil
	}()
	if recovered == nil {
		t.Fatal("invalid bootstrap unexpectedly succeeded")
	}
	db := OpenPostgres(config, nil)
	if got := PgCount(db, "select 1", nil); !Equal(got, FromInt64(1)) {
		t.Fatalf("retry pool answered %s", got.String())
	}
}

// The live half of the NULL rule: a nullable NUMERIC column read through the plain-`Int`
// scanner traps and names the column type, while the `Maybe Int` scanner (a pointer carrier
// through MaybeOfPointer) reads the same row as Nothing — which is the emitted shape for each.
func TestBoundNullNumericIntoIntTrapsAndIntoMaybeIsNothing(t *testing.T) {
	config := liveCluster(t)
	db := OpenPostgres(config, []PostgresTable{{
		Name: "nullable_amounts",
		Columns: []PostgresColumn{
			{Name: "id", Type: "text", PrimaryKey: true},
			{Name: "amount", Type: "numeric", Nullable: true},
		},
	}})
	table := db.QualifiedTable("nullable_amounts")
	PgTruncate(db, "nullable_amounts")
	PgExec(db, `insert into `+table+` ("id", "amount") values ($1, $2)`, []any{"n", nil})

	trapped := func() (recovered any) {
		defer func() { recovered = recover() }()
		PgQuery(db, `select "amount" from `+table, nil,
			func(row pgx.CollectableRow) (Int, error) {
				amount := pgtype.Numeric{}
				if err := row.Scan(&amount); err != nil {
					return FromInt64(0), err
				}
				return PgIntOf(amount), nil
			})
		return nil
	}()
	if trapped == nil || !strings.Contains(fmt.Sprint(trapped), "NUMERIC column holds NULL") {
		t.Fatalf("a NULL NUMERIC read into a plain Int answered with %v", trapped)
	}

	maybes := PgQuery(db, `select "amount" from `+table, nil,
		func(row pgx.CollectableRow) (Maybe[Int], error) {
			var amount *pgtype.Numeric
			if err := row.Scan(&amount); err != nil {
				return Nothing[Int](), err
			}
			return MaybeOfPointer(amount, func() Int { return PgIntOf(*amount) }), nil
		})
	if len(maybes) != 1 || maybes[0].IsSomething() {
		t.Fatalf("a NULL NUMERIC read into a Maybe Int answered %+v", maybes)
	}
}

// A routine rebind must not repeat runtime ALTER TABLE upgrades: an active
// outbox reader holds ACCESS SHARE until its transaction finishes. The upgrade
// would need ACCESS EXCLUSIVE and block, despite both columns already existing.
func TestPostgresRebindDoesNotRepeatOutboxDDL(t *testing.T) {
	config := liveCluster(t)
	config.Schema = uniqueName("rebind_ddl")
	db := OpenPostgres(config, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := db.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	if _, err := tx.Exec(ctx, "lock table "+db.QualifiedTable(pubsubOutboxTable)+" in access share mode"); err != nil {
		t.Fatal(err)
	}
	checkCtx, checkCancel := context.WithTimeout(context.Background(), time.Second)
	defer checkCancel()
	// Still create an application table first encountered at this call site.
	db.bootstrap(checkCtx, []PostgresTable{{Name: "later", Columns: []PostgresColumn{{Name: "id", Type: "text", PrimaryKey: true}}}})
	if _, err := db.pool.Exec(ctx, "insert into "+db.QualifiedTable("later")+" (id) values ('new declaration')"); err != nil {
		t.Fatal(err)
	}
}
