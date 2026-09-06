package migrationtest

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"tesl.dev/runtime/go/internal/cli"
	"tesl.dev/runtime/go/teslrt"
)

// INV-ADDITIVE-READ, INV-ADDITIVE-WRITE, INV-PRIVILEGE, INV-INSTALL-CATALOG; TR-BOOT-EXPAND, TR-READ, TR-WRITE.
// Normal compiled application binaries exercise the installer, standalone schema
// worker and request process with separate operator-provisioned PostgreSQL roles.
func TestCompiledWorkerLessonRetainsRows(t *testing.T) {
	dsn := os.Getenv("TESL_MIGRATION_TEST_DSN")
	if dsn == "" {
		if os.Getenv("TESL_MIGRATION_TEST_REQUIRE_POSTGRES") == "1" {
			t.Fatal("TESL_MIGRATION_TEST_REQUIRE_POSTGRES=1 requires TESL_MIGRATION_TEST_DSN")
		}
		t.Skip("run scripts/run-migration-tests.sh")
	}
	root := os.Getenv("TESL_REPO_ROOT")
	if root == "" {
		var err error
		root, err = filepath.Abs("../../../..")
		if err != nil {
			t.Fatal(err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	// Cleanup is registered in resource order: processes stop before connections,
	// database and roles are removed, and before their context is cancelled.
	t.Cleanup(cancel)
	project := t.TempDir()
	const entry = "lesson84-worker-migrations.tesl"
	const child = "schema/worker-notes/v-current/notes.tesl"
	for _, name := range []string{entry, child, "schema/worker-notes/v-current.tesl"} {
		data, err := os.ReadFile(filepath.Join(root, "example/learn", name))
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(project, name)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(project, "tesl.toml"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	original, err := os.ReadFile(filepath.Join(project, entry))
	if err != nil {
		t.Fatal(err)
	}
	compiler := filepath.Join(root, "compiler/_build/default/bin/main.exe")
	var output bytes.Buffer
	app := cli.New()
	app.Directory, app.Stdout, app.Stderr = project, &output, &output
	app.Resolver.Getenv = func(key string) string {
		if key == "TESL_COMPILER" {
			return compiler
		}
		return os.Getenv(key)
	}
	command := func(args ...string) {
		t.Helper()
		output.Reset()
		if err := app.Run(ctx, args); err != nil {
			t.Fatalf("Worker lesson command: %v\n%s", err, &output)
		}
	}
	check := func(name string) {
		t.Helper()
		cmd := exec.CommandContext(ctx, compiler, "agent-context", filepath.Join(project, name))
		cmd.Dir = project
		if data, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("Worker lesson diagnostics: %v\n%s", err, data)
		}
	}
	binaries := make(map[int]string)
	for _, version := range []int{1, 2} {
		if version == 2 {
			command("migrate", "generate", entry, "--new-revision")
			path := filepath.Join(project, child)
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			text := string(data)
			for _, edit := range [][2]string{
				{"  title: String ::: ValidTitle title\n}", "  title: String ::: ValidTitle title\n  category: Maybe String\n}"},
				{"Note { id: id, title: title }", "Note { id: id, title: title, category: Nothing }"},
			} {
				if strings.Count(text, edit[0]) != 1 {
					t.Fatalf("Worker lesson edit target changed: %q", edit[0])
				}
				text = strings.Replace(text, edit[0], edit[1], 1)
			}
			if err := os.WriteFile(path, []byte(text), 0600); err != nil {
				t.Fatal(err)
			}
			command("migrate", "generate", entry)
			check(child)
			check("migrations/worker-notes/v2.tesl")
		}
		check(entry)
		generated := filepath.Join(t.TempDir(), fmt.Sprintf("go-v%d", version))
		command("compile", entry, "--out", generated)
		unit := exec.CommandContext(ctx, "go", "test", "-race", "-count=1", "./internal/teslmodlesson84workermigrations")
		unit.Dir = generated
		if data, err := unit.CombinedOutput(); err != nil {
			t.Fatalf("Worker lesson V%d unit/API tests: %v\n%s", version, err, data)
		}
		binary := filepath.Join(t.TempDir(), fmt.Sprintf("worker-app-v%d", version))
		build := exec.CommandContext(ctx, "go", "build", "-race", "-o", binary, "./cmd/app")
		build.Dir = generated
		if data, err := build.CombinedOutput(); err != nil {
			t.Fatalf("Worker lesson V%d application: %v\n%s", version, err, data)
		}
		binaries[version] = binary
		current, err := os.ReadFile(filepath.Join(project, entry))
		if err != nil || !bytes.Equal(original, current) {
			t.Fatal("Worker migration changed the connection, handlers, routes, codecs or application tests")
		}
		if err := os.RemoveAll(generated); err != nil {
			t.Fatal(err)
		}
	}
	// The deployed executables must work without source files or generated Go.
	if err := os.RemoveAll(project); err != nil {
		t.Fatal(err)
	}
	admin, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = admin.Close(context.Background()) })
	database := "worker_lesson_" + strings.ReplaceAll(teslrt.UUIDv7(), "-", "")
	owner, worker, requestRole, setup := database+"_owner", database+"_worker", database+"_app", database+"_setup"
	t.Cleanup(func() {
		cleanup, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		if _, err := admin.Exec(cleanup, "drop database if exists "+pgx.Identifier{database}.Sanitize()+" with (force)"); err != nil {
			t.Errorf("Worker lesson database cleanup: %v", err)
		}
		for _, role := range []string{worker, requestRole, setup, owner} {
			if _, err := admin.Exec(cleanup, "drop role if exists "+pgx.Identifier{role}.Sanitize()); err != nil {
				t.Errorf("Worker lesson role cleanup: %v", err)
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
	loginEnvironment := func(role string) []string {
		return append(append([]string(nil), environment...), "NOTES_DB_USER="+role, "PGUSER="+role)
	}
	installCtx, stopInstall := context.WithTimeout(ctx, 10*time.Second)
	install := exec.CommandContext(installCtx, binaries[1], "--schema", "install", "--worker", worker, "--request", requestRole, "--json")
	install.Env = loginEnvironment(setup)
	data, installErr := install.CombinedOutput()
	stopInstall()
	if installErr != nil {
		t.Fatalf("Worker lesson installer: %v\n%s", installErr, data)
	}
	var installation struct {
		Kind              string `json:"kind"`
		DatabaseUUID      string `json:"databaseUuid"`
		InitialVersion    int    `json:"initialVersion"`
		CurrentVersion    int    `json:"currentVersion"`
		InstallingVersion int    `json:"installingVersion"`
	}
	if err := json.Unmarshal(data, &installation); err != nil || installation.Kind != "schema-install" || installation.DatabaseUUID == "" ||
		installation.InitialVersion != 1 || installation.CurrentVersion != 0 || installation.InstallingVersion != 1 {
		t.Fatalf("Worker installer performed storage work or recorded the wrong origin: %s (%v)", data, err)
	}
	if _, err := observer.Exec(ctx, "revoke "+owner+" from "+setup); err != nil {
		t.Fatal(err)
	}
	var isolated bool
	if err := observer.QueryRow(ctx, `select
 not pg_catalog.has_database_privilege($1,$2,'TEMPORARY') and
 not pg_catalog.has_schema_privilege($1,'public','CREATE') and
 not pg_catalog.has_schema_privilege($1,'worker_notes','CREATE')`, requestRole, database).Scan(&isolated); err != nil || !isolated {
		t.Fatalf("request fixture unexpectedly has temporary-table or schema CREATE authority: %v (%v)", isolated, err)
	}
	status := func(version, current int) {
		t.Helper()
		commandCtx, stop := context.WithTimeout(ctx, 10*time.Second)
		defer stop()
		cmd := exec.CommandContext(commandCtx, binaries[version], "--schema", "status", "--database", "Lesson84WorkerMigrations.NoteDatabase", "--json")
		cmd.Env = loginEnvironment(requestRole)
		data, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("Worker lesson status from request login: %v\n%s", err, data)
		}
		var report teslrt.PgMigrationStatus
		if err := json.Unmarshal(data, &report); err != nil || report.Kind != "schema-status" || report.BinaryVersion != version ||
			report.CurrentVersion != current || report.DatabaseUUID != installation.DatabaseUUID || report.HistoryError != "" {
			t.Fatalf("Worker status changed storage or reported a different database: %s (%v)", data, err)
		}
	}
	status(1, 0)
	client := &http.Client{Timeout: time.Second}
	startRequest := func(version int, label string) *workerLessonProcess {
		t.Helper()
		return startWorkerLessonProcess(t, ctx, binaries[version], append(loginEnvironment(requestRole), "PGAPPNAME=tesl-app:"+label), label)
	}
	startWorker := func(version int) *workerLessonProcess {
		t.Helper()
		label := fmt.Sprintf("schema-worker-v%d", version)
		process := startWorkerLessonProcess(t, ctx, binaries[version], append(loginEnvironment(worker), "PGAPPNAME=tesl-exec:"+label), label, "--schema", "worker", "--json")
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
					if ready.Database != "Lesson84WorkerMigrations.NoteDatabase" || ready.DatabaseUUID != installation.DatabaseUUID ||
						ready.BinaryVersion != version || ready.CurrentVersion != version {
						t.Fatalf("worker published the wrong readiness: %s", line)
					}
					return true
				}
			}
			return false
		})
		process.assertAlive(t)
		process.assertNoHTTP(t)
		status(version, version)
		return process
	}
	assertWaiting := func(process *workerLessonProcess, before string, current int) {
		t.Helper()
		// Observe two completed read snapshots on this exact request backend.
		// The first rollback alone could also be a failing initialization; a new
		// idle rollback proves that startup is continuing its readiness loop.
		var firstPID int
		var firstSnapshot time.Time
		workerLessonWait(t, ctx, process, "request control-state observation", func() bool {
			var pid int
			var completed time.Time
			err := observer.QueryRow(ctx, `select pid,state_change from pg_stat_activity
 where datname=$1 and usename=$2 and application_name=$3 and state='idle' and query='rollback'`,
				database, requestRole, "tesl-app:"+process.label).Scan(&pid, &completed)
			if errors.Is(err, pgx.ErrNoRows) {
				return false
			}
			if err != nil {
				t.Fatal(err)
			}
			if firstPID == 0 {
				firstPID, firstSnapshot = pid, completed
				return false
			}
			return pid == firstPID && completed.After(firstSnapshot)
		})
		process.assertNoHTTP(t)
		if after := workerLessonControlSnapshot(t, ctx, observer); before != after {
			t.Fatalf("request startup mutated migration state before its worker:\nbefore %s\nafter %s", before, after)
		}
		status(current+1, current)
	}
	assertHTTPReady := func(process *workerLessonProcess) {
		t.Helper()
		workerLessonWait(t, ctx, process, "HTTP readiness", func() bool {
			response, err := client.Get(process.base + "/notes/readiness")
			if err != nil {
				return false
			}
			_ = response.Body.Close()
			return response.StatusCode == http.StatusNotFound
		})
	}
	before := workerLessonControlSnapshot(t, ctx, observer)
	old := startRequest(1, "worker-lesson-request-v1")
	assertWaiting(old, before, 0)
	var absent bool
	if err := observer.QueryRow(ctx, "select to_regclass('worker_notes.lesson_worker_notes') is null").Scan(&absent); err != nil || !absent {
		t.Fatalf("request process created initial entity storage: %v (%v)", absent, err)
	}
	firstWorker := startWorker(1)
	assertHTTPReady(old)
	workerLessonRequest(t, ctx, client, old.base, "POST", "retained", `{"title":"  First note  "}`, 200, "First note")
	firstWorker.assertNoHTTP(t)
	firstWorker.stop(t)
	before = workerLessonControlSnapshot(t, ctx, observer)
	current := startRequest(2, "worker-lesson-request-v2")
	assertWaiting(current, before, 1)
	workerLessonRequest(t, ctx, client, old.base, "GET", "retained", "", 200, "First note")
	secondWorker := startWorker(2)
	assertHTTPReady(current)
	workerLessonRequest(t, ctx, client, current.base, "GET", "retained", "", 200, "First note")
	status(1, 2)
	workerLessonRequest(t, ctx, client, current.base, "POST", "new", `{"title":"New note"}`, 200, "New note")
	workerLessonRequest(t, ctx, client, old.base, "GET", "new", "", 200, "New note")
	workerLessonRequest(t, ctx, client, old.base, "POST", "during-roll", `{"title":"Old writer"}`, 200, "Old writer")
	workerLessonRequest(t, ctx, client, current.base, "GET", "during-roll", "", 200, "Old writer")
	old.stop(t)
	// A fully expanded database serves and restarts without a running worker.
	secondWorker.assertNoHTTP(t)
	secondWorker.stop(t)
	restarted := startRequest(1, "worker-lesson-request-v1-restart")
	assertHTTPReady(restarted)
	workerLessonRequest(t, ctx, client, restarted.base, "GET", "retained", "", 200, "First note")
	workerLessonRequest(t, ctx, client, restarted.base, "GET", "new", "", 200, "New note")
	workerLessonRequest(t, ctx, client, restarted.base, "POST", "restarted", `{"title":"Restarted writer"}`, 200, "Restarted writer")
	workerLessonRequest(t, ctx, client, current.base, "GET", "restarted", "", 200, "Restarted writer")
	for i, process := range []*workerLessonProcess{current, restarted} {
		id := fmt.Sprintf("invalid-%d", i)
		for _, body := range []string{`{"title":"   "}`, `{"title":42}`, `{"title":"` + strings.Repeat("x", 81) + `"}`} {
			workerLessonRequest(t, ctx, client, process.base, "POST", id, body, 400, "")
			workerLessonRequest(t, ctx, client, process.base, "GET", id, "", 404, "")
		}
	}
	requestConfig := config.Copy()
	requestConfig.User = requestRole
	requestConn, err := pgx.ConnectConfig(ctx, requestConfig)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = requestConn.Close(context.Background()) })
	before = workerLessonControlSnapshot(t, ctx, observer)
	for _, sql := range []string{
		"create temporary table request_temporary(id integer)",
		"create table public.request_created(id integer)",
		"create table worker_notes.request_created(id integer)",
		"alter table worker_notes.lesson_worker_notes add column request_added text",
		"update worker_notes.tesl_schema_state set current=current where id=1",
		"select worker_notes.tesl_begin_expansion(3,null,null,null,null,0,true)",
		"select worker_notes.tesl_record_expansion_object(3,0,null)",
		"select worker_notes.tesl_record_expanded(3)",
		"select worker_notes.tesl_lock_expired_index_holder('x','tesl-exec:old',1,2,'abi')",
		"set role " + worker,
		"set role " + owner,
	} {
		_, err := requestConn.Exec(ctx, sql)
		var pgError *pgconn.PgError
		if !errors.As(err, &pgError) || pgError.Code != "42501" {
			t.Fatalf("request login was not denied at the privilege boundary for %q: %v", sql, err)
		}
	}
	if after := workerLessonControlSnapshot(t, ctx, observer); before != after {
		t.Fatalf("request privilege probes changed protected state:\nbefore %s\nafter %s", before, after)
	}
	// Each process must use its declared identity. A privilege mismatch must
	// fail for that reason, before readiness, rather than a coincidental error.
	for _, mismatch := range []struct {
		login, reason string
		args          []string
	}{
		{requestRole, "configured worker identity", []string{"--schema", "worker", "--json"}},
		{worker, "configured request identity", nil},
	} {
		refusalCtx, stopRefusal := context.WithTimeout(ctx, 10*time.Second)
		refused := exec.CommandContext(refusalCtx, binaries[2], mismatch.args...)
		refused.Env = loginEnvironment(mismatch.login)
		refusalOutput, refusalErr := refused.CombinedOutput()
		refusalTimedOut := refusalCtx.Err() != nil
		stopRefusal()
		if refusalErr == nil || refusalTimedOut || bytes.Contains(refusalOutput, []byte("schema-worker-ready")) ||
			!bytes.Contains(refusalOutput, []byte(mismatch.reason)) {
			t.Fatalf("wrong process identity did not fail promptly for %q: %v\n%s", mismatch.reason, refusalErr, refusalOutput)
		}
		if after := workerLessonControlSnapshot(t, ctx, observer); before != after {
			t.Fatalf("refused process changed protected state:\nbefore %s\nafter %s", before, after)
		}
	}
	var rows, nulls int
	if err := observer.QueryRow(ctx, "select count(*),count(*) filter(where category is null) from worker_notes.lesson_worker_notes").Scan(&rows, &nulls); err != nil || rows != 4 || nulls != 4 {
		t.Fatalf("Worker rollout lost rows or changed nullable defaults: %d %d (%v)", rows, nulls, err)
	}
	workerLessonRequest(t, ctx, client, current.base, "GET", "retained", "", 200, "First note")
}

func workerLessonControlSnapshot(t *testing.T, ctx context.Context, conn *pgx.Conn) string {
	t.Helper()
	var snapshot string
	err := conn.QueryRow(ctx, `select jsonb_build_object(
 'meta',(select jsonb_agg(to_jsonb(m) order by id) from worker_notes.tesl_schema_meta m),
 'state',(select jsonb_agg(to_jsonb(s) order by id) from worker_notes.tesl_schema_state s),
 'history',(select jsonb_agg(to_jsonb(v) order by version,step,seq) from worker_notes.tesl_schema_versions v),
 'intents',(select jsonb_agg(to_jsonb(e) order by version) from worker_notes.tesl_schema_expansions e),
 'objects',(select jsonb_agg(to_jsonb(o) order by version,ordinal) from worker_notes.tesl_schema_expansion_objects o),
 'columns',(select jsonb_agg(to_jsonb(c) order by table_name,ordinal_position) from information_schema.columns c where table_schema='worker_notes'))::text`).Scan(&snapshot)
	if err != nil {
		t.Fatal(err)
	}
	return snapshot
}

type workerLessonProcess struct {
	label, base, address string
	cmd                  *exec.Cmd
	log                  *os.File
	done                 chan struct{}
	waitErr              error
	once                 sync.Once
}

func startWorkerLessonProcess(t *testing.T, ctx context.Context, binary string, environment []string, label string, args ...string) *workerLessonProcess {
	t.Helper()
	return startMigrationAppProcess(t, ctx, binary, environment, label, "NOTES_HTTP_PORT", args...)
}

func startMigrationAppProcess(t *testing.T, ctx context.Context, binary string, environment []string, label, portEnvironment string, args ...string) *workerLessonProcess {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	_, port, err := net.SplitHostPort(address)
	if err != nil {
		_ = listener.Close()
		t.Fatal(err)
	}
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	log, err := os.CreateTemp(t.TempDir(), label+"-*.log")
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.CommandContext(ctx, binary, args...)
	cmd.Env = append(append([]string(nil), environment...), portEnvironment+"="+port)
	cmd.Stdout, cmd.Stderr = log, log
	if err := cmd.Start(); err != nil {
		_ = log.Close()
		t.Fatal(err)
	}
	process := &workerLessonProcess{label: label, base: "http://" + address, address: address, cmd: cmd, log: log, done: make(chan struct{})}
	go func() {
		process.waitErr = cmd.Wait()
		close(process.done)
	}()
	t.Cleanup(func() { process.stop(t) })
	return process
}

func (process *workerLessonProcess) output() []byte {
	data, _ := os.ReadFile(process.log.Name())
	return data
}

func (process *workerLessonProcess) assertAlive(t *testing.T) {
	t.Helper()
	select {
	case <-process.done:
		t.Fatalf("%s exited: %v\n%s", process.label, process.waitErr, process.output())
	default:
	}
}

func (process *workerLessonProcess) assertNoHTTP(t *testing.T) {
	t.Helper()
	process.assertAlive(t)
	conn, err := net.DialTimeout("tcp", process.address, 100*time.Millisecond)
	if err == nil {
		_ = conn.Close()
		t.Fatalf("%s unexpectedly opened an HTTP listener\n%s", process.label, process.output())
	}
}

func (process *workerLessonProcess) stop(t *testing.T) {
	t.Helper()
	process.once.Do(func() {
		_ = process.cmd.Process.Signal(os.Interrupt)
		select {
		case <-process.done:
		case <-time.After(5 * time.Second):
			_ = process.cmd.Process.Kill()
			<-process.done
			t.Errorf("%s ignored graceful shutdown", process.label)
		}
		_ = process.log.Close()
		if process.waitErr != nil {
			t.Errorf("%s shutdown: %v\n%s", process.label, process.waitErr, process.output())
		}
	})
}

func workerLessonWait(t *testing.T, ctx context.Context, process *workerLessonProcess, reason string, ready func() bool) {
	t.Helper()
	waitCtx, stop := context.WithTimeout(ctx, 20*time.Second)
	defer stop()
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		process.assertAlive(t)
		if ready() {
			return
		}
		select {
		case <-waitCtx.Done():
			t.Fatalf("%s waiting for %s: %v\n%s", process.label, reason, waitCtx.Err(), process.output())
		case <-process.done:
			process.assertAlive(t)
		case <-ticker.C:
		}
	}
}

func workerLessonRequest(t *testing.T, ctx context.Context, client *http.Client, base, method, id, body string, want int, title string) {
	t.Helper()
	request, err := http.NewRequestWithContext(ctx, method, base+"/notes/"+id, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = response.Body.Close() }()
	data, err := io.ReadAll(io.LimitReader(response.Body, 4096))
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != want {
		t.Fatalf("%s %s: %d %s", method, id, response.StatusCode, data)
	}
	if want == http.StatusOK {
		var got map[string]string
		if err := json.Unmarshal(data, &got); err != nil || len(got) != 2 || got["id"] != id || got["title"] != title {
			t.Fatalf("Worker rollout changed the public API: %s (%v)", data, err)
		}
	}
}
