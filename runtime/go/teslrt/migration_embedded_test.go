package teslrt

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func pgEmbeddedTestGeneration(service *pgEmbeddedIndexService) (*pgEmbeddedIndexGeneration, int) {
	service.mutex.Lock()
	defer service.mutex.Unlock()
	if service.generation == nil {
		return nil, 0
	}
	return service.generation, service.generation.refs
}

func pgEmbeddedTestTags(t *testing.T, f *pgControlTestFixture) []string {
	t.Helper()
	rows, err := f.installer.Query(f.ctx, "select distinct application_name from pg_catalog.pg_stat_activity where datname=current_database() and application_name like 'tesl-exec:%' order by 1")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var tags []string
	for rows.Next() {
		var tag string
		if err := rows.Scan(&tag); err != nil {
			t.Fatal(err)
		}
		tags = append(tags, tag)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return tags
}

func pgEmbeddedTestAwait(t *testing.T, f *pgControlTestFixture, condition func() bool) {
	t.Helper()
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	for !condition() {
		select {
		case <-f.ctx.Done():
			t.Fatal(f.ctx.Err())
		case <-tick.C:
		}
	}
}

func TestPgMigrationEmbeddedNestedScopesShareServiceAndRetainPool(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	database := pgBootTestDatabase(t, f, 1)
	var pool *PostgresDB
	var initial *pgEmbeddedIndexGeneration
	var initialTag string
	WithDatabase(database, func() {
		pool = database.bound()
		var refs int
		initial, refs = pgEmbeddedTestGeneration(pool.embedded)
		if initial == nil || refs != 1 {
			t.Fatalf("first scope did not reserve its executor: %p %d", initial, refs)
		}
		tags := pgEmbeddedTestTags(t, f)
		if len(tags) != 1 {
			t.Fatalf("first scope executor tags: %v", tags)
		}
		initialTag = tags[0]
		WithDatabase(database, func() {
			generation, refs := pgEmbeddedTestGeneration(pool.embedded)
			if database.bound() != pool || generation != initial || refs != 2 {
				t.Fatalf("nested scope did not share pool/service: %p %d", generation, refs)
			}
		})
		generation, refs := pgEmbeddedTestGeneration(pool.embedded)
		if generation != initial || refs != 1 || initial.ctx.Err() != nil {
			t.Fatalf("nested release stopped outer service: %p %d %v", generation, refs, initial.ctx.Err())
		}
	})
	if generation, refs := pgEmbeddedTestGeneration(pool.embedded); generation != nil || refs != 0 {
		t.Fatalf("last scope left an executor owner: %p %d", generation, refs)
	}
	if tags := pgEmbeddedTestTags(t, f); len(tags) != 0 {
		t.Fatalf("last scope left tagged backends: %v", tags)
	}
	if err := pool.pool.Ping(f.ctx); err != nil {
		t.Fatalf("scope release closed the reusable request pool: %v", err)
	}
	WithDatabase(database, func() {
		generation, refs := pgEmbeddedTestGeneration(pool.embedded)
		tags := pgEmbeddedTestTags(t, f)
		if database.bound() != pool || generation == initial || refs != 1 || len(tags) != 1 || tags[0] == initialTag {
			t.Fatalf("later scope did not retain its pool and reacquire a fresh executor: generation=%p refs=%d tags=%v", generation, refs, tags)
		}
	})
}

func TestPgMigrationEmbeddedOverlappingScopesKeepSharedOwnerAlive(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	database := pgBootTestDatabase(t, f, 1)
	secondEntered, secondRelease, secondDone := make(chan struct{}), make(chan struct{}), make(chan any, 1)
	defer close(secondRelease)
	var pool *PostgresDB
	var initial *pgEmbeddedIndexGeneration
	WithDatabase(database, func() {
		pool = database.bound()
		initial, _ = pgEmbeddedTestGeneration(pool.embedded)
		go func() {
			secondDone <- recoverDebugSQLFailure(func() {
				WithDatabase(database, func() {
					close(secondEntered)
					<-secondRelease
				})
			})
		}()
		pgEmbeddedTestAwait(t, f, func() bool {
			_, refs := pgEmbeddedTestGeneration(pool.embedded)
			return refs == 2
		})
	})
	select {
	case <-secondEntered:
	case failure := <-secondDone:
		t.Fatalf("second scope failed: %v", failure)
	case <-f.ctx.Done():
		t.Fatal(f.ctx.Err())
	}
	generation, refs := pgEmbeddedTestGeneration(pool.embedded)
	if generation != initial || refs != 1 || initial.ctx.Err() != nil {
		t.Fatalf("first release stopped the shared generation: %p %d %v", generation, refs, initial.ctx.Err())
	}
	// Release explicitly here; the deferred fallback must remain idempotent.
	secondRelease <- struct{}{}
	select {
	case failure := <-secondDone:
		if failure != nil {
			t.Fatal(failure)
		}
	case <-f.ctx.Done():
		t.Fatal(f.ctx.Err())
	}
	if tags := pgEmbeddedTestTags(t, f); len(tags) != 0 {
		t.Fatalf("overlapping scopes leaked executor sessions: %v", tags)
	}
}

func TestPgMigrationEmbeddedPermanentFailurePreservesActivePoolAndRefusesNextScope(t *testing.T) {
	t.Setenv("TESL_SCHEMA_POLL_S", "1")
	f := pgNewControlTest(t)
	f.install(t, 1)
	database := pgBootTestDatabase(t, f, 1)
	var pool *PostgresDB
	WithDatabase(database, func() {
		pool = database.bound()
		generation, _ := pgEmbeddedTestGeneration(pool.embedded)
		f.call(t, "create index undeclared on notes_app.notes(id)")
		select {
		case <-generation.done:
		case <-f.ctx.Done():
			t.Fatal(f.ctx.Err())
		}
		if err := pool.pool.Ping(f.ctx); err != nil {
			t.Fatalf("failed schema service closed the active pool: %v", err)
		}
		if database.bound() != pool {
			t.Fatal("failed schema service removed the active binding")
		}
	})
	pgBootRefuses(t, database, "Embedded migration service refused")
	if tags := pgEmbeddedTestTags(t, f); len(tags) != 0 {
		t.Fatalf("permanent service failure left an actor: %v", tags)
	}
}

func TestPgMigrationEmbeddedQueuedScopeRechecksServiceBeforeBinding(t *testing.T) {
	for _, failure := range []string{"shutdown", "permanent"} {
		t.Run(failure, func(t *testing.T) {
			t.Setenv("TESL_SCHEMA_POLL_S", "1")
			f := pgNewControlTest(t)
			f.install(t, 1)
			database := pgBootTestDatabase(t, f, 1)
			entered, done := make(chan struct{}), make(chan any, 1)
			WithDatabase(database, func() {
				service := database.bound().embedded
				generation, _ := pgEmbeddedTestGeneration(service)
				go func() {
					done <- recoverDebugSQLFailure(func() { WithDatabase(database, func() { close(entered) }) })
				}()
				pgEmbeddedTestAwait(t, f, func() bool {
					_, refs := pgEmbeddedTestGeneration(service)
					return refs == 2
				})
				if failure == "shutdown" {
					generation.stop()
				} else {
					f.call(t, "create index undeclared on notes_app.notes(id)")
				}
				select {
				case <-generation.done:
				case <-f.ctx.Done():
					t.Fatal(f.ctx.Err())
				}
			})
			select {
			case refusal := <-done:
				if refusal == nil || !strings.Contains(fmt.Sprint(refusal), "Embedded migration service refused") {
					t.Fatalf("queued scope ignored failed service: %v", refusal)
				}
			case <-f.ctx.Done():
				t.Fatal(f.ctx.Err())
			}
			select {
			case <-entered:
				t.Fatal("queued scope published a binding after service stopped")
			default:
			}
			if tags := pgEmbeddedTestTags(t, f); len(tags) != 0 {
				t.Fatalf("queued refusal leaked actors: %v", tags)
			}
		})
	}
}

func TestPgMigrationEmbeddedPoolFailureJoinsTransferredServiceAndAllowsRetry(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	database := pgBootTestDatabase(t, f, 1)
	correctDatabase := database.Config.DBName
	database.Config.DDLConnection = f.worker.Config().ConnString()
	// The DDL service expands the actual database. The separately configured
	// request pool connects successfully elsewhere, then fails identity checks.
	database.Config.DBName = "postgres"
	pgBootRefuses(t, database, "versioned connection refused")
	if tags := pgEmbeddedTestTags(t, f); len(tags) != 0 {
		t.Fatalf("failed pool publication leaked its transferred service: %v", tags)
	}
	database.Config.DBName = correctDatabase
	WithDatabase(database, func() {
		if database.bound() == nil {
			t.Fatal("corrected initialization did not retry")
		}
	})
}

func TestPgMigrationEmbeddedCanceledInitialOwnerNeverPublishes(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	history := pgExpansionTestHistory(f.namespace, 1)
	state, err := ExecutePgMigrationExpansion(f.ctx, f.worker, history, f.roles)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(f.ctx)
	cancel()
	service, release, err := pgStartEmbeddedIndexService(ctx, cancel, f.worker, f.worker.Config(), history, f.roles, state, pgIndexTestSettings())
	if err == nil || release != nil || !strings.Contains(fmt.Sprint(err), "canceled") {
		t.Fatalf("canceled owner published readiness: %v %v", release != nil, err)
	}
	if generation, refs := pgEmbeddedTestGeneration(service); generation != nil || refs != 0 {
		t.Fatalf("canceled owner leaked references: %p %d", generation, refs)
	}
	if !f.worker.IsClosed() {
		t.Fatal("canceled owner did not close transferred connection")
	}
}

func TestPgMigrationEmbeddedReconnectOutageRetriesAndCancellationIsNotSticky(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	history := pgExpansionTestHistory(f.namespace, 1)
	state, err := ExecutePgMigrationExpansion(f.ctx, f.worker, history, f.roles)
	if err != nil {
		t.Fatal(err)
	}
	config := f.worker.Config().Copy()
	dial := config.DialFunc
	var failures atomic.Int32
	attempts := make(chan struct{}, 16)
	config.DialFunc = func(ctx context.Context, network, address string) (net.Conn, error) {
		if remaining := failures.Load(); remaining != 0 {
			if remaining > 0 {
				failures.Add(-1)
			}
			select {
			case attempts <- struct{}{}:
			default:
			}
			return nil, &net.OpError{Op: "dial", Net: network, Err: errors.New("temporary test connection refusal")}
		}
		return dial(ctx, network, address)
	}
	conn, err := pgx.ConnectConfig(f.ctx, config.Copy())
	if err != nil {
		t.Fatal(err)
	}
	ctx, stop := pgEmbeddedContext()
	settings := pgIndexTestSettings()
	settings.poll = 50 * time.Millisecond
	service, release, err := pgStartEmbeddedIndexService(ctx, stop, conn, config, history, f.roles, state, settings)
	if err != nil {
		t.Fatal(err)
	}
	release()
	failures.Store(2)
	release, err = service.acquire()
	if err != nil {
		t.Fatalf("temporary reconnect outage became permanent: %v", err)
	}
	if len(attempts) != 2 || len(pgEmbeddedTestTags(t, f)) != 1 {
		t.Fatal("reconnect did not retry both failures and complete real PostgreSQL admission")
	}
	<-attempts
	<-attempts
	release()
	failures.Store(-1)
	done := make(chan error, 1)
	go func() {
		release, err := service.acquire()
		if release != nil {
			release()
		}
		done <- err
	}()
	select {
	case <-attempts:
	case err := <-done:
		t.Fatalf("retry exited before controlled cancellation: %v", err)
	case <-f.ctx.Done():
		t.Fatal(f.ctx.Err())
	}
	generation, _ := pgEmbeddedTestGeneration(service)
	generation.stop()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("retry cancellation result: %v", err)
		}
	case <-f.ctx.Done():
		t.Fatal(f.ctx.Err())
	}
	if generation, refs := pgEmbeddedTestGeneration(service); generation != nil || refs != 0 {
		t.Fatalf("canceled retry left ownership: %p %d", generation, refs)
	}
	if tags := pgEmbeddedTestTags(t, f); len(tags) != 0 {
		t.Fatalf("canceled retry left backend/fence: %v", tags)
	}
	failures.Store(0)
	release, err = service.acquire()
	if err != nil {
		t.Fatalf("normal cancellation poisoned the next real connection: %v", err)
	}
	release()
}

func TestPgMigrationEmbeddedPermanentAuthenticationFailureDoesNotRetry(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	history := pgExpansionTestHistory(f.namespace, 1)
	state, err := ExecutePgMigrationExpansion(f.ctx, f.worker, history, f.roles)
	if err != nil {
		t.Fatal(err)
	}
	conn, err := pgx.ConnectConfig(f.ctx, f.worker.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	config := f.worker.Config().Copy()
	config.User = "nonexistent_" + strings.ReplaceAll(UUIDv7(), "-", "")
	ctx, stop := pgEmbeddedContext()
	service, release, err := pgStartEmbeddedIndexService(ctx, stop, conn, config, history, f.roles, state, pgIndexTestSettings())
	var rejected *pgconn.PgError
	if release != nil || !errors.As(err, &rejected) || rejected.Code != "28000" {
		t.Fatalf("permanent PostgreSQL login refusal lost: %v", err)
	}
	if release, err := service.acquire(); release != nil || err == nil {
		t.Fatal("permanent login failure was retried")
	}
}

func TestPgMigrationEmbeddedCanceledStartupContextReachesServeAndLaterScopeIsFresh(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	database := pgBootTestDatabase(t, f, 1)
	WithDatabase(database, func() {
		generation, _ := pgEmbeddedTestGeneration(database.bound().embedded)
		if currentRuntimeLifecycle() != generation.ctx {
			t.Fatal("server lifecycle does not inherit the bound Embedded scope")
		}
		generation.stop() // Shutdown occurs in user startup, before Serve subscribes.
		// An attempted listen would fail with this invalid port. Correctly
		// inherited cancellation returns normally before any listener is opened.
		Serve(Server{}, ServeOptions{Port: -1, ListenAddress: "127.0.0.1"})
	})
	if err := currentRuntimeLifecycle().Err(); err != nil {
		t.Fatalf("old scope poisoned unbound runtime lifecycle: %v", err)
	}
	WithDatabase(database, func() {
		if err := currentRuntimeLifecycle().Err(); err != nil {
			t.Fatalf("old scope poisoned new application lifecycle: %v", err)
		}
	})
}
