//go:build linux

package cli

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestMigrationNativeContractUsesGuardedSourceWriter(t *testing.T) {
	app := realMigrationApp(t)
	writeProjectFile(t, app.Directory, "app.tesl", migrationPostgresApp)
	if _, err := migrationRun(t, app, "generate", "app.tesl", "--new-revision"); err != nil {
		t.Fatal(err)
	}
	after := strings.Replace(migrationSchema, "exposing [String]", "exposing [String, Int]", 1)
	after = strings.Replace(after, "id: String }", "id: String, count: Int }", 1)
	writeProjectFile(t, app.Directory, "schema/notes/v-current.tesl", after)
	migrationPath := filepath.Join(app.Directory, "migrations/notes/v2.tesl")
	original, err := os.ReadFile(migrationPath)
	if err != nil {
		t.Fatal(err)
	}
	offset := strings.Index(string(original), "module ")
	if offset < 0 {
		t.Fatal("missing migration module")
	}
	source := `module NotesSchema.Migrate.V2 exposing [migration]
import Tesl.Prelude exposing [String, Int]
import Tesl.Migration exposing [Migration, Entity(..), Migrated(..)]
import NotesSchema.V1
import NotesSchema.VCurrent
migration = Migration {
 from: NotesSchema.V1, to: NotesSchema.VCurrent, same: [], fixtures: [oldNote],
 entities: { Note: Migrate convert [] }
}
fn convert(old: NotesSchema.V1.Note) -> Migrated NotesSchema.VCurrent.Note =
 Row (NotesSchema.VCurrent.Note { id: old.id, count: 7 })
fn oldNote() -> NotesSchema.V1.Note = NotesSchema.V1.Note { id: "one" }
`
	writeProjectFile(t, app.Directory, "migrations/notes/v2.tesl", string(original[:offset])+source)
	if _, err := migrationRun(t, app, "generate", "app.tesl"); err != nil {
		t.Fatal(err)
	}
	migrationCheck(t, app, "app.tesl", true)
	before := migrationTree(t, app.Directory)
	result, err := migrationRun(t, app, "contract", "app.tesl", "--version", "2", "--manifest-json")
	if err != nil || string(result["operation"]) != `"contract"` || string(result["compilable"]) != "true" {
		t.Fatalf("contract preview %v %s", err, app.Stdout)
	}
	if !reflect.DeepEqual(before, migrationTree(t, app.Directory)) {
		t.Fatal("preview wrote source")
	}
	result, err = migrationRun(t, app, "contract", "app.tesl", "--version", "2")
	if err != nil || string(result["kind"]) != `"migration-source-application"` || string(result["compilable"]) != "true" {
		t.Fatalf("contract source publication %v %s", err, app.Stdout)
	}
	path := filepath.Join(app.Directory, "migrations/notes/v2-contract.tesl")
	contract, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(contract), "Trigger Note") || !strings.Contains(string(contract), "NotNull Note count") {
		t.Fatal("contract omitted source authority")
	}
	migrationCheck(t, app, "app.tesl", true)
	migrationCheck(t, app, "migrations/notes/v2-contract.tesl", true)
	if _, err := migrationRun(t, app, "contract", "app.tesl", "--version", "2"); err == nil {
		t.Fatal("overwrote existing authority")
	}
	unchanged, err := os.ReadFile(path)
	if err != nil || string(unchanged) != string(contract) {
		t.Fatal("refusal changed reviewed contract")
	}
	writeProjectFile(t, app.Directory, "migrations/notes/v2-contract.tesl", strings.Replace(string(contract), "NotNull Note count", "NotNull Note id", 1))
	if result := migrationCheck(t, app, "app.tesl", false); !strings.Contains(result, "MIG022") {
		t.Fatal("stale contract was not diagnosed", result)
	}
}
