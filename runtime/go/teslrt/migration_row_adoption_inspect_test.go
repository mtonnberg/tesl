package teslrt

import (
	"context"
	"strings"
	"testing"
)

// These are local source/observation boundary tests, not adoption authority or
// substitutes for the ordinary compiler's original-application native fixture.
func TestPgRowAdoptionSourceBoundary(t *testing.T) {
	for _, kind := range []string{"empty", "missing inventory", "queued history", "unsealed", "wrong namespace", "duplicate owner", "unlinked"} {
		t.Run(kind, func(t *testing.T) {
			h, q := queueProjectionFixture(t)
			for _, value := range queueProjectionDB(q)["versions"].([]any) {
				v := value.(map[string]any)
				if kind != "queued history" {
					v["contracts"] = []any{}
				}
			}
			registerCompiledMigrationHistory(h.Database, h.Family, h.Namespace, h.CurrentVersion, h.SourceCompilerABI, h.StoredValueCompatibility, h.HistoryJSON)
			if kind != "missing inventory" {
				registerCompiledQueueHistory(queueProjectionJSON(t, q))
			}
			db := NewDatabase("Main", PostgresConfig{Schema: h.Namespace}, nil)
			RegisterDatabaseMigrationHistory(db, h.Family)
			RegisterDatabaseIdentity(h.Database, db)
			db.applicationPreflightClosed = kind != "unsealed"
			switch kind {
			case "wrong namespace":
				db.Config.Schema = "different"
			case "unlinked":
				compiledMigrationHistories.Delete(h.Family)
			case "duplicate owner":
				other := NewDatabase("Other", PostgresConfig{Schema: h.Namespace}, nil)
				RegisterDatabaseMigrationHistory(other, h.Family)
				alias := h.Database + ".duplicate"
				RegisterDatabaseIdentity(alias, other)
				t.Cleanup(func() { databaseIdentities.Delete(alias) })
			}
			got, err := pgCompiledLegacyRowAdoptionSource(db)
			if kind == "empty" {
				if err != nil {
					t.Fatal(err)
				}
				if got.history != h || len(got.queues.Versions) != 3 || got.queues.Versions[0].SourceSealInventory != "unrecorded" || got.queues.Versions[1].SourceSealInventory != "unknown" || got.queues.Versions[2].SourceSealInventory != "complete" {
					t.Fatal("source provenance changed", got)
				}
				if _, err := InspectPgCompiledRowAdoption(context.Background(), nil, db); err == nil || !strings.Contains(err.Error(), "idle dedicated Request") {
					t.Fatal("missing connection became observation", err)
				}
			} else if err == nil {
				t.Fatal("unsupported source accepted", kind)
			}
			if db.open != nil {
				t.Fatal("source inspection opened a database")
			}
		})
	}
	if _, err := InspectPgCompiledRowAdoption(context.Background(), nil, nil); err == nil {
		t.Fatal("nil owner accepted")
	}
}

func TestPgRowAdoptionCompletedAnchorBoundary(t *testing.T) {
	// Installed origin V2/current V3 remains anchor V3. No V1 receipt is added.
	state := PgMigrationControlState{Format: 3, InitialVersion: 2, Current: 3, MaxObservedProtocol: 1}
	plan := PgMigrationExpansionPlan{InitialVersion: 2, CurrentVersion: 3, Steps: []PgMigrationExpansionStep{{Version: 2}, {Version: 3}}}
	intents := map[int]*pgExpansionIntent{2: {}, 3: {}}
	if err := pgLegacyRowAdoptionComplete(state, plan, intents, nil); err != nil {
		t.Fatal(err)
	}
	for _, kind := range []string{"format2", "format4", "format5", "fresh", "installing", "older binary", "future protocol", "empty plan", "pending intent", "pending", "building", "failed", "terminal"} {
		t.Run(kind, func(t *testing.T) {
			s, p := state, plan
			in := map[int]*pgExpansionIntent{2: {}, 3: {}}
			var jobs []pgMigrationIndexJob
			switch kind {
			case "format2":
				s.Format = 2
			case "format4":
				s.Format = 4
			case "format5":
				s.Format = 5
			case "fresh":
				s.Current = 0
			case "installing":
				s.InstallingVersion = 4
			case "older binary":
				p.CurrentVersion = 2
			case "future protocol":
				s.MaxObservedProtocol = 2
			case "empty plan":
				p.Steps = nil
			case "pending intent":
				in[4] = &pgExpansionIntent{}
			default:
				jobs = []pgMigrationIndexJob{{State: kind}}
			}
			if err := pgLegacyRowAdoptionComplete(s, p, in, jobs); err == nil {
				t.Fatal("incomplete adoption observation accepted", kind)
			}
		})
	}
	if err := pgLegacyRowAdoptionComplete(state, plan, intents, []pgMigrationIndexJob{{State: "valid"}}); err != nil {
		t.Fatal(err)
	}
}

func TestPgRowAdoptionSummaryIsDiagnosticCopy(t *testing.T) {
	inspection := PgRowAdoptionInspection{summary: PgRowAdoptionSummary{AnchorVersion: 7, LegacyInitialVersion: 4, Tables: []PgRowAdoptionTable{{Table: "notes", Generation: 1}}, SourceSealInventory: []string{"unknown"}}}
	copy := inspection.Summary()
	if len(copy.Tables) != 1 || len(copy.SourceSealInventory) != 1 {
		t.Fatal("summary omitted fixture provenance")
	}
	copy.Tables[0].Generation = 99
	copy.SourceSealInventory[0] = "complete"
	again := inspection.Summary()
	if again.AnchorVersion != 7 || again.LegacyInitialVersion != 4 || len(again.Tables) != 1 || len(again.SourceSealInventory) != 1 || again.Tables[0].Generation != 1 || again.SourceSealInventory[0] != "unknown" {
		t.Fatal("summary mutation changed diagnostic provenance", again)
	}
}
