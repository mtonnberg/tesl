package tooling

import (
	"strings"
	"testing"
)

func TestSearchSchemaRejectsMissingRequirements(t *testing.T) {
	valid := `{"version":1,"catalog_id":"id","scope":"builtins","query":"nowMillis","mode":"text","error":null,"total":1,"limit":20,"results":[{"id":"id","name":"nowMillis","module":"Tesl.Time","kind":"value","signature":"nowMillis : PosixMillis requires [time]","doc":"Clock","import":null,"structural_status":"checker-scheme","requirements":{"capabilities":["time"],"capabilities_status":"known-direct","proofs_status":"unavailable","additional_requirements_status":"unavailable"}}]}`
	if err := ValidateCompilerJSON("--search-json", []byte(valid)); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{
		strings.Replace(valid, `"version":1`, `"version":2`, 1),
		strings.Replace(valid, `"requirements":`, `"missing_requirements":`, 1),
		strings.Replace(valid, `"proofs_status":"unavailable"`, `"proofs_status":"none"`, 1),
		strings.Replace(valid, `"capabilities":["time"]`, `"capabilities":[42]`, 1),
		strings.Replace(valid, `"total":1`, `"total":0`, 1),
		strings.Replace(valid, `"error":null`, `"error":true`, 1),
	} {
		if err := ValidateCompilerJSON("--search-json", []byte(bad)); err == nil {
			t.Fatalf("accepted invalid search response: %s", bad)
		}
	}
}
