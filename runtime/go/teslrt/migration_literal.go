package teslrt

import (
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

// pgCatalogLiteral reads only the closed constant language emitted by
// pg_get_expr with standard_conforming_strings=on and an empty search_path.
// The caller must separately check the column's actual pg_catalog base type,
// typmod, nullability and storage attributes. This is not a general SQL expression
// parser, nor permission to evaluate the original expression. Its decoded value
// can be submitted as a parameter to a checked built-in input type in a temporary
// comparison table; no user-provided cast/function text is carried forward.
type pgCatalogLiteral struct {
	input     *string // nil is SQL NULL
	inputType string  // Original checked input type, before a lossless numeric widening.
}

var pgCatalogNumber = regexp.MustCompile(`^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$`)

func pgCatalogBaseType(name string) string {
	switch name {
	case "bool", "boolean":
		return "bool"
	case "int2", "smallint":
		return "int2"
	case "int4", "integer":
		return "int4"
	case "int8", "bigint":
		return "int8"
	case "numeric":
		return "numeric"
	case "float4", "real":
		return "float4"
	case "float8", "double precision":
		return "float8"
	case "varchar", "character varying":
		return "varchar"
	case "bpchar", "character":
		return "bpchar"
	case "timestamp", "timestamp without time zone":
		return "timestamp"
	case "timestamptz", "timestamp with time zone":
		return "timestamptz"
	case "time", "time without time zone":
		return "time"
	case "timetz", "time with time zone":
		return "timetz"
	case "text", "bytea", "json", "jsonb", "uuid", "date", "interval":
		return name
	}
	return ""
}

func parsePgCatalogLiteral(expression, baseType string) (pgCatalogLiteral, bool) {
	baseType = pgCatalogBaseType(baseType)
	if baseType == "" || len(expression) == 0 || len(expression) > 64<<20 || !utf8.ValidString(expression) || strings.ContainsRune(expression, 0) {
		return pgCatalogLiteral{}, false
	}
	s := strings.TrimSpace(expression)
	if pgCatalogNumber.MatchString(s) {
		switch baseType {
		case "int2", "int4", "int8", "numeric", "float4", "float8":
			return pgCatalogLiteral{input: &s}, true
		}
		return pgCatalogLiteral{}, false
	}
	if s == "true" || s == "false" {
		return pgCatalogLiteral{input: &s}, baseType == "bool"
	}
	var value *string
	var suffix string
	inputType := baseType
	if s == "NULL" || strings.HasPrefix(s, "NULL::") {
		suffix = s[4:]
	} else {
		decoded, rest, ok := pgCatalogQuoted(s)
		if !ok {
			return pgCatalogLiteral{}, false
		}
		value, suffix = &decoded, rest
	}
	suffix = strings.TrimSpace(suffix)
	if suffix != "" {
		if !strings.HasPrefix(suffix, "::") {
			return pgCatalogLiteral{}, false
		}
		annotated := strings.TrimSpace(suffix[2:])
		annotated = strings.TrimPrefix(annotated, "pg_catalog.")
		// PostgreSQL renders small negative numeric defaults as integer
		// constants. Preserve their original range check before the built-in
		// lossless widening; never accept a general cast or its SQL text.
		inputType = pgCatalogBaseType(annotated)
		numericWidening := baseType == "numeric" && (inputType == "int2" || inputType == "int4" || inputType == "int8")
		if inputType != baseType && !numericWidening {
			return pgCatalogLiteral{}, false
		}
	}
	return pgCatalogLiteral{input: value, inputType: inputType}, true
}

func pgCatalogQuoted(s string) (string, string, bool) {
	escaped := strings.HasPrefix(s, "E'") || strings.HasPrefix(s, "e'")
	start := 0
	if escaped {
		start = 1
	}
	if len(s) <= start || s[start] != '\'' {
		return "", "", false
	}
	var out strings.Builder
	for i := start + 1; i < len(s); i++ {
		c := s[i]
		if c == '\'' {
			if i+1 < len(s) && s[i+1] == '\'' {
				out.WriteByte('\'')
				i++
				continue
			}
			value := out.String()
			return value, s[i+1:], utf8.ValidString(value) && !strings.ContainsRune(value, 0)
		}
		if c != '\\' || !escaped {
			out.WriteByte(c)
			continue
		}
		i++
		if i == len(s) {
			return "", "", false
		}
		switch s[i] {
		case 'b':
			out.WriteByte('\b')
		case 'f':
			out.WriteByte('\f')
		case 'n':
			out.WriteByte('\n')
		case 'r':
			out.WriteByte('\r')
		case 't':
			out.WriteByte('\t')
		case 'u', 'U':
			digits := 4
			if s[i] == 'U' {
				digits = 8
			}
			if i+digits >= len(s) {
				return "", "", false
			}
			number, err := strconv.ParseUint(s[i+1:i+1+digits], 16, 32)
			if err != nil || number > utf8.MaxRune || !utf8.ValidRune(rune(number)) || number == 0 {
				return "", "", false
			}
			out.WriteRune(rune(number))
			i += digits
		case 'x':
			first := i + 1
			for i+1 < len(s) && i+1-first < 2 && pgHexDigit(s[i+1]) {
				i++
			}
			if first > i {
				return "", "", false
			}
			number, err := strconv.ParseUint(s[first:i+1], 16, 8)
			if err != nil {
				return "", "", false
			}
			out.WriteByte(byte(number))
		case '0', '1', '2', '3', '4', '5', '6', '7':
			first := i
			for i+1 < len(s) && i+1-first < 3 && s[i+1] >= '0' && s[i+1] <= '7' {
				i++
			}
			number, err := strconv.ParseUint(s[first:i+1], 8, 8)
			if err != nil {
				return "", "", false
			}
			out.WriteByte(byte(number))
		default:
			out.WriteByte(s[i])
		}
	}
	return "", "", false
}

func pgHexDigit(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'
}
