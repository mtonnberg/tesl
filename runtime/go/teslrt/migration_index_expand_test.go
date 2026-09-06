package teslrt

import (
	"encoding/json"
	"fmt"
	"reflect"
	"slices"
	"strings"
	"testing"
)

// Unlike the control API fixtures, these histories go through the production
// expansion executor. Both kinds reuse a populated V1 table; the unique key is
// newly nullable so every already admitted old writer continues to omit NULL.
func pgIndexExpansionTestHistory(namespace string, current int, unique bool) PgCompiledMigrationHistory {
	index := PgMigrationCatalogIndex{Name: "active__v2", Columns: []string{"active"}}
	if unique {
		index = PgMigrationCatalogIndex{Name: "token__v2", Columns: []string{"token"}, Unique: true}
	}
	steps := []PgMigrationExpansionStep{
		{Version: 1, SnapshotHash: strings.Repeat("1", 64), EpochPreserving: true, Operations: []PgMigrationExpansionOperation{
			{Kind: "create-table", Table: "notes", Columns: []PgMigrationCatalogColumn{
				pgPlanTestColumn("id", "text", false, true), pgPlanTestColumn("active", "bool", false, false)}, Indexes: []PgMigrationCatalogIndex{}},
		}},
		{Version: 2, SnapshotHash: strings.Repeat("2", 64), EpochPreserving: true, Operations: []PgMigrationExpansionOperation{
			{Kind: "add-column", Table: "notes", Column: &PgMigrationCatalogColumn{Name: "token", Type: "text", Nullable: true}},
			{Kind: "build-index-concurrently", Table: "notes", Index: &index},
		}},
		{Version: 3, SnapshotHash: strings.Repeat("3", 64), EpochPreserving: true, Operations: []PgMigrationExpansionOperation{
			{Kind: "add-column", Table: "notes", Column: &PgMigrationCatalogColumn{Name: "note", Type: "text", Nullable: true}},
			{Kind: "retain-index", Table: "notes", Index: &index},
		}},
	}[:current]
	pgPlanTestSeal(steps)
	origins := []any{}
	for origin := range current {
		baseline := PgMigrationExpansionStep{Version: origin + 1, SnapshotHash: steps[origin].SnapshotHash, EpochPreserving: true}
		for _, table := range steps[origin].Catalog {
			baseline.Operations = append(baseline.Operations, PgMigrationExpansionOperation{
				Kind: "create-table", Table: table.Name, Columns: slices.Clone(table.Columns), Indexes: table.Indexes})
		}
		chain := append([]PgMigrationExpansionStep{baseline}, steps[origin+1:]...)
		pgPlanTestSeal(chain)
		origins = append(origins, map[string]any{"initialVersion": origin + 1, "steps": pgPlanTestStepsJSON(chain), "errors": []any{}})
	}
	history := PgCompiledMigrationHistory{Database: "App.Main", Family: "NotesSchema", Namespace: namespace, CurrentVersion: current,
		SourceCompilerABI: pgTestSourceABI, StoredValueCompatibility: pgTestStoredValueCompatibility}
	encoded, err := json.Marshal(map[string]any{"version": 3, "kind": "compiled-migration-history", "compilerAbi": history.SourceCompilerABI,
		"storedValueCompatibility": history.StoredValueCompatibility, "databases": []any{map[string]any{
			"database": history.Database, "family": history.Family, "namespace": namespace, "currentVersion": current, "origins": origins}}})
	if err != nil {
		panic(err)
	}
	history.HistoryJSON = string(encoded)
	return history
}

func pgExpandIndexTest(t *testing.T, f *pgControlTestFixture, version int, unique bool) PgMigrationControlState {
	t.Helper()
	state, err := ExecutePgMigrationExpansion(f.ctx, f.worker, pgIndexExpansionTestHistory(f.namespace, version, unique), f.roles)
	if err != nil {
		t.Fatal(err)
	}
	return state
}

func TestPgMigrationIndexExpansionRegistersAndRetainsWithoutBuilding(t *testing.T) {
	for _, unique := range []bool{false, true} {
		t.Run(fmt.Sprintf("unique=%v", unique), func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			f.install(t, 1)
			pgExpandIndexTest(t, f, 1, unique)
			f.call(t, "insert into notes_app.notes(id,active) values('before',true)")
			state := pgExpandIndexTest(t, f, 3, unique)
			if state.Current != 3 || state.MinVersion != 1 {
				t.Fatalf("additive lifecycle: %+v", state)
			}
			jobs := pgIndexControlTestJobs(t, f)
			if len(jobs) != 1 || jobs[0].Version != 2 || jobs[0].Ordinal != 1 || jobs[0].State != "pending" || jobs[0].Attempts != 0 ||
				jobs[0].Holder != "" || jobs[0].Token != 0 || jobs[0].Index.Unique != unique {
				t.Fatalf("registration ran work or retention rewrote provenance: %+v", jobs)
			}
			var absent bool
			if err := f.worker.QueryRow(f.ctx, "select to_regclass($1) is null", "notes_app."+jobs[0].Index.Name).Scan(&absent); err != nil || !absent {
				t.Fatalf("CIC happened inside expansion: absent=%v err=%v", absent, err)
			}
			for _, version := range []int{1, 3, 2, 3} {
				if retry := pgExpandIndexTest(t, f, version, unique); !reflect.DeepEqual(state, retry) {
					t.Fatalf("V%d replay changed lifecycle", version)
				}
			}
			if !reflect.DeepEqual(jobs, pgIndexControlTestJobs(t, f)) {
				t.Fatal("retry replaced the original job or lease")
			}
			for _, version := range []int{1, 2, 3} {
				if unique && version >= 2 {
					// The tagged regression waits for the actual pending boundary
					// before cancellation, instead of treating a slow query as proof.
					continue
				}
				if _, err := pgWaitForMigrationReadiness(f.ctx, request, pgIndexExpansionTestHistory(f.namespace, version, unique), f.roles); err != nil {
					t.Fatalf("V%d safe pending index blocked readiness: %v", version, err)
				}
			}
			if _, err := request.Exec(f.ctx, "insert into notes_app.notes(id,active) values('old-writer',false)"); err != nil {
				t.Fatal(err)
			}
			var count int
			if err := request.QueryRow(f.ctx, "select count(*) from notes_app.notes where token is null and note is null").Scan(&count); err != nil || count != 2 {
				t.Fatalf("retained or old-writer row changed: %d %v", count, err)
			}
		})
	}
}

func TestPgMigrationIndexExpansionPinsUnfinishedExecutorButAllowsObserver(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	f.install(t, 1)
	pgExpandIndexTest(t, f, 1, false)
	before := pgExpandIndexTest(t, f, 2, false)
	jobs := pgIndexControlTestJobs(t, f)
	upgrade := pgIndexExpansionTestHistory(f.namespace, 3, false)
	upgrade.SourceCompilerABI = "tesl-source-abi-v1:" + strings.Repeat("b", 64)
	upgrade.HistoryJSON = strings.ReplaceAll(upgrade.HistoryJSON, pgTestSourceABI, upgrade.SourceCompilerABI)
	if _, err := ExecutePgMigrationExpansion(f.ctx, f.worker, upgrade, f.roles); err == nil || !strings.Contains(err.Error(), "unfinished index job compiler ABI") {
		t.Fatalf("new compiler executed an unfinished older job: %v", err)
	}
	after, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
	if err != nil || !reflect.DeepEqual(before, after) || !reflect.DeepEqual(jobs, pgIndexControlTestJobs(t, f)) {
		t.Fatalf("refused executor changed protected state: %v", err)
	}
	var count int
	if err := f.worker.QueryRow(f.ctx, "select count(*) from notes_app.tesl_schema_expansions where version=3").Scan(&count); err != nil || count != 0 {
		t.Fatalf("refusal began later expansion: %d %v", count, err)
	}
	observer := pgIndexExpansionTestHistory(f.namespace, 2, false)
	observer.SourceCompilerABI = upgrade.SourceCompilerABI
	observer.HistoryJSON = strings.ReplaceAll(observer.HistoryJSON, pgTestSourceABI, observer.SourceCompilerABI)
	if _, err := pgWaitForMigrationReadiness(f.ctx, request, observer, f.roles); err != nil {
		t.Fatalf("same-contract request tried to execute the unfinished job: %v", err)
	}
}

func TestPgMigrationIndexExpansionRefusesNameCollisionsWithoutProgress(t *testing.T) {
	for _, collision := range []string{"index", "table", "index on unrelated table"} {
		t.Run(collision, func(t *testing.T) {
			f, _ := pgNewWorkerTest(t)
			f.install(t, 1)
			pgExpandIndexTest(t, f, 1, false)
			switch collision {
			case "index":
				f.call(t, "create index active__v2 on notes_app.notes(active)")
			case "index on unrelated table":
				f.call(t, "create table notes_app.extra(flag bool); create index active__v2 on notes_app.extra(flag)")
			default:
				f.call(t, "create table notes_app.active__v2(id text)")
			}
			if _, err := ExecutePgMigrationExpansion(f.ctx, f.worker, pgIndexExpansionTestHistory(f.namespace, 2, false), f.roles); err == nil || !strings.Contains(err.Error(), "unrecorded relation already uses concurrent index name") {
				t.Fatalf("unrecorded name collision was not refused before expansion: %v", err)
			}
			if len(pgIndexControlTestJobs(t, f)) != 0 {
				t.Fatal("refused collision registered a protected job")
			}
			var count int
			if err := f.worker.QueryRow(f.ctx, "select count(*) from notes_app.tesl_schema_expansions where version=2").Scan(&count); err != nil || count != 0 {
				t.Fatalf("collision began later expansion: %d %v", count, err)
			}
		})
	}
}

func TestPgMigrationIndexExpansionFreshInstallCreatesBaselineIndexes(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	f.install(t, 3)
	state := pgExpandIndexTest(t, f, 3, true)
	if state.InitialVersion != 3 || state.MinVersion != 3 || len(pgIndexControlTestJobs(t, f)) != 0 {
		t.Fatalf("fresh installation invented migration jobs: %+v", state)
	}
	if _, err := pgWaitForMigrationReadiness(f.ctx, request, pgIndexExpansionTestHistory(f.namespace, 3, true), f.roles); err != nil {
		t.Fatal(err)
	}
	f.call(t, "insert into notes_app.notes(id,active,token) values('one',true,'unique')")
	if _, err := request.Exec(f.ctx, "insert into notes_app.notes(id,active,token) values('two',false,'unique')"); err == nil {
		t.Fatal("fresh baseline did not enforce its unique index")
	}
}
