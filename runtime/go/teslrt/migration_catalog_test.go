package teslrt

import (
	"strings"
	"testing"
)

func TestMigrationCatalogRejectsUnrepresentableContractBeforeSQL(t *testing.T) {
	valid := func() []PgMigrationCatalogTable {
		return []PgMigrationCatalogTable{{Name: "items", Columns: []PgMigrationCatalogColumn{
			{Name: "id", Type: "text", PrimaryKey: true}, {Name: "count", Type: "numeric"},
		}}}
	}
	if err := pgValidateMigrationCatalog(valid()); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name   string
		change func([]PgMigrationCatalogTable) []PgMigrationCatalogTable
	}{
		{"duplicate_table", func(ts []PgMigrationCatalogTable) []PgMigrationCatalogTable { return append(ts, ts[0]) }},
		{"table_name", func(ts []PgMigrationCatalogTable) []PgMigrationCatalogTable { ts[0].Name = "bad\x00name"; return ts }},
		{"primary_name_limit", func(ts []PgMigrationCatalogTable) []PgMigrationCatalogTable {
			ts[0].Name = strings.Repeat("x", 59)
			return ts
		}},
		{"primary_relation_collision", func(ts []PgMigrationCatalogTable) []PgMigrationCatalogTable {
			ts = append(ts, valid()[0])
			ts[1].Name = "items_pkey"
			return ts
		}},
		{"duplicate_column", func(ts []PgMigrationCatalogTable) []PgMigrationCatalogTable { ts[0].Columns[1].Name = "id"; return ts }},
		{"type_expression", func(ts []PgMigrationCatalogTable) []PgMigrationCatalogTable {
			ts[0].Columns[1].Type = "numeric(2)"
			return ts
		}},
		{"no_primary", func(ts []PgMigrationCatalogTable) []PgMigrationCatalogTable {
			ts[0].Columns[0].PrimaryKey = false
			return ts
		}},
		{"two_primaries", func(ts []PgMigrationCatalogTable) []PgMigrationCatalogTable {
			ts[0].Columns[1].PrimaryKey = true
			return ts
		}},
		{"nullable_primary", func(ts []PgMigrationCatalogTable) []PgMigrationCatalogTable {
			ts[0].Columns[0].Nullable = true
			return ts
		}},
		{"primary_index_collision", func(ts []PgMigrationCatalogTable) []PgMigrationCatalogTable {
			ts[0].Indexes = []PgMigrationCatalogIndex{{Name: "items_pkey", Columns: []string{"count"}}}
			return ts
		}},
		{"missing_key", func(ts []PgMigrationCatalogTable) []PgMigrationCatalogTable {
			ts[0].Indexes = []PgMigrationCatalogIndex{{Name: "by_count", Columns: []string{"missing"}}}
			return ts
		}},
		{"duplicate_key", func(ts []PgMigrationCatalogTable) []PgMigrationCatalogTable {
			ts[0].Indexes = []PgMigrationCatalogIndex{{Name: "by_count", Columns: []string{"count", "count"}}}
			return ts
		}},
		{"default_expression", func(ts []PgMigrationCatalogTable) []PgMigrationCatalogTable {
			ts[0].Columns[1].Default = &PgMigrationCatalogConstant{Kind: "int", Value: "1+1"}
			return ts
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if err := pgValidateMigrationCatalog(tc.change(valid())); err == nil {
				t.Fatal("invalid storage contract accepted")
			}
		})
	}
}

func TestMigrationCatalogConstantsPreserveCanonicalInput(t *testing.T) {
	for _, tc := range []struct{ typ, kind, value string }{
		{"numeric", "int", "01"}, {"numeric", "int", "+1"}, {"numeric", "int", "-0"},
		{"numeric", "int", strings.Repeat("1", 131073)}, {"int4", "int", "2147483648"},
		{"float8", "float64", "3FF8000000000000"}, {"float8", "float64", "7ff0000000000000"},
		{"float8", "float64", "7ff8000000000000"}, {"float8", "float64", "0"},
		{"bool", "bool", "TRUE"}, {"text", "string", "a\x00b"}, {"text", "string", "\xff"},
		{"text", "unknown", "x"}, {"jsonb", "string", "{}"},
	} {
		if _, err := pgMigrationConstantInput(tc.typ, PgMigrationCatalogConstant{Kind: tc.kind, Value: tc.value}); err == nil {
			t.Fatalf("noncanonical %s/%s constant accepted", tc.typ, tc.kind)
		}
	}
	for _, tc := range []struct{ typ, kind, value, input string }{
		{"numeric", "int", "-123", "-123"}, {"float8", "float64", "8000000000000000", "-0"},
		{"bool", "bool", "false", "false"}, {"text", "string", "å🙂'\\", "å🙂'\\"},
	} {
		got, err := pgMigrationConstantInput(tc.typ, PgMigrationCatalogConstant{Kind: tc.kind, Value: tc.value})
		if err != nil || got != tc.input {
			t.Fatalf("constant changed: %q %v", got, err)
		}
	}
}
