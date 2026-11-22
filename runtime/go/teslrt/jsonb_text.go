package teslrt

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// JsonbText is the text PostgreSQL gives back for a `jsonb` column: what `value::jsonb::text`
// returns. A `String @db(jsonb)` column round-trips through that form on PostgreSQL, so the
// memory store stores the same form — otherwise a test comparing the text passes in memory and
// fails against the real database. PostgreSQL's rules:
//
//   - whitespace between tokens is dropped, then `": "` follows a key and `", "` separates
//     members and elements;
//   - object keys are ordered by byte length, then by bytes, and a repeated key keeps its
//     last value;
//   - a string is re-escaped: `"`, `\` and the control characters are escaped (`\b \f \n \r
//     \t`, the rest as `\u00XX`), everything else — `/` and non-ASCII included — is written
//     as itself;
//   - a number is a NUMERIC: the exponent is folded into the digits (`1e2` is `100`, `1.5e1`
//     is `15`), the decimal scale written is kept (`1.50` stays `1.50`), and there is no
//     negative zero.
//
// Text that is not JSON, or that holds `\u0000` (which jsonb refuses), panics — PostgreSQL
// rejects the same write.
func JsonbText(text string) string {
	decoder := json.NewDecoder(strings.NewReader(text))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		panic(fmt.Sprintf("invalid input syntax for type json: %v", err))
	}
	if _, err := decoder.Token(); err != io.EOF {
		panic("invalid input syntax for type json: trailing data after the value")
	}
	if !utf8.ValidString(text) {
		panic("invalid input syntax for type json: text is not valid UTF-8")
	}
	var out bytes.Buffer
	writeJsonbValue(&out, value)
	return out.String()
}

func writeJsonbValue(out *bytes.Buffer, value any) {
	switch typed := value.(type) {
	case nil:
		out.WriteString("null")
	case bool:
		if typed {
			out.WriteString("true")
		} else {
			out.WriteString("false")
		}
	case json.Number:
		out.WriteString(jsonbNumber(string(typed)))
	case string:
		writeJsonbString(out, typed)
	case []any:
		out.WriteByte('[')
		for index, element := range typed {
			if index > 0 {
				out.WriteString(", ")
			}
			writeJsonbValue(out, element)
		}
		out.WriteByte(']')
	case map[string]any:
		// encoding/json keeps the LAST of a repeated key, which is PostgreSQL's rule too.
		keys := make([]string, 0, len(typed))
		for key := range typed {
			keys = append(keys, key)
		}
		sort.Slice(keys, func(i, j int) bool {
			if len(keys[i]) != len(keys[j]) {
				return len(keys[i]) < len(keys[j])
			}
			return keys[i] < keys[j]
		})
		out.WriteByte('{')
		for index, key := range keys {
			if index > 0 {
				out.WriteString(", ")
			}
			writeJsonbString(out, key)
			out.WriteString(": ")
			writeJsonbValue(out, typed[key])
		}
		out.WriteByte('}')
	default:
		panic(fmt.Sprintf("JsonbText: unexpected decoded value %T", value))
	}
}

func writeJsonbString(out *bytes.Buffer, text string) {
	out.WriteByte('"')
	for _, character := range text {
		switch character {
		case 0:
			panic("unsupported Unicode escape sequence: \\u0000 cannot be converted to text")
		case '"':
			out.WriteString(`\"`)
		case '\\':
			out.WriteString(`\\`)
		case '\b':
			out.WriteString(`\b`)
		case '\f':
			out.WriteString(`\f`)
		case '\n':
			out.WriteString(`\n`)
		case '\r':
			out.WriteString(`\r`)
		case '\t':
			out.WriteString(`\t`)
		default:
			if character < 0x20 {
				fmt.Fprintf(out, `\u%04x`, character)
			} else {
				out.WriteRune(character)
			}
		}
	}
	out.WriteByte('"')
}

// jsonbNumber renders a JSON number the way PostgreSQL's NUMERIC prints it.
func jsonbNumber(text string) string {
	negative := strings.HasPrefix(text, "-")
	text = strings.TrimPrefix(text, "-")
	exponent := 0
	if cut := strings.IndexAny(text, "eE"); cut >= 0 {
		// encoding/json has already validated the number, so the exponent parses.
		exponent, _ = strconv.Atoi(strings.TrimPrefix(text[cut+1:], "+"))
		text = text[:cut]
	}
	integer, fraction, _ := strings.Cut(text, ".")
	digits := integer + fraction
	// value = digits × 10^(exponent - len(fraction)); the printed scale is never negative.
	shift := exponent - len(fraction)
	scale := 0
	if shift < 0 {
		scale = -shift
	} else {
		digits += strings.Repeat("0", shift)
	}
	if len(digits) <= scale {
		digits = strings.Repeat("0", scale-len(digits)+1) + digits
	}
	whole := strings.TrimLeft(digits[:len(digits)-scale], "0")
	if whole == "" {
		whole = "0"
	}
	rendered := whole
	if scale > 0 {
		rendered += "." + digits[len(digits)-scale:]
	}
	if negative && strings.Trim(rendered, "0.") != "" {
		rendered = "-" + rendered
	}
	return rendered
}
