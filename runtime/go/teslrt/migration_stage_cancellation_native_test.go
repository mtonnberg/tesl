//go:build tesl_migration_test

package teslrt

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

func TestPgStageCancelFailedPreparationAndSuccessor(t *testing.T) {
	root := os.Getenv("TESL_STAGE_CANCELLATION_PROGRAMS")
	if root == "" {
		t.Skip("compiled cancellation programs required")
	}
	t.Setenv("TESL_SCHEMA_POLL_S", "1")
	f, request := pgNewWorkerTest(t)
	f.namespace = "notes"
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
	t.Cleanup(cancel)
	f.ctx = ctx
	pgStageInstall(t, f, root, "v1")
	pgRowAdditiveWorker(t, f, root, "v1")()
	if _, err := request.Exec(ctx, `select notes.tesl_admit_writer(1); insert into notes.notes(id,title) select 'kept',string_agg(md5(n::text),'') from generate_series(1,256) n`); err != nil {
		t.Fatal(err)
	}
	output, stop := pgRowAdditiveProcess(t, pgRowAdditiveCommand(f, root, "v2", "--schema", "worker", "--json"))
	wait, end := context.WithTimeout(ctx, 20*time.Second)
	defer end()
	for {
		var failed int
		if err := f.worker.QueryRow(wait, `select count(*) from notes.tesl_schema_index where state='failed'`).Scan(&failed); err != nil {
			t.Fatal(err)
		}
		if failed > 0 {
			break
		}
		if err := pgIndexWait(wait, 20*time.Millisecond); err != nil {
			t.Fatalf("no failed preparation: %v %s", err, output.String())
		}
	}
	stop()
	pgStageInstall(t, f, root, "v3")
	pgRowAdditiveWorker(t, f, root, "v3")()
	var cancelled, terminal, indexes, length int
	if err := f.worker.QueryRow(ctx, `select (select count(*) from notes.tesl_schema_stages where state='cancelled'),(select count(*) from notes.tesl_schema_index where state='terminal' and terminal_version=3),
 (select count(*) from pg_catalog.pg_index where indrelid='notes.notes'::regclass and not indisprimary),(select length(title) from notes.notes where id='kept')`).Scan(&cancelled, &terminal, &indexes, &length); err != nil || cancelled != 5 || terminal != 5 || indexes != 0 || length != 8192 {
		t.Fatal("cancellation lost data or index retirement", cancelled, terminal, indexes, length, err)
	}
	if out, err := pgRowAdditiveCommand(f, root, "v3", "--schema", "status", "--json").CombinedOutput(); err != nil || !strings.Contains(string(out), `"cancellationVersion":3`) || !strings.Contains(string(out), `"terminalVersion":3`) {
		t.Fatalf("status omitted cancellation provenance: %v %s", err, out)
	}
	if _, err := request.Exec(ctx, `select notes.tesl_admit_writer(2)`); err == nil || !strings.Contains(err.Error(), "retired") {
		t.Fatal("old preparation producer not fenced", err)
	}
	if _, err := request.Exec(ctx, `select notes.tesl_admit_writer(3); insert into notes.notes(id,title,active,amount,big_amount,optional_text) values('a','duplicate',true,7,7,'same'),('b','duplicate',true,7,7,'same')`); err != nil {
		t.Fatal("cancelled keys still enforced", err)
	}
	pgStageInstall(t, f, root, "v3")
	pgRowAdditiveWorker(t, f, root, "v3")()
	pgStageInstall(t, f, root, "v4")
	pgRowAdditiveWorker(t, f, root, "v4")()
	app := pgRowAdditiveApp(t, f, root, "v4")
	pgCallRowAccessApp(t, ctx, app, "PUT", "/edit", 200)
	var current, minimum, rows int
	if err := f.worker.QueryRow(ctx, `select current,min_version,(select count(*) from notes.notes) from notes.tesl_schema_state`).Scan(&current, &minimum, &rows); err != nil || current != 4 || minimum != 3 || rows != 3 {
		t.Fatal("cancelled history failed to advance", current, minimum, rows, err)
	}
}

func TestPgStageCancelPublicationRecovery(t *testing.T) {
	root := os.Getenv("TESL_STAGE_CANCELLATION_PROGRAMS")
	if root == "" {
		t.Skip("compiled cancellation programs required")
	}
	t.Setenv("TESL_SCHEMA_POLL_S", "1")
	for _, boundary := range []string{"stage-cancel-before-drop", "stage-cancel-after-receipt", "stage-cancel-after-commit"} {
		t.Run(boundary, func(t *testing.T) {
			f, _ := pgNewWorkerTest(t)
			f.namespace = "notes"
			ctx, cancel := context.WithTimeout(context.Background(), 100*time.Second)
			t.Cleanup(cancel)
			f.ctx = ctx
			pgStageInstall(t, f, root, "v3")
			pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{boundary, 1}})
			defer pauses[0].resume()
			cmd := pgRowAdditiveCommand(f, root, "v3", "--schema", "worker", "--json")
			cmd.Env = append(cmd.Env, "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
			var output pgRowAppOutput
			cmd.Stdout = &output
			cmd.Stderr = &output
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() { done <- cmd.Wait() }()
			joined := false
			defer func() {
				if !joined {
					_ = cmd.Process.Kill()
					<-done
				}
			}()
			select {
			case <-pauses[0].arrived:
			case err := <-done:
				joined = true
				t.Fatalf("before cancellation boundary: %v %s", err, output.String())
			case <-ctx.Done():
				t.Fatal("cancellation boundary timeout", output.String())
			}
			if err := cmd.Process.Kill(); err != nil {
				t.Fatal(err)
			}
			<-done
			joined = true
			pauses[0].resume()
			pgRowAdditiveWorker(t, f, root, "v3")()
			var completed int
			if err := f.worker.QueryRow(ctx, `select count(*) from notes.tesl_schema_stage_cancellations`).Scan(&completed); err != nil || completed != 5 {
				t.Fatal("cancellation did not recover", completed, err)
			}
			pgStageInstall(t, f, root, "v4")
			pgRowAdditiveWorker(t, f, root, "v4")()
		})
	}
}

func TestPgStageCancelFourReleaseCatchup(t *testing.T) {
	root := os.Getenv("TESL_STAGE_CANCELLATION_PROGRAMS")
	if root == "" {
		t.Skip("compiled cancellation programs required")
	}
	t.Setenv("TESL_SCHEMA_POLL_S", "1")
	f, _ := pgNewWorkerTest(t)
	f.namespace = "notes"
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	t.Cleanup(cancel)
	f.ctx = ctx
	pgStageInstall(t, f, root, "v4")
	if out, err := pgRowAdditiveCommand(f, root, "v4", "--schema", "catch-up", "--json").CombinedOutput(); err != nil {
		t.Fatalf("cancel catchup: %v %s", err, out)
	}
	var current, completed, attempts int
	if err := f.worker.QueryRow(ctx, `select current,(select count(*) from notes.tesl_schema_stage_cancellations),(select coalesce(sum(attempts),0) from notes.tesl_schema_index) from notes.tesl_schema_state`).Scan(&current, &completed, &attempts); err != nil || current != 4 || completed != 5 || attempts != 0 {
		t.Fatal("catchup built preparations scheduled for cancellation", current, completed, attempts, err)
	}
}
