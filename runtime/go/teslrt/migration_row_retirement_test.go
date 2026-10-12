package teslrt

import (
	"fmt"
	"slices"
	"strings"
	"testing"
)

// Deliberately inert structural fixtures: these tests cannot install a catalog
// or publish an adapter. Generated application acceptance covers that authority.
func rowRetirementSourceFixture(t *testing.T) (PgCompiledMigrationHistory, map[string]any) {
	h, base, _ := rowTestFixture(t)
	a, l := pgRowAtom, pgRowList
	boolean := func(v bool) pgRowCanonical { return l(a("bool"), a(fmt.Sprint(v))) }
	db := rowTestDB(base)
	versions := []any{}
	for v := 1; v <= 2; v++ {
		names := []string{"Archive", "Note"}
		if v == 2 {
			names = []string{"Note"}
		}
		roots, defs, tables := []pgRowCanonical{}, []pgRowCanonical{}, []pgRowCanonical{}
		entities := []any{}
		for _, name := range names {
			table := strings.ToLower(name)
			ref := pgRowTypeReference(h.Family, name)
			body := l(a("entity"), ref, a(table), a("id"), l(l(a("field"), a("id"), a("fixture-string"), l(a("none")), l(a("none")))), l())
			definition := l(ref, body)
			roots = append(roots, ref)
			defs = append(defs, definition)
			typeDoc := l(a("stored-value-semantics"), a(h.StoredValueCompatibility), l(a("closure"), l(ref), l(definition)))
			typeHex, typeHash := rowTestDoc("contract", typeDoc)
			entities = append(entities, map[string]any{"entity": name, "table": table, "generation": 1, "typeContract": typeHex, "typeContractHash": typeHash, "goTypePackage": "tesl.generated/schema", "goTypeName": name, "columns": []any{map[string]any{"field": "id", "name": "id", "type": "text", "nullable": false, "primaryKey": true}}})
			tables = append(tables, l(a(table), l(l(a("id"), a("text"), boolean(false), boolean(true))), l()))
		}
		slices.SortFunc(roots, func(a, b pgRowCanonical) int { return strings.Compare(pgRowEncode(a), pgRowEncode(b)) })
		slices.SortFunc(defs, func(a, b pgRowCanonical) int {
			return strings.Compare(pgRowEncode(a.children[0]), pgRowEncode(b.children[0]))
		})
		schema := l(a("stored-value-semantics"), a(h.StoredValueCompatibility), l(a("closure"), l(roots...), l(defs...)))
		schemaHex, schemaHash := rowTestDoc("snapshot", schema)
		storageHex, storageHash := rowTestDoc("migration", l(a("postgres-storage-v1"), schema, l(tables...)))
		versions = append(versions, map[string]any{"version": v, "schemaContract": schemaHex, "schemaSnapshotHash": schemaHash, "storageContract": storageHex, "storageSnapshotHash": storageHash, "entities": entities})
	}
	base["version"] = 5
	db["versions"] = versions
	db["retirements"] = []any{map[string]any{"migrationVersion": 2, "entity": "Archive", "fromSchemaSnapshot": versions[0].(map[string]any)["schemaSnapshotHash"], "toSchemaSnapshot": versions[1].(map[string]any)["schemaSnapshotHash"]}}
	h.HistoryJSON = rowTestJSON(t, base)
	return h, base
}
func TestRowRetirementSourceAuthority(t *testing.T) {
	h, _ := rowRetirementSourceFixture(t)
	inventory, err := pgReadRowBase(h)
	if err != nil || len(inventory) != 1 || len(inventory[0].Retirements) != 1 {
		t.Fatal("explicit source retirement rejected", err)
	}
	cases := map[string]func(map[string]any){
		"legacy omission cannot grant retirement": func(b map[string]any) { b["version"] = 4; delete(rowTestDB(b), "retirements") },
		"missing authority":                       func(b map[string]any) { rowTestDB(b)["retirements"] = []any{} },
		"duplicate authority": func(b map[string]any) {
			r := rowTestDB(b)["retirements"].([]any)
			rowTestDB(b)["retirements"] = append(r, r[0])
		},
		"wrong retiring entity": func(b map[string]any) { rowTestDB(b)["retirements"].([]any)[0].(map[string]any)["entity"] = "Note" },
		"wrong predecessor": func(b map[string]any) {
			rowTestDB(b)["retirements"].([]any)[0].(map[string]any)["fromSchemaSnapshot"] = strings.Repeat("a", 64)
		},
		"unknown descriptor field": func(b map[string]any) { rowTestDB(b)["retirements"].([]any)[0].(map[string]any)["force"] = true },
		"transformed retired entity": func(b map[string]any) {
			rowTestDB(b)["versions"].([]any)[0].(map[string]any)["entities"].([]any)[0].(map[string]any)["generation"] = 2
		},
		"retired identity cannot reappear": func(b map[string]any) {
			db := rowTestDB(b)
			versions := db["versions"].([]any)
			origin := versions[0].(map[string]any)
			third := map[string]any{}
			for key, value := range origin {
				third[key] = value
			}
			third["version"] = 3
			db["versions"] = append(versions, third)
			db["currentVersion"] = 3
			db["origins"] = append(db["origins"].([]any), map[string]any{"initialVersion": 3, "steps": nil, "errors": []any{map[string]any{"code": "MIG016", "message": "structural fixture"}}})
		},
		"changed survivor generation": func(b map[string]any) {
			rowTestDB(b)["versions"].([]any)[1].(map[string]any)["entities"].([]any)[0].(map[string]any)["generation"] = 2
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			h, b := rowRetirementSourceFixture(t)
			mutate(b)
			h.CurrentVersion = rowTestDB(b)["currentVersion"].(int)
			h.HistoryJSON = rowTestJSON(t, b)
			if _, err := pgReadRowBase(h); err == nil {
				t.Fatal("malformed retirement accepted")
			}
		})
	}
}

func rowRetirementPhysicalFixture(t *testing.T) (*pgRowPhysicalPlan, pgRowCanonical) {
	seed := rowPhysicalSeed(t).Databases[0].Versions[0]
	previous, err := pgParseRowPhysicalPlan(seed.Contract, seed.Hash)
	if err != nil || len(previous.entities) == 0 {
		t.Fatal(err)
	}
	old := previous.entities[0]
	old.identity = "Archive"
	old.table = "archive"
	old.indexes = nil
	keep := old
	keep.identity = "Note"
	keep.table = "notes"
	previous.entities = []pgRowPhysicalEntity{old, keep}
	a, l := pgRowAtom, pgRowList
	node := l(a("tesl-retained-physical-version-v5"), a(previous.family), a(previous.namespace), a("2"), a(strings.Repeat("b", 64)), a(strings.Repeat("c", 64)), l(pgRowPhysicalEntityNode(old), pgRowPhysicalEntityNode(keep)), l(), l(), l(l(a("Archive"), a(previous.schemaSnapshotHash), a(strings.Repeat("b", 64)))))
	return previous, node
}
func TestRowRetirementPhysicalAuthority(t *testing.T) {
	previous, node := rowRetirementPhysicalFixture(t)
	encoded, hash := rowTestDoc("migration", node)
	plan, err := pgParseRowPhysicalPlan(encoded, hash)
	if err != nil {
		t.Fatal(err)
	}
	if err := pgValidateRowPhysicalLineage(previous, plan); err != nil {
		t.Fatal(err)
	}
	if plan.compiled != nil {
		t.Fatal("description parser granted execution authority")
	}
	cases := map[string]func(*pgRowCanonical){
		"missing retirement": func(n *pgRowCanonical) { n.children[9] = pgRowList() },
		"duplicate retirement": func(n *pgRowCanonical) {
			n.children[9].children = append(n.children[9].children, n.children[9].children[0])
		},
		"missing retained table":      func(n *pgRowCanonical) { n.children[6].children = n.children[6].children[1:] },
		"unknown owner":               func(n *pgRowCanonical) { n.children[9].children[0].children[0] = pgRowAtom("Unknown") },
		"wrong predecessor":           func(n *pgRowCanonical) { n.children[9].children[0].children[1] = pgRowAtom(strings.Repeat("d", 64)) },
		"wrong target":                func(n *pgRowCanonical) { n.children[9].children[0].children[2] = pgRowAtom(strings.Repeat("d", 64)) },
		"changed retained generation": func(n *pgRowCanonical) { n.children[6].children[0].children[2] = pgRowAtom("2") },
		"changed survivor type":       func(n *pgRowCanonical) { n.children[6].children[1].children[4] = pgRowAtom(strings.Repeat("d", 64)) },
		"retirement at origin":        func(n *pgRowCanonical) { n.children[3] = pgRowAtom("1") },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			previous, node := rowRetirementPhysicalFixture(t)
			mutate(&node)
			encoded, hash := rowTestDoc("migration", node)
			plan, err := pgParseRowPhysicalPlan(encoded, hash)
			if err == nil {
				err = pgValidateRowPhysicalLineage(previous, plan)
			}
			if err == nil {
				t.Fatal("malformed retirement accepted")
			}
		})
	}
}
