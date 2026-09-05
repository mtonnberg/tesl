package migrationtest

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// INV-ADDITIVE-READ, INV-ADDITIVE-WRITE, INV-ATOMIC-WRITE; TR-READ, TR-WRITE.
// This is the phase-0 oracle: the test prepares the superset catalog explicitly.
// It does not claim that the runtime can yet execute a migration plan.
func TestCompiledVersionsShareRowsAndPauseInsideTransactions(t *testing.T) {
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
	compiler := filepath.Join(root, "compiler/_build/default/bin/main.exe")
	if _, err := os.Stat(compiler); err != nil {
		t.Fatal("process matrix requires a built compiler: ", err)
	}
	buildCtx, cancelBuild := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancelBuild()
	binaries := make(map[int]string)
	memoryTests := make(map[int]string)
	for _, v := range []int{7, 8, 9} {
		dir := filepath.Join(t.TempDir(), "emitted")
		fixture := filepath.Join(root, fmt.Sprintf("runtime/go/internal/migrationtest/testdata/v%d/app.tesl", v))
		compile := exec.CommandContext(buildCtx, compiler, fixture, "--out", dir)
		compile.Env = append(os.Environ(), "TESL_REPO_ROOT="+root)
		if output, err := compile.CombinedOutput(); err != nil {
			t.Fatalf("compile V%d: %v\n%s", v, err, output)
		}
		memoryTest := filepath.Join(dir, "memory-tests")
		build := exec.CommandContext(buildCtx, "go", "test", "-c", "-race", "-tags", "tesl_migration_test", "-o", memoryTest, "./internal/teslmodapp")
		build.Dir = dir
		if output, err := build.CombinedOutput(); err != nil {
			t.Fatalf("build V%d: %v\n%s", v, err, output)
		}
		memoryTests[v] = memoryTest
		// Tesl's `test with database` correctly truncates tables between tests.
		// The process oracle instead wraps the exported, compiler-emitted entry
		// point in the ordinary application binding so rows survive restarts.
		module, err := os.ReadFile(filepath.Join(dir, "go.mod"))
		if err != nil {
			t.Fatal(err)
		}
		fields := strings.Fields(string(module))
		if len(fields) < 2 || fields[0] != "module" {
			t.Fatal("emitted module declaration missing")
		}
		launcher := filepath.Join(dir, "cmd", "migration-fixture")
		if err = os.MkdirAll(launcher, 0700); err != nil {
			t.Fatal(err)
		}
		source := fmt.Sprintf("package main\nimport ( fixture %q; %q )\nfunc main() { if len(fixture.FixtureDbDatabase.Tables) != 1 || fixture.FixtureDbDatabase.Tables[0].Name != \"notes\" { panic(\"imported entity catalog duplicated or missing\") }; teslrt.WithDatabase(fixture.FixtureDbDatabase, func() { _ = fixture.Perform() }) }\n", fields[1]+"/internal/teslmodapp", fields[1]+"/internal/teslrt")
		if err = os.WriteFile(filepath.Join(launcher, "main.go"), []byte(source), 0600); err != nil {
			t.Fatal(err)
		}
		binary := filepath.Join(dir, "fixture")
		build = exec.CommandContext(buildCtx, "go", "build", "-race", "-tags", "tesl_migration_test", "-o", binary, "./cmd/migration-fixture")
		build.Dir = dir
		if output, err := build.CombinedOutput(); err != nil {
			t.Fatalf("build V%d launcher: %v\n%s", v, err, output)
		}
		binaries[v] = binary
		if v == 7 {
			release := filepath.Join(dir, "release-fixture")
			build = exec.CommandContext(buildCtx, "go", "build", "-o", release, "./cmd/migration-fixture")
			build.Dir = dir
			if output, err := build.CombinedOutput(); err != nil {
				t.Fatalf("release fixture: %v\n%s", err, output)
			}
			contents, err := os.ReadFile(release)
			if err != nil {
				t.Fatal(err)
			}
			for _, testOnly := range []string{"TESL_MIGRATION_TEST_SOCKET", "TESL_MIGRATION_TEST_ACTOR", "migrationOccurrences"} {
				if bytes.Contains(contents, []byte(testOnly)) {
					t.Fatalf("release binary contains test control %s", testOnly)
				}
			}
		}
	}
	f := newDatabaseFixture(t)
	database := f.schema + "_apps"
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
	if _, err = conn.Exec(f.ctx, `create schema migration_fixture;
create table migration_fixture.notes (id text primary key, title text not null, label text, score numeric)`); err != nil {
		t.Fatal(err)
	}
	schedule := NewSchedule(f.dump)
	// Keep below the platform's Unix socket path length even when Go's -test.run
	// selector makes t.TempDir's default path very long.
	socketDir, err := os.MkdirTemp("", "tesl-mig-sock-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(socketDir) })
	socket := filepath.Join(socketDir, "control")
	controller, err := ListenProcesses(f.ctx, socket, schedule)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(controller.Close)
	type outcome struct {
		output      []byte
		err         error
		expectsTest bool
	}
	start := func(version int, actor, test, operation, key, value string) <-chan outcome {
		cmd := exec.CommandContext(f.ctx, binaries[version])
		if test == "memory round trip" {
			cmd = exec.CommandContext(f.ctx, memoryTests[version], "-test.v", "-test.timeout=25s")
		}
		cmd.Env = append(os.Environ(),
			"TESL_FIXTURE_DATABASE="+database, "TESL_FIXTURE_OPERATION="+operation,
			"TESL_FIXTURE_KEY="+key, "TESL_FIXTURE_VALUE="+value,
			"TESL_TEST_NAME="+test, "TESL_TEST_KIND=test", "TESL_MIGRATION_TEST_SOCKET="+socket,
			"TESL_MIGRATION_TEST_ACTOR="+actor,
			"TESL_TEST_POSTGRES_SHARED_HOST="+config.Host,
			fmt.Sprintf("TESL_TEST_POSTGRES_SHARED_PORT=%d", config.Port),
			"TESL_TEST_POSTGRES_SHARED_USER="+config.User, "PGPASSWORD="+config.Password)
		done := make(chan outcome, 1)
		go func() {
			output, err := cmd.CombinedOutput()
			done <- outcome{output, err, test == "memory round trip"}
		}()
		return done
	}
	finish := func(done <-chan outcome) {
		t.Helper()
		select {
		case result := <-done:
			if result.err != nil || bytes.Contains(result.output, []byte("FAIL")) || (result.expectsTest && !bytes.Contains(result.output, []byte("--- PASS:"))) {
				t.Fatalf("fixture: %v\n%s\n%s", result.err, result.output, f.dump())
			}
		case <-f.ctx.Done():
			t.Fatalf("fixture timed out: %v\n%s", f.ctx.Err(), f.dump())
		}
	}
	for _, v := range []int{7, 8, 9} {
		finish(start(v, fmt.Sprintf("memory%d", v), "memory round trip", "", "", ""))
		finish(start(v, fmt.Sprintf("insert%d", v), "postgres trace", "insert", fmt.Sprint(v), "stored"))
	}
	for _, v := range []int{7, 8, 9} {
		for _, key := range []string{"7", "8", "9"} {
			finish(start(v, fmt.Sprintf("read%d-%s", v, key), "postgres trace", "read", key, "stored"))
		}
	}
	event := Event{"write-complete", "paused-v7", 1}
	if err = schedule.Pause(event); err != nil {
		t.Fatal(err)
	}
	old := start(7, "paused-v7", "postgres trace", "update", "9", "old-write")
	if err = schedule.Await(f.ctx, event); err != nil {
		t.Fatal(err)
	}
	newer := start(8, "competing-v8", "postgres trace", "update", "9", "new-write")
	// Observe the competing backend's row-lock wait. No sleep or scheduler-speed
	// assumption decides whether the test reached the intended interleaving.
	for {
		var waiting bool
		if err = f.conn.QueryRow(f.ctx, "select exists(select 1 from pg_stat_activity where datname=$1 and wait_event_type='Lock' and query like 'update%')", database).Scan(&waiting); err != nil {
			t.Fatalf("%v\n%s", err, f.dump())
		}
		if waiting {
			break
		}
		select {
		case result := <-newer:
			t.Fatalf("competing update did not wait: %v\n%s", result.err, result.output)
		default:
		}
	}
	if err = schedule.Release(event); err != nil {
		t.Fatal(err)
	}
	finish(old)
	finish(newer)
	var title, label, score string
	if err = conn.QueryRow(f.ctx, "select title,label,score::text from migration_fixture.notes where id='9'").Scan(&title, &label, &score); err != nil {
		t.Fatal(err)
	}
	if title != "new-write" || label != "label" || score != "9" {
		t.Fatalf("old writer destroyed newer columns: %q %q %q", title, label, score)
	}
	var shapes string
	if err = conn.QueryRow(f.ctx, "select string_agg(id || ':' || coalesce(label,'null') || ':' || coalesce(score::text,'null'), ',' order by id) from migration_fixture.notes").Scan(&shapes); err != nil {
		t.Fatal(err)
	}
	if shapes != "7:null:null,8:label:null,9:label:9" {
		t.Fatalf("raw row oracle: %s", shapes)
	}
	controller.Close()
	if failures := controller.Errors(); len(failures) != 0 {
		t.Fatal(failures)
	}
	// At least one event from every version proves the instrumented runtime was
	// included, rather than vacuously passing with the release no-op hook.
	for _, v := range []int{7, 8, 9} {
		found := false
		for _, arrival := range schedule.Trace() {
			found = found || strings.HasPrefix(arrival.Actor, fmt.Sprintf("read%d-", v))
		}
		if !found {
			t.Fatalf("V%d emitted no process boundaries", v)
		}
	}
}
