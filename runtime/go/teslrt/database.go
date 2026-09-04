package teslrt

import (
	"context"
	"sync"
	"sync/atomic"

	"github.com/jackc/pgx/v5"
)

// A `database D = Database { … }` declaration at run time, and the dispatch that decides
// whether a query reads the in-memory table or the PostgreSQL server.
//
// WHY THE DISPATCH IS DYNAMIC. Which store an entity's rows live in is NOT a property of the
// entity: it is a property of whether something has CONNECTED. Racket's `select-many` asks
// `database-runtime-for-entity`, which answers a connection only while a `with database D`
// is active and only for an entity D manages; outside that extent the very same query reads
// the in-memory source. That is not an accident of the implementation — it is what lets a
// `test` block exercise a Postgres-backed entity with no server anywhere. So the emitted
// code carries BOTH forms for an entity of a Postgres-backed database (the Go predicate and
// the SQL statement), and picks here, exactly as Racket picks there.
//
// A program whose databases are all `backend: Memory` never reaches this file: its entities
// emit the plain `Table*` calls they always did, and its go.mod requires nothing.
type Database struct {
	// Name as the declaration writes it, which is what a refusal names.
	Name string
	// Config and Tables are what a connection needs: the DSN parts and the schema to create.
	Config PostgresConfig
	Tables []PostgresTable

	mutex sync.RWMutex
	// The live connection, non-nil only inside `with database D`.
	open *PostgresDB
}

// The database `with database D` most recently bound, program-wide.
//
// Racket holds this in ONE parameter (`current-database-runtime`), so at most one database is
// connected at a time and `transaction { … }` needs no argument to know which server it opens a
// transaction on — it opens one on whatever is bound. That is the model reproduced here, rather
// than a per-declaration binding that would have to invent an answer for a `transaction` written
// where two databases are in scope.
var boundDatabase atomic.Pointer[Database]

// NewDatabase, PostgresTableOf and PostgresColumnOf are what a `database` declaration emits.
// They are constructors rather than struct literals because gofmt ALIGNS the values in a
// multi-line composite literal and breaks the alignment run at a nested multi-line value — a
// rule the emitter would have to reproduce exactly, at every shape, forever. A call whose
// arguments sit one per line is stable at every size instead.
func NewDatabase(name string, config PostgresConfig, tables []PostgresTable) *Database {
	return &Database{Name: name, Config: config, Tables: tables}
}

func PostgresTableOf(name string, columns ...PostgresColumn) PostgresTable {
	return PostgresTable{Name: name, Columns: columns}
}

// PostgresTableWithIndexes is the same table plus its declared UNIQUE indexes, which the
// bootstrap creates. Kept separate from PostgresTableOf so a table with none stays a one-line
// call in emitted code.
func PostgresTableWithIndexes(name string, unique []PostgresIndex,
	columns ...PostgresColumn) PostgresTable {
	return PostgresTable{Name: name, Columns: columns, Unique: unique}
}

func PostgresIndexOf(name string, columns ...string) PostgresIndex {
	return PostgresIndex{Name: name, Columns: columns}
}

func PostgresColumnOf(name, columnType string, primaryKey, nullable bool) PostgresColumn {
	return PostgresColumn{Name: name, Type: columnType, PrimaryKey: primaryKey, Nullable: nullable}
}

// WithDatabase is `with database D { … }`: it connects, runs the body with D bound, and
// unbinds afterwards — including when the body panics, since a check failure unwinds through
// here and the next block must not inherit a binding from it.
//
// The POOL is not closed on the way out, unlike Racket's `disconnect-database`. `OpenPostgres`
// is idempotent per configuration, so the second `with database D` in a program reuses the
// first one's pool rather than paying a fresh handshake; a pool that outlives the block holds
// idle connections, which is what a pool is for. Nothing observable differs — a query outside
// the block does not reach the server either way, because the binding is what routes it.
func WithDatabase(database *Database, body func()) {
	connection := OpenPostgres(database.Config, database.Tables)
	database.mutex.Lock()
	previous := database.open
	database.open = connection
	database.mutex.Unlock()
	previousBound := boundDatabase.Swap(database)
	defer func() {
		boundDatabase.Store(previousBound)
		database.mutex.Lock()
		database.open = previous
		database.mutex.Unlock()
	}()
	body()
}

// bound answers the connection a statement should run on, or nil for the in-memory store.
func (database *Database) bound() *PostgresDB {
	if database == nil {
		return nil
	}
	database.mutex.RLock()
	defer database.mutex.RUnlock()
	return database.open
}

// ── Transactions ──────────────────────────────────────────────────────────────
//
// A transaction has to run every statement on ONE connection, so the executor a statement
// picks up has to follow the code that opened it — and that code is an ordinary Tesl function
// which may call other ordinary Tesl functions, none of which carry a handle.
//
// Racket solves this with a parameter, which is THREAD-local, and its web server serves each
// request on its own thread. The faithful Go reading of "thread-local" for a server that
// serves each request on its own goroutine is goroutine-local, so that is what this is: the
// open transaction is keyed by goroutine id, and a statement finds it only from inside the
// goroutine that began it. Two requests in two transactions therefore cannot see each other's
// uncommitted rows, which a package-level handle would get wrong.
//
// The one place this differs from Racket: a goroutine STARTED inside a transaction does not
// inherit it, where a Racket thread created inside a `parameterize` does. A transaction body
// that spawns work and expects that work to join the transaction is refused by the emitter
// rather than silently running outside it.
var openTransactions sync.Map // goroutine id -> pgx.Tx

// WithTransaction is `transaction { … }`: the body runs atomically with respect to a trap.
// Against PostgreSQL it is a real BEGIN/COMMIT, rolled back if the body panics so a check
// failure halfway through leaves nothing behind. Against the in-memory store it is the same
// PROMISE kept a different way — see `WithMemoryTransaction` — because the spec says the
// transaction rolls back on any exception and does not carve the Memory store out of that, and
// `tesl test` runs on the Memory store: a test asserting atomicity has to observe the same
// outcome production does.
func WithTransaction(body func()) {
	database := boundDatabase.Load()
	connection := database.bound()
	if connection == nil {
		WithMemoryTransaction(body)
		return
	}
	// The lease bound applies to acquiring the connection and issuing BEGIN, not to the body:
	// the body's own statements each run under their own lease (see the executors), and the
	// commit gets a fresh bound below, so a transaction may legitimately outlive one lease.
	beginCtx, cancelBegin := context.WithTimeout(context.Background(), pgLeaseTimeout())
	defer cancelBegin()
	transaction, err := connection.pool.Begin(beginCtx)
	if err != nil {
		panic(pgFailure("transaction: cannot begin", err))
	}
	key := goroutineID()
	if _, nested := openTransactions.Load(key); nested {
		// Racket nests by starting a SAVEPOINT; until that is built, a nested block would
		// silently commit the outer one at its own end, so it is refused here rather than
		// answered with weaker atomicity than it claims.
		_ = transaction.Rollback(beginCtx)
		panic("transaction: a transaction is already open on database " + database.Name)
	}
	openTransactions.Store(key, transaction)
	committed := false
	defer func() {
		openTransactions.Delete(key)
		if !committed {
			ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
			defer cancel()
			_ = transaction.Rollback(ctx)
		}
	}()
	body()
	commitCtx, cancelCommit := context.WithTimeout(context.Background(), pgLeaseTimeout())
	defer cancelCommit()
	if err := transaction.Commit(commitCtx); err != nil {
		panic(pgFailure("transaction: cannot commit", err))
	}
	committed = true
}

// currentTransaction is the open transaction for THIS goroutine, if any.
func currentTransaction() pgx.Tx {
	if found, open := openTransactions.Load(goroutineID()); open {
		if transaction, ok := found.(pgx.Tx); ok {
			return transaction
		}
	}
	return nil
}
