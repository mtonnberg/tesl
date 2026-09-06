package teslrt

import (
	"context"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"

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
	// Immutable source information linked by the compiler, not live DB state.
	migrationHistory *PgCompiledMigrationHistory
	// Declarations may initialize before or after the compiled history is linked.
	// Worker preflight closes registration under this same mutex before any I/O.
	migrationFacilities        map[pgMigrationFacility]struct{}
	migrationQueues            map[*Queue]struct{}
	migrationFacilitiesClosed  bool
	applicationPreflightClosed bool
}

// The database `with database D` most recently bound, program-wide.
//
// Racket holds this in ONE parameter (`current-database-runtime`), so at most one database is
// connected at a time and `transaction { … }` needs no argument to know which server it opens a
// transaction on — it opens one on whatever is bound. That is the model reproduced here, rather
// than a per-declaration binding that would have to invent an answer for a `transaction` written
// where two databases are in scope.
var boundDatabase atomic.Pointer[Database]

// Binding ownership also owns every worker started within that lexical scope.
// Retain the parent chain so nested same-connection scopes cannot hide live
// outer workers when a later nested scope attempts a different binding.
type pgDatabaseScope struct {
	database   *Database
	connection *PostgresDB
	workers    *runtimeWorkerScope
	parent     *pgDatabaseScope
}

var boundDatabaseScope atomic.Pointer[pgDatabaseScope]

// Application configuration owns connections. Query modules resolve the compiled
// database identity at execution time, avoiding a Go import back-edge from a
// handler or schema package to the application that imports it.
var databaseIdentities sync.Map

func RegisterDatabaseIdentity(identity string, database *Database) *Database {
	if identity == "" || database == nil {
		panic("database: invalid compiled identity")
	}
	previous, loaded := databaseIdentities.LoadOrStore(identity, database)
	if loaded && previous != database {
		panic("database: duplicate compiled identity " + identity)
	}
	return database
}

func ResolveDatabaseIdentity(identity string) *Database {
	database, ok := databaseIdentities.Load(identity)
	if !ok {
		panic("database: unregistered compiled identity " + identity)
	}
	// Only RegisterDatabaseIdentity writes this private table.
	return database.(*Database) //nolint:forcetypeassert
}

var databaseBindings = struct {
	mutex sync.Mutex
	cond  *sync.Cond
	owner uint64
	depth int
}{}

func init() {
	databaseBindings.cond = sync.NewCond(&databaseBindings.mutex)
	currentRuntimeLifecycle = currentDatabaseLifecycle
	currentRuntimeWorkers = func() runtimeWorkers {
		if scope := boundDatabaseScope.Load(); scope != nil {
			return scope.workers
		}
		return nil
	}
}

func currentDatabaseLifecycle() context.Context {
	if scope := boundDatabaseScope.Load(); scope != nil {
		return scope.workers.ctx
	}
	database := boundDatabase.Load()
	if database == nil {
		return context.Background()
	}
	connection := database.bound()
	if connection == nil || connection.embedded == nil {
		return context.Background()
	}
	service := connection.embedded
	service.mutex.Lock()
	defer service.mutex.Unlock()
	if service.generation == nil {
		return context.Background()
	}
	return service.generation.ctx
}

// acquireDatabaseBinding serializes process-wide bindings while allowing the same goroutine
// to nest them. The API has no context or handle to carry a binding explicitly, so overlap
// cannot be made request-local without changing generated programs; serialization makes the
// existing process-global contract deterministic instead of letting scopes unbind each other.
func acquireDatabaseBinding() {
	owner := goroutineID()
	databaseBindings.mutex.Lock()
	for databaseBindings.owner != 0 && databaseBindings.owner != owner {
		databaseBindings.cond.Wait()
	}
	databaseBindings.owner = owner
	databaseBindings.depth++
	databaseBindings.mutex.Unlock()
}

func releaseDatabaseBinding() {
	owner := goroutineID()
	databaseBindings.mutex.Lock()
	defer databaseBindings.mutex.Unlock()
	if databaseBindings.owner != owner || databaseBindings.depth == 0 {
		panic("database: binding released by a goroutine that does not own it")
	}
	databaseBindings.depth--
	if databaseBindings.depth == 0 {
		databaseBindings.owner = 0
		databaseBindings.cond.Broadcast()
	}
}

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
	if borrowWorkerDatabase(database, body) {
		return
	}
	if err := pgVerifyMigrationFacilities(database); err != nil {
		panic(err)
	}
	// Refuse a cross-database scope before even opening/bootstraping its pool.
	// It cannot participate atomically in the caller's existing transaction.
	if currentTransaction() != nil {
		currentTransactionFor(database.bound())
		// The existing transaction already owns this physical connection. Reopening
		// or rebinding would borrow another connection or wait on the serving scope.
		body()
		return
	}
	var connection *PostgresDB
	if history, versioned := database.CompiledMigrationHistory(); versioned {
		var release func()
		connection, release = openVersionedPostgres(database.Config, history)
		if release != nil {
			defer release()
		}
	} else {
		connection = OpenPostgres(database.Config, database.Tables)
	}
	withDatabaseBinding(database, connection, body)
}

// A worker is already owned by a scope whose binding cannot be released until
// that worker returns. Reacquiring the main goroutine's binding lock would
// deadlock its drain. Borrow exactly that binding, without a new lifetime or
// connection; reject another database before opening or bootstrapping anything.
func borrowWorkerDatabase(database *Database, body func()) bool {
	identity := goroutineID()
	for scope := boundDatabaseScope.Load(); scope != nil; scope = scope.parent {
		if !scope.workers.owns(identity) {
			continue
		}
		if scope.database != database || database.bound() != scope.connection || boundDatabase.Load() != database {
			panic("database: worker cannot enter another database scope")
		}
		body()
		return true
	}
	return false
}

// The production binding boundary is shared by ordinary and versioned pools.
// Pools remain reusable, but no worker may outlive the binding it dispatches on.
func withDatabaseBinding(database *Database, connection *PostgresDB, body func()) {
	acquireDatabaseBinding()
	defer releaseDatabaseBinding()
	previousScope := boundDatabaseScope.Load()
	var suspended []*runtimeWorkerScope
	defer func() {
		for _, scope := range suspended {
			scope.resume()
		}
	}()
	for scope := previousScope; scope != nil; scope = scope.parent {
		if scope.database == database && scope.connection == connection {
			continue
		}
		if !scope.workers.suspend() {
			panic("database: cannot replace a binding while its workers are running")
		}
		suspended = append(suspended, scope.workers)
	}
	parent := currentRuntimeLifecycle()
	if connection.embedded != nil {
		if err := connection.embedded.check(); err != nil {
			panic(pgFailure("database: Embedded migration service refused before binding", err))
		}
		service := connection.embedded
		service.mutex.Lock()
		generation := service.generation
		service.mutex.Unlock()
		// Direct ancestry propagates cancellation synchronously. An AfterFunc
		// bridge could lose a stop immediately followed by Serve. Same-pool
		// nesting already descends from this generation through its outer scope.
		if generation != nil && (previousScope == nil || previousScope.connection != connection) {
			parent = generation.ctx
		}
	}
	signalContext, stopSignals := signal.NotifyContext(parent, os.Interrupt, syscall.SIGTERM)
	defer stopSignals()
	workers := newRuntimeWorkerScope(signalContext, goroutineID)
	defer workers.cancel()
	database.mutex.Lock()
	previous := database.open
	database.open = connection
	database.mutex.Unlock()
	previousBound := boundDatabase.Swap(database)
	scope := &pgDatabaseScope{database: database, connection: connection, workers: workers, parent: previousScope}
	boundDatabaseScope.Store(scope)
	defer func() {
		// Keep both lookup paths intact during handler cleanup and completion,
		// even when Serve failed or the application body is unwinding a panic.
		workers.join()
		boundDatabaseScope.Store(previousScope)
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
type pgTransactionBinding struct {
	database    *PostgresDB
	transaction pgx.Tx
}

var openTransactions sync.Map // goroutine id -> pgTransactionBinding

// WithTransaction is `transaction { … }`: the body runs atomically with respect to a trap.
// Against PostgreSQL it is a real BEGIN/COMMIT, rolled back if the body panics so a check
// failure halfway through leaves nothing behind. Against the in-memory store it is the same
// PROMISE kept a different way — see `WithMemoryTransaction` — because the spec says the
// transaction rolls back on any exception and does not carve the Memory store out of that, and
// `tesl test` runs on the Memory store: a test asserting atomicity has to observe the same
// outcome production does.
func WithTransaction(body func()) {
	key := goroutineID()
	if _, nested := openTransactions.Load(key); nested {
		// Refuse before borrowing a second connection: a size-one pool is
		// already leased by the outer transaction and cannot satisfy BEGIN.
		panic("transaction: a transaction is already open")
	}
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
	options := pgx.TxOptions{}
	if connection.migration != nil {
		options.IsoLevel = pgx.ReadCommitted
	}
	transaction, err := connection.pool.BeginTx(beginCtx, options)
	if err != nil {
		panic(pgFailure("transaction: cannot begin", err))
	}
	openTransactions.Store(key, pgTransactionBinding{database: connection, transaction: transaction})
	committed := false
	defer func() {
		openTransactions.Delete(key)
		queueTransactionClaims.Delete(transaction)
		if !committed {
			ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
			defer cancel()
			_ = transaction.Rollback(ctx)
		}
	}()
	body()
	commitCtx, cancelCommit := context.WithTimeout(context.Background(), pgLeaseTimeout())
	defer cancelCommit()
	if err := pgAdmitMigrationTransaction(commitCtx, transaction, connection, false); err != nil {
		panic(pgFailure("transaction", err))
	}
	if err := transaction.Commit(commitCtx); err != nil {
		panic(pgFailure("transaction: cannot commit", err))
	}
	committed = true
}

// currentTransaction is the open transaction for THIS goroutine, if any.
func currentTransaction() pgx.Tx {
	if found, open := openTransactions.Load(goroutineID()); open {
		if binding, ok := found.(pgTransactionBinding); ok {
			return binding.transaction
		}
	}
	return nil
}

// A transaction belongs to one opened database, not merely to a goroutine.
// Reusing its connection for another database can execute that database's SQL
// against the wrong server and would also apply the wrong migration fence.
func currentTransactionFor(database *PostgresDB) pgx.Tx {
	if found, open := openTransactions.Load(goroutineID()); open {
		binding, ok := found.(pgTransactionBinding)
		if !ok || binding.database != database || binding.transaction == nil {
			panic("transaction: cannot use another database inside an open transaction")
		}
		return binding.transaction
	}
	return nil
}

// The group owns workers through claim, handler, lease renewal and completion.
// Cancellation stops new iterations, not in-flight work. A claim which passed
// beginIteration before cancellation is already in flight and must finish too.
// The enclosing scope must join this group before changing its database binding.
type runtimeWorkerScope struct {
	ctx       context.Context
	identify  func() uint64
	cancel    context.CancelFunc
	mutex     sync.Mutex
	workers   sync.WaitGroup
	live      int
	members   map[uint64]struct{}
	closed    bool
	suspended int
}

func newRuntimeWorkerScope(parent context.Context, identify func() uint64) *runtimeWorkerScope {
	ctx, cancel := context.WithCancel(parent)
	return &runtimeWorkerScope{ctx: ctx, cancel: cancel, members: map[uint64]struct{}{}, identify: identify}
}

func (scope *runtimeWorkerScope) start(run func()) {
	scope.mutex.Lock()
	defer scope.mutex.Unlock()
	if scope.suspended != 0 {
		panic("workers: cannot start while another database is bound")
	}
	if scope.closed || scope.ctx.Err() != nil {
		return
	}
	scope.live++
	scope.workers.Add(1)
	go func() {
		identity := scope.identify()
		scope.mutex.Lock()
		scope.members[identity] = struct{}{}
		scope.mutex.Unlock()
		defer func() {
			scope.mutex.Lock()
			scope.live--
			delete(scope.members, identity)
			scope.mutex.Unlock()
			scope.workers.Done()
		}()
		run()
	}()
}

func (scope *runtimeWorkerScope) beginIteration() bool {
	scope.mutex.Lock()
	defer scope.mutex.Unlock()
	return !scope.closed && scope.suspended == 0 && scope.ctx.Err() == nil
}

// Pause registration atomically with checking for live workers. Without this,
// a callback could start workers between the check and a nested DB rebind.
func (scope *runtimeWorkerScope) suspend() bool {
	scope.mutex.Lock()
	defer scope.mutex.Unlock()
	if scope.live != 0 {
		return false
	}
	scope.suspended++
	return true
}

func (scope *runtimeWorkerScope) resume() {
	scope.mutex.Lock()
	defer scope.mutex.Unlock()
	scope.suspended--
}

func (scope *runtimeWorkerScope) join() {
	scope.mutex.Lock()
	scope.closed = true
	scope.cancel()
	scope.mutex.Unlock()
	scope.workers.Wait()
}

func (scope *runtimeWorkerScope) owns(identity uint64) bool {
	scope.mutex.Lock()
	defer scope.mutex.Unlock()
	_, exists := scope.members[identity]
	return exists
}

func (scope *runtimeWorkerScope) context() context.Context { return scope.ctx }
