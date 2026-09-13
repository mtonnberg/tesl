package teslrt

import (
	"slices"
	"strings"
	"testing"
)

// These pure descriptor fixtures grant neither compiler registration nor SQL
// authority. Actual job execution belongs to the later native protocol gate.
func rowIndexPlanPair() (*pgRowPhysicalPlan, *pgRowPhysicalPlan) {
	entity := pgRowPhysicalEntity{identity: "Note", table: "notes", generation: 1, insertGeneration: 1,
		columns: []pgRowPhysicalColumn{
			{catalog: PgMigrationCatalogColumn{Name: "id", Type: "int8", PrimaryKey: true}, introducedVersion: 1},
			{catalog: PgMigrationCatalogColumn{Name: "key", Type: "text"}, introducedVersion: 1},
		}, projection: []pgRowPhysicalField{{logical: "id", physical: "id"}, {logical: "key", physical: "key"}}}
	previous := &pgRowPhysicalPlan{family: "App", namespace: "notes", version: 1, entities: []pgRowPhysicalEntity{entity}}
	plan := *previous
	plan.version = 2
	plan.entities = slices.Clone(previous.entities)
	plan.entities[0].columns = slices.Clone(entity.columns)
	return previous, &plan
}

func TestRowConcurrentIndexAdmittedKeyDomains(t *testing.T) {
	for _, carrier := range []string{"bool", "int4", "int8", "float8", "text", "numeric", "jsonb"} {
		for _, fresh := range []bool{false, true} {
			name := carrier + "/retained"
			if fresh {
				name = carrier + "/new-null"
			}
			t.Run(name, func(t *testing.T) {
				previous, plan := rowIndexPlanPair()
				key := "key"
				if fresh {
					key = "fresh"
					plan.entities[0].columns = append(plan.entities[0].columns, pgRowPhysicalColumn{
						catalog: PgMigrationCatalogColumn{Name: key, Type: carrier, Nullable: true}, introducedVersion: 2})
				} else {
					previous.entities[0].columns[1].catalog.Type = carrier
					plan.entities[0].columns[1].catalog.Type = carrier
				}
				plan.entities[0].indexes = []PgMigrationCatalogIndex{{Name: "note_key_lookup", Columns: []string{key}}}
				indexes, err := pgDeriveRowConcurrentIndexes(previous, plan)
				want := fresh || slices.Contains([]string{"bool", "int4", "int8", "float8"}, carrier)
				if want {
					if err != nil || len(indexes) != 1 || indexes[0].entity != "Note" || indexes[0].table != "notes" || indexes[0].index.Columns[0] != key {
						t.Fatal("safe exact descriptor lost", indexes, err)
					}
					indexes[0].index.Columns[0] = "changed"
					if plan.entities[0].indexes[0].Columns[0] != key {
						t.Fatal("derived descriptor aliases immutable source keys")
					}
				} else if err == nil || !strings.Contains(err.Error(), "admitted schema") {
					t.Fatal("unbounded admitted key accepted", carrier, err)
				}
			})
		}
	}
}

func TestRowConcurrentIndexRefusesUnsafeAndMalformedPlans(t *testing.T) {
	cases := map[string]func(*pgRowPhysicalPlan, *pgRowPhysicalPlan){
		"unique old bounded": func(_, p *pgRowPhysicalPlan) {
			p.entities[0].indexes[0] = PgMigrationCatalogIndex{Name: "fresh_lookup", Columns: []string{"id"}, Unique: true}
		},
		"unique new null": func(_, p *pgRowPhysicalPlan) { p.entities[0].indexes[0].Unique = true },
		"new default": func(_, p *pgRowPhysicalPlan) {
			p.entities[0].columns[2].catalog.Default = &PgMigrationCatalogConstant{Kind: "string", Value: "value"}
		},
		"new required":          func(_, p *pgRowPhysicalPlan) { p.entities[0].columns[2].catalog.Nullable = false },
		"old origin":            func(_, p *pgRowPhysicalPlan) { p.entities[0].columns[2].introducedVersion = 1 },
		"mixed old unbounded":   func(_, p *pgRowPhysicalPlan) { p.entities[0].indexes[0].Columns = []string{"fresh", "key"} },
		"mixed old bounded":     func(_, p *pgRowPhysicalPlan) { p.entities[0].indexes[0].Columns = []string{"fresh", "id"} },
		"missing key":           func(_, p *pgRowPhysicalPlan) { p.entities[0].indexes[0].Columns = []string{"missing"} },
		"repeated key":          func(_, p *pgRowPhysicalPlan) { p.entities[0].indexes[0].Columns = []string{"fresh", "fresh"} },
		"empty keys":            func(_, p *pgRowPhysicalPlan) { p.entities[0].indexes[0].Columns = nil },
		"colliding relation":    func(_, p *pgRowPhysicalPlan) { p.entities[0].indexes[0].Name = "notes" },
		"reserved primary name": func(_, p *pgRowPhysicalPlan) { p.entities[0].indexes[0].Name = "notes_pkey" },
		"duplicate index": func(_, p *pgRowPhysicalPlan) {
			p.entities[0].indexes = append(p.entities[0].indexes, p.entities[0].indexes[0])
		},
		"retained removed": func(old, _ *pgRowPhysicalPlan) {
			old.entities[0].indexes = []PgMigrationCatalogIndex{{Name: "old_lookup", Columns: []string{"id"}}}
		},
		"retained redefined": func(old, _ *pgRowPhysicalPlan) {
			old.entities[0].indexes = []PgMigrationCatalogIndex{{Name: "fresh_lookup", Columns: []string{"id"}}}
		},
		"wrong owner":                  func(_, p *pgRowPhysicalPlan) { p.family = "Foreign" },
		"nonadjacent":                  func(_, p *pgRowPhysicalPlan) { p.version = 3 },
		"settled target":               func(_, p *pgRowPhysicalPlan) { p.settled = true },
		"transformation":               func(_, p *pgRowPhysicalPlan) { p.windows = []pgRowPhysicalWindow{{entity: "Note"}} },
		"missing settled prerequisite": func(_, p *pgRowPhysicalPlan) { p.requiresContractVersion = 1 },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			previous, plan := rowIndexPlanPair()
			plan.entities[0].columns = append(plan.entities[0].columns, pgRowPhysicalColumn{catalog: PgMigrationCatalogColumn{Name: "fresh", Type: "text", Nullable: true}, introducedVersion: 2})
			plan.entities[0].indexes = []PgMigrationCatalogIndex{{Name: "fresh_lookup", Columns: []string{"fresh"}}}
			mutate(previous, plan)
			if _, err := pgDeriveRowConcurrentIndexes(previous, plan); err == nil {
				t.Fatal("unsafe or malformed index revision accepted")
			}
		})
	}
}

func TestRowConcurrentIndexRetainedAndNewTableInventory(t *testing.T) {
	previous, plan := rowIndexPlanPair()
	previous.entities[0].indexes = []PgMigrationCatalogIndex{{Name: "existing_key", Columns: []string{"key"}}}
	plan.entities[0].indexes = slices.Clone(previous.entities[0].indexes)
	added := pgRowPhysicalEntity{identity: "Added", table: "added", generation: 1, insertGeneration: 1,
		columns: []pgRowPhysicalColumn{{catalog: PgMigrationCatalogColumn{Name: "id", Type: "text", PrimaryKey: true}, introducedVersion: 2}},
		indexes: []PgMigrationCatalogIndex{{Name: "added_key", Columns: []string{"id"}, Unique: true}}}
	plan.entities = append(plan.entities, added)
	indexes, err := pgDeriveRowConcurrentIndexes(previous, plan)
	if err != nil || len(indexes) != 0 {
		t.Fatal("unchanged or empty-table indexes became concurrent jobs", indexes, err)
	}
	plan.entities[1].indexes[0].Name = "existing_key"
	if _, err := pgDeriveRowConcurrentIndexes(previous, plan); err == nil {
		t.Fatal("cross-table relation collision accepted")
	}
}

func TestRowConcurrentIndexCompleteInventory(t *testing.T) {
	previous, plan := rowIndexPlanPair()
	plan.entities[0].columns = append(plan.entities[0].columns, pgRowPhysicalColumn{catalog: PgMigrationCatalogColumn{Name: "fresh", Type: "jsonb", Nullable: true}, introducedVersion: 2})
	plan.entities[0].indexes = []PgMigrationCatalogIndex{
		{Name: "first_lookup", Columns: []string{"id"}},
		{Name: "second_lookup", Columns: []string{"fresh"}},
	}
	indexes, err := pgDeriveRowConcurrentIndexes(previous, plan)
	if err != nil || len(indexes) != 2 || indexes[0].index.Name != "first_lookup" || indexes[1].index.Name != "second_lookup" {
		t.Fatal("complete ordered inventory lost", indexes, err)
	}
	plan.entities[0].indexes[1].Columns = []string{"key"}
	indexes, err = pgDeriveRowConcurrentIndexes(previous, plan)
	if err == nil || indexes != nil {
		t.Fatal("refused revision returned a partial executable inventory", indexes, err)
	}
}
