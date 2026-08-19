package teslrt

import (
	"context"
	"fmt"
	"math/big"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

// The PostgreSQL backend: `database D = Database { … backend: Postgres (…) }`.
//
// This is the second approved non-stdlib dependency (`github.com/jackc/pgx/v5`), and it ships
// only with a program that declares a Postgres database — a Memory-backed program still emits a
// go.mod requiring nothing. Go has no Postgres driver in its standard library, so there is no
// substitute available the way `crypto/hmac` was for MACs.
//
// WHAT THE COMPILER DOES AND WHAT THIS DOES. Every statement is built at COMPILE time: the
// emitter turns a `select … where …` into SQL text with `$1`-style placeholders plus the
// arguments, because the query's shape is known statically and building it here would mean
// re-deriving what the emitter already knows. So this file holds the connection, the schema
// bootstrap, the value mapping, and the four executors — nothing that decides what a query says.
//
// THE COLUMN TYPES ARE THE RACKET RUNTIME'S, not a fresh choice. They have to be, or a table
// created by one backend is unreadable by the other:
//
//	Int          NUMERIC             arbitrary precision, lossless at any magnitude
//	Int32        INTEGER             the opt-in compact width
//	Float        DOUBLE PRECISION
//	String       TEXT
//	Bool         BOOLEAN
//	PosixMillis  BIGINT              the one deliberate exception to Int → NUMERIC
//
// A newtype takes its base's column type; a `Maybe X` column is X's type, nullable.
//
// WHICH PROGRAMS GET THIS FILE. Only one that declares a Postgres-backed database: the driver
// and its dependency chain have no place in a binary that never opens a connection, the same
// argument that gates the HTTP half. A declared database is still INERT until something
// connects — `with database D` is the only thing that does — so a `test` block over a
// Postgres-backed entity runs against the in-memory table with no server anywhere, which is
// the dispatch `database.go` performs.
type PostgresConfig struct {
	DBName   string
	User     string
	Password string
	Host     string
	Port     int
	// SocketDir selects a Unix-socket connection (`SocketConnection`), which is how a local
	// cluster is usually reached; when it is set, Host and Port are ignored.
	SocketDir string
	Schema    string
}

// PostgresColumn describes one column, as the entity declares it.
type PostgresColumn struct {
	Name       string
	Type       string
	PrimaryKey bool
	Nullable   bool
}

// PostgresTable is an entity's table, named as the entity names it.
type PostgresTable struct {
	Name    string
	Columns []PostgresColumn
	// The declared UNIQUE indexes. A plain index is a performance hint with no observable
	// effect and is not created here; a unique one is an INVARIANT, and the two backends have
	// to agree about which programs run.
	Unique []PostgresIndex
}

// PostgresIndex is one declared index: the name `dsl/sql.rkt` derives (`<table>_<cols>_idx`,
// or an explicit `as "…"`) and the columns it covers. The NAME matters — a table shared with
// the Racket backend must not end up with two indexes doing the same job.
type PostgresIndex struct {
	Name    string
	Columns []string
}

// PostgresDB is a live pool plus the schema every statement is qualified with.
type PostgresDB struct {
	pool   *pgxpool.Pool
	schema string
}

var postgresConnectOnce sync.Map // schema+dsn -> *PostgresDB

// OpenPostgres connects, creates the schema and the declared tables if they are absent, and
// answers a pool. It is idempotent per configuration: a program with several databases on one
// cluster opens one pool per configuration rather than one per call site.
//
// The environment wins over the declaration for the password and the host, because those are
// deployment facts rather than program facts: `PGPASSWORD`, `PGHOST` and `PGPORT` are the names
// every other Postgres client already reads, so a deployment does not need a Tesl-specific one.
func OpenPostgres(config PostgresConfig, tables []PostgresTable) *PostgresDB {
	dsn := postgresDSN(config)
	key := config.Schema + "\x00" + dsn
	if existing, found := postgresConnectOnce.Load(key); found {
		if db, ok := existing.(*PostgresDB); ok {
			return db
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		panic("database: cannot connect to PostgreSQL: " + err.Error())
	}
	db := &PostgresDB{pool: pool, schema: config.Schema}
	db.bootstrap(ctx, tables)
	postgresConnectOnce.Store(key, db)
	return db
}

// PgPort reads a port out of the environment, falling back to the number the declaration
// wrote. It is not `EnvInt`: a Tesl `Int` is unbounded and a port is an ordinary `int`, and a
// value that is not a port at all is the declaration's fallback rather than a zero — a zero
// port would silently become "let the OS choose", which is not what an unset variable means.
func PgPort(name string, fallback int) int {
	text := os.Getenv(name)
	if text == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(text)
	if err != nil || parsed <= 0 || parsed > 65535 {
		return fallback
	}
	return parsed
}

func postgresDSN(config PostgresConfig) string {
	settings := []string{}
	add := func(key, value string) {
		if value != "" {
			settings = append(settings, key+"="+value)
		}
	}
	add("dbname", config.DBName)
	add("user", config.User)
	password := config.Password
	if fromEnv := os.Getenv("PGPASSWORD"); fromEnv != "" {
		password = fromEnv
	}
	add("password", password)
	if config.SocketDir != "" {
		add("host", config.SocketDir)
	} else {
		host := config.Host
		if fromEnv := os.Getenv("PGHOST"); fromEnv != "" {
			host = fromEnv
		}
		add("host", host)
		port := config.Port
		if fromEnv := os.Getenv("PGPORT"); fromEnv != "" {
			if parsed, err := strconv.Atoi(fromEnv); err == nil {
				port = parsed
			}
		}
		if port > 0 {
			add("port", strconv.Itoa(port))
		}
	}
	return strings.Join(settings, " ")
}

// bootstrap creates the schema and any missing table. `if not exists` throughout: a second
// process starting at the same time must not fail, and an EXISTING table is left exactly as it
// is — this is not a migration tool, and silently altering a live table would be worse than
// refusing to.
func (db *PostgresDB) bootstrap(ctx context.Context, tables []PostgresTable) {
	if db.schema != "" {
		if _, err := db.pool.Exec(ctx,
			"create schema if not exists "+quoteIdentifier(db.schema)); err != nil {
			panic("database: cannot create schema " + db.schema + ": " + err.Error())
		}
	}
	for _, table := range tables {
		definitions := make([]string, 0, len(table.Columns))
		for _, column := range table.Columns {
			definition := quoteIdentifier(column.Name) + " " + column.Type
			switch {
			case column.PrimaryKey:
				definition += " PRIMARY KEY"
			case !column.Nullable:
				definition += " NOT NULL"
			}
			definitions = append(definitions, definition)
		}
		statement := fmt.Sprintf("create table if not exists %s (%s)",
			db.QualifiedTable(table.Name), strings.Join(definitions, ", "))
		if _, err := db.pool.Exec(ctx, statement); err != nil {
			panic("database: cannot create table " + table.Name + ": " + err.Error())
		}
		for _, index := range table.Unique {
			columns := make([]string, 0, len(index.Columns))
			for _, column := range index.Columns {
				columns = append(columns, quoteIdentifier(column))
			}
			indexStatement := fmt.Sprintf("create unique index if not exists %s on %s (%s)",
				quoteIdentifier(index.Name), db.QualifiedTable(table.Name),
				strings.Join(columns, ", "))
			if _, err := db.pool.Exec(ctx, indexStatement); err != nil {
				panic("database: cannot create unique index " + index.Name + ": " + err.Error())
			}
		}
	}
}

// QualifiedTable is `"schema"."table"`, quoted so a name that needs quoting works and a name
// that does not is unchanged.
func (db *PostgresDB) QualifiedTable(table string) string {
	if db.schema == "" {
		return quoteIdentifier(table)
	}
	return quoteIdentifier(db.schema) + "." + quoteIdentifier(table)
}

// quoteIdentifier doubles any embedded quote, which is the only escape a quoted SQL identifier
// has. Identifiers here come from the PROGRAM (an entity's declared table name), never from a
// request, but quoting is what keeps that true if one ever does.
func quoteIdentifier(name string) string {
	return `"` + strings.ReplaceAll(name, `"`, `""`) + `"`
}

// ── Executing ─────────────────────────────────────────────────────────────────
//
// Four executors, because a Tesl query is one of four shapes. Each takes SQL the EMITTER built,
// so nothing here decides what a query says.

// Every statement goes through `executor` rather than through the pool directly: inside a
// `transaction { … }` the statements have to share ONE connection, and the transaction is the
// only thing that knows which. Both *pgxpool.Pool and pgx.Tx answer this shape, so the choice
// is made once, here, rather than at each of the executors below.
type pgExecutor interface {
	Query(ctx context.Context, sql string, arguments ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, arguments ...any) pgx.Row
	Exec(ctx context.Context, sql string, arguments ...any) (pgconn.CommandTag, error)
}

func (db *PostgresDB) executor() pgExecutor {
	if transaction := currentTransaction(); transaction != nil {
		return transaction
	}
	return db.pool
}

// PgQuery runs a select and scans every row through `scan`.
func PgQuery[Row any](db *PostgresDB, statement string, arguments []any,
	scan func(pgx.CollectableRow) (Row, error)) []Row {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	rows, err := db.executor().Query(ctx, statement, arguments...)
	if err != nil {
		panic("database: " + err.Error())
	}
	collected, err := pgx.CollectRows(rows, scan)
	if err != nil {
		panic("database: " + err.Error())
	}
	return collected
}

func PgQueryPlan[Row any](db *PostgresDB, plan PgPlan,
	scan func(pgx.CollectableRow) (Row, error)) []Row {
	rows := PgQuery(db, plan.SQL, plan.arguments(), scan)
	if plan.Capture != nil {
		plan.Capture(len(rows))
	}
	return rows
}

// PgQueryOne is `selectOne`: the first row, or Nothing. `limit 1` is the emitter's job, so this
// only decides what "no row" means.
func PgQueryOne[Row any](db *PostgresDB, statement string, arguments []any,
	scan func(pgx.CollectableRow) (Row, error)) Maybe[Row] {
	rows := PgQuery(db, statement, arguments, scan)
	if len(rows) == 0 {
		return Nothing[Row]()
	}
	return Something(rows[0])
}

func PgQueryOnePlan[Row any](db *PostgresDB, plan PgPlan,
	scan func(pgx.CollectableRow) (Row, error)) Maybe[Row] {
	rows := PgQueryPlan(db, plan, scan)
	if len(rows) == 0 {
		return Nothing[Row]()
	}
	return Something(rows[0])
}

// PgExec runs a statement that answers no rows, and reports how many it touched.
func PgExec(db *PostgresDB, statement string, arguments []any) int64 {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	tag, err := db.executor().Exec(ctx, statement, arguments...)
	if err != nil {
		panic("database: " + err.Error())
	}
	return tag.RowsAffected()
}

func PgExecPlan(db *PostgresDB, plan PgPlan) int64 {
	rows := PgExec(db, plan.SQL, plan.arguments())
	if plan.Capture != nil {
		plan.Capture(int(rows))
	}
	return rows
}

// PgCount is `count … from …`: one row, one number.
func PgCount(db *PostgresDB, statement string, arguments []any) Int {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	row := db.executor().QueryRow(ctx, statement, arguments...)
	var counted int64
	if err := row.Scan(&counted); err != nil {
		panic("database: " + err.Error())
	}
	return FromInt64(counted)
}

func PgCountPlan(db *PostgresDB, plan PgPlan) Int {
	count := PgCount(db, plan.SQL, plan.arguments())
	if plan.Capture != nil {
		if value, ok := count.Int64(); ok {
			plan.Capture(int(value))
		}
	}
	return count
}

// PgScalar is the aggregate executor: one row, one value, scanned by the emitter's own reader
// because the column's type is the entity's rather than something this file can know.
func PgScalar[Value any](db *PostgresDB, statement string, arguments []any,
	scan func(pgx.Row) (Value, error)) Value {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	value, err := scan(db.executor().QueryRow(ctx, statement, arguments...))
	if err != nil {
		panic("database: " + err.Error())
	}
	return value
}

func PgScalarPlan[Value any](db *PostgresDB, plan PgPlan,
	scan func(pgx.Row) (Value, error)) Value {
	value := PgScalar(db, plan.SQL, plan.arguments(), scan)
	if plan.Capture != nil {
		plan.Capture(1)
	}
	return value
}

// PgSumMoney is `selectSum` over a Money column. The statement answers the total, the number of
// DISTINCT currencies and one witness code in a single row, because the two refusals need those
// facts and a second query could see a different set of rows than the sum did.
//
// A stored code that is not an ISO 4217 currency is data corruption or a schema written by an
// incompatible build, and it traps rather than decoding into a half-formed Money — Racket's
// `money-stored-currency` takes the same line.
func PgSumMoney(db *PostgresDB, statement string, arguments []any, entity, field string) Money {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	var total pgtype.Numeric
	var distinct int64
	var witness *string
	if err := db.executor().QueryRow(ctx, statement, arguments...).
		Scan(&total, &distinct, &witness); err != nil {
		panic("database: " + err.Error())
	}
	currency := Currency{}
	if witness != nil {
		known := CurrencyFromCode(*witness)
		if !known.IsSomething() {
			panic("field " + field + " on entity " + entity + ": stored currency code " + *witness +
				" is not a known ISO 4217 currency — the column holds corrupt data or was" +
				" written by an incompatible schema")
		}
		currency = known.SomethingValue
	}
	return MoneySumResult(entity, field, PgIntOf(total), currency, int(distinct))
}

func PgSumMoneyPlan(db *PostgresDB, plan PgPlan, entity, field string) Money {
	value := PgSumMoney(db, plan.SQL, plan.arguments(), entity, field)
	if plan.Capture != nil {
		plan.Capture(1)
	}
	return value
}

// PgTruncate empties a table, for a test block that starts from an empty store. It is the
// Postgres counterpart of `TableTruncate`, and it exists for the same reason: one test block's
// rows must not be another's.
func PgTruncate(db *PostgresDB, table string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := db.executor().Exec(ctx, "truncate table "+db.QualifiedTable(table)); err != nil {
		// A table that does not exist yet is not an error here: a test may run before anything
		// created it, and the bootstrap is what creates it.
		if !strings.Contains(err.Error(), "does not exist") {
			panic("database: cannot truncate " + table + ": " + err.Error())
		}
	}
}

// ── Values ────────────────────────────────────────────────────────────────────
//
// An `Int` is arbitrary precision on both sides — Tesl's integers are unbounded and the column is
// NUMERIC — so it travels as a pgtype.Numeric rather than through int64, which would silently
// fail exactly where the arbitrary precision matters.

// PgInt binds an Int as a NUMERIC parameter. It goes through the decimal TEXT of the value
// rather than through int64, because a Tesl Int is unbounded and int64 is exactly where that
// stops being true.
func PgInt(value Int) pgtype.Numeric {
	parsed, ok := new(big.Int).SetString(value.String(), 10)
	if !ok {
		panic("database: " + value.String() + " is not an integer")
	}
	return pgtype.Numeric{Int: parsed, Exp: 0, Valid: true}
}

// PgIntOf reads a NUMERIC (or any integer column) back into an Int.
func PgIntOf(value pgtype.Numeric) Int {
	if !value.Valid || value.Int == nil {
		return FromInt64(0)
	}
	if value.Exp == 0 {
		return fromBig(new(big.Int).Set(value.Int))
	}
	// A scale the column carries but a Tesl Int cannot: the value is not an integer, and
	// answering a truncated one would be a silent wrong answer.
	if value.Exp > 0 {
		scaled := new(big.Int).Set(value.Int)
		ten := big.NewInt(10)
		for range int(value.Exp) {
			scaled.Mul(scaled, ten)
		}
		return fromBig(scaled)
	}
	panic("database: a NUMERIC column holds a fractional value where Tesl expects an Int")
}

// PgNull binds a `Maybe X` column: Nothing is SQL NULL, Something is the bound value. The
// binding of the inner value is the caller's, because only the emitter knows the column's type.
func PgNull[T any](value Maybe[T], bind func(T) any) any {
	if !value.IsSomething() {
		return nil
	}
	return bind(value.SomethingValue)
}

// MaybeOfPointer reads a nullable column back: a NULL is Nothing, and anything else is decoded
// by the caller's reader. The reader is a thunk rather than a value so the decode is not run on
// the NULL — dereferencing the carrier there would panic.
func MaybeOfPointer[Carrier any, Value any](carrier *Carrier, decode func() Value) Maybe[Value] {
	if carrier == nil {
		return Nothing[Value]()
	}
	return Something(decode())
}

// PgBigint binds a PosixMillis-shaped value, whose column is BIGINT.
func PgBigint(value Int) int64 {
	exact, ok := value.Int64()
	if !ok {
		panic("database: " + value.String() + " does not fit a BIGINT column")
	}
	return exact
}
