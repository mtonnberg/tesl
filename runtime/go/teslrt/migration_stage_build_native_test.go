//go:build tesl_migration_test

package teslrt

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func TestPgStageGuardWritesDuringUniqueBuild(t *testing.T) {
	root := os.Getenv("TESL_STAGE_GUARD_PROGRAMS")
	if root == "" {
		t.Skip("compiled stage lifecycle programs required")
	}
	t.Setenv("TESL_SCHEMA_POLL_S", "1")
	f, request := pgNewWorkerTest(t)
	f.namespace = "notes"
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	t.Cleanup(cancel)
	f.ctx = ctx
	pgStageInstall(t, f, root, "v3-contract")
	if out, err := pgRowAdditiveCommand(f, root, "v3-contract", "--schema", "catch-up", "--json").CombinedOutput(); err != nil {
		t.Fatalf("setup: %v %s", err, out)
	}
	held, err := request.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer held.Rollback(ctx)
	if _, err := held.Exec(ctx, `select notes.tesl_admit_writer(3); insert into notes.notes(id,title) values('held','held')`); err != nil {
		t.Fatal(err)
	}
	type outcome struct {
		out []byte
		err error
	}
	done := make(chan outcome, 1)
	go func() {
		out, err := pgRowAdditiveCommand(f, root, "v3-contract", "--schema", "contract", "V3", "--json").CombinedOutput()
		done <- outcome{out, err}
	}()
	wait, end := context.WithTimeout(ctx, 15*time.Second)
	defer end()
	for {
		var waiting bool
		if err := f.worker.QueryRow(wait, `select exists(select 1 from pg_catalog.pg_stat_progress_create_index where relid='notes.notes'::regclass and phase like 'waiting for writers%')`).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting {
			break
		}
		select {
		case result := <-done:
			t.Fatalf("builder did not wait for V3 transaction: %v %s", result.err, result.out)
		default:
		}
		if err := pgIndexWait(wait, 10*time.Millisecond); err != nil {
			t.Fatal(err)
		}
	}
	a, err := pgx.ConnectConfig(ctx, request.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close(ctx)
	b, err := pgx.ConnectConfig(ctx, request.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close(ctx)
	first, err := a.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Rollback(ctx)
	if _, err := first.Exec(ctx, `select notes.tesl_admit_writer(3); insert into notes.notes(id,title) values('during-a','during')`); err != nil {
		t.Fatal("guard refused known building target", err)
	}
	second, err := b.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Rollback(ctx)
	if _, err := second.Exec(ctx, `select notes.tesl_admit_writer(3)`); err != nil {
		t.Fatal(err)
	}
	duplicate := make(chan error, 1)
	go func() {
		_, err := second.Exec(ctx, `insert into notes.notes(id,title) values('during-b','during')`)
		duplicate <- err
	}()
	for {
		var waiting bool
		if err := f.worker.QueryRow(wait, `select exists(select 1 from pg_catalog.pg_locks where pid=$1 and locktype='advisory' and objsubid=1 and not granted)`, b.PgConn().PID()).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting {
			break
		}
		if err := pgIndexWait(wait, time.Millisecond); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := f.worker.Exec(ctx, `begin; select notes.tesl_admit_writer(3); set local lock_timeout='1s'; insert into notes.notes(id,title) values('other','other'); commit`); err != nil {
		t.Fatal("different key blocked by the build/guard", err)
	}
	if err := first.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	var unique *pgconn.PgError
	if err := <-duplicate; !errors.As(err, &unique) || unique.Code != "23505" || unique.ConstraintName != "title_unique" {
		t.Fatal("same-key guard failed during build", err)
	}
	_ = second.Rollback(ctx)
	if err := held.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	result := <-done
	if result.err != nil {
		t.Fatalf("concurrent build did not finish: %v %s", result.err, result.out)
	}
}
