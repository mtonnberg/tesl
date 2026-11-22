//go:build tesl_migration_test

package teslrt

import (
	"context"
	"errors"
	"net"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// pgWireTurns counts how often the client starts writing after it has read,
// i.e. how many times a request waited for the server. An optional delay is
// added to every such wait to stand in for network round-trip time.
type pgWireTurns struct {
	mu      sync.Mutex
	turns   int
	writing bool
	delay   time.Duration
}

func (w *pgWireTurns) reset() (turns int) {
	w.mu.Lock()
	defer w.mu.Unlock()
	turns, w.turns = w.turns, 0
	return turns
}

type pgTurnConn struct {
	net.Conn
	wire *pgWireTurns
}

func (c *pgTurnConn) Write(b []byte) (int, error) {
	c.wire.mu.Lock()
	if !c.wire.writing {
		c.wire.turns++
		c.wire.writing = true
	}
	c.wire.mu.Unlock()
	return c.Conn.Write(b)
}

func (c *pgTurnConn) Read(b []byte) (int, error) {
	c.wire.mu.Lock()
	wait := c.wire.writing
	c.wire.writing = false
	delay := c.wire.delay
	c.wire.mu.Unlock()
	if wait && delay > 0 {
		time.Sleep(delay)
	}
	return c.Conn.Read(b)
}

// pgStatementLog records every statement in the order its result was read,
// including batch members.
type pgStatementLog struct {
	mu   sync.Mutex
	sqls []string
}

func (l *pgStatementLog) add(sql string) {
	l.mu.Lock()
	l.sqls = append(l.sqls, sql)
	l.mu.Unlock()
}
func (l *pgStatementLog) take() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	taken := l.sqls
	l.sqls = nil
	return taken
}
func (l *pgStatementLog) TraceQueryStart(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryStartData) context.Context {
	l.add(data.SQL)
	return ctx
}
func (l *pgStatementLog) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}
func (l *pgStatementLog) TraceBatchStart(ctx context.Context, _ *pgx.Conn, _ pgx.TraceBatchStartData) context.Context {
	return ctx
}
func (l *pgStatementLog) TraceBatchQuery(_ context.Context, _ *pgx.Conn, data pgx.TraceBatchQueryData) {
	if data.Err == nil {
		l.add(data.SQL)
	}
}
func (l *pgStatementLog) TraceBatchEnd(context.Context, *pgx.Conn, pgx.TraceBatchEndData) {}

// pgPipelineTestDatabase is the admission fixture on a pool whose wire turns
// and statements are observable. format5 selects the compatibility-fenced read.
func pgPipelineTestDatabase(t *testing.T, mode pgx.QueryExecMode, format5 bool) (*pgControlTestFixture, *PostgresDB, *pgWireTurns, *pgStatementLog) {
	t.Helper()
	f, base := pgAdmissionTestDatabase(t)
	config, err := pgxpool.ParseConfig(f.worker.Config().ConnString())
	if err != nil {
		t.Fatal(err)
	}
	config.ConnConfig = f.worker.Config().Copy()
	config.ConnConfig.RuntimeParams["default_transaction_isolation"] = "repeatable read"
	config.ConnConfig.DefaultQueryExecMode = mode
	wire, log := &pgWireTurns{}, &pgStatementLog{}
	config.ConnConfig.Tracer = log
	dialer := &net.Dialer{}
	config.ConnConfig.DialFunc = func(ctx context.Context, network, address string) (net.Conn, error) {
		conn, err := dialer.DialContext(ctx, network, address)
		if err != nil {
			return nil, err
		}
		return &pgTurnConn{Conn: conn, wire: wire}, nil
	}
	config.MaxConns = 1
	pool, err := pgxpool.NewWithConfig(f.ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	protocol := *base.migration
	if format5 {
		protocol.controlFormat = pgRowControlFormat
	}
	db := &PostgresDB{pool: pool, schema: base.schema, migration: &protocol}
	previous := boundDatabase.Swap(&Database{Name: "Main", open: db})
	t.Cleanup(func() { boundDatabase.Store(previous) })
	return f, db, wire, log
}

const pgPipelineTestQuery = "select id from notes_app.notes"

func pgPipelineTestRead(ctx context.Context, db *PostgresDB, ran *bool) ([]string, error) {
	return pgMigrationStatement(ctx, db, false, func(executor pgExecutor) ([]string, error) {
		*ran = true
		rows, err := executor.Query(ctx, pgPipelineTestQuery)
		if err != nil {
			return nil, err
		}
		return pgx.CollectRows(rows, pgx.RowTo[string])
	})
}

func pgRequireIdleLease(t *testing.T, ctx context.Context, db *PostgresDB) {
	t.Helper()
	lease, err := db.pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	status := lease.Conn().PgConn().TxStatus()
	lease.Release()
	if status != 'I' {
		t.Fatalf("read left its session in transaction state %q", status)
	}
}

var pgPipelineTestModes = map[string]pgx.QueryExecMode{
	"cache-statement": pgx.QueryExecModeCacheStatement,
	"exec":            pgx.QueryExecModeExec,
	"simple-protocol": pgx.QueryExecModeSimpleProtocol,
}

// The statements actually executed for an implicit format-5 read: admission
// after the compatibility key and before the query, and again after it.
func TestPgMigrationAdmissionPipelinedReadOrder(t *testing.T) {
	for name, mode := range pgPipelineTestModes {
		t.Run(name, func(t *testing.T) {
			f, db, _, log := pgPipelineTestDatabase(t, mode, true)
			var ran bool
			ids, err := pgPipelineTestRead(f.ctx, db, &ran)
			if err != nil || !slices.Equal(ids, []string{"retained"}) {
				t.Fatalf("read failed: %v %v", ids, err)
			}
			admit := pgAdmissionSQL(db, false)
			executed := log.take()
			want := []string{"begin isolation level read committed", pgReadFenceSQL, admit, pgPipelineTestQuery, admit, "commit"}
			if len(executed) < len(want) || !slices.Equal(executed[len(executed)-len(want):], want) {
				t.Fatalf("read statements out of protocol order:\n got %q\nwant %q", executed, want)
			}
			pgRequireIdleLease(t, f.ctx, db)
		})
	}
}

// A retired binary's read never reaches application SQL: the first admission
// in the opening pipeline refuses, and the caller's statements never run.
func TestPgMigrationAdmissionPipelinedReadRefusesBeforeApplicationSQL(t *testing.T) {
	for name, mode := range pgPipelineTestModes {
		t.Run(name, func(t *testing.T) {
			f, db, _, log := pgPipelineTestDatabase(t, mode, true)
			pgAdmissionRetire(t, f, db)
			log.take()
			var ran bool
			ids, err := pgPipelineTestRead(f.ctx, db, &ran)
			var refusal *pgMigrationAdmissionError
			if !errors.As(err, &refusal) || !strings.Contains(err.Error(), "schema version 1 is retired") {
				t.Fatalf("retired read was not refused by admission: %v", err)
			}
			if ran || ids != nil {
				t.Fatal("application SQL ran on a version that was not admitted")
			}
			if slices.Contains(log.take(), pgPipelineTestQuery) {
				t.Fatal("the query reached the server without admission")
			}
			pgRequireIdleLease(t, f.ctx, db)
		})
	}
}

// Pipelining keeps admission's snapshot after the lock grant: a read queued
// behind a compatibility drain observes a retirement committed while it
// waited, and refuses without running application SQL.
func TestPgMigrationAdmissionPipelinedReadAdmitsAfterCompatibilityKey(t *testing.T) {
	for name, mode := range pgPipelineTestModes {
		t.Run(name, func(t *testing.T) {
			f, db, _, _ := pgPipelineTestDatabase(t, mode, true)
			drain, err := pgx.ConnectConfig(f.ctx, f.installer.Config().Copy())
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = drain.Close(context.Background()) }()
			if _, err := drain.Exec(f.ctx, "select pg_catalog.pg_advisory_lock($1::integer,$2::integer)", -db.migration.fenceNamespace, db.migration.version); err != nil {
				t.Fatal(err)
			}
			var ran bool
			done := make(chan error, 1)
			go func() {
				_, err := pgPipelineTestRead(f.ctx, db, &ran)
				done <- err
			}()
			deadline := time.Now().Add(10 * time.Second)
			for {
				var waiting bool
				if err := f.installer.QueryRow(f.ctx, `select exists(select 1 from pg_catalog.pg_locks
 where locktype='advisory' and not granted and classid=($1::integer)::oid and objid=($2::integer)::oid)`,
					-db.migration.fenceNamespace, db.migration.version).Scan(&waiting); err != nil {
					t.Fatal(err)
				}
				if waiting {
					break
				}
				select {
				case err := <-done:
					t.Fatalf("read finished while the compatibility key was held exclusively: %v", err)
				default:
				}
				if time.Now().After(deadline) {
					t.Fatal("read never queued behind the compatibility key")
				}
				time.Sleep(5 * time.Millisecond)
			}
			pgAdmissionRetire(t, f, db)
			if _, err := drain.Exec(f.ctx, "select pg_catalog.pg_advisory_unlock($1::integer,$2::integer)", -db.migration.fenceNamespace, db.migration.version); err != nil {
				t.Fatal(err)
			}
			var refusal *pgMigrationAdmissionError
			if err := <-done; !errors.As(err, &refusal) {
				t.Fatalf("read admitted against the state from before its lock wait: %v", err)
			}
			if ran {
				t.Fatal("application SQL ran after a retirement committed during the lock wait")
			}
			pgRequireIdleLease(t, f.ctx, db)
		})
	}
}

// One implicit read waits for the server three times: {BEGIN, fence,
// admission}, the query, {admission, COMMIT}. The older control format has
// no fence and admission prefix but still pipelines COMMIT.
func TestPgMigrationAdmissionPipelinedReadRoundTrips(t *testing.T) {
	for _, format5 := range []bool{true, false} {
		for name, mode := range pgPipelineTestModes {
			label := name + "/format5"
			if !format5 {
				label = name + "/format4"
			}
			t.Run(label, func(t *testing.T) {
				f, db, wire, _ := pgPipelineTestDatabase(t, mode, format5)
				var ran bool
				// Connect and fill the statement cache first.
				for range 2 {
					if _, err := pgPipelineTestRead(f.ctx, db, &ran); err != nil {
						t.Fatal(err)
					}
				}
				wire.reset()
				if _, err := pgPipelineTestRead(f.ctx, db, &ran); err != nil {
					t.Fatal(err)
				}
				if got := wire.reset(); got != 3 {
					t.Fatalf("implicit read used %d round trips, want 3", got)
				}
				const rtt, reads = 2 * time.Millisecond, 20
				wire.mu.Lock()
				wire.delay = rtt
				wire.mu.Unlock()
				started := time.Now()
				for range reads {
					if _, err := pgPipelineTestRead(f.ctx, db, &ran); err != nil {
						t.Fatal(err)
					}
				}
				t.Logf("%s: %v per read with %v injected per round trip", label, time.Since(started)/reads, rtt)
			})
		}
	}
}
