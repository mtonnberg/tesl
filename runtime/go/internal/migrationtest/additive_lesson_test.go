package migrationtest

import (
	"bytes"
	"context"
	"encoding/json"
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
	"tesl.dev/runtime/go/internal/cli"
	"tesl.dev/runtime/go/teslrt"
)

// INV-ADDITIVE-READ, INV-ADDITIVE-WRITE, INV-CATALOG-EVIDENCE; TR-BOOT-EXPAND, TR-READ, TR-WRITE.
// This lesson runs the actual generated main and HTTP server. Its only schema
// setup is the production operator installer; application startup does the DDL.
func TestCompiledAdditiveLessonRetainsRows(t *testing.T) {
	testCompiledAdditiveLesson(t, false, Event{})
}

// INV-ADDITIVE-READ, INV-ADDITIVE-WRITE, INV-CATALOG-EVIDENCE; TR-BOOT-EXPAND, TR-READ, TR-WRITE.
func TestCompiledMigrationCompilerUpgradeRetainsRows(t *testing.T) {
	testCompiledAdditiveLesson(t, true, Event{Name: "expansion-after-commit", Actor: "compiler-a", Occurrence: 1})
}

func testCompiledAdditiveLesson(t *testing.T, upgrade bool, interruption Event) {
	t.Helper()
	dsn := os.Getenv("TESL_MIGRATION_TEST_DSN")
	if dsn == "" {
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
	defer cancel()
	project := t.TempDir()
	const entry = "lesson83-additive-migrations.tesl"
	const child = "schema/additive-notes/v-current/notes.tesl"
	for _, name := range []string{entry, child, "schema/additive-notes/v-current.tesl"} {
		contents, err := os.ReadFile(filepath.Join(root, "example/learn", name))
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(project, name)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, contents, 0600); err != nil {
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
	var compatibleCompiler, incompatibleCompiler string
	if upgrade {
		compiler, compatibleCompiler, incompatibleCompiler = buildMigrationCompilerVariants(t, ctx, root)
	}
	baselineCompiler := compiler
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
			t.Fatalf("lesson command: %v\n%s", err, &output)
		}
	}
	check := func(name string) {
		t.Helper()
		cmd := exec.CommandContext(ctx, compiler, "agent-context", filepath.Join(project, name))
		cmd.Dir = project
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("lesson diagnostics: %v\n%s", err, out)
		}
	}
	binaries, versions := map[int]string{}, map[int]int{}
	type revision struct {
		key, version    int
		compiler, field string
	}
	revisions := []revision{{1, 1, compiler, ""}, {2, 2, compiler, "category"}}
	if !upgrade {
		revisions = append(revisions, revision{3, 3, compiler, "indexed"})
	}
	if upgrade {
		// C has no frozen source yet: its freshly compiled V1 is valid in
		// isolation, but cannot interpret a database established by A.
		revisions = append([]revision{{5, 1, incompatibleCompiler, ""}}, revisions...)
		revisions = append(revisions, revision{6, 3, compiler, "archived"}, revision{3, 3, compatibleCompiler, ""}, revision{4, 4, compatibleCompiler, "label"})
	}
	var frozenByA map[string][]byte
	for _, revision := range revisions {
		version := revision.version
		compiler = revision.compiler
		if revision.field != "" {
			command("migrate", "generate", entry, "--new-revision")
			path := filepath.Join(project, child)
			source, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			text := string(source)
			beforeFields, beforeValue := "  title: String ::: ValidTitle title\n", "Note { id: id, title: title"
			if version >= 3 {
				beforeFields += "  category: Maybe String\n"
				beforeValue += ", category: Nothing"
			}
			if version == 4 {
				beforeFields += "  archived: Maybe String\n"
				beforeValue += ", archived: Nothing"
			}
			for _, edit := range [][2]string{{beforeFields + "}", beforeFields + "  " + revision.field + ": Maybe String\n}"}, {beforeValue + " }", beforeValue + ", " + revision.field + ": Nothing }"}} {
				if strings.Count(text, edit[0]) != 1 {
					t.Fatalf("lesson edit target changed: %q", edit[0])
				}
				text = strings.Replace(text, edit[0], edit[1], 1)
			}
			if revision.field == "indexed" {
				for _, edit := range [][2]string{
					{"  indexed: Maybe String\n", "  indexed: Maybe Bool\n  index [indexed]\n"},
					{"import Tesl.Prelude exposing [Int, String]", "import Tesl.Prelude exposing [Bool, Int, String]"},
				} {
					if strings.Count(text, edit[0]) != 1 {
						t.Fatalf("Embedded index edit target changed: %q", edit[0])
					}
					text = strings.Replace(text, edit[0], edit[1], 1)
				}
			}
			if err := os.WriteFile(path, []byte(text), 0600); err != nil {
				t.Fatal(err)
			}
			// A schema edit invalidates its unrefreshed header. The command resolves it.
			command("migrate", "generate", entry)
			check(child)
			check(fmt.Sprintf("migrations/additive-notes/v%d.tesl", version))
		}
		if upgrade && revision.key == 3 {
			// Frozen schema bytes are an independent guard, even if a new
			// compiler says it supports the same stored-value contract.
			assertMigrationBuildRefuses(t, ctx, incompatibleCompiler, project, entry)
			assertFrozenMigrationSources(t, project, frozenByA)
			assertChangedFrozenSourceRefuses(t, ctx, compiler, project, entry, frozenByA)
		}
		check(entry)
		generated := filepath.Join(t.TempDir(), fmt.Sprintf("go-v%d", version))
		command("compile", entry, "--out", generated)
		// The same source API assertions must compile and run in both revisions.
		unit := exec.CommandContext(ctx, "go", "test", "-race", "-count=1", "./internal/teslmodlesson83additivemigrations")
		unit.Dir = generated
		if out, err := unit.CombinedOutput(); err != nil {
			t.Fatalf("lesson V%d API/unit tests: %v\n%s", version, err, out)
		}
		binary := filepath.Join(t.TempDir(), fmt.Sprintf("app-v%d", version))
		build := exec.CommandContext(ctx, "go", "build", "-race", "-o", binary, "./cmd/app")
		build.Dir = generated
		if out, err := build.CombinedOutput(); err != nil {
			t.Fatalf("lesson V%d application: %v\n%s", version, err, out)
		}
		binaries[revision.key], versions[revision.key] = binary, version
		if upgrade && revision.key == 2 || !upgrade && revision.key == 3 {
			interrupted := filepath.Join(t.TempDir(), fmt.Sprintf("app-v%d-interrupted", version))
			build := exec.CommandContext(ctx, "go", "build", "-race", "-tags=tesl_migration_test", "-o", interrupted, "./cmd/app")
			build.Dir = generated
			if out, err := build.CombinedOutput(); err != nil {
				t.Fatalf("instrumented interruption application: %v\n%s", err, out)
			}
			binaries[7] = interrupted
		}
		if revision.key == 6 {
			frozenByA = frozenMigrationSources(t, project)
		}
		if revision.key == 4 {
			assertFrozenMigrationSources(t, project, frozenByA)
		}
		current, err := os.ReadFile(filepath.Join(project, entry))
		if err != nil || !bytes.Equal(original, current) {
			t.Fatal("migration changed the application, handlers or API tests")
		}
		if err := os.RemoveAll(generated); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.RemoveAll(project); err != nil {
		t.Fatal(err)
	}
	if upgrade {
		t.Run("pending-compatible-worker-requests", func(t *testing.T) {
			testPendingCompatibleCompilerRequests(t, ctx, root, baselineCompiler, compatibleCompiler)
		})
	}
	admin, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = admin.Close(context.Background()) }()
	database := "lesson_" + strings.ReplaceAll(teslrt.UUIDv7(), "-", "")
	roles := teslrt.PgMigrationControlRoles{Owner: database + "_owner", Worker: database + "_worker"}
	setupRole := database + "_setup"
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		_, _ = admin.Exec(cleanup, "drop database if exists "+pgx.Identifier{database}.Sanitize()+" with (force)")
		_, _ = admin.Exec(cleanup, "drop role if exists "+pgx.Identifier{roles.Worker}.Sanitize())
		_, _ = admin.Exec(cleanup, "drop role if exists "+pgx.Identifier{setupRole}.Sanitize())
		_, _ = admin.Exec(cleanup, "drop role if exists "+pgx.Identifier{roles.Owner}.Sanitize())
	}()
	for _, sql := range []string{"create role " + roles.Owner + " nologin", "create role " + roles.Worker + " login", "create role " + setupRole + " login",
		"grant " + roles.Owner + " to " + setupRole, "create database " + database, "grant create on database " + database + " to " + roles.Owner} {
		if _, err := admin.Exec(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	config := admin.Config().Copy()
	config.Database = database
	installer, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = installer.Close(context.Background()) }()
	if _, err := installer.Exec(ctx, "grant create on schema public to "+roles.Owner); err != nil {
		t.Fatal(err)
	}
	applicationEnvironment := append(os.Environ(), "NOTES_CONTROL_OWNER="+roles.Owner, "NOTES_DB_NAME="+database, "NOTES_DB_USER="+roles.Worker,
		"NOTES_DB_PASSWORD="+config.Password, "NOTES_DB_HOST="+config.Host, "NOTES_DB_PORT="+strconv.Itoa(int(config.Port)),
		"PGUSER="+roles.Worker, "PGDATABASE="+database, "PGHOST="+config.Host, "PGPORT="+strconv.Itoa(int(config.Port)), "PGPASSWORD="+config.Password)
	// Exercise the actual compiled installer with a non-administrative login
	// whose only temporary authority is the operator's control-owner grant.
	commandCtx, stopCommand := context.WithTimeout(ctx, 5*time.Second)
	install := exec.CommandContext(commandCtx, binaries[1], "--schema", "install", "--worker", roles.Worker, "--json")
	install.Env = append(append([]string(nil), applicationEnvironment...), "NOTES_DB_USER="+setupRole, "PGUSER="+setupRole)
	installOutput, installErr := install.CombinedOutput()
	stopCommand()
	if installErr != nil {
		t.Fatalf("standalone installer: %v\n%s", installErr, installOutput)
	}
	var installation struct {
		Kind              string `json:"kind"`
		InitialVersion    int    `json:"initialVersion"`
		CurrentVersion    int    `json:"currentVersion"`
		InstallingVersion int    `json:"installingVersion"`
	}
	if err := json.Unmarshal(installOutput, &installation); err != nil || installation.Kind != "schema-install" ||
		installation.InitialVersion != 1 || installation.CurrentVersion != 0 || installation.InstallingVersion != 1 {
		t.Fatalf("standalone installer started the application or chose the wrong origin: %s, %v", installOutput, err)
	}
	if _, err := installer.Exec(ctx, "revoke "+roles.Owner+" from "+setupRole); err != nil {
		t.Fatal(err)
	}
	status := func(version, current int) teslrt.PgMigrationStatus {
		t.Helper()
		commandCtx, stop := context.WithTimeout(ctx, 5*time.Second)
		defer stop()
		command := exec.CommandContext(commandCtx, binaries[version], "--schema", "status", "--database", "Lesson83AdditiveMigrations.NoteDatabase", "--json")
		command.Env = applicationEnvironment
		text, err := command.CombinedOutput()
		if err != nil {
			t.Fatalf("standalone schema command: %v\n%s", err, text)
		}
		var report teslrt.PgMigrationStatus
		if err := json.Unmarshal(text, &report); err != nil || report.Kind != "schema-status" || report.BinaryVersion != versions[version] || report.CurrentVersion != current || report.HistoryError != "" {
			t.Fatalf("standalone status misreported or performed an expansion: %s, %v", text, err)
		}
		return report
	}
	status(1, 0) // Operator command reports installation without starting the app.
	client := &http.Client{Timeout: time.Second}
	start := func(version int) (string, func()) {
		t.Helper()
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		address := listener.Addr().String()
		_, port, err := net.SplitHostPort(address)
		if err != nil {
			t.Fatal(err)
		}
		if err := listener.Close(); err != nil {
			t.Fatal(err)
		}
		log, err := os.CreateTemp(t.TempDir(), "app-*.log")
		if err != nil {
			t.Fatal(err)
		}
		cmd := exec.CommandContext(ctx, binaries[version])
		cmd.Env = append(append([]string(nil), applicationEnvironment...), "NOTES_HTTP_PORT="+port)
		cmd.Stdout = log
		cmd.Stderr = log
		if err := cmd.Start(); err != nil {
			_ = log.Close()
			t.Fatal(err)
		}
		done := make(chan error, 1)
		go func() { done <- cmd.Wait() }()
		var once sync.Once
		stop := func() {
			once.Do(func() {
				_ = cmd.Process.Signal(os.Interrupt)
				err := <-done
				_ = log.Close()
				if err != nil {
					data, _ := os.ReadFile(log.Name())
					t.Errorf("V%d process: %v\n%s", version, err, data)
				}
			})
		}
		// These must run before the deferred database cleanup, including failure paths.
		ready := false
		defer func() {
			if !ready {
				stop()
			}
		}()
		base := "http://" + address
		for {
			select {
			case failure := <-done:
				done <- failure
				data, _ := os.ReadFile(log.Name())
				t.Fatalf("V%d startup: %v\n%s", version, failure, data)
			case <-ctx.Done():
				t.Fatal(ctx.Err())
			default:
			}
			req, err := http.NewRequestWithContext(ctx, "GET", base+"/notes/readiness", nil)
			if err != nil {
				t.Fatal(err)
			}
			response, err := client.Do(req)
			if err == nil {
				_ = response.Body.Close()
				if response.StatusCode == 404 {
					ready = true
					return base, stop
				}
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
	request := func(base, method, id, body string, want int, title string) {
		t.Helper()
		req, err := http.NewRequestWithContext(ctx, method, base+"/notes/"+id, strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Content-Type", "application/json")
		res, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = res.Body.Close() }()
		data, err := io.ReadAll(io.LimitReader(res.Body, 4096))
		if err != nil {
			t.Fatal(err)
		}
		if res.StatusCode != want {
			t.Fatalf("%s %s: %d %s", method, id, res.StatusCode, data)
		}
		if want == 200 {
			var got map[string]string
			if err := json.Unmarshal(data, &got); err != nil || len(got) != 2 || got["id"] != id || got["title"] != title {
				t.Fatalf("public API changed: %s (%v)", data, err)
			}
		}
	}
	old, stopOld := start(1)
	defer stopOld()
	request(old, "POST", "retained", `{"title":"  First note  "}`, 200, "First note")
	status(2, 1) // The newer command does not run its pending expansion.
	if upgrade {
		interruptLessonExpansion(t, ctx, binaries[7], applicationEnvironment, interruption)
		assertMigrationStartupRefuses(t, ctx, binaries[3], applicationEnvironment, installer, "abi")
	}
	current, stopCurrent := start(2)
	defer stopCurrent()
	status(1, 2) // An older operator binary can inspect a later additive epoch.
	request(current, "GET", "retained", "", 200, "First note")
	var nullable bool
	if err := installer.QueryRow(ctx, "select category is null from additive_notes.lesson_migration_notes where id='retained'").Scan(&nullable); err != nil || !nullable {
		t.Fatalf("old row was not retained with SQL NULL: %v %v", nullable, err)
	}
	request(current, "POST", "new", `{"title":"New note"}`, 200, "New note")
	request(old, "GET", "new", "", 200, "New note")
	request(old, "POST", "during-roll", `{"title":"Old writer"}`, 200, "Old writer")
	request(current, "GET", "during-roll", "", 200, "Old writer")
	stopOld()
	restarted, stopRestarted := start(1)
	defer stopRestarted()
	request(restarted, "GET", "retained", "", 200, "First note")
	request(restarted, "GET", "new", "", 200, "New note")
	request(restarted, "POST", "restarted", `{"title":"Restarted writer"}`, 200, "Restarted writer")
	request(current, "GET", "restarted", "", 200, "Restarted writer")
	for i, base := range []string{current, restarted} {
		id := fmt.Sprintf("invalid-%d", i)
		request(base, "POST", id, `{"title":"   "}`, 400, "")
		request(base, "GET", id, "", 404, "")
		request(base, "POST", id, `{"title":42}`, 400, "")
		request(base, "GET", id, "", 404, "")
	}
	var rows, nulls int
	if err := installer.QueryRow(ctx, "select count(*),count(*) filter(where category is null) from additive_notes.lesson_migration_notes").Scan(&rows, &nulls); err != nil || rows != 4 || nulls != 4 {
		t.Fatalf("retained rows or nullable defaults changed: %d %d %v", rows, nulls, err)
	}
	if !upgrade {
		testCompiledEmbeddedIndexLifecycle(t, ctx, installer, binaries[3], binaries[7], applicationEnvironment, current, restarted)
	}
	if upgrade {
		third, stopThird := start(6)
		defer stopThird()
		request(third, "GET", "retained", "", 200, "First note")
		before := status(6, 3)
		after := status(3, 3)
		if before.SourceCompilerABI == after.SourceCompilerABI || before.StoredValueCompatibility != after.StoredValueCompatibility || after.StoredValueCompatibility == "" {
			t.Fatalf("fixture must use distinct real builds with the same compatibility contract: A=%+v B=%+v", before, after)
		}
		upgraded, stopUpgraded := start(3)
		defer stopUpgraded()
		request(upgraded, "GET", "retained", "", 200, "First note")
		request(upgraded, "POST", "compiler-b", `{"title":"Compiler B writer"}`, 200, "Compiler B writer")
		request(current, "GET", "compiler-b", "", 200, "Compiler B writer")
		newRevision, stopNewRevision := start(4)
		defer stopNewRevision()
		status(1, 4)
		status(2, 4)
		status(3, 4)
		request(newRevision, "GET", "retained", "", 200, "First note")
		request(newRevision, "POST", "compiler-b-v4", `{"title":"New revision"}`, 200, "New revision")
		request(current, "GET", "compiler-b-v4", "", 200, "New revision")
		stopCurrent()
		oldCompilerRestart, stopOldCompilerRestart := start(2)
		defer stopOldCompilerRestart()
		request(oldCompilerRestart, "GET", "compiler-b-v4", "", 200, "New revision")
		request(oldCompilerRestart, "POST", "compiler-a-restart", `{"title":"Still compatible"}`, 200, "Still compatible")
		request(newRevision, "GET", "compiler-a-restart", "", 200, "Still compatible")
		for i, base := range []string{upgraded, newRevision, oldCompilerRestart} {
			id := fmt.Sprintf("compiler-invalid-%d", i)
			for _, body := range []string{`{"title":"   "}`, `{"title":42}`, `{"title":"` + strings.Repeat("a", 81) + `"}`} {
				request(base, "POST", id, body, 400, "")
				request(base, "GET", id, "", 404, "")
			}
		}
		assertMigrationBuildProvenance(t, ctx, installer, before.SourceCompilerABI, after.SourceCompilerABI, after.StoredValueCompatibility)
		assertMigrationStartupRefuses(t, ctx, binaries[5], applicationEnvironment, installer, "stored-value")
		if err := installer.QueryRow(ctx, "select count(*),count(*) filter(where category is null and archived is null and label is null) from additive_notes.lesson_migration_notes").Scan(&rows, &nulls); err != nil || rows != 7 || nulls != 7 {
			t.Fatalf("compiler upgrade changed retained rows or omission defaults: %d %d %v", rows, nulls, err)
		}
	}
}
