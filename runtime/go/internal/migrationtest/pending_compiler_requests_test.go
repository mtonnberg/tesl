package migrationtest

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// INV-ADDITIVE-READ, INV-ADDITIVE-WRITE, INV-CATALOG-EVIDENCE; TR-BOOT-EXPAND, TR-READ, TR-WRITE.
// Called by the existing actual A/B/C compiler gate so this acceptance case does
// not build another compiler tree. A and B differ in compiler query source, not
// in their explicitly declared stored-value semantics. Emitted ABI/history bytes
// and saved migration source are never patched to manufacture compatibility.
func testPendingCompatibleCompilerRequests(t *testing.T, ctx context.Context, root, compilerA, compilerB string) {
	t.Helper()
	apps := buildPendingCompilerApps(t, ctx, root, compilerA, compilerB)
	db := newShowcaseDatabase(t, ctx, os.Getenv("TESL_MIGRATION_TEST_DSN"))
	db.install(t, apps.a1)
	oldWorker := db.workerNode(t, apps.a1, 1)
	client := &http.Client{Timeout: 3 * time.Second}
	first := db.requestNode(t, apps.a1, "pending-a-before")
	requireShowcaseReady(t, ctx, client, first)
	retained := showcaseTodo{ID: "retained", Title: "Established by compiler A"}
	requireShowcaseTodo(t, ctx, client, first.base, http.MethodPost, retained.ID, `{"title":"Established by compiler A"}`, retained)
	first.stop(t)

	directory, err := os.MkdirTemp("", "tesl-pending-compiler-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	boundary := Event{Name: "expansion-after-commit", Actor: "pending-compiler-b", Occurrence: 1}
	schedule := NewSchedule(nil)
	if err := schedule.Pause(boundary); err != nil {
		t.Fatal(err)
	}
	// Failure unwinding releases the test-only boundary before t.Cleanup stops
	// application processes; a blocked hook must not manufacture a shutdown hang.
	defer func() { _ = schedule.Release(boundary) }()
	socket := filepath.Join(directory, "control.sock")
	controller, err := ListenProcesses(ctx, socket, schedule)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(controller.Close)
	newWorker := startMigrationAppProcess(t, ctx, apps.b2Tagged,
		append(db.login(db.worker), "PGAPPNAME=tesl-exec:pending-compiler-b", "TESL_MIGRATION_TEST_SOCKET="+socket, "TESL_MIGRATION_TEST_ACTOR="+boundary.Actor),
		"pending-b-worker", "TODO_HTTP_PORT", "--schema", "worker", "--json")
	wait, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if err := schedule.Await(wait, boundary); err != nil {
		t.Fatalf("B did not pause after committing its expansion intent: %v\n%s", err, newWorker.output())
	}
	var current, objects int
	var creator, contract string
	if err := db.observer.QueryRow(ctx, `select s.current,e.source_abi,e.stored_value_compatibility,
 (select count(*) from todo_app.tesl_schema_expansion_objects where version=2)
 from todo_app.tesl_schema_state s cross join todo_app.tesl_schema_expansions e
 where s.id=1 and e.version=2`).Scan(&current, &creator, &contract, &objects); err != nil ||
		current != 1 || creator != apps.abiB || creator == apps.abiA || contract != apps.compatibility || objects != 0 {
		t.Fatalf("not an actual cross-ABI pending expansion: current=%d creator=%s objects=%d contract=%s (%v)", current, creator, objects, contract, err)
	}
	// This snapshot covers durable migration authority, including the intent,
	// object receipts and lifecycle; it intentionally excludes instance heartbeats.
	before := db.controlSnapshot(t)

	// A cold old request and its status command observe the completed prefix.
	// Neither needs authority to execute B's unfinished expansion. The older
	// already-admitted worker must likewise stay idle instead of taking it over.
	restarted := db.requestNode(t, apps.a1, "pending-a-restarted")
	requireShowcaseReady(t, ctx, client, restarted)
	requireShowcaseTodo(t, ctx, client, restarted.base, http.MethodGet, retained.ID, "", retained)
	during := showcaseTodo{ID: "during", Title: "Old request during new intent"}
	requireShowcaseTodo(t, ctx, client, restarted.base, http.MethodPost, during.ID, `{"title":"Old request during new intent"}`, during)
	db.status(t, apps.a1, 1, 1)
	newRequest := db.requestNode(t, apps.b2, "pending-b-request")
	db.requireWaiting(t, newRequest)
	var firstInstance string
	var firstSnapshot time.Time
	workerLessonWait(t, ctx, oldWorker, "old idle worker observing B's pending intent", func() bool {
		var instance string
		var completed time.Time
		// The coordinator publishes its heartbeat only after its checked index
		// snapshot. A fresh heartbeat proves this pending intent was observed.
		err := db.observer.QueryRow(ctx, `select instance,last_seen from todo_app.tesl_schema_instances
 where version=1 and instance like 'tesl-exec:%' order by last_seen desc limit 1`).Scan(&instance, &completed)
		if errors.Is(err, pgx.ErrNoRows) {
			return false
		}
		if err != nil {
			t.Fatal(err)
		}
		if firstInstance == "" {
			firstInstance, firstSnapshot = instance, completed
			return false
		}
		return instance == firstInstance && completed.After(firstSnapshot)
	})

	// The live B worker holds the expansion boot lock. Kill it at the committed
	// intent, then observe its PostgreSQL backend disappear before asking A2 to
	// execute. A timeout behind B's lock would prove serialization, not ABI refusal.
	var backends int
	if err := db.observer.QueryRow(ctx, `select count(*) from pg_stat_activity
 where datname=$1 and usename=$2 and application_name='tesl-exec:pending-compiler-b'`, db.name, db.worker).Scan(&backends); err != nil || backends == 0 {
		t.Fatalf("B's paused expansion backend is not observable: count=%d (%v)", backends, err)
	}
	newWorker.once.Do(func() {
		if err := newWorker.cmd.Process.Kill(); err != nil {
			t.Fatal(err)
		}
		<-newWorker.done
		_ = newWorker.log.Close()
		if newWorker.waitErr == nil {
			t.Fatal("killed B expansion worker reported success")
		}
	})
	if err := schedule.Release(boundary); err != nil {
		t.Fatal(err)
	}
	workerLessonWait(t, ctx, oldWorker, "B backend and its expansion boot lock disappearing", func() bool {
		if err := db.observer.QueryRow(ctx, `select count(*) from pg_stat_activity
 where datname=$1 and usename=$2 and application_name='tesl-exec:pending-compiler-b'`, db.name, db.worker).Scan(&backends); err != nil {
			t.Fatal(err)
		}
		return backends == 0
	})

	refuse, stop := context.WithTimeout(ctx, 10*time.Second)
	command := exec.CommandContext(refuse, apps.a2, "--schema", "worker", "--json")
	command.Env = db.login(db.worker)
	output, refusal := command.CombinedOutput()
	stop()
	if refusal == nil || refuse.Err() == context.DeadlineExceeded || !bytes.Contains(output, []byte("unfinished migration compiler ABI differs")) ||
		bytes.Contains(output, []byte("schema-worker-ready")) {
		t.Fatalf("A executor gained authority over B's pending work: %v\n%s", refusal, output)
	}
	if after := db.controlSnapshot(t); before != after {
		t.Fatalf("observation or refused executor changed B's pending state:\nbefore %s\nafter %s", before, after)
	}
	requireShowcaseTodo(t, ctx, client, restarted.base, http.MethodGet, during.ID, "", during)
	newRequest.assertNoHTTP(t)
	oldWorker.assertAlive(t)

	ordinary := db.workerNode(t, apps.b2, 2)
	requireShowcaseReady(t, ctx, client, newRequest)
	db.status(t, apps.a1, 1, 2)
	db.status(t, apps.b2, 2, 2)
	for _, row := range []showcaseTodo{retained, during} {
		requireShowcaseTodo(t, ctx, client, newRequest.base, http.MethodGet, row.ID, "", row)
	}
	after := showcaseTodo{ID: "after", Title: "New writer after expansion", Completed: true}
	requireShowcaseTodo(t, ctx, client, newRequest.base, http.MethodPost, after.ID, `{"title":"New writer after expansion"}`,
		showcaseTodo{ID: after.ID, Title: after.Title})
	requireShowcaseTodo(t, ctx, client, restarted.base, http.MethodPut, after.ID, `{"title":"New writer after expansion","completed":true}`, after)
	requireShowcaseTodo(t, ctx, client, newRequest.base, http.MethodGet, after.ID, "", after)
	var rows, nulls int
	if err := db.observer.QueryRow(ctx, "select count(*),count(*) filter(where details is null) from todo_app.todos").Scan(&rows, &nulls); err != nil || rows != 3 || nulls != 3 {
		t.Fatalf("pending compiler upgrade lost rows or old-writer NULL defaults: rows=%d nulls=%d (%v)", rows, nulls, err)
	}
	if err := db.observer.QueryRow(ctx, "select source_abi from todo_app.tesl_schema_expansions where version=2").Scan(&creator); err != nil || creator != apps.abiB {
		t.Fatalf("completed expansion rewrote its actual B executor provenance: %s (%v)", creator, err)
	}
	oldWorker.assertAlive(t)
	ordinary.assertNoHTTP(t)
}

type pendingCompilerApps struct {
	a1, a2, b2, b2Tagged      string
	abiA, abiB, compatibility string
}

type pendingCompilerHistory struct {
	Version                  int             `json:"version"`
	CompilerABI              string          `json:"compilerAbi"`
	StoredValueCompatibility string          `json:"storedValueCompatibility"`
	Databases                json.RawMessage `json:"databases"`
}

func buildPendingCompilerApps(t *testing.T, ctx context.Context, root, compilerA, compilerB string) pendingCompilerApps {
	t.Helper()
	var apps pendingCompilerApps
	var a2History pendingCompilerHistory
	var a2Source map[string][]byte
	buildRoot := t.TempDir()
	for _, release := range []struct {
		name, compiler string
		revision       int
		target         *string
	}{
		{"a1", compilerA, 1, &apps.a1}, {"a2", compilerA, 2, &apps.a2}, {"b2", compilerB, 2, &apps.b2},
	} {
		output := filepath.Join(buildRoot, release.name)
		command := exec.CommandContext(ctx, "bash", filepath.Join(root, "example/db-migration-example/deploy/build-revision.sh"),
			fmt.Sprint(release.revision), output, "--emit-only")
		command.Dir = root
		command.Env = append(os.Environ(), "TESL_COMPILER="+release.compiler, "TESL_REPO_ROOT="+root)
		if data, err := command.CombinedOutput(); err != nil {
			t.Fatalf("compile actual %s saved-source application: %v\n%s", release.name, err, data)
		}
		generated := filepath.Join(output, "go")
		data, err := os.ReadFile(filepath.Join(generated, "migration-history.json"))
		if err != nil {
			t.Fatal(err)
		}
		var history pendingCompilerHistory
		if err := json.Unmarshal(data, &history); err != nil || history.Version != 3 || history.CompilerABI == "" || history.StoredValueCompatibility == "" {
			t.Fatalf("missing real compiler provenance: %s (%v)", data, err)
		}
		source := pendingCompilerSourceBytes(t, filepath.Join(output, "source"))
		switch release.name {
		case "a1":
			apps.abiA, apps.compatibility = history.CompilerABI, history.StoredValueCompatibility
		case "a2":
			if history.CompilerABI != apps.abiA || history.StoredValueCompatibility != apps.compatibility {
				t.Fatal("compiler A changed while freezing application releases")
			}
			a2History, a2Source = history, source
		case "b2":
			apps.abiB = history.CompilerABI
			if apps.abiB == apps.abiA || history.StoredValueCompatibility != apps.compatibility || !bytes.Equal(a2History.Databases, history.Databases) {
				t.Fatal("A/B must have distinct actual ABIs and identical checked storage histories under one explicit contract")
			}
			if len(source) != len(a2Source) {
				t.Fatal("B changed the saved migration source closure")
			}
			for name, expected := range a2Source {
				if !bytes.Equal(source[name], expected) {
					t.Fatalf("B changed frozen source/provenance in %s", name)
				}
			}
		}
		unit := exec.CommandContext(ctx, "go", "test", "-race", "-count=1", "./internal/teslmodtodoapp")
		unit.Dir = generated
		if data, err := unit.CombinedOutput(); err != nil {
			t.Fatalf("%s unchanged app unit/API suite: %v\n%s", release.name, err, data)
		}
		*release.target = filepath.Join(t.TempDir(), "pending-"+release.name)
		build := exec.CommandContext(ctx, "go", "build", "-race", "-o", *release.target, "./cmd/app")
		build.Dir = generated
		if data, err := build.CombinedOutput(); err != nil {
			t.Fatalf("%s ordinary application binary: %v\n%s", release.name, err, data)
		}
		if release.name == "b2" {
			apps.b2Tagged = filepath.Join(t.TempDir(), "pending-b2-tagged")
			build := exec.CommandContext(ctx, "go", "build", "-race", "-tags=tesl_migration_test", "-o", apps.b2Tagged, "./cmd/app")
			build.Dir = generated
			if data, err := build.CombinedOutput(); err != nil {
				t.Fatalf("B pending-boundary executable: %v\n%s", err, data)
			}
		}
	}
	// All subsequent observation, writes and executor refusals use standalone
	// binaries. No source tree or generated Go remains available at deployment.
	if err := os.RemoveAll(buildRoot); err != nil {
		t.Fatal(err)
	}
	return apps
}

func pendingCompilerSourceBytes(t *testing.T, source string) map[string][]byte {
	t.Helper()
	files := make(map[string][]byte)
	if err := filepath.WalkDir(source, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() || !strings.HasSuffix(path, ".tesl") {
			return nil
		}
		name, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		data, err := os.ReadFile(path)
		if err == nil {
			files[name] = data
		}
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return files
}
