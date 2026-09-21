package teslrt

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestRowQueueCompleteSourceBinding(t *testing.T) {
	directory := os.Getenv("TESL_QUEUE_SOURCE_FIXTURE")
	if directory == "" {
		t.Skip("requires exact compiler-owned queue source fixture")
	}
	for _, prefix := range []string{"", "history-", "empty-"} {
		t.Run(prefix+"inventory", func(t *testing.T) {
			read := func(name string) []byte {
				b, err := os.ReadFile(filepath.Join(directory, prefix+name))
				if err != nil {
					t.Fatal(err)
				}
				return b
			}
			base := map[string]any{}
			if err := json.Unmarshal(read("source.json"), &base); err != nil {
				t.Fatal(err)
			}
			db := queueProjectionDB(base)
			h := PgCompiledMigrationHistory{Database: db["database"].(string), Family: db["family"].(string), Namespace: db["namespace"].(string), CurrentVersion: int(db["currentVersion"].(float64)), SourceCompilerABI: base["compilerAbi"].(string), StoredValueCompatibility: base["storedValueCompatibility"].(string), HistoryJSON: string(read("source.json"))}
			// An absent companion never manufactures complete empty history, even for
			// a queue-free source snapshot.
			if _, err := pgRowQueueSources(h); err == nil || !strings.Contains(err.Error(), "metadata is missing") {
				t.Fatalf("missing source companion: %v", err)
			}
			companion := map[string]any{}
			if err := json.Unmarshal(read("queue.json"), &companion); err != nil {
				t.Fatal(err)
			}
			registerQueueProjection(t, h, companion)
			t.Cleanup(func() {
				compiledMigrationHistories.Delete(h.Family)
				compiledQueueHistories.Lock()
				delete(compiledQueueHistories.families, h.Family)
				compiledQueueHistories.Unlock()
			})
			sources, err := pgRowQueueSources(h)
			if err != nil {
				t.Fatal(err)
			}
			if len(sources) != h.CurrentVersion {
				t.Fatal("incomplete source versions")
			}
			for _, source := range sources {
				if source.bindingHash == source.version.StorageSnapshotHash || source.bindingHash == source.inventoryHash {
					t.Fatal("independent identities collapsed")
				}
				if prefix == "empty-" {
					if pgRowEncode(source.queues) != pgRowEncode(pgRowList(pgRowAtom("complete-queues"), pgRowList())) || pgRowEncode(source.facilities) != pgRowEncode(pgRowList(pgRowAtom("complete-facilities"), pgRowList())) {
						t.Fatal("empty baseline canonical inventory changed")
					}
				} else if len(source.queues.children[1].children) != 1 || len(source.facilities.children[1].children) != 1 {
					t.Fatal("nonempty queue/facility inventory was erased")
				}
				changed := source.version
				changed.SourceSealInventory = "unknown"
				regenerated := h
				regenerated.SourceCompilerABI = "tesl-source-abi-v1:" + strings.Repeat("a", 64)
				compatible, err := pgRowQueueSourceBinding(regenerated, changed)
				if err != nil {
					t.Fatal(err)
				}
				if compatible.binding != source.binding || compatible.inventoryHash != source.inventoryHash {
					t.Fatal("creator/seal provenance leaked into stored value identity")
				}
				changed.SchemaSnapshotHash = strings.Repeat("a", 64)
				substituted, err := pgRowQueueSourceBinding(h, changed)
				if err != nil {
					t.Fatal(err)
				}
				if substituted.bindingHash == source.bindingHash {
					t.Fatal("schema identity not bound")
				}
				changed = source.version
				changed.StorageSnapshotHash = strings.Repeat("a", 64)
				substituted, err = pgRowQueueSourceBinding(h, changed)
				if err != nil {
					t.Fatal(err)
				}
				if substituted.bindingHash == source.bindingHash {
					t.Fatal("source storage identity not bound")
				}
			}
		})
	}
}

func TestRowQueueCandidateCatalogBoundaries(t *testing.T) {
	functions := pgRowControlFunctions("test")
	seen := map[string]bool{}
	for _, fn := range functions {
		if seen[fn.name] {
			t.Fatalf("duplicate protected function %s", fn.name)
		}
		seen[fn.name] = true
		if fn.name == "tesl_queue_admit" && !strings.Contains(fn.body, "format_version=5") {
			t.Fatal("row queue admission lacks exact format5 authority")
		}
	}
	if !seen["tesl_register_row_queue_source"] || !seen["tesl_queue_inventory_hash"] || !seen["tesl_queue_admit"] {
		t.Fatal("incomplete combined candidate functions")
	}
	// The public3 and private4 catalog builders never acquire row5 functions.
	for _, fn := range append(pgMigrationControlFunctions("test"), pgQueueCandidateControlFunctions("test")...) {
		if fn.name == "tesl_register_row_queue_source" {
			t.Fatal("legacy catalog acquired row source mutation")
		}
	}
}

func TestRowQueueCatalogInstallerRefusesMissingSource(t *testing.T) {
	// A nil connection makes any accidental crossing of the local validation
	// boundary visible. Neither case can publish a closed application registry.
	for _, database := range []*Database{nil, NewDatabase("Unversioned", PostgresConfig{}, nil)} {
		if _, err := pgInstallCompiledRowQueueCatalog(context.Background(), nil, database, PgMigrationControlRoles{}); err == nil {
			t.Fatal("catalog installer accepted missing checked source")
		}
		if database != nil && (database.applicationPreflightClosed || database.migrationFacilitiesClosed) {
			t.Fatal("failed catalog source validation published closure")
		}
	}
}

// Synthetic row protocol fixtures must explicitly carry complete empty source
// metadata too. This is test input construction, never a production fallback.
func rowTestRegisterQueueAbsenceIfEmpty(t *testing.T, history PgCompiledMigrationHistory) {
	t.Helper()
	sources, err := pgQueueSourceProjection(history)
	if err != nil {
		t.Fatal(err)
	}
	databases := []any{}
	for _, source := range sources {
		versions, origins := []any{}, []any{}
		for i, version := range source.versions {
			for _, definition := range version.definitions {
				if !definition.atom && len(definition.children) > 0 && definition.children[0].isAtom("queue-schema") {
					// Negative source fixtures with a queue retain missing metadata.
					// They must never acquire a fabricated empty companion.
					return
				}
			}
			versions = append(versions, map[string]any{"version": i + 1, "storageSnapshotHash": version.storage, "schemaSnapshotHash": version.schema, "checkedInventory": "complete", "sourceSealInventory": "unrecorded", "contracts": []any{}})
			refs := []int{}
			for j := i + 1; j <= source.current; j++ {
				refs = append(refs, j)
			}
			origins = append(origins, map[string]any{"initialVersion": i + 1, "versions": refs})
		}
		databases = append(databases, map[string]any{"database": source.database, "family": source.family, "namespace": source.namespace, "currentVersion": source.current, "versions": versions, "origins": origins})
	}
	registerCompiledQueueHistory(rowTestJSON(t, map[string]any{"version": 1, "kind": "compiled-queue-history", "compilerAbi": history.SourceCompilerABI, "storedValueCompatibility": history.StoredValueCompatibility, "databases": databases}))
	t.Cleanup(func() {
		compiledQueueHistories.Lock()
		delete(compiledQueueHistories.families, history.Family)
		compiledQueueHistories.Unlock()
	})
}

func TestRowQueueLifecyclePreservesFormat4Operations(t *testing.T) {
	legacy, row := pgQueueOperationFunctions("test"), pgRowQueueOperationFunctions("test")
	if len(legacy) != len(row) {
		t.Fatal("row operations changed lifecycle inventory")
	}
	for i, fn := range legacy {
		if fn.name == "tesl_queue_admit" {
			if !strings.Contains(fn.body, "format_version=4") || strings.Contains(fn.body, "tesl_row_queue_sources") {
				t.Fatal("format4 admission changed")
			}
			if row[i].name != fn.name || !strings.Contains(row[i].body, "format_version=5") {
				t.Fatal("missing distinct row admission")
			}
		} else if !reflect.DeepEqual(fn, row[i]) {
			t.Fatalf("row lifecycle differs for %s", fn.name)
		}
	}
}
