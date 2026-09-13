//go:build linux

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
	"tesl.dev/runtime/go/internal/cli"
	"tesl.dev/runtime/go/teslrt"
)

// INV-ADDITIVE-READ, INV-ADDITIVE-WRITE; TR-BOOT-EXPAND.
// Actual source generation -> compiler -> linked standalone executable ->
// production executor. No harness DDL implements a migration in this test.
// Request dispatch and permanent admission have separate integration gates.
func TestCompiledMigrationExpansionRetainsRowsAcrossStandaloneRevisions(t *testing.T) {
	dsn := os.Getenv("TESL_MIGRATION_TEST_DSN")
	if dsn == "" {
		t.Skip("run scripts/run-migration-tests.sh")
	}
	root := os.Getenv("TESL_REPO_ROOT")
	if root == "" {
		t.Fatal("TESL_REPO_ROOT is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	compiler := filepath.Join(root, "compiler/_build/default/bin/main.exe")
	project := filepath.Join(t.TempDir(), "source")
	var output bytes.Buffer
	app := cli.New()
	app.Directory, app.Stdout, app.Stderr = project, &output, &output
	app.Resolver.Getenv = func(key string) string {
		if key == "TESL_COMPILER" {
			return compiler
		}
		return os.Getenv(key)
	}
	write := func(name, text string) {
		t.Helper()
		path := filepath.Join(project, name)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
	}
	check := func(name string, valid bool) {
		t.Helper()
		cmd := exec.CommandContext(ctx, compiler, "agent-context", filepath.Join(project, name))
		cmd.Dir = project
		text, err := cmd.CombinedOutput()
		if (err == nil) != valid {
			t.Fatalf("source diagnostics for %s: %v\n%s", name, err, text)
		}
	}
	runCLI := func(args ...string) {
		t.Helper()
		output.Reset()
		if err := app.Run(ctx, args); err != nil {
			t.Fatalf("native migration command: %v\n%s", err, &output)
		}
	}
	const source = `module App exposing []
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import NotesSchema.VCurrent
database Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate,
 backend: Postgres (PostgresConfig { dbName: "notes", user: "tesl", password: "", namespace: "notes_app",
 connection: TcpConnection { host: "127.0.0.1", port: 5432 } }) }
`
	const schema = `module NotesSchema.VCurrent exposing [Note]
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe]
entity Note table "notes" primaryKey id { id: String%s }
`
	write("tesl.toml", "")
	write("schema/notes/v-current.tesl", fmt.Sprintf(schema, ""))
	check("schema/notes/v-current.tesl", true)
	write("app.tesl", source)
	check("app.tesl", true)
	var binaries [3]string
	for version := 1; version <= 3; version++ {
		if version > 1 {
			runCLI("migrate", "generate", "app.tesl", "--new-revision")
			fields := ", caption: Maybe String"
			if version == 3 {
				fields += ", summary: Maybe String"
			}
			write("schema/notes/v-current.tesl", fmt.Sprintf(schema, fields))
			check("schema/notes/v-current.tesl", false)
			runCLI("migrate", "generate", "app.tesl")
			check("app.tesl", true)
			check(fmt.Sprintf("migrations/notes/v%d.tesl", version), true)
		}
		generated := filepath.Join(t.TempDir(), fmt.Sprintf("v%d", version))
		runCLI("compile", "app.tesl", "--out", generated)
		module, err := os.ReadFile(filepath.Join(generated, "go.mod"))
		if err != nil {
			t.Fatal(err)
		}
		fields := strings.Fields(string(module))
		if len(fields) < 2 || fields[0] != "module" {
			t.Fatal("missing generated module")
		}
		launcher := filepath.Join(generated, "cmd/expand")
		if err := os.MkdirAll(launcher, 0700); err != nil {
			t.Fatal(err)
		}
		program := fmt.Sprintf(`package main
import("context";"encoding/json";"os";"time";"github.com/jackc/pgx/v5";fixture %q;%q)
func main(){
 ctx,cancel:=context.WithTimeout(context.Background(),20*time.Second);defer cancel()
 history,ok:=fixture.MainDatabase.CompiledMigrationHistory();if !ok {panic("missing linked history")}
 config,err:=pgx.ParseConfig(os.Getenv("TESL_EXPANSION_DSN"));if err!=nil {panic(err)}
 config.Database=os.Getenv("TESL_EXPANSION_DATABASE");config.User=os.Getenv("TESL_EXPANSION_WORKER")
 conn,err:=pgx.ConnectConfig(ctx,config);if err!=nil {panic(err)};defer conn.Close(ctx)
 state,err:=teslrt.ExecutePgMigrationExpansion(ctx,conn,history,teslrt.PgMigrationControlRoles{Owner:os.Getenv("TESL_EXPANSION_OWNER"),Worker:os.Getenv("TESL_EXPANSION_WORKER")})
 if err!=nil {panic(err)};if err:=json.NewEncoder(os.Stdout).Encode(state);err!=nil {panic(err)}
}
`, fields[1]+"/internal/teslmodapp", fields[1]+"/internal/teslrt")
		if err := os.WriteFile(filepath.Join(launcher, "main.go"), []byte(program), 0600); err != nil {
			t.Fatal(err)
		}
		binary := filepath.Join(t.TempDir(), fmt.Sprintf("revision%d", version))
		build := exec.CommandContext(ctx, "go", "build", "-race", "-o", binary, "./cmd/expand")
		build.Dir = generated
		if text, err := build.CombinedOutput(); err != nil {
			t.Fatalf("build emitted executor: %v\n%s", err, text)
		}
		binaries[version-1] = binary
		// Only the binary survives: no sources, Go package or JSON sidecar.
		if err := os.RemoveAll(generated); err != nil {
			t.Fatal(err)
		}
		application, err := os.ReadFile(filepath.Join(project, "app.tesl"))
		if err != nil || string(application) != source {
			t.Fatal("migration changed application connection ownership")
		}
	}
	if err := os.RemoveAll(project); err != nil {
		t.Fatal(err)
	}
	admin, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = admin.Close(context.Background()) }()
	name := "exec_" + strings.ReplaceAll(teslrt.UUIDv7(), "-", "")
	roles := teslrt.PgMigrationControlRoles{Owner: name + "_owner", Worker: name + "_worker"}
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		_, _ = admin.Exec(cleanup, "drop database if exists "+pgx.Identifier{name}.Sanitize()+" with (force)")
		_, _ = admin.Exec(cleanup, "drop role if exists "+pgx.Identifier{roles.Worker}.Sanitize())
		_, _ = admin.Exec(cleanup, "drop role if exists "+pgx.Identifier{roles.Owner}.Sanitize())
	}()
	for _, sql := range []string{"create role " + roles.Owner + " nologin", "create role " + roles.Worker + " login", "create database " + name, "grant create on database " + name + " to " + roles.Owner} {
		if _, err := admin.Exec(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	config := admin.Config().Copy()
	config.Database = name
	installer, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = installer.Close(context.Background()) }()
	if _, err := installer.Exec(ctx, "grant create on schema public to "+roles.Owner); err != nil {
		t.Fatal(err)
	}
	seed, err := teslrt.InstallPgMigrationControl(ctx, installer, "notes_app", roles, 1)
	if err != nil {
		t.Fatal(err)
	}
	config.User = roles.Worker
	for _, version := range []int{1, 2, 3, 1, 2, 3} {
		cmd := exec.CommandContext(ctx, binaries[version-1])
		cmd.Env = append(os.Environ(), "TESL_EXPANSION_DSN="+dsn, "TESL_EXPANSION_DATABASE="+name, "TESL_EXPANSION_OWNER="+roles.Owner, "TESL_EXPANSION_WORKER="+roles.Worker)
		text, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("execute standalone V%d: %v\n%s", version, err, text)
		}
		var state teslrt.PgMigrationControlState
		if err := json.Unmarshal(text, &state); err != nil || state.DatabaseUUID != seed.DatabaseUUID || state.InitialVersion != 1 || state.Current < version {
			t.Fatalf("invalid persisted state: %s,%v", text, err)
		}
		if _, err := installer.Exec(ctx, "insert into notes_app.notes(id) values ($1)", teslrt.UUIDv7()); err != nil {
			t.Fatalf("unchanged old writer: %v", err)
		}
	}
	var count int
	if err := installer.QueryRow(ctx, "select count(*) from notes_app.notes where caption is null and summary is null").Scan(&count); err != nil || count != 6 {
		t.Fatalf("standalone migrations lost rows: %d,%v", count, err)
	}
}
