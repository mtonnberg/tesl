//go:build linux

package sourceedit

import (
	"bytes"
	"context"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestSourcePreparationFailurePreservesSources(t *testing.T) {
	for _, foreign := range []bool{false, true} {
		t.Run(map[bool]string{false: "cancellation", true: "unrelated-file"}[foreign], func(t *testing.T) {
			root, m := transactionFixture(t, true)
			before := sourceSnapshot(t, root)
			fault := errors.New("preparation failed")
			extra := filepath.Join(root, transactionDirectory, "user.txt")
			report, err := m.apply(context.Background(), func(point string) error {
				if point == "before-prepare" {
					if foreign {
						if err := os.WriteFile(extra, []byte("keep me"), 0600); err != nil {
							t.Fatal(err)
						}
					}
					return fault
				}
				return nil
			})
			if !errors.Is(err, fault) || report.RecoveryRequired != foreign {
				t.Fatalf("preparation failure: %+v %v", report, err)
			}
			if foreign {
				data, err := os.ReadFile(extra)
				if err != nil || string(data) != "keep me" {
					t.Fatal("preparation discarded user file")
				}
				if _, err := Recover(context.Background(), root); err == nil {
					t.Fatal("orphan cleanup ignored unknown file")
				}
				if err := os.Remove(extra); err != nil {
					t.Fatal(err)
				}
				if _, err := Recover(context.Background(), root); err != nil {
					t.Fatal(err)
				}
			}
			if !reflect.DeepEqual(before, sourceSnapshot(t, root)) {
				t.Fatal("failed preparation changed source")
			}
		})
	}
}
func TestSourceApplyPreservesWriteThroughDisplacedFileHandle(t *testing.T) {
	root, m := transactionFixture(t, true)
	target := m.wire.Edits[0]
	original, _ := hex.DecodeString(*target.BeforeHex)
	user := append(bytes.Clone(original), []byte("# old editor file handle saved\n")...)
	old, err := os.OpenFile(target.Path, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = old.Close() }()
	fired := false
	report, err := m.apply(context.Background(), func(point string) error {
		if point == "written:"+target.Path {
			fired = true
			if _, err := old.WriteAt(user, 0); err != nil {
				return err
			}
			return old.Truncate(int64(len(user)))
		}
		return nil
	})
	if !fired || err == nil || report.RecoveryRequired {
		t.Fatalf("displaced handle save: %+v %v", report, err)
	}
	actual, err := os.ReadFile(target.Path)
	if err != nil || !bytes.Equal(actual, user) {
		t.Fatal("save through displaced handle was lost")
	}
	if _, err := os.Stat(filepath.Join(root, transactionDirectory)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("restored save retained transaction")
	}
	assertChecks(t, root)
}
func TestSourceInversePreservesSaveAfterLastComparison(t *testing.T) {
	root, m := transactionFixture(t, true)
	runSourceChild(t, root, m, "apply", "before-commit")
	target := m.wire.Edits[0].Path
	user := []byte("# saved immediately before inverse capture\n")
	fired := false
	report, err := recoverWithCheckpoint(context.Background(), root, func(point string) error {
		if point == "before-capture:"+target {
			fired = true
			return os.WriteFile(target, user, 0600)
		}
		return nil
	})
	if !fired || err == nil || !report.RecoveryRequired {
		t.Fatalf("inverse save: %+v %v", report, err)
	}
	for _, path := range []string{target, filepath.Join(root, transactionDirectory, "capture-000000")} {
		actual, err := os.ReadFile(path)
		if err != nil || !bytes.Equal(actual, user) {
			t.Fatalf("inverse lost user bytes at %s: %v", path, err)
		}
	}
	before := sourceSnapshot(t, root)
	if _, err := Recover(context.Background(), root); err == nil {
		t.Fatal("unresolved captured save was discarded")
	}
	if !reflect.DeepEqual(before, sourceSnapshot(t, root)) {
		t.Fatal("repeat recovery rewrote captured user bytes")
	}
}
func TestSourceRecoveryRefusesRedirectedPublishedSource(t *testing.T) {
	root, m := transactionFixture(t, true)
	before := sourceSnapshot(t, root)
	runSourceChild(t, root, m, "apply", "before-commit")
	target := m.wire.Edits[0].Path
	outside := filepath.Join(t.TempDir(), "user.txt")
	if err := os.WriteFile(outside, []byte("outside user work"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(target); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, target); err != nil {
		t.Fatal(err)
	}
	report, err := Recover(context.Background(), root)
	if err == nil || !report.RecoveryRequired {
		t.Fatalf("redirected recovery: %+v %v", report, err)
	}
	actual, err := os.ReadFile(outside)
	if err != nil || string(actual) != "outside user work" {
		t.Fatal("recovery changed redirected user data")
	}
	if _, err := os.Readlink(target); err != nil {
		t.Fatal("recovery replaced the user's link")
	}
	if err := os.Remove(target); err != nil {
		t.Fatal(err)
	}
	after, _ := hex.DecodeString(m.wire.Edits[0].AfterHex)
	if err := os.WriteFile(target, after, 0600); err != nil {
		t.Fatal(err)
	}
	if report, err := Recover(context.Background(), root); err != nil || report.RecoveryRequired {
		t.Fatalf("resolved redirection: %+v %v", report, err)
	}
	if !reflect.DeepEqual(before, sourceSnapshot(t, root)) {
		t.Fatal("resolved redirection did not restore original tree")
	}
}
