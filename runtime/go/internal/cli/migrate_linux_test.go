//go:build linux

package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"tesl.dev/runtime/go/internal/sourceedit"
	"tesl.dev/runtime/go/teslrt"
)

const migrationSchema = "module NotesSchema.VCurrent exposing [Note]\nimport Tesl.Prelude exposing [String]\nentity Note table \"notes\" primaryKey id { id: String }\n"
const migrationApp = "module App exposing []\nimport Tesl.Database exposing [Database, Memory]\nimport NotesSchema.VCurrent\ndatabase Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate, backend: Memory }\n"

const migrationPostgresApp = `module App exposing []
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import NotesSchema.VCurrent
database Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate,
 backend: Postgres (PostgresConfig { dbName: "notes", user: "tesl", password: "", namespace: "notes_app",
 connection: TcpConnection { host: "127.0.0.1", port: 5432 } }) }
`

func realMigrationApp(t *testing.T) *App {
	t.Helper()
	repo := os.Getenv("TESL_REPO_ROOT")
	if repo == "" {
		t.Skip("requires TESL_REPO_ROOT and built compiler")
	}
	compiler := filepath.Join(repo, "compiler", "_build", "default", "bin", "main.exe")
	if _, err := os.Stat(compiler); err != nil {
		t.Fatal(err)
	}
	app, _ := fakeApp(t)
	app.Environment = os.Environ()
	app.Resolver.Getenv = func(key string) string {
		if key == "TESL_COMPILER" {
			return compiler
		}
		if key == "TESL_TOOLCHAIN_ROOT" {
			return ""
		}
		return os.Getenv(key)
	}
	app.Execute = execute
	writeProjectFile(t, app.Directory, "tesl.toml", "")
	writeProjectFile(t, app.Directory, "app.tesl", migrationApp)
	writeProjectFile(t, app.Directory, "schema/notes/v-current.tesl", migrationSchema)
	migrationCheck(t, app, "app.tesl", true)
	migrationCheck(t, app, "schema/notes/v-current.tesl", true)
	return app
}
func migrationCheck(t *testing.T, app *App, path string, ok bool) string {
	t.Helper()
	compiler, err := app.Resolver.Resolve("compiler")
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(compiler, "agent-context", filepath.Join(app.Directory, path))
	cmd.Env = app.Environment
	cmd.Dir = app.Directory
	out, err := cmd.CombinedOutput()
	if (err == nil) != ok {
		t.Fatalf("unexpected judgment: %s %v", out, err)
	}
	return string(out)
}
func migrationTree(t *testing.T, root string) map[string]string {
	t.Helper()
	result := map[string]string{}
	if err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if path == root {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		value := fmt.Sprintf("%o:", info.Mode())
		if info.Mode().IsRegular() {
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			value += string(data)
		}
		result[path] = value
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return result
}
func migrationRun(t *testing.T, app *App, args ...string) (map[string]json.RawMessage, error) {
	t.Helper()
	app.Stdout.(*bytes.Buffer).Reset()
	err := app.Run(context.Background(), append([]string{"migrate"}, args...))
	var result map[string]json.RawMessage
	if jsonErr := json.Unmarshal(app.Stdout.(*bytes.Buffer).Bytes(), &result); jsonErr != nil {
		t.Fatalf("non-JSON response: %s %v", app.Stdout, jsonErr)
	}
	return result, err
}
func TestMigrationNativePlanIsReadOnlyAndCoversCompleteHistory(t *testing.T) {
	app := realMigrationApp(t)
	const source = migrationPostgresApp
	writeProjectFile(t, app.Directory, "app.tesl", source)
	migrationCheck(t, app, "app.tesl", true)
	for version := 1; version <= 3; version++ {
		if version > 1 {
			if _, err := migrationRun(t, app, "generate", "app.tesl", "--new-revision"); err != nil {
				t.Fatal(err)
			}
			schema := strings.Replace(migrationSchema, "import Tesl.Prelude", "import Tesl.Maybe exposing [Maybe]\nimport Tesl.Prelude", 1)
			if version == 2 {
				schema = strings.Replace(schema, "id: String }", "id: String, caption: Maybe String }", 1)
			} else {
				schema = strings.Replace(schema, "id: String }", "id: String, caption: Maybe String, summary: Maybe String }", 1)
			}
			writeProjectFile(t, app.Directory, "schema/notes/v-current.tesl", schema)
			migrationCheck(t, app, "schema/notes/v-current.tesl", false)
			if _, err := migrationRun(t, app, "generate", "app.tesl"); err != nil {
				t.Fatal(err)
			}
			migrationCheck(t, app, "app.tesl", true)
		}
		before := migrationTree(t, app.Directory)
		result, err := migrationRun(t, app, "plan", "app.tesl", "--database", "App.Main")
		if err != nil || string(result["kind"]) != `"migration-plan-preview"` || string(result["executable"]) != "false" {
			t.Fatalf("plan V%d: %v, %s", version, err, app.Stdout)
		}
		var steps []struct {
			Version    int
			Catalog    []teslrt.PgMigrationCatalogTable
			Operations []struct {
				Kind   string
				Column struct{ Name string }
			}
		}
		if err := json.Unmarshal(result["steps"], &steps); err != nil {
			t.Fatal(err)
		}
		if len(steps) != version || steps[version-1].Version != version {
			t.Fatalf("incomplete history: %+v", steps)
		}
		for i, step := range steps {
			if len(step.Catalog) != 1 || step.Catalog[0].Name != "notes" || len(step.Catalog[0].Columns) != i+1 {
				t.Fatalf("wrong retained physical projection at V%d: %+v", i+1, step.Catalog)
			}
			for _, column := range step.Catalog[0].Columns {
				if column.Type != "text" || column.PrimaryKey != (column.Name == "id") || column.Nullable != (column.Name != "id") || column.Default != nil {
					t.Fatalf("column contract changed in transport: %+v", column)
				}
			}
		}
		last := steps[version-1].Operations
		if len(last) != 1 || (version == 1 && last[0].Kind != "create-table") ||
			(version > 1 && (last[0].Kind != "add-column" || last[0].Column.Name != map[int]string{2: "caption", 3: "summary"}[version])) {
			t.Fatalf("wrong V%d delta: %+v", version, last)
		}
		if string(result["initialVersion"]) != "1" {
			t.Fatalf("default initial version: %s", result["initialVersion"])
		}
		generated := filepath.Join(t.TempDir(), "generated")
		if err := app.Run(context.Background(), []string{"compile", "app.tesl", "--out", generated}); err != nil {
			t.Fatal(err)
		}
		compiledBytes, err := os.ReadFile(filepath.Join(generated, "migration-history.json"))
		if err != nil {
			t.Fatal(err)
		}
		var compiled struct {
			Version     int
			Kind        string
			CompilerABI string `json:"compilerAbi"`
			Databases   []struct {
				Database       string
				Family         string
				Namespace      string
				CurrentVersion int
				Origins        []struct {
					InitialVersion int
					Steps          json.RawMessage
					Errors         []json.RawMessage
				}
			}
		}
		if err := json.Unmarshal(compiledBytes, &compiled); err != nil {
			t.Fatal(err)
		}
		var planABI string
		if err := json.Unmarshal(result["compilerAbi"], &planABI); err != nil {
			t.Fatal(err)
		}
		if compiled.Version != 2 || compiled.Kind != "compiled-migration-history" || compiled.CompilerABI != planABI || len(compiled.Databases) != 1 {
			t.Fatalf("invalid compiled history envelope: %s", compiledBytes)
		}
		database := compiled.Databases[0]
		if database.Database != "App.Main" || database.Family != "NotesSchema" || database.Namespace != "notes_app" || database.CurrentVersion != version || len(database.Origins) != version {
			t.Fatalf("compiled history has wrong connection or revision: %s", compiledBytes)
		}
		for origin := 1; origin <= version; origin++ {
			born, err := migrationRun(t, app, "plan", "app.tesl", "--initial-version", fmt.Sprint(origin))
			if err != nil || string(born["initialVersion"]) != fmt.Sprint(origin) || string(born["executable"]) != "false" {
				t.Fatalf("plan initially installed V%d at V%d: %v, %s", origin, version, err, app.Stdout)
			}
			compiledOrigin := database.Origins[origin-1]
			if compiledOrigin.InitialVersion != origin || len(compiledOrigin.Errors) != 0 || bytes.Contains(compiledOrigin.Steps, []byte(`"catalog":`)) {
				t.Fatalf("compiled origin V%d disagrees with the checked source plan: %s", origin, compiledOrigin.Steps)
			}
			history := teslrt.PgCompiledMigrationHistory{Database: database.Database, Family: database.Family, Namespace: database.Namespace,
				CurrentVersion: version, SourceCompilerABI: compiled.CompilerABI, HistoryJSON: string(compiledBytes)}
			runtimePlan, err := history.ExpansionPlan(origin)
			if err != nil {
				t.Fatalf("runtime rejected compiled V%d history from V%d: %v", version, origin, err)
			}
			var installed []struct {
				Version                int
				SnapshotHash, StepHash string
				EpochPreserving        bool
				Catalog                []teslrt.PgMigrationCatalogTable
				Operations             []struct{ Kind string }
			}
			if err := json.Unmarshal(born["steps"], &installed); err != nil {
				t.Fatal(err)
			}
			if len(installed) != version-origin+1 || len(installed[0].Operations) != 1 || installed[0].Operations[0].Kind != "create-table" {
				t.Fatalf("wrong installation baseline: %+v", installed)
			}
			for i, step := range installed {
				if step.Version != origin+i || !reflect.DeepEqual(step.Catalog, steps[origin+i-1].Catalog) {
					t.Fatalf("wrong nullable-only origin projection: %+v", step)
				}
				actual := runtimePlan.Steps[i]
				if actual.Version != step.Version || actual.SnapshotHash != step.SnapshotHash || actual.StepHash != step.StepHash ||
					actual.EpochPreserving != step.EpochPreserving || !reflect.DeepEqual(actual.Catalog, step.Catalog) {
					t.Fatalf("runtime replay differs from compiler projection at V%d: %+v / %+v", step.Version, actual, step)
				}
			}
			if bytes.Equal(result["planHash"], born["planHash"]) != (origin == 1) {
				t.Fatal("plan identity does not distinguish initial installation")
			}
		}
		if _, err := migrationRun(t, app, "plan", "app.tesl", "--initial-version", fmt.Sprint(version+1)); err == nil {
			t.Fatal("accepted a future installation version")
		}
		application, err := os.ReadFile(filepath.Join(app.Directory, "app.tesl"))
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(before, migrationTree(t, app.Directory)) || string(application) != source {
			t.Fatal("plan changed files or migration generation changed the connection owner")
		}
	}
}

func TestMigrationCompiledExpansionAllOperations(t *testing.T) {
	app := realMigrationApp(t)
	writeProjectFile(t, app.Directory, "app.tesl", migrationPostgresApp)
	schema := `module NotesSchema.VCurrent exposing [Note]
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Float exposing [Float]
import Tesl.Maybe exposing [Maybe(..)]
entity Note table "notes" primaryKey id {
 id: String, active: Bool
 index [active] as "active_index"
}
`
	writeProjectFile(t, app.Directory, "schema/notes/v-current.tesl", schema)
	migrationCheck(t, app, "app.tesl", true)
	if _, err := migrationRun(t, app, "generate", "app.tesl"); err != nil {
		t.Fatal(err)
	}
	schema = strings.Replace(schema, "id: String, active: Bool", "id: String, active: Bool, rank: Int, caption: String, ratio: Float, published: Bool, optional: Maybe String", 1)
	schema = strings.Replace(schema, ` index [active] as "active_index"`, " index [active] as \"active_index\"\n unique index [optional] as \"optional_index\"", 1)
	audit := "entity Audit table \"audit\" primaryKey id { id: String }\n"
	schema += audit
	writeProjectFile(t, app.Directory, "schema/notes/v-current.tesl", schema)
	migrationCheck(t, app, "schema/notes/v-current.tesl", false)
	if _, err := migrationRun(t, app, "generate", "app.tesl"); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(app.Directory, "migrations/notes/v2.tesl")
	generated, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	source := string(generated)
	start, end := strings.Index(source, "  entities:"), strings.LastIndex(source, "\n}")
	if start < 0 || end < start {
		t.Fatalf("unexpected generated migration shape: %s", source)
	}
	source = source[:start] + `  entities: { Note: Additive [Default rank 42, Default caption "雪é", Default ratio 1.25, Default published True], Audit: New }` + source[end:]
	source = strings.Replace(source, "import Tesl.Migration", "import Tesl.Prelude exposing [Bool(..)]\nimport Tesl.Migration", 1)
	writeProjectFile(t, app.Directory, "migrations/notes/v2.tesl", source)
	migrationCheck(t, app, "migrations/notes/v2.tesl", true)
	if _, err := migrationRun(t, app, "generate", "app.tesl", "--new-revision"); err != nil {
		t.Fatal(err)
	}
	schema = strings.ReplaceAll(schema, audit, "")
	schema = strings.Replace(schema, `index [active] as "active_index"`, `unique index [active] as "active_unique"`, 1)
	writeProjectFile(t, app.Directory, "schema/notes/v-current.tesl", schema)
	migrationCheck(t, app, "schema/notes/v-current.tesl", false)
	if _, err := migrationRun(t, app, "generate", "app.tesl"); err != nil {
		t.Fatal(err)
	}
	migrationCheck(t, app, "app.tesl", true)
	output := filepath.Join(t.TempDir(), "generated")
	if err := app.Run(context.Background(), []string{"compile", "app.tesl", "--out", output}); err != nil {
		t.Fatal(err)
	}
	historyBytes, err := os.ReadFile(filepath.Join(output, "migration-history.json"))
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for origin := 1; origin <= 3; origin++ {
		preview, err := migrationRun(t, app, "plan", "app.tesl", "--initial-version", fmt.Sprint(origin))
		if err != nil {
			t.Fatal(err)
		}
		var abi string
		if err := json.Unmarshal(preview["compilerAbi"], &abi); err != nil {
			t.Fatal(err)
		}
		history := teslrt.PgCompiledMigrationHistory{Database: "App.Main", Family: "NotesSchema", Namespace: "notes_app", CurrentVersion: 3,
			SourceCompilerABI: abi, HistoryJSON: string(historyBytes)}
		plan, err := history.ExpansionPlan(origin)
		if err != nil {
			t.Fatal(err)
		}
		var expected []struct {
			Version                int
			SnapshotHash, StepHash string
			EpochPreserving        bool
			Catalog                []teslrt.PgMigrationCatalogTable
		}
		if err := json.Unmarshal(preview["steps"], &expected); err != nil {
			t.Fatal(err)
		}
		if len(expected) != len(plan.Steps) {
			t.Fatal("runtime omitted steps")
		}
		for i, step := range plan.Steps {
			want := expected[i]
			if step.Version != want.Version || step.SnapshotHash != want.SnapshotHash || step.StepHash != want.StepHash ||
				step.EpochPreserving != want.EpochPreserving || !reflect.DeepEqual(step.Catalog, want.Catalog) {
				t.Fatalf("compiler/runtime disagreement at origin V%d step V%d: %+v / %+v", origin, step.Version, step, want)
			}
			for _, op := range step.Operations {
				seen[op.Kind] = true
			}
		}
	}
	for _, kind := range []string{"create-table", "add-column", "build-index-concurrently", "retain-index", "retain-table"} {
		if !seen[kind] {
			t.Errorf("fixture did not exercise %s", kind)
		}
	}
	if got, err := os.ReadFile(filepath.Join(app.Directory, "app.tesl")); err != nil || string(got) != migrationPostgresApp {
		t.Fatalf("migration changed the connection owner: %v", err)
	}
}

func TestMigrationCompiledHistorySurvivesWithoutSources(t *testing.T) {
	app := realMigrationApp(t)
	owner := strings.Replace(migrationPostgresApp, "module App exposing []", "module Config exposing [Main]\nimport A", 1)
	writeProjectFile(t, app.Directory, "config.tesl", owner)
	writeProjectFile(t, app.Directory, "a.tesl", "module A exposing []\nimport Config\n")
	writeProjectFile(t, app.Directory, "app.tesl", "module App exposing []\nimport Config\n")
	if output := migrationCheck(t, app, "app.tesl", false); !strings.Contains(output, "import cycle") {
		t.Fatal("connection-module cycle was not refused")
	}
	writeProjectFile(t, app.Directory, "a.tesl", "module A exposing []\nimport B\n")
	writeProjectFile(t, app.Directory, "b.tesl", "module B exposing []\nimport A\n")
	for _, file := range []string{"app.tesl", "config.tesl", "a.tesl", "b.tesl"} {
		migrationCheck(t, app, file, true)
	}
	generated := filepath.Join(t.TempDir(), "generated")
	if err := app.Run(context.Background(), []string{"compile", "app.tesl", "--out", generated}); err != nil {
		t.Fatal(err)
	}
	module, err := os.ReadFile(filepath.Join(generated, "go.mod"))
	if err != nil {
		t.Fatal(err)
	}
	fields := strings.Fields(string(module))
	if len(fields) < 2 || fields[0] != "module" {
		t.Fatal("missing generated module")
	}
	// The pure A/B cycle is lowered independently. An imported application's
	// connection still receives its own compiled history.
	probe := fmt.Sprintf(`package main
import ("encoding/json"; "os"; fixture %q)
func main() {
 history, ok := fixture.MainDatabase.CompiledMigrationHistory()
 if !ok { panic("missing linked migration history") }
 plan, err := history.ExpansionPlan(1)
 if err != nil { panic(err) }
 if len(plan.Steps) != 1 || len(plan.Steps[0].Catalog) != 1 { panic("incomplete standalone plan") }
 if err := json.NewEncoder(os.Stdout).Encode(history); err != nil { panic(err) }
}
`, fields[1]+"/internal/teslmodconfig")
	writeProjectFile(t, generated, "cmd/history-probe/main.go", probe)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	binary := filepath.Join(generated, "history-probe")
	build := exec.CommandContext(ctx, "go", "build", "-race", "-o", binary, "./cmd/history-probe")
	build.Dir, build.Env = generated, app.Environment
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("compile history probe: %v\n%s", err, output)
	}
	if err := os.Remove(filepath.Join(generated, "migration-history.json")); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(app.Directory); err != nil {
		t.Fatal(err)
	}
	output, err := exec.CommandContext(ctx, binary).CombinedOutput()
	if err != nil {
		t.Fatalf("standalone history probe: %v\n%s", err, output)
	}
	var history teslrt.PgCompiledMigrationHistory
	if err := json.Unmarshal(output, &history); err != nil {
		t.Fatal(err)
	}
	if history.Database != "Config.Main" || history.Family != "NotesSchema" || history.Namespace != "notes_app" ||
		history.CurrentVersion != 1 || !strings.HasPrefix(history.SourceCompilerABI, "tesl-source-abi-v1:") || !json.Valid([]byte(history.HistoryJSON)) {
		t.Fatalf("wrong standalone connection history: %+v", history)
	}
}

func TestMigrationNativeFormatterPreservesGeneratedFrozenClosures(t *testing.T) {
	app := realMigrationApp(t)
	schema := strings.Replace(migrationSchema, "id: String }", "id:String}", 1)
	schema = strings.Replace(schema, "import Tesl.Prelude", "import NotesSchema.VCurrent.Private\nimport Tesl.Prelude", 1)
	writeProjectFile(t, app.Directory, "schema/notes/v-current.tesl", schema)
	writeProjectFile(t, app.Directory, "schema/notes/v-current/private.tesl", "module NotesSchema.VCurrent.Private exposing []\nimport Tesl.Prelude exposing [Int]\nfn value()->Int=42\n")
	migrationCheck(t, app, "app.tesl", true)
	if _, err := migrationRun(t, app, "generate", "app.tesl"); err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(app.Directory, "migrations/notes/v2.tesl")
	contents, err := os.ReadFile(root)
	if err != nil {
		t.Fatal(err)
	}
	updated := strings.Replace(string(contents), "import ", "#a preserved comment\nimport NotesSchema.Migrate.V2.Private\nimport ", 1)
	if updated == string(contents) {
		t.Fatal("migration fixture has no import section")
	}
	writeProjectFile(t, app.Directory, "migrations/notes/v2.tesl", updated)
	writeProjectFile(t, app.Directory, "migrations/notes/v2/private.tesl", "module NotesSchema.Migrate.V2.Private exposing []\nimport Tesl.Prelude exposing [Int]\nfn value()->Int=42\n")
	migrationCheck(t, app, "app.tesl", true)
	if _, err := migrationRun(t, app, "generate", "app.tesl", "--new-revision"); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"schema/notes/v1.tesl", "schema/notes/v1/private.tesl", "migrations/notes/v2.tesl", "migrations/notes/v2/private.tesl"} {
		file := filepath.Join(app.Directory, name)
		before, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		if err = app.Run(context.Background(), []string{"fmt", name}); err == nil {
			t.Fatalf("formatted frozen file %s", name)
		}
		if after, err := os.ReadFile(file); err != nil || !bytes.Equal(before, after) {
			t.Fatalf("formatter rewrote %s", name)
		}
		if err = app.Run(context.Background(), []string{"fmt-check", name}); err != nil {
			t.Fatalf("style check requires an illegal rewrite of %s: %v", name, err)
		}
		migrationCheck(t, app, "app.tesl", true)
	}
	if err = app.Run(context.Background(), []string{"fmt", "schema/notes/v-current.tesl"}); err != nil {
		t.Fatal(err)
	}
	if _, err = migrationRun(t, app, "generate", "app.tesl"); err != nil {
		t.Fatal(err)
	}
	migrationCheck(t, app, "app.tesl", true)
}

func TestMigrationNativeCompilerLifecycle(t *testing.T) {
	app := realMigrationApp(t)
	before := migrationTree(t, app.Directory)
	preview, err := migrationRun(t, app, "generate", "./app.tesl", "--manifest-json")
	if err != nil || string(preview["kind"]) != `"migration-source-preview"` {
		t.Fatalf("preview: %v", err)
	}
	if !reflect.DeepEqual(before, migrationTree(t, app.Directory)) {
		t.Fatal("preview wrote sources")
	}
	for _, next := range []bool{false, true} {
		args := []string{"generate", "./app.tesl"}
		if next {
			args = append(args, "--new-revision")
		}
		result, err := migrationRun(t, app, args...)
		if err != nil || string(result["kind"]) != `"migration-source-application"` || string(result["ok"]) != "true" || string(result["compilable"]) != "true" {
			t.Fatalf("native source write: %s %v", app.Stdout, err)
		}
		var report sourceedit.Report
		if err := json.Unmarshal(result["sourceTransaction"], &report); err != nil {
			t.Fatal(err)
		}
		if report.Outcome != "committed" || report.RecoveryRequired || len(report.Written) == 0 {
			t.Fatalf("missing write outcome: %+v", report)
		}
		for _, path := range report.Written {
			relative, _ := filepath.Rel(app.Directory, path)
			migrationCheck(t, app, relative, true)
		}
		migrationCheck(t, app, "app.tesl", true)
		bytes, err := os.ReadFile(filepath.Join(app.Directory, "app.tesl"))
		if err != nil || string(bytes) != migrationApp {
			t.Fatal("native generation changed the application")
		}
		snapshot := migrationTree(t, app.Directory)
		_, err = migrationRun(t, app, "generate", "app.tesl")
		if err != nil || !reflect.DeepEqual(snapshot, migrationTree(t, app.Directory)) {
			t.Fatalf("refresh was not idempotent: %v", err)
		}
	}
}
func TestMigrationNativeWritesDecisionHoles(t *testing.T) {
	app := realMigrationApp(t)
	if _, err := migrationRun(t, app, "generate", "app.tesl"); err != nil {
		t.Fatal(err)
	}
	writeProjectFile(t, app.Directory, "schema/notes/v-current.tesl", strings.Replace(migrationSchema, "id: String }", "id: String, title: String }", 1))
	migrationCheck(t, app, "schema/notes/v-current.tesl", false)
	result, err := migrationRun(t, app, "generate", "app.tesl")
	if err != nil || string(result["ok"]) != "true" || string(result["compilable"]) != "false" || !bytes.Contains(result["diagnostics"], []byte("MIG003")) {
		t.Fatalf("decision was hidden: %s %v", app.Stdout, err)
	}
	if out := migrationCheck(t, app, "app.tesl", false); !strings.Contains(out, "MIG003") {
		t.Fatal("source decision did not block application")
	}
	before := migrationTree(t, app.Directory)
	if _, err := migrationRun(t, app, "generate", "app.tesl", "--new-revision"); err == nil {
		t.Fatal("incomplete revision froze")
	}
	if !reflect.DeepEqual(before, migrationTree(t, app.Directory)) {
		t.Fatal("failed freeze wrote files")
	}
}
func TestMigrationNativeRefusesStaleCompilerResult(t *testing.T) {
	app := realMigrationApp(t)
	real := app.Execute
	var expected map[string]string
	app.Execute = func(ctx context.Context, inv Invocation) error {
		if err := real(ctx, inv); err != nil {
			return err
		}
		writeProjectFile(t, app.Directory, "app.tesl", migrationApp+"# concurrent save\n")
		expected = migrationTree(t, app.Directory)
		return nil
	}
	result, err := migrationRun(t, app, "generate", "app.tesl")
	if err == nil || string(result["ok"]) != "false" || !reflect.DeepEqual(expected, migrationTree(t, app.Directory)) {
		t.Fatalf("stale preview wrote sources: %s %v", app.Stdout, err)
	}
}
func TestMigrationNativeRefusesOpenBuffers(t *testing.T) {
	app := realMigrationApp(t)
	writeProjectFile(t, app.Directory, "buffer.txt", migrationApp)
	before := migrationTree(t, app.Directory)
	result, err := migrationRun(t, app, "generate", "app.tesl", "--project-root", app.Directory, "--overlay", filepath.Join(app.Directory, "app.tesl"), "5", filepath.Join(app.Directory, "buffer.txt"))
	if err == nil || string(result["ok"]) != "false" || !strings.Contains(err.Error(), "open editor") || !reflect.DeepEqual(before, migrationTree(t, app.Directory)) {
		t.Fatalf("open buffer was saved: %s %v", app.Stdout, err)
	}
}
func TestMigrationNativeRecoveryDispatch(t *testing.T) {
	app, _ := fakeApp(t)
	before := migrationTree(t, app.Directory)
	state := filepath.Join(app.Directory, ".tesl-source-edit")
	if err := os.Mkdir(state, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(state, "journal.tmp"), []byte("{"), 0600); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		result, err := migrationRun(t, app, "recover-source", "--project-root", ".")
		if err != nil || string(result["kind"]) != `"migration-source-recovery"` || string(result["ok"]) != "true" {
			t.Fatalf("native recovery: %s %v", app.Stdout, err)
		}
		if !reflect.DeepEqual(before, migrationTree(t, app.Directory)) {
			t.Fatal("recovery changed sources")
		}
	}
	if err := os.Mkdir(state, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(state, "source-000000"), []byte("retain"), 0600); err != nil {
		t.Fatal(err)
	}
	result, err := migrationRun(t, app, "recover-source", "--project-root", app.Directory)
	if err == nil || string(result["ok"]) != "false" {
		t.Fatal("source without journal was removed")
	}
	data, err := os.ReadFile(filepath.Join(state, "source-000000"))
	if err != nil || string(data) != "retain" {
		t.Fatal("recovery removed unknown source")
	}
}
func TestMigrationRecoveryRejectsAliasBeforeParentNormalization(t *testing.T) {
	app, _ := fakeApp(t)
	child := filepath.Join(app.Directory, "child")
	if err := os.Mkdir(child, 0700); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(app.Directory, "alias")
	if err := os.Symlink(child, alias); err != nil {
		t.Fatal(err)
	}
	if _, err := migrationRecoveryRoot(app.Directory, "alias/.."); err == nil {
		t.Fatal("alias hidden by normalization")
	}
	if root, err := migrationRecoveryRoot(app.Directory, "child/.."); err != nil || root != app.Directory {
		t.Fatalf("normal parent path refused: %s %v", root, err)
	}
}
func TestMigrationNativeRejectsCompilerFailureAndMalformedOutput(t *testing.T) {
	for _, sample := range []struct {
		output  string
		failure bool
	}{
		{`{"ok":true,"manifest":null}`, false}, {`{"ok":false}`, false}, {"not JSON", false}, {`{"ok":false,"manifest":null}`, true},
	} {
		t.Run(sample.output, func(t *testing.T) {
			app, calls := fakeApp(t)
			record := app.Execute
			app.Execute = func(ctx context.Context, inv Invocation) error {
				_ = record(ctx, inv)
				if _, err := fmt.Fprint(inv.Stdout, sample.output); err != nil {
					return err
				}
				if sample.failure {
					return errors.New("compiler failed")
				}
				return nil
			}
			before := migrationTree(t, app.Directory)
			if err := app.Run(context.Background(), []string{"migrate", "generate", "app.tesl", "--database", "App.Main", "--", "-file.tesl"}); err == nil {
				t.Fatal("bad compiler response accepted")
			}
			want := []string{"migrate", "generate", "--manifest-json", "app.tesl", "--database", "App.Main", "--", "-file.tesl"}
			if len(*calls) != 1 || !reflect.DeepEqual((*calls)[0].Args, want) {
				t.Fatalf("lost argv boundaries: %+v", *calls)
			}
			if !reflect.DeepEqual(before, migrationTree(t, app.Directory)) {
				t.Fatal("compiler refusal wrote sources")
			}
			if sample.failure && app.Stdout.(*bytes.Buffer).String() != sample.output {
				t.Fatal("compiler error response was hidden")
			}
		})
	}
}
func TestMigrationNativeHelpAndMalformedRecoveryNeverExecute(t *testing.T) {
	for _, args := range [][]string{{"migrate"}, {"migrate", "--help"}, {"migrate", "generate", "--help"}, {"migrate", "recover-source", "--help"}, {"migrate", "recover-source"}, {"migrate", "recover-source", "--project-root", ".", "extra"}} {
		app, calls := fakeApp(t)
		_ = app.Run(context.Background(), args)
		if len(*calls) != 0 {
			t.Fatalf("unexpected compiler invocation: %+v", *calls)
		}
	}
}

func TestMigrationNativeBoundsCapturedCompilerOutput(t *testing.T) {
	app, _ := fakeApp(t)
	chunk := bytes.Repeat([]byte("x"), 64<<10)
	app.Execute = func(_ context.Context, inv Invocation) error {
		// Use the same generic writer copying path as subprocess transport. An
		// accidentally promoted ReaderFrom method must not bypass the byte limit.
		for i := 0; i < 1025; i++ {
			if _, err := io.Copy(inv.Stdout, bytes.NewReader(chunk)); err != nil {
				return err
			}
		}
		return nil
	}
	app.Stdout = io.Discard
	before := migrationTree(t, app.Directory)
	err := app.Run(context.Background(), []string{"migrate", "generate", "app.tesl"})
	if err == nil || !strings.Contains(err.Error(), "exceeds 64 MiB") {
		t.Fatalf("compiler output was not bounded: %v", err)
	}
	if !reflect.DeepEqual(before, migrationTree(t, app.Directory)) {
		t.Fatal("oversized compiler result wrote sources")
	}
}
