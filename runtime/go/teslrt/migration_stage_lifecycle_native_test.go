//go:build tesl_migration_test

package teslrt

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

func TestPgStageGuardPromotionLifecycle(t *testing.T) {
	root := os.Getenv("TESL_STAGE_GUARD_PROGRAMS")
	if root == "" {
		t.Skip("compiled stage lifecycle programs required")
	}
	t.Setenv("TESL_SCHEMA_POLL_S", "1")
	f, request := pgNewWorkerTest(t)
	f.namespace = "notes"
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
	t.Cleanup(cancel)
	f.ctx = ctx
	pgStageInstall(t, f, root, "v1")
	pgRowAdditiveWorker(t, f, root, "v1")()
	stop := pgRowAdditiveWorker(t, f, root, "v2")
	for {
		var n int
		if err := f.worker.QueryRow(ctx, `select count(*) from notes.tesl_schema_index where state='valid'`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n == 5 {
			break
		}
		if err := pgIndexWait(ctx, 10*time.Millisecond); err != nil {
			t.Fatal(err)
		}
	}
	stop()
	pgRowAdditiveWorker(t, f, root, "v3-contract")()
	tx, err := request.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `select notes.tesl_admit_writer(2); insert into notes.notes(id,title) values('legacy-a','duplicate'),('legacy-b','duplicate'),('legacy-c','duplicate')`); err != nil {
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
	wait, stopWait := context.WithTimeout(ctx, 10*time.Second)
	defer stopWait()
	for {
		var n int
		if err := f.worker.QueryRow(wait, `select count(*) from notes.tesl_schema_stage_contracts`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n == 1 {
			break
		}
		select {
		case result := <-done:
			t.Fatalf("contract before drain: %v %s", result.err, result.out)
		default:
		}
		if err := pgIndexWait(wait, 10*time.Millisecond); err != nil {
			t.Fatal(err)
		}
	}
	var minimum, targets int
	if err := f.worker.QueryRow(ctx, `select min_version,(select count(*) from notes.tesl_schema_index where is_unique) from notes.tesl_schema_state`).Scan(&minimum, &targets); err != nil || minimum >= 3 || targets != 0 {
		t.Fatal("target registered before writer drain", minimum, targets, err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	result := <-done
	if result.err == nil || !strings.Contains(string(result.out), "blocked_duplicates") {
		t.Fatalf("expected duplicate block, got %v %s", result.err, result.out)
	}
	if _, err := request.Exec(ctx, `select notes.tesl_admit_writer(2)`); err == nil {
		t.Fatal("retired producer admitted")
	}
	var blocked int
	if err := f.worker.QueryRow(ctx, `select count(*) from notes.tesl_schema_stages where state='blocked_duplicates'`).Scan(&blocked); err != nil || blocked == 0 {
		t.Fatal("missing durable duplicate state", blocked, err)
	}
	if out, err := pgRowAdditiveCommand(f, root, "v3-contract", "--schema", "status", "--json").CombinedOutput(); err != nil || !strings.Contains(string(out), `"blocked_duplicates"`) {
		t.Fatalf("status omitted duplicate blocker: %v %s", err, out)
	}
	var actualABI, applicationName string
	if err := f.installer.QueryRow(ctx, `select compiler_abi from notes.tesl_schema_stage_contracts where version=3`).Scan(&actualABI); err != nil {
		t.Fatal(err)
	}
	if err := f.worker.QueryRow(ctx, `select current_setting('application_name')`).Scan(&applicationName); err != nil {
		t.Fatal(err)
	}
	if _, err := f.installer.Exec(ctx, `update notes.tesl_schema_stage_contracts set compiler_abi=$1 where version=3`, "tesl-source-abi-v1:"+strings.Repeat("0", 64)); err != nil {
		t.Fatal(err)
	}
	if _, err := f.worker.Exec(ctx, `set application_name='tesl-exec:stage-abi-refusal'`); err != nil {
		t.Fatal(err)
	}
	_, abiErr := f.worker.Exec(ctx, `select notes.tesl_claim_index((select id from notes.tesl_schema_index where is_unique and state='failed' limit 1),3,$1,6000)`, actualABI)
	if _, err := f.installer.Exec(ctx, `update notes.tesl_schema_stage_contracts set compiler_abi=$1 where version=3`, actualABI); err != nil {
		t.Fatal(err)
	}
	if _, err := f.worker.Exec(ctx, `select set_config('application_name',$1,false)`, applicationName); err != nil {
		t.Fatal(err)
	}
	if abiErr == nil || !strings.Contains(abiErr.Error(), "unfinished index compiler ABI differs") {
		t.Fatal("promotion lease borrowed the expansion ABI", abiErr)
	}
	app := pgRowAdditiveApp(t, f, root, "v3-contract")
	pgCallRowAccessApp(t, ctx, app, "GET", "/all", 200)
	tx, err = request.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `select notes.tesl_admit_writer(3); update notes.notes set title='repaired' where id='legacy-b'; delete from notes.notes where id='legacy-c'`); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if out, err := pgRowAdditiveCommand(f, root, "v3-contract", "--schema", "contract", "V3", "--json").CombinedOutput(); err != nil {
		t.Fatalf("repair/retry: %v %s", err, out)
	}
	var enforced, triggers int
	if err := f.worker.QueryRow(ctx, `select (select count(*) from notes.tesl_schema_stages where state='enforced'),(select count(*) from pg_catalog.pg_trigger where tgrelid='notes.notes'::regclass and not tgisinternal)`).Scan(&enforced, &triggers); err != nil || enforced != 5 || triggers != 0 {
		t.Fatal("incomplete native enforcement switchover", enforced, triggers, err)
	}
	pgStageInstall(t, f, root, "v4")
	pgRowAdditiveWorker(t, f, root, "v4")()
	reliant := pgRowAdditiveApp(t, f, root, "v4")
	pgCallRowAccessApp(t, ctx, reliant, "POST", "/two", 200)
	pgCallRowAccessApp(t, ctx, reliant, "POST", "/two", 200)
	var count int
	if err := f.worker.QueryRow(ctx, `select count(*) from notes.notes where title='two'`).Scan(&count); err != nil || count != 1 {
		t.Fatal("V4 conflict reliance failed", count, err)
	}
	if _, err := f.installer.Exec(ctx, `update pg_catalog.pg_index set indisvalid=false where indexrelid='notes.title_unique'::regclass`); err != nil {
		t.Fatal(err)
	}
	for _, version := range []int{3, 4} {
		if _, err := request.Exec(ctx, `select notes.tesl_admit_writer($1)`, version); err == nil {
			t.Fatal("enforcement receipt bypassed invalid target", version)
		}
	}
	if _, err := f.installer.Exec(ctx, `update pg_catalog.pg_index set indisvalid=true where indexrelid='notes.title_unique'::regclass`); err != nil {
		t.Fatal(err)
	}
	pgStageInstall(t, f, root, "v4")
	if out, err := pgRowAdditiveCommand(f, root, "v3-contract", "--schema", "contract", "V3", "--json").CombinedOutput(); err != nil {
		t.Fatalf("historical enforced Contract replay: %v %s", err, out)
	}
}
