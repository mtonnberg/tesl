package teslrt

import (
	"slices"
	"strings"
	"testing"
)

func rowRetirementEmptyQueueCompanion(t *testing.T, h PgCompiledMigrationHistory, source map[string]any) map[string]any {
	versions, origins := []any{}, []any{}
	for i, raw := range rowTestDB(source)["versions"].([]any) {
		v := raw.(map[string]any)
		versions = append(versions, map[string]any{"version": i + 1, "storageSnapshotHash": v["storageSnapshotHash"], "schemaSnapshotHash": v["schemaSnapshotHash"], "checkedInventory": "complete", "sourceSealInventory": "unrecorded", "contracts": []any{}})
		refs := []int{}
		for n := i + 1; n <= h.CurrentVersion; n++ {
			refs = append(refs, n)
		}
		origins = append(origins, map[string]any{"initialVersion": i + 1, "versions": refs})
	}
	return map[string]any{"version": 1, "kind": "compiled-queue-history", "compilerAbi": h.SourceCompilerABI, "storedValueCompatibility": h.StoredValueCompatibility, "databases": []any{map[string]any{"database": h.Database, "family": h.Family, "namespace": h.Namespace, "currentVersion": h.CurrentVersion, "versions": versions, "origins": origins}}}
}
func TestRowRetirementSourceV5EmptyQueueRouting(t *testing.T) {
	h, source := rowRetirementSourceFixture(t)
	if _, err := h.ExpansionPlan(1); err == nil {
		t.Fatal("source-only Drop gained legacy expansion authority")
	}
	projection, err := pgQueueSourceProjection(h)
	if err != nil || len(projection) != 1 || len(projection[0].versions) != 2 {
		t.Fatal("source v5 was not routed through exact row inventory", err)
	}
	companion := rowRetirementEmptyQueueCompanion(t, h, source)
	inventory, err := pgReadQueueHistory(h, rowTestJSON(t, companion), 1)
	if err != nil || len(inventory.Versions) != 2 {
		t.Fatal("empty queue companion refused Drop source", err)
	}
	for _, v := range inventory.Versions {
		if len(v.Contracts) != 0 {
			t.Fatal("manufactured queue contract")
		}
	}
	// The compiler forbids this combination. A coherently rehashed source must
	// still be refused by runtime before an empty companion can conceal the queue.
	db := rowTestDB(source)
	for _, raw := range db["versions"].([]any) {
		version := raw.(map[string]any)
		reader := &pgMigrationWireReader{}
		schema := pgRowDocument(reader, version["schemaContract"].(string), version["schemaSnapshotHash"].(string), "snapshot")
		ref := pgRowTypeReference(h.Family, "Notifications")
		ref.children[1] = pgRowAtom("value")
		closure := &schema.children[2]
		closure.children[1].children = append(closure.children[1].children, ref)
		closure.children[2].children = append(closure.children[2].children, pgRowList(ref, pgRowList(pgRowAtom("queue-schema"), ref, pgRowList())))
		slices.SortFunc(closure.children[1].children, func(a, b pgRowCanonical) int { return strings.Compare(pgRowEncode(a), pgRowEncode(b)) })
		slices.SortFunc(closure.children[2].children, func(a, b pgRowCanonical) int {
			return strings.Compare(pgRowEncode(a.children[0]), pgRowEncode(b.children[0]))
		})
		schemaHex, schemaHash := rowTestDoc("snapshot", schema)
		storage := pgRowDocument(reader, version["storageContract"].(string), version["storageSnapshotHash"].(string), "migration")
		storage.children[1] = schema
		storageHex, storageHash := rowTestDoc("migration", storage)
		version["schemaContract"], version["schemaSnapshotHash"] = schemaHex, schemaHash
		version["storageContract"], version["storageSnapshotHash"] = storageHex, storageHash
	}
	versions := db["versions"].([]any)
	retirement := db["retirements"].([]any)[0].(map[string]any)
	retirement["fromSchemaSnapshot"] = versions[0].(map[string]any)["schemaSnapshotHash"]
	retirement["toSchemaSnapshot"] = versions[1].(map[string]any)["schemaSnapshotHash"]
	h.HistoryJSON = rowTestJSON(t, source)
	if _, err := pgReadRowBase(h); err == nil || !strings.Contains(err.Error(), "historical queue schema") {
		t.Fatal("forged queue-bearing Drop source admitted", err)
	}
	companion = rowRetirementEmptyQueueCompanion(t, h, source)
	if _, err := pgReadQueueHistory(h, rowTestJSON(t, companion), 1); err == nil || !strings.Contains(err.Error(), "historical queue schema") {
		t.Fatal("empty queue companion concealed queued Drop", err)
	}
}
