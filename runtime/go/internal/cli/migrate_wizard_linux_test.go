//go:build linux

package cli

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"
)

// Each completed terminal line represents a user saving files and pressing
// Enter. Callbacks run only when the wizard actually asks for the next answer.
type migrationScriptedInput struct {
	steps   []func() string
	pending string
}

func (input *migrationScriptedInput) Read(out []byte) (int, error) {
	if input.pending == "" {
		if len(input.steps) == 0 {
			return 0, io.EOF
		}
		step := input.steps[0]
		input.steps = input.steps[1:]
		input.pending = step()
	}
	n := copy(out, input.pending)
	input.pending = input.pending[n:]
	return n, nil
}

func TestMigrationWizardNativeFullApplicationKeepsHandlersUnchanged(t *testing.T) {
	migrationWizardFullApplication(t, false)
}

func TestMigrationWizardNativeQualifiedFullApplicationGenerateRefreshResume(t *testing.T) {
	migrationWizardFullApplication(t, true)
}

func migrationWizardFullApplication(t *testing.T, qualified bool) {
	t.Helper()
	app := realMigrationApp(t)
	repo := os.Getenv("TESL_REPO_ROOT")
	schemaPath := "schema/worker-notes/v-current/notes.tesl"
	if qualified {
		schemaPath = "schema/todo/v-current/notes.tesl"
	}
	for _, path := range []string{"lesson84-worker-migrations.tesl", "schema/worker-notes/v-current.tesl", "schema/worker-notes/v-current/notes.tesl"} {
		contents, err := os.ReadFile(filepath.Join(repo, "example", "learn", path))
		if err != nil {
			t.Fatal(err)
		}
		source := string(contents)
		if qualified {
			source = strings.ReplaceAll(source, "WorkerNotesSchema", "Schema.Todo")
			path = strings.Replace(path, "schema/worker-notes/", "schema/todo/", 1)
		}
		writeProjectFile(t, app.Directory, path, source)
	}
	entry := "lesson84-worker-migrations.tesl"
	before, err := os.ReadFile(filepath.Join(app.Directory, entry))
	if err != nil {
		t.Fatal(err)
	}
	schema := filepath.Join(app.Directory, schemaPath)
	input := &migrationScriptedInput{steps: []func() string{func() string {
		original, err := os.ReadFile(schema)
		if err != nil {
			t.Fatal(err)
		}
		changed := strings.Replace(string(original), "  title: String ::: ValidTitle title\n}", "  title: String ::: ValidTitle title\n  category: Maybe String\n}", 1)
		changed = strings.Replace(changed, "Note { id: id, title: title }", "Note { id: id, title: title, category: Nothing }", 1)
		if changed == string(original) {
			t.Fatal("lesson schema fixture did not change")
		}
		if err := os.WriteFile(schema, []byte(changed), 0600); err != nil {
			t.Fatal(err)
		}
		return "\n"
	}}}
	app.Stdin = input
	if err := app.Run(context.Background(), []string{"migrate", entry}); err != nil {
		t.Fatalf("guided app: %v\n%s\n%s", err, app.Stdout, app.Stderr)
	}
	after, err := os.ReadFile(filepath.Join(app.Directory, entry))
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("wizard changed full application handlers/connection config")
	}
	output := app.Stdout.(*bytes.Buffer).String()
	for _, want := range []string{"Prepared Lesson84WorkerMigrations.NoteDatabase revision V2", "Current schema files to edit:", schemaPath, "Application checks passed", "add-column", "category", "schema-worker-ready"} {
		if !strings.Contains(output, want) {
			t.Errorf("missing %q in %s", want, output)
		}
	}
	if len(input.steps) != 0 {
		t.Fatal("wizard did not request the schema edit")
	}
	migrationCheck(t, app, entry, true)
	if qualified {
		app.Stdin = strings.NewReader("\n")
		if err := app.Run(context.Background(), []string{"migrate", entry, "--resume"}); err != nil {
			t.Fatalf("qualified resume: %v\n%s", err, app.Stdout)
		}
		migrationCheck(t, app, entry, true)
		migrationCheck(t, app, schemaPath, true)
		after, err := os.ReadFile(filepath.Join(app.Directory, entry))
		if err != nil || !bytes.Equal(before, after) {
			t.Fatal("qualified resume changed application code")
		}
	}
}

func TestMigrationWizardNativeRefusesChangedSelectionOrRevisionBeforeWrite(t *testing.T) {
	for _, change := range []string{"family", "revision"} {
		t.Run(change, func(t *testing.T) {
			app := realMigrationApp(t)
			var expected map[string]string
			app.Stdin = &migrationScriptedInput{steps: []func() string{func() string {
				if change == "family" {
					writeProjectFile(t, app.Directory, "app.tesl", strings.ReplaceAll(migrationApp, "NotesSchema", "OtherSchema"))
					writeProjectFile(t, app.Directory, "schema/other/v-current.tesl", strings.ReplaceAll(migrationSchema, "NotesSchema", "OtherSchema"))
				} else {
					other := *app
					other.Stdin = nil
					other.Stdout = io.Discard
					if err := other.migrate(context.Background(), []string{"migrate", "generate", "app.tesl", "--new-revision"}); err != nil {
						t.Fatal(err)
					}
				}
				expected = migrationTree(t, app.Directory)
				return "\n"
			}}}
			if err := app.Run(context.Background(), []string{"migrate", "app.tesl"}); err == nil || !strings.Contains(err.Error(), "selection changed") {
				t.Fatalf("selection race: %v\n%s", err, app.Stdout)
			}
			if !reflect.DeepEqual(expected, migrationTree(t, app.Directory)) {
				t.Fatal("wizard published a preview for a different selected family/revision")
			}
		})
	}
}

func TestMigrationWizardNativeResumeUsesExactAppliedOperation(t *testing.T) {
	app := realMigrationApp(t)
	if _, err := migrationRun(t, app, "generate", "app.tesl"); err != nil {
		t.Fatal(err)
	}
	real := app.Execute
	var expected map[string]string
	app.Execute = func(ctx context.Context, inv Invocation) error {
		if err := os.Remove(filepath.Join(app.Directory, "schema/notes/v1.tesl")); err != nil {
			t.Fatal(err)
		}
		if err := os.RemoveAll(filepath.Join(app.Directory, "migrations")); err != nil {
			t.Fatal(err)
		}
		expected = migrationTree(t, app.Directory)
		return real(ctx, inv)
	}
	app.Stdin = migrationNeverRead{t}
	if err := app.Run(context.Background(), []string{"migrate", "app.tesl", "--resume"}); err == nil || !strings.Contains(err.Error(), "no current migration") {
		t.Fatalf("resume accepted start from its exact preview: %v", err)
	}
	if !reflect.DeepEqual(expected, migrationTree(t, app.Directory)) {
		t.Fatal("resume published a fresh start after history changed")
	}
}

func TestMigrationWizardNativeResumesSavedSyntaxErrors(t *testing.T) {
	app := realMigrationApp(t)
	writeProjectFile(t, app.Directory, "app.tesl", migrationPostgresApp)
	if _, err := migrationRun(t, app, "generate", "app.tesl"); err != nil {
		t.Fatal(err)
	}
	writeProjectFile(t, app.Directory, "schema/notes/v-current.tesl", migrationSchema+"invalid syntax !!\n")
	app.Stdin = &migrationScriptedInput{steps: []func() string{
		func() string {
			writeProjectFile(t, app.Directory, "schema/notes/v-current.tesl", migrationSchema)
			return "\n"
		},
		func() string { return "\n" },
	}}
	if err := app.Run(context.Background(), []string{"migrate", "app.tesl", "--resume"}); err != nil {
		t.Fatalf("invalid saved edit could not resume: %v\n%s", err, app.Stdout)
	}
	if !strings.Contains(app.Stdout.(*bytes.Buffer).String(), "saved revision diagnostics") {
		t.Fatal("resume did not enter diagnostic loop")
	}
	if _, err := os.Stat(filepath.Join(app.Directory, "schema/notes/v2.tesl")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("resuming invalid source advanced revision")
	}
}

func TestMigrationWizardNativeRechecksSavedApplicationAndStopsAtPlanRefusal(t *testing.T) {
	t.Run("saved application changed", func(t *testing.T) {
		app := realMigrationApp(t)
		writeProjectFile(t, app.Directory, "app.tesl", migrationPostgresApp)
		real := app.Execute
		checks := 0
		app.Execute = func(ctx context.Context, inv Invocation) error {
			if len(inv.Args) > 0 && inv.Args[0] == "--check" {
				checks++
				if checks == 1 {
					writeProjectFile(t, app.Directory, "app.tesl", migrationPostgresApp+"invalid application !!\n")
				}
			}
			return real(ctx, inv)
		}
		app.Stdin = &migrationScriptedInput{steps: []func() string{
			func() string { return "\n" },
			func() string { writeProjectFile(t, app.Directory, "app.tesl", migrationPostgresApp); return "\n" },
		}}
		if err := app.Run(context.Background(), []string{"migrate", "app.tesl"}); err != nil {
			t.Fatalf("saved application recovery: %v\n%s\n%s", err, app.Stdout, app.Stderr)
		}
		if checks != 2 || !strings.Contains(app.Stdout.(*bytes.Buffer).String(), "application diagnostics") {
			t.Fatal("saved check failure did not stop completion and prompt recovery")
		}
	})
	t.Run("physical planning refuses", func(t *testing.T) {
		app := realMigrationApp(t)
		app.Stdin = strings.NewReader("\n")
		if err := app.Run(context.Background(), []string{"migrate", "app.tesl"}); err == nil || !strings.Contains(err.Error(), "planning is not ready") {
			t.Fatalf("unsupported Memory plan was called ready: %v", err)
		}
		if strings.Contains(app.Stdout.(*bytes.Buffer).String(), "then build the release") {
			t.Fatal("refused plan printed deployment guidance")
		}
		migrationCheck(t, app, "app.tesl", true)
	})
}

func TestMigrationWizardNativeLoopsThroughSyntaxAndDecisionDiagnostics(t *testing.T) {
	app := realMigrationApp(t)
	writeProjectFile(t, app.Directory, "app.tesl", migrationPostgresApp)
	decisionFile := filepath.Join(app.Directory, "migrations/notes/v2.tesl")
	input := &migrationScriptedInput{steps: []func() string{
		func() string {
			writeProjectFile(t, app.Directory, "schema/notes/v-current.tesl", migrationSchema+"not valid Tesl !!\n")
			return "\n"
		},
		func() string {
			writeProjectFile(t, app.Directory, "schema/notes/v-current.tesl", strings.Replace(migrationSchema, "id: String }", "id: String, title: String }", 1))
			return "\n"
		},
		func() string {
			if !strings.Contains(app.Stdout.(*bytes.Buffer).String(), "MIG003") {
				t.Fatal("wizard did not show its decision diagnostic before asking for input")
			}
			source, err := os.ReadFile(decisionFile)
			if err != nil {
				t.Fatal(err)
			}
			hole := regexp.MustCompile(`todo "(?:\\.|[^"\\])*"`)
			if len(hole.FindAll(source, -1)) != 1 {
				t.Fatalf("expected one generated decision: %s", source)
			}
			changed := hole.ReplaceAll(source, []byte(`Additive [Default title "untitled"]`))
			if err := os.WriteFile(decisionFile, changed, 0600); err != nil {
				t.Fatal(err)
			}
			return "\n"
		},
	}}
	app.Stdin = input
	if err := app.Run(context.Background(), []string{"migrate", "app.tesl", "--database", "App.Main"}); err != nil {
		t.Fatalf("diagnostic loop: %v\n%s\n%s", err, app.Stdout, app.Stderr)
	}
	if len(input.steps) != 0 || !strings.Contains(app.Stdout.(*bytes.Buffer).String(), "generation diagnostics") {
		t.Fatal("wizard skipped the source diagnostic retry")
	}
	source, err := os.ReadFile(decisionFile)
	if err != nil || !bytes.Contains(source, []byte(`Additive [Default title "untitled"]`)) {
		t.Fatal("refresh discarded the authored migration decision")
	}
	migrationCheck(t, app, "app.tesl", true)
}

func TestMigrationWizardNativeQuitEOFAndResumeDoNotAdvanceAgain(t *testing.T) {
	for _, answer := range []string{"q\n", ""} {
		t.Run("answer="+answer, func(t *testing.T) {
			app := realMigrationApp(t)
			writeProjectFile(t, app.Directory, "app.tesl", migrationPostgresApp)
			app.Stdin = strings.NewReader(answer)
			err := app.Run(context.Background(), []string{"migrate", "app.tesl"})
			if (answer == "") != errors.Is(err, io.EOF) || answer != "" && err != nil {
				t.Fatalf("stop: %v", err)
			}
			if _, err := os.Stat(filepath.Join(app.Directory, "migrations/notes/v2.tesl")); err != nil {
				t.Fatal("prepared files did not remain saved")
			}
			app.Stdin = strings.NewReader("\n")
			if err := app.Run(context.Background(), []string{"migrate", "app.tesl", "--resume"}); err != nil {
				t.Fatalf("resume: %v\n%s", err, app.Stdout)
			}
			if _, err := os.Stat(filepath.Join(app.Directory, "schema/notes/v2.tesl")); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("resume froze the current revision again")
			}
			app.Stdin = strings.NewReader("q\n")
			if err := app.Run(context.Background(), []string{"migrate", "app.tesl"}); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(filepath.Join(app.Directory, "migrations/notes/v3.tesl")); err != nil {
				t.Fatal("default command did not start the next revision")
			}
		})
	}
}

func TestMigrationWizardNativeResumeRequiresExistingRevision(t *testing.T) {
	app := realMigrationApp(t)
	before := migrationTree(t, app.Directory)
	app.Stdin = migrationNeverRead{t}
	if err := app.Run(context.Background(), []string{"migrate", "app.tesl", "--resume"}); err == nil || !strings.Contains(err.Error(), "no current migration") {
		t.Fatalf("resume: %v", err)
	}
	if !reflect.DeepEqual(before, migrationTree(t, app.Directory)) {
		t.Fatal("resume created an unrequested first revision")
	}
}

func TestMigrationWizardNativeStopsOnStaleSourceWrite(t *testing.T) {
	app := realMigrationApp(t)
	real := app.Execute
	var expected map[string]string
	app.Execute = func(ctx context.Context, inv Invocation) error {
		if err := real(ctx, inv); err != nil {
			return err
		}
		writeProjectFile(t, app.Directory, "app.tesl", migrationApp+"# racing save\n")
		expected = migrationTree(t, app.Directory)
		return nil
	}
	app.Stdin = migrationNeverRead{t}
	if err := app.Run(context.Background(), []string{"migrate", "app.tesl"}); err == nil {
		t.Fatal("wizard accepted a stale guarded source write")
	}
	if !reflect.DeepEqual(expected, migrationTree(t, app.Directory)) {
		t.Fatal("wizard replaced the racing save or tried another write")
	}
}

func TestMigrationWizardTerminalReadCancelsWithoutAWaitingGoroutine(t *testing.T) {
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = read.Close(); _ = write.Close() }()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	started := time.Now()
	if _, err := migrationReadLine(ctx, read); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("terminal poll cancellation: %v", err)
	}
	if time.Since(started) > time.Second {
		t.Fatal("cancelled prompt remained blocked")
	}
}

func TestMigrationWizardNativeFinalPlanMustMatchPreparedSelection(t *testing.T) {
	for _, change := range []string{"family", "revision"} {
		t.Run(change, func(t *testing.T) {
			app := realMigrationApp(t)
			writeProjectFile(t, app.Directory, "app.tesl", migrationPostgresApp)
			real := app.Execute
			var expected map[string]string
			app.Execute = func(ctx context.Context, inv Invocation) error {
				if len(inv.Args) > 1 && inv.Args[0] == "migrate" && inv.Args[1] == "plan" {
					if change == "family" {
						writeProjectFile(t, app.Directory, "app.tesl", strings.ReplaceAll(migrationPostgresApp, "NotesSchema", "OtherSchema"))
						writeProjectFile(t, app.Directory, "schema/other/v-current.tesl", strings.ReplaceAll(migrationSchema, "NotesSchema", "OtherSchema"))
					} else {
						other := *app
						other.Execute = real
						other.Stdin = nil
						other.Stdout = io.Discard
						if err := other.migrate(ctx, []string{"migrate", "generate", "app.tesl", "--new-revision"}); err != nil {
							t.Fatal(err)
						}
					}
					expected = migrationTree(t, app.Directory)
				}
				return real(ctx, inv)
			}
			app.Stdin = strings.NewReader("\n")
			if err := app.Run(context.Background(), []string{"migrate", "app.tesl"}); err == nil || !strings.Contains(err.Error(), "plan selection changed") {
				t.Fatalf("changed final plan was accepted: %v\n%s", err, app.Stdout)
			}
			if strings.Contains(app.Stdout.(*bytes.Buffer).String(), "then build the release") {
				t.Fatal("changed plan printed deployment completion")
			}
			if expected == nil || !reflect.DeepEqual(expected, migrationTree(t, app.Directory)) {
				t.Fatal("final plan refusal changed saved sources")
			}
		})
	}
}
