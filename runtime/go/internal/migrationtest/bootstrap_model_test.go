package migrationtest

import (
	"fmt"
	"maps"
	"reflect"
	"slices"
	"testing"
)

func bootstrapSnapshots() map[int]BootstrapSnapshot {
	return map[int]BootstrapSnapshot{
		8: {Hash: "eight", Objects: map[string]string{"notes.id": "int primary key", "notes.title": "text nullable"}},
		9: {Hash: "nine", Objects: map[string]string{"notes.id": "int primary key", "notes.title": "text nullable", "notes.label": "text nullable"}},
	}
}

func bootApply(t *testing.T, m *BootstrapModel, ops ...Op) {
	t.Helper()
	for _, op := range ops {
		if err := m.Apply(op); err != nil {
			t.Fatalf("bootstrap %+v: %v", op, err)
		}
	}
}

func bootDenied(t *testing.T, m *BootstrapModel, op Op) {
	t.Helper()
	before := m.Clone()
	if err := m.Apply(op); err == nil {
		t.Fatalf("forbidden bootstrap operation accepted: %+v", op)
	}
	if !reflect.DeepEqual(m, before) {
		t.Fatalf("refused bootstrap operation changed state: %+v", op)
	}
}

func finishBootObjects(t *testing.T, m *BootstrapModel, version int, holder string) {
	t.Helper()
	for _, object := range slices.Sorted(maps.Keys(m.Snapshots[version].Objects)) {
		bootApply(t, m, Op{Kind: "install-object", ID: object, Hash: m.Snapshots[version].Objects[object], Version: version, Holder: holder})
	}
}

// INV-BOOT-LOCK, INV-INSTALL-TARGET, INV-INSTALL-ATOMIC, INV-INSTALL-CATALOG; TR-BOOT-LOCK, TR-BOOT-CRASH, TR-INSTALL-SELECT, TR-INSTALL-OBJECT, TR-INSTALL-RECORD, TR-BOOT-EXPAND, TR-BOOT-RELEASE.
func TestBootstrapWinnerSurvivesEveryPartialInstallCrash(t *testing.T) {
	for _, winner := range []int{8, 9} {
		for progress := 0; progress <= len(bootstrapSnapshots()[winner].Objects); progress++ {
			t.Run(fmt.Sprintf("winner-%d/objects-%d", winner, progress), func(t *testing.T) {
				m := NewBootstrapModel(bootstrapSnapshots())
				bootApply(t, m, Op{Kind: "boot-lock", Holder: "first"}, Op{Kind: "install-select", Version: winner, Holder: "first"})
				bootDenied(t, m, Op{Kind: "boot-lock", Holder: "newer"})
				for _, object := range slices.Sorted(maps.Keys(m.Snapshots[winner].Objects))[:progress] {
					bootApply(t, m, Op{Kind: "install-object", ID: object, Hash: m.Snapshots[winner].Objects[object], Version: winner, Holder: "first"})
				}
				if m.History != nil {
					t.Fatal("partial install published admission/history")
				}
				bootApply(t, m, Op{Kind: "boot-crash", Holder: "first"}, Op{Kind: "boot-lock", Holder: "newer"}, Op{Kind: "install-select", Version: 9, Holder: "newer"})
				if m.Installing != winner {
					t.Fatal("successor replaced persisted install target")
				}
				bootDenied(t, m, Op{Kind: "install-object", ID: "notes.id", Hash: "int primary key", Version: winner, Holder: "first"})
				finishBootObjects(t, m, winner, "newer")
				bootApply(t, m, Op{Kind: "install-record", Version: winner, Hash: m.Snapshots[winner].Hash, Holder: "newer"})
				if m.Installing != 0 || m.History.Base != winner || m.History.Floor != winner || m.History.Compat != winner || m.History.Versions[winner] != "contracted" {
					t.Fatal("initial install did not atomically publish its complete initial history")
				}
				if winner == 8 {
					finishBootObjects(t, m, 9, "newer")
					bootApply(t, m, Op{Kind: "boot-expand", Version: 9, Hash: "nine", Holder: "newer"})
					if !m.History.Admitted(8) || !m.History.Admitted(9) {
						t.Fatal("winner V8 did not admit the ordinary V8/V9 additive window")
					}
				} else if m.History.Admitted(8) {
					t.Fatal("database born at V9 invented V8 rollback history")
				}
				bootApply(t, m, Op{Kind: "boot-release", Holder: "newer"})
			})
		}
	}
}

// INV-BOOT-LOCK, INV-INSTALL-TARGET, INV-INSTALL-CATALOG, INV-INSTALL-ATOMIC; TR-INSTALL-SELECT, TR-INSTALL-OBJECT, TR-INSTALL-RECORD, TR-BOOT-CRASH.
func TestBootstrapRefusesWrongTargetIncompleteCatalogAndStaleOwner(t *testing.T) {
	m := NewBootstrapModel(bootstrapSnapshots())
	bootDenied(t, m, Op{Kind: "install-select", Version: 8, Holder: "first"})
	bootApply(t, m, Op{Kind: "boot-lock", Holder: "first"})
	bootDenied(t, m, Op{Kind: "install-select", Version: 10, Holder: "first"})
	bootApply(t, m, Op{Kind: "install-select", Version: 8, Holder: "first"})
	bootDenied(t, m, Op{Kind: "install-object", ID: "notes.label", Hash: "text nullable", Version: 9, Holder: "first"})
	bootDenied(t, m, Op{Kind: "install-record", Version: 8, Hash: "eight", Holder: "first"})
	bootDenied(t, m, Op{Kind: "boot-crash", Holder: "stranger"})
	finishBootObjects(t, m, 8, "first")
	bootDenied(t, m, Op{Kind: "install-record", Version: 9, Hash: "nine", Holder: "first"})
	bootDenied(t, m, Op{Kind: "install-record", Version: 8, Hash: "edited", Holder: "first"})
	bootApply(t, m, Op{Kind: "install-record", Version: 8, Hash: "eight", Holder: "first"}, Op{Kind: "boot-crash", Holder: "first"})
	if m.History.Floor != 8 || m.Installing != 0 {
		t.Fatal("crash after install commit lost durable history")
	}
	clone := m.Clone()
	clone.Catalog["notes.id"] = "text"
	if err := clone.Check(); err == nil {
		t.Fatal("catalog drift was accepted")
	}
	clone = m.Clone()
	clone.History.Floor = 9
	if err := clone.Check(); err == nil {
		t.Fatal("corrupted install history was accepted")
	}
	if m.Catalog["notes.id"] != "int primary key" || m.History.Floor != 8 {
		t.Fatal("model snapshots share mutable catalog/history")
	}
	bootApply(t, m, Op{Kind: "boot-lock", Holder: "retry"}, Op{Kind: "install-record", Version: 8, Hash: "eight", Holder: "retry"})
	bootDenied(t, m, Op{Kind: "install-record", Version: 8, Hash: "edited", Holder: "retry"})
	finishBootObjects(t, m, 9, "retry")
	bootApply(t, m, Op{Kind: "boot-expand", Version: 9, Hash: "nine", Holder: "retry"}, Op{Kind: "boot-expand", Version: 9, Hash: "nine", Holder: "retry"})
	bootDenied(t, m, Op{Kind: "install-record", Version: 8, Hash: "eight", Holder: "retry"})
	bootDenied(t, m, Op{Kind: "install-record", Version: 9, Hash: "nine", Holder: "retry"})
	bootDenied(t, m, Op{Kind: "boot-expand", Version: 9, Hash: "edited", Holder: "retry"})
}
