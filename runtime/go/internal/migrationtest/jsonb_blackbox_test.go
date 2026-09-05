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
)

// INV-JSONB-COMPATIBILITY, INV-JSONB-RETENTION; TR-READ, TR-WRITE.
// Existing codecs are the oracle here, not a production migration executor.
// Every version has byte-identical handlers, HTTP codecs and connection setup.
func TestCompiledJSONBCodecsRequireBothDirectionsAndRewriteEvidence(t *testing.T) {
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
	buildCtx, cancelBuild := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancelBuild()
	binaries := map[string]string{}
	var application []byte
	for _, version := range []string{"v7", "v8", "v8-bridge", "v9"} {
		source := filepath.Join(root, "runtime/go/internal/migrationtest/testdata/jsonb", version, "app.tesl")
		contents, err := os.ReadFile(source)
		if err != nil {
			t.Fatal(err)
		}
		if application == nil {
			application = contents
		} else if !bytes.Equal(application, contents) {
			t.Fatal("JSONB representation changes must leave the complete application source byte-identical")
		}
		dir := filepath.Join(t.TempDir(), "emitted")
		compile := exec.CommandContext(buildCtx, compiler, source, "--out", dir)
		compile.Env = append(os.Environ(), "TESL_REPO_ROOT="+root)
		if output, err := compile.CombinedOutput(); err != nil {
			t.Fatalf("compile JSONB %s: %v\n%s", version, err, output)
		}
		module, err := os.ReadFile(filepath.Join(dir, "go.mod"))
		if err != nil {
			t.Fatal(err)
		}
		fields := strings.Fields(string(module))
		if len(fields) < 2 || fields[0] != "module" {
			t.Fatal("emitted module declaration missing")
		}
		launcher := filepath.Join(dir, "cmd", "jsonb-fixture")
		if err = os.MkdirAll(launcher, 0700); err != nil {
			t.Fatal(err)
		}
		program := fmt.Sprintf(`package main
import ("encoding/json"; "io"; "os"; fixture %q; %q)
func main() {
  teslrt.WithDatabase(fixture.FixtureDbDatabase, func() {
    input, output := json.NewDecoder(os.Stdin), json.NewEncoder(os.Stdout)
    for {
      var request struct { Method, Path, Body string }
      if err := input.Decode(&request); err == io.EOF { return } else if err != nil { panic(err) }
      response := teslrt.ApiRequest(fixture.NotesServer, request.Method, request.Path, request.Body, nil, nil)
      if err := output.Encode(struct { Status string; Body any }{
        response.Status.String(), response.Body.JsonRaw(),
      }); err != nil { panic(err) }
    }
  })
}
`, fields[1]+"/internal/teslmodapp", fields[1]+"/internal/teslrt")
		if err = os.WriteFile(filepath.Join(launcher, "main.go"), []byte(program), 0600); err != nil {
			t.Fatal(err)
		}
		binary := filepath.Join(dir, "jsonb-fixture")
		build := exec.CommandContext(buildCtx, "go", "build", "-race", "-o", binary, "./cmd/jsonb-fixture")
		build.Dir = dir
		if output, err := build.CombinedOutput(); err != nil {
			t.Fatalf("build JSONB %s: %v\n%s", version, err, output)
		}
		binaries[version] = binary
	}
	f := newDatabaseFixture(t)
	database := f.schema + "_jsonb"
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
	type applicationProcess struct {
		input  *json.Encoder
		output *json.Decoder
		stderr string
	}
	processes := map[string]*applicationProcess{}
	// Keep each build connected throughout the trace, as during a rolling deploy.
	// Starting a race binary per request also adds the detector's one-second exit
	// delay to every operation, eventually exhausting the fixture's hard deadline.
	process := func(version string) *applicationProcess {
		t.Helper()
		if running := processes[version]; running != nil {
			return running
		}
		cmd := exec.CommandContext(f.ctx, binaries[version])
		cmd.Env = append(os.Environ(), "TESL_FIXTURE_DATABASE="+database,
			"TESL_TEST_POSTGRES_SHARED_HOST="+config.Host,
			fmt.Sprintf("TESL_TEST_POSTGRES_SHARED_PORT=%d", config.Port),
			"TESL_TEST_POSTGRES_SHARED_USER="+config.User, "PGPASSWORD="+config.Password)
		stdin, err := cmd.StdinPipe()
		if err != nil {
			t.Fatal(err)
		}
		stdout, err := cmd.StdoutPipe()
		if err != nil {
			_ = stdin.Close()
			t.Fatal(err)
		}
		stderrPath := filepath.Join(t.TempDir(), "stderr.log")
		stderr, err := os.Create(stderrPath)
		if err != nil {
			_ = stdin.Close()
			_ = stdout.Close()
			t.Fatal(err)
		}
		cmd.Stderr = stderr
		if err = cmd.Start(); err != nil {
			_ = stdin.Close()
			_ = stdout.Close()
			_ = stderr.Close()
			t.Fatal(err)
		}
		t.Cleanup(func() {
			_ = stdin.Close()
			if err := cmd.Wait(); err != nil {
				log, _ := os.ReadFile(stderrPath)
				t.Errorf("%s process failed (including race reports): %v\n%s", version, err, log)
			}
			_ = stderr.Close()
		})
		running := &applicationProcess{json.NewEncoder(stdin), json.NewDecoder(stdout), stderrPath}
		processes[version] = running
		return running
	}
	request := func(version, method, id, body, status, text string) {
		t.Helper()
		running := process(version)
		if err := running.input.Encode(struct{ Method, Path, Body string }{method, "/notes/" + id, body}); err != nil {
			t.Fatalf("%s %s %s: %v\n%s", version, method, id, err, f.dump())
		}
		var response struct {
			Status string
			Body   json.RawMessage
		}
		if err := running.output.Decode(&response); err != nil {
			log, _ := os.ReadFile(running.stderr)
			t.Fatalf("%s invalid process response: %v\n%s\n%s", version, err, log, f.dump())
		}
		if response.Status != status {
			log, _ := os.ReadFile(running.stderr)
			t.Fatalf("%s %s %s: status %s, want %s; %s\n%s", version, method, id, response.Status, status, response.Body, log)
		}
		if status == "200" {
			var note struct{ ID, Text string }
			if err := json.Unmarshal(response.Body, &note); err != nil || note.ID != id || note.Text != text {
				t.Fatalf("%s HTTP contract changed: %s (%v)", version, response.Body, err)
			}
		}
	}
	raw := func(id, key, text string) {
		t.Helper()
		var stored string
		if err := conn.QueryRow(f.ctx, "select details::text from migration_jsonb.notes where id=$1", id).Scan(&stored); err != nil {
			t.Fatal(err)
		}
		var fields map[string]string
		if err := json.Unmarshal([]byte(stored), &fields); err != nil || len(fields) != 1 || fields[key] != text {
			t.Fatalf("stored JSONB %s: %s, want only %s=%s (%v)", id, stored, key, text, err)
		}
	}
	request("v7", "POST", "untouched", `{"text":"kept"}`, "200", "kept")
	raw("untouched", "title", "kept")
	request("v7", "GET", "untouched", "", "200", "kept")
	request("v8", "GET", "untouched", "", "200", "kept")
	raw("untouched", "title", "kept") // Reading through the fallback did not rewrite it.
	request("v8", "POST", "new", `{"text":"new value"}`, "200", "new value")
	raw("new", "body", "new value")
	request("v8", "GET", "new", "", "200", "new value")
	request("v7", "GET", "new", "", "500", "") // New-readable does not imply old-readable.
	request("v9", "GET", "new", "", "200", "new value")
	request("v9", "GET", "untouched", "", "500", "") // Two later builds did not eliminate old JSON.
	raw("untouched", "title", "kept")
	request("v8", "PUT", "untouched", "", "200", "kept")
	raw("untouched", "body", "kept")
	request("v9", "GET", "untouched", "", "200", "kept")
	request("v7", "GET", "untouched", "", "500", "")
	// Every persisted occurrence matters, including nullable records and records
	// inside an ADT. Rewriting just the first column cannot justify pruning.
	request("v7", "POST", "partial", `{"text":"all occurrences"}`, "200", "all occurrences")
	if _, err = conn.Exec(f.ctx, `update migration_jsonb.notes
set details=jsonb_build_object('body', details->'title') where id='partial'`); err != nil {
		t.Fatal(err)
	}
	request("v9", "GET", "partial", "", "500", "")
	if _, err = conn.Exec(f.ctx, `update migration_jsonb.notes set backup=null where id='partial'`); err != nil {
		t.Fatal(err)
	}
	request("v8", "GET", "partial", "", "200", "all occurrences") // SQL NULL bypasses the record decoder.
	request("v9", "GET", "partial", "", "500", "")                // The ADT still contains old JSON.
	request("v8", "PUT", "partial", "", "200", "all occurrences")
	request("v9", "GET", "partial", "", "200", "all occurrences")
	var optionalNull bool
	var changed string
	if err = conn.QueryRow(f.ctx, `select backup is null, change #>> '{fields,details,body}'
from migration_jsonb.notes where id='partial'`).Scan(&optionalNull, &changed); err != nil || !optionalNull || changed != "all occurrences" {
		t.Fatalf("nullable/ADT rewrite lost data: %v %q (%v)", optionalNull, changed, err)
	}
	request("v8", "POST", "invalid-input", `{"text":""}`, "422", "")
	var invalidCount int
	if err = conn.QueryRow(f.ctx, `select count(*) from migration_jsonb.notes where id='invalid-input'`).Scan(&invalidCount); err != nil || invalidCount != 0 {
		t.Fatalf("rejected input was inserted: %d (%v)", invalidCount, err)
	}
	// A compatible bridge writes both keys. The legacy and current decoders can
	// both read it, while handlers and the HTTP contract remain identical.
	request("v7", "POST", "bridge-old", `{"text":"old value"}`, "200", "old value")
	request("v8-bridge", "GET", "bridge-old", "", "200", "old value")
	raw("bridge-old", "title", "old value")
	request("v8-bridge", "PUT", "bridge-old", "", "200", "old value")
	request("v7", "GET", "bridge-old", "", "200", "old value")
	request("v9", "GET", "bridge-old", "", "200", "old value")
	request("v8-bridge", "POST", "bridge-new", `{"text":"new value"}`, "200", "new value")
	request("v7", "GET", "bridge-new", "", "200", "new value")
	request("v9", "GET", "bridge-new", "", "200", "new value")
	var bridgeKeys bool
	if err = conn.QueryRow(f.ctx, `select details = '{"title":"new value","body":"new value"}'::jsonb
and backup = details and change #> '{fields,details}' = details
from migration_jsonb.notes where id='bridge-new'`).Scan(&bridgeKeys); err != nil || !bridgeKeys {
		t.Fatalf("bridge did not preserve both representations in every occurrence: %v (%v)", bridgeKeys, err)
	}
	// A compatible codec still cannot justify pruning while old writers remain:
	// this late V7 write introduces another legacy-only value after the rewrite.
	request("v7", "POST", "late-old", `{"text":"late value"}`, "200", "late value")
	request("v8-bridge", "GET", "late-old", "", "200", "late value")
	request("v9", "GET", "late-old", "", "500", "")
	request("v8-bridge", "PUT", "late-old", "", "200", "late value")
	request("v9", "GET", "late-old", "", "200", "late value")
	// A well-shaped JSON object can still violate the record's proof. Neither
	// the main column, nullable column nor ADT payload may fabricate that proof.
	for _, corrupt := range []struct{ name, details, backup, change string }{
		{"proof-main", `{"body":""}`, `null`, `{"tag":"Unchanged"}`},
		{"proof-optional", `{"body":"valid"}`, `{"body":""}`, `{"tag":"Unchanged"}`},
		{"json-null-optional", `{"body":"valid"}`, `null`, `{"tag":"Unchanged"}`},
		{"proof-adt", `{"body":"valid"}`, `{"body":"valid"}`, `{"tag":"Changed","fields":{"details":{"body":""}}}`},
		{"unknown-adt", `{"body":"valid"}`, `{"body":"valid"}`, `{"tag":"Future"}`},
	} {
		if _, err = conn.Exec(f.ctx, `insert into migration_jsonb.notes (id,details,backup,change)
values ($1,$2::jsonb,$3::jsonb,$4::jsonb)`, corrupt.name, corrupt.details, corrupt.backup, corrupt.change); err != nil {
			t.Fatal(err)
		}
		request("v8", "GET", corrupt.name, "", "500", "")
	}
	var columnType string
	if err = conn.QueryRow(f.ctx, `select format_type(a.atttypid,a.atttypmod)
from pg_attribute a where a.attrelid='migration_jsonb.notes'::regclass and a.attname='details'`).Scan(&columnType); err != nil {
		t.Fatal(err)
	}
	if columnType != "jsonb" {
		t.Fatalf("physical column changed: %s", columnType)
	}
}
