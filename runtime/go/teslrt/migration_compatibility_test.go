package teslrt

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func pgCompatibilityTestDurableState(t *testing.T, f *pgControlTestFixture) string {
	t.Helper()
	var value string
	if err := f.worker.QueryRow(f.ctx, `select pg_catalog.jsonb_build_array(
 (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(x) order by id) from notes_app.tesl_schema_meta x),
 (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(x) order by id) from notes_app.tesl_schema_state x),
 (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(x) order by version,step,seq) from notes_app.tesl_schema_versions x),
 (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(x) order by version) from notes_app.tesl_schema_expansions x),
 (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(x) order by version,ordinal) from notes_app.tesl_schema_expansion_objects x))::text`).Scan(&value); err != nil {
		t.Fatal(err)
	}
	return value
}

func TestPgMigrationStoredValueCompatibilityRuntimeLifecycle(t *testing.T) {
	f := pgNewControlTest(t)
	seed := f.install(t, 1)
	a := pgExpansionTestHistory(f.namespace, 1)
	if _, err := ExecutePgMigrationExpansion(f.ctx, f.worker, a, f.roles); err != nil {
		t.Fatal(err)
	}
	f.call(t, "insert into notes_app.notes(id,active) values ('retained',true)")
	for version := 2; version <= 3; version++ {
		digit := map[int]string{2: "b", 3: "d"}[version]
		history := pgCompatibilityTestCompiler(pgExpansionTestHistory(f.namespace, version), digit)
		state, err := ExecutePgMigrationExpansion(f.ctx, f.worker, history, f.roles)
		if err != nil || state.Current != version || state.DatabaseUUID != seed.DatabaseUUID {
			t.Fatalf("compatible compiler did not append V%d: %+v %v", version, state, err)
		}
		before := pgCompatibilityTestDurableState(t, f)
		if _, err := ExecutePgMigrationExpansion(f.ctx, f.worker, a, f.roles); err != nil || before != pgCompatibilityTestDurableState(t, f) {
			t.Fatalf("old compiler changed or refused completed future history: %v", err)
		}
	}
	status, err := InspectPgMigrationStatus(f.ctx, f.worker, a, f.roles)
	if err != nil || status.HistoryError != "" || status.StoredValueCompatibility != a.StoredValueCompatibility || len(status.Expansions) != 3 {
		t.Fatalf("older status lost compatible provenance: %+v %v", status, err)
	}
	for i, digit := range []string{"a", "b", "d"} {
		if status.Expansions[i].SourceCompilerABI != "tesl-source-abi-v1:"+strings.Repeat(digit, 64) || status.Expansions[i].StoredValueCompatibility != pgTestStoredValueCompatibility {
			t.Fatalf("V%d creator provenance was relabelled: %+v", i+1, status.Expansions[i])
		}
	}
	f.call(t, "insert into notes_app.notes(id,active) values ('old-writer',false)")
	var count int
	if err := f.worker.QueryRow(f.ctx, "select count(*) from notes_app.notes where published and rank=-9007199254740993").Scan(&count); err != nil || count != 2 {
		t.Fatalf("compatible compiler changed stored defaults or retained rows: %d %v", count, err)
	}
}

func TestPgMigrationStoredValueCompatibilityRefusesBeforeMutation(t *testing.T) {
	for _, scenario := range []string{"missing contract", "malformed contract", "different contract", "future contract", "lifecycle contract", "partial ABI", "legacy control format"} {
		t.Run(scenario, func(t *testing.T) {
			f := pgNewControlTest(t)
			f.install(t, 1)
			f.expand(t, 1)
			binary := pgCompatibilityTestCompiler(pgExpansionTestHistory(f.namespace, 2), "b")
			fragment := "compatibility"
			switch scenario {
			case "partial ABI":
				plan, err := pgExpansionTestHistory(f.namespace, 2).ExpansionPlan(1)
				if err != nil {
					t.Fatal(err)
				}
				step := plan.Steps[1]
				f.call(t, "select notes_app.tesl_begin_expansion(2,$1::text,$2::text,$3::text,$4::text,$5::integer,true)", step.SnapshotHash, step.StepHash, plan.SourceCompilerABI, plan.StoredValueCompatibility, len(step.Operations))
				fragment = "unfinished migration compiler ABI"
			case "legacy control format":
				if _, err := f.installer.Exec(f.ctx, "update notes_app.tesl_schema_meta set format_version=1; alter table notes_app.tesl_schema_versions drop column stored_value_compatibility; alter table notes_app.tesl_schema_expansions drop column stored_value_compatibility"); err != nil {
					t.Fatal(err)
				}
				fragment = "unsupported migration control format 1"
			default:
				value := "tesl-stored-value-v1:" + strings.Repeat("d", 64)
				version := 1
				if scenario == "future contract" {
					f.expand(t, 3)
					version = 3
					binary = pgExpansionTestHistory(f.namespace, 1)
				}
				if scenario == "missing contract" {
					value = ""
				}
				if scenario == "malformed contract" {
					value = "tesl-stored-value-v1:" + strings.Repeat("C", 64)
				}
				table := "tesl_schema_expansions"
				if scenario == "lifecycle contract" {
					table, fragment = "tesl_schema_versions", "provenance"
				}
				if _, err := f.installer.Exec(f.ctx, "update notes_app."+table+" set stored_value_compatibility=$1 where version=$2", value, version); err != nil {
					t.Fatal(err)
				}
			}
			before := pgCompatibilityTestDurableState(t, f)
			if _, err := ExecutePgMigrationExpansion(f.ctx, f.worker, binary, f.roles); err == nil || !strings.Contains(err.Error(), fragment) {
				t.Fatalf("unsafe compatibility accepted: %v", err)
			}
			if before != pgCompatibilityTestDurableState(t, f) {
				t.Fatal("refused compatibility modified durable state")
			}
			if scenario == "partial ABI" {
				f.expand(t, 2)
				if _, err := ExecutePgMigrationExpansion(f.ctx, f.worker, binary, f.roles); err != nil {
					t.Fatalf("completed original compiler intent remained pinned: %v", err)
				}
			}
		})
	}
}

func pgCompatibilityTestCompiler(history PgCompiledMigrationHistory, digit string) PgCompiledMigrationHistory {
	old := history.SourceCompilerABI
	history.SourceCompilerABI = "tesl-source-abi-v1:" + strings.Repeat(digit, 64)
	history.HistoryJSON = strings.ReplaceAll(history.HistoryJSON, old, history.SourceCompilerABI)
	return history
}

func pgCompatibilityTestState(t *testing.T, current int) (PgMigrationControlState, PgMigrationExpansionPlan, map[int]*pgExpansionIntent) {
	t.Helper()
	plan, err := pgExpansionTestHistory("notes", 3).ExpansionPlan(1)
	if err != nil {
		t.Fatal(err)
	}
	state := PgMigrationControlState{Present: true, InitialVersion: 1, Current: current}
	intents := map[int]*pgExpansionIntent{}
	for _, step := range plan.Steps[:current] {
		intent := &pgExpansionIntent{Version: step.Version, SnapshotHash: step.SnapshotHash, ArtifactHash: step.StepHash,
			SourceABI: plan.SourceCompilerABI, StoredValueCompatibility: plan.StoredValueCompatibility,
			OperationCount: len(step.Operations), EpochPreserving: true}
		for ordinal := range step.Operations {
			intent.Objects = append(intent.Objects, pgMigrationObjectHash(step.StepHash, ordinal))
		}
		intents[step.Version] = intent
		epoch := true
		state.Versions = append(state.Versions, PgMigrationControlVersion{Version: step.Version, Step: "expanded", SnapshotHash: step.SnapshotHash,
			ArtifactHash: step.StepHash, SourceABI: plan.SourceCompilerABI, StoredValueCompatibility: plan.StoredValueCompatibility,
			FenceDomain: "tesl-1", Protocol: 1, EpochPreserving: &epoch})
		if step.Version == 1 {
			for _, name := range []string{"contracting", "contracted"} {
				state.Versions = append(state.Versions, PgMigrationControlVersion{Version: 1, Step: name, ArtifactHash: step.StepHash,
					SourceABI: plan.SourceCompilerABI, StoredValueCompatibility: plan.StoredValueCompatibility, FenceDomain: "tesl-1", Protocol: 1})
			}
		}
	}
	return state, plan, intents
}

func TestPgMigrationCompatibilityPreservesCompletedCreatorProvenance(t *testing.T) {
	state, plan, intents := pgCompatibilityTestState(t, 3)
	before, err := json.Marshal([]any{state, intents})
	if err != nil {
		t.Fatal(err)
	}
	plan.SourceCompilerABI = "tesl-source-abi-v1:" + strings.Repeat("b", 64)
	if err := pgVerifyExpansionHistory(state, plan, intents); err != nil {
		t.Fatal(err)
	}
	// The older compiler may restart after a compatible future version completed.
	plan.CurrentVersion, plan.Steps = 1, plan.Steps[:1]
	if err := pgVerifyExpansionHistory(state, plan, intents); err != nil {
		t.Fatal(err)
	}
	after, err := json.Marshal([]any{state, intents})
	if err != nil || string(before) != string(after) {
		t.Fatal("compatibility verification rewrote creator provenance")
	}
}

func TestPgMigrationCompatibilityRequiresCompleteMatchingHistory(t *testing.T) {
	for name, mutate := range map[string]func(*PgMigrationControlState, *PgMigrationExpansionPlan, map[int]*pgExpansionIntent){
		"missing contract": func(_ *PgMigrationControlState, _ *PgMigrationExpansionPlan, intents map[int]*pgExpansionIntent) {
			intents[1].StoredValueCompatibility = ""
		},
		"malformed contract": func(_ *PgMigrationControlState, _ *PgMigrationExpansionPlan, intents map[int]*pgExpansionIntent) {
			intents[1].StoredValueCompatibility = "tesl-stored-value-v1:" + strings.Repeat("C", 64)
		},
		"different contract": func(_ *PgMigrationControlState, _ *PgMigrationExpansionPlan, intents map[int]*pgExpansionIntent) {
			intents[1].StoredValueCompatibility = "tesl-stored-value-v1:" + strings.Repeat("d", 64)
		},
		"future contract": func(_ *PgMigrationControlState, plan *PgMigrationExpansionPlan, intents map[int]*pgExpansionIntent) {
			plan.CurrentVersion, plan.Steps = 1, plan.Steps[:1]
			intents[3].StoredValueCompatibility = "tesl-stored-value-v1:" + strings.Repeat("d", 64)
		},
		"missing lifecycle": func(state *PgMigrationControlState, _ *PgMigrationExpansionPlan, _ map[int]*pgExpansionIntent) {
			state.Versions = state.Versions[:len(state.Versions)-1]
		},
		"incomplete objects": func(_ *PgMigrationControlState, _ *PgMigrationExpansionPlan, intents map[int]*pgExpansionIntent) {
			intents[2].Objects = nil
		},
		"changed snapshot": func(_ *PgMigrationControlState, _ *PgMigrationExpansionPlan, intents map[int]*pgExpansionIntent) {
			intents[1].SnapshotHash = strings.Repeat("e", 64)
		},
		"changed step": func(_ *PgMigrationControlState, _ *PgMigrationExpansionPlan, intents map[int]*pgExpansionIntent) {
			intents[1].ArtifactHash = strings.Repeat("e", 64)
		},
		"lifecycle ABI": func(state *PgMigrationControlState, _ *PgMigrationExpansionPlan, _ map[int]*pgExpansionIntent) {
			state.Versions[0].SourceABI = "tesl-source-abi-v1:" + strings.Repeat("b", 64)
		},
		"lifecycle contract": func(state *PgMigrationControlState, _ *PgMigrationExpansionPlan, _ map[int]*pgExpansionIntent) {
			state.Versions[0].StoredValueCompatibility = ""
		},
		"contracted provenance": func(state *PgMigrationControlState, _ *PgMigrationExpansionPlan, _ map[int]*pgExpansionIntent) {
			state.Versions[2].StoredValueCompatibility = ""
		},
	} {
		t.Run(name, func(t *testing.T) {
			state, plan, intents := pgCompatibilityTestState(t, 3)
			plan.SourceCompilerABI = "tesl-source-abi-v1:" + strings.Repeat("b", 64)
			mutate(&state, &plan, intents)
			if err := pgVerifyExpansionHistory(state, plan, intents); err == nil {
				t.Fatal("incompatible or incomplete completed history accepted")
			}
		})
	}
}

func TestPgMigrationCompatibilityPinsUnfinishedIntentsToActualABI(t *testing.T) {
	for _, progress := range []string{"no objects", "partial objects", "all objects before lifecycle"} {
		t.Run(progress, func(t *testing.T) {
			state, plan, intents := pgCompatibilityTestState(t, 2)
			state.Current = 1
			state.Versions = state.Versions[:3]
			switch progress {
			case "no objects":
				intents[2].Objects = nil
			case "partial objects":
				intents[2].Objects = intents[2].Objects[:1]
			}
			if err := pgVerifyExpansionHistory(state, plan, intents); err != nil {
				t.Fatalf("same compiler could not resume: %v", err)
			}
			plan.SourceCompilerABI = "tesl-source-abi-v1:" + strings.Repeat("b", 64)
			for _, current := range []int{3, 1} {
				plan.CurrentVersion, plan.Steps = current, plan.Steps[:current]
				if err := pgVerifyExpansionHistory(state, plan, intents); err == nil || !strings.Contains(err.Error(), "unfinished migration compiler ABI") {
					t.Fatalf("different ABI accepted unfinished intent at binary V%d: %v", current, err)
				}
			}
		})
	}
}

func TestPgMigrationCompiledCompatibilityContractIsRequired(t *testing.T) {
	for _, value := range []string{"", "tesl-stored-value-v1:bad", "tesl-stored-value-v1:" + strings.Repeat("C", 64), "tesl-stored-value-v2:" + strings.Repeat("c", 64)} {
		history := pgPlanTestHistory()
		original := history.StoredValueCompatibility
		history.StoredValueCompatibility = value
		history.HistoryJSON = strings.ReplaceAll(history.HistoryJSON, original, value)
		if plan, err := history.ExpansionPlan(1); err == nil || !reflect.DeepEqual(plan, PgMigrationExpansionPlan{}) {
			t.Fatalf("invalid compatibility %q released a plan", value)
		}
		migrationRegistrationPanics(t, func() {
			registerCompiledMigrationHistory("A.Main", "InvalidCompatibilitySchema", "notes", 1, pgTestSourceABI, value, "{}")
		})
	}
	for _, version := range []int{1, 2} {
		history := pgPlanTestRewrite(t, pgPlanTestHistory(), func(root map[string]any) { root["version"] = version; delete(root, "storedValueCompatibility") })
		if _, err := history.ExpansionPlan(1); err == nil {
			t.Fatalf("legacy history v%d acquired an implicit compatibility contract", version)
		}
	}
	history := pgPlanTestHistory()
	history.StoredValueCompatibility = "tesl-stored-value-v1:" + strings.Repeat("d", 64)
	if _, err := history.ExpansionPlan(1); err == nil {
		t.Fatal("linked metadata differed from embedded compatibility")
	}
}
