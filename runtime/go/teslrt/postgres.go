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
// NOT YET SHIPPED WITH AN EMITTED PROGRAM, deliberately. A declared database is inert on both
// backends until something CONNECTS to it, and the only thing that connects is `with database D`
// — every `with database` in the corpus names a Memory-backed database, and the emitter refuses
// the Postgres case rather than silently reading the in-memory store. So this file is absent
// from compiler/gen/gen_go_runtime.ml's list: it is verified here (postgres_test.go, against the
// same shared cluster the Racket Postgres tests use) and joins an emitted project when the
// emitter can route a query to it.
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

// PgQuery runs a select and scans every row through `scan`.
func PgQuery[Row any](db *PostgresDB, statement string, arguments []any,
	scan func(pgx.CollectableRow) (Row, error)) []Row {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	rows, err := db.pool.Query(ctx, statement, arguments...)
	if err != nil {
		panic("database: " + err.Error())
	}
	collected, err := pgx.CollectRows(rows, scan)
	if err != nil {
		panic("database: " + err.Error())
	}
	return collected
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

// PgExec runs a statement that answers no rows, and reports how many it touched.
func PgExec(db *PostgresDB, statement string, arguments []any) int64 {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	tag, err := db.pool.Exec(ctx, statement, arguments...)
	if err != nil {
		panic("database: " + err.Error())
	}
	return tag.RowsAffected()
}

// PgCount is `count … from …`: one row, one number.
func PgCount(db *PostgresDB, statement string, arguments []any) Int {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	row := db.pool.QueryRow(ctx, statement, arguments...)
	var counted int64
	if err := row.Scan(&counted); err != nil {
		panic("database: " + err.Error())
	}
	return FromInt64(counted)
}

// PgTruncate empties a table, for a test block that starts from an empty store. It is the
// Postgres counterpart of `TableTruncate`, and it exists for the same reason: one test block's
// rows must not be another's.
func PgTruncate(db *PostgresDB, table string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := db.pool.Exec(ctx, "truncate table "+db.QualifiedTable(table)); err != nil {
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

// PgBigint binds a PosixMillis-shaped value, whose column is BIGINT.
func PgBigint(value Int) int64 {
	exact, ok := value.Int64()
	if !ok {
		panic("database: " + value.String() + " does not fit a BIGINT column")
	}
	return exact
}
