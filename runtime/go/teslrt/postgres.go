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
	// PoolSize is the maximum number of live connections. Zero preserves Tesl's omitted
	// poolSize default of 10.
	PoolSize int
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
	pool           *pgxpool.Pool
	schema         string
	bootstrapMutex sync.Mutex
}

type postgresInitialization struct {
	done    chan struct{}
	db      *PostgresDB
	failure any
}

var postgresConnectOnce sync.Map // schema+dsn -> *postgresInitialization

// OpenPostgres connects, creates the schema and the declared tables if they are absent, and
// answers a pool. It is idempotent per configuration: a program with several databases on one
// cluster opens one pool per configuration rather than one per call site.
//
// The environment wins over the declaration for the password and the host, because those are
// deployment facts rather than program facts: `PGPASSWORD`, `PGHOST` and `PGPORT` are the names
// every other Postgres client already reads, so a deployment does not need a Tesl-specific one.
func OpenPostgres(config PostgresConfig, tables []PostgresTable) *PostgresDB {
	dsn := postgresDSN(config)
	poolConfig := postgresPoolConfig(config, dsn)
	key := fmt.Sprintf("%s\x00%s\x00%d", config.Schema, dsn, poolConfig.MaxConns)
	created := &postgresInitialization{done: make(chan struct{})}
	actual, loaded := postgresConnectOnce.LoadOrStore(key, created)
	initialization, ok := actual.(*postgresInitialization)
	if !ok {
		panic("database: connection registry holds an unexpected value")
	}
	if !loaded {
		initializePostgres(key, initialization, poolConfig, config.Schema, tables)
	} else {
		<-initialization.done
	}
	if initialization.failure != nil {
		panic(initialization.failure)
	}
	if initialization.db == nil {
		panic("database: PostgreSQL initialization completed without a pool")
	}
	if loaded {
		ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
		initialization.db.bootstrap(ctx, tables)
		cancel()
	}
	return initialization.db
}

func initializePostgres(key string, initialization *postgresInitialization,
	poolConfig *pgxpool.Config, schema string, tables []PostgresTable) {
	defer close(initialization.done)
	var pool *pgxpool.Pool
	defer func() {
		if failure := recover(); failure != nil {
			if pool != nil {
				pool.Close()
			}
			initialization.failure = failure
			postgresConnectOnce.CompareAndDelete(key, initialization)
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
	defer cancel()
	var err error
	pool, err = pgxpool.NewWithConfig(ctx, poolConfig)
	if err != nil {
		panic("database: cannot connect to PostgreSQL: " + err.Error())
	}
	db := &PostgresDB{pool: pool, schema: schema}
	db.bootstrap(ctx, tables)
	initialization.db = db
}

const defaultPostgresPoolSize = 10

func postgresPoolConfig(config PostgresConfig, dsn string) *pgxpool.Config {
	poolConfig, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		panic("database: invalid PostgreSQL configuration: " + err.Error())
	}
	size := config.PoolSize
	if size == 0 {
		size = defaultPostgresPoolSize
	}
	// validPostgresPoolSize proves size fits pgx's int32 limit.
	poolConfig.MaxConns = int32(validPostgresPoolSize(size)) // #nosec G115 -- range validated above
	return poolConfig
}

func validPostgresPoolSize(size int) int {
	const maxPoolSize = int64(1<<31 - 1)
	if size < 1 || int64(size) > maxPoolSize {
		panic(fmt.Sprintf("database: poolSize must be between 1 and %d", maxPoolSize))
	}
	return size
}

// PgPoolSize lowers `envInt name fallback` in PostgresConfig.poolSize.
func PgPoolSize(name string, fallback int) int {
	text := os.Getenv(name)
	if text == "" {
		return validPostgresPoolSize(fallback)
	}
	parsed, err := strconv.ParseInt(text, 10, 32)
	if err != nil || parsed < 1 {
		panic(fmt.Sprintf("envInt: invalid positive pool size environment value %s=%s", name, text))
	}
	return validPostgresPoolSize(int(parsed))
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

// bootstrap creates the schema, declared tables, and the runtime-owned pub/sub outbox before
// the Database can be bound. `if not exists` throughout: a second process starting at the same
// time must not fail. Application tables are never altered; the outbox's idempotent ALTERs are
// runtime metadata rather than application migration machinery.
func (db *PostgresDB) bootstrap(ctx context.Context, tables []PostgresTable) {
	db.bootstrapMutex.Lock()
	defer db.bootstrapMutex.Unlock()
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
	if err := createPubsubOutbox(ctx, db); err != nil {
		panic("database: cannot create the pub/sub outbox: " + err.Error())
	}
	if err := normalizeLegacyPubsubRows(db); err != nil {
		panic("database: cannot upgrade the pub/sub outbox: " + err.Error())
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

// ── The lease ─────────────────────────────────────────────────────────────────
//
// Every statement runs under ONE bound, the pool lease: the time a request may wait for a
// connection from the pool plus the time its statement may then take. `TESL_PG_POOL_LEASE_TIMEOUT_MS`
// sets it (default 10 s), as the spec documents; the bootstrap and the transaction's BEGIN and
// COMMIT use the same bound, so there is one knob rather than a scattering of literals.
//
// When the bound is exceeded the request is answered 503 rather than 500. A saturated pool is
// not a broken server: it is a full one, and `503` with "try again" is what tells a client (and
// a load balancer) to do exactly that, where a 500 tells it to give up. `pgFailure` is where a
// driver error becomes one or the other.

const defaultPgLeaseTimeout = 10 * time.Second

// pgLeaseTimeout reads the knob on every call rather than once, because it is cheap and a test
// that sets the environment must not be answered from a cache made by an earlier test. A value
// that is not a positive number is refused loudly: silently running with the default would hide
// a misspelled deployment setting until the first saturation.
func pgLeaseTimeout() time.Duration {
	text := strings.TrimSpace(os.Getenv("TESL_PG_POOL_LEASE_TIMEOUT_MS"))
	if text == "" {
		return defaultPgLeaseTimeout
	}
	parsed, err := strconv.ParseInt(text, 10, 64)
	if err != nil || parsed < 1 {
		panic("database: TESL_PG_POOL_LEASE_TIMEOUT_MS must be a positive number of milliseconds, not " +
			strconv.Quote(text))
	}
	return time.Duration(parsed) * time.Millisecond
}

// The rejection a lease that ran out becomes: `callHandler` maps a RequestRejection to the
// response it names, so a saturated pool answers 503 instead of the generic 500 any other trap
// becomes. The message is deliberately generic — it reaches the client.
var pgDatabaseBusy = RequestRejection{Status: 503, Message: "database busy, try again"}

// pgFailure is the panic value for a driver error: the lease running out (the pool never handed
// over a connection in time, or the statement did not finish in time) is the 503 rejection, and
// anything else keeps the driver's own text under `prefix`, for the operator log.
func pgFailure(prefix string, err error) any {
	if errors.Is(err, context.DeadlineExceeded) || pgconn.Timeout(err) {
		return pgDatabaseBusy
	}
	return prefix + ": " + err.Error()
}

// PgQuery runs a select and scans every row through `scan`.
func PgQuery[Row any](db *PostgresDB, statement string, arguments []any,
	scan func(pgx.CollectableRow) (Row, error)) []Row {
	ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
	defer cancel()
	rows, err := db.executor().Query(ctx, statement, arguments...)
	if err != nil {
		panic(pgFailure("database", err))
	}
	collected, err := pgx.CollectRows(rows, scan)
	if err != nil {
		panic(pgFailure("database", err))
	}
	migrationBoundary("query-complete")
	return collected
}

func PgQueryPlan[Row any](db *PostgresDB, plan PgPlan,
	scan func(pgx.CollectableRow) (Row, error)) []Row {
	rowCount := 0
	if plan.Capture != nil {
		defer func() { plan.Capture(rowCount) }()
	}
	rows := PgQuery(db, plan.SQL, plan.arguments(), scan)
	rowCount = len(rows)
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
	ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
	defer cancel()
	tag, err := db.executor().Exec(ctx, statement, arguments...)
	if err != nil {
		panic(pgFailure("database", err))
	}
	migrationBoundary("write-complete")
	return tag.RowsAffected()
}

func PgExecPlan(db *PostgresDB, plan PgPlan) int64 {
	rowCount := 0
	if plan.Capture != nil {
		defer func() { plan.Capture(rowCount) }()
	}
	rows := PgExec(db, plan.SQL, plan.arguments())
	rowCount = int(rows)
	return rows
}

// PgCount is `count … from …`: one row, one number.
func PgCount(db *PostgresDB, statement string, arguments []any) Int {
	ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
	defer cancel()
	row := db.executor().QueryRow(ctx, statement, arguments...)
	var counted int64
	if err := row.Scan(&counted); err != nil {
		panic(pgFailure("database", err))
	}
	return FromInt64(counted)
}

func PgCountPlan(db *PostgresDB, plan PgPlan) Int {
	rowCount := 0
	if plan.Capture != nil {
		defer func() { plan.Capture(rowCount) }()
	}
	count := PgCount(db, plan.SQL, plan.arguments())
	if value, ok := count.Int64(); ok {
		rowCount = int(value)
	}
	return count
}

// PgScalar is the aggregate executor: one row, one value, scanned by the emitter's own reader
// because the column's type is the entity's rather than something this file can know.
func PgScalar[Value any](db *PostgresDB, statement string, arguments []any,
	scan func(pgx.Row) (Value, error)) Value {
	ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
	defer cancel()
	value, err := scan(db.executor().QueryRow(ctx, statement, arguments...))
	if err != nil {
		panic(pgFailure("database", err))
	}
	return value
}

func PgScalarPlan[Value any](db *PostgresDB, plan PgPlan,
	scan func(pgx.Row) (Value, error)) Value {
	rowCount := 0
	if plan.Capture != nil {
		defer func() { plan.Capture(rowCount) }()
	}
	value := PgScalar(db, plan.SQL, plan.arguments(), scan)
	rowCount = 1
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
	ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
	defer cancel()
	var total pgtype.Numeric
	var distinct int64
	var witness *string
	if err := db.executor().QueryRow(ctx, statement, arguments...).
		Scan(&total, &distinct, &witness); err != nil {
		panic(pgFailure("database", err))
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
	// A SUM over no rows is NULL, and the row set being empty is what `MoneySumResult` refuses
	// (by the distinct count); reading the NULL as zero here lets it say so rather than trapping
	// on the column first.
	minorUnits := FromInt64(0)
	if total.Valid {
		minorUnits = PgIntOf(total)
	}
	return MoneySumResult(entity, field, minorUnits, currency, int(distinct))
}

func PgSumMoneyPlan(db *PostgresDB, plan PgPlan, entity, field string) Money {
	rowCount := 0
	if plan.Capture != nil {
		defer func() { plan.Capture(rowCount) }()
	}
	value := PgSumMoney(db, plan.SQL, plan.arguments(), entity, field)
	rowCount = 1
	return value
}

// PgTruncate empties a table, for a test block that starts from an empty store. It is the
// Postgres counterpart of `TableTruncate`, and it exists for the same reason: one test block's
// rows must not be another's.
func PgTruncate(db *PostgresDB, table string) {
	ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
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

// PgIntOf reads a NUMERIC (or any integer column) back into an Int — a NON-NULL one.
//
// A NULL traps. The emitted scanner reads a `Maybe Int` column into a `*pgtype.Numeric` and
// hands only a non-nil carrier here (`MaybeOfPointer` skips the decode on NULL), a `selectSum`
// is `coalesce(sum(…), 0)`, and `selectMax`/`selectMin` go through the same pointer carrier — so
// the only way a NULL reaches this function is a column Tesl typed as plain `Int` holding one:
// schema drift, or a row another tool wrote. Answering 0 there fabricated a balance; TEXT
// columns already trapped on the same shape, and the two must agree.
func PgIntOf(value pgtype.Numeric) Int {
	if !value.Valid || value.Int == nil {
		panic("database: a NUMERIC column holds NULL where Tesl expects an Int; " +
			"declare the field as `Maybe Int` if the column may be NULL")
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

// MaybeOfJSONColumn preserves the difference between SQL NULL and JSON null.
// pgx scans only SQL NULL to a nil []byte; a non-nil "null" must reach the
// type's decoder and be rejected if it is not a valid record or ADT.
func MaybeOfJSONColumn[Value any](carrier []byte, decode func([]byte) Value) Maybe[Value] {
	if carrier == nil {
		return Nothing[Value]()
	}
	return Something(decode(carrier))
}

// PgBigint binds a PosixMillis-shaped value, whose column is BIGINT.
func PgBigint(value Int) int64 {
	exact, ok := value.Int64()
	if !ok {
		panic("database: " + value.String() + " does not fit a BIGINT column")
	}
	return exact
}
