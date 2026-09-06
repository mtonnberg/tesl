package migrationtest

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"tesl.dev/runtime/go/internal/cli"
	"tesl.dev/runtime/go/teslrt"
)

const controlUpgradeFixturePath = "testdata/control-format2"
const controlUpgradeBridgeFixturePath = "testdata/control-format3-contract2"
const controlUpgradeEntry = "lesson84-worker-migrations.tesl"

// INV-FIXTURE-PROVENANCE, INV-INSTALL-CATALOG, INV-PRIVILEGE, INV-ADDITIVE-READ, INV-ADDITIVE-WRITE; TR-BOOT-EXPAND, TR-READ, TR-WRITE.
// The old executable is built from an immutable, authentic prior emission. No
// maximum-format constant, runtime source, compiled history or ABI is patched.
func TestCompiledControlFormatUpgrade(t *testing.T) {
	dsn := os.Getenv("TESL_MIGRATION_TEST_DSN")
	if dsn == "" {
		if os.Getenv("TESL_MIGRATION_TEST_REQUIRE_POSTGRES") == "1" {
			t.Fatal("TESL_MIGRATION_TEST_REQUIRE_POSTGRES=1 requires TESL_MIGRATION_TEST_DSN")
		}
		t.Skip("run scripts/run-migration-tests.sh")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Minute)
	t.Cleanup(cancel)
	oldBinary, bridgeBinary, currentBinary, manifest := buildControlUpgradeApps(t, ctx)
	admin, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = admin.Close(context.Background()) })
	database := "control_upgrade_" + strings.ReplaceAll(teslrt.UUIDv7(), "-", "")
	owner, worker, requestRole, setup := database+"_owner", database+"_worker", database+"_app", database+"_setup"
	t.Cleanup(func() {
		cleanup, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		if _, err := admin.Exec(cleanup, "drop database if exists "+pgx.Identifier{database}.Sanitize()+" with (force)"); err != nil {
			t.Errorf("control upgrade database cleanup: %v", err)
		}
		for _, role := range []string{worker, requestRole, setup, owner} {
			if _, err := admin.Exec(cleanup, "drop role if exists "+pgx.Identifier{role}.Sanitize()); err != nil {
				t.Errorf("control upgrade role cleanup: %v", err)
			}
		}
	})
	for _, sql := range []string{
		"create role " + owner + " nologin", "create role " + worker + " login",
		"create role " + requestRole + " login", "create role " + setup + " login",
		"grant " + owner + " to " + setup, "create database " + database,
		"grant create on database " + database + " to " + owner,
		"revoke temporary on database " + database + " from public",
		"grant temporary on database " + database + " to " + owner + "," + worker,
	} {
		if _, err := admin.Exec(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	config := admin.Config().Copy()
	config.Database = database
	observer, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = observer.Close(context.Background()) })
	for _, sql := range []string{"revoke create on schema public from public", "grant create on schema public to " + owner} {
		if _, err := observer.Exec(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	environment := append(os.Environ(), "NOTES_CONTROL_OWNER="+owner, "NOTES_DB_NAME="+database,
		"NOTES_REQUEST_ROLE="+requestRole, "NOTES_WORKER_ROLE="+worker,
		"NOTES_DB_PASSWORD="+config.Password, "NOTES_DB_HOST="+config.Host, "NOTES_DB_PORT="+strconv.Itoa(int(config.Port)),
		"PGDATABASE="+database, "PGHOST="+config.Host, "PGPORT="+strconv.Itoa(int(config.Port)), "PGPASSWORD="+config.Password,
		"TESL_PG_POOL_LEASE_TIMEOUT_MS=60000")
	login := func(role string) []string {
		return append(append([]string(nil), environment...), "NOTES_DB_USER="+role, "PGUSER="+role)
	}
	installArgs := []string{"--schema", "install", "--worker", worker, "--request", requestRole, "--json"}
	installer := func(binary string) []byte {
		t.Helper()
		commandCtx, stop := context.WithTimeout(ctx, 15*time.Second)
		defer stop()
		command := exec.CommandContext(commandCtx, binary, installArgs...)
		command.Env = login(setup)
		data, err := command.CombinedOutput()
		if err != nil {
			t.Fatalf("compiled installer: %v\n%s", err, data)
		}
		return data
	}
	var installed struct {
		Kind              string `json:"kind"`
		DatabaseUUID      string `json:"databaseUuid"`
		InitialVersion    int    `json:"initialVersion"`
		CurrentVersion    int    `json:"currentVersion"`
		InstallingVersion int    `json:"installingVersion"`
	}
	data := installer(oldBinary)
	if err := json.Unmarshal(data, &installed); err != nil || installed.Kind != "schema-install" || installed.DatabaseUUID == "" ||
		installed.InitialVersion != 1 || installed.CurrentVersion != 0 || installed.InstallingVersion != 1 {
		t.Fatalf("old installer did not produce the original unexpanded installation: %s (%v)", data, err)
	}
	format := func(want int) {
		t.Helper()
		var got int
		if err := observer.QueryRow(ctx, "select format_version from worker_notes.tesl_schema_meta where id=1").Scan(&got); err != nil || got != want {
			t.Fatalf("control format: got %d, want %d (%v)", got, want, err)
		}
	}
	format(2)
	installationUUID := installed.DatabaseUUID
	if _, err := observer.Exec(ctx, "revoke "+owner+" from "+setup); err != nil {
		t.Fatal(err)
	}
	var isolated bool
	if err := observer.QueryRow(ctx, `select not pg_catalog.has_database_privilege($1,$2,'TEMPORARY') and
 not pg_catalog.has_schema_privilege($1,'public','CREATE') and not pg_catalog.has_schema_privilege($1,'worker_notes','CREATE')`,
		requestRole, database).Scan(&isolated); err != nil || !isolated {
		t.Fatalf("request login has unintended DDL authority: %v (%v)", isolated, err)
	}
	client := &http.Client{Timeout: time.Second}
	startRequest := func(binary, label string) *workerLessonProcess {
		t.Helper()
		process := startWorkerLessonProcess(t, ctx, binary, append(login(requestRole), "PGAPPNAME=tesl-app:"+label), label)
		workerLessonWait(t, ctx, process, "HTTP readiness", func() bool {
			response, err := client.Get(process.base + "/notes/readiness")
			if err != nil {
				return false
			}
			_ = response.Body.Close()
			return response.StatusCode == http.StatusNotFound
		})
		return process
	}
	startWorker := func(binary, label string) *workerLessonProcess {
		t.Helper()
		process := startWorkerLessonProcess(t, ctx, binary, append(login(worker), "PGAPPNAME=tesl-exec:"+label), label, "--schema", "worker", "--json")
		workerLessonWait(t, ctx, process, "schema-worker-ready", func() bool {
			var ready struct {
				Kind           string `json:"kind"`
				Database       string `json:"database"`
				DatabaseUUID   string `json:"databaseUuid"`
				BinaryVersion  int    `json:"binaryVersion"`
				CurrentVersion int    `json:"currentVersion"`
			}
			for _, line := range bytes.Split(process.output(), []byte("\n")) {
				if json.Unmarshal(line, &ready) == nil && ready.Kind == "schema-worker-ready" {
					if ready.Database != "Lesson84WorkerMigrations.NoteDatabase" || ready.DatabaseUUID != installed.DatabaseUUID ||
						ready.BinaryVersion != 1 || ready.CurrentVersion != 1 {
						t.Fatalf("worker published the wrong readiness: %s", line)
					}
					return true
				}
			}
			return false
		})
		process.assertNoHTTP(t)
		return process
	}
	oldWorker := startWorker(oldBinary, "format2-worker")
	oldRequest := startRequest(oldBinary, "format2-request")
	workerLessonRequest(t, ctx, client, oldRequest.base, "POST", "retained", `{"title":"  Original note  "}`, 200, "Original note")
	bridgeRequest := startRequest(bridgeBinary, "bridge-on-format2")
	workerLessonRequest(t, ctx, client, bridgeRequest.base, "GET", "retained", "", 200, "Original note")
	workerLessonRequest(t, ctx, client, bridgeRequest.base, "POST", "bridge", `{"title":"Bridge writer"}`, 200, "Bridge writer")
	workerLessonRequest(t, ctx, client, oldRequest.base, "GET", "bridge", "", 200, "Bridge writer")
	workerLessonRequest(t, ctx, client, oldRequest.base, "POST", "old-peer", `{"title":"Old writer"}`, 200, "Old writer")
	workerLessonRequest(t, ctx, client, bridgeRequest.base, "GET", "old-peer", "", 200, "Old writer")
	format(2) // Starting a bridge request must never upgrade the control schema.
	oldRequest.stop(t)
	bridgeRequest.stop(t)
	oldWorker.stop(t)
	var provenance bool
	if err := observer.QueryRow(ctx, `select count(*)=1 and bool_and(source_abi=$1 and stored_value_compatibility=$2 and epoch_preserving)
 from worker_notes.tesl_schema_expansions`, manifest.CompilerABI, manifest.StoredValueCompatibility).Scan(&provenance); err != nil || !provenance {
		t.Fatalf("original binary did not persist its actual compiler identity: %v (%v)", provenance, err)
	}
	before := controlUpgradeSnapshot(t, ctx, observer, false)
	if _, err := observer.Exec(ctx, "grant "+owner+" to "+setup); err != nil {
		t.Fatal(err)
	}
	// Contract 3 cannot interpret the original contract-2 rows. Request,
	// status and installer recognize this catalog and reach semantic refusal;
	// the current worker requires the format upgrade before inspecting history.
	assertCurrentControlUpgradeRefusals(t, ctx, observer, currentBinary, login, worker, requestRole, setup,
		"format2", "persisted stored-value compatibility differs at V1", false, installArgs)
	// The acknowledgement is intentionally lost only after the actual installer
	// has committed. A closed pipe exercises the ordinary executable's output
	// path; no test hook or instrumented runtime is involved.
	readPipe, writePipe, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := readPipe.Close(); err != nil {
		_ = writePipe.Close()
		t.Fatal(err)
	}
	failedCtx, stopFailed := context.WithTimeout(ctx, 15*time.Second)
	failed := exec.CommandContext(failedCtx, bridgeBinary, installArgs...)
	failed.Env, failed.Stdout = login(setup), writePipe
	var failedStderr bytes.Buffer
	failed.Stderr = &failedStderr
	failedErr := failed.Run()
	_ = writePipe.Close()
	failedTimeout := failedCtx.Err()
	stopFailed()
	var outputExit *exec.ExitError
	outputFailure := false
	if errors.As(failedErr, &outputExit) {
		status, signalled := outputExit.Sys().(syscall.WaitStatus)
		outputFailure = strings.Contains(failedStderr.String(), "broken pipe") || (signalled && status.Signal() == syscall.SIGPIPE)
	}
	if !outputFailure || failedTimeout != nil {
		t.Fatalf("installer did not fail its acknowledgement promptly: %v (%v)\n%s", failedErr, failedTimeout, &failedStderr)
	}
	format(3)
	if after := controlUpgradeSnapshot(t, ctx, observer, false); before != after {
		t.Fatalf("control upgrade changed old state beyond format_version:\nbefore %s\nafter %s", before, after)
	}
	upgraded := controlUpgradeSnapshot(t, ctx, observer, true)
	firstRetry, secondRetry := installer(bridgeBinary), installer(bridgeBinary)
	if !bytes.Equal(firstRetry, secondRetry) {
		t.Fatalf("repeated installation changed its acknowledgement:\n%s\n%s", firstRetry, secondRetry)
	}
	if err := json.Unmarshal(firstRetry, &installed); err != nil || installed.Kind != "schema-install" || installed.DatabaseUUID != installationUUID || installed.InitialVersion != 1 || installed.CurrentVersion != 1 || installed.InstallingVersion != 0 {
		t.Fatalf("retry did not acknowledge the completed installation: %s (%v)", firstRetry, err)
	}
	if after := controlUpgradeSnapshot(t, ctx, observer, true); upgraded != after {
		t.Fatalf("installer retry changed committed state:\nbefore %s\nafter %s", upgraded, after)
	}
	if _, err := observer.Exec(ctx, "revoke "+owner+" from "+setup); err != nil {
		t.Fatal(err)
	}
	currentWorker := startWorker(bridgeBinary, "format3-worker")
	currentRequest := startRequest(bridgeBinary, "format3-request")
	for id, title := range map[string]string{"retained": "Original note", "bridge": "Bridge writer", "old-peer": "Old writer"} {
		workerLessonRequest(t, ctx, client, currentRequest.base, "GET", id, "", 200, title)
	}
	workerLessonRequest(t, ctx, client, currentRequest.base, "POST", "after-upgrade", `{"title":"Upgraded writer"}`, 200, "Upgraded writer")
	currentRequest.stop(t)
	currentWorker.stop(t)
	// A running current worker may publish legitimate heartbeats; drain it
	// before proving that the actual old binaries leave every control row alone.
	before = controlUpgradeSnapshot(t, ctx, observer, true)
	for _, refusal := range []struct {
		label, role string
		args        []string
	}{
		{"old-request-on-format3", requestRole, nil},
		{"old-worker-on-format3", worker, []string{"--schema", "worker", "--json"}},
	} {
		assertOldControlUpgradeRefused(t, ctx, oldBinary, login(refusal.role), refusal.label, refusal.args...)
		if after := controlUpgradeSnapshot(t, ctx, observer, true); before != after {
			t.Fatalf("old %s mutated upgraded state:\nbefore %s\nafter %s", refusal.label, before, after)
		}
	}
	// This immutable historical format-3 prototype predates the sixth index
	// recovery API. Current software must refuse that exact missing function
	// before interpreting rows. This is catalog evidence, not semantic refusal.
	if _, err := observer.Exec(ctx, "grant "+owner+" to "+setup); err != nil {
		t.Fatal(err)
	}
	assertCurrentControlUpgradeRefusals(t, ctx, observer, currentBinary, login, worker, requestRole, setup,
		"historical-format3", "protected migration function worker_notes.tesl_lock_expired_index_holder is missing or unreadable", true, installArgs)
	if _, err := observer.Exec(ctx, "revoke "+owner+" from "+setup); err != nil {
		t.Fatal(err)
	}
	restarted := startRequest(bridgeBinary, "format3-request-restart")
	workerLessonRequest(t, ctx, client, restarted.base, "GET", "after-upgrade", "", 200, "Upgraded writer")
	format(3)
}

func controlUpgradeSnapshot(t *testing.T, ctx context.Context, conn *pgx.Conn, includeFormat3 bool) string {
	t.Helper()
	// Include all persisted provenance, lifecycle and fence fields, as well as
	// entity contents. Only format_version is excluded for the 2 -> 3 comparison.
	extra := ""
	tableFilter := " and table_name not in ('tesl_schema_index','tesl_schema_leases')"
	indexFilter := " and tablename not in ('tesl_schema_index','tesl_schema_leases')"
	functionFilter := " and proname not in ('tesl_register_index','tesl_claim_index','tesl_renew_index','tesl_release_index','tesl_record_index_state','tesl_lock_expired_index_holder')"
	if includeFormat3 {
		tableFilter, indexFilter, functionFilter = "", "", ""
		extra = `, 'format',(select format_version from worker_notes.tesl_schema_meta),
 'indexes',(select jsonb_agg(to_jsonb(i) order by version,table_name,index_name) from worker_notes.tesl_schema_index i),
 'leases',(select jsonb_agg(to_jsonb(l) order by name) from worker_notes.tesl_schema_leases l)`
	}
	var result string
	if err := conn.QueryRow(ctx, `select jsonb_build_object(
 'meta',(select jsonb_agg(to_jsonb(m)-'format_version' order by id) from worker_notes.tesl_schema_meta m),
 'state',(select jsonb_agg(to_jsonb(s) order by id) from worker_notes.tesl_schema_state s),
 'versions',(select jsonb_agg(to_jsonb(v) order by version,step,seq) from worker_notes.tesl_schema_versions v),
 'intents',(select jsonb_agg(to_jsonb(e) order by version) from worker_notes.tesl_schema_expansions e),
 'objects',(select jsonb_agg(to_jsonb(o) order by version,ordinal) from worker_notes.tesl_schema_expansion_objects o),
 'instances',(select jsonb_agg(to_jsonb(i) order by instance) from worker_notes.tesl_schema_instances i),
 'rows',(select jsonb_agg(to_jsonb(n) order by id) from worker_notes.lesson_worker_notes n),
 'columns',(select jsonb_agg(to_jsonb(c) order by table_name,ordinal_position) from information_schema.columns c where table_schema='worker_notes'`+tableFilter+`),
 'catalog_indexes',(select jsonb_agg(to_jsonb(i) order by indexname) from pg_indexes i where schemaname='worker_notes'`+indexFilter+`),
 'functions',(select jsonb_agg(jsonb_build_array(proname,pg_get_function_identity_arguments(p.oid),pg_get_functiondef(p.oid),proowner,proacl)
 order by proname,pg_get_function_identity_arguments(p.oid)) from pg_proc p join pg_namespace n on p.pronamespace=n.oid
 where n.nspname='worker_notes'`+functionFilter+`)`+extra+")::text").Scan(&result); err != nil {
		t.Fatal(err)
	}
	return result
}

func assertOldControlUpgradeRefused(t *testing.T, ctx context.Context, binary string, environment []string, label string, args ...string) {
	t.Helper()
	assertControlUpgradeRefused(t, ctx, binary, environment, label, func(output []byte) bool {
		unsupported := bytes.Contains(output, []byte("unsupported migration control format 3"))
		catalogChanged := bytes.Contains(output, []byte("protected migration")) && bytes.Contains(output, []byte("differs from"))
		return unsupported || catalogChanged
	}, args...)
}

func assertCurrentControlUpgradeRefusals(t *testing.T, ctx context.Context, observer *pgx.Conn, binary string,
	login func(string) []string, worker, requestRole, setup, phase, expected string, includeFormat3 bool, installArgs []string) {
	t.Helper()
	before := controlUpgradeRefusalSnapshot(t, ctx, observer, includeFormat3)
	workerExpected := expected
	if !includeFormat3 {
		workerExpected = "migration control format 2 requires the installer upgrade before worker expansion"
	}
	for _, command := range []struct {
		label, role, expected string
		args                  []string
	}{
		{"request", requestRole, expected, nil},
		{"worker", worker, workerExpected, []string{"--schema", "worker", "--json"}},
		{"status", requestRole, expected, []string{"--schema", "status", "--json"}},
		{"installer", setup, expected, installArgs},
	} {
		assertControlUpgradeRefused(t, ctx, binary, login(command.role), "current-"+command.label+"-"+phase,
			func(output []byte) bool { return bytes.Contains(output, []byte(command.expected)) }, command.args...)
		if after := controlUpgradeRefusalSnapshot(t, ctx, observer, includeFormat3); before != after {
			t.Fatalf("current %s refusal changed retained %s state:\nbefore %s\nafter %s", command.label, phase, before, after)
		}
	}
}

// The upgrade comparison deliberately omits format and newly added objects;
// refusals must preserve both, even when the database still has format 2.
func controlUpgradeRefusalSnapshot(t *testing.T, ctx context.Context, observer *pgx.Conn, includeFormat3 bool) string {
	t.Helper()
	state := controlUpgradeSnapshot(t, ctx, observer, includeFormat3)
	var snapshot string
	if err := observer.QueryRow(ctx, `select jsonb_build_object(
 'state',$1::jsonb,'format',(select format_version from worker_notes.tesl_schema_meta where id=1),
 'relations',(select jsonb_agg(jsonb_build_array(c.relname,c.relkind,c.relowner,c.relacl,c.reloptions) order by c.relname)
 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='worker_notes'),
 'functions',(select jsonb_agg(jsonb_build_array(p.proname,pg_catalog.pg_get_function_identity_arguments(p.oid),
 pg_catalog.pg_get_functiondef(p.oid),p.proowner,p.proacl) order by p.proname,pg_catalog.pg_get_function_identity_arguments(p.oid))
 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='worker_notes'))::text`, state).Scan(&snapshot); err != nil {
		t.Fatal(err)
	}
	return snapshot
}

func assertControlUpgradeRefused(t *testing.T, ctx context.Context, binary string, environment []string, label string,
	matches func([]byte) bool, args ...string) {
	t.Helper()
	refusalCtx, stop := context.WithTimeout(ctx, 10*time.Second)
	defer stop()
	process := startWorkerLessonProcess(t, refusalCtx, binary, environment, label, args...)
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-process.done:
			process.once.Do(func() { _ = process.log.Close() })
			output := process.output()
			if process.waitErr == nil || refusalCtx.Err() != nil || bytes.Contains(output, []byte("schema-worker-ready")) ||
				!matches(output) {
				t.Fatalf("compiled process did not report its expected refusal promptly: %v\n%s", process.waitErr, output)
			}
			return
		case <-refusalCtx.Done():
			t.Fatalf("compiled process did not refuse promptly: %v\n%s", refusalCtx.Err(), process.output())
		case <-ticker.C:
			connection, err := net.DialTimeout("tcp", process.address, 100*time.Millisecond)
			if err == nil {
				_ = connection.Close()
				t.Fatalf("refused compiled process served HTTP\n%s", process.output())
			}
		}
	}
}

func buildControlUpgradeApps(t *testing.T, ctx context.Context) (string, string, string, controlUpgradeManifest) {
	t.Helper()
	manifest, files, sources, err := readControlUpgradeFixture(controlUpgradeFixturePath, 2, 84)
	if err != nil {
		t.Fatal(err)
	}
	bridgeManifest, bridgeFiles, bridgeSources, err := readControlUpgradeFixture(controlUpgradeBridgeFixturePath, 3, 88)
	if err != nil {
		t.Fatal(err)
	}
	if manifest.CompilerABI == bridgeManifest.CompilerABI || manifest.StoredValueCompatibility != bridgeManifest.StoredValueCompatibility || len(sources) != len(bridgeSources) {
		t.Fatal("historical bridge must have a distinct actual ABI and the original stored-value contract and sources")
	}
	for name, source := range sources {
		if !bytes.Equal(source, bridgeSources[name]) {
			t.Fatalf("historical bridge changed original app/schema source %s", name)
		}
	}
	root := os.Getenv("TESL_REPO_ROOT")
	if root == "" {
		root, err = filepath.Abs("../../../..")
		if err != nil {
			t.Fatal(err)
		}
	}
	buildRoot := t.TempDir()
	oldGo, bridgeGo, currentGo, project := filepath.Join(buildRoot, "old-go"), filepath.Join(buildRoot, "bridge-go"), filepath.Join(buildRoot, "current-go"), filepath.Join(buildRoot, "source")
	for directory, contents := range map[string]map[string][]byte{oldGo: files, bridgeGo: bridgeFiles, project: sources} {
		for name, data := range contents {
			writeControlUpgradeFile(t, filepath.Join(directory, name), data)
		}
	}
	writeControlUpgradeFile(t, filepath.Join(project, "tesl.toml"), nil)
	compiler := filepath.Join(root, "compiler/_build/default/bin/main.exe")
	for name := range sources {
		command := exec.CommandContext(ctx, compiler, "agent-context", filepath.Join(project, name))
		command.Dir = project
		if data, err := command.CombinedOutput(); err != nil {
			t.Fatalf("frozen source diagnostics: %v\n%s", err, data)
		}
	}
	var output bytes.Buffer
	app := cli.New()
	app.Directory, app.Stdout, app.Stderr = project, &output, &output
	app.Resolver.Getenv = func(key string) string {
		if key == "TESL_COMPILER" {
			return compiler
		}
		return os.Getenv(key)
	}
	if err := app.Run(ctx, []string{"compile", controlUpgradeEntry, "--out", currentGo}); err != nil {
		t.Fatalf("current application emission: %v\n%s", err, &output)
	}
	for name, want := range sources {
		got, err := os.ReadFile(filepath.Join(project, name))
		if err != nil || !bytes.Equal(want, got) {
			t.Fatalf("current compilation changed frozen application source %s: %v", name, err)
		}
	}
	currentHistory, err := os.ReadFile(filepath.Join(currentGo, "migration-history.json"))
	if err != nil {
		t.Fatal(err)
	}
	var current struct {
		CompilerABI              string `json:"compilerAbi"`
		StoredValueCompatibility string `json:"storedValueCompatibility"`
	}
	if err := json.Unmarshal(currentHistory, &current); err != nil || current.CompilerABI == "" || current.CompilerABI == manifest.CompilerABI || current.CompilerABI == bridgeManifest.CompilerABI ||
		current.StoredValueCompatibility == "" || current.StoredValueCompatibility == manifest.StoredValueCompatibility {
		t.Fatalf("current compiler must record its actual different ABI and changed stored-value contract: %s (%v)", currentHistory, err)
	}
	binaries := make([]string, 0, 3)
	for index, generated := range []string{oldGo, bridgeGo, currentGo} {
		command := exec.CommandContext(ctx, "go", "test", "-race", "-count=1", "./internal/teslmodlesson84workermigrations")
		command.Dir = generated
		if data, err := command.CombinedOutput(); err != nil {
			t.Fatalf("historical/current application %d unit/API tests: %v\n%s", index, err, data)
		}
		binary := filepath.Join(t.TempDir(), fmt.Sprintf("control-app-%d", index))
		command = exec.CommandContext(ctx, "go", "build", "-race", "-o", binary, "./cmd/app")
		command.Dir = generated
		if data, err := command.CombinedOutput(); err != nil {
			t.Fatalf("historical/current application %d ordinary build: %v\n%s", index, err, data)
		}
		binaries = append(binaries, binary)
	}
	// Recheck both historical emissions after building. Neither compatibility
	// baseline may be patched, relabeled or refreshed by the test harness.
	for generated, inventory := range map[string]map[string][]byte{oldGo: files, bridgeGo: bridgeFiles} {
		seen := 0
		if err := filepath.WalkDir(generated, func(name string, entry fs.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			if entry.IsDir() {
				return nil
			}
			relative, err := filepath.Rel(generated, name)
			if err != nil {
				return err
			}
			want, exists := inventory[filepath.ToSlash(relative)]
			got, err := os.ReadFile(name)
			if !entry.Type().IsRegular() || !exists || err != nil || !bytes.Equal(want, got) {
				return fmt.Errorf("building a historical application changed its emitted inventory at %s: %v", relative, err)
			}
			seen++
			return nil
		}); err != nil {
			t.Fatal(err)
		}
		if seen != len(inventory) {
			t.Fatal("building a historical application removed a recorded emitted file")
		}
	}
	if err := os.RemoveAll(buildRoot); err != nil {
		t.Fatal(err)
	}
	return binaries[0], binaries[1], binaries[2], manifest
}

type controlUpgradeManifest struct {
	Version                  int               `json:"version"`
	FormatVersion            int               `json:"formatVersion"`
	CompilerABI              string            `json:"compilerAbi"`
	StoredValueCompatibility string            `json:"storedValueCompatibility"`
	ArchiveSHA256            string            `json:"archiveSha256"`
	SourceSHA256             map[string]string `json:"sourceSha256"`
	Files                    map[string]string `json:"files"`
}

func controlUpgradeHash(data []byte) string {
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:])
}

// Validate all bytes and names before creating a build tree. This loader is
// intentionally private to two closed historical fixtures, not a release importer.
func readControlUpgradeFixture(directory string, expectedFormat, expectedFiles int) (controlUpgradeManifest, map[string][]byte, map[string][]byte, error) {
	var manifest controlUpgradeManifest
	if expectedFormat != 2 && expectedFormat != 3 || expectedFormat == 2 && expectedFiles != 84 || expectedFormat == 3 && expectedFiles != 88 {
		return manifest, nil, nil, errors.New("unsupported historical fixture expectation")
	}
	data, err := readControlUpgradeBoundedFile(filepath.Join(directory, "manifest.json"), 1<<20)
	if err != nil {
		return manifest, nil, nil, err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&manifest); err != nil {
		return manifest, nil, nil, fmt.Errorf("fixture manifest: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return manifest, nil, nil, errors.New("fixture manifest has trailing JSON")
	}
	if manifest.Version != 1 || manifest.FormatVersion != expectedFormat || len(manifest.Files) != expectedFiles || len(manifest.SourceSHA256) != 3 ||
		!strings.HasPrefix(manifest.CompilerABI, "tesl-source-abi-v1:") || !strings.HasPrefix(manifest.StoredValueCompatibility, "tesl-stored-value-v1:") {
		return manifest, nil, nil, errors.New("fixture manifest has an unsupported identity or incomplete inventory")
	}
	archive, err := readControlUpgradeBoundedFile(filepath.Join(directory, "worker-app.tar.gz"), 8<<20)
	if err != nil {
		return manifest, nil, nil, err
	}
	if len(archive) > 8<<20 || controlUpgradeHash(archive) != manifest.ArchiveSHA256 {
		return manifest, nil, nil, errors.New("fixture archive checksum mismatch or size limit exceeded")
	}
	compressed, err := gzip.NewReader(bytes.NewReader(archive))
	if err != nil {
		return manifest, nil, nil, fmt.Errorf("fixture archive gzip: %w", err)
	}
	defer func() { _ = compressed.Close() }()
	expanded := &io.LimitedReader{R: compressed, N: 16<<20 + 1}
	reader := tar.NewReader(expanded)
	files := make(map[string][]byte)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return manifest, nil, nil, fmt.Errorf("fixture archive tar: %w", err)
		}
		if !fs.ValidPath(header.Name) || path.Clean(header.Name) != header.Name || strings.Contains(header.Name, "\\") || header.Typeflag != tar.TypeReg {
			return manifest, nil, nil, fmt.Errorf("fixture archive has an unsafe or non-regular entry %q", header.Name)
		}
		if _, exists := files[header.Name]; exists {
			return manifest, nil, nil, fmt.Errorf("fixture archive has duplicate entry %q", header.Name)
		}
		expected, exists := manifest.Files[header.Name]
		if !exists {
			return manifest, nil, nil, fmt.Errorf("fixture archive has unlisted entry %q", header.Name)
		}
		if header.Size < 0 || header.Size > 2<<20 {
			return manifest, nil, nil, fmt.Errorf("fixture archive entry is too large: %q", header.Name)
		}
		contents, err := io.ReadAll(reader)
		if err != nil || controlUpgradeHash(contents) != expected {
			return manifest, nil, nil, fmt.Errorf("fixture archive member checksum mismatch: %q (%v)", header.Name, err)
		}
		files[header.Name] = contents
	}
	// tar EOF can precede gzip's checksum trailer and conventional zero padding.
	// Read through that trailer within the same total expansion bound.
	padding, err := io.ReadAll(expanded)
	if err != nil {
		return manifest, nil, nil, fmt.Errorf("fixture archive gzip trailer: %w", err)
	}
	if expanded.N == 0 || len(bytes.Trim(padding, "\x00")) != 0 {
		return manifest, nil, nil, errors.New("fixture archive expansion limit or trailing data")
	}
	if len(files) != len(manifest.Files) {
		return manifest, nil, nil, errors.New("fixture archive is missing listed members")
	}
	var history struct {
		CompilerABI              string `json:"compilerAbi"`
		StoredValueCompatibility string `json:"storedValueCompatibility"`
	}
	if err := json.Unmarshal(files["migration-history.json"], &history); err != nil || history.CompilerABI != manifest.CompilerABI ||
		history.StoredValueCompatibility != manifest.StoredValueCompatibility {
		return manifest, nil, nil, errors.New("fixture manifest and emitted compiler provenance differ")
	}
	sources := make(map[string][]byte)
	for name, expected := range manifest.SourceSHA256 {
		relative, found := strings.CutPrefix(name, "example/learn/")
		if !found || !fs.ValidPath(relative) || strings.Contains(relative, "\\") {
			return manifest, nil, nil, fmt.Errorf("fixture manifest has an unsafe source path %q", name)
		}
		contents, err := readControlUpgradeBoundedFile(filepath.Join(directory, "source", relative), 1<<20)
		if err != nil || controlUpgradeHash(contents) != expected {
			return manifest, nil, nil, fmt.Errorf("fixture source checksum mismatch: %q (%v)", name, err)
		}
		sources[relative] = contents
	}
	return manifest, files, sources, nil
}

func readControlUpgradeBoundedFile(name string, limit int64) ([]byte, error) {
	file, err := os.Open(name)
	if err != nil {
		return nil, err
	}
	defer func() { _ = file.Close() }()
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("fixture file exceeds size limit: %s", name)
	}
	return data, nil
}

func writeControlUpgradeFile(t *testing.T, name string, contents []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(name), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(name, contents, 0600); err != nil {
		t.Fatal(err)
	}
}

// INV-FIXTURE-PROVENANCE.
// The compatibility test must fail before building or connecting when its real
// historical evidence is incomplete or changed. These use no database or compiler.
func TestControlUpgradeFixtureRefusesTampering(t *testing.T) {
	for _, fixture := range []struct {
		name, directory string
		format, files   int
	}{
		{"original-format2", controlUpgradeFixturePath, 2, 84},
		{"historical-format3", controlUpgradeBridgeFixturePath, 3, 88},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			testControlUpgradeFixtureTampering(t, fixture.directory, fixture.format, fixture.files)
		})
	}
}

func testControlUpgradeFixtureTampering(t *testing.T, fixtureDirectory string, expectedFormat, expectedFiles int) {
	t.Helper()
	baseline, files, sources, err := readControlUpgradeFixture(fixtureDirectory, expectedFormat, expectedFiles)
	if err != nil {
		t.Fatal(err)
	}
	archive, err := os.ReadFile(filepath.Join(fixtureDirectory, "worker-app.tar.gz"))
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct{ name, reason string }{
		{"archive-checksum", "archive checksum"},
		{"member-checksum", "member checksum"},
		{"missing-member", "missing listed members"},
		{"extra-member", "unlisted entry"},
		{"duplicate-member", "duplicate entry"},
		{"parent-path", "unsafe or non-regular"},
		{"symlink", "unsafe or non-regular"},
		{"invalid-gzip", "archive gzip"},
		{"gzip-checksum", "checksum"},
		{"truncated-tar", "archive tar"},
		{"source-checksum", "source checksum"},
		{"compiler-provenance", "compiler provenance"},
		{"stored-value-provenance", "compiler provenance"},
		{"format-identity", "unsupported identity"},
		{"inventory-count", "incomplete inventory"},
		{"unknown-manifest-field", "fixture manifest"},
		{"trailing-manifest-json", "trailing JSON"},
	} {
		t.Run(test.name, func(t *testing.T) {
			directory := t.TempDir()
			for name, data := range sources {
				writeControlUpgradeFile(t, filepath.Join(directory, "source", name), data)
			}
			manifest := baseline
			candidate := bytes.Clone(archive)
			switch test.name {
			case "archive-checksum":
				candidate[len(candidate)-1] ^= 1
			case "gzip-checksum":
				candidate[len(candidate)-8] ^= 1
				manifest.ArchiveSHA256 = controlUpgradeHash(candidate)
			case "member-checksum", "missing-member", "extra-member", "duplicate-member", "parent-path", "symlink":
				candidate = controlUpgradeModifiedArchive(t, files, test.name)
				manifest.ArchiveSHA256 = controlUpgradeHash(candidate)
			case "invalid-gzip":
				candidate = []byte("not a gzip archive")
				manifest.ArchiveSHA256 = controlUpgradeHash(candidate)
			case "truncated-tar":
				var compressed bytes.Buffer
				writer := gzip.NewWriter(&compressed)
				if _, err := writer.Write([]byte("incomplete tar header")); err != nil {
					t.Fatal(err)
				}
				if err := writer.Close(); err != nil {
					t.Fatal(err)
				}
				candidate = compressed.Bytes()
				manifest.ArchiveSHA256 = controlUpgradeHash(candidate)
			case "source-checksum":
				writeControlUpgradeFile(t, filepath.Join(directory, "source", controlUpgradeEntry), []byte("module Changed\n"))
			case "compiler-provenance":
				manifest.CompilerABI = "tesl-source-abi-v1:" + strings.Repeat("0", 64)
			case "stored-value-provenance":
				manifest.StoredValueCompatibility = "tesl-stored-value-v1:" + strings.Repeat("0", 64)
			case "format-identity":
				manifest.FormatVersion = 5 - expectedFormat
			case "inventory-count":
				manifest.Files = make(map[string]string)
				for name, digest := range baseline.Files {
					if name != "cmd/app/main.go" {
						manifest.Files[name] = digest
					}
				}
			case "unknown-manifest-field", "trailing-manifest-json":
				// Applied below, after encoding the otherwise valid manifest.
			default:
				t.Fatalf("unknown fixture mutation %s", test.name)
			}
			manifestJSON, err := json.Marshal(manifest)
			if err != nil {
				t.Fatal(err)
			}
			if test.name == "unknown-manifest-field" {
				manifestJSON = append([]byte(`{"unreviewed":true,`), manifestJSON[1:]...)
			}
			if test.name == "trailing-manifest-json" {
				manifestJSON = append(manifestJSON, []byte(` {"version":1}`)...)
			}
			writeControlUpgradeFile(t, filepath.Join(directory, "manifest.json"), manifestJSON)
			writeControlUpgradeFile(t, filepath.Join(directory, "worker-app.tar.gz"), candidate)
			_, gotFiles, gotSources, err := readControlUpgradeFixture(directory, expectedFormat, expectedFiles)
			if err == nil || !strings.Contains(err.Error(), test.reason) || gotFiles != nil || gotSources != nil {
				t.Fatalf("fixture mutation %s was not refused before extraction for %q: %v", test.name, test.reason, err)
			}
			if _, err := os.Stat(filepath.Join(directory, "cmd/app/main.go")); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("refused fixture created a build tree: %v", err)
			}
		})
	}
}

func controlUpgradeModifiedArchive(t *testing.T, files map[string][]byte, mutation string) []byte {
	t.Helper()
	var result bytes.Buffer
	compressed := gzip.NewWriter(&result)
	archive := tar.NewWriter(compressed)
	write := func(name string, data []byte, kind byte) {
		t.Helper()
		header := &tar.Header{Name: name, Typeflag: kind, Mode: 0600, Size: int64(len(data))}
		if kind == tar.TypeSymlink {
			header.Linkname = "outside"
		}
		if err := archive.WriteHeader(header); err != nil {
			t.Fatal(err)
		}
		if _, err := archive.Write(data); err != nil {
			t.Fatal(err)
		}
	}
	for name, data := range files {
		if name == "cmd/app/main.go" {
			switch mutation {
			case "missing-member":
				continue
			case "member-checksum":
				data = append(bytes.Clone(data), []byte("\n// patched runtime\n")...)
			}
		}
		write(name, data, tar.TypeReg)
	}
	switch mutation {
	case "extra-member":
		write("unreviewed.go", []byte("package main\n"), tar.TypeReg)
	case "duplicate-member":
		write("cmd/app/main.go", files["cmd/app/main.go"], tar.TypeReg)
	case "parent-path":
		write("../escape.go", nil, tar.TypeReg)
	case "symlink":
		write("linked-source.go", nil, tar.TypeSymlink)
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	if err := compressed.Close(); err != nil {
		t.Fatal(err)
	}
	return result.Bytes()
}
