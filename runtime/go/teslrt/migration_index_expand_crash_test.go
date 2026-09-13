//go:build tesl_migration_test

package teslrt

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func pgIndexExpansionWaitDone(t *testing.T, f *pgControlTestFixture, done <-chan error) error {
	t.Helper()
	select {
	case err := <-done:
		return err
	case <-f.ctx.Done():
		t.Fatal("executor did not stop before fixture deadline")
		return f.ctx.Err()
	}
}

func pgIndexExpansionWaitDead(t *testing.T, f *pgControlTestFixture, pid uint32) {
	t.Helper()
	ctx, cancel := context.WithTimeout(f.ctx, 5*time.Second)
	defer cancel()
	for {
		var present bool
		if err := f.installer.QueryRow(ctx, `select exists(select 1 from pg_stat_activity where pid=$1)
 or exists(select 1 from pg_locks where pid=$1)`, pid).Scan(&present); err != nil {
			t.Fatal(err)
		}
		if !present {
			return
		}
		timer := time.NewTimer(10 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			t.Fatal("killed executor backend or locks did not disappear")
		case <-timer.C:
		}
	}
}

func pgIndexStartExpansionTest(f *pgControlTestFixture, conn *pgx.Conn, history PgCompiledMigrationHistory) <-chan error {
	done := make(chan error, 1)
	go func() {
		defer func() { _ = conn.Close(context.Background()) }()
		_, err := ExecutePgMigrationExpansion(f.ctx, conn, history, f.roles)
		done <- err
	}()
	return done
}

func TestPgMigrationIndexExpansionCrashRegistrationIsAtomic(t *testing.T) {
	for _, unique := range []bool{false, true} {
		for _, boundary := range []string{"expansion-before-commit", "expansion-after-commit", "expansion-after-ddl"} {
			hits := 4 // Intent, nullable column, protected job, expanded lifecycle.
			if boundary == "expansion-after-ddl" {
				hits = 2
			}
			for hit := 1; hit <= hits; hit++ {
				t.Run(fmt.Sprintf("unique=%v/%s/%d", unique, boundary, hit), func(t *testing.T) {
					f, request := pgNewWorkerTest(t)
					f.install(t, 1)
					pgExpandIndexTest(t, f, 1, unique)
					f.call(t, "insert into notes_app.notes(id,active) values('retained',true)")
					arrived, resume := pgPauseExpansionBoundary(t, boundary, hit)
					conn, err := pgx.ConnectConfig(f.ctx, f.worker.Config().Copy())
					if err != nil {
						t.Fatal(err)
					}
					pid := conn.PgConn().PID()
					done := pgIndexStartExpansionTest(f, conn, pgIndexExpansionTestHistory(f.namespace, 2, unique))
					select {
					case <-arrived:
					case err := <-done:
						t.Fatalf("executor exited before the crash boundary: %v", err)
					case <-f.ctx.Done():
						t.Fatal(f.ctx.Err())
					}
					var killed bool
					if err := f.installer.QueryRow(f.ctx, "select pg_terminate_backend($1::integer)", pid).Scan(&killed); err != nil || !killed {
						t.Fatalf("kill task-owned expansion backend: %v %v", killed, err)
					}
					resume()
					if err := pgIndexExpansionWaitDone(t, f, done); err == nil {
						t.Fatal("killed expansion reported success")
					}
					pgIndexExpansionWaitDead(t, f, pid)
					t.Setenv("TESL_MIGRATION_TEST_SOCKET", "")
					want := hit - 2
					if boundary != "expansion-before-commit" {
						want = hit - 1
					}
					want = max(0, min(2, want))
					var objects, current int
					if err := f.worker.QueryRow(f.ctx, "select count(*) from notes_app.tesl_schema_expansion_objects where version=2").Scan(&objects); err != nil || objects != want {
						t.Fatalf("object commit prefix: got=%d want=%d err=%v", objects, want, err)
					}
					jobs := pgIndexControlTestJobs(t, f)
					wantJobs := 0
					if want == 2 {
						wantJobs = 1
					}
					if len(jobs) != wantJobs {
						t.Fatalf("job and operation progress did not commit together: %+v objects=%d", jobs, objects)
					}
					wantCurrent := 1
					if boundary == "expansion-after-commit" && hit == 4 {
						wantCurrent = 2
					}
					if err := f.worker.QueryRow(f.ctx, "select current from notes_app.tesl_schema_state").Scan(&current); err != nil || current != wantCurrent {
						t.Fatalf("lifecycle commit: got=%d want=%d err=%v", current, wantCurrent, err)
					}
					if _, err := pgWaitForMigrationReadiness(f.ctx, request, pgIndexExpansionTestHistory(f.namespace, 1, unique), f.roles); err != nil {
						t.Fatalf("old request could not restart during interrupted expansion: %v", err)
					}
					if _, err := request.Exec(f.ctx, "insert into notes_app.notes(id,active) values('old-restart',false)"); err != nil {
						t.Fatal(err)
					}
					pgExpandIndexTest(t, f, 3, unique)
					jobs = pgIndexControlTestJobs(t, f)
					if len(jobs) != 1 || jobs[0].State != "pending" || jobs[0].Attempts != 0 || jobs[0].Token != 0 {
						t.Fatalf("resume duplicated or executed a job: %+v", jobs)
					}
					var retained int
					if err := request.QueryRow(f.ctx, "select count(*) from notes_app.notes where token is null and note is null").Scan(&retained); err != nil || retained != 2 {
						t.Fatalf("crash/retry changed old writes: %d %v", retained, err)
					}
				})
			}
		}
	}
}

func TestPgMigrationIndexExpansionPendingCompilerDoesNotBlockOldRequest(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	f.install(t, 1)
	pgExpandIndexTest(t, f, 1, true)
	newHistory := pgCompatibilityTestCompiler(pgIndexExpansionTestHistory(f.namespace, 2, true), "b")
	arrived, resume := pgPauseExpansionBoundary(t, "expansion-after-commit", 1)
	conn, err := pgx.ConnectConfig(f.ctx, f.worker.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	done := pgIndexStartExpansionTest(f, conn, newHistory)
	select {
	case <-arrived:
	case err := <-done:
		t.Fatalf("new compiler failed before pending intent: %v", err)
	case <-f.ctx.Done():
		t.Fatal(f.ctx.Err())
	}
	// V2's immutable intent now exists, but none of its work has run. A V1
	// request is only an observer and must not need the worker's compiler ABI.
	if _, err := pgWaitForMigrationReadiness(f.ctx, request, pgIndexExpansionTestHistory(f.namespace, 1, true), f.roles); err != nil {
		t.Fatalf("pending future compiler prevented old request startup: %v", err)
	}
	if _, err := request.Exec(f.ctx, "insert into notes_app.notes(id,active) values('during-intent',true)"); err != nil {
		t.Fatal(err)
	}
	if _, err := f.installer.Exec(f.ctx, "select pg_terminate_backend($1::integer)", conn.PgConn().PID()); err != nil {
		t.Fatal(err)
	}
	resume()
	if err := pgIndexExpansionWaitDone(t, f, done); err == nil {
		t.Fatal("killed new compiler executor reported success")
	}
	pgIndexExpansionWaitDead(t, f, conn.PgConn().PID())
	t.Setenv("TESL_MIGRATION_TEST_SOCKET", "")
	if _, err := ExecutePgMigrationExpansion(f.ctx, f.worker, pgIndexExpansionTestHistory(f.namespace, 2, true), f.roles); err == nil || !strings.Contains(err.Error(), "unfinished migration compiler ABI") {
		t.Fatalf("observer exception let old compiler resume new work: %v", err)
	}
	if _, err := ExecutePgMigrationExpansion(f.ctx, f.worker, newHistory, f.roles); err != nil {
		t.Fatal(err)
	}
	var retained bool
	if err := request.QueryRow(f.ctx, "select active and token is null from notes_app.notes where id='during-intent'").Scan(&retained); err != nil || !retained {
		t.Fatalf("pending-intent old write was not retained: %v %v", retained, err)
	}
}

func TestPgMigrationIndexExpansionUniqueWaitsForPhysicalAndDurableCompletion(t *testing.T) {
	for _, physical := range []bool{false, true} {
		t.Run(fmt.Sprintf("physical-valid=%v", physical), func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			f.install(t, 1)
			pgExpandIndexTest(t, f, 1, true)
			pgExpandIndexTest(t, f, 3, true)
			if physical {
				f.call(t, "create unique index concurrently token__v2 on notes_app.notes(token)")
			}
			before := pgIndexControlTestJobs(t, f)
			arrived, resume := pgPauseExpansionBoundary(t, "request-readiness-pending", 1)
			ctx, cancel := context.WithCancel(f.ctx)
			defer cancel()
			done := make(chan error, 1)
			go func() {
				_, err := pgWaitForMigrationReadiness(ctx, request, pgIndexExpansionTestHistory(f.namespace, 3, true), f.roles)
				done <- err
			}()
			select {
			case <-arrived:
			case err := <-done:
				t.Fatalf("unique readiness did not enter the verified pending state: %v", err)
			case <-f.ctx.Done():
				t.Fatal(f.ctx.Err())
			}
			cancel()
			resume()
			if err := pgIndexExpansionWaitDone(t, f, done); !errors.Is(err, context.Canceled) || !strings.Contains(err.Error(), "waiting for schema worker") {
				t.Fatalf("readiness cancellation happened outside the verified pending loop: %v", err)
			}
			after := pgIndexControlTestJobs(t, f)
			if len(before) != 1 || len(after) != 1 || before[0].State != "pending" || after[0].State != "pending" || after[0].Token != 0 || after[0].Attempts != 0 {
				t.Fatalf("readiness observer performed worker execution: before=%+v after=%+v", before, after)
			}
		})
	}
}
