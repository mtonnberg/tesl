package migrationtest

import (
	"bytes"
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
import ("fmt";"context";"os";"github.com/jackc/pgx/v5"; fixture %q; %q)
func main() {
 if err:=teslrt.PreflightApplicationDatabases(fixture.FixtureDbDatabase);err!=nil {panic(err)}
 history, ok := fixture.FixtureDbDatabase.CompiledMigrationHistory()
 if !ok || history.Database != "App.FixtureDb" || history.Family != "StorageSchema" ||
   history.Namespace != "storage_fixture" || history.CurrentVersion != 1 || history.SourceCompilerABI == "" || history.HistoryJSON == "" {
   panic("compiled migration history is not linked to the application connection")
 }
 if len(os.Args)>1 && os.Args[1]=="install" {
   ctx:=context.Background()
   config,err:=pgx.ParseConfig(os.Getenv("TESL_STORAGE_INSTALL_DSN"));if err!=nil {panic(err)}
   config.Database=os.Getenv("TESL_FIXTURE_DATABASE")
   conn,err:=pgx.ConnectConfig(ctx,config);if err!=nil {panic(err)};defer conn.Close(ctx)
   _,err=teslrt.InstallPgCompiledRowBaseline(ctx,conn,fixture.FixtureDbDatabase,teslrt.PgMigrationControlRoles{Owner:os.Getenv("TESL_FIXTURE_CONTROL_OWNER"),Worker:os.Getenv("TESL_TEST_POSTGRES_SHARED_USER")})
   if err!=nil {panic(err)};return
 }
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

	cmd := exec.CommandContext(f.ctx, binary)
	cmd.Env = append(os.Environ(), "TESL_FIXTURE_DATABASE="+database,
		"TESL_TEST_POSTGRES_SHARED_HOST="+config.Host,
		fmt.Sprintf("TESL_TEST_POSTGRES_SHARED_PORT=%d", config.Port),
		"TESL_TEST_POSTGRES_SHARED_USER="+f.worker, "PGPASSWORD="+config.Password, "TESL_FIXTURE_CONTROL_OWNER="+f.control)
	install := exec.CommandContext(f.ctx, binary, "install")
	install.Env = append(cmd.Env, "TESL_STORAGE_INSTALL_DSN="+config.ConnString())
	if installed, err := install.CombinedOutput(); err != nil {
		t.Fatalf("install compiler-linked storage baseline: %v\n%s", err, installed)
	}
	var output, diagnostics bytes.Buffer
	cmd.Stdout, cmd.Stderr = &output, &diagnostics
	if err := cmd.Run(); err != nil || strings.TrimSpace(output.String()) != "ok" {
		t.Fatalf("typed storage round trip: %v\nstdout: %s\nstderr: %s\n%s", err, output.String(), diagnostics.String(), f.dump())
	}
	var catalog string
	err = conn.QueryRow(f.ctx, `select string_agg(attname || ':' || format_type(atttypid, atttypmod), ',' order by attname)
from pg_attribute where attrelid='storage_fixture.samples'::regclass and attnum>0 and not attisdropped`).Scan(&catalog)
	if err != nil || catalog != "_tesl_v:smallint,bounded:integer,builtin:numeric,id:text,label:text,wide:bigint" {
		t.Fatalf("actual PostgreSQL catalog %q: %v", catalog, err)
	}
	// Compare against the independent logical storage preview. The row protocol
	// adds exactly one smallint generation marker, outside the legacy catalog API.
	expectedColumns := map[string]teslrt.PgMigrationCatalogColumn{}
	for _, column := range plan.Steps[0].Catalog[0].Columns {
		expectedColumns[column.Name] = column
	}
	expectedColumns["_tesl_v"] = teslrt.PgMigrationCatalogColumn{Name: "_tesl_v", Type: "int2"}
	rows, err := conn.Query(f.ctx, `select a.attname,t.typname,not a.attnotnull,
 exists(select 1 from pg_constraint c where c.conrelid=a.attrelid and c.contype='p' and a.attnum=any(c.conkey)),
 pg_get_expr(d.adbin,d.adrelid)
 from pg_attribute a join pg_type t on t.oid=a.atttypid
 left join pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
 where a.attrelid='storage_fixture.samples'::regclass and a.attnum>0 and not a.attisdropped`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var actual teslrt.PgMigrationCatalogColumn
		var defaultSQL *string
		if err := rows.Scan(&actual.Name, &actual.Type, &actual.Nullable, &actual.PrimaryKey, &defaultSQL); err != nil {
			rows.Close()
			t.Fatal(err)
		}
		want, exists := expectedColumns[actual.Name]
		if !exists || actual.Name != want.Name || actual.Type != want.Type || actual.Nullable != want.Nullable || actual.PrimaryKey != want.PrimaryKey {
			rows.Close()
			t.Fatalf("independent storage plan mismatch: %+v want %+v", actual, want)
		}
		if actual.Name == "_tesl_v" {
			if defaultSQL == nil || *defaultSQL != "1" {
				rows.Close()
				t.Fatalf("wrong permanent generation default: %v", defaultSQL)
			}
		} else if want.Default != nil || defaultSQL != nil {
			rows.Close()
			t.Fatalf("unexpected storage default for %s", actual.Name)
		}
		delete(expectedColumns, actual.Name)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		t.Fatal(err)
	}
	rows.Close()
	if len(expectedColumns) != 0 {
		t.Fatalf("missing storage columns: %+v", expectedColumns)
	}
	var label, builtin, bounded, wide string
	err = conn.QueryRow(f.ctx, `select label, builtin::text, bounded::text, wide::text
from storage_fixture.samples where id='round-trip'`).Scan(&label, &builtin, &bounded, &wide)
	if err != nil || label != "not a number: å" || builtin != "2147483647" || bounded != "-2147483648" || wide != "2147483647" {
		t.Fatalf("stored values %q %q %q %q: %v", label, builtin, bounded, wide, err)
	}
}
