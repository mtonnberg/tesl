//go:build linux

package sourceedit

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

type sourceNode struct {
	Mode  os.FileMode
	Bytes string
}

func sourceSnapshot(t *testing.T, root string) map[string]sourceNode {
	t.Helper()
	result := map[string]sourceNode{}
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if path == root {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		node := sourceNode{Mode: info.Mode()}
		if info.Mode().IsRegular() {
			b, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			node.Bytes = string(b)
		}
		relative, _ := filepath.Rel(root, path)
		result[relative] = node
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return result
}
func compilerPreview(t *testing.T, root string, newRevision bool) *Manifest {
	t.Helper()
	compiler := filepath.Join(os.Getenv("TESL_REPO_ROOT"), "compiler", "_build", "default", "bin", "main.exe")
	args := []string{"migrate", "generate", filepath.Join(root, "app.tesl"), "--manifest-json"}
	if newRevision {
		args = append(args, "--new-revision")
	}
	cmd := exec.Command(compiler, args...)
	output, err := cmd.Output()
	if err != nil {
		t.Fatalf("preview: %s %v", output, err)
	}
	var response struct {
		OK         bool            `json:"ok"`
		Compilable bool            `json:"compilable"`
		Manifest   json.RawMessage `json:"manifest"`
	}
	if err := json.Unmarshal(output, &response); err != nil {
		t.Fatal(err)
	}
	if !response.OK || !response.Compilable {
		t.Fatalf("incomplete preview: %s", output)
	}
	m, err := Decode(response.Manifest)
	if err != nil {
		t.Fatal(err)
	}
	return m
}
func transactionFixture(t *testing.T, next bool) (string, *Manifest) {
	t.Helper()
	root, _, raw := compilerManifest(t)
	m, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	if next {
		if report, err := m.Apply(context.Background()); err != nil {
			t.Fatalf("initial source application: %+v, %v", report, err)
		}
		m = compilerPreview(t, root, true)
	}
	return root, m
}
func assertProposed(t *testing.T, m *Manifest) {
	t.Helper()
	for path := range sourceSnapshot(t, m.ProjectRoot()) {
		if filepath.Base(path) == ownedDirectoryMarker {
			t.Fatalf("directory ownership marker remains: %s", path)
		}
	}
	for _, e := range m.wire.Edits {
		expected, _ := hex.DecodeString(e.AfterHex)
		actual, err := os.ReadFile(e.Path)
		if err != nil || !bytes.Equal(actual, expected) {
			t.Fatalf("source differs from reviewed edit: %s %v", e.Path, err)
		}
	}
	if _, err := os.Stat(filepath.Join(m.ProjectRoot(), transactionDirectory)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("transaction state remains: %v", err)
	}
}
func assertChecks(t *testing.T, root string) {
	t.Helper()
	compiler := filepath.Join(os.Getenv("TESL_REPO_ROOT"), "compiler", "_build", "default", "bin", "main.exe")
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || !strings.HasSuffix(path, ".tesl") {
			return nil
		}
		out, err := exec.Command(compiler, "agent-context", path).CombinedOutput()
		if err != nil {
			return fmt.Errorf("%s: %s, %w", path, out, err)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
func TestSourceApplyGeneratedHistory(t *testing.T) {
	root, m := transactionFixture(t, false)
	app, err := os.ReadFile(filepath.Join(root, "app.tesl"))
	if err != nil {
		t.Fatal(err)
	}
	report, err := m.Apply(context.Background())
	if err != nil || report.RecoveryRequired || len(report.Written) != len(m.wire.Edits) || len(report.Restored) != 0 {
		t.Fatalf("apply: %+v %v", report, err)
	}
	assertProposed(t, m)
	assertChecks(t, root)
	again := compilerPreview(t, root, false)
	if len(again.wire.Edits) != 0 {
		t.Fatal("repeated generation is not idempotent")
	}
	if report, err := again.Apply(context.Background()); err != nil || len(report.Written) != 0 {
		t.Fatalf("empty apply: %+v %v", report, err)
	}
	next := compilerPreview(t, root, true)
	if report, err := next.Apply(context.Background()); err != nil {
		t.Fatalf("next: %+v %v", report, err)
	}
	assertProposed(t, next)
	assertChecks(t, root)
	unchanged, err := os.ReadFile(filepath.Join(root, "app.tesl"))
	if err != nil || !bytes.Equal(app, unchanged) {
		t.Fatal("source application changed connection/application bytes")
	}
	before := sourceSnapshot(t, root)
	if _, err := next.Apply(context.Background()); err == nil {
		t.Fatal("stale manifest reapplied")
	}
	if !reflect.DeepEqual(before, sourceSnapshot(t, root)) {
		t.Fatal("stale apply touched filesystem")
	}
}
func TestSourceApplyRollsBackEveryPublicationBoundary(t *testing.T) {
	for _, next := range []bool{false, true} {
		t.Run(fmt.Sprint(next), func(t *testing.T) {
			root, m := transactionFixture(t, next)
			before := sourceSnapshot(t, root)
			points := []string{"before-prepare", "journal-durable", "before-commit"}
			for _, path := range requiredDirectories(m.wire) {
				for _, prefix := range []string{"before-directory:", "staged-directory:", "after-directory:"} {
					points = append(points, prefix+path)
				}
			}
			for _, e := range m.wire.Edits {
				for _, prefix := range []string{"staged:", "published:", "written:"} {
					points = append(points, prefix+e.Path)
				}
			}
			for _, point := range points {
				t.Run(filepath.Base(point), func(t *testing.T) {
					fired := false
					fault := errors.New("injected source failure")
					report, err := m.apply(context.Background(), func(name string) error {
						if name == point {
							fired = true
							return fault
						}
						return nil
					})
					if !fired || !errors.Is(err, fault) || report.RecoveryRequired {
						t.Fatalf("fault not restored: %s %+v %v", point, report, err)
					}
					if !reflect.DeepEqual(before, sourceSnapshot(t, root)) {
						t.Fatalf("incomplete inverse at %s", point)
					}
					if err := m.VerifyDisk(); err != nil {
						t.Fatalf("original guards not restored: %v", err)
					}
				})
			}
		})
	}
}
func TestSourceApplyPreservesPrepublicationSave(t *testing.T) {
	root, m := transactionFixture(t, true)
	existing := m.wire.Edits[0]
	if existing.BeforeHex == nil {
		t.Fatal("fixture must first replace a completed migration")
	}
	before, _ := hex.DecodeString(*existing.BeforeHex)
	user := append(bytes.Clone(before), []byte("# saved during generation\n")...)
	report, err := m.apply(context.Background(), func(point string) error {
		if point == "before-write:"+existing.Path {
			return os.WriteFile(existing.Path, user, 0600)
		}
		return nil
	})
	if err == nil || report.RecoveryRequired {
		t.Fatalf("racing save was not restored automatically: %+v %v", report, err)
	}
	actual, err := os.ReadFile(existing.Path)
	if err != nil || !bytes.Equal(actual, user) {
		t.Fatal("overwrote the racing user save")
	}
	if _, err := os.Stat(filepath.Join(root, transactionDirectory)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("restored racing save left transaction state")
	}
	assertChecks(t, root)
}
func TestSourceApplyDoesNotDeleteConcurrentCreation(t *testing.T) {
	root, m := transactionFixture(t, false)
	e := m.wire.Edits[0]
	if e.BeforeHex != nil {
		t.Fatal("new source expected")
	}
	after, _ := hex.DecodeString(e.AfterHex)
	report, err := m.apply(context.Background(), func(point string) error {
		if point == "before-write:"+e.Path {
			return os.WriteFile(e.Path, after, 0600)
		}
		return nil
	})
	if err == nil || !report.RecoveryRequired {
		t.Fatalf("concurrent creation did not retain recovery state: %+v %v", report, err)
	}
	actual, err := os.ReadFile(e.Path)
	if err != nil || !bytes.Equal(actual, after) {
		t.Fatal("deleted an independently created file with equal bytes")
	}
	if err := os.Remove(e.Path); err != nil {
		t.Fatal(err)
	}
	if report, err := Recover(context.Background(), root); err != nil || report.RecoveryRequired {
		t.Fatalf("recovery after resolving creation conflict: %+v %v", report, err)
	}
	if err := m.VerifyDisk(); err != nil {
		t.Fatal(err)
	}
}
func TestSourceApplyPreservesPostpublicationSave(t *testing.T) {
	root, m := transactionFixture(t, true)
	e := m.wire.Edits[0]
	after, _ := hex.DecodeString(e.AfterHex)
	user := append(bytes.Clone(after), []byte("# user edited the proposal\n")...)
	report, err := m.apply(context.Background(), func(point string) error {
		if point == "written:"+e.Path {
			return os.WriteFile(e.Path, user, 0600)
		}
		return nil
	})
	if err == nil || !report.RecoveryRequired {
		t.Fatalf("edited publication not retained: %+v %v", report, err)
	}
	actual, _ := os.ReadFile(e.Path)
	if !bytes.Equal(actual, user) {
		t.Fatal("rollback overwrote user changes")
	}
	if _, err := Recover(context.Background(), root); err == nil {
		t.Fatal("recovery ignored unresolved user edits")
	}
	if err := os.WriteFile(e.Path, after, 0600); err != nil {
		t.Fatal(err)
	}
	if report, err := Recover(context.Background(), root); err != nil || report.RecoveryRequired {
		t.Fatalf("resolved recovery: %+v %v", report, err)
	}
	if err := m.VerifyDisk(); err != nil {
		t.Fatal(err)
	}
}
func TestSourceApplyOwnsRecoveryLock(t *testing.T) {
	root, m := transactionFixture(t, false)
	tested := false
	report, err := m.apply(context.Background(), func(point string) error {
		if point == "journal-durable" {
			tested = true
			if _, err := Recover(context.Background(), root); err == nil || !strings.Contains(err.Error(), "active") {
				t.Fatalf("recovery entered an active transaction: %v", err)
			}
		}
		return nil
	})
	if err != nil || report.RecoveryRequired || !tested {
		t.Fatalf("locked application: %+v %v", report, err)
	}
	assertProposed(t, m)
}
func TestSourceApplyCancellationRestoresChanges(t *testing.T) {
	root, m := transactionFixture(t, true)
	before := sourceSnapshot(t, root)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	report, err := m.apply(ctx, func(point string) error {
		if point == "written:"+m.wire.Edits[0].Path {
			cancel()
		}
		return nil
	})
	if !errors.Is(err, context.Canceled) || report.RecoveryRequired || !reflect.DeepEqual(before, sourceSnapshot(t, root)) {
		t.Fatalf("cancellation did not restore: %+v %v", report, err)
	}
}
func runSourceChild(t *testing.T, root string, m *Manifest, operation, stop string) {
	t.Helper()
	file := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(file, m.JSON(), 0600); err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, executable, "-test.run=^TestSourceTransactionProcessHelper$")
	cmd.Env = append(os.Environ(), "TESL_SOURCE_EDIT_TEST_ROOT="+root, "TESL_SOURCE_EDIT_TEST_MANIFEST="+file, "TESL_SOURCE_EDIT_TEST_OPERATION="+operation, "TESL_SOURCE_EDIT_TEST_STOP="+stop)
	out, err := cmd.CombinedOutput()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 73 {
		t.Fatalf("child did not reach %s: %s %v", stop, out, err)
	}
}
func TestSourceTransactionProcessHelper(t *testing.T) {
	root := os.Getenv("TESL_SOURCE_EDIT_TEST_ROOT")
	if root == "" {
		return
	}
	data, err := os.ReadFile(os.Getenv("TESL_SOURCE_EDIT_TEST_MANIFEST"))
	if err != nil {
		t.Fatal(err)
	}
	m, err := Decode(data)
	if err != nil {
		t.Fatal(err)
	}
	checkpoint := func(name string) error {
		if name == os.Getenv("TESL_SOURCE_EDIT_TEST_STOP") {
			os.Exit(73)
		}
		return nil
	}
	if os.Getenv("TESL_SOURCE_EDIT_TEST_OPERATION") == "recover" {
		_, err = recoverWithCheckpoint(context.Background(), root, checkpoint)
	} else {
		_, err = m.apply(context.Background(), checkpoint)
	}
	t.Fatalf("requested checkpoint not reached: %v", err)
}
func TestSourceRecoveryAfterRealProcessExit(t *testing.T) {
	for _, next := range []bool{false, true} {
		for _, phase := range []string{"before-prepare", "journal-durable", "staged", "published", "written", "before-commit", "committed"} {
			t.Run(fmt.Sprintf("next=%t/%s", next, phase), func(t *testing.T) {
				root, m := transactionFixture(t, next)
				before := sourceSnapshot(t, root)
				stop := phase
				if phase == "staged" || phase == "published" || phase == "written" {
					stop += ":" + m.wire.Edits[0].Path
				}
				runSourceChild(t, root, m, "apply", stop)
				report, err := Recover(context.Background(), root)
				if err != nil || report.RecoveryRequired {
					t.Fatalf("restart recovery: %+v %v", report, err)
				}
				if phase == "committed" {
					assertProposed(t, m)
				} else if !reflect.DeepEqual(before, sourceSnapshot(t, root)) {
					t.Fatal("restart did not restore original sources")
				}
				assertChecks(t, root)
			})
		}
	}
}
func TestSourceRecoveryCanItselfBeInterrupted(t *testing.T) {
	for _, phase := range []string{"captured", "restored"} {
		t.Run(phase, func(t *testing.T) {
			root, m := transactionFixture(t, true)
			before := sourceSnapshot(t, root)
			runSourceChild(t, root, m, "apply", "before-commit")
			// Rollback traverses in reverse, so stop on the existing first edit after
			// all new files have already been restored to absence.
			runSourceChild(t, root, m, "recover", phase+":"+m.wire.Edits[0].Path)
			if report, err := Recover(context.Background(), root); err != nil || report.RecoveryRequired {
				t.Fatalf("second restart: %+v %v", report, err)
			}
			if !reflect.DeepEqual(before, sourceSnapshot(t, root)) {
				t.Fatal("interrupted inverse lost original source")
			}
		})
	}
}

func TestSourceRecoverySurvivesTerminalCleanupExits(t *testing.T) {
	for _, point := range []string{"outcome-committed", "cleaned:source-000000", "cleaned:journal.json", "cleaned:owner"} {
		t.Run(point, func(t *testing.T) {
			root, m := transactionFixture(t, true)
			runSourceChild(t, root, m, "apply", point)
			report, err := Recover(context.Background(), root)
			if err != nil || report.RecoveryRequired {
				t.Fatalf("terminal cleanup: %+v %v", report, err)
			}
			assertProposed(t, m)
			assertChecks(t, root)
		})
	}
	for _, point := range []string{"outcome-restored", "cleaned:capture-000000", "cleaned:journal.json", "cleaned:owner"} {
		t.Run("inverse/"+point, func(t *testing.T) {
			root, m := transactionFixture(t, true)
			before := sourceSnapshot(t, root)
			runSourceChild(t, root, m, "apply", "before-commit")
			runSourceChild(t, root, m, "recover", point)
			report, err := Recover(context.Background(), root)
			if err != nil || report.RecoveryRequired {
				t.Fatalf("inverse cleanup: %+v %v", report, err)
			}
			if !reflect.DeepEqual(before, sourceSnapshot(t, root)) {
				t.Fatal("cleanup restart changed restored sources")
			}
		})
	}
}
func TestSourceRecoveryUnpublishedOutcomeJournal(t *testing.T) {
	for _, bytes := range []string{"{", `{"phase":"committed"}`} {
		t.Run(bytes, func(t *testing.T) {
			root, m := transactionFixture(t, true)
			before := sourceSnapshot(t, root)
			runSourceChild(t, root, m, "apply", "before-commit")
			if err := os.WriteFile(filepath.Join(root, transactionDirectory, "journal.tmp"), []byte(bytes), 0600); err != nil {
				t.Fatal(err)
			}
			if report, err := Recover(context.Background(), root); err != nil || report.RecoveryRequired {
				t.Fatalf("unpublished outcome: %+v %v", report, err)
			}
			if !reflect.DeepEqual(before, sourceSnapshot(t, root)) {
				t.Fatal("unpublished outcome authorized commit")
			}
		})
	}
}
func TestSourceRecoveryRejectsChangedJournal(t *testing.T) {
	for _, change := range []string{"phase", "root", "digest", "directories", "modes", "duplicate", "unknown", "nonce"} {
		t.Run(change, func(t *testing.T) {
			root, m := transactionFixture(t, false)
			runSourceChild(t, root, m, "apply", "before-commit")
			file := filepath.Join(root, transactionDirectory, "journal.json")
			original, err := os.ReadFile(file)
			if err != nil {
				t.Fatal(err)
			}
			var j map[string]any
			if err := json.Unmarshal(original, &j); err != nil {
				t.Fatal(err)
			}
			switch change {
			case "nonce":
				j["nonce"] = ""
			case "phase":
				j["phase"] = "guessed"
			case "root":
				j["manifest"].(map[string]any)["projectRoot"] = filepath.Dir(root)
			case "digest":
				j["manifestHash"] = strings.Repeat("0", 64)
			case "directories":
				j["createdDirectories"] = []any{}
			case "modes":
				j["modes"] = []any{77777}
			case "unknown":
				j["extra"] = true
			}
			changed, err := json.Marshal(j)
			if err != nil {
				t.Fatal(err)
			}
			if change == "duplicate" {
				changed = bytes.Replace(changed, []byte(`"phase":"prepared"`), []byte(`"phase":"prepared","phase":"committed"`), 1)
			}
			if err := os.WriteFile(file, changed, 0600); err != nil {
				t.Fatal(err)
			}
			before := sourceSnapshot(t, root)
			if _, err := Recover(context.Background(), root); err == nil {
				t.Fatal("modified journal accepted")
			}
			if !reflect.DeepEqual(before, sourceSnapshot(t, root)) {
				t.Fatal("invalid recovery wrote source or metadata")
			}
			if err := os.WriteFile(file, original, 0600); err != nil {
				t.Fatal(err)
			}
			if _, err := Recover(context.Background(), root); err != nil {
				t.Fatal(err)
			}
		})
	}
}
func TestSourceApplyPreservesModesAndRejectsModeRaces(t *testing.T) {
	for _, race := range []bool{false, true} {
		t.Run(fmt.Sprint(race), func(t *testing.T) {
			root, m := transactionFixture(t, true)
			e := m.wire.Edits[0]
			if err := os.Chmod(e.Path, 0640); err != nil {
				t.Fatal(err)
			}
			report, err := m.apply(context.Background(), func(point string) error {
				if race && point == "staged:"+e.Path {
					return os.Chmod(e.Path, 0600)
				}
				return nil
			})
			info, statErr := os.Stat(e.Path)
			if statErr != nil {
				t.Fatal(statErr)
			}
			if race {
				if err == nil || report.RecoveryRequired || info.Mode().Perm() != 0600 {
					t.Fatalf("mode race: %+v %v %o", report, err, info.Mode().Perm())
				}
			} else {
				if err != nil || info.Mode().Perm() != 0640 {
					t.Fatalf("mode preservation: %v %o", err, info.Mode().Perm())
				}
				assertProposed(t, m)
			}
			assertChecks(t, root)
		})
	}
}
func TestSourceApplyRejectsUnsavedViewBeforeWriting(t *testing.T) {
	root, _, raw := compilerManifest(t)
	var wire map[string]any
	if err := json.Unmarshal(raw, &wire); err != nil {
		t.Fatal(err)
	}
	inputs := wire["inputs"].([]any)
	inputs[0].(map[string]any)["sourceHash"] = strings.Repeat("1", 64)
	modified, _ := json.Marshal(wire)
	m, err := Decode(modified)
	if err != nil {
		t.Fatal(err)
	}
	before := sourceSnapshot(t, root)
	if _, err := m.Apply(context.Background()); err == nil {
		t.Fatal("unsaved source was silently saved")
	}
	if !reflect.DeepEqual(before, sourceSnapshot(t, root)) {
		t.Fatal("unsaved refusal wrote files")
	}
}
func TestSourceRecoveryOrphanPreparation(t *testing.T) {
	for _, temporary := range []bool{false, true} {
		t.Run(fmt.Sprint(temporary), func(t *testing.T) {
			root, m := transactionFixture(t, false)
			before := sourceSnapshot(t, root)
			state := filepath.Join(root, transactionDirectory)
			if err := os.Mkdir(state, 0700); err != nil {
				t.Fatal(err)
			}
			if temporary {
				if err := os.WriteFile(filepath.Join(state, "journal.tmp"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			if report, err := Recover(context.Background(), root); err != nil || report.RecoveryRequired {
				t.Fatalf("orphan preparation: %+v %v", report, err)
			}
			if !reflect.DeepEqual(before, sourceSnapshot(t, root)) {
				t.Fatal("orphan cleanup changed sources")
			}
			if err := m.VerifyDisk(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestSourceApplyRefusesPendingTransactionEvenWithoutEdits(t *testing.T) {
	root, m := transactionFixture(t, false)
	if _, err := m.Apply(context.Background()); err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(root, transactionDirectory)
	if err := os.Mkdir(state, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(state, "journal.tmp"), []byte("{"), 0600); err != nil {
		t.Fatal(err)
	}
	// This fresh compiler snapshot sees the transaction directory, so ordinary
	// directory hashes alone cannot reject it; an idempotent refresh must refuse.
	noEdits := compilerPreview(t, root, false)
	if len(noEdits.wire.Edits) != 0 {
		t.Fatal("fixture must be an idempotent refresh")
	}
	before := sourceSnapshot(t, root)
	report, err := noEdits.Apply(context.Background())
	if err == nil || !report.RecoveryRequired || !reflect.DeepEqual(before, sourceSnapshot(t, root)) {
		t.Fatalf("no-op hid pending state: %+v %v", report, err)
	}
	if _, err := Recover(context.Background(), root); err != nil {
		t.Fatal(err)
	}
	if _, err := compilerPreview(t, root, false).Apply(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestSourceApplyRefusesUnsavedDirectoryView(t *testing.T) {
	root, m := transactionFixture(t, false)
	wire := m.wire
	value := strings.Repeat("1", 64)
	wire.Directories[0].SourceHash = &value
	changed, err := Decode(encode(wire))
	if err != nil {
		t.Fatal(err)
	}
	before := sourceSnapshot(t, root)
	if _, err := changed.Apply(context.Background()); err == nil {
		t.Fatal("unsaved directory view applied")
	}
	if !reflect.DeepEqual(before, sourceSnapshot(t, root)) {
		t.Fatal("directory refusal wrote sources")
	}
}
func TestSourceInverseDoesNotOverwriteConcurrentCapture(t *testing.T) {
	root, m := transactionFixture(t, true)
	before := sourceSnapshot(t, root)
	runSourceChild(t, root, m, "apply", "before-commit")
	target := m.wire.Edits[0].Path
	capture := filepath.Join(root, transactionDirectory, "capture-000000")
	fired := false
	report, err := recoverWithCheckpoint(context.Background(), root, func(point string) error {
		if point == "before-capture:"+target {
			fired = true
			return os.WriteFile(capture, []byte("concurrent recovery note"), 0600)
		}
		return nil
	})
	if !fired || err == nil || !report.RecoveryRequired {
		t.Fatalf("capture race: %+v %v", report, err)
	}
	data, err := os.ReadFile(capture)
	if err != nil || string(data) != "concurrent recovery note" {
		t.Fatalf("concurrent capture was overwritten: %q %v", data, err)
	}
	after, _ := hex.DecodeString(m.wire.Edits[0].AfterHex)
	data, err = os.ReadFile(target)
	if err != nil || !bytes.Equal(data, after) {
		t.Fatal("failed no-replace capture changed published source")
	}
	if err := os.Remove(capture); err != nil {
		t.Fatal(err)
	}
	if report, err := Recover(context.Background(), root); err != nil || report.RecoveryRequired {
		t.Fatalf("resolved capture recovery: %+v %v", report, err)
	}
	if !reflect.DeepEqual(before, sourceSnapshot(t, root)) {
		t.Fatal("resolved inverse lost the original project")
	}
}
