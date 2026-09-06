package teslrt

import (
	"reflect"
	"slices"
	"strings"
	"testing"
)

func pgIndexCatalogTestTables() (*pgCatalogExpectations, *pgCatalogTable, *pgCatalogTable, pgMigrationIndexJob) {
	metadata := &pgCatalogExpectations{types: map[string]pgCatalogExpectedType{
		"text": {name: "text", kind: "b", opclass: 3126},
		"bool": {name: "bool", kind: "b", opclass: 10003},
	}}
	actual := &pgCatalogTable{Name: "todos", Columns: []pgCatalogColumn{
		{Number: 1, Name: "id", Type: "text", TypeNamespace: "pg_catalog", TypeKind: "b", Typmod: -1, Required: true},
		{Number: 3, Name: "done", Type: "bool", TypeNamespace: "pg_catalog", TypeKind: "b", Typmod: -1, Required: true},
	}}
	expected := *actual
	expected.Columns = slices.Clone(actual.Columns)
	expected.Columns[1].Number = 2 // A dropped old attribute is not index drift.
	actual.Indexes = []pgCatalogIndex{{Name: "done__v2", Method: "btree", Immediate: true,
		Keys: []int{3}, KeyCount: 1, AttributeCount: 1, Opclasses: []int64{10003}, Collations: []int64{0}, Options: []int64{0},
		Valid: true, Ready: true, Live: true}}
	expected.Indexes = slices.Clone(actual.Indexes)
	expected.Indexes[0].Keys = []int{2}
	job := pgMigrationIndexJob{Version: 2, Table: "todos", State: "valid",
		Index: PgMigrationCatalogIndex{Name: "done__v2", Columns: []string{"done"}}}
	return metadata, actual, &expected, job
}

func TestPgMigrationIndexCatalogReadiness(t *testing.T) {
	for _, unique := range []bool{false, true} {
		for _, state := range []string{"pending", "building", "failed", "valid"} {
			for _, physical := range []string{"absent", "initializing", "ready-invalid", "valid", "dead"} {
				t.Run(strings.Join([]string{map[bool]string{false: "plain", true: "unique"}[unique], state, physical}, "/"), func(t *testing.T) {
					metadata, actual, expected, job := pgIndexCatalogTestTables()
					job.Index.Unique, job.State = unique, state
					actual.Indexes[0].Unique, expected.Indexes[0].Unique = unique, unique
					switch physical {
					case "absent":
						actual.Indexes = nil
					case "initializing":
						actual.Indexes[0].Valid, actual.Indexes[0].Ready = false, false
					case "ready-invalid":
						actual.Indexes[0].Valid = false
					case "dead":
						actual.Indexes[0].Live = false
					}
					var report PgMigrationCatalogReport
					live, want, ready, err := pgPrepareIndexJobCatalog(metadata, actual, expected, []pgMigrationIndexJob{job}, 2, &report)
					if err != nil || len(live.Indexes) != 0 || len(want.Indexes) != 0 {
						t.Fatalf("exact registered index was not checked separately: %v %+v", err, report)
					}
					if ready != (!unique || physical == "valid" && state == "valid") {
						t.Fatalf("unexpected unique readiness: %v", ready)
					}
					brokenCompletion := state == "valid" && physical != "valid"
					if (len(report.Missing)+len(report.Drift) != 0) != brokenCompletion {
						t.Fatalf("completed state trusted over physical catalog: %+v", report)
					}
				})
			}
		}
	}
}

func TestPgMigrationIndexCatalogRejectsSemanticMutations(t *testing.T) {
	expression, predicate := "lower(done)", "done"
	mutations := map[string]func(*pgCatalogIndex){
		"method":             func(i *pgCatalogIndex) { i.Method = "hash" },
		"unique":             func(i *pgCatalogIndex) { i.Unique = true },
		"primary":            func(i *pgCatalogIndex) { i.Primary = true },
		"exclusion":          func(i *pgCatalogIndex) { i.Exclusion = true },
		"deferred":           func(i *pgCatalogIndex) { i.Immediate = false },
		"nulls-not-distinct": func(i *pgCatalogIndex) { i.NullsNotDistinct = true },
		"constraint-owned":   func(i *pgCatalogIndex) { i.ConstraintOwned = true },
		"wrong-key":          func(i *pgCatalogIndex) { i.Keys = []int{1} },
		"expression-key":     func(i *pgCatalogIndex) { i.Keys = []int{0} },
		"key-count":          func(i *pgCatalogIndex) { i.KeyCount = 0 },
		"include":            func(i *pgCatalogIndex) { i.AttributeCount = 2 },
		"opclass":            func(i *pgCatalogIndex) { i.Opclasses = []int64{1234} },
		"collation":          func(i *pgCatalogIndex) { i.Collations = []int64{1234} },
		"descending":         func(i *pgCatalogIndex) { i.Options = []int64{1} },
		"expression":         func(i *pgCatalogIndex) { i.Expression = &expression },
		"predicate":          func(i *pgCatalogIndex) { i.Predicate = &predicate },
	}
	for name, mutate := range mutations {
		t.Run(name, func(t *testing.T) {
			metadata, actual, expected, job := pgIndexCatalogTestTables()
			job.State = "building" // Pending work grants no weaker semantic shape.
			mutate(&actual.Indexes[0])
			var report PgMigrationCatalogReport
			_, _, _, err := pgPrepareIndexJobCatalog(metadata, actual, expected, []pgMigrationIndexJob{job}, 2, &report)
			if err != nil || len(report.Drift) != 1 {
				t.Fatalf("wrong physical index was accepted: %v %+v", err, report)
			}
		})
	}
}

func TestPgMigrationIndexCatalogDoesNotHideUnrecordedIndexesOrMutateInputs(t *testing.T) {
	metadata, actual, expected, job := pgIndexCatalogTestTables()
	unknown := actual.Indexes[0]
	unknown.Name = "unrecorded"
	actual.Indexes = append(actual.Indexes, unknown)
	originalActual, originalExpected := slices.Clone(actual.Indexes), slices.Clone(expected.Indexes)
	var report PgMigrationCatalogReport
	live, want, _, err := pgPrepareIndexJobCatalog(metadata, actual, expected, []pgMigrationIndexJob{job}, 2, &report)
	if err != nil || len(live.Indexes) != 1 || live.Indexes[0].Name != "unrecorded" || len(want.Indexes) != 0 ||
		!reflect.DeepEqual(actual.Indexes, originalActual) || !reflect.DeepEqual(expected.Indexes, originalExpected) {
		t.Fatalf("unrecorded index hidden or fingerprint source mutated: %v %+v %+v", err, live, want)
	}
	actual.Indexes[0].Name = "renamed"
	report = PgMigrationCatalogReport{}
	_, _, _, err = pgPrepareIndexJobCatalog(metadata, actual, expected, []pgMigrationIndexJob{job}, 2, &report)
	if err != nil || len(report.Missing) != 1 {
		t.Fatalf("a differently named lookalike satisfied the completed job: %v %+v", err, report)
	}
}

func TestPgMigrationFutureIndexRequiresSafeOldWriterDomain(t *testing.T) {
	for _, typ := range []string{"bool", "int4", "int8", "float8", "text", "numeric", "jsonb", "uuid", "custom"} {
		for _, unique := range []bool{false, true} {
			for _, newKey := range []bool{false, true} {
				for _, defaulted := range []bool{false, true} {
					actual := &pgCatalogTable{Columns: []pgCatalogColumn{{Name: "key", Type: typ, TypeNamespace: "pg_catalog", TypeKind: "b", Typmod: -1}}}
					expected := &pgCatalogTable{}
					if !newKey {
						expected.Columns = slices.Clone(actual.Columns)
					}
					if defaulted {
						actual.Columns[0].Default = new("true")
					}
					bounded := slices.Contains([]string{"bool", "int4", "int8", "float8"}, typ)
					supported := bounded || slices.Contains([]string{"text", "numeric", "jsonb"}, typ)
					want := supported && (newKey && !defaulted || !unique && bounded)
					got := pgFutureIndexSafeForWrites(actual, expected, PgMigrationCatalogIndex{Columns: []string{"key"}, Unique: unique})
					if got != want {
						t.Fatalf("type=%s unique=%v new=%v default=%v: got %v want %v", typ, unique, newKey, defaulted, got, want)
					}
				}
			}
		}
	}
	for name, mutate := range map[string]func(*pgCatalogColumn){
		"namespace": func(c *pgCatalogColumn) { c.TypeNamespace = "user" },
		"domain":    func(c *pgCatalogColumn) { c.TypeKind = "d" },
		"typmod":    func(c *pgCatalogColumn) { c.Typmod = 10 },
		"generated": func(c *pgCatalogColumn) { c.Generated = "s" },
		"identity":  func(c *pgCatalogColumn) { c.Identity = "a" },
		"collation": func(c *pgCatalogColumn) { c.Collation = 42 },
	} {
		t.Run(name, func(t *testing.T) {
			actual := &pgCatalogTable{Columns: []pgCatalogColumn{{Name: "key", Type: "bool", TypeNamespace: "pg_catalog", TypeKind: "b", Typmod: -1}}}
			mutate(&actual.Columns[0])
			if pgFutureIndexSafeForWrites(actual, &pgCatalogTable{}, PgMigrationCatalogIndex{Columns: []string{"key"}}) {
				t.Fatal("nonstandard future index column accepted")
			}
		})
	}
}
