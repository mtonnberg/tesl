//go:build tesl_migration_test

package teslrt

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestPgMigrationAdmissionFenceLastsUntilTransactionCommit(t *testing.T) {
	f, db := pgAdmissionTestDatabase(t)
	wrote, resume := make(chan struct{}), make(chan struct{})
	defer func() {
		select {
		case <-resume:
		default:
			close(resume)
		}
	}()
	writer := make(chan any, 1)
	go func() {
		writer <- recoverDebugSQLFailure(func() {
			WithTransaction(func() {
				PgExec(db, "update notes_app.notes set active=false", nil)
				close(wrote)
				<-resume
			})
		})
	}()
	select {
	case <-wrote:
	case failure := <-writer:
		t.Fatalf("write failed: %v", failure)
	case <-f.ctx.Done():
		t.Fatal("write did not finish")
	}
	retired := make(chan error, 1)
	go func() {
		retired <- func() error {
			tx, err := f.installer.Begin(f.ctx)
			if err != nil {
				return err
			}
			defer func() { _ = tx.Rollback(context.Background()) }()
			if _, err := tx.Exec(f.ctx, "select pg_catalog.pg_advisory_xact_lock($1::integer,1)", db.migration.fenceNamespace); err != nil {
				return err
			}
			if _, err := tx.Exec(f.ctx, "update notes_app.tesl_schema_state set min_version=2,compat_floor=2"); err != nil {
				return err
			}
			return tx.Commit(f.ctx)
		}()
	}()
	for {
		var waiting int
		if err := f.worker.QueryRow(f.ctx, `select count(*) from pg_catalog.pg_locks where locktype='advisory' and classid=$1::oid and objid=1 and mode='ExclusiveLock' and not granted`, db.migration.fenceNamespace).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting == 1 {
			break
		}
		select {
		case err := <-retired:
			t.Fatalf("retirement passed an open writer: %v", err)
		case <-f.ctx.Done():
			t.Fatal("retirement did not wait")
		case <-time.After(10 * time.Millisecond):
		}
	}
	var active bool
	if err := f.worker.QueryRow(f.ctx, "select active from notes_app.notes").Scan(&active); err != nil || !active {
		t.Fatalf("uncommitted write escaped: %v,%v", active, err)
	}
	close(resume)
	if failure := <-writer; failure != nil {
		t.Fatalf("admitted old writer could not commit: %v", failure)
	}
	if err := <-retired; err != nil {
		t.Fatal(err)
	}
	if err := f.worker.QueryRow(f.ctx, "select active from notes_app.notes").Scan(&active); err != nil || active {
		t.Fatalf("admitted write was lost: %v,%v", active, err)
	}
	pgRequireAdmissionRefusal(t, recoverDebugSQLFailure(func() { PgExec(db, "insert into notes_app.notes(id,active) values ('too-late',true)", nil) }))
}

func TestPgMigrationAdmissionCannotRecoverAndCommitARefusedTransaction(t *testing.T) {
	f, db := pgAdmissionTestDatabase(t)
	pgAdmissionRetire(t, f, db)
	refused := false
	failure := recoverDebugSQLFailure(func() {
		WithTransaction(func() {
			refused = recoverDebugSQLFailure(func() { PgExec(db, "insert into notes_app.notes(id,active) values ('forbidden',true)", nil) }) != nil
		})
	})
	if !refused {
		t.Fatal("inner statement did not refuse")
	}
	pgRequireAdmissionRefusal(t, failure)
	// A size-one pool must recover after rollback and serve a surviving binary.
	survivor := &PostgresDB{pool: db.pool, schema: db.schema, migration: &pgMigrationAdmission{version: 2, fenceNamespace: db.migration.fenceNamespace, databaseUUID: db.migration.databaseUUID}}
	PgExec(survivor, "insert into notes_app.notes(id,active) values ('survivor',true)", nil)
	if n := PgCount(survivor, "select count(*) from notes_app.notes", nil); n.String() != "2" {
		t.Fatalf("refusal leaked a write or pool state: %s", n.String())
	}
}

func TestPgMigrationAdmissionProtectsQueueAndOutboxWrites(t *testing.T) {
	for _, kind := range []string{"claim", "renew", "email claim", "publish", "transactional publish", "legacy dispatch", "pubsub prune"} {
		t.Run(kind, func(t *testing.T) {
			f, db := pgAdmissionTestDatabase(t)
			declaration := &Database{open: db}
			queue := &pgQueueBackend{pgStore: pgStore{database: declaration}, name: "jobs"}
			queue.lastReclaim.Store(time.Now().Add(time.Hour).UnixNano()) // Exercise claim itself, not the preceding sweep.
			ensureTable(db, jobsTable, jobsTableDDL)
			ensureTable(db, outboxTable, outboxTableDDL)
			if err := createPubsubOutbox(f.ctx, db); err != nil {
				t.Fatal(err)
			}
			f.call(t, "insert into "+db.QualifiedTable(jobsTable)+"(id,queue,job_type,payload,status) values ('job','jobs','Job','{}','pending')")
			f.call(t, "insert into "+db.QualifiedTable(outboxTable)+"(status,next_attempt_at) values ('pending',now())")
			f.call(t, "insert into "+db.QualifiedTable(pubsubOutboxTable)+"(channel,key,payload,dispatch_seq,dispatched_at) values ('Events','key','{}',1,now()-interval '2 hours'),('Events','key','{}',null,null)")
			var leaseBefore time.Time
			if kind == "renew" {
				f.call(t, "update "+db.QualifiedTable(jobsTable)+" set status='processing',claim_token='claim:1',claim_seq=1,lease_until=now()+interval '10 minutes'")
				if err := f.worker.QueryRow(f.ctx, "select lease_until from "+db.QualifiedTable(jobsTable)).Scan(&leaseBefore); err != nil {
					t.Fatal(err)
				}
			}
			pgAdmissionRetire(t, f, db)
			runtime := &pgPubsub{database: declaration, ctx: f.ctx}
			var operationErr error
			failure := recoverDebugSQLFailure(func() {
				switch kind {
				case "claim":
					queue.dequeue(jobPending)
				case "renew":
					_, operationErr = queue.renewClaim(f.ctx, db, db.QualifiedTable(jobsTable), "job", "claim:1", time.Minute)
				case "email claim":
					(&pgOutboxBackend{pgStore: pgStore{database: declaration}}).claimDue(1)
				case "publish":
					runtime.publish("Events", "key", "{}")
				case "transactional publish":
					WithTransaction(func() { runtime.publish("Events", "key", "{}") })
				case "legacy dispatch":
					_, operationErr = dispatchLegacyPubsubPending(f.ctx, f.worker, db)
				case "pubsub prune":
					operationErr = runtime.prune(f.worker, db)
				}
			})
			if operationErr != nil {
				var refusal *pgMigrationAdmissionError
				if !errors.As(operationErr, &refusal) {
					t.Fatalf("wrong background refusal: %v", operationErr)
				}
			} else {
				pgRequireAdmissionRefusal(t, failure)
			}
			var pending int
			if kind == "renew" {
				var lease time.Time
				if err := f.worker.QueryRow(f.ctx, "select lease_until from "+db.QualifiedTable(jobsTable)).Scan(&lease); err != nil || !lease.Equal(leaseBefore) {
					t.Fatalf("retired renewal changed lease: %v,%v", lease, err)
				}
			} else if err := f.worker.QueryRow(f.ctx, "select count(*) from "+db.QualifiedTable(jobsTable)+" where status='pending'").Scan(&pending); err != nil || pending != 1 {
				t.Fatalf("retired worker claimed a job: %d,%v", pending, err)
			}
			if err := f.worker.QueryRow(f.ctx, "select count(*) from "+db.QualifiedTable(outboxTable)+" where locked_at is null and claim_token is null").Scan(&pending); err != nil || pending != 1 {
				t.Fatalf("retired worker claimed an email: %d,%v", pending, err)
			}
			if err := f.worker.QueryRow(f.ctx, "select count(*) from "+db.QualifiedTable(pubsubOutboxTable)).Scan(&pending); err != nil || pending != 2 {
				t.Fatalf("retired pubsub changed outbox rows: %d,%v", pending, err)
			}
			if err := f.worker.QueryRow(f.ctx, "select count(*) from "+db.QualifiedTable(pubsubOutboxTable)+" where dispatch_seq is null").Scan(&pending); err != nil || pending != 1 {
				t.Fatalf("retired dispatcher assigned a sequence: %d,%v", pending, err)
			}
		})
	}
}

func TestPgMigrationAdmissionPreventsUnadmittedPubsubDeliveryAndCursor(t *testing.T) {
	for _, kind := range []string{"prepare", "drain"} {
		t.Run(kind, func(t *testing.T) {
			f, db := pgAdmissionTestDatabase(t)
			if err := createPubsubOutbox(f.ctx, db); err != nil {
				t.Fatal(err)
			}
			f.call(t, "insert into "+db.QualifiedTable(pubsubOutboxTable)+"(channel,key,payload,dispatch_seq,dispatched_at) values ('Events','key','{}',1,now())")
			channel := NewSseChannel("Events")
			listener := channel.register("key")
			defer channel.unregister("key", listener)
			runtime := &pgPubsub{ctx: f.ctx, channels: map[string][]*SseChannel{"Events": {channel}}}
			arrived, resume := pgPauseExpansionBoundary(t, "read-before-admit", 1)
			defer resume()
			done := make(chan error, 1)
			go func() {
				if kind == "prepare" {
					done <- runtime.prepareOn(db, f.worker)
				} else {
					done <- runtime.drain(f.worker, db)
				}
			}()
			select {
			case <-arrived:
			case err := <-done:
				t.Fatalf("pubsub read ended early: %v", err)
			case <-f.ctx.Done():
				t.Fatal("pubsub read did not pause")
			}
			pgAdmissionRetire(t, f, db)
			resume()
			var refusal *pgMigrationAdmissionError
			if err := <-done; !errors.As(err, &refusal) {
				t.Fatalf("pubsub did not refuse: %v", err)
			}
			if runtime.ready || runtime.cursor() != 0 {
				t.Fatal("unadmitted read changed readiness or cursor")
			}
			expectNoEvent(t, listener, 10*time.Millisecond)
		})
	}
}

func pgAdmissionTestDatabase(t *testing.T) (*pgControlTestFixture, *PostgresDB) {
	t.Helper()
	f := pgNewControlTest(t)
	f.install(t, 1)
	state := f.expand(t, 2)
	f.call(t, "insert into notes_app.notes(id,active) values ('retained',true)")
	config, err := pgxpool.ParseConfig(f.worker.Config().ConnString())
	if err != nil {
		t.Fatal(err)
	}
	config.ConnConfig = f.worker.Config().Copy()
	// The runtime must select READ COMMITTED explicitly. Otherwise the first
	// fence SELECT could capture admission state before waiting for retirement.
	config.ConnConfig.RuntimeParams["default_transaction_isolation"] = "repeatable read"
	config.MaxConns = 1
	pool, err := pgxpool.NewWithConfig(f.ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	db := &PostgresDB{pool: pool, schema: f.namespace, migration: &pgMigrationAdmission{
		version: 1, fenceNamespace: state.FenceNamespace, databaseUUID: state.DatabaseUUID}}
	previous := boundDatabase.Swap(&Database{Name: "Main", open: db})
	t.Cleanup(func() { boundDatabase.Store(previous) })
	return f, db
}

// Simulate the future retirement transition under its specified exclusive
// fence. Phase 1 must already protect requests even though retirement itself is
// not exposed by the current control interface.
func pgAdmissionRetire(t *testing.T, f *pgControlTestFixture, db *PostgresDB) {
	t.Helper()
	tx, err := f.installer.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	if _, err := tx.Exec(f.ctx, "select pg_catalog.pg_advisory_xact_lock($1::integer,1)", db.migration.fenceNamespace); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(f.ctx, "update notes_app.tesl_schema_state set min_version=2,compat_floor=2"); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(f.ctx); err != nil {
		t.Fatal(err)
	}
}

func pgRequireAdmissionRefusal(t *testing.T, failure any) {
	t.Helper()
	rejection, ok := failure.(RequestRejection)
	if !ok || rejection.Status != 503 || rejection.Message != "database schema version unavailable" {
		t.Fatalf("expected admission refusal, got %T: %v", failure, failure)
	}
}

func TestPgMigrationAdmissionReadsCheckAfterSQL(t *testing.T) {
	for _, kind := range []string{"query", "query plan", "one", "one plan", "count", "scalar", "money", "explicit transaction"} {
		t.Run(kind, func(t *testing.T) {
			f, db := pgAdmissionTestDatabase(t)
			arrived, resume := pgPauseExpansionBoundary(t, "read-before-admit", 1)
			defer resume()
			scan := func(row pgx.CollectableRow) (string, error) {
				var value string
				err := row.Scan(&value)
				return value, err
			}
			statement := "select id from notes_app.notes"
			call := func() {
				switch kind {
				case "query":
					PgQuery(db, statement, nil, scan)
				case "query plan":
					PgQueryPlan(db, PgPlan{SQL: statement}, scan)
				case "one":
					PgQueryOne(db, statement, nil, scan)
				case "one plan":
					PgQueryOnePlan(db, PgPlan{SQL: statement}, scan)
				case "count":
					PgCount(db, "select count(*) from notes_app.notes", nil)
				case "scalar":
					PgScalar(db, "select count(*) from notes_app.notes", nil, func(row pgx.Row) (int64, error) { var n int64; err := row.Scan(&n); return n, err })
				case "money":
					PgSumMoney(db, "select 100::numeric,1::bigint,'USD'::text", nil, "Note", "amount")
				case "explicit transaction":
					WithTransaction(func() { PgQuery(db, statement, nil, scan) })
				}
			}
			done := make(chan any, 1)
			go func() { done <- recoverDebugSQLFailure(call) }()
			select {
			case <-arrived:
			case failure := <-done:
				t.Fatalf("read ended before admission boundary: %v", failure)
			case <-f.ctx.Done():
				t.Fatal("read did not reach final admission")
			}
			// A read must hold no advisory fence: retirement can commit while
			// the old read's result is buffered but has not been admitted.
			pgAdmissionRetire(t, f, db)
			resume()
			pgRequireAdmissionRefusal(t, <-done)
			lease, err := db.pool.Acquire(f.ctx)
			if err != nil {
				t.Fatal(err)
			}
			status := lease.Conn().PgConn().TxStatus()
			lease.Release()
			if status != 'I' {
				t.Fatal("refused read leaked a transaction")
			}
		})
	}
}

func TestPgMigrationAdmissionWritesFenceBeforeFreshAdmission(t *testing.T) {
	for _, kind := range []string{"exec", "returning", "returning CTE", "updateReturnOne", "truncate", "explicit transaction"} {
		t.Run(kind, func(t *testing.T) {
			f, db := pgAdmissionTestDatabase(t)
			retirement, err := f.installer.Begin(f.ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = retirement.Rollback(context.Background()) }()
			if _, err := retirement.Exec(f.ctx, "select pg_catalog.pg_advisory_xact_lock($1::integer,1)", db.migration.fenceNamespace); err != nil {
				t.Fatal(err)
			}
			statement := "update notes_app.notes set active=false"
			scan := func(row pgx.CollectableRow) (string, error) { var id string; err := row.Scan(&id); return id, err }
			done := make(chan any, 1)
			go func() {
				done <- recoverDebugSQLFailure(func() {
					switch kind {
					case "exec":
						PgExec(db, statement, nil)
					case "returning":
						PgWriteQuery(db, statement+" returning id", nil, scan)
					case "returning CTE":
						PgWriteQuery(db, "with changed as ("+statement+" returning id) select id from changed", nil, scan)
					case "updateReturnOne":
						pgUpdateReturnOne(db, PgPlan{SQL: statement + " returning id"}, scan)
					case "truncate":
						PgTruncate(db, "notes")
					case "explicit transaction":
						WithTransaction(func() { PgExec(db, statement, nil) })
					}
				})
			}()
			for {
				var waiting int
				if err := f.worker.QueryRow(f.ctx, `select count(*) from pg_catalog.pg_locks where locktype='advisory' and classid=$1::oid and objid=1 and mode='ShareLock' and not granted`, db.migration.fenceNamespace).Scan(&waiting); err != nil {
					t.Fatal(err)
				}
				if waiting == 1 {
					break
				}
				select {
				case failure := <-done:
					t.Fatalf("write skipped its fence: %v", failure)
				case <-f.ctx.Done():
					t.Fatal("write did not wait for retirement")
				case <-time.After(10 * time.Millisecond):
				}
			}
			if _, err := retirement.Exec(f.ctx, "update notes_app.tesl_schema_state set min_version=2,compat_floor=2"); err != nil {
				t.Fatal(err)
			}
			if err := retirement.Commit(f.ctx); err != nil {
				t.Fatal(err)
			}
			pgRequireAdmissionRefusal(t, <-done)
			var count int
			if err := f.worker.QueryRow(f.ctx, "select count(*) from notes_app.notes where active").Scan(&count); err != nil || count != 1 {
				t.Fatalf("retired write changed rows: %d,%v", count, err)
			}
		})
	}
}

func TestPgMigrationAdmissionExplicitReadChecksAgainAtCommit(t *testing.T) {
	f, db := pgAdmissionTestDatabase(t)
	read, resume := make(chan struct{}), make(chan struct{})
	defer func() {
		select {
		case <-resume:
		default:
			close(resume)
		}
	}()
	done := make(chan any, 1)
	go func() {
		done <- recoverDebugSQLFailure(func() {
			WithTransaction(func() {
				if got := PgCount(db, "select count(*) from notes_app.notes", nil); got.String() != "1" {
					panic(fmt.Sprintf("unexpected count %s", got.String()))
				}
				close(read)
				<-resume
			})
		})
	}()
	select {
	case <-read:
	case failure := <-done:
		t.Fatalf("transaction ended early: %v", failure)
	case <-f.ctx.Done():
		t.Fatal("read did not finish")
	}
	pgAdmissionRetire(t, f, db)
	close(resume)
	pgRequireAdmissionRefusal(t, <-done)
}
