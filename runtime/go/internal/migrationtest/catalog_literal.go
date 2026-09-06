package migrationtest

import (
	"regexp"
	"strings"
)

var catalogNumber = regexp.MustCompile(`^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$`)

// literalCatalogDefault is the deliberately conservative fixture recognizer for
// server-deparsed defaults with standard_conforming_strings=on and an empty search_path.
// It accepts a scalar literal, or a quoted/NULL constant with one built-in type
// annotation. It does NOT treat an arbitrary cast expression as a constant:
// casts can run user code, domain constraints or time-dependent conversions.
// Unknown spellings are drift, never evidence that a default is harmless.
// This harness oracle is not embedded in the production runtime.
func literalCatalogDefault(expression string) bool {
	if len(expression) == 0 || len(expression) > 32768 {
		return false
	}
	s := strings.TrimSpace(expression)
	if catalogNumber.MatchString(s) || s == "true" || s == "false" || s == "NULL" {
		return true
	}
	var suffix string
	if strings.HasPrefix(s, "NULL::") {
		suffix = s[4:]
	} else {
		start, escaped := 0, false
		if strings.HasPrefix(s, "E'") || strings.HasPrefix(s, "e'") {
			start, escaped = 1, true
		}
		if len(s) <= start || s[start] != '\'' {
			return false
		}
		end := -1
		for i := start + 1; i < len(s); i++ {
			if escaped && s[i] == '\\' {
				i++
			} else if s[i] == '\'' {
				if i+1 < len(s) && s[i+1] == '\'' {
					i++
				} else {
					end = i + 1
					break
				}
			}
		}
		if end < 0 {
			return false
		}
		suffix = strings.TrimSpace(s[end:])
		if suffix == "" {
			return true
		}
	}
	if !strings.HasPrefix(suffix, "::") {
		return false
	}
	target := strings.TrimSpace(suffix[2:])
	target = strings.TrimPrefix(target, "pg_catalog.")
	// These are deparser spellings of supported built-in scalar constants, not
	// an open-ended SQL type-name grammar. No domains, user types, arrays, typmod
	// coercions, chained casts, COLLATE clauses or parenthesised computations.
	return constantCatalogType(target)
}

func constantCatalogType(target string) bool {
	switch target {
	case "boolean", "smallint", "integer", "bigint", "numeric", "real", "double precision",
		"text", "character varying", "character", "bytea", "json", "jsonb", "uuid",
		"date", "time without time zone", "time with time zone", "timestamp without time zone",
		"timestamp with time zone", "interval":
		return true
	}
	return false
}
