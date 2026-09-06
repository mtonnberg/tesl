package migrationtest

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
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
	"tesl.dev/runtime/go/teslrt"
)

// INV-ADDITIVE-READ, INV-ADDITIVE-WRITE, INV-PRIVILEGE, INV-CATALOG-EVIDENCE; TR-BOOT-EXPAND, TR-READ, TR-WRITE.
// Seven ordinary compiled apps share retained PostgreSQL rows through six real
// migration edges. Only the interrupted V4 worker has test boundary hooks.
func TestCompiledTodoShowcaseRollingUpgrade(t *testing.T) {
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
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Minute)
	t.Cleanup(cancel)
	binaries, interrupted := buildShowcaseRevisions(t, ctx, root)
	db := newShowcaseDatabase(t, ctx, dsn)
	db.install(t, binaries[1])
	db.status(t, binaries[1], 1, 0)
	client := &http.Client{Timeout: 3 * time.Second}
	first := db.requestNode(t, binaries[1], "todo-v1-a")
	db.requireWaiting(t, first)
	worker := db.workerNode(t, binaries[1], 1)
	requireShowcaseReady(t, ctx, client, first)
	second := db.requestNode(t, binaries[1], "todo-v1-b")
	requireShowcaseReady(t, ctx, client, second)
	nodes := []*showcaseProxyNode{newShowcaseProxyNode(t, first), newShowcaseProxyNode(t, second)}
	proxy := &showcaseProxy{nodes: append([]*showcaseProxyNode(nil), nodes...)}
	server := httptest.NewServer(proxy)
	defer server.Close()
	seeds := []showcaseTodo{
		{ID: "seed-pending", Title: "Keep this pending task"},
		{ID: "seed-completed", Title: "Keep this completed task", Completed: true},
	}
	for _, todo := range seeds {
		created := todo
		created.Completed = false
		requireShowcaseTodo(t, ctx, client, server.URL, http.MethodPost, todo.ID, fmt.Sprintf(`{"title":%q}`, "  "+todo.Title+"  "), created)
		if todo.Completed {
			requireShowcaseTodo(t, ctx, client, server.URL, http.MethodPut, todo.ID, fmt.Sprintf(`{"title":%q,"completed":true}`, todo.Title), todo)
		}
	}
	traffic := startShowcaseTraffic(ctx, client, server.URL)
	// Stop and join the writer before process cleanups even if a phase fails.
	defer traffic.finish(t)
	traffic.requireProgress(t, ctx, nodes[0].process.label, nodes[1].process.label)
	for version := 2; version <= 7; version++ {
		t.Logf("rollout V%d while both request nodes serve retained todo rows", version)
		worker.stop(t)
		next := db.requestNode(t, binaries[version], fmt.Sprintf("todo-v%d-a", version))
		db.requireWaiting(t, next)
		traffic.requireProgress(t, ctx, nodes[0].process.label, nodes[1].process.label)
		if version == 4 {
			crashShowcaseExpansion(t, db, interrupted,
				Event{Name: "expansion-after-ddl", Actor: "todo-v4-worker", Occurrence: 1}, traffic,
				nodes[0].process.label, nodes[1].process.label)
			next.assertNoHTTP(t)
		}
		worker = db.workerNode(t, binaries[version], version)
		requireShowcaseReady(t, ctx, client, next)
		for index := range nodes {
			if index == 1 {
				next = db.requestNode(t, binaries[version], fmt.Sprintf("todo-v%d-b", version))
				requireShowcaseReady(t, ctx, client, next)
			}
			replacement := newShowcaseProxyNode(t, next)
			proxy.replace(t, nodes[index], replacement)
			nodes[index] = replacement
			// With only the first node replaced, traffic necessarily crosses the
			// old/new boundary; after the second, both independent new nodes run.
			traffic.requireProgress(t, ctx, nodes[0].process.label, nodes[1].process.label)
			for _, seed := range seeds {
				requireShowcaseTodo(t, ctx, client, server.URL, http.MethodGet, seed.ID, "", seed)
			}
		}
		worker.assertNoHTTP(t)
	}
	worker.stop(t)
	// The original compatible binary restarts after all six schema changes,
	// receives real proxy traffic, and writes without a live schema worker.
	restarted := db.requestNode(t, binaries[1], "todo-v1-restarted")
	requireShowcaseReady(t, ctx, client, restarted)
	replacement := newShowcaseProxyNode(t, restarted)
	proxy.replace(t, nodes[0], replacement)
	nodes[0] = replacement
	traffic.requireProgress(t, ctx, nodes[0].process.label, nodes[1].process.label)
	db.status(t, binaries[1], 1, 7)
	retained := traffic.finish(t)
	if len(retained) < 25 {
		t.Fatalf("rollout produced only %d completed write/readback cycles", len(retained))
	}
	for _, seed := range seeds {
		retained[seed.ID] = seed
	}
	for _, node := range nodes {
		requireShowcaseInvalidInput(t, db, client, node.process.base)
	}
	db.requireRequestPrivileges(t)
	requireShowcaseDeletion(t, ctx, client, server.URL)
	requireShowcaseList(t, ctx, client, server.URL, retained)
	for _, node := range nodes {
		requireShowcaseList(t, ctx, client, node.process.base, retained)
	}
	db.requireFinalStorage(t, len(retained))
}

func buildShowcaseRevisions(t *testing.T, ctx context.Context, root string) (map[int]string, string) {
	t.Helper()
	example := filepath.Join(root, "example", "db-migration-example")
	originals := make(map[string][]byte)
	err := filepath.WalkDir(example, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() && (entry.Name() == ".local" || entry.Name() == ".tesl-stuff" || entry.Name() == "elm-stuff") {
			return filepath.SkipDir
		}
		if entry.IsDir() || (!strings.HasSuffix(path, ".tesl") && filepath.Dir(path) != filepath.Join(example, "releases")) {
			return nil
		}
		data, err := os.ReadFile(path)
		if err == nil {
			originals[path] = data
		}
		return err
	})
	if err != nil || len(originals) < 20 {
		t.Fatalf("showcase frozen source inventory: %d files (%v)", len(originals), err)
	}
	appSource := originals[filepath.Join(example, "todo-app.tesl")]
	if len(appSource) == 0 {
		t.Fatal("showcase entry module is missing")
	}
	compiler := filepath.Join(root, "compiler", "_build", "default", "bin", "main.exe")
	buildRoot, binaries := t.TempDir(), make(map[int]string)
	interrupted := filepath.Join(t.TempDir(), "todo-v4-interrupted")
	for version := 1; version <= 7; version++ {
		output := filepath.Join(buildRoot, fmt.Sprintf("v%d", version))
		command := exec.CommandContext(ctx, "bash", filepath.Join(example, "build-revision.sh"), strconv.Itoa(version), output, "--emit-only")
		command.Dir = root
		command.Env = append(os.Environ(), "TESL_COMPILER="+compiler, "TESL_REPO_ROOT="+root)
		if data, err := command.CombinedOutput(); err != nil {
			t.Fatalf("documented V%d build-revision workflow: %v\n%s", version, err, data)
		}
		source, err := os.ReadFile(filepath.Join(output, "source", "todo-app.tesl"))
		if err != nil || !bytes.Equal(source, appSource) {
			t.Fatalf("V%d migration changed connection, handlers, DTOs, API or application tests (%v)", version, err)
		}
		requireShowcaseReleaseSources(t, example, filepath.Join(output, "source"), version, originals)
		generated := filepath.Join(output, "go")
		unit := exec.CommandContext(ctx, "go", "test", "-race", "-count=1", "./internal/teslmodtodoapp")
		unit.Dir = generated
		if data, err := unit.CombinedOutput(); err != nil {
			t.Fatalf("V%d emitted todo unit/API suite: %v\n%s", version, err, data)
		}
		binary := filepath.Join(t.TempDir(), fmt.Sprintf("todo-v%d", version))
		build := exec.CommandContext(ctx, "go", "build", "-race", "-o", binary, "./cmd/app")
		build.Dir = generated
		if data, err := build.CombinedOutput(); err != nil {
			t.Fatalf("V%d ordinary todo binary: %v\n%s", version, err, data)
		}
		binaries[version] = binary
		if version == 4 {
			build := exec.CommandContext(ctx, "go", "build", "-race", "-tags=tesl_migration_test", "-o", interrupted, "./cmd/app")
			build.Dir = generated
			if data, err := build.CombinedOutput(); err != nil {
				t.Fatalf("V4 tagged interruption worker: %v\n%s", err, data)
			}
		}
	}
	for path, expected := range originals {
		if actual, err := os.ReadFile(path); err != nil || !bytes.Equal(actual, expected) {
			t.Fatalf("building archived releases rewrote showcase source %s (%v)", path, err)
		}
	}
	// Deployment cannot consult reconstructed sources or generated Go. Only the
	// copied ordinary executables and the one fault-injection worker remain.
	if err := os.RemoveAll(buildRoot); err != nil {
		t.Fatal(err)
	}
	return binaries, interrupted
}

func requireShowcaseReleaseSources(t *testing.T, example, source string, version int, originals map[string][]byte) {
	t.Helper()
	var release struct {
		Revision int               `json:"revision"`
		Files    map[string]string `json:"files"`
	}
	if err := json.Unmarshal(originals[filepath.Join(example, "releases", fmt.Sprintf("v%d.json", version))], &release); err != nil || release.Revision != version || len(release.Files) == 0 {
		t.Fatalf("V%d release archive is absent or invalid: %v", version, err)
	}
	for relative, expected := range release.Files {
		if actual, err := os.ReadFile(filepath.Join(source, relative)); err != nil || string(actual) != expected {
			t.Fatalf("V%d reconstructed target changed archived bytes in %s (%v)", version, relative, err)
		}
	}
	for path, expected := range originals {
		relative, err := filepath.Rel(example, path)
		if err != nil {
			t.Fatal(err)
		}
		for previous := 1; previous < version; previous++ {
			schema := filepath.Join("schema", "todo", fmt.Sprintf("v%d", previous))
			frozen := relative == schema+".tesl" || strings.HasPrefix(relative, schema+string(filepath.Separator)) ||
				(previous > 1 && relative == filepath.Join("migrations", "todo", fmt.Sprintf("v%d.tesl", previous)))
			if frozen {
				if actual, err := os.ReadFile(filepath.Join(source, relative)); err != nil || !bytes.Equal(actual, expected) {
					t.Fatalf("V%d replay rewrote frozen predecessor %s (%v)", version, relative, err)
				}
			}
		}
	}
}

type showcaseTodo struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	Completed bool   `json:"completed"`
}

func decodeShowcaseTodo(data []byte) (showcaseTodo, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return showcaseTodo{}, err
	}
	if len(fields) != 3 || fields["id"] == nil || fields["title"] == nil || fields["completed"] == nil {
		return showcaseTodo{}, fmt.Errorf("todo response changed its public shape: %s", data)
	}
	for _, field := range fields {
		if bytes.Equal(bytes.TrimSpace(field), []byte("null")) {
			return showcaseTodo{}, fmt.Errorf("todo response introduced a nullable field: %s", data)
		}
	}
	var todo showcaseTodo
	if err := json.Unmarshal(data, &todo); err != nil {
		return showcaseTodo{}, err
	}
	return todo, nil
}

func showcaseRequest(ctx context.Context, client *http.Client, base, method, path, body string, wantStatus int) ([]byte, string, error) {
	request, err := http.NewRequestWithContext(ctx, method, base+path, strings.NewReader(body))
	if err != nil {
		return nil, "", err
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := client.Do(request)
	if err != nil {
		return nil, "", err
	}
	defer func() { _ = response.Body.Close() }()
	data, err := io.ReadAll(io.LimitReader(response.Body, 2<<20))
	if err != nil {
		return nil, "", err
	}
	if response.StatusCode != wantStatus {
		return nil, "", fmt.Errorf("%s %s: got HTTP %d, want %d: %s", method, path, response.StatusCode, wantStatus, data)
	}
	return data, response.Header.Get("X-Showcase-Node"), nil
}

func requireShowcaseTodo(t *testing.T, ctx context.Context, client *http.Client, base, method, id, body string, want showcaseTodo) {
	t.Helper()
	data, _, err := showcaseRequest(ctx, client, base, method, "/api/todos/"+id, body, http.StatusOK)
	if err != nil {
		t.Fatal(err)
	}
	got, err := decodeShowcaseTodo(data)
	if err != nil || got != want {
		t.Fatalf("%s %s: got %+v, want %+v (%v)", method, id, got, want, err)
	}
}

type showcaseProxyNode struct {
	process  *workerLessonProcess
	proxy    *httputil.ReverseProxy
	inflight sync.WaitGroup
}

// The test drives a real HTTP hop to each ordinary application process. Node
// selection and draining belong to this proxy, not the application response.
type showcaseProxy struct {
	mu     sync.Mutex
	nodes  []*showcaseProxyNode
	serial uint64
}

func newShowcaseProxyNode(t *testing.T, process *workerLessonProcess) *showcaseProxyNode {
	t.Helper()
	target, err := url.Parse(process.base)
	if err != nil {
		t.Fatal(err)
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.ModifyResponse = func(response *http.Response) error {
		response.Header.Set("X-Showcase-Node", process.label)
		return nil
	}
	proxy.ErrorHandler = func(response http.ResponseWriter, _ *http.Request, err error) {
		http.Error(response, "showcase proxy: "+err.Error(), http.StatusBadGateway)
	}
	return &showcaseProxyNode{process: process, proxy: proxy}
}

func (proxy *showcaseProxy) ServeHTTP(response http.ResponseWriter, request *http.Request) {
	proxy.mu.Lock()
	if len(proxy.nodes) == 0 {
		proxy.mu.Unlock()
		http.Error(response, "no ready nodes", http.StatusServiceUnavailable)
		return
	}
	node := proxy.nodes[proxy.serial%uint64(len(proxy.nodes))]
	proxy.serial++
	// Add while holding the routing lock so removal cannot begin Wait before
	// the last request selected for the old node has registered itself.
	node.inflight.Add(1)
	proxy.mu.Unlock()
	defer node.inflight.Done()
	node.proxy.ServeHTTP(response, request)
}

func (proxy *showcaseProxy) replace(t *testing.T, old, next *showcaseProxyNode) {
	t.Helper()
	proxy.mu.Lock()
	found := false
	for i, node := range proxy.nodes {
		if node == old {
			proxy.nodes[i], found = next, true
			break
		}
	}
	proxy.mu.Unlock()
	if !found {
		t.Fatal("attempted to replace a node outside the proxy")
	}
	old.inflight.Wait()
	old.process.stop(t)
}

type showcaseTraffic struct {
	mu        sync.Mutex
	hits      map[string]map[string]int
	completed map[string]showcaseTodo
	err       error
	stop      chan struct{}
	done      chan struct{}
	once      sync.Once
}

func startShowcaseTraffic(ctx context.Context, client *http.Client, base string) *showcaseTraffic {
	traffic := &showcaseTraffic{hits: make(map[string]map[string]int), completed: make(map[string]showcaseTodo), stop: make(chan struct{}), done: make(chan struct{})}
	go func() {
		defer close(traffic.done)
		for sequence := 1; ; sequence++ {
			select {
			case <-traffic.stop:
				return
			default:
			}
			id, title := fmt.Sprintf("rolling-%06d", sequence), fmt.Sprintf("Rolling task %d", sequence)
			for _, operation := range []struct {
				method, body string
				completed    bool
			}{
				{http.MethodPost, fmt.Sprintf(`{"title":%q}`, title), false},
				{http.MethodGet, "", false},
				{http.MethodPut, fmt.Sprintf(`{"title":%q,"completed":true}`, title), true},
				{http.MethodGet, "", true},
				// An odd cycle alternates the next cycle's writer under a
				// two-node round robin. Progress still checks actual methods.
				{http.MethodGet, "", true},
			} {
				data, node, err := showcaseRequest(ctx, client, base, operation.method, "/api/todos/"+id, operation.body, http.StatusOK)
				if err == nil {
					var got showcaseTodo
					got, err = decodeShowcaseTodo(data)
					if err == nil && got != (showcaseTodo{ID: id, Title: title, Completed: operation.completed}) {
						err = fmt.Errorf("continuous %s readback changed %s: %+v", operation.method, id, got)
					}
				}
				traffic.mu.Lock()
				if err != nil || node == "" {
					traffic.err = errors.Join(err, fmt.Errorf("continuous rollout request failed for %s via node %q", id, node))
					traffic.mu.Unlock()
					return
				}
				if traffic.hits[node] == nil {
					traffic.hits[node] = make(map[string]int)
				}
				traffic.hits[node][operation.method]++
				traffic.mu.Unlock()
			}
			traffic.mu.Lock()
			traffic.completed[id] = showcaseTodo{ID: id, Title: title, Completed: true}
			traffic.mu.Unlock()
			select {
			case <-traffic.stop:
				return
			case <-ctx.Done():
				traffic.mu.Lock()
				traffic.err = ctx.Err()
				traffic.mu.Unlock()
				return
			case <-time.After(5 * time.Millisecond):
			}
		}
	}()
	return traffic
}

func (traffic *showcaseTraffic) requireProgress(t *testing.T, ctx context.Context, labels ...string) {
	t.Helper()
	traffic.mu.Lock()
	before, completed := make(map[string]map[string]int), len(traffic.completed)
	for _, label := range labels {
		before[label] = make(map[string]int)
		for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodGet} {
			before[label][method] = traffic.hits[label][method]
		}
	}
	traffic.mu.Unlock()
	bounded, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		traffic.mu.Lock()
		err, progressed := traffic.err, len(traffic.completed) > completed
		for _, label := range labels {
			for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodGet} {
				minimum := 1
				if method == http.MethodGet {
					minimum = 2
				}
				progressed = progressed && traffic.hits[label][method] >= before[label][method]+minimum
			}
		}
		traffic.mu.Unlock()
		if err != nil {
			t.Fatal(err)
		}
		if progressed {
			return
		}
		select {
		case <-bounded.Done():
			t.Fatalf("continuous POST, PUT and readback traffic did not pass through every active node %v: %v", labels, bounded.Err())
		case <-traffic.done:
			t.Fatal("continuous traffic stopped before rollout completed")
		case <-ticker.C:
		}
	}
}

func (traffic *showcaseTraffic) finish(t *testing.T) map[string]showcaseTodo {
	t.Helper()
	traffic.once.Do(func() { close(traffic.stop) })
	<-traffic.done
	traffic.mu.Lock()
	defer traffic.mu.Unlock()
	if traffic.err != nil {
		t.Errorf("continuous traffic: %v", traffic.err)
	}
	result := make(map[string]showcaseTodo, len(traffic.completed))
	for id, todo := range traffic.completed {
		result[id] = todo
	}
	return result
}

type showcaseDatabase struct {
	ctx                             context.Context
	observer                        *pgx.Conn
	config                          *pgx.ConnConfig
	name, owner, worker, app, setup string
	environment                     []string
	uuid                            string
}

func newShowcaseDatabase(t *testing.T, ctx context.Context, dsn string) *showcaseDatabase {
	t.Helper()
	admin, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = admin.Close(context.Background()) })
	name := "todo_showcase_" + strings.ReplaceAll(teslrt.UUIDv7(), "-", "")
	db := &showcaseDatabase{ctx: ctx, name: name, owner: name + "_owner", worker: name + "_worker", app: name + "_app", setup: name + "_setup"}
	t.Cleanup(func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if _, err := admin.Exec(cleanup, "drop database if exists "+pgx.Identifier{name}.Sanitize()+" with (force)"); err != nil {
			t.Errorf("showcase database cleanup: %v", err)
		}
		for _, role := range []string{db.worker, db.app, db.setup, db.owner} {
			if _, err := admin.Exec(cleanup, "drop role if exists "+pgx.Identifier{role}.Sanitize()); err != nil {
				t.Errorf("showcase role cleanup: %v", err)
			}
		}
	})
	for _, sql := range []string{
		"create role " + db.owner + " nologin", "create role " + db.worker + " login",
		"create role " + db.app + " login", "create role " + db.setup + " login",
		"grant " + db.owner + " to " + db.setup, "create database " + db.name,
		"grant create on database " + db.name + " to " + db.owner,
		"revoke temporary on database " + db.name + " from public",
		"grant temporary on database " + db.name + " to " + db.owner + "," + db.worker,
	} {
		if _, err := admin.Exec(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	db.config = admin.Config().Copy()
	db.config.Database = db.name
	db.observer, err = pgx.ConnectConfig(ctx, db.config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.observer.Close(context.Background()) })
	for _, sql := range []string{"revoke create on schema public from public", "grant create on schema public to " + db.owner} {
		if _, err := db.observer.Exec(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	db.environment = append(os.Environ(), "TODO_CONTROL_OWNER="+db.owner, "TODO_REQUEST_ROLE="+db.app, "TODO_WORKER_ROLE="+db.worker,
		"TODO_DB_NAME="+db.name, "TODO_DB_PASSWORD="+db.config.Password, "TODO_DB_HOST="+db.config.Host,
		"TODO_DB_PORT="+strconv.Itoa(int(db.config.Port)), "TODO_DDL_CONNECTION=",
		"PGDATABASE="+db.name, "PGHOST="+db.config.Host, "PGPORT="+strconv.Itoa(int(db.config.Port)), "PGPASSWORD="+db.config.Password,
		"TESL_PG_POOL_LEASE_TIMEOUT_MS=60000")
	return db
}

func (db *showcaseDatabase) login(role string) []string {
	return append(append([]string(nil), db.environment...), "TODO_DB_USER="+role, "PGUSER="+role)
}

func (db *showcaseDatabase) install(t *testing.T, binary string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(db.ctx, 10*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, binary, "--schema", "install", "--worker", db.worker, "--request", db.app, "--json")
	command.Env = db.login(db.setup)
	data, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("showcase install: %v\n%s", err, data)
	}
	var result struct {
		Kind              string `json:"kind"`
		DatabaseUUID      string `json:"databaseUuid"`
		InitialVersion    int    `json:"initialVersion"`
		CurrentVersion    int    `json:"currentVersion"`
		InstallingVersion int    `json:"installingVersion"`
	}
	if err := json.Unmarshal(data, &result); err != nil || result.Kind != "schema-install" || result.DatabaseUUID == "" ||
		result.InitialVersion != 1 || result.CurrentVersion != 0 || result.InstallingVersion != 1 {
		t.Fatalf("installer did not preserve fresh V1 origin: %s (%v)", data, err)
	}
	db.uuid = result.DatabaseUUID
	if _, err := db.observer.Exec(db.ctx, "revoke "+db.owner+" from "+db.setup); err != nil {
		t.Fatal(err)
	}
	var isolated bool
	if err := db.observer.QueryRow(db.ctx, `select
 not pg_catalog.has_database_privilege($1,$2,'TEMPORARY') and
 not pg_catalog.has_schema_privilege($1,'public','CREATE') and
 not pg_catalog.has_schema_privilege($1,'todo_app','CREATE')`, db.app, db.name).Scan(&isolated); err != nil || !isolated {
		t.Fatalf("request role unexpectedly has TEMP or schema CREATE: %v (%v)", isolated, err)
	}
}

func (db *showcaseDatabase) status(t *testing.T, binary string, version, current int) {
	t.Helper()
	ctx, cancel := context.WithTimeout(db.ctx, 10*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, binary, "--schema", "status", "--json")
	command.Env = db.login(db.app)
	data, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("read-only showcase status: %v\n%s", err, data)
	}
	var status teslrt.PgMigrationStatus
	if err := json.Unmarshal(data, &status); err != nil || status.Kind != "schema-status" || status.DatabaseUUID != db.uuid ||
		status.BinaryVersion != version || status.CurrentVersion != current || status.HistoryError != "" {
		t.Fatalf("wrong showcase status: %s (%v)", data, err)
	}
}

func (db *showcaseDatabase) requestNode(t *testing.T, binary, label string) *workerLessonProcess {
	t.Helper()
	return startMigrationAppProcess(t, db.ctx, binary, append(db.login(db.app), "PGAPPNAME=tesl-app:"+label), label, "TODO_HTTP_PORT")
}

func (db *showcaseDatabase) workerNode(t *testing.T, binary string, version int) *workerLessonProcess {
	t.Helper()
	label := fmt.Sprintf("todo-schema-v%d", version)
	worker := startMigrationAppProcess(t, db.ctx, binary, append(db.login(db.worker), "PGAPPNAME=tesl-exec:"+label), label, "TODO_HTTP_PORT", "--schema", "worker", "--json")
	workerLessonWait(t, db.ctx, worker, "schema-worker-ready", func() bool {
		for _, line := range bytes.Split(worker.output(), []byte("\n")) {
			var ready struct {
				Kind           string `json:"kind"`
				Database       string `json:"database"`
				DatabaseUUID   string `json:"databaseUuid"`
				BinaryVersion  int    `json:"binaryVersion"`
				CurrentVersion int    `json:"currentVersion"`
			}
			if json.Unmarshal(line, &ready) == nil && ready.Kind == "schema-worker-ready" {
				if ready.Database != "TodoApp.TodoDatabase" || ready.DatabaseUUID != db.uuid || ready.BinaryVersion != version || ready.CurrentVersion != version {
					t.Fatalf("wrong showcase worker publication: %s", line)
				}
				return true
			}
		}
		return false
	})
	worker.assertNoHTTP(t)
	db.status(t, binary, version, version)
	return worker
}

func requireShowcaseReady(t *testing.T, ctx context.Context, client *http.Client, process *workerLessonProcess) {
	t.Helper()
	workerLessonWait(t, ctx, process, "todo HTTP readiness", func() bool {
		data, _, err := showcaseRequest(ctx, client, process.base, http.MethodGet, "/api/health", "", http.StatusOK)
		if err != nil {
			return false
		}
		var health map[string]string
		if err := json.Unmarshal(data, &health); err != nil || len(health) != 1 || health["status"] != "ready" {
			t.Fatalf("todo health response changed: %s (%v)", data, err)
		}
		return true
	})
}

func (db *showcaseDatabase) controlSnapshot(t *testing.T) string {
	t.Helper()
	var snapshot string
	err := db.observer.QueryRow(db.ctx, `select jsonb_build_object(
 'meta',(select jsonb_agg(to_jsonb(m) order by id) from todo_app.tesl_schema_meta m),
 'state',(select jsonb_agg(to_jsonb(s) order by id) from todo_app.tesl_schema_state s),
 'history',(select jsonb_agg(to_jsonb(v) order by version,step,seq) from todo_app.tesl_schema_versions v),
 'intents',(select jsonb_agg(to_jsonb(e) order by version) from todo_app.tesl_schema_expansions e),
 'objects',(select jsonb_agg(to_jsonb(o) order by version,ordinal) from todo_app.tesl_schema_expansion_objects o),
 'indexes',(select jsonb_agg(to_jsonb(i) order by id) from todo_app.tesl_schema_index i),
 'leases',(select jsonb_agg(to_jsonb(l) order by name) from todo_app.tesl_schema_leases l),
 'columns',(select jsonb_agg(to_jsonb(c) order by table_name,ordinal_position) from information_schema.columns c where table_schema='todo_app'))::text`).Scan(&snapshot)
	if err != nil {
		t.Fatal(err)
	}
	return snapshot
}

func (db *showcaseDatabase) requireWaiting(t *testing.T, process *workerLessonProcess) {
	t.Helper()
	before := db.controlSnapshot(t)
	var firstPID int
	var firstSnapshot time.Time
	workerLessonWait(t, db.ctx, process, "read-only request readiness loop", func() bool {
		var pid int
		var completed time.Time
		err := db.observer.QueryRow(db.ctx, `select pid,state_change from pg_stat_activity
 where datname=$1 and usename=$2 and application_name=$3 and state='idle' and query='rollback'`,
			db.name, db.app, "tesl-app:"+process.label).Scan(&pid, &completed)
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
	if after := db.controlSnapshot(t); before != after {
		t.Fatalf("waiting request changed migration control state:\nbefore %s\nafter %s", before, after)
	}
}

func crashShowcaseExpansion(t *testing.T, db *showcaseDatabase, binary string, boundary Event, traffic *showcaseTraffic, labels ...string) {
	t.Helper()
	directory, err := os.MkdirTemp("", "todo-crash-")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = os.RemoveAll(directory) }()
	socket := filepath.Join(directory, "control.sock")
	schedule := NewSchedule(nil)
	if err := schedule.Pause(boundary); err != nil {
		t.Fatal(err)
	}
	controller, err := ListenProcesses(db.ctx, socket, schedule)
	if err != nil {
		t.Fatal(err)
	}
	defer controller.Close()
	worker := startMigrationAppProcess(t, db.ctx, binary,
		append(db.login(db.worker), "TESL_MIGRATION_TEST_SOCKET="+socket, "TESL_MIGRATION_TEST_ACTOR="+boundary.Actor),
		"todo-crash-v4", "TODO_HTTP_PORT", "--schema", "worker", "--json")
	bounded, cancel := context.WithTimeout(db.ctx, 10*time.Second)
	defer cancel()
	if err := schedule.Await(bounded, boundary); err != nil {
		t.Fatalf("V4 worker never reached uncommitted projects DDL: %v\n%s", err, worker.output())
	}
	worker.assertNoHTTP(t)
	// The new independent table may be locked by its uncommitted CREATE, while
	// the old application's todo writes and readbacks must continue on both nodes.
	traffic.requireProgress(t, db.ctx, labels...)
	before := db.controlSnapshot(t)
	worker.once.Do(func() {
		if err := worker.cmd.Process.Kill(); err != nil {
			t.Fatal(err)
		}
		<-worker.done
		_ = worker.log.Close()
		if worker.waitErr == nil {
			t.Fatal("killed V4 worker reported success")
		}
	})
	if err := schedule.Release(boundary); err != nil {
		t.Fatal(err)
	}
	// Joining the killed process prevents another SQL statement from racing this
	// assertion. The committed intent survives; its DDL and object receipt do not.
	var current, intents, objects int
	var tableAbsent bool
	if err := db.observer.QueryRow(db.ctx, `select current,
 (select count(*) from todo_app.tesl_schema_expansions where version=4),
 (select count(*) from todo_app.tesl_schema_expansion_objects where version=4),
 to_regclass('todo_app.projects') is null from todo_app.tesl_schema_state where id=1`).Scan(&current, &intents, &objects, &tableAbsent); err != nil ||
		current != 3 || intents != 1 || objects != 0 || !tableAbsent {
		t.Fatalf("crash did not preserve exact V3 progress and roll back V4 DDL: current=%d intents=%d objects=%d absent=%v (%v)", current, intents, objects, tableAbsent, err)
	}
	if after := db.controlSnapshot(t); before != after {
		t.Fatalf("killed worker published its uncommitted step:\nbefore %s\nafter %s", before, after)
	}
	traffic.requireProgress(t, db.ctx, labels...)
}

func (db *showcaseDatabase) requireRequestPrivileges(t *testing.T) {
	t.Helper()
	config := db.config.Copy()
	config.User = db.app
	connection, err := pgx.ConnectConfig(db.ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = connection.Close(context.Background()) }()
	before := db.controlSnapshot(t)
	if _, err := connection.Exec(db.ctx, "set application_name='tesl-exec:spoofed-worker'"); err != nil {
		t.Fatal(err)
	}
	for _, sql := range []string{
		"create temporary table request_temporary(id integer)",
		"create table public.request_created(id integer)",
		"create table todo_app.request_created(id integer)",
		"alter table todo_app.todos add column request_added text",
		"update todo_app.tesl_schema_state set current=current where id=1",
		"select todo_app.tesl_begin_expansion(8,null,null,null,null,0,true)",
		"select todo_app.tesl_record_expansion_object(8,0,null)",
		"select todo_app.tesl_record_expanded(8)",
		"select todo_app.tesl_register_index('spoof',7,0,'todos','request_created',array['title'],false)",
		"select todo_app.tesl_claim_index('spoof',7,'abi',30000)",
		"select todo_app.tesl_renew_index('spoof',1,30000)",
		"select todo_app.tesl_release_index('spoof',1)",
		"select todo_app.tesl_record_index_state('spoof',1,'valid',null)",
		"set role " + db.worker,
		"set role " + db.owner,
	} {
		_, err := connection.Exec(db.ctx, sql)
		var pgError *pgconn.PgError
		if !errors.As(err, &pgError) || pgError.Code != "42501" {
			t.Fatalf("request role was not denied at the privilege boundary for %q: %v", sql, err)
		}
	}
	if after := db.controlSnapshot(t); before != after {
		t.Fatalf("request privilege probes changed protected state:\nbefore %s\nafter %s", before, after)
	}
}

func (db *showcaseDatabase) todoSnapshot(t *testing.T) string {
	t.Helper()
	var snapshot string
	if err := db.observer.QueryRow(db.ctx, "select coalesce(jsonb_agg(to_jsonb(t) order by id),'[]'::jsonb)::text from todo_app.todos t").Scan(&snapshot); err != nil {
		t.Fatal(err)
	}
	return snapshot
}

func requireShowcaseInvalidInput(t *testing.T, db *showcaseDatabase, client *http.Client, base string) {
	t.Helper()
	before := db.todoSnapshot(t)
	for _, operation := range []struct {
		method, id, body string
		status           int
	}{
		{http.MethodPost, "invalid", `{"title":"   "}`, 400},
		{http.MethodPost, "invalid", `{"title":42}`, 400},
		{http.MethodPost, "invalid", `{"title":"` + strings.Repeat("x", 121) + `"}`, 400},
		{http.MethodPost, "invalid", `{`, 400},
		{http.MethodPost, "invalid", `{}`, 400},
		{http.MethodPut, "seed-pending", `{"title":"  ","completed":true}`, 400},
		{http.MethodPut, "seed-pending", `{"title":"Valid","completed":"wrong"}`, 400},
		{http.MethodPut, "missing", `{"title":"Missing","completed":true}`, 404},
		{http.MethodPost, "seed-pending", `{"title":"Duplicate"}`, 409},
		{http.MethodGet, "invalid", "", 404},
	} {
		if _, _, err := showcaseRequest(db.ctx, client, base, operation.method, "/api/todos/"+operation.id, operation.body, operation.status); err != nil {
			t.Fatal(err)
		}
		if after := db.todoSnapshot(t); before != after {
			t.Fatalf("rejected %s %s mutated stored todos", operation.method, operation.id)
		}
	}
}

func requireShowcaseDeletion(t *testing.T, ctx context.Context, client *http.Client, base string) {
	t.Helper()
	todo := showcaseTodo{ID: "delete-me", Title: "A disposable task"}
	requireShowcaseTodo(t, ctx, client, base, http.MethodPost, todo.ID, `{"title":"A disposable task"}`, todo)
	for attempt := 0; attempt < 2; attempt++ {
		data, _, err := showcaseRequest(ctx, client, base, http.MethodDelete, "/api/todos/"+todo.ID, "", http.StatusOK)
		if err != nil {
			t.Fatal(err)
		}
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(data, &fields); err != nil || len(fields) != 2 || string(fields["id"]) != `"delete-me"` || string(fields["deleted"]) != "true" {
			t.Fatalf("idempotent delete response changed: %s (%v)", data, err)
		}
		if _, _, err := showcaseRequest(ctx, client, base, http.MethodGet, "/api/todos/"+todo.ID, "", http.StatusNotFound); err != nil {
			t.Fatal(err)
		}
	}
}

func requireShowcaseList(t *testing.T, ctx context.Context, client *http.Client, base string, expected map[string]showcaseTodo) {
	t.Helper()
	data, _, err := showcaseRequest(ctx, client, base, http.MethodGet, "/api/todos", "", http.StatusOK)
	if err != nil {
		t.Fatal(err)
	}
	var items []json.RawMessage
	if err := json.Unmarshal(data, &items); err != nil || len(items) != len(expected) {
		t.Fatalf("todo list lost or added retained rows: %d, want %d (%v)", len(items), len(expected), err)
	}
	seen := make(map[string]bool)
	for _, item := range items {
		todo, err := decodeShowcaseTodo(item)
		if err != nil {
			t.Fatal(err)
		}
		want, ok := expected[todo.ID]
		if !ok || seen[todo.ID] || want != todo {
			t.Fatalf("retained todo changed or appeared twice: got %+v, want %+v", todo, want)
		}
		seen[todo.ID] = true
	}
}

func (db *showcaseDatabase) requireFinalStorage(t *testing.T, wantRows int) {
	t.Helper()
	var rows, defaults int
	if err := db.observer.QueryRow(db.ctx, `select count(*),count(*) filter(where
 details is null and due_at is null and project_id is null and priority=0) from todo_app.todos`).Scan(&rows, &defaults); err != nil || rows != wantRows || defaults != wantRows {
		t.Fatalf("old/new writes did not retain every row with nullable/default semantics: rows=%d defaults=%d want=%d (%v)", rows, defaults, wantRows, err)
	}
	var revisions, first, last, abis, contracts int
	var receiptsComplete bool
	if err := db.observer.QueryRow(db.ctx, `select count(*),min(version),max(version),
 count(distinct source_abi),count(distinct stored_value_compatibility),
 bool_and(epoch_preserving and operation_count>0 and operation_count=(
 select count(*) from todo_app.tesl_schema_expansion_objects o where o.version=e.version))
 from todo_app.tesl_schema_expansions e`).Scan(&revisions, &first, &last, &abis, &contracts, &receiptsComplete); err != nil ||
		revisions != 7 || first != 1 || last != 7 || abis != 1 || contracts != 1 || !receiptsComplete {
		t.Fatalf("seven genuine expansion steps were not recorded with complete immutable receipts: revisions=%d range=%d..%d ABI=%d contracts=%d complete=%v (%v)", revisions, first, last, abis, contracts, receiptsComplete, err)
	}
	var projects bool
	if err := db.observer.QueryRow(db.ctx, `select
 exists(select 1 from information_schema.columns where table_schema='todo_app' and table_name='projects' and column_name='description' and is_nullable='YES' and data_type='text') and
 exists(select 1 from pg_catalog.pg_index i join pg_catalog.pg_attribute a on a.attrelid=i.indrelid
 where i.indrelid='todo_app.projects'::regclass and a.attname='archived' and i.indisvalid and i.indisready and
 not i.indisunique and i.indnkeyatts=1 and a.attnum=any(i.indkey))`).Scan(&projects); err != nil || !projects {
		t.Fatalf("projects table, its fresh-table index, or its later nullable field is absent: %v (%v)", projects, err)
	}
}
