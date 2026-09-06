package migrationtest

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"tesl.dev/runtime/go/teslrt"
)

// INV-CATALOG-EVIDENCE; TR-CATALOG-COMPARE.
// The emitted application creates its own catalog and round-trips typed values.
// This verifies storage mapping through actual versioned startup and admission.
func TestCompiledStorageUsesOwnedTypeBaseAndBuiltinBounds(t *testing.T) {
	if os.Getenv("TESL_MIGRATION_TEST_DSN") == "" {
		t.Skip("PostgreSQL process matrix: run scripts/run-migration-tests.sh")
	}
	root := os.Getenv("TESL_REPO_ROOT")
	if root == "" {
		var err error
		root, err = filepath.Abs("../../../..")
		if err != nil {
			t.Fatal(err)
		}
	}
	buildCtx, cancelBuild := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancelBuild()
	dir := filepath.Join(t.TempDir(), "emitted")
	source := filepath.Join(root, "runtime/go/internal/migrationtest/testdata/storage/app.tesl")
	planCommand := exec.CommandContext(buildCtx, filepath.Join(root, "compiler/_build/default/bin/main.exe"),
		"migrate", "plan", source, "--project-root", filepath.Dir(source))
	planCommand.Env = append(os.Environ(), "TESL_REPO_ROOT="+root)
	planJSON, err := planCommand.CombinedOutput()
	if err != nil {
		t.Fatalf("derive compiled storage plan: %v\n%s", err, planJSON)
	}
	var plan struct {
		Version                      int
		Kind, Namespace, CompilerABI string
		OK                           bool
		Executable                   *bool
		Steps                        []struct {
			Version int
			Catalog []teslrt.PgMigrationCatalogTable
		}
	}
	if err = json.Unmarshal(planJSON, &plan); err != nil || plan.Version != 1 || plan.Kind != "migration-plan-preview" ||
		!plan.OK || plan.Executable == nil || *plan.Executable || len(plan.Steps) != 1 || plan.Steps[0].Version != 1 ||
		len(plan.Steps[0].Catalog) != 1 || plan.Namespace != "storage_fixture" || !strings.HasPrefix(plan.CompilerABI, "tesl-source-abi-v1:") {
		t.Fatalf("incomplete storage plan: %s %v", planJSON, err)
	}
	compile := exec.CommandContext(buildCtx, filepath.Join(root, "compiler/_build/default/bin/main.exe"), source, "--out", dir)
	compile.Env = append(os.Environ(), "TESL_REPO_ROOT="+root)
	if output, err := compile.CombinedOutput(); err != nil {
		t.Fatalf("compile storage fixture: %v\n%s", err, output)
	}
	module, err := os.ReadFile(filepath.Join(dir, "go.mod"))
	if err != nil {
		t.Fatal(err)
	}
	fields := strings.Fields(string(module))
	if len(fields) < 2 || fields[0] != "module" {
		t.Fatal("emitted module declaration missing")
	}
	launcher := filepath.Join(dir, "cmd", "storage-fixture")
	if err = os.MkdirAll(launcher, 0700); err != nil {
		t.Fatal(err)
	}
	program := fmt.Sprintf(`package main
import ("fmt"; fixture %q; %q)
func main() {
 history, ok := fixture.FixtureDbDatabase.CompiledMigrationHistory()
 if !ok || history.Database != "App.FixtureDb" || history.Family != "StorageSchema" ||
   history.Namespace != "storage_fixture" || history.CurrentVersion != 1 || history.SourceCompilerABI == "" || history.HistoryJSON == "" {
   panic("compiled migration history is not linked to the application connection")
 }
 plan, err := history.ExpansionPlan(1)
 if err != nil { panic(err) }
 if len(plan.Steps) != 1 || len(plan.Steps[0].Catalog) != 1 { panic("incomplete linked expansion plan") }
 teslrt.WithDatabase(fixture.FixtureDbDatabase, func() { fmt.Println(fixture.RoundTrip()) })
}
`, fields[1]+"/internal/teslmodapp", fields[1]+"/internal/teslrt")
	if err = os.WriteFile(filepath.Join(launcher, "main.go"), []byte(program), 0600); err != nil {
		t.Fatal(err)
	}
	binary := filepath.Join(dir, "storage-fixture")
	build := exec.CommandContext(buildCtx, "go", "build", "-race", "-o", binary, "./cmd/storage-fixture")
	build.Dir = dir
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build storage fixture: %v\n%s", err, output)
	}
	if err := os.Remove(filepath.Join(dir, "migration-history.json")); err != nil {
		t.Fatal(err)
	}
	f := newDatabaseFixture(t)
	database := f.schema + "_storage"
	f.activityDatabases = []string{database}
	f.exec(t, "create database "+database)
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if _, err := f.conn.Exec(ctx, "drop database "+database+" with (force)"); err != nil {
			t.Error(err)
		}
	})
	config, err := pgx.ParseConfig(f.dsn)
	if err != nil {
		t.Fatal(err)
	}
	config.Database = database
	conn, err := pgx.ConnectConfig(f.ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close(context.Background()) })
	f.exec(t, "alter role "+f.worker+" login")
	f.exec(t, "grant create on database "+database+" to "+f.control)
	if _, err := conn.Exec(f.ctx, "grant create on schema public to "+f.control); err != nil {
		t.Fatal(err)
	}
	if _, err := teslrt.InstallPgMigrationControl(f.ctx, conn, plan.Namespace, teslrt.PgMigrationControlRoles{Owner: f.control, Worker: f.worker}, 1); err != nil {
		t.Fatal(err)
	}

	cmd := exec.CommandContext(f.ctx, binary)
	cmd.Env = append(os.Environ(), "TESL_FIXTURE_DATABASE="+database,
		"TESL_TEST_POSTGRES_SHARED_HOST="+config.Host,
		fmt.Sprintf("TESL_TEST_POSTGRES_SHARED_PORT=%d", config.Port),
		"TESL_TEST_POSTGRES_SHARED_USER="+f.worker, "PGPASSWORD="+config.Password, "TESL_FIXTURE_CONTROL_OWNER="+f.control)
	if output, err := cmd.CombinedOutput(); err != nil || strings.TrimSpace(string(output)) != "ok" {
		t.Fatalf("typed storage round trip: %v\n%s\n%s", err, output, f.dump())
	}
	var catalog string
	err = conn.QueryRow(f.ctx, `select string_agg(attname || ':' || format_type(atttypid, atttypmod), ',' order by attname)
from pg_attribute where attrelid='storage_fixture.samples'::regclass and attnum>0 and not attisdropped`).Scan(&catalog)
	if err != nil || catalog != "bounded:integer,builtin:numeric,id:text,label:text,wide:bigint" {
		t.Fatalf("actual PostgreSQL catalog %q: %v", catalog, err)
	}
	report, err := teslrt.InspectPgMigrationCatalog(f.ctx, conn, plan.Namespace, f.worker, plan.Steps[0].Catalog)
	if err != nil || len(report.Drift) != 0 || len(report.Missing) != 0 || len(report.Benign) != 0 {
		t.Fatalf("compiler plan and emitted storage differ: %+v %v", report, err)
	}
	var label, builtin, bounded, wide string
	err = conn.QueryRow(f.ctx, `select label, builtin::text, bounded::text, wide::text
from storage_fixture.samples where id='round-trip'`).Scan(&label, &builtin, &bounded, &wide)
	if err != nil || label != "not a number: å" || builtin != "2147483647" || bounded != "-2147483648" || wide != "2147483647" {
		t.Fatalf("stored values %q %q %q %q: %v", label, builtin, bounded, wide, err)
	}
}
