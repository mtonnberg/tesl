//go:build linux

package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const migrationEditedSchema = "module NotesSchema.VCurrent exposing [Note]\nimport Tesl.Maybe exposing [Maybe]\nimport Tesl.Prelude exposing [String]\nentity Note table \"notes\" primaryKey id { id: String, title: Maybe String }\n"

func migrationGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	command := exec.Command("git", append([]string{"-c", "user.email=test@example.invalid", "-c", "user.name=test"}, args...)...)
	command.Dir = dir
	if out, err := command.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// A project whose V2 is finished and committed, with the next schema change
// already saved in v-current before the wizard runs.
func migrationEditedFirstProject(t *testing.T, tracked bool) *App {
	t.Helper()
	app := realMigrationApp(t)
	writeProjectFile(t, app.Directory, "app.tesl", migrationPostgresApp)
	if _, err := migrationRun(t, app, "generate", "app.tesl"); err != nil {
		t.Fatal(err)
	}
	if tracked {
		if _, err := exec.LookPath("git"); err != nil {
			t.Skip("requires git")
		}
		migrationGit(t, app.Directory, "init", "-q")
		migrationGit(t, app.Directory, "add", "-A")
		migrationGit(t, app.Directory, "commit", "-qm", "V2")
	}
	writeProjectFile(t, app.Directory, "schema/notes/v-current.tesl", migrationEditedSchema)
	app.Stdout.(*bytes.Buffer).Reset()
	return app
}

func migrationAssertStartedWithEdits(t *testing.T, app *App) {
	t.Helper()
	current, err := os.ReadFile(filepath.Join(app.Directory, "schema/notes/v-current.tesl"))
	if err != nil || string(current) != migrationEditedSchema {
		t.Fatalf("edits were not reapplied: %q %v", current, err)
	}
	frozen, err := os.ReadFile(filepath.Join(app.Directory, "schema/notes/v2.tesl"))
	if err != nil || strings.Contains(string(frozen), "title") || !strings.Contains(string(frozen), "module NotesSchema.V2") {
		t.Fatalf("V2 was not frozen from its recorded source: %q %v", frozen, err)
	}
	if _, err := os.Stat(filepath.Join(app.Directory, "migrations/notes/v3.tesl")); err != nil {
		t.Fatal("V3 was not started")
	}
	if entries, err := os.ReadDir(filepath.Join(app.Directory, ".tesl-stuff", "migrate-edits")); err == nil && len(entries) > 0 {
		t.Fatal("backup of reapplied edits was retained")
	}
}

func TestMigrationWizardStartsNextRevisionFromEditedCurrent(t *testing.T) {
	app := migrationEditedFirstProject(t, true)
	input := &migrationScriptedInput{steps: []func() string{func() string {
		output := app.Stdout.(*bytes.Buffer).String()
		if !strings.Contains(output, "start V3 with these edits") || strings.Contains(output, "MIG001") {
			t.Fatalf("wizard did not offer to keep the edits as V3: %s", output)
		}
		return "\n"
	}}}
	app.Stdin = input
	if err := app.Run(context.Background(), []string{"migrate", "app.tesl"}); err != nil {
		t.Fatalf("edit-first wizard: %v\n%s", err, app.Stdout)
	}
	migrationAssertStartedWithEdits(t, app)
	output := app.Stdout.(*bytes.Buffer).String()
	for _, want := range []string{"restored V2 source from the git index (SHA-256 verified)", "Reapplied your saved edits", "Application checks passed", "add column"} {
		if !strings.Contains(output, want) {
			t.Errorf("missing %q in %s", want, output)
		}
	}
	migrationCheck(t, app, "app.tesl", true)
}

func TestMigrationWizardFoldsEditedCurrentIntoDraftOnRequest(t *testing.T) {
	app := migrationEditedFirstProject(t, true)
	app.Stdin = &migrationScriptedInput{steps: []func() string{func() string { return "r\n" }}}
	if err := app.Run(context.Background(), []string{"migrate", "app.tesl"}); err != nil {
		t.Fatalf("fold into draft: %v\n%s", err, app.Stdout)
	}
	if _, err := os.Stat(filepath.Join(app.Directory, "migrations/notes/v3.tesl")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("folding the edits into V2 started V3")
	}
	migrationCheck(t, app, "app.tesl", true)
}

func TestMigrationEditedCurrentWithoutRecordedSourceChangesNothing(t *testing.T) {
	app := migrationEditedFirstProject(t, false)
	before := migrationTree(t, app.Directory)
	app.Stdin = &migrationScriptedInput{steps: []func() string{func() string { return "\n" }}}
	err := app.Run(context.Background(), []string{"migrate", "app.tesl"})
	if err == nil || !strings.Contains(err.Error(), "No files were changed") {
		t.Fatalf("untracked edit-first start: %v", err)
	}
	if !reflect.DeepEqual(before, migrationTree(t, app.Directory)) {
		t.Fatal("refused edit-first start changed files")
	}
}

func TestMigrationGenerateNewRevisionKeepsEditedCurrent(t *testing.T) {
	app := migrationEditedFirstProject(t, true)
	result, err := migrationRun(t, app, "generate", "app.tesl", "--new-revision")
	if err != nil {
		t.Fatalf("generate --new-revision: %v\n%s", err, app.Stdout)
	}
	var reapplied []string
	if err := json.Unmarshal(result["editsReapplied"], &reapplied); err != nil || len(reapplied) != 1 || !strings.HasSuffix(reapplied[0], "schema/notes/v-current.tesl") {
		t.Fatalf("missing reapplied edits: %s", result["editsReapplied"])
	}
	migrationAssertStartedWithEdits(t, app)
	if !strings.Contains(app.Stderr.(*bytes.Buffer).String(), "Keeping them as revision V3") {
		t.Fatalf("progress was not reported on stderr: %s", app.Stderr)
	}
}
