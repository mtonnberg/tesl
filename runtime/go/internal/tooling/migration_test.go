package tooling

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

type migrationPreviewAudit struct {
	Args         []string
	Sources      map[string]string
	PrivateFiles []string
	LogicalPath  string
}

func migrationPreviewHelper(mode string) {
	if len(os.Args) == 0 {
		return
	}
	args := os.Args[1:]
	audit := migrationPreviewAudit{Args: args, Sources: map[string]string{}, LogicalPath: os.Getenv("TESL_LOGICAL_PATH")}
	for i, arg := range args {
		if arg != "--overlay" {
			continue
		}
		if i+3 >= len(args) {
			os.Exit(2)
		}
		data, err := os.ReadFile(args[i+3])
		if err != nil {
			os.Exit(3)
		}
		audit.Sources[args[i+1]] = string(data)
		audit.PrivateFiles = append(audit.PrivateFiles, args[i+3])
	}
	encoded, err := json.Marshal(audit)
	if err != nil || os.WriteFile(os.Getenv("TESL_MIGRATION_PREVIEW_AUDIT"), encoded, 0600) != nil {
		os.Exit(4)
	}
	if mode == "hang" {
		time.Sleep(30 * time.Second)
		os.Exit(5)
	}
	response, err := os.ReadFile(os.Getenv("TESL_MIGRATION_PREVIEW_RESPONSE"))
	if err != nil {
		os.Exit(6)
	}
	_, _ = os.Stdout.Write(response)
	if mode == "failure" {
		os.Exit(1)
	}
}

func migrationPreviewVector(t *testing.T) (MigrationSelection, []MigrationDocument, map[string]any) {
	t.Helper()
	root := t.TempDir()
	entry := filepath.Join(root, "app.tesl")
	documents := []MigrationDocument{{Path: entry, Version: -7, Source: "saved"}}
	if err := os.WriteFile(entry, []byte("saved"), 0600); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256([]byte("saved"))
	hash := hex.EncodeToString(digest[:])
	manifest := map[string]any{"version": 1, "projectRoot": root,
		"documents": []any{map[string]any{"path": entry, "version": -7}}, "imports": []any{},
		"inputs":      []any{map[string]any{"path": entry, "sourceHash": hash, "diskHash": hash}},
		"directories": []any{map[string]any{"path": root, "sourceHash": strings.Repeat("a", 64), "diskHash": strings.Repeat("a", 64)}},
		"edits":       []any{}}
	response := map[string]any{"version": 1, "kind": "migration-source-preview", "ok": true, "operation": "start",
		"compilerAbi": "tesl-source-abi-v1:" + strings.Repeat("a", 64), "compilable": true,
		"selection": map[string]any{"entryFile": entry, "databaseFile": entry, "database": "App.Main", "family": "NotesSchema",
			"schemaRoot": "NotesSchema.VCurrent", "previousVersion": nil, "revisionBefore": 1, "revisionAfter": 2},
		"diagnostics": map[string]any{"version": 1, "diagnostics": []any{}}, "manifest": manifest}
	return MigrationSelection{EntryFile: entry, ProjectRoot: root, Database: "App.Main", NewRevision: true}, documents, response
}

func migrationPreviewClient(t *testing.T, response any, mode string) (Client, string) {
	t.Helper()
	root := t.TempDir()
	file, audit := filepath.Join(root, "response.json"), filepath.Join(root, "audit.json")
	data, err := json.Marshal(response)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, data, 0600); err != nil {
		t.Fatal(err)
	}
	return Client{Executable: testExecutable(t), Timeout: 5 * time.Second, Environment: append(os.Environ(),
		"TESL_MIGRATION_PREVIEW_HELPER="+mode, "TESL_MIGRATION_PREVIEW_RESPONSE="+file, "TESL_MIGRATION_PREVIEW_AUDIT="+audit,
		"TESL_LOGICAL_PATH=must-not-rebase-the-manifest")}, audit
}

func migrationPreviewReadAudit(t *testing.T, path string) migrationPreviewAudit {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var audit migrationPreviewAudit
	if err := json.Unmarshal(data, &audit); err != nil {
		t.Fatal(err)
	}
	for _, file := range audit.PrivateFiles {
		if _, err := os.Stat(file); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("private buffer survived compiler exit: %s %v", file, err)
		}
	}
	return audit
}

func TestMigrationPreviewTransportPreservesSelectionAndCleansBuffers(t *testing.T) {
	selection, documents, response := migrationPreviewVector(t)
	client, auditFile := migrationPreviewClient(t, response, "ok")
	before := append([]MigrationDocument(nil), documents...)
	preview, _, err := client.QueryMigrationPreview(context.Background(), selection, documents)
	if err != nil || preview == nil {
		t.Fatalf("preview: %v", err)
	}
	if !reflect.DeepEqual(before, documents) {
		t.Fatal("transport mutated caller buffers")
	}
	audit := migrationPreviewReadAudit(t, auditFile)
	if audit.LogicalPath != "" || audit.Sources[selection.EntryFile] != "saved" || len(audit.PrivateFiles) != 1 ||
		!reflect.DeepEqual(audit.Args[:9], []string{"migrate", "generate", selection.EntryFile, "--manifest-json", "--project-root", selection.ProjectRoot, "--database", "App.Main", "--new-revision"}) {
		t.Fatalf("changed source transport or invoked a mutating compiler endpoint: %+v", audit)
	}
	if preview.Manifest().DocumentVersions()[selection.EntryFile] != -7 {
		t.Fatal("lost signed document version")
	}
	if saved, err := os.ReadFile(selection.EntryFile); err != nil || string(saved) != "saved" {
		t.Fatal("preview saved the buffer")
	}
}

func TestMigrationPreviewRefusesChangedCompilerBindings(t *testing.T) {
	for _, scenario := range []string{"root", "entry", "database", "operation", "missing document", "changed version", "ignored overlay", "failed process", "invalid response"} {
		t.Run(scenario, func(t *testing.T) {
			selection, documents, response := migrationPreviewVector(t)
			mode := "ok"
			switch scenario {
			case "root":
				manifest := response["manifest"].(map[string]any)
				foreign := selection.ProjectRoot + "-other"
				manifest["projectRoot"] = foreign
				manifest["directories"].([]any)[0].(map[string]any)["path"] = foreign
				manifest["inputs"].([]any)[0].(map[string]any)["path"] = filepath.Join(foreign, "app.tesl")
				manifest["documents"].([]any)[0].(map[string]any)["path"] = filepath.Join(foreign, "app.tesl")
			case "entry":
				response["selection"].(map[string]any)["entryFile"] = filepath.Join(selection.ProjectRoot, "other.tesl")
			case "database":
				response["selection"].(map[string]any)["database"] = "Other.Main"
			case "operation":
				response["operation"] = "refresh"
			case "missing document":
				response["manifest"].(map[string]any)["documents"] = []any{}
			case "changed version":
				response["manifest"].(map[string]any)["documents"].([]any)[0].(map[string]any)["version"] = 8
			case "ignored overlay":
				documents[0].Source = "unsaved bytes with the same version"
			case "failed process":
				mode = "failure"
			case "invalid response":
				response["ok"] = false
			}
			client, auditFile := migrationPreviewClient(t, response, mode)
			if preview, _, err := client.QueryMigrationPreview(context.Background(), selection, documents); err == nil || preview != nil {
				t.Fatalf("changed compiler binding accepted: %v", err)
			}
			migrationPreviewReadAudit(t, auditFile)
		})
	}
}

func TestMigrationPreviewCancellationRemovesPrivateFiles(t *testing.T) {
	selection, documents, response := migrationPreviewVector(t)
	client, auditFile := migrationPreviewClient(t, response, "hang")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		preview, _, err := client.QueryMigrationPreview(ctx, selection, documents)
		if preview != nil {
			err = fmt.Errorf("canceled preview returned a manifest")
		}
		done <- err
	}()
	t.Cleanup(func() { cancel(); <-finished })
	deadline := time.After(3 * time.Second)
	for {
		if _, err := os.Stat(auditFile); err == nil {
			break
		}
		select {
		case <-deadline:
			t.Fatal("compiler did not receive overlays")
		case <-time.After(5 * time.Millisecond):
		}
	}
	cancel()
	if err := <-done; err == nil {
		t.Fatal("cancellation returned success")
	}
	migrationPreviewReadAudit(t, auditFile)
}

func TestMigrationPreviewRejectsInvalidInputsBeforeStartingCompiler(t *testing.T) {
	selection, documents, _ := migrationPreviewVector(t)
	for _, scenario := range []string{"relative root", "outside entry", "duplicate buffer", "outside buffer", "invalid UTF-8", "too many buffers", "invalid database"} {
		t.Run(scenario, func(t *testing.T) {
			selected := selection
			buffers := append([]MigrationDocument(nil), documents...)
			switch scenario {
			case "relative root":
				selected.ProjectRoot = "relative"
			case "outside entry":
				selected.EntryFile = filepath.Join(filepath.Dir(selected.ProjectRoot), "other.tesl")
			case "duplicate buffer":
				buffers = append(buffers, buffers[0])
			case "outside buffer":
				buffers[0].Path = filepath.Join(filepath.Dir(selected.ProjectRoot), "other.tesl")
			case "invalid UTF-8":
				buffers[0].Source = string([]byte{255})
			case "too many buffers":
				buffers = make([]MigrationDocument, DefaultMaxOverlayDocuments+1)
			case "invalid database":
				selected.Database = "bad\x00name"
			}
			if preview, _, err := (Client{}).QueryMigrationPreview(context.Background(), selected, buffers); err == nil || preview != nil || strings.Contains(err.Error(), "executable") {
				t.Fatalf("invalid input reached compiler: %v", err)
			}
		})
	}
}
