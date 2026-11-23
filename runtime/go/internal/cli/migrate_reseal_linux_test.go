//go:build linux

package cli

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// A compiler whose stored-value semantics changed refuses a sealed history
// until `tesl migrate reseal` re-checks it and re-records its seals
// through the guarded source writer.
func TestMigrationNativeResealReRecordsSeals(t *testing.T) {
	app := realMigrationApp(t)
	writeProjectFile(t, app.Directory, "app.tesl", migrationPostgresApp)
	if _, err := migrationRun(t, app, "generate", "app.tesl", "--new-revision"); err != nil {
		t.Fatal(err)
	}
	schema := strings.Replace(migrationSchema, "import Tesl.Prelude", "import Tesl.Maybe exposing [Maybe]\nimport Tesl.Prelude", 1)
	writeProjectFile(t, app.Directory, "schema/notes/v-current.tesl", strings.Replace(schema, "id: String }", "id: String, caption: Maybe String }", 1))
	if _, err := migrationRun(t, app, "generate", "app.tesl"); err != nil {
		t.Fatal(err)
	}
	migrationCheck(t, app, "app.tesl", true)

	// The same stdlib with one more declaration: different stored-value semantics.
	stdlib := t.TempDir()
	repo := os.Getenv("TESL_REPO_ROOT")
	for _, name := range []string{"civil-time.tesl", "either.tesl", "list-prim.tesl", "list.tesl"} {
		data, err := os.ReadFile(filepath.Join(repo, "tesl", name))
		if err != nil {
			t.Fatal(err)
		}
		if name == "either.tesl" {
			data = append(data, []byte("\nfn revalidationProbe(x: Int) -> Int = x\n")...)
		}
		writeProjectFile(t, stdlib, name, string(data))
	}
	app.Environment = append(app.Environment, "TESL_STDLIB_DIR="+stdlib)
	if out := migrationCheck(t, app, "app.tesl", false); !strings.Contains(out, "MIG013") || !strings.Contains(out, "tesl migrate reseal") {
		t.Fatalf("changed semantics were not diagnosed with the command: %s", out)
	}
	before := migrationTree(t, app.Directory)
	result, err := migrationRun(t, app, "reseal", "app.tesl", "--manifest-json")
	if err != nil || string(result["operation"]) != `"reseal"` {
		t.Fatalf("reseal preview %v %s", err, app.Stdout)
	}
	if !reflect.DeepEqual(before, migrationTree(t, app.Directory)) {
		t.Fatal("preview wrote source")
	}
	result, err = migrationRun(t, app, "reseal", "app.tesl")
	if err != nil || string(result["kind"]) != `"migration-source-application"` || string(result["ok"]) != "true" {
		t.Fatalf("reseal publication %v %s", err, app.Stdout)
	}
	migrationCheck(t, app, "app.tesl", true)
	if _, err := migrationRun(t, app, "reseal", "app.tesl"); err == nil {
		t.Fatal("a second re-seal found something to re-record")
	}
}
