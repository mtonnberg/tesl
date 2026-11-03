package teslrt

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The compiler suite writes these bytes from one owned complete capture, then
// removes all Tesl sources before this test starts. No database is opened.
func TestQueueCompleteSourceProjection(t *testing.T) {
	directory := os.Getenv("TESL_QUEUE_SOURCE_FIXTURE")
	if directory == "" {
		t.Skip("requires compiler-produced complete queue source fixture")
	}
	read := func(name string) map[string]any {
		data, err := os.ReadFile(filepath.Join(directory, name))
		if err != nil {
			t.Fatal(err)
		}
		var value map[string]any
		if err = json.Unmarshal(data, &value); err != nil {
			t.Fatal(err)
		}
		return value
	}
	history := func(base map[string]any) PgCompiledMigrationHistory {
		d := queueProjectionDB(base)
		return PgCompiledMigrationHistory{Database: d["database"].(string), Family: d["family"].(string), Namespace: d["namespace"].(string), CurrentVersion: int(d["currentVersion"].(float64)), SourceCompilerABI: base["compilerAbi"].(string), StoredValueCompatibility: base["storedValueCompatibility"].(string), HistoryJSON: queueProjectionJSON(t, base)}
	}
	check := func(base, companion map[string]any) (PgQueueSourceInventory, error) {
		return pgReadQueueHistory(history(base), queueProjectionJSON(t, companion), 1)
	}
	t.Run("actual source and no activation", func(t *testing.T) {
		base, companion := read("source.json"), read("queue.json")
		got, err := check(base, companion)
		if err != nil {
			t.Fatal(err)
		}
		if got.CurrentVersion != 1 || len(got.Versions) != 1 || got.Versions[0].SourceSealInventory != "unrecorded" || len(got.Versions[0].Contracts) != 1 || got.Versions[0].Contracts[0].Queue != "Notifications" || got.Versions[0].Contracts[0].Payloads[0].Job != "Notify" {
			t.Fatal("actual source inventory differs", got)
		}
		if _, err := history(base).ExpansionPlan(1); err == nil {
			t.Fatal("source-only queue enabled ExpansionPlan")
		}
	})
	t.Run("atomic metadata registration remains local", func(t *testing.T) {
		base, companion := read("source.json"), read("queue.json")
		h := history(base)
		t.Cleanup(func() {
			compiledMigrationHistories.Delete(h.Family)
			compiledQueueHistories.Lock()
			delete(compiledQueueHistories.families, h.Family)
			compiledQueueHistories.Unlock()
		})
		registerQueueProjection(t, h, companion)
		got, err := h.QueueSourceInventory(1)
		if err != nil || got.Versions[0].Contracts[0].Queue != "Notifications" {
			t.Fatal(got, err)
		}
		got.Versions[0].Contracts = nil
		again, err := h.QueueSourceInventory(1)
		if err != nil || len(again.Versions[0].Contracts) != 1 {
			t.Fatal("mutable source registration", err)
		}
		db := NewDatabase("D", PostgresConfig{Schema: h.Namespace}, nil)
		RegisterDatabaseMigrationHistory(db, h.Family)
		if db.open != nil || db.applicationPreflightClosed || db.migrationFacilitiesClosed {
			t.Fatal("source registration acquired runtime admission")
		}
	})

	for _, provenance := range []string{"unknown", "complete", "unrecorded"} {
		t.Run("provenance-"+provenance, func(t *testing.T) {
			base, companion := read("source.json"), read("queue.json")
			queueProjectionVersion(companion)["sourceSealInventory"] = provenance
			got, err := check(base, companion)
			if err != nil || got.Versions[0].SourceSealInventory != provenance {
				t.Fatal("source provenance became installation authority", got, err)
			}
		})
	}
	t.Run("complete original two-version history", func(t *testing.T) {
		base, companion := read("history-source.json"), read("history-queue.json")
		for origin := 1; origin <= 2; origin++ {
			got, err := pgReadQueueHistory(history(base), queueProjectionJSON(t, companion), origin)
			if err != nil || len(got.Versions) != 3-origin || got.Versions[0].SourceSealInventory != "complete" {
				t.Fatal("complete frozen source lost origin", got, err)
			}
		}
		versions := queueProjectionDB(companion)["versions"].([]any)
		versions[1].(map[string]any)["schemaSnapshotHash"] = strings.Repeat("a", 64)
		if _, err := check(base, companion); err == nil || !strings.Contains(err.Error(), "schema snapshot differs") {
			t.Fatal("later source not validated", err)
		}
	})
	t.Run("genuine empty source preserves provenance", func(t *testing.T) {
		base, companion := read("empty-source.json"), read("empty-queue.json")
		for _, provenance := range []string{"unrecorded", "unknown", "complete"} {
			queueProjectionVersion(companion)["sourceSealInventory"] = provenance
			got, err := check(base, companion)
			if err != nil || len(got.Versions[0].Contracts) != 0 || got.Versions[0].SourceSealInventory != provenance {
				t.Fatal("empty source laundered authority", got, err)
			}
		}
		queueProjectionVersion(companion)["contracts"] = queueProjectionVersion(read("queue.json"))["contracts"]
		if _, err := check(base, companion); err == nil || !strings.Contains(err.Error(), "omits or adds") {
			t.Fatal("nonempty queue substituted into empty snapshot", err)
		}
	})

	cases := map[string]struct {
		want   string
		change func(map[string]any, map[string]any)
	}{
		"missing queue":  {"omits or adds", func(_, q map[string]any) { queueProjectionVersion(q)["contracts"] = []any{} }},
		"extra database": {"omits or adds", func(_, q map[string]any) { q["databases"] = append(q["databases"].([]any), queueProjectionDB(q)) }},
		"wrong schema":   {"schema snapshot differs", func(_, q map[string]any) { queueProjectionVersion(q)["schemaSnapshotHash"] = strings.Repeat("a", 64) }},
		"wrong storage":  {"storage snapshot differs", func(_, q map[string]any) { queueProjectionVersion(q)["storageSnapshotHash"] = strings.Repeat("a", 64) }},
		"wrong queue owner": {"owner differs", func(_, q map[string]any) {
			queueProjectionVersion(q)["contracts"].([]any)[0].(map[string]any)["queue"] = "Elsewhere"
		}},
		"wrong job member":    {"belongs to another", func(_, q map[string]any) { queueProjectionPayload(q)["job"] = "Other" }},
		"missing origin":      {"every installation origin", func(_, q map[string]any) { queueProjectionDB(q)["origins"] = []any{} }},
		"missing base origin": {"omits installation origins", func(b, _ map[string]any) { queueProjectionDB(b)["origins"] = []any{} }},
		"invalid refused base origin": {"refused source origin", func(b, _ map[string]any) {
			o := queueProjectionDB(b)["origins"].([]any)[0].(map[string]any)
			o["errors"] = []any{map[string]any{"code": "MIG021", "message": "unsupported"}}
		}},
		"queue membership closure substitution": {"type root differs", func(_, q map[string]any) {
			mutateQueuePayload(t, q, func(n pgRowCanonical) pgRowCanonical {
				for _, definition := range n.children[3].children[1].children[2].children[2].children {
					if definition.children[1].list(5) && definition.children[1].children[0].isAtom("codec") {
						n.children[3].children[1].children[2].children[1].children[0] = definition.children[0]
						break
					}
				}
				return n
			})
		}},
		"freshly rehashed codec substitution": {"closure differs", func(_, q map[string]any) {
			mutateQueuePayload(t, q, func(n pgRowCanonical) pgRowCanonical {
				changed := false
				var walk func(pgRowCanonical) pgRowCanonical
				walk = func(n pgRowCanonical) pgRowCanonical {
					if n.atom && n.value == "text" {
						n.value = "changed-wire-key"
						changed = true
					}
					for i := range n.children {
						n.children[i] = walk(n.children[i])
					}
					return n
				}
				// Keep the root and keys exact; change only a codec's actual definition.
				defs := &n.children[3].children[1].children[2].children[2]
				for i, d := range defs.children {
					if d.list(2) && !d.children[1].atom && len(d.children[1].children) > 0 && d.children[1].children[0].isAtom("codec") {
						defs.children[i].children[1] = walk(d.children[1])
					}
				}
				if !changed {
					t.Fatal("fixture has no private codec body")
				}
				return n
			})
		}},
	}
	for name, test := range cases {
		t.Run(name, func(t *testing.T) {
			base, companion := read("source.json"), read("queue.json")
			test.change(base, companion)
			if _, err := check(base, companion); err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("wanted %q refusal, got %v", test.want, err)
			}
		})
	}
	t.Run("refused execution is retained source", func(t *testing.T) {
		base, companion := read("source.json"), read("queue.json")
		origin := queueProjectionDB(base)["origins"].([]any)[0].(map[string]any)
		origin["steps"] = nil
		origin["errors"] = []any{map[string]any{"code": "MIG021", "message": "execution unsupported"}}
		if _, err := check(base, companion); err != nil {
			t.Fatal("refused origin discarded complete source", err)
		}
		if _, err := history(base).ExpansionPlan(1); err == nil {
			t.Fatal("refused origin enabled execution")
		}
	})
	t.Run("empty companion does not establish empty schema", func(t *testing.T) {
		base, companion := read("source.json"), read("queue.json")
		queueProjectionVersion(companion)["contracts"] = []any{}
		queueProjectionVersion(companion)["sourceSealInventory"] = "complete"
		if _, err := check(base, companion); err == nil {
			t.Fatal("claimed empty erased real queue")
		}
	})
}
func mutateQueuePayload(t *testing.T, q map[string]any, change func(pgRowCanonical) pgRowCanonical) {
	t.Helper()
	payload := queueProjectionPayload(q)
	node, _, err := pgReadRowCanonical(payload["contract"].(string))
	if err != nil {
		t.Fatal(err)
	}
	data := []byte(pgRowEncode(change(node)))
	payload["contract"] = hex.EncodeToString(data)
	payload["contractHash"] = fmt.Sprintf("%x", sha256.Sum256(data))
}
