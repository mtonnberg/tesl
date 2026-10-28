package teslrt

import (
	"strings"
	"testing"
)

func TestRowEpochRetirementIdentityAndCompletePrefix(t *testing.T) {
	b := &pgRowBaseline{history: PgCompiledMigrationHistory{Database: "App.Main", Family: "Schema.Notes", Namespace: "notes", StoredValueCompatibility: "tesl-stored-value-v1:" + strings.Repeat("a", 64)}}
	state := PgMigrationControlState{DatabaseUUID: "00000000-0000-4000-8000-000000000001", FenceNamespace: 17}
	plans := map[int]*pgRowPhysicalPlan{}
	for v := 1; v <= 3; v++ {
		plans[v] = &pgRowPhysicalPlan{version: v, family: "Schema.Notes", namespace: "notes", hash: strings.Repeat(string(rune('0'+v)), 64)}
	}
	doc, hash, err := pgRowEpochDocument(b, state, 1, 3, false, plans)
	if err != nil || doc == "" || !pgMigrationDigest(hash) {
		t.Fatal("complete additive retirement", err)
	}
	other := state
	other.DatabaseUUID = "00000000-0000-4000-8000-000000000002"
	_, otherHash, err := pgRowEpochDocument(b, other, 1, 3, false, plans)
	if err != nil || otherHash == hash {
		t.Fatal("retirement crossed a database replacement", err)
	}
	_, forced, err := pgRowEpochDocument(b, state, 1, 3, true, plans)
	if err != nil || forced == hash {
		t.Fatal("force decision was not bound to the retirement receipt", err)
	}
	delete(plans, 2)
	if _, _, err := pgRowEpochDocument(b, state, 1, 3, false, plans); err == nil {
		t.Fatal("incomplete physical prefix authorized retirement")
	}
	plans[2] = &pgRowPhysicalPlan{version: 2, family: "Schema.Notes", namespace: "notes", hash: strings.Repeat("2", 64), windows: []pgRowPhysicalWindow{{}}}
	if _, _, err := pgRowEpochDocument(b, state, 1, 3, false, plans); err == nil {
		t.Fatal("a transforming predecessor was treated as an additive epoch")
	}
	// A description may bind a closed transforming prefix without treating it
	// as an additive slot. Runtime publication separately requires its Contract.
	if plans[3] == nil {
		t.Fatal("epoch fixture omitted its surviving plan")
	}
	plans[3].requiresContractVersion = 2
	if _, _, err := pgRowEpochDocument(b, state, 2, 3, false, plans); err != nil {
		t.Fatal("additive tail lost its complete transforming prefix", err)
	}
	plans[3].requiresContractVersion = 3
	if _, _, err := pgRowEpochDocument(b, state, 2, 3, false, plans); err == nil {
		t.Fatal("unclosed prerequisite inside additive tail accepted")
	}
	plans[3].requiresContractVersion = 0
	// A pure table Drop has no row transform windows, but is destructive and
	// requires its exact table Contract rather than additive epoch retirement.
	plans[2].windows = nil
	plans[2].retirements = []pgRowPhysicalRetirement{{entity: "Archive"}}
	for _, force := range []bool{false, true} {
		if _, _, err := pgRowEpochDocument(b, state, 1, 3, force, plans); err == nil || !strings.Contains(err.Error(), "purely additive admitted tail") {
			t.Fatal("table retirement was treated as an additive epoch", force, err)
		}
	}
	if _, _, err := pgRowEpochDocument(b, state, 1, 2147483646, false, plans); err == nil {
		t.Fatal("unbounded missing prefix accepted")
	}
	if _, _, err := pgRowEpochDocument(b, state, 3, 3, false, plans); err == nil {
		t.Fatal("empty retirement was published")
	}
}

func TestRowEpochCommandScope(t *testing.T) {
	_, _, usage := pgParseSchemaCommand([]string{"--schema", "unknown"})
	if usage == nil || !strings.Contains(usage.Error(), "contract Vn") || !strings.Contains(usage.Error(), "close-epoch --through Vn [--dry-run] [--force]") {
		t.Fatal("schema usage omits lifecycle commands", usage)
	}
	for _, args := range [][]string{
		{"--schema", "close-epoch", "--through", "V2", "--dry-run", "--json"},
		{"--schema", "close-epoch", "--force", "--through", "V3"},
	} {
		command, handled, err := pgParseSchemaCommand(args)
		if err != nil || !handled || command.targetVersion < 2 {
			t.Fatalf("valid close-epoch command refused: %v %+v", err, command)
		}
	}
	for _, args := range [][]string{
		{"--schema", "close-epoch"}, {"--schema", "close-epoch", "--through", "V02"},
		{"--schema", "close-epoch", "--through", "V1"}, {"--schema", "close-epoch", "--through", "V2", "--through", "V3"},
		{"--schema", "worker", "--force"}, {"--schema", "contract", "V2", "--dry-run"},
	} {
		_, handled, err := pgParseSchemaCommand(args)
		if err == nil || !handled {
			t.Fatalf("invalid close-epoch command accepted: %v", args)
		}
	}
}

func TestPgRowEpochEmptyQueueInventoryDoesNotBlockRetirement(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	db := pgRowBaselineFixture(t, f)
	pgRowBaselineReady(t, f, db)
	if err := pgCheckRowQueueRetirement(f.ctx, f.worker, f.namespace); err != nil {
		t.Fatal("complete queue-free inventory blocked", err)
	}
	// The queue tables exist even for queue-free apps. Their mere presence
	// must not turn the queue safety boundary into an entity retirement ban.
	for _, statement := range []string{
		`select notes_app.tesl_close_row_epoch(null,null,null,null,null,null,null,null,true)`,
		`select notes_app.tesl_retire_row_window(null,null,null,null,null,null)`,
		`select notes_app.tesl_begin_row_contract(null,null)`,
	} {
		_, err := f.worker.Exec(f.ctx, statement)
		if err == nil || strings.Contains(err.Error(), "queue-bearing history") {
			t.Fatalf("queue-free call did not reach normal retirement validation: %s: %v", statement, err)
		}
	}
}
