package teslrt

import (
	"slices"
	"testing"
)

// Pure operation derivation checks do not register codecs or grant SQL authority.
func TestRowNewTableOperationAndOrigins(t *testing.T) {
	seed := rowPhysicalSeed(t).Databases[0].Versions[0]
	previous, err := pgParseRowPhysicalPlan(seed.Contract, seed.Hash)
	if err != nil {
		t.Fatal(err)
	}
	plan := *previous
	plan.version = 2
	plan.entities = slices.Clone(previous.entities)
	added := previous.entities[0]
	added.identity, added.table = "Added", "added"
	added.columns = slices.Clone(added.columns)
	for i := range added.columns {
		added.columns[i].introducedVersion = 2
	}
	added.indexes = []PgMigrationCatalogIndex{{Name: "added_id_lookup", Columns: []string{added.columns[0].catalog.Name}}}
	plan.entities = append(plan.entities, added)
	operations, err := pgRowForwardOperations(previous, &plan)
	if err != nil || len(operations) != 1 || operations[0].table == nil {
		t.Fatal("new entity did not derive one create operation", err)
	}
	table := operations[0].table
	if table.Name != "added" || len(table.Indexes) != 1 {
		t.Fatal("new table lost its exact index inventory")
	}
	marker := table.Columns[len(table.Columns)-1]
	if marker.Name != "_tesl_v" || marker.Type != "int2" || marker.Nullable || marker.Default == nil || marker.Default.Value != "1" {
		t.Fatal("new table lacks permanent generation-one marker")
	}
	plan.entities[len(plan.entities)-1].generation = 2
	if _, err := pgRowForwardOperations(previous, &plan); err == nil {
		t.Fatal("invented historical generation authorized table creation")
	}
	plan.entities[len(plan.entities)-1].generation = 1
	plan.entities[len(plan.entities)-1].columns[0].introducedVersion = 1
	if _, err := pgRowForwardOperations(previous, &plan); err == nil {
		t.Fatal("old column origin authorized new table")
	}
}

func TestRowExistingTableIndexRequiresConcurrentJob(t *testing.T) {
	seed := rowPhysicalSeed(t).Databases[0].Versions[0]
	previous, err := pgParseRowPhysicalPlan(seed.Contract, seed.Hash)
	if err != nil {
		t.Fatal(err)
	}
	plan := *previous
	plan.version = 2
	plan.entities = slices.Clone(previous.entities)
	plan.entities[0].indexes = append(slices.Clone(plan.entities[0].indexes), PgMigrationCatalogIndex{Name: "later_index", Columns: []string{plan.entities[0].columns[0].catalog.Name}})
	if _, err := pgRowForwardOperations(previous, &plan); err == nil {
		t.Fatal("existing table index escaped concurrent job requirement")
	}
}
