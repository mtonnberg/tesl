package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"reflect"
	"strings"
	"testing"
)

type migrationNeverRead struct{ t *testing.T }

func (reader migrationNeverRead) Read([]byte) (int, error) {
	reader.t.Fatal("interactive input was read before refusal")
	return 0, io.EOF
}

func TestMigrationWizardRejectsCIAndNonTerminalBeforeAnyWork(t *testing.T) {
	for _, mode := range []string{"ci", "nil", "pipe", "null-device"} {
		t.Run(mode, func(t *testing.T) {
			app, calls := fakeApp(t)
			switch mode {
			case "ci":
				app.Environment = append(app.Environment, "CI=true")
				app.Stdin = migrationNeverRead{t}
			case "nil":
				app.Stdin = nil
			case "pipe":
				read, write, err := os.Pipe()
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { _ = read.Close(); _ = write.Close() })
				app.Stdin = read
			case "null-device":
				file, err := os.Open(os.DevNull)
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { _ = file.Close() })
				app.Stdin = file
			}
			if err := app.Run(context.Background(), []string{"migrate", "app.tesl"}); err == nil {
				t.Fatal("unguided input accepted")
			}
			if len(*calls) != 0 {
				t.Fatalf("noninteractive refusal invoked compiler: %+v", *calls)
			}
			if app.Stdout.(*bytes.Buffer).Len() != 0 {
				t.Fatal("noninteractive refusal printed an interactive prompt")
			}
		})
	}
}

func TestMigrationWizardArgumentsPreserveOpaqueSelection(t *testing.T) {
	options, err := parseMigrationWizard([]string{"my app.tesl", "--database", "App.Store", "--resume"})
	if err != nil || !options.resume {
		t.Fatalf("parse: %+v %v", options, err)
	}
	if got, want := options.generateArgs(false), []string{"migrate", "generate", "--database", "App.Store", "--", "my app.tesl"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("argv: %q", got)
	}
	options, err = parseMigrationWizard([]string{"--", "-entry.tesl"})
	if err != nil || !reflect.DeepEqual(options.generateArgs(true), []string{"migrate", "generate", "--new-revision", "--", "-entry.tesl"}) {
		t.Fatalf("literal entry: %+v %v", options, err)
	}
	for _, args := range [][]string{{}, {""}, {"--"}, {"--", ""}, {"--", "a", "b"}, {"a.tesl", "--resume", "--resume"}, {"a.tesl", "--database"}, {"a.tesl", "--database", ""}, {"a.tesl", "--database", "A", "--database", "B"}, {"a.tesl", "--new-revision"}, {"a.tesl", "--manifest-json"}, {"a.tesl", "extra.tesl"}} {
		if _, err := parseMigrationWizard(args); err == nil {
			t.Errorf("invalid arguments accepted: %q", args)
		}
	}
}

func TestMigrationWizardPromptRequiresWholeLineAndHandlesStop(t *testing.T) {
	app, _ := fakeApp(t)
	app.Stdin = strings.NewReader("unexpected\nq\n")
	proceed, err := app.migrationWizardPrompt(context.Background(), "Save your changes")
	if err != nil || proceed || !strings.Contains(app.Stdout.(*bytes.Buffer).String(), "--resume") {
		t.Fatalf("quit: %v %v %s", proceed, err, app.Stdout)
	}
	app.Stdin = strings.NewReader("")
	if _, err := app.migrationWizardPrompt(context.Background(), "Save your changes"); !errors.Is(err, io.EOF) {
		t.Fatalf("EOF became Enter: %v", err)
	}
	if _, err := migrationReadLine(context.Background(), strings.NewReader("q")); !errors.Is(err, io.EOF) {
		t.Fatalf("partial EOF became a completed answer: %v", err)
	}
	if _, err := migrationReadLine(context.Background(), strings.NewReader(strings.Repeat("x", 4096)+"\n")); err == nil {
		t.Fatal("unbounded prompt line accepted")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := migrationReadLine(ctx, migrationNeverRead{t}); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled input read: %v", err)
	}
}

func TestMigrationWizardCurrentPathsFollowOpaqueQualifiedClosure(t *testing.T) {
	var report migrationWizardReport
	if err := json.Unmarshal([]byte(`{"selection":{"schemaRoot":"Schema.Todo.VCurrent"},"manifest":{"imports":[
 {"module":"Schema.Todo.VCurrent.Notes","sourceResolved":"/project/data/arbitrary-name.tesl"},
 {"module":"Schema.Todo.VCurrent","sourceResolved":"/project/selected-root.tesl"},
 {"module":"Schema.Todo.VCurrent.Notes","sourceResolved":"/project/data/arbitrary-name.tesl"},
 {"module":"Schema.Todo.VCurrentOther","sourceResolved":"/project/wrong-prefix.tesl"},
 {"module":"Schema.Todo.V7.Notes","sourceResolved":"/project/frozen.tesl"},
 {"module":"OtherSchema.VCurrent","sourceResolved":"/project/other.tesl"}]}}`), &report); err != nil {
		t.Fatal(err)
	}
	if got, want := migrationWizardCurrentPaths(report), []string{"/project/data/arbitrary-name.tesl", "/project/selected-root.tesl"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("current closure paths: %q", got)
	}
}

func TestMigrationWizardHelpNeverReadsOrExecutes(t *testing.T) {
	for _, args := range [][]string{{"migrate"}, {"migrate", "--help"}, {"migrate", "generate", "--help"}} {
		app, calls := fakeApp(t)
		app.Stdin = migrationNeverRead{t}
		app.Environment = append(app.Environment, "CI=true")
		if err := app.Run(context.Background(), args); err != nil {
			t.Fatal(err)
		}
		for _, text := range []string{"tesl migrate <entry.tesl>", "--resume", "interactive terminal", "--manifest-json"} {
			if !strings.Contains(app.Stdout.(*bytes.Buffer).String(), text) {
				t.Errorf("help for %q omitted %q", args, text)
			}
		}
		if len(*calls) != 0 {
			t.Fatal("migration help invoked a tool")
		}
	}
}
