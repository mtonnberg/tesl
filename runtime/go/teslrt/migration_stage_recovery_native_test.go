//go:build tesl_migration_test

package teslrt

import (
	"context"
	"os"
	"testing"
	"time"
)

func TestPgStageGuardContractCrashRecovery(t *testing.T) {
	root := os.Getenv("TESL_STAGE_GUARD_PROGRAMS")
	if root == "" {
		t.Skip("compiled stage lifecycle programs required")
	}
	t.Setenv("TESL_LEASE_TTL_S", "6")
	t.Setenv("TESL_SCHEMA_POLL_S", "1")
	for _, boundary := range []string{"stage-contract-after-intent", "stage-contract-after-floor", "stage-contract-after-handoff", "index-after-create", "stage-before-enforcement", "stage-after-enforcement-statement", "stage-after-enforcement-commit"} {
		t.Run(boundary, func(t *testing.T) {
			f, _ := pgNewWorkerTest(t)
			f.namespace = "notes"
			ctx, cancel := context.WithTimeout(context.Background(), 100*time.Second)
			t.Cleanup(cancel)
			f.ctx = ctx
			pgStageInstall(t, f, root, "v3-contract")
			if out, err := pgRowAdditiveCommand(f, root, "v3-contract", "--schema", "catch-up", "--json").CombinedOutput(); err != nil {
				t.Fatalf("setup: %v %s", err, out)
			}
			pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{boundary, 1}})
			defer pauses[0].resume()
			cmd := pgRowAdditiveCommand(f, root, "v3-contract", "--schema", "contract", "V3", "--json")
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
				t.Fatalf("before %s: %v %s", boundary, err, output.String())
			case <-ctx.Done():
				t.Fatal("crash boundary timeout", boundary, output.String())
			}
			oids := map[string]int64{}
			rows, err := f.worker.Query(ctx, `select c.relname,c.oid::bigint from pg_catalog.pg_index i join pg_catalog.pg_class c on c.oid=i.indexrelid
    where i.indrelid='notes.notes'::regclass and i.indisunique and not i.indisprimary and i.indisvalid and i.indisready and i.indislive`)
			if err != nil {
				t.Fatal(err)
			}
			for rows.Next() {
				var name string
				var oid int64
				if err := rows.Scan(&name, &oid); err != nil {
					t.Fatal(err)
				}
				oids[name] = oid
			}
			if err := rows.Err(); err != nil {
				t.Fatal(err)
			}
			rows.Close()
			var floor, targets int
			if err := f.worker.QueryRow(ctx, `select min_version,(select count(*) from notes.tesl_schema_index where is_unique) from notes.tesl_schema_state`).Scan(&floor, &targets); err != nil {
				t.Fatal(err)
			}
			if boundary == "stage-contract-after-intent" && (floor != 1 || targets != 0) {
				t.Fatal("intent advanced floor/build", floor, targets)
			}
			if boundary == "stage-contract-after-floor" && (floor != 3 || targets != 0) {
				t.Fatal("floor/build ordering", floor, targets)
			}
			if err := cmd.Process.Kill(); err != nil {
				t.Fatal(err)
			}
			select {
			case <-done:
				joined = true
			case <-ctx.Done():
				t.Fatal("worker did not exit")
			}
			pauses[0].resume()
			if out, err := pgRowAdditiveCommand(f, root, "v3-contract", "--schema", "contract", "V3", "--json").CombinedOutput(); err != nil {
				t.Fatalf("recovery: %v %s", err, out)
			}
			for name, want := range oids {
				var oid int64
				if err := f.worker.QueryRow(ctx, `select pg_catalog.to_regclass($1)::oid::bigint`, "notes."+name).Scan(&oid); err != nil || oid != want {
					t.Fatal("recovery rebuilt a valid target", name, want, oid, err)
				}
			}
			if boundary == "index-after-create" {
				var token int64
				if err := f.worker.QueryRow(ctx, `select max(l.token) from notes.tesl_schema_index j join notes.tesl_schema_leases l on l.name='index:'||j.index_name where j.is_unique`).Scan(&token); err != nil || token < 2 {
					t.Fatal("index lease takeover was not fenced", token, err)
				}
			}
			var enforced int
			if err := f.worker.QueryRow(ctx, `select count(*) from notes.tesl_schema_stages where state='enforced'`).Scan(&enforced); err != nil || enforced != 5 {
				t.Fatal("recovery did not finish", enforced, err)
			}
			pgStageInstall(t, f, root, "v4")
		})
	}
}

func TestPgStageGuardFourReleaseCatchup(t *testing.T) {
	root := os.Getenv("TESL_STAGE_GUARD_PROGRAMS")
	if root == "" {
		t.Skip("compiled stage lifecycle programs required")
	}
	t.Setenv("TESL_SCHEMA_POLL_S", "1")
	f, _ := pgNewWorkerTest(t)
	f.namespace = "notes"
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
	t.Cleanup(cancel)
	f.ctx = ctx
	pgStageInstall(t, f, root, "v4")
	if out, err := pgRowAdditiveCommand(f, root, "v4", "--schema", "catch-up", "--json").CombinedOutput(); err != nil {
		t.Fatalf("four-release catchup: %v %s", err, out)
	}
	var current, floor, enforced int
	if err := f.worker.QueryRow(f.ctx, `select current,min_version,(select count(*) from notes.tesl_schema_stages where state='enforced') from notes.tesl_schema_state`).Scan(&current, &floor, &enforced); err != nil || current != 4 || floor != 3 || enforced != 5 {
		t.Fatal("catchup identity/enforcement differs", current, floor, enforced, err)
	}
	app := pgRowAdditiveApp(t, f, root, "v4")
	pgCallRowAccessApp(t, f.ctx, app, "POST", "/two", 200)
	pgCallRowAccessApp(t, f.ctx, app, "POST", "/two", 200)
}

func TestPgStageGuardFourReleaseDeploy(t *testing.T) {
	root := os.Getenv("TESL_STAGE_GUARD_PROGRAMS")
	if root == "" {
		t.Skip("compiled stage lifecycle programs required")
	}
	t.Setenv("TESL_SCHEMA_POLL_S", "1")
	f, _ := pgNewWorkerTest(t)
	f.namespace = "notes"
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
	t.Cleanup(cancel)
	f.ctx = ctx
	cmd := pgRowAdditiveCommand(f, root, "v4", "--schema", "deploy", "--json")
	cmd.Env = append(cmd.Env, "TESL_SCHEMA_INSTALLER_DSN="+f.installer.Config().ConnString())
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("four-release deploy: %v %s", err, out)
	}
	var current, floor, enforced int
	if err := f.worker.QueryRow(ctx, `select current,min_version,(select count(*) from notes.tesl_schema_stages where state='enforced') from notes.tesl_schema_state`).Scan(&current, &floor, &enforced); err != nil || current != 4 || floor != 3 || enforced != 5 {
		t.Fatal("deployment identity/enforcement differs", current, floor, enforced, err)
	}
}
