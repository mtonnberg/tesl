package teslrt

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type pgQueueListenerTrace struct {
	mutex                  sync.Mutex
	queries                []string
	inheritedNotifications int
}

func (trace *pgQueueListenerTrace) TraceQueryStart(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryStartData) context.Context {
	trace.mutex.Lock()
	trace.queries = append(trace.queries, data.SQL)
	trace.mutex.Unlock()
	return ctx
}
func (*pgQueueListenerTrace) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}
func (trace *pgQueueListenerTrace) snapshot() []string {
	trace.mutex.Lock()
	defer trace.mutex.Unlock()
	return append([]string(nil), trace.queries...)
}
func (trace *pgQueueListenerTrace) attempts() int {
	n := 0
	for _, query := range trace.snapshot() {
		if query == "select current_user, session_user" {
			n++
		}
	}
	return n
}
func pgQueueListenerSetup(t *testing.T, current, latest int) (*pgQueueRuntimeFixture, *pgPubsub, *pgQueueListenerTrace) {
	t.Helper()
	shrinkPubsubIntervals(t)
	f := pgNewQueueRuntimeTest(t, current, latest)
	trace := &pgQueueListenerTrace{}
	config := f.db.pool.Config()
	config.ConnConfig.Tracer = trace
	// Rebuild only this unbound test pool, retaining its admission hook. The
	// listener must replace an inherited notification callback even if a future
	// production opener or fixture clears callbacks during pool construction.
	config.ConnConfig.OnNotification = func(*pgconn.PgConn, *pgconn.Notification) {
		trace.mutex.Lock()
		trace.inheritedNotifications++
		trace.mutex.Unlock()
	}
	pool, err := pgxpool.NewWithConfig(f.ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	f.db.pool.Close()
	f.db.pool = pool
	t.Cleanup(pool.Close)
	listener := pubsubRuntimeOf(t, f.database)
	t.Cleanup(listener.Close)
	return f, listener, trace
}
func pgQueueAwaitWake(t *testing.T, queue *Queue) {
	t.Helper()
	select {
	case <-queue.wake:
	case <-time.After(5 * time.Second):
		t.Fatal("checked queue was not woken")
	}
}
func pgQueueNoWake(t *testing.T, queue *Queue) {
	t.Helper()
	select {
	case <-queue.wake:
		t.Fatal("unexpected queue wake")
	case <-time.After(100 * time.Millisecond):
	}
}
func pgQueueAwaitListener(t *testing.T, listener *pgPubsub, old uint32) uint32 {
	t.Helper()
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		if pid := listener.ListenerPID(); pid != 0 && pid != old {
			return pid
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("protected listener did not connect")
	return 0
}
func pgQueueKillListener(t *testing.T, f *pgQueueRuntimeFixture, pid uint32) {
	t.Helper()
	var killed bool
	if err := f.installer.QueryRow(f.ctx, "select pg_terminate_backend($1)", int64(pid)).Scan(&killed); err != nil || !killed {
		t.Fatal("terminate listener", pid, killed, err)
	}
}
func pgQueueNoSSE(t *testing.T, f *pgQueueRuntimeFixture, listener *pgPubsub, trace *pgQueueListenerTrace) {
	t.Helper()
	var objects int
	if err := f.installer.QueryRow(f.ctx, "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='notes_app' and c.relname like 'tesl_pubsub%'").Scan(&objects); err != nil || objects != 0 {
		t.Fatal("queue-only listener acquired SSE storage", objects, err)
	}
	listener.mutex.Lock()
	ready, cursor := listener.ready, listener.dispatchCursor
	listener.mutex.Unlock()
	if ready || cursor != 0 {
		t.Fatal("queue listener initialized an SSE baseline")
	}
	trace.mutex.Lock()
	inherited := trace.inheritedNotifications
	trace.mutex.Unlock()
	if inherited != 0 {
		t.Fatal("dedicated listener inherited another connection's notification callback", inherited)
	}
	listens := 0
	for _, query := range trace.snapshot() {
		lower := strings.ToLower(strings.TrimSpace(query))
		if strings.Contains(lower, "tesl_pubsub") || strings.HasPrefix(lower, "create ") || strings.HasPrefix(lower, "alter ") || strings.HasPrefix(lower, "drop ") {
			t.Fatal("queue listener touched SSE or DDL", query)
		}
		if strings.HasPrefix(lower, "listen ") {
			listens++
			if lower != `listen "tesl_queue"` {
				t.Fatal("unexpected LISTEN channel", query)
			}
		}
	}
	if listens == 0 {
		t.Fatal("test never observed actual LISTEN")
	}
}

func TestQueueListenerAliasesAreSeparateAndIdempotent(t *testing.T) {
	renamed := NewQueue("Renamed", 1)
	collision := NewQueue("Notifications", 1)
	listener := &pgPubsub{queues: map[string][]*Queue{}}
	listener.registerQueue(renamed)
	listener.registerQueue(collision)
	listener.registerQueueAlias("Notifications", renamed)
	listener.registerQueueAlias("Notifications", renamed)
	if len(listener.queueAliases["Notifications"]) != 1 || renamed.name != "Renamed" {
		t.Fatal("alias changed identity or duplicated registration")
	}
	listener.wakeQueueAlias("Notifications")
	pgQueueAwaitWake(t, renamed)
	pgQueueNoWake(t, collision)
	listener.wakeQueues("Notifications")
	pgQueueAwaitWake(t, collision)
	pgQueueNoWake(t, renamed)
}

func TestQueueListenerProtectedCommitRollbackAndNoSSE(t *testing.T) {
	f, listener, trace := pgQueueListenerSetup(t, 1, 1)
	f.bound(func() {
		pgQueueAwaitListener(t, listener, 0)
		pgQueueAwaitWake(t, f.queue)
		if f.queue.name != "AppLocalReminderJobs" || f.backend.name != "AppLocalReminderJobs" {
			t.Fatal("schema alias renamed the App queue")
		}
		tx, err := f.request.Begin(f.ctx)
		if err != nil {
			t.Fatal(err)
		}
		f.enqueue(t, tx, 1, "committed-notify")
		pgQueueNoWake(t, f.queue)
		if err := tx.Commit(f.ctx); err != nil {
			t.Fatal(err)
		}
		pgQueueAwaitWake(t, f.queue)
		tx, err = f.request.Begin(f.ctx)
		if err != nil {
			t.Fatal(err)
		}
		f.enqueue(t, tx, 1, "rolled-back-notify")
		pgQueueNoWake(t, f.queue)
		if err := tx.Rollback(f.ctx); err != nil {
			t.Fatal(err)
		}
		pgQueueNoWake(t, f.queue)
		for _, notification := range [][2]string{{pubsubNotifyChannel, "Notifications"}, {queueNotifyChannel, f.queue.name}, {queueNotifyChannel, "UnknownContract"}} {
			if _, err := f.request.Exec(f.ctx, "select pg_notify($1,$2)", notification[0], notification[1]); err != nil {
				t.Fatal(err)
			}
			pgQueueNoWake(t, f.queue)
		}
		var count int
		if err := f.installer.QueryRow(f.ctx, "select count(*) from notes_app.tesl_jobs where id='rolled-back-notify'").Scan(&count); err != nil || count != 0 {
			t.Fatal("notification test did not roll back stored payload", count, err)
		}
		var temporary bool
		if err := f.request.QueryRow(f.ctx, "select has_database_privilege(current_user,current_database(),'TEMP')").Scan(&temporary); err != nil || temporary {
			t.Fatal("listener test accidentally has TEMP", temporary, err)
		}
		pgQueueNoSSE(t, f, listener, trace)
	})
	deadline := time.Now().Add(3 * time.Second)
	for listener.ListenerPID() != 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if listener.ListenerPID() != 0 {
		t.Fatal("queue listener retained an unbound database")
	}
	listener.Close()
	select {
	case <-listener.done:
	default:
		t.Fatal("Close returned before listener joined")
	}
}

func TestQueueListenerReconnectRevalidatesExactCandidateCatalog(t *testing.T) {
	f, listener, trace := pgQueueListenerSetup(t, 1, 3)
	f.bound(func() {
		pid := pgQueueAwaitListener(t, listener, 0)
		pgQueueAwaitWake(t, f.queue)
		pgQueueKillListener(t, f, pid)
		pid = pgQueueAwaitListener(t, listener, pid)
		pgQueueAwaitWake(t, f.queue)
		f.enqueue(t, f.request, 1, "after-reconnect")
		pgQueueAwaitWake(t, f.queue)
		before := trace.attempts()
		if _, err := f.installer.Exec(f.ctx, "alter table notes_app.tesl_queue_payloads add column unknown_listener_column text"); err != nil {
			t.Fatal(err)
		}
		pgQueueKillListener(t, f, pid)
		deadline := time.Now().Add(8 * time.Second)
		for trace.attempts() <= before && time.Now().Before(deadline) {
			time.Sleep(10 * time.Millisecond)
		}
		if trace.attempts() <= before {
			t.Fatal("test never observed a reconnect validation attempt")
		}
		// The exact verification must finish/refuse, not just have begun its first query.
		tx, err := f.request.BeginTx(f.ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted, AccessMode: pgx.ReadOnly})
		if err != nil {
			t.Fatal(err)
		}
		err = pgVerifyQueueCandidateConnection(f.ctx, tx, f.db, f.db.queueRuntime)
		_ = tx.Rollback(f.ctx)
		if err == nil || !strings.Contains(err.Error(), "tesl_queue_payloads") || !strings.Contains(err.Error(), "differs") {
			t.Fatal("changed protected table was accepted", err)
		}
		if _, err := f.request.Exec(f.ctx, "select pg_notify('tesl_queue','Notifications')"); err != nil {
			t.Fatal(err)
		}
		pgQueueNoWake(t, f.queue)
		if listener.ListenerPID() != 0 {
			t.Fatal("changed catalog published an admitted listener")
		}
		if _, err := f.installer.Exec(f.ctx, "alter table notes_app.tesl_queue_payloads drop column unknown_listener_column"); err != nil {
			t.Fatal(err)
		}
		pgQueueAwaitListener(t, listener, pid)
		pgQueueAwaitWake(t, f.queue)
		f.enqueue(t, f.request, 1, "after-repair")
		pgQueueAwaitWake(t, f.queue)
		pgQueueNoSSE(t, f, listener, trace)
		listener.Close()
		select {
		case <-listener.done:
		default:
			t.Fatal("Close returned before active listener joined")
		}
		if listener.ListenerPID() != 0 {
			t.Fatal("canceled listener retained a backend")
		}
		f.enqueue(t, f.request, 1, "after-listener-close")
		pgQueueNoWake(t, f.queue)
	})
}

func TestQueueListenerVerifierRejectsChangedBindingAndLogin(t *testing.T) {
	f, listener, _ := pgQueueListenerSetup(t, 1, 1)
	// Startup verification runs before Database.open is published.
	if f.database.bound() != nil {
		t.Fatal("fixture prematurely bound database")
	}
	verify := func(db *PostgresDB, binding *pgQueueRuntime) error {
		tx, err := f.request.BeginTx(f.ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted, AccessMode: pgx.ReadOnly})
		if err != nil {
			return err
		}
		defer func() { _ = tx.Rollback(f.ctx) }()
		return pgVerifyQueueCandidateConnection(f.ctx, tx, db, binding)
	}
	if err := verify(f.db, f.db.queueRuntime); err != nil {
		t.Fatal("valid pre-binding candidate refused", err)
	}
	for _, test := range []struct {
		name, want string
		change     func(*PostgresDB, *pgMigrationAdmission, *pgQueueRuntime)
	}{
		{"namespace", "compiled database binding", func(db *PostgresDB, _ *pgMigrationAdmission, _ *pgQueueRuntime) { db.schema = "another" }},
		{"version", "compiled database binding", func(_ *PostgresDB, a *pgMigrationAdmission, _ *pgQueueRuntime) { a.version = 2 }},
		{"uuid", "identity differs", func(_ *PostgresDB, a *pgMigrationAdmission, _ *pgQueueRuntime) {
			a.databaseUUID = "11111111-1111-1111-1111-111111111111"
		}},
		{"fence", "identity differs", func(_ *PostgresDB, a *pgMigrationAdmission, _ *pgQueueRuntime) { a.fenceNamespace++ }},
		{"login", "login changed", func(_ *PostgresDB, a *pgMigrationAdmission, _ *pgQueueRuntime) { a.worker = f.roles.Worker }},
		{"source", "application registration", func(_ *PostgresDB, _ *pgMigrationAdmission, b *pgQueueRuntime) {
			b.history.SourceCompilerABI = strings.Repeat("b", 64)
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			admission := *f.db.migration
			binding := *f.db.queueRuntime
			db := &PostgresDB{pool: f.db.pool, schema: f.db.schema, migration: &admission, queueRuntime: &binding}
			test.change(db, &admission, &binding)
			if err := verify(db, &binding); err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatal("expected exact binding refusal", err)
			}
		})
	}
	// Even a caller that accidentally pins the schema-worker login cannot make
	// a Worker-topology application pool use that more privileged identity.
	admission := *f.db.migration
	admission.worker = f.roles.Worker
	workerDB := &PostgresDB{pool: f.db.pool, schema: f.db.schema, migration: &admission, queueRuntime: f.db.queueRuntime}
	tx, err := f.worker.BeginTx(f.ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted, AccessMode: pgx.ReadOnly})
	if err != nil {
		t.Fatal(err)
	}
	err = pgVerifyQueueCandidateConnection(f.ctx, tx, workerDB, f.db.queueRuntime)
	_ = tx.Rollback(f.ctx)
	if err == nil || !strings.Contains(err.Error(), "declared topology") {
		t.Fatal("schema-worker became an application login", err)
	}
	if _, err := listener.listenQueue(f.db); err == nil || !strings.Contains(err.Error(), "no longer bound") {
		t.Fatal("unbound candidate opened a listener", err)
	}
	if err := pgVerifyMigrationConnection(f.ctx, f.request, f.db); err == nil {
		t.Fatal("production format guard admitted private candidate")
	}
}
