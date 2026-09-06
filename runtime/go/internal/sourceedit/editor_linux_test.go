//go:build linux

package sourceedit

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

func editorTransactionFixture(t *testing.T) (*Manifest, []EditorDocument) {
	t.Helper()
	root, next := transactionFixture(t, true)
	var changed string
	for _, edit := range next.wire.Edits {
		if edit.BeforeHex != nil {
			changed = edit.Path
			break
		}
	}
	if changed == "" {
		t.Fatal("next revision fixture has no existing migration to freeze")
	}
	entry := filepath.Join(root, "app.tesl")
	documents := make([]EditorDocument, 0, 2)
	for i, path := range []string{entry, changed} {
		source, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		text := string(source)
		if path == changed {
			text += "\n# Unsaved migration review note 🌱\n"
		}
		documents = append(documents, EditorDocument{Path: path, Version: int32(11 + i), Source: text})
	}
	preview := editorCompilerPreview(t, root, documents, true)
	if len(preview.Manifest().DocumentVersions()) != 2 {
		t.Fatal("compiler did not bind both editor documents")
	}
	return preview.Manifest(), documents
}

func editorCompilerPreview(t *testing.T, root string, documents []EditorDocument, next bool) *Preview {
	t.Helper()
	compiler := filepath.Join(os.Getenv("TESL_REPO_ROOT"), "compiler", "_build", "default", "bin", "main.exe")
	args := []string{"migrate", "generate", filepath.Join(root, "app.tesl"), "--manifest-json", "--project-root", root}
	if next {
		args = append(args, "--new-revision")
	}
	private := t.TempDir()
	for i, doc := range documents {
		contents := filepath.Join(private, strconv.Itoa(i)+".overlay")
		if err := os.WriteFile(contents, []byte(doc.Source), 0600); err != nil {
			t.Fatal(err)
		}
		args = append(args, "--overlay", doc.Path, strconv.Itoa(int(doc.Version)), contents)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, compiler, args...).CombinedOutput()
	if err != nil {
		t.Fatalf("editor compiler preview: %s %v", output, err)
	}
	preview, err := DecodePreview(output)
	if err != nil || preview == nil || !preview.Compilable() {
		t.Fatalf("editor proposal does not compile: %s %v", output, err)
	}
	return preview
}

func runEditorSourceChild(t *testing.T, m *Manifest, documents []EditorDocument, operation, stop string) {
	t.Helper()
	private := t.TempDir()
	manifestFile, documentsFile := filepath.Join(private, "manifest.json"), filepath.Join(private, "documents.json")
	if err := os.WriteFile(manifestFile, m.JSON(), 0600); err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(documents)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(documentsFile, raw, 0600); err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, executable, "-test.run=^TestEditorSourceProcessHelper$")
	cmd.Env = append(os.Environ(), "TESL_EDITOR_SOURCE_TEST_MANIFEST="+manifestFile, "TESL_EDITOR_SOURCE_TEST_DOCUMENTS="+documentsFile,
		"TESL_EDITOR_SOURCE_TEST_OPERATION="+operation, "TESL_EDITOR_SOURCE_TEST_STOP="+stop)
	output, err := cmd.CombinedOutput()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 73 {
		t.Fatalf("editor child did not reach %s: %s %v", stop, output, err)
	}
}

func TestEditorSourceProcessHelper(t *testing.T) {
	file := os.Getenv("TESL_EDITOR_SOURCE_TEST_MANIFEST")
	if file == "" {
		return
	}
	raw, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	m, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	raw, err = os.ReadFile(os.Getenv("TESL_EDITOR_SOURCE_TEST_DOCUMENTS"))
	if err != nil {
		t.Fatal(err)
	}
	var documents []EditorDocument
	if err := json.Unmarshal(raw, &documents); err != nil {
		t.Fatal(err)
	}
	checkpoint := func(name string) error {
		if name == os.Getenv("TESL_EDITOR_SOURCE_TEST_STOP") {
			os.Exit(73)
		}
		return nil
	}
	ctx := context.Background()
	editor, _, err := m.prepareEditor(ctx, documents, checkpoint)
	if err != nil || editor == nil {
		t.Fatal(err)
	}
	if _, err := editor.Publish(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := editor.BeginClientEdits(ctx); err != nil {
		t.Fatal(err)
	}
	if os.Getenv("TESL_EDITOR_SOURCE_TEST_OPERATION") == "restore" {
		_, err = editor.Restore(ctx, documents)
	} else {
		_, err = editor.Commit(ctx, editorAppliedDocuments(t, m, documents))
	}
	t.Fatalf("requested editor checkpoint was not reached: %v", err)
}

func assertEditorCommittedDisk(t *testing.T, m *Manifest, before map[string]sourceNode) {
	t.Helper()
	expected := make(map[string]sourceNode, len(before))
	for path, node := range before {
		expected[path] = node
	}
	physical := m.wire
	physical.Edits = closedEdits(m)
	for _, path := range requiredDirectories(physical) {
		rel, _ := filepath.Rel(m.ProjectRoot(), path)
		expected[rel] = sourceNode{Mode: os.ModeDir | 0700}
	}
	for _, edit := range physical.Edits {
		rel, _ := filepath.Rel(m.ProjectRoot(), edit.Path)
		node := expected[rel]
		if edit.BeforeHex == nil {
			node.Mode = 0600
		}
		after, _ := hex.DecodeString(edit.AfterHex)
		node.Bytes = string(after)
		expected[rel] = node
	}
	if !reflect.DeepEqual(expected, sourceSnapshot(t, m.ProjectRoot())) {
		t.Fatal("committed recovery changed open-buffer disk preimages or retained metadata")
	}
}

func TestEditorSourceRecoveryAfterRealProcessExit(t *testing.T) {
	for _, phase := range []string{"before-prepare", "journal-durable", "published", "before-client", "outcome-editor-pending", "client-pending", "before-commit", "outcome-committed", "committed", "cleaned:source-000000", "cleaned:journal.json", "cleaned:owner"} {
		t.Run(phase, func(t *testing.T) {
			m, documents := editorTransactionFixture(t)
			before := sourceSnapshot(t, m.ProjectRoot())
			stop := phase
			if phase == "published" {
				stop += ":" + closedEdits(m)[0].Path
			}
			runEditorSourceChild(t, m, documents, "commit", stop)
			pending := sourceSnapshot(t, m.ProjectRoot())
			report, err := Recover(context.Background(), m.ProjectRoot())
			switch phase {
			case "outcome-editor-pending", "client-pending", "before-commit":
				if err == nil || !report.RecoveryRequired || !strings.Contains(err.Error(), "outcome is unknown") || !reflect.DeepEqual(pending, sourceSnapshot(t, m.ProjectRoot())) {
					t.Fatalf("crash recovery guessed an unacknowledged buffer state: %+v %v", report, err)
				}
			case "outcome-committed", "committed", "cleaned:source-000000", "cleaned:journal.json", "cleaned:owner":
				if err != nil || report.RecoveryRequired {
					t.Fatalf("committed recovery failed: %+v %v", report, err)
				}
				assertEditorCommittedDisk(t, m, before)
			default:
				if err != nil || report.RecoveryRequired || !reflect.DeepEqual(before, sourceSnapshot(t, m.ProjectRoot())) {
					t.Fatalf("pre-client crash did not restore original disk: %+v %v", report, err)
				}
			}
		})
	}
	for _, phase := range []string{"outcome-restored", "cleaned:capture-000000", "cleaned:journal.json"} {
		t.Run("inverse/"+phase, func(t *testing.T) {
			m, documents := editorTransactionFixture(t)
			before := sourceSnapshot(t, m.ProjectRoot())
			runEditorSourceChild(t, m, documents, "restore", phase)
			if report, err := Recover(context.Background(), m.ProjectRoot()); err != nil || report.RecoveryRequired || !reflect.DeepEqual(before, sourceSnapshot(t, m.ProjectRoot())) {
				t.Fatalf("inverse cleanup changed restored source: %+v %v", report, err)
			}
		})
	}
}

func editorAppliedDocuments(t *testing.T, m *Manifest, original []EditorDocument) []EditorDocument {
	t.Helper()
	documents := append([]EditorDocument{}, original...)
	for i := range documents {
		for _, edit := range m.wire.Edits {
			if edit.Path == documents[i].Path && edit.DocumentVersion != nil {
				after, err := hex.DecodeString(edit.AfterHex)
				if err != nil {
					t.Fatal(err)
				}
				documents[i].Source = string(after)
				documents[i].Version += 3
			}
		}
	}
	return documents
}

func TestEditorSourceTransactionCommitsOnlyAfterBufferAcknowledgement(t *testing.T) {
	m, documents := editorTransactionFixture(t)
	before := sourceSnapshot(t, m.ProjectRoot())
	ctx := context.Background()
	editor, report, err := m.PrepareEditor(ctx, documents)
	if err != nil || editor == nil || report.Outcome != "prepared" {
		t.Fatalf("prepare: %+v %v", report, err)
	}
	t.Cleanup(func() { _ = editor.Close() })
	journalBytes, err := os.ReadFile(filepath.Join(m.ProjectRoot(), transactionDirectory, "journal.json"))
	if err != nil {
		t.Fatal(err)
	}
	var journal journal
	if err := json.Unmarshal(journalBytes, &journal); err != nil || journal.Version != 2 || !bytes.Equal(journal.Manifest, m.JSON()) || journal.ManifestHash != m.Digest() {
		t.Fatalf("editor journal stripped original buffer authority: %s %v", journalBytes, err)
	}
	if _, err := editor.Commit(ctx, documents); err == nil {
		t.Fatal("unpublished editor transaction committed")
	}
	if _, err := editor.BeginClientEdits(ctx); err == nil {
		t.Fatal("client requests authorized before publication")
	}
	if _, err := editor.Publish(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := editor.Publish(ctx); err == nil {
		t.Fatal("publication was allowed twice")
	}
	if _, err := editor.CommitWithoutClient(ctx, documents); err == nil {
		t.Fatal("mixed proposal committed without buffer acknowledgement")
	}
	for _, doc := range documents {
		rel, _ := filepath.Rel(m.ProjectRoot(), doc.Path)
		saved, err := os.ReadFile(doc.Path)
		if err != nil || string(saved) != before[rel].Bytes {
			t.Fatal("filesystem publication saved an editor buffer")
		}
	}
	if _, err := Recover(ctx, m.ProjectRoot()); err == nil {
		t.Fatal("recovery stole an active editor transaction")
	}
	if _, err := editor.BeginClientEdits(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := editor.Abort(ctx); err == nil {
		t.Fatal("disk-only abort accepted an outstanding client request")
	}
	if _, err := editor.Commit(ctx, documents); err == nil {
		t.Fatal("unapplied buffers were accepted as committed")
	}
	applied := editorAppliedDocuments(t, m, documents)
	report, err = editor.Commit(ctx, applied)
	if err != nil || report.Outcome != "committed" || report.RecoveryRequired || len(report.Written) != len(closedEdits(m)) {
		t.Fatalf("commit: %+v %v", report, err)
	}
	if _, err := os.Stat(filepath.Join(m.ProjectRoot(), transactionDirectory)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("committed editor journal was not cleaned")
	}
	for _, edit := range closedEdits(m) {
		after, _ := hex.DecodeString(edit.AfterHex)
		saved, err := os.ReadFile(edit.Path)
		if err != nil || !bytes.Equal(after, saved) {
			t.Fatalf("closed file differs from compiler proposal: %s %v", edit.Path, err)
		}
	}
	// The actual resulting disk + unsaved-buffer view still compiles, and a
	// repeated refresh has no edits. No implicit save is required for this check.
	refresh := editorCompilerPreview(t, m.ProjectRoot(), applied, false)
	if len(refresh.Manifest().FileEdits()) != 0 {
		t.Fatal("committed mixed source view is not an idempotent compiler refresh")
	}
	if len(report.Written) > 0 {
		report.Written[0] = "caller mutation"
		if editor.Report().Written[0] == "caller mutation" {
			t.Fatal("mutable report changed retained transaction state")
		}
	}
}

func TestEditorSourceTransactionPreservesUnrelatedUserBuffersDuringRestore(t *testing.T) {
	m, documents := editorTransactionFixture(t)
	before := sourceSnapshot(t, m.ProjectRoot())
	ctx := context.Background()
	editor, _, err := m.PrepareEditor(ctx, documents)
	if err != nil || editor == nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = editor.Close() })
	if _, err := editor.Publish(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := editor.BeginClientEdits(ctx); err != nil {
		t.Fatal(err)
	}
	// The application buffer was never edited by this operation. An unrelated
	// user change must survive an inverse, not prevent filesystem restoration.
	documents[0].Source += "\n# User work during migration review\n"
	documents[0].Version++
	documents[1].Version += 5
	if _, err := editor.Restore(ctx, documents[:1]); err == nil {
		t.Fatal("restoration accepted a missing edited buffer")
	}
	if _, err := editor.Restore(ctx, append(append([]EditorDocument{}, documents...), documents[1])); err == nil {
		t.Fatal("restoration accepted duplicate edited buffer acknowledgements")
	}
	if report, err := editor.Restore(ctx, documents); err != nil || report.RecoveryRequired || !reflect.DeepEqual(before, sourceSnapshot(t, m.ProjectRoot())) {
		t.Fatalf("unrelated user edits blocked a guarded inverse: %+v %v", report, err)
	}
	if !strings.Contains(documents[0].Source, "User work during migration review") {
		t.Fatal("restore changed its caller's unedited application buffer")
	}
}

func TestEditorSourceTransactionWithOnlyClosedEdits(t *testing.T) {
	root, _ := transactionFixture(t, false)
	entry := filepath.Join(root, "app.tesl")
	source, err := os.ReadFile(entry)
	if err != nil {
		t.Fatal(err)
	}
	documents := []EditorDocument{{Path: entry, Version: 9, Source: string(source)}}
	m := editorCompilerPreview(t, root, documents, false).Manifest()
	editor, _, err := m.PrepareEditor(context.Background(), documents)
	if err != nil || editor == nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = editor.Close() })
	if _, err := editor.CommitWithoutClient(context.Background(), documents); err == nil {
		t.Fatal("unpublished source committed")
	}
	if _, err := editor.Publish(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := editor.BeginClientEdits(context.Background()); err == nil {
		t.Fatal("closed-only edit acquired an ambiguous client phase")
	}
	stale := append([]EditorDocument{}, documents...)
	stale[0].Version++
	if _, err := editor.CommitWithoutClient(context.Background(), stale); err == nil {
		t.Fatal("closed-only commit ignored open dependency versions")
	}
	if report, err := editor.CommitWithoutClient(context.Background(), documents); err != nil || report.Outcome != "committed" || report.RecoveryRequired {
		t.Fatalf("closed-only commit: %+v %v", report, err)
	}
	assertProposed(t, m)
	assertChecks(t, root)
}

func TestEditorSourceTransactionRejectsStalePreparationAndCancelsPublication(t *testing.T) {
	m, documents := editorTransactionFixture(t)
	before := sourceSnapshot(t, m.ProjectRoot())
	for _, change := range []string{"missing", "duplicate", "version", "source"} {
		stale := append([]EditorDocument{}, documents...)
		switch change {
		case "missing":
			stale = stale[:1]
		case "duplicate":
			stale[1] = stale[0]
		case "version":
			stale[1].Version++
		case "source":
			stale[1].Source += "changed"
		}
		if editor, _, err := m.PrepareEditor(context.Background(), stale); err == nil || editor != nil || !reflect.DeepEqual(before, sourceSnapshot(t, m.ProjectRoot())) {
			t.Fatalf("stale %s created source transaction state", change)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	first := closedEdits(m)[0].Path
	editor, _, err := m.prepareEditor(ctx, documents, func(point string) error {
		if point == "written:"+first {
			cancel()
		}
		return nil
	})
	if err != nil || editor == nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = editor.Close() })
	if _, err := editor.Publish(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("publication ignored cancellation: %v", err)
	}
	if _, err := editor.BeginClientEdits(context.Background()); err == nil {
		t.Fatal("cancelled publication authorized buffer edits")
	}
	if report, err := editor.Abort(context.Background()); err != nil || report.RecoveryRequired || !reflect.DeepEqual(before, sourceSnapshot(t, m.ProjectRoot())) {
		t.Fatalf("cancelled publication failed to restore: %+v %v", report, err)
	}
}

func TestEditorSourceTransactionRestoreAndUnknownOutcome(t *testing.T) {
	for _, mode := range []string{"abort", "restore", "unknown", "prepared recovery"} {
		t.Run(mode, func(t *testing.T) {
			m, documents := editorTransactionFixture(t)
			before := sourceSnapshot(t, m.ProjectRoot())
			ctx := context.Background()
			editor, _, err := m.PrepareEditor(ctx, documents)
			if err != nil || editor == nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = editor.Close() })
			if _, err := editor.Publish(ctx); err != nil {
				t.Fatal(err)
			}
			if mode == "restore" || mode == "unknown" {
				if _, err := editor.BeginClientEdits(ctx); err != nil {
					t.Fatal(err)
				}
			}
			var report Report
			switch mode {
			case "abort":
				report, err = editor.Abort(ctx)
			case "restore":
				applied := editorAppliedDocuments(t, m, documents)
				if _, err := editor.Restore(ctx, applied); err == nil {
					t.Fatal("buffer inverse was not required before restoration")
				}
				for i := range documents {
					if applied[i].Source != documents[i].Source {
						documents[i].Version = applied[i].Version + 2
					}
				}
				report, err = editor.Restore(ctx, documents)
			case "prepared recovery":
				if err := editor.Close(); err != nil {
					t.Fatal(err)
				}
				report, err = Recover(ctx, m.ProjectRoot())
			case "unknown":
				if err := editor.Close(); err != nil || !editor.Report().RecoveryRequired {
					t.Fatalf("unknown outcome did not retain recovery state: %v", err)
				}
				pending := sourceSnapshot(t, m.ProjectRoot())
				for i := 0; i < 2; i++ {
					report, err := Recover(ctx, m.ProjectRoot())
					if err == nil || !strings.Contains(err.Error(), "outcome is unknown") || !report.RecoveryRequired || !reflect.DeepEqual(pending, sourceSnapshot(t, m.ProjectRoot())) {
						t.Fatalf("disk recovery guessed the editor outcome: %+v %v", report, err)
					}
				}
				return
			}
			if err != nil || report.Outcome != "restored" || report.RecoveryRequired || !reflect.DeepEqual(before, sourceSnapshot(t, m.ProjectRoot())) {
				t.Fatalf("restoration did not preserve original disk: %+v %v", report, err)
			}
		})
	}
}
