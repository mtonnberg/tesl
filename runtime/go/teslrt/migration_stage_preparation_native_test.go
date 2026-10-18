//go:build tesl_migration_test

package teslrt

import (
	"context"
	"encoding/hex"
	"os"
	"strings"
	"testing"
	"time"
)

func pgStagePrograms(t *testing.T) string {
	t.Helper()
	root := os.Getenv("TESL_STAGE_PREPARATION_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated predecessor/staging programs required")
	}
	return root
}

func pgStageInstall(t *testing.T, f *pgControlTestFixture, root, version string) {
	t.Helper()
	if out, err := pgRowAdditiveCommand(f, root, version, "--schema", "install", "--worker", f.roles.Worker, "--request", f.roles.Request, "--json").CombinedOutput(); err != nil {
		t.Fatalf("install: %v %s", err, out)
	}
}

func pgAwaitStageIndexes(t *testing.T, f *pgControlTestFixture, count int) {
	t.Helper()
	ctx, cancel := context.WithTimeout(f.ctx, 15*time.Second)
	defer cancel()
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		var pending, valid int
		if err := f.worker.QueryRow(ctx, `select (select count(*) from notes.tesl_schema_stages where state='pending'),(select count(*) from notes.tesl_schema_index where state='valid')`).Scan(&pending, &valid); err != nil {
			t.Fatal(err)
		}
		if pending == 2 && valid == count {
			return
		}
		select {
		case <-ctx.Done():
			t.Fatal("stage index completion", pending, valid, ctx.Err())
		case <-ticker.C:
		}
	}
}

func pgStageSnapshot(t *testing.T, f *pgControlTestFixture) string {
	t.Helper()
	var state string
	if err := f.worker.QueryRow(f.ctx, `select jsonb_agg(to_jsonb(s) order by stage_id)::text from notes.tesl_schema_stages s`).Scan(&state); err != nil {
		t.Fatal(err)
	}
	return state
}

func TestPgStagePreparationPredecessorCarryRestart(t *testing.T) {
	root := pgStagePrograms(t)
	f, _ := pgNewWorkerTest(t)
	f.namespace = "notes"
	pgStageInstall(t, f, root, "v1")
	pgRowAdditiveWorker(t, f, root, "v1")()
	old := pgRowAdditiveApp(t, f, root, "v1")
	pgCallRowAccessApp(t, f.ctx, old, "POST", "/one", 200)
	stop := pgRowAdditiveWorker(t, f, root, "v2")
	pgAwaitStageIndexes(t, f, 2)
	frozen := pgStageSnapshot(t, f)
	fresh := pgRowAdditiveApp(t, f, root, "v2")
	pgCallRowAccessApp(t, f.ctx, fresh, "POST", "/two", 200)
	pgCallRowAccessApp(t, f.ctx, old, "PUT", "/edit", 200)
	pgCallRowAccessApp(t, f.ctx, old, "GET", "/all", 200)
	var duplicates, indexes int
	if err := f.worker.QueryRow(f.ctx, `select count(*) from notes.notes where active`).Scan(&duplicates); err != nil || duplicates != 2 {
		t.Fatal("old writer must be allowed to create duplicates", duplicates, err)
	}
	if _, err := f.worker.Exec(f.ctx, `update notes.notes set amount=7`); err != nil {
		t.Fatal(err)
	}
	if err := f.worker.QueryRow(f.ctx, `select count(*) from pg_catalog.pg_index i join pg_catalog.pg_class c on c.oid=i.indexrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='notes' and c.relname in ('active_lookup','amount_lookup') and not i.indisunique and i.indisvalid and i.indisready and i.indislive`).Scan(&indexes); err != nil || indexes != 2 {
		t.Fatal("preparatory indexes must be nonunique and valid", indexes, err)
	}
	stop()
	stop = pgRowAdditiveWorker(t, f, root, "v3")
	pgAwaitStageIndexes(t, f, 3)
	stop()
	pgStageInstall(t, f, root, "v3")
	stop = pgRowAdditiveWorker(t, f, root, "v3")
	pgAwaitStageIndexes(t, f, 3)
	stop()
	if got := pgStageSnapshot(t, f); got != frozen {
		t.Fatal("restart/carry/reinstall rewrote introduction identity", got, frozen)
	}
	pgCallRowAccessApp(t, f.ctx, old, "GET", "/all", 200)
	pgCallRowAccessApp(t, f.ctx, old, "PUT", "/edit", 200)
}

func TestPgStagePreparationCatchupAndTamper(t *testing.T) {
	root := pgStagePrograms(t)
	f, _ := pgNewWorkerTest(t)
	f.namespace = "notes"
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	f.ctx = ctx
	pgStageInstall(t, f, root, "v3")
	if out, err := pgRowAdditiveCommand(f, root, "v3", "--schema", "catch-up", "--json").CombinedOutput(); err != nil {
		t.Fatalf("finite stage catch-up: %v %s", err, out)
	}
	pgAwaitStageIndexes(t, f, 3)
	var current, minimum int
	if err := f.worker.QueryRow(f.ctx, `select current,min_version from notes.tesl_schema_state`).Scan(&current, &minimum); err != nil || current != 3 || minimum != 1 {
		t.Fatal("catchup invented admission identity", current, minimum, err)
	}
	refuse := func(t *testing.T) {
		t.Helper()
		out, err := pgRowAdditiveCommand(f, root, "v3", "--schema", "install", "--worker", f.roles.Worker, "--request", f.roles.Request, "--json").CombinedOutput()
		if err == nil {
			t.Fatalf("tampered stage accepted: %s", out)
		}
	}
	for _, column := range []string{"source_abi", "source_snapshot", "descriptor"} {
		t.Run(column, func(t *testing.T) {
			var saved []byte
			// Use one owner-selected row. Restore exact bytes after each refusal.
			if column == "descriptor" {
				if err := f.installer.QueryRow(f.ctx, `select descriptor from notes.tesl_schema_stages order by stage_id limit 1`).Scan(&saved); err != nil {
					t.Fatal(err)
				}
				node, _, err := pgReadRowCanonical(hex.EncodeToString(saved))
				if err != nil || !node.list(10) {
					t.Fatal("fixture stage descriptor", err)
				}
				// Keep the semantic ID, index name, canonical framing and checksum
				// valid. Only full descriptor/source comparison detects this drift.
				if node.children[7].isAtom("bool") {
					node.children[7] = pgRowAtom("int4")
				} else {
					node.children[7] = pgRowAtom("bool")
				}
				if _, err := f.installer.Exec(f.ctx, `update notes.tesl_schema_stages set descriptor=$1,descriptor_hash=encode(sha256($1),'hex') where stage_id=(select min(stage_id) from notes.tesl_schema_stages)`, []byte(pgRowEncode(node))); err != nil {
					t.Fatal(err)
				}
				refuse(t)
				if _, err := f.installer.Exec(f.ctx, `update notes.tesl_schema_stages set descriptor=$1,descriptor_hash=encode(sha256($1),'hex') where stage_id=(select min(stage_id) from notes.tesl_schema_stages)`, saved); err != nil {
					t.Fatal(err)
				}
			} else {
				var text string
				if err := f.installer.QueryRow(f.ctx, "select "+column+" from notes.tesl_schema_stages order by stage_id limit 1").Scan(&text); err != nil {
					t.Fatal(err)
				}
				changed := strings.Repeat("0", 64)
				if column == "source_abi" {
					changed = "tesl-source-abi-v1:" + changed
				}
				if _, err := f.installer.Exec(f.ctx, "update notes.tesl_schema_stages set "+column+"=$1 where stage_id=(select min(stage_id) from notes.tesl_schema_stages)", changed); err != nil {
					t.Fatal(err)
				}
				refuse(t)
				if _, err := f.installer.Exec(f.ctx, "update notes.tesl_schema_stages set "+column+"=$1 where stage_id=(select min(stage_id) from notes.tesl_schema_stages)", text); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
	if _, err := f.installer.Exec(f.ctx, "grant update on notes.tesl_schema_stages to "+quoteIdentifier(f.roles.Request)); err != nil {
		t.Fatal(err)
	}
	refuse(t)
	if _, err := f.installer.Exec(f.ctx, "revoke update on notes.tesl_schema_stages from "+quoteIdentifier(f.roles.Request)); err != nil {
		t.Fatal(err)
	}
	if _, err := f.installer.Exec(f.ctx, `alter table notes.tesl_schema_stage_protocol add column foreign_shape text`); err != nil {
		t.Fatal(err)
	}
	refuse(t)
	if _, err := f.installer.Exec(f.ctx, `alter table notes.tesl_schema_stage_protocol drop column foreign_shape`); err != nil {
		t.Fatal(err)
	}
	if _, err := f.installer.Exec(f.ctx, `alter table notes.tesl_schema_stage_protocol rename to old_stage_protocol`); err != nil {
		t.Fatal(err)
	}
	refuse(t)
	if _, err := f.installer.Exec(f.ctx, `alter table notes.old_stage_protocol rename to tesl_schema_stage_protocol`); err != nil {
		t.Fatal(err)
	}
	if _, err := f.installer.Exec(f.ctx, `drop index notes.active_lookup; create unique index active_lookup on notes.notes(active)`); err != nil {
		t.Fatal(err)
	}
	refuse(t)
	if _, err := f.installer.Exec(f.ctx, `drop index notes.active_lookup; create index active_lookup on notes.notes(active)`); err != nil {
		t.Fatal(err)
	}
	pgStageInstall(t, f, root, "v3")
	before := pgStageSnapshot(t, f)
	if out, err := pgRowAdditiveCommand(f, root, "v3", "--schema", "contract", "V2", "--json").CombinedOutput(); err == nil {
		t.Fatalf("unreviewed stage promotion accepted: %s", out)
	}
	if pgStageSnapshot(t, f) != before {
		t.Fatal("refused promotion mutated pending stages")
	}
}

func TestPgStagePreparationInterruptedIndexBuild(t *testing.T) {
	root := pgStagePrograms(t)
	f, _ := pgNewWorkerTest(t)
	f.namespace = "notes"
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	f.ctx = ctx
	t.Setenv("TESL_LEASE_TTL_S", "6")
	t.Setenv("TESL_SCHEMA_POLL_S", "1")
	pgStageInstall(t, f, root, "v1")
	pgRowAdditiveWorker(t, f, root, "v1")()
	pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{"index-before-create", 1}})
	defer pauses[0].resume()
	cmd := pgRowAdditiveCommand(f, root, "v2", "--schema", "worker", "--json")
	cmd.Env = append(cmd.Env, "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
	var output pgRowAppOutput
	cmd.Stdout, cmd.Stderr = &output, &output
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
		t.Fatalf("worker exited before stage index build: %v %s", err, output.String())
	case <-ctx.Done():
		t.Fatal("stage index build boundary not reached", output.String())
	}
	frozen := pgStageSnapshot(t, f)
	var pending int
	if err := f.worker.QueryRow(ctx, `select count(*) from notes.tesl_schema_index where state<>'valid'`).Scan(&pending); err != nil || pending == 0 {
		t.Fatal("build pause did not retain unfinished index work", pending, err)
	}
	if err := cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
		joined = true
	case <-ctx.Done():
		t.Fatal("killed worker did not exit")
	}
	pauses[0].resume()
	stop := pgRowAdditiveWorker(t, f, root, "v2")
	pgAwaitStageIndexes(t, f, 2)
	stop()
	if pgStageSnapshot(t, f) != frozen {
		t.Fatal("index recovery rewrote source-bound stage identity")
	}
}
