package teslrt

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func TestMigrationCatalogLiteralDecodesOnlySupportedConstants(t *testing.T) {
	for _, tc := range []struct{ expression, typ, value string }{
		{"  -1200.5  ", "numeric", "-1200.5"}, {"+1.5e-10", "float8", "+1.5e-10"},
		{"true", "bool", "true"}, {"'quote''end'::text", "text", "quote'end"},
		{`'back\slash'::pg_catalog.text`, "text", `back\slash`},
		{`E'back\\slash\n\t\''::text`, "text", "back\\slash\n\t'"},
		{`E'\xc3\xa5\360\237\231\202'::text`, "text", "å🙂"},
		{`E'\u00e5\U0001f642'::text`, "text", "å🙂"},
		{"'{}'::jsonb", "jsonb", "{}"}, {"'2020-01-01'::date", "date", "2020-01-01"},
		{"'ok'::character varying", "varchar", "ok"}, {"'12:34:00'::time without time zone", "time", "12:34:00"},
		{"''::text", "text", ""}, {"'not SQL; nextval(''x'')'::text", "text", "not SQL; nextval('x')"},
	} {
		t.Run(tc.expression, func(t *testing.T) {
			got, ok := parsePgCatalogLiteral(tc.expression, tc.typ)
			if !ok || got.input == nil || *got.input != tc.value {
				t.Fatalf("literal %q: %#v %t, want %q", tc.expression, got, ok, tc.value)
			}
		})
	}
	for _, expression := range []string{"NULL", "NULL::text", "NULL::pg_catalog.text"} {
		value, ok := parsePgCatalogLiteral(expression, "text")
		if !ok || value.input != nil {
			t.Fatalf("SQL NULL lost: %#v %t", value, ok)
		}
	}
}

func TestMigrationCatalogLiteralRejectsComputationsAndAmbiguity(t *testing.T) {
	for _, tc := range []struct{ expression, typ string }{
		{"nextval('x')", "int8"}, {"now()", "timestamptz"}, {"lower('X')", "text"}, {"1 + 1", "int4"},
		{"(0)::public.custom_type", "int4"}, {"'now'::text::timestamptz", "timestamptz"},
		{"'x'::public.text", "text"}, {"'x'::text::text", "text"}, {"'x' COLLATE \"C\"", "text"},
		{"'too long'::varchar(2)", "varchar"}, {"'x'::text; select 1", "text"},
		{"'unterminated", "text"}, {"E'bad\\'", "text"}, {`E'\uD800\uDC00'`, "text"},
		{`E'\x00'`, "text"}, {`E'\U00110000'`, "text"}, {`E'\777'`, "text"}, {`E'\xff'`, "text"},
		{"'x'\n'y'", "text"}, {"'x'::text[]", "text"}, {"'x'::TEXT", "text"},
		{"'x' /* comment */", "text"}, {"NULL::unknown", "text"}, {"NULL", "domain"},
		{"true", "int4"}, {"42", "text"}, {"'x'::text", "int4"},
		{"", "text"}, {"'\x00'", "text"}, {"'\xff'", "text"},
	} {
		t.Run(tc.expression, func(t *testing.T) {
			if _, ok := parsePgCatalogLiteral(tc.expression, tc.typ); ok {
				t.Fatalf("computing or unsupported default accepted: %q on %s", tc.expression, tc.typ)
			}
		})
	}
}

func FuzzMigrationCatalogLiteral(f *testing.F) {
	for _, seed := range []string{"'x'::text", `E'\\\x27'::text`, "NULL::pg_catalog.text", "now()", "'x'::text;select 1", "'å🙂'", "'-123'::integer", "'-9007199254740993'::bigint", "true", "-1.25e2"} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, expression string) {
		for _, typ := range []string{"text", "numeric", "int4", "float8", "bool"} {
			value, ok := parsePgCatalogLiteral(expression, typ)
			if ok && value.input != nil && (!utf8.ValidString(*value.input) || strings.ContainsRune(*value.input, 0)) {
				t.Fatal("decoded invalid PostgreSQL input")
			}
			if ok {
				validInput := value.inputType == "" || value.inputType == typ
				if typ == "numeric" {
					validInput = validInput || value.inputType == "int2" || value.inputType == "int4" || value.inputType == "int8"
				}
				if !validInput {
					t.Fatalf("unexpected input cast %s to %s", value.inputType, typ)
				}
				for _, suffix := range []string{";select 1", " || 'x'", " -- comment"} {
					if _, accepted := parsePgCatalogLiteral(expression+suffix, typ); accepted {
						t.Fatalf("accepted expression continuation: %q on %s", expression+suffix, typ)
					}
				}
			}
		}
	})
}

func TestMigrationCatalogLiteralPreservesIntegerInputForNumericDefaults(t *testing.T) {
	for _, typ := range []string{"int2", "int4", "int8"} {
		value, ok := parsePgCatalogLiteral("'-123'::pg_catalog."+typ, "numeric")
		if !ok || value.inputType != typ || value.input == nil || *value.input != "-123" {
			t.Fatalf("lost integer range: %+v, %v", value, ok)
		}
	}
	for _, source := range []string{"float8", "text", "public.int4", "int4::numeric", "numeric(5,2)"} {
		if _, ok := parsePgCatalogLiteral("'12'::"+source, "numeric"); ok {
			t.Fatalf("accepted unsupported cast %s", source)
		}
	}
	for _, test := range []struct{ expression, typ string }{
		{strings.Repeat("1", 131072), "numeric"}, {"'" + strings.Repeat("x", 65536) + "'::text", "text"},
	} {
		if _, ok := parsePgCatalogLiteral(test.expression, test.typ); !ok {
			t.Fatal("valid large source constant prevents old-version admission")
		}
	}
}
