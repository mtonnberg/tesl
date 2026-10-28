//go:build linux

package sourceedit

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestSourceApplyPreservesForeignDirectories(t *testing.T) {
	for _, point := range []string{"before-directory:", "staged-directory:"} {
		t.Run(point, func(t *testing.T) {
			root, m := transactionFixture(t, false)
			dirs := requiredDirectories(m.wire)
			if len(dirs) == 0 {
				t.Fatal("fixture needs new directories")
			}
			target := dirs[0]
			before := sourceSnapshot(t, root)
			fired := false
			report, err := m.apply(context.Background(), func(name string) error {
				if name == point+target {
					fired = true
					return os.Mkdir(target, 0750)
				}
				return nil
			})
			if !fired || err == nil || report.RecoveryRequired {
				t.Fatalf("foreign directory: %+v %v", report, err)
			}
			relative, _ := filepath.Rel(root, target)
			before[relative] = sourceNode{Mode: os.ModeDir | 0750}
			if !reflect.DeepEqual(before, sourceSnapshot(t, root)) {
				t.Fatal("foreign directory removed, replaced, or left with transaction data")
			}
		})
	}
}

func TestSourceDirectoryRecoverySurvivesProcessExit(t *testing.T) {
	for _, point := range []string{"staged-directory:", "after-directory:", "captured-directory:", "cleaned-directory:"} {
		t.Run(point, func(t *testing.T) {
			root, m := transactionFixture(t, false)
			before := sourceSnapshot(t, root)
			dirs := requiredDirectories(m.wire)
			if len(dirs) == 0 {
				t.Fatal("fixture needs new directories")
			}
			target := dirs[0]
			if point == "captured-directory:" {
				runSourceChild(t, root, m, "apply", "before-commit")
				runSourceChild(t, root, m, "recover", point+target)
			} else {
				runSourceChild(t, root, m, "apply", point+target)
			}
			report, err := Recover(context.Background(), root)
			if err != nil || report.RecoveryRequired {
				t.Fatalf("directory restart: %+v %v", report, err)
			}
			if point == "cleaned-directory:" {
				assertProposed(t, m)
			} else if !reflect.DeepEqual(before, sourceSnapshot(t, root)) {
				t.Fatal("directory inverse did not restore original tree")
			}
		})
	}
}

func TestSourceDirectoryInversePreservesLateUserFile(t *testing.T) {
	for _, duringCapture := range []bool{false, true} {
		t.Run(fmt.Sprint(duringCapture), func(t *testing.T) {
			root, m := transactionFixture(t, false)
			before := sourceSnapshot(t, root)
			dirs := requiredDirectories(m.wire)
			if len(dirs) == 0 {
				t.Fatal("fixture needs new directories")
			}
			target := dirs[len(dirs)-1]
			runSourceChild(t, root, m, "apply", "before-commit")
			point := "before-restore:" + m.wire.Edits[len(m.wire.Edits)-1].Path
			slot := target
			if duringCapture {
				point = "captured-directory:" + target
				slot = filepath.Join(root, transactionDirectory, fmt.Sprintf("removed-directory-%06d", len(dirs)-1))
			}
			fired := false
			report, err := recoverWithCheckpoint(context.Background(), root, func(name string) error {
				if name == point {
					fired = true
					return os.WriteFile(filepath.Join(slot, "user.txt"), []byte("keep my work"), 0600)
				}
				return nil
			})
			if !fired || err == nil || !report.RecoveryRequired {
				t.Fatalf("late directory save: %+v %v", report, err)
			}
			path := filepath.Join(target, "user.txt")
			data, err := os.ReadFile(path)
			if err != nil || string(data) != "keep my work" {
				t.Fatalf("user file lost or relocated: %q %v", data, err)
			}
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			if report, err := Recover(context.Background(), root); err != nil || report.RecoveryRequired {
				t.Fatalf("resolved directory: %+v %v", report, err)
			}
			if !reflect.DeepEqual(before, sourceSnapshot(t, root)) {
				t.Fatal("resolved directory inverse differs")
			}
		})
	}
}
