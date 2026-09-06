package teslrt

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"slices"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

func pgExpansionTestHistory(namespace string, current int) PgCompiledMigrationHistory {
	steps := pgPlanTestSteps()[:current]
	if current >= 2 {
		steps[1].Operations = steps[1].Operations[:len(steps[1].Operations)-1]
	}
	if current >= 3 {
		steps[2].EpochPreserving = true
		steps[2].Operations = []PgMigrationExpansionOperation{{Kind: "retain-table", Table: "audit"}}
	}
	pgPlanTestSeal(steps)
	origins := []any{}
	for origin := range current {
		baseline := PgMigrationExpansionStep{Version: origin + 1, SnapshotHash: steps[origin].SnapshotHash, EpochPreserving: true}
		for _, table := range steps[origin].Catalog {
			columns := slices.Clone(table.Columns)
			for i := range columns {
				columns[i].Default = nil
			}
			baseline.Operations = append(baseline.Operations, PgMigrationExpansionOperation{Kind: "create-table", Table: table.Name, Columns: columns, Indexes: table.Indexes})
		}
		chain := append([]PgMigrationExpansionStep{baseline}, steps[origin+1:]...)
		pgPlanTestSeal(chain)
		origins = append(origins, map[string]any{"initialVersion": origin + 1, "steps": pgPlanTestStepsJSON(chain), "errors": []any{}})
	}
	history := PgCompiledMigrationHistory{Database: "App.Main", Family: "NotesSchema", Namespace: namespace, CurrentVersion: current,
		SourceCompilerABI: pgTestSourceABI, StoredValueCompatibility: pgTestStoredValueCompatibility}
	encoded, err := json.Marshal(map[string]any{"version": 3, "kind": "compiled-migration-history", "compilerAbi": history.SourceCompilerABI, "storedValueCompatibility": history.StoredValueCompatibility,
		"databases": []any{map[string]any{"database": history.Database, "family": history.Family, "namespace": namespace, "currentVersion": current, "origins": origins}}})
	if err != nil {
		panic(err)
	}
	history.HistoryJSON = string(encoded)
	return history
}

func (f *pgControlTestFixture) expand(t *testing.T, current int) PgMigrationControlState {
	t.Helper()
	state, err := ExecutePgMigrationExpansion(f.ctx, f.worker, pgExpansionTestHistory(f.namespace, current), f.roles)
	if err != nil {
		t.Fatal(err)
	}
	return state
}

func TestPgMigrationExpansionRetainsRowsAndOldWriters(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	f.expand(t, 1)
	f.call(t, "insert into notes_app.notes(id,active) values ('before',true)")
	state := f.expand(t, 3)
	if state.Current != 3 || state.InitialVersion != 1 || state.MinVersion != 1 || len(state.Versions) != 5 {
		t.Fatalf("bad expanded state: %+v", state)
	}
	// This is the V1 statement, unchanged after two later deployments. SQL
	// defaults fill every added required value without an application rewrite.
	f.call(t, "insert into notes_app.notes(id,active) values ('after',false)")
	var rows int
	if err := f.worker.QueryRow(f.ctx, `select count(*) from notes_app.notes where
 rank = -9007199254740993 and encode(float8send(ratio),'hex') = '8000000000000000'
 and published and caption = $1 and optional is null`, "雪é ' \\ 🙂").Scan(&rows); err != nil || rows != 2 {
		t.Fatalf("retained/defaulted rows: %d, %v", rows, err)
	}
	before := state
	if got := f.expand(t, 1); !reflect.DeepEqual(before, got) {
		t.Fatal("old binary changed later history")
	}
	if got := f.expand(t, 3); !reflect.DeepEqual(before, got) {
		t.Fatal("retry appended or rewrote history")
	}
	for v := 1; v <= 3; v++ {
		f.call(t, "select notes_app.tesl_admit($1::integer)", v)
	}
	var leaked int
	if err := f.worker.QueryRow(f.ctx, `select count(*) from pg_catalog.pg_class where relnamespace=pg_catalog.pg_my_temp_schema()`).Scan(&leaked); err != nil || leaked != 0 {
		t.Fatalf("comparison objects leaked across commit: %d, %v", leaked, err)
	}
	if f.worker.PgConn().TxStatus() != 'I' {
		t.Fatal("executor leaked a transaction")
	}
}

func TestPgMigrationExpansionKeepsFirstInstallationOrigin(t *testing.T) {
	f := pgNewControlTest(t)
	seed := f.install(t, 2)
	state := f.expand(t, 3)
	if state.InitialVersion != 2 || state.MinVersion != 2 || state.Current != 3 || state.DatabaseUUID != seed.DatabaseUUID || len(state.Versions) != 4 {
		t.Fatalf("replaced initial installation provenance: %+v", state)
	}
	var defaults int
	if err := f.worker.QueryRow(f.ctx, `select count(*) from pg_catalog.pg_attrdef d join pg_catalog.pg_class c on c.oid=d.adrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname=$1 and c.relname='notes'`, f.namespace).Scan(&defaults); err != nil || defaults != 0 {
		t.Fatalf("late installation inherited old omission defaults: %d, %v", defaults, err)
	}
	if _, err := ExecutePgMigrationExpansion(f.ctx, f.worker, pgExpansionTestHistory(f.namespace, 1), f.roles); err == nil {
		t.Fatal("binary predating installation accepted")
	}
}

func TestPgMigrationExpansionRefusesUnrecordedLookalikes(t *testing.T) {
	for _, scenario := range []string{"table", "column", "index collision"} {
		t.Run(scenario, func(t *testing.T) {
			f := pgNewControlTest(t)
			f.install(t, 1)
			current := 1
			switch scenario {
			case "table":
				f.call(t, "create table notes_app.notes(id text primary key,active bool not null)")
			case "column":
				f.expand(t, 1)
				f.call(t, "insert into notes_app.notes(id,active) values ('retained',true)")
				f.call(t, "alter table notes_app.notes add column rank numeric default -9007199254740993 not null")
				current = 2
			case "index collision":
				f.call(t, "create table notes_app.active_idx (marker text)")
			}
			_, err := ExecutePgMigrationExpansion(f.ctx, f.worker, pgExpansionTestHistory(f.namespace, current), f.roles)
			if err == nil {
				t.Fatal("executor adopted an unrecorded object")
			}
			var count int
			if err := f.worker.QueryRow(f.ctx, "select count(*) from notes_app.tesl_schema_expansion_objects where version=$1", current).Scan(&count); err != nil || count != 0 {
				t.Fatalf("failed DDL recorded progress: %d, %v", count, err)
			}
			if scenario == "index collision" {
				if err := f.worker.QueryRow(f.ctx, "select count(*) from pg_catalog.pg_tables where schemaname=$1 and tablename='notes'", f.namespace).Scan(&count); err != nil || count != 0 {
					t.Fatalf("partial table committed before index failure: %d,%v", count, err)
				}
				f.call(t, "drop table notes_app.active_idx")
				f.expand(t, 1)
			}
		})
	}
}

func TestPgMigrationExpansionRejectsRecordedDriftBeforeDDL(t *testing.T) {
	for name, sql := range map[string]string{
		"missing table":          "drop table notes_app.notes",
		"missing index":          "drop index notes_app.active_idx",
		"changed column":         "alter table notes_app.notes alter active drop not null",
		"missing lifecycle":      "delete from notes_app.tesl_schema_versions where step='expanded'",
		"missing baseline final": "delete from notes_app.tesl_schema_versions where step='contracted'",
		"missing object":         "delete from notes_app.tesl_schema_expansion_objects",
		"object hash":            "update notes_app.tesl_schema_expansion_objects set operation_hash=repeat('b',64)",
		"missing intent":         "delete from notes_app.tesl_schema_expansions",
		"extra intent":           "insert into notes_app.tesl_schema_expansions select 3,snapshot_hash,artefact_hash,source_abi,stored_value_compatibility,operation_count,epoch_preserving,started_at from notes_app.tesl_schema_expansions",
		"ABI":                    "update notes_app.tesl_schema_expansions set source_abi='tesl-source-abi-v1:'||repeat('b',64)",
		"snapshot":               "update notes_app.tesl_schema_expansions set snapshot_hash=repeat('b',64)",
	} {
		t.Run(name, func(t *testing.T) {
			f := pgNewControlTest(t)
			f.install(t, 1)
			f.expand(t, 1)
			if _, err := f.installer.Exec(f.ctx, sql); err != nil {
				t.Fatal(err)
			}
			if _, err := ExecutePgMigrationExpansion(f.ctx, f.worker, pgExpansionTestHistory(f.namespace, 2), f.roles); err == nil {
				t.Fatal("recorded drift accepted")
			}
			var count int
			if err := f.worker.QueryRow(f.ctx, "select count(*) from notes_app.tesl_schema_expansions where version=2").Scan(&count); err != nil || count != 0 {
				t.Fatalf("started later expansion before verifying history: %d,%v", count, err)
			}
		})
	}
}

func TestPgMigrationExpansionRefusesUnsupportedPlanBeforeWork(t *testing.T) {
	f := pgNewControlTest(t)
	f.namespace = "notes"
	f.install(t, 1)
	_, err := ExecutePgMigrationExpansion(f.ctx, f.worker, pgPlanTestHistory(), f.roles)
	if err == nil || !strings.Contains(err.Error(), "index") {
		t.Fatalf("unsupported populated index plan: %v", err)
	}
	var count int
	if err := f.worker.QueryRow(f.ctx, "select count(*) from notes.tesl_schema_expansions").Scan(&count); err != nil || count != 0 {
		t.Fatalf("unsupported plan partly executed: %d,%v", count, err)
	}
	malformed := pgExpansionTestHistory("notes", 1)
	malformed.HistoryJSON = "{}"
	if _, err := ExecutePgMigrationExpansion(f.ctx, nil, malformed, f.roles); err == nil || !strings.Contains(err.Error(), "history") {
		t.Fatalf("malformed artifact reached connection: %v", err)
	}
}

func TestPgMigrationExpansionQuotedObjectsAndSessionSettings(t *testing.T) {
	f := pgNewControlTest(t)
	f.namespace = "notes '$tesl$\"\\雪"
	f.install(t, 1)
	f.call(t, "set standard_conforming_strings=off; set search_path=pg_catalog; set TimeZone='Europe/Stockholm'")
	f.expand(t, 2)
	for setting, want := range map[string]string{"standard_conforming_strings": "off", "search_path": "pg_catalog", "TimeZone": "Europe/Stockholm"} {
		var got string
		if err := f.worker.QueryRow(f.ctx, "select current_setting($1)", setting).Scan(&got); err != nil || got != want {
			t.Fatalf("setting %s leaked: %q,%v", setting, got, err)
		}
	}
	var caption string
	query := fmt.Sprintf("insert into %s.notes(id,active) values ('quoted',true) returning caption", quoteIdentifier(f.namespace))
	if err := f.worker.QueryRow(f.ctx, query).Scan(&caption); err != nil || caption != "雪é ' \\ 🙂" {
		t.Fatalf("literal changed: %q,%v", caption, err)
	}
}

func TestPgMigrationExpansionRequiresActualWorkerLogin(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	if _, err := f.installer.Exec(f.ctx, "set role "+quoteIdentifier(f.roles.Worker)); err != nil {
		t.Fatal(err)
	}
	defer func() { _, _ = f.installer.Exec(f.ctx, "reset role") }()
	if _, err := ExecutePgMigrationExpansion(f.ctx, f.installer, pgExpansionTestHistory(f.namespace, 1), f.roles); err == nil || !strings.Contains(err.Error(), "worker identity") {
		t.Fatalf("privileged session disguised as worker accepted: %v", err)
	}
	var n int
	if err := f.installer.QueryRow(f.ctx, "select count(*) from notes_app.tesl_schema_expansions").Scan(&n); err != nil || n != 0 {
		t.Fatalf("wrong login started entity work: %d,%v", n, err)
	}
}

func TestPgMigrationExpansionNumericDefaultInputRange(t *testing.T) {
	f := pgNewControlTest(t)
	for _, sample := range []struct {
		expression string
		valid      bool
	}{
		{"'-32768'::smallint", true}, {"'-2147483648'::integer", true}, {"'-9223372036854775808'::bigint", true},
		{"'32768'::smallint", false}, {"'2147483648'::integer", false}, {"'9223372036854775808'::bigint", false},
	} {
		err := pgExpansionTransaction(f.ctx, f.worker, func(tx pgx.Tx) error {
			column := pgCatalogColumn{Name: "extra", Type: "numeric", TypeNamespace: "pg_catalog", TypeKind: "b", Typmod: -1, Required: true, Default: &sample.expression}
			got, err := pgBenignExtraColumn(f.ctx, tx, column)
			if err != nil {
				return err
			}
			if got != sample.valid {
				return fmt.Errorf("%s: got %v want %v", sample.expression, got, sample.valid)
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
}

func TestPgMigrationExpansionLockTimeoutLeavesResumableIntent(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	f.expand(t, 1)
	f.call(t, "insert into notes_app.notes(id,active) values ('retained',true)")
	blocker, err := f.installer.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = blocker.Rollback(context.Background()) }()
	if _, err := blocker.Exec(f.ctx, "lock table notes_app.notes in access share mode"); err != nil {
		t.Fatal(err)
	}
	if _, err := ExecutePgMigrationExpansion(f.ctx, f.worker, pgExpansionTestHistory(f.namespace, 2), f.roles); err == nil || !strings.Contains(err.Error(), "lock timeout") {
		t.Fatalf("DDL did not respect lock timeout: %v", err)
	}
	var intents, objects, current int
	if err := f.worker.QueryRow(f.ctx, `select (select count(*) from notes_app.tesl_schema_expansions where version=2),
 (select count(*) from notes_app.tesl_schema_expansion_objects where version=2), current from notes_app.tesl_schema_state`).Scan(&intents, &objects, &current); err != nil || intents != 1 || objects != 0 || current != 1 {
		t.Fatalf("timeout changed progress: %d,%d,%d,%v", intents, objects, current, err)
	}
	f.call(t, "insert into notes_app.notes(id,active) values ('during',true)")
	if err := blocker.Rollback(f.ctx); err != nil {
		t.Fatal(err)
	}
	f.expand(t, 2)
	var rows int
	if err := f.worker.QueryRow(f.ctx, "select count(*) from notes_app.notes where rank=-9007199254740993").Scan(&rows); err != nil || rows != 2 {
		t.Fatalf("timeout/retry lost old writes: %d,%v", rows, err)
	}
}

func TestPgMigrationExpansionEmptySchemaAndCanceledEntry(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	history := pgExpansionTestHistory(f.namespace, 1)
	envelope := map[string]any{}
	if err := json.Unmarshal([]byte(history.HistoryJSON), &envelope); err != nil {
		t.Fatal(err)
	}
	step := PgMigrationExpansionStep{Version: 1, SnapshotHash: strings.Repeat("1", 64), EpochPreserving: true}
	step.StepHash = pgMigrationStepHash(step)
	envelope["databases"] = []any{map[string]any{"database": history.Database, "family": history.Family, "namespace": history.Namespace, "currentVersion": 1,
		"origins": []any{map[string]any{"initialVersion": 1, "errors": []any{}, "steps": pgPlanTestStepsJSON([]PgMigrationExpansionStep{step})}}}}
	data, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	history.HistoryJSON = string(data)
	canceled, cancel := context.WithCancel(f.ctx)
	cancel()
	if _, err := ExecutePgMigrationExpansion(canceled, f.worker, history, f.roles); err == nil || f.worker.IsClosed() || f.worker.PgConn().TxStatus() != 'I' {
		t.Fatalf("pre-canceled entry changed connection: %v", err)
	}
	state, err := ExecutePgMigrationExpansion(f.ctx, f.worker, history, f.roles)
	if err != nil || state.Current != 1 || len(state.Versions) != 3 {
		t.Fatalf("empty schema did not finalize baseline: %+v,%v", state, err)
	}
	var objects int
	if err := f.worker.QueryRow(f.ctx, "select count(*) from notes_app.tesl_schema_expansion_objects").Scan(&objects); err != nil || objects != 0 {
		t.Fatalf("empty schema fabricated object progress: %d,%v", objects, err)
	}
}

func TestPgMigrationExpansionDoesNotBootstrapBeforeInstallation(t *testing.T) {
	f := pgNewControlTest(t)
	if _, err := ExecutePgMigrationExpansion(f.ctx, f.worker, pgExpansionTestHistory(f.namespace, 1), f.roles); err == nil || !strings.Contains(err.Error(), "not installed") {
		t.Fatalf("missing installer did not refuse: %v", err)
	}
	var objects int
	if err := f.worker.QueryRow(f.ctx, "select count(*) from pg_catalog.pg_namespace where nspname=$1", f.namespace).Scan(&objects); err != nil || objects != 0 {
		t.Fatalf("executor created objects before installation: %d,%v", objects, err)
	}
}
