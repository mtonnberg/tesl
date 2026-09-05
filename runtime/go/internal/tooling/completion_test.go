package tooling

import (
	"encoding/json"
	"testing"
)

func TestCompletionMetadataValidation(t *testing.T) {
	for _, test := range []struct {
		name  string
		field string
		value any
		valid bool
	}{
		{"legacy fields only", "", nil, true},
		{"null module", "module", nil, true},
		{"ambient module", "module", "", true},
		{"module name", "module", "Tesl.String", true},
		{"module wrong type", "module", 1, false},
		{"documentation", "documentation", "Description", true},
		{"null documentation", "documentation", nil, true},
		{"invalid documentation", "documentation", []string{}, false},
		{"import boolean", "requires_import", true, true},
		{"import string", "requires_import", "true", false},
		{"null import flag", "requires_import", nil, false},
		{"null edit", "text_edit", nil, true},
		{"invalid edit", "text_edit", map[string]any{"kind": "unknown"}, false},
		{"empty import edit", "import_edit", map[string]any{}, false},
		{"sort text", "sort_text", "2:String.length", true},
		{"invalid sort text", "sort_text", true, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			item := map[string]any{"label": "String.length", "detail": "String -> Int", "kind": "function"}
			if test.field != "" {
				item[test.field] = test.value
			}
			payload, err := json.Marshal(map[string]any{"version": 1, "completions": []any{item}})
			if err != nil {
				t.Fatal(err)
			}
			err = ValidateCompilerJSON("--completions-json", payload)
			if (err == nil) != test.valid {
				t.Fatalf("validation error=%v, want valid=%v", err, test.valid)
			}
		})
	}
}
