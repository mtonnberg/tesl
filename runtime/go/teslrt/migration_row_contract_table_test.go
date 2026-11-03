package teslrt

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
	"testing"
)

func tableContractFixture() (*pgRowPhysicalPlan, *pgRowPhysicalPlan, pgRowCanonical, pgRowCanonical, pgRowCanonical, pgRowCanonical) {
	entity := func(name string) pgRowPhysicalEntity {
		return pgRowPhysicalEntity{identity: name, table: strings.ToLower(name), generation: 1, insertGeneration: 1, typeContractHash: strings.Repeat("a", 64), columns: []pgRowPhysicalColumn{{catalog: PgMigrationCatalogColumn{Name: "id", Type: "text", PrimaryKey: true}, introducedVersion: 1}}, projection: []pgRowPhysicalField{{logical: "id", physical: "id"}}}
	}
	retirement := pgRowPhysicalRetirement{entity: "Archive", fromSchemaHash: strings.Repeat("d", 64), toSchemaHash: strings.Repeat("b", 64)}
	archive, note := entity("Archive"), entity("Note")
	window := &pgRowPhysicalPlan{family: "Schema.Notes", namespace: "notes", version: 2, schemaSnapshotHash: strings.Repeat("b", 64), storageSnapshotHash: strings.Repeat("c", 64), entities: []pgRowPhysicalEntity{archive, note}, retirements: []pgRowPhysicalRetirement{retirement}}
	settled := *window
	settled.settled = true
	settled.retirements = nil
	settled.entities = []pgRowPhysicalEntity{note}
	basic := func(tag string, version int, schema string, entities []pgRowPhysicalEntity, reverse bool) pgRowCanonical {
		nodes := []pgRowCanonical{}
		for _, e := range entities {
			n := pgRowPhysicalEntityNode(e)
			if !reverse {
				n.children = n.children[:9]
			}
			nodes = append(nodes, n)
		}
		return pgRowList(pgRowAtom(tag), pgRowAtom(window.family), pgRowAtom(window.namespace), pgRowAtom(fmt.Sprint(version)), pgRowAtom(schema), pgRowAtom(window.storageSnapshotHash), pgRowList(nodes...), pgRowList())
	}
	physical := basic("tesl-retained-physical-version-v5", 2, window.schemaSnapshotHash, window.entities, true)
	physical.children = append(physical.children, pgRowList(), pgRowList(pgRowRetirementNode(retirement)))
	final := basic("tesl-settled-physical-version-v1", 2, window.schemaSnapshotHash, settled.entities, false)
	prior := basic("tesl-retained-physical-version-v1", 1, retirement.fromSchemaHash, window.entities, false)
	encode := func(n pgRowCanonical) (string, string) {
		raw, hash := pgRowBaselineDocument(n)
		return hex.EncodeToString([]byte(raw)), hash
	}
	window.contract, window.hash = encode(physical)
	settled.contract, settled.hash = encode(final)
	contract := pgRowList(pgRowAtom("tesl-table-contract-v1"), pgRowAtom(window.family), pgRowAtom(window.namespace), pgRowAtom("2"), pgRowAtom(window.schemaSnapshotHash), pgRowAtom(pgRowTableRetirementBehavior(window)), pgRowAtom(window.hash), pgRowAtom(settled.hash), pgRowList(), pgRowList(pgRowList(pgRowAtom("drop-table"), pgRowAtom("Archive"), pgRowPhysicalEntityNode(archive))))
	return window, &settled, contract, physical, final, prior
}
func tableContractBytes(n pgRowCanonical) ([]byte, string) {
	raw := []byte(pgRowEncode(pgRowList(pgRowAtom("tesl-migration-canonical"), pgRowAtom("1"), pgRowAtom("contract"), n)))
	return raw, fmt.Sprintf("%x", sha256.Sum256(raw))
}
func TestRowTableContractExactAuthority(t *testing.T) {
	w, s, n, _, _, _ := tableContractFixture()
	raw, hash := tableContractBytes(n)
	parsed, err := pgParseRowContract(hex.EncodeToString(raw), hash, w, s)
	if err != nil || len(parsed.operations) != 1 || len(parsed.finalGenerations) != 0 || parsed.preparationCount != 0 {
		t.Fatal("pure table retirement", parsed, err)
	}
	for name, mutate := range map[string]func(*pgRowPhysicalPlan, *pgRowPhysicalPlan, *pgRowCanonical){
		"forged finality": func(w, s *pgRowPhysicalPlan, n *pgRowCanonical) {
			n.children[8] = pgRowList(pgRowList(pgRowAtom("Archive"), pgRowAtom("2")))
		},
		"old contract tag":  func(w, s *pgRowPhysicalPlan, n *pgRowCanonical) { n.children[0] = pgRowAtom("tesl-row-contract-v1") },
		"omitted operation": func(w, s *pgRowPhysicalPlan, n *pgRowCanonical) { n.children[9] = pgRowList() },
		"extra operation": func(w, s *pgRowPhysicalPlan, n *pgRowCanonical) {
			n.children[9].children = append(n.children[9].children, n.children[9].children[0])
		},
		"changed predecessor": func(w, s *pgRowPhysicalPlan, n *pgRowCanonical) {
			n.children[9].children[0].children[2].children[1] = pgRowAtom("foreign")
		},
		"changed behavior":   func(w, s *pgRowPhysicalPlan, n *pgRowCanonical) { n.children[5] = pgRowAtom(strings.Repeat("e", 64)) },
		"changed survivor":   func(w, s *pgRowPhysicalPlan, n *pgRowCanonical) { s.entities[0].insertGeneration = 2 },
		"last entity":        func(w, s *pgRowPhysicalPlan, n *pgRowCanonical) { s.entities = nil },
		"mixed transform":    func(w, s *pgRowPhysicalPlan, n *pgRowCanonical) { w.windows = []pgRowPhysicalWindow{{}} },
		"missing retirement": func(w, s *pgRowPhysicalPlan, n *pgRowCanonical) { w.retirements = nil },
	} {
		t.Run(name, func(t *testing.T) {
			w, s, n, _, _, _ := tableContractFixture()
			mutate(w, s, &n)
			raw, hash := tableContractBytes(n)
			if _, err := pgParseRowContract(hex.EncodeToString(raw), hash, w, s); err == nil {
				t.Fatal("unauthorized table retirement accepted")
			}
		})
	}
}
func TestPgRowTableContractProtectedCanonicalValidation(t *testing.T) {
	f := pgNewControlTest(t)
	if _, err := f.installer.Exec(f.ctx, "create schema "+quoteIdentifier(f.namespace)+" authorization "+quoteIdentifier(f.roles.Owner)); err != nil {
		t.Fatal(err)
	}
	functions := append(pgRowTableContractFunctions(f.namespace), pgRowQueueFunctions(f.namespace)[0])
	for _, fn := range pgQueueRegistrationFunctions(f.namespace) {
		if fn.name == "tesl_queue_bytes" {
			functions = append(functions, fn)
		}
	}
	for _, fn := range functions {
		if _, err := f.installer.Exec(f.ctx, pgControlFunctionSQL(f.namespace, f.roles.Owner, fn)); err != nil {
			t.Fatal(fn.name, err)
		}
	}
	validate := func(n, p, s, previous pgRowCanonical) (bool, error) {
		physical, physicalHash := pgRowBaselineDocument(p)
		settled, settledHash := pgRowBaselineDocument(s)
		n.children[6] = pgRowAtom(physicalHash)
		n.children[7] = pgRowAtom(settledHash)
		behavior := pgRowList(pgRowAtom("tesl-table-retirement-v1"), p.children[1], p.children[2], p.children[3], p.children[9])
		_, behaviorHash := tableContractBytes(behavior)
		n.children[5] = pgRowAtom(behaviorHash)
		doc, _ := tableContractBytes(n)
		prior, _ := pgRowBaselineDocument(previous)
		var valid bool
		err := f.installer.QueryRow(f.ctx, "select "+quoteIdentifier(f.namespace)+".tesl_row_table_contract_valid($1,$2,$3,$4,2)", doc, []byte(physical), []byte(settled), []byte(prior)).Scan(&valid)
		return valid, err
	}
	_, _, n, p, s, prior := tableContractFixture()
	physicalDoc, _ := pgRowBaselineDocument(p)
	var family string
	if err := f.installer.QueryRow(f.ctx, "select "+quoteIdentifier(f.namespace)+".tesl_row_physical_source_header($1)->>'family'", []byte(physicalDoc)).Scan(&family); err != nil || family != "Schema.Notes" {
		t.Fatal("v5 exact physical header", family, err)
	}
	for _, mutate := range []func(string) string{
		func(doc string) string {
			return strings.Replace(doc, "l10:s33:tesl-retained-physical-version-v5", "l010:s33:tesl-retained-physical-version-v5", 1)
		},
		func(doc string) string {
			return strings.Replace(doc, "l10:s33:tesl-retained-physical-version-v5", "l11:s33:tesl-retained-physical-version-v5", 1)
		},
		func(doc string) string {
			return strings.Replace(doc, "tesl-retained-physical-version-v5", "tesl-retained-physical-version-v4", 1)
		},
		func(doc string) string {
			return strings.Replace(doc, "l10:s33:tesl-retained-physical-version-v5", "l9:s33:tesl-retained-physical-version-v5", 1)
		},
	} {
		if err := f.installer.QueryRow(f.ctx, "select "+quoteIdentifier(f.namespace)+".tesl_row_physical_source_header($1)->>'family'", []byte(mutate(physicalDoc))).Scan(&family); err == nil {
			t.Fatal("inexact v5 physical header accepted")
		}
	}

	if ok, err := validate(n, p, s, prior); err != nil || !ok {
		t.Fatal("exact SQL retirement refused", ok, err)
	}
	for name, mutate := range map[string]func(*pgRowCanonical, *pgRowCanonical, *pgRowCanonical, *pgRowCanonical){
		"forged finality": func(n, p, s, prior *pgRowCanonical) {
			n.children[8] = pgRowList(pgRowList(pgRowAtom("Archive"), pgRowAtom("2")))
		},
		"changed survivor before window": func(n, p, s, prior *pgRowCanonical) {
			p.children[6].children[1].children[1] = pgRowAtom("changed")
			s.children[6].children[0].children[1] = pgRowAtom("changed")
		},
		"duplicate surviving identity": func(n, p, s, prior *pgRowCanonical) {
			p.children[6].children = append(p.children[6].children, p.children[6].children[1])
			prior.children[6].children = append(prior.children[6].children, prior.children[6].children[1])
			s.children[6].children = append(s.children[6].children, s.children[6].children[0])
		},
		"wrong source edge": func(n, p, s, prior *pgRowCanonical) {
			p.children[9].children[0].children[1] = pgRowAtom(strings.Repeat("f", 64))
		},
		"wrong predecessor table":    func(n, p, s, prior *pgRowCanonical) { prior.children[6].children[0].children[1] = pgRowAtom("foreign") },
		"unrelated survivor removed": func(n, p, s, prior *pgRowCanonical) { s.children[6] = pgRowList() },
		"missing operation":          func(n, p, s, prior *pgRowCanonical) { n.children[9] = pgRowList() },
		"wrong drop table": func(n, p, s, prior *pgRowCanonical) {
			n.children[9].children[0].children[2].children[1] = pgRowAtom("foreign")
		},
	} {
		t.Run(name, func(t *testing.T) {
			_, _, n, p, s, prior := tableContractFixture()
			mutate(&n, &p, &s, &prior)
			ok, err := validate(n, p, s, prior)
			if err == nil && ok {
				t.Fatal("forged canonical retirement accepted")
			}
		})
	}
	for _, doc := range []string{"l01:s1:x", "l1:s2:x", "l1:l1:", "l0:trailing", "l1:s01:x", "l2:s1:x", "l1:l1000001:"} {
		var nodes [][]byte
		if err := f.installer.QueryRow(f.ctx, "select "+quoteIdentifier(f.namespace)+".tesl_row_canonical_children($1)", []byte(doc)).Scan(&nodes); err == nil {
			t.Fatalf("malformed framing accepted: %s", doc)
		}
	}
}

func TestPgRowTableContractDependencyPreflight(t *testing.T) {
	f := pgNewControlTest(t)
	ns := quoteIdentifier(f.namespace) + "."
	if _, err := f.installer.Exec(f.ctx, "create schema "+quoteIdentifier(f.namespace)+"; create table "+ns+"archive(id text primary key); create index archive_id_idx on "+ns+"archive(id)"); err != nil {
		t.Fatal(err)
	}
	w, s, _, _, _, _ := tableContractFixture()
	w.namespace = f.namespace
	c := &pgRowContract{window: w, settled: s}
	check := func(want bool) {
		t.Helper()
		err := pgRowTableContractDependencies(f.ctx, f.installer, c)
		if (err != nil) != want {
			t.Fatalf("dependency refusal=%v, error=%v", want, err)
		}
	}
	check(false)
	for _, test := range []struct{ name, create, drop string }{
		{"view", "create view " + ns + "dependent as select id from " + ns + "archive", "drop view " + ns + "dependent"},
		{"foreign key", "create table " + ns + "dependent(id text references " + ns + "archive(id))", "drop table " + ns + "dependent"},
		{"row type", "create function " + ns + "dependent() returns " + ns + "archive language sql as 'select null::" + ns + "archive'", "drop function " + ns + "dependent()"},
		{"row array type", "create function " + ns + "dependent() returns " + ns + "archive[] language sql as 'select null::" + ns + "archive[]'", "drop function " + ns + "dependent()"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := f.installer.Exec(f.ctx, test.create); err != nil {
				t.Fatal(err)
			}
			check(true)
			if _, err := f.installer.Exec(f.ctx, test.drop); err != nil {
				t.Fatal(err)
			}
			check(false)
		})
	}
}
