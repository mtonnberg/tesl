package teslrt

import (
	"encoding/json"
	"testing"
)

func TestRowRevalidateWireRequiresExactPrimitiveStorage(t *testing.T) {
	for _, carrier := range []string{"numeric", "float8", "text", "bool", "int4", "int8"} {
		old := PgRowSchemaColumn{Field: "value", Name: "value", Type: carrier}
		r := &pgMigrationWireReader{}
		pgRowCheckRevalidateColumn(r, "migrate", old, old)
		if r.err != nil {
			t.Fatal("identical primitive representation refused", carrier, r.err)
		}
	}
	for name, mutate := range map[string]func(*PgRowSchemaColumn, *PgRowSchemaColumn, *string){
		"different SQL type":        func(_, target *PgRowSchemaColumn, _ *string) { target.Type = "text" },
		"different physical column": func(_, target *PgRowSchemaColumn, _ *string) { target.Name = "value__v2" },
		"different logical field":   func(_, target *PgRowSchemaColumn, _ *string) { target.Field = "other" },
		"nullable change":           func(_, target *PgRowSchemaColumn, _ *string) { target.Nullable = true },
		"nullable storage":          func(old, target *PgRowSchemaColumn, _ *string) { old.Nullable, target.Nullable = true, true },
		"primary key":               func(old, target *PgRowSchemaColumn, _ *string) { old.PrimaryKey, target.PrimaryKey = true, true },
		"json codec":                func(old, target *PgRowSchemaColumn, _ *string) { old.Type, target.Type = "jsonb", "jsonb" },
		"derived callback":          func(_, _ *PgRowSchemaColumn, mode *string) { *mode = "derived" },
	} {
		t.Run(name, func(t *testing.T) {
			old := PgRowSchemaColumn{Field: "value", Name: "value", Type: "numeric"}
			target, mode := old, "migrate"
			mutate(&old, &target, &mode)
			r := &pgMigrationWireReader{}
			pgRowCheckRevalidateColumn(r, mode, old, target)
			if r.err == nil {
				t.Fatal("unsafe Revalidate representation accepted")
			}
		})
	}
}

func TestRowRevalidateWireMappingOperands(t *testing.T) {
	for _, test := range []struct {
		name, source, constant string
		ok                     bool
	}{
		{"same field", `"value"`, `null`, true},
		{"missing source", `null`, `null`, false},
		{"renamed source", `"other"`, `null`, false},
		{"literal instead of proof callback", `"value"`, `"1"`, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			r := &pgMigrationWireReader{}
			pgRowMapping(r, json.RawMessage(`{"target":"value","kind":"revalidate","proofEnforcement":"runtime-only","source":`+test.source+`,"constant":`+test.constant+`}`))
			if (r.err == nil) != test.ok {
				t.Fatal("unexpected Revalidate operand acceptance", r.err)
			}
		})
	}
}

func TestRowRevalidateCannotReplaceCheckedMapping(t *testing.T) {
	history, _, companion := rowTestFixture(t)
	if _, err := pgReadRowCompanion(history, rowTestJSON(t, companion)); err != nil {
		t.Fatal("unchanged fixture refused", err)
	}
	fields := rowTestTransform(companion)["fieldMapping"].([]any)
	title := fields[1].(map[string]any)
	title["kind"], title["source"] = "revalidate", "title"
	title["proofEnforcement"] = "runtime-only"
	if _, err := pgReadRowCompanion(history, rowTestJSON(t, companion)); err == nil {
		t.Fatal("Revalidate substituted for different compiler-checked semantic mapping")
	}
}

func TestRowRevalidateRequiresExplicitRuntimeOnlyEnforcement(t *testing.T) {
	for _, suffix := range []string{"", `,"proofEnforcement":"sql-check"`, `,"proofEnforcement":null`} {
		r := &pgMigrationWireReader{}
		pgRowMapping(r, json.RawMessage(`{"target":"value","kind":"revalidate","source":"value","constant":null`+suffix+`}`))
		if r.err == nil {
			t.Fatal("missing or unsupported proof enforcement accepted", suffix)
		}
	}
}
