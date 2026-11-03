package migrationtest

import (
	"strings"
	"testing"
)

// INV-CATALOG-DEFAULT; TR-CATALOG-COMPARE.
func TestLiteralCatalogDefaultFailsClosed(t *testing.T) {
	for _, literal := range []string{
		"0", "-1", "+12.5", "-.5", "1e+10", "NULL", "true", "false",
		"''", "'a''b'::text", "'function(1)::evil'::text", "'{}'::jsonb",
		"'2020-01-01'::date", "NULL::pg_catalog.text", "E'a\\'b'::text",
		"E'\\\\'::bytea", "'λ\nquote''end'::text",
	} {
		if !literalCatalogDefault(literal) {
			t.Errorf("safe constant refused: %q", literal)
		}
	}
	for _, expression := range []string{
		"", " ", "now()", "nextval('s')", "gen_random_uuid()", "lower('X')",
		"0 + 1", "(0)", "(0)::example.user_type", "0::text", "'x'::example.user_type",
		"'x'::example.domain", "('now'::text)::timestamp with time zone", "'x'::text::text",
		"'x'::text collate pg_catalog.\"C\"", "'x'::\"text\"", "'x'::pg_catalog.\"TEXT\"",
		"'x'::text; select 1", "'x'::text -- comment", "'x'::text/* comment */",
		"'x' || 'y'", "'x'::text + 'y'::text", "'not closed", "E'\\'", "E'x\\'::text",
		"'x'::text[]", "'x'::character varying(3)", "$tag$x$tag$", "NULL::user_domain",
		"NaN", "Inf", "1e", "1_000", "0x10", "'x'\x00::text", strings.Repeat("'", 32769),
	} {
		if literalCatalogDefault(expression) {
			t.Errorf("computing, unsupported or malformed default accepted: %q", expression)
		}
	}
	// Any suffix outside the recognized constant grammar must remain a refusal,
	// even when it contains quote/backslash bytes that resemble literal contents.
	for _, prefix := range []string{"0", "'x'", "E'x'", "'x'::text"} {
		for _, suffix := range []string{";", "--", "/*", "()", "::user_type", " + 1", " || 'x'", "\x00"} {
			if literalCatalogDefault(prefix + suffix) {
				t.Errorf("suffix escaped grammar: %q", prefix+suffix)
			}
		}
	}
}
