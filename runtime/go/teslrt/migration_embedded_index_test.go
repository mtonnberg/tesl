package teslrt

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

type pgEmbeddedTestScope struct {
	entered chan *PostgresDB
	done    chan struct{}
	release func()
	failure any
}

func pgStartEmbeddedTestScope(t *testing.T, database *Database) *pgEmbeddedTestScope {
	t.Helper()
	leave := make(chan struct{})
	scope := &pgEmbeddedTestScope{entered: make(chan *PostgresDB, 1), done: make(chan struct{}), release: sync.OnceFunc(func() { close(leave) })}
	go func() {
		scope.failure = recoverDebugSQLFailure(func() {
			WithDatabase(database, func() {
				scope.entered <- database.bound()
				<-leave
			})
		})
		close(scope.done)
	}()
	t.Cleanup(func() {
		scope.release()
		select {
		case <-scope.done:
		case <-time.After(10 * time.Second):
			t.Error("Embedded scope did not join after release")
		}
	})
	return scope
}

func pgEmbeddedIndexDatabase(t *testing.T, f *pgControlTestFixture, unique bool) *Database {
	t.Helper()
	database := pgBootTestDatabase(t, f, 2)
	history := pgIndexExpansionTestHistory(f.namespace, 2, unique)
	database.migrationHistory = &history
	return database
}

func pgEmbeddedIndexBlocker(t *testing.T, f *pgControlTestFixture) (pgx.Tx, func()) {
	t.Helper()
	conn, err := pgx.ConnectConfig(f.ctx, f.worker.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	tx, err := conn.Begin(f.ctx)
	if err != nil {
		_ = conn.Close(f.ctx)
		t.Fatal(err)
	}
	if _, err := tx.Exec(f.ctx, "insert into notes_app.notes(id,active) values('blocked-old-writer',false)"); err != nil {
		_ = conn.Close(f.ctx)
		t.Fatal(err)
	}
	return tx, func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = tx.Rollback(cleanup)
		_ = conn.Close(cleanup)
	}
}

func pgEmbeddedIndexWaiting(t *testing.T, f *pgControlTestFixture, scope *pgEmbeddedTestScope) {
	t.Helper()
	pgEmbeddedTestAwait(t, f, func() bool {
		if scope != nil {
			select {
			case <-scope.done:
				t.Fatalf("Embedded scope exited before blocked CIC: %v", scope.failure)
			default:
			}
		}
		var waiting bool
		err := f.installer.QueryRow(f.ctx, `select exists(select 1 from pg_catalog.pg_stat_progress_create_index
 where datid=(select oid from pg_catalog.pg_database where datname=current_database())
 and relid='notes_app.notes'::regclass and phase='waiting for writers before build')`).Scan(&waiting)
		if err != nil {
			t.Fatal(err)
		}
		return waiting
	})
}

func pgEmbeddedIndexEntered(t *testing.T, f *pgControlTestFixture, scope *pgEmbeddedTestScope) *PostgresDB {
	t.Helper()
	select {
	case pool := <-scope.entered:
		return pool
	case <-scope.done:
		t.Fatalf("Embedded scope refused readiness: %v", scope.failure)
	case <-f.ctx.Done():
		t.Fatal(f.ctx.Err())
	}
	return nil
}

func pgEmbeddedIndexScopeStop(t *testing.T, f *pgControlTestFixture, scope *pgEmbeddedTestScope) {
	t.Helper()
	scope.release()
	select {
	case <-scope.done:
		if scope.failure != nil {
			t.Fatal(scope.failure)
		}
	case <-f.ctx.Done():
		t.Fatal(f.ctx.Err())
	}
}

func TestPgMigrationEmbeddedPlainIndexServesCRUDAndRestartsAfterScopeCancellation(t *testing.T) {
	t.Setenv("TESL_LEASE_TTL_S", "2")
	t.Setenv("TESL_SCHEMA_POLL_S", "1")
	t.Setenv("PGAPPNAME", "tesl-app:embedded-request-pool")
	f := pgNewControlTest(t)
	f.install(t, 1)
	pgExpandIndexTest(t, f, 1, false)
	f.call(t, "insert into notes_app.notes(id,active) values('retained',true)")
	pgExpandIndexTest(t, f, 2, false)
	blocker, closeBlocker := pgEmbeddedIndexBlocker(t, f)
	defer closeBlocker()
	database := pgEmbeddedIndexDatabase(t, f, false)
	database.Config.DDLConnection = f.worker.Config().ConnString() + " application_name=dedicated-ddl-input-must-be-retagged"
	scope := pgStartEmbeddedTestScope(t, database)
	pool := pgEmbeddedIndexEntered(t, f, scope)
	pgEmbeddedIndexWaiting(t, f, scope)
	job := pgIndexControlTestJobs(t, f)[0]
	if job.State == "valid" || job.Attempts != 1 {
		t.Fatalf("plain scope did not become ready during its actual build: %+v", job)
	}
	var application string
	if err := pool.pool.QueryRow(f.ctx, "select current_setting('application_name')").Scan(&application); err != nil || application != "tesl-app:embedded-request-pool" {
		t.Fatalf("DDL config leaked into request pool: %q %v", application, err)
	}
	if _, err := pool.pool.Exec(f.ctx, "insert into notes_app.notes(id,active) values('request-during-build',true); update notes_app.notes set active=false where id='retained'"); err != nil {
		t.Fatalf("plain CIC blocked normal request CRUD: %v", err)
	}
	pgEmbeddedIndexScopeStop(t, f, scope)
	if tags := pgEmbeddedTestTags(t, f); len(tags) != 0 {
		t.Fatalf("scope cancellation left a DDL backend: %v", tags)
	}
	if err := pool.pool.Ping(f.ctx); err != nil {
		t.Fatal(err)
	}
	restarted := pgStartEmbeddedTestScope(t, database)
	if next := pgEmbeddedIndexEntered(t, f, restarted); next != pool {
		t.Fatal("restart replaced cached request pool")
	}
	if err := blocker.Commit(f.ctx); err != nil {
		t.Fatal(err)
	}
	pgEmbeddedTestAwait(t, f, func() bool { return pgIndexControlTestJobs(t, f)[0].State == "valid" })
	completed := pgIndexControlTestJobs(t, f)[0]
	if completed.Holder == job.Holder || completed.Token <= job.Token {
		t.Fatalf("restarted service did not fence its predecessor: before=%+v after=%+v", job, completed)
	}
	var count int
	if err := pool.pool.QueryRow(f.ctx, "select count(*) from notes_app.notes").Scan(&count); err != nil || count != 3 {
		t.Fatalf("restart lost retained/concurrent rows: %d %v", count, err)
	}
	pgEmbeddedIndexScopeStop(t, f, restarted)
}

func TestPgMigrationEmbeddedUniqueIndexOutlivesStartupBudgetBeforePublishing(t *testing.T) {
	t.Setenv("TESL_LEASE_TTL_S", "2")
	t.Setenv("TESL_SCHEMA_POLL_S", "1")
	f := pgNewControlTest(t)
	f.install(t, 1)
	pgExpandIndexTest(t, f, 1, true)
	pgExpandIndexTest(t, f, 2, true)
	blocker, closeBlocker := pgEmbeddedIndexBlocker(t, f)
	defer closeBlocker()
	database := pgEmbeddedIndexDatabase(t, f, true)
	scope := pgStartEmbeddedTestScope(t, database)
	pgEmbeddedIndexWaiting(t, f, scope)
	initial := pgIndexControlTestJobs(t, f)[0]
	var until time.Time
	if err := f.installer.QueryRow(f.ctx, "select clock_timestamp()+interval '10.5 seconds'").Scan(&until); err != nil {
		t.Fatal(err)
	}
	pgEmbeddedTestAwait(t, f, func() bool {
		select {
		case <-scope.entered:
			t.Fatal("unique readiness published before the real build completed")
		case <-scope.done:
			t.Fatalf("unique build was cut off by startup deadline: %v", scope.failure)
		default:
		}
		var elapsed bool
		if err := f.installer.QueryRow(f.ctx, "select clock_timestamp()>$1::timestamptz", until).Scan(&elapsed); err != nil {
			t.Fatal(err)
		}
		return elapsed
	})
	renewed := pgIndexControlTestJobs(t, f)[0]
	if renewed.Token != initial.Token || renewed.ExpiresAt == nil || initial.ExpiresAt == nil || !renewed.ExpiresAt.After(*initial.ExpiresAt) {
		t.Fatalf("long unique build lost ownership or did not renew: before=%+v after=%+v", initial, renewed)
	}
	if err := blocker.Commit(f.ctx); err != nil {
		t.Fatal(err)
	}
	pool := pgEmbeddedIndexEntered(t, f, scope)
	completed := pgIndexControlTestJobs(t, f)[0]
	var valid bool
	err := pool.pool.QueryRow(f.ctx, "select indisvalid and indisready and indislive from pg_catalog.pg_index where indexrelid='notes_app.token__v2'::regclass").Scan(&valid)
	if err != nil || !valid || completed.State != "valid" {
		t.Fatalf("unique readiness lacks physical and durable completion: %v %v %+v", valid, err, completed)
	}
	if _, err := pool.pool.Exec(f.ctx, "insert into notes_app.notes(id,active,token) values('one',true,'same'),('two',false,'same')"); err == nil {
		t.Fatal("ready unique index did not enforce uniqueness")
	}
	pgEmbeddedIndexScopeStop(t, f, scope)
}

func TestPgMigrationEmbeddedRequestDSNCannotBorrowDDLLogin(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	database := pgBootTestDatabase(t, f, 1)
	database.Config.DDLConnection = f.installer.Config().ConnString()
	pgBootRefuses(t, database, "configured worker identity")
	var count int
	err := f.installer.QueryRow(f.ctx, "select count(*) from notes_app.tesl_schema_expansions").Scan(&count)
	if err != nil || count != 0 {
		t.Fatalf("wrong DDL identity began expansion: %d %v", count, err)
	}
	if tags := pgEmbeddedTestTags(t, f); len(tags) != 0 {
		t.Fatalf("wrong DDL identity started service: %v", tags)
	}
}
