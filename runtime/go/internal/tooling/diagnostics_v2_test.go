package tooling

import (
	"encoding/json"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func richDiagnosticFixture() map[string]any {
	return map[string]any{"file": "/tmp/app.tesl", "start": map[string]int{"line": 0, "col": 0}, "end": map[string]int{"line": 0, "col": 1},
		"severity": "error", "code": "MIG003", "message": "a decision", "source": "migration", "fix": nil,
		"relatedInformation": []any{}, "actionClass": "decision", "needsConfirmation": true, "fixAllEligible": false,
		"command": nil, "codeDescription": map[string]any{"href": "https://github.com/mtonnberg/tesl/blob/main/manual/best-practices.md#database-access"}}
}

func richDiagnosticJSON(t *testing.T, diagnostic map[string]any) []byte {
	t.Helper()
	data, err := json.Marshal(map[string]any{"version": 2, "diagnostics": []any{diagnostic}})
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestRichDiagnosticMetadataValidation(t *testing.T) {
	valid := richDiagnosticJSON(t, richDiagnosticFixture())
	if err := ValidateCompilerJSON("--check-json-v2", valid); err != nil {
		t.Fatal(err)
	}
	if err := ValidateCompilerJSON("--check-json", valid); err == nil {
		t.Fatal("legacy endpoint accepted protocol 2")
	}
	if err := ValidateCompilerJSON("--check-json-v2", []byte(`{"version":1,"diagnostics":[]}`)); err == nil {
		t.Fatal("rich endpoint silently accepted legacy diagnostics")
	}
	for _, field := range []string{"relatedInformation", "actionClass", "needsConfirmation", "fixAllEligible", "command", "codeDescription"} {
		t.Run("missing "+field, func(t *testing.T) {
			d := richDiagnosticFixture()
			delete(d, field)
			if err := ValidateCompilerJSON("--check-json-v2", richDiagnosticJSON(t, d)); err == nil {
				t.Fatal("missing metadata accepted")
			}
		})
	}
	for _, test := range []struct {
		name string
		edit func(map[string]any)
	}{
		{"null related array", func(d map[string]any) { d["relatedInformation"] = nil }},
		{"missing related fields", func(d map[string]any) { d["relatedInformation"] = []any{map[string]any{"file": "old.tesl"}} }},
		{"inverted related range", func(d map[string]any) {
			d["relatedInformation"] = []any{map[string]any{"file": "old.tesl", "message": "old", "start": map[string]int{"line": 1, "col": 1}, "end": map[string]int{"line": 1, "col": 0}}}
		}},
		{"unknown class", func(d map[string]any) { d["actionClass"] = "safe" }},
		{"object class", func(d map[string]any) { d["actionClass"] = map[string]any{} }},
		{"array class", func(d map[string]any) { d["actionClass"] = []any{} }},
		{"unconfirmed decision", func(d map[string]any) { d["needsConfirmation"] = false }},
		{"unknown action requests confirmation", func(d map[string]any) { d["actionClass"] = nil }},
		{"decision in fix-all", func(d map[string]any) { d["fixAllEligible"] = true }},
		{"eligibility not boolean", func(d map[string]any) { d["fixAllEligible"] = "false" }},
		{"confirmation not boolean", func(d map[string]any) { d["needsConfirmation"] = 0 }},
		{"fix-all lacks source edit", func(d map[string]any) {
			d["actionClass"], d["needsConfirmation"], d["fixAllEligible"] = "mechanical", false, true
		}},
		{"executable documentation", func(d map[string]any) {
			d["codeDescription"] = map[string]any{"href": "command:workbench.action.terminal.new"}
		}},
		{"documentation user info", func(d map[string]any) { d["codeDescription"] = map[string]any{"href": "https://user@example.com"} }},
		{"documentation missing link", func(d map[string]any) { d["codeDescription"] = map[string]any{} }},
		{"command shape", func(d map[string]any) { d["command"] = "tesl.generateMigration" }},
	} {
		t.Run(test.name, func(t *testing.T) {
			d := richDiagnosticFixture()
			test.edit(d)
			if err := ValidateCompilerJSON("--check-json-v2", richDiagnosticJSON(t, d)); err == nil {
				t.Fatal("invalid metadata accepted")
			}
		})
	}
}

func TestRichDiagnosticCommandsRequireAnExplicitSelection(t *testing.T) {
	entry := filepath.Join(t.TempDir(), "app.tesl")
	command := func() map[string]any {
		return map[string]any{"title": "Change schema", "command": "tesl.generateMigration", "arguments": []any{map[string]any{"entryFile": entry, "database": "App.Main"}}}
	}
	d := richDiagnosticFixture()
	d["actionClass"], d["needsConfirmation"], d["command"] = "mechanical", false, command()
	if err := ValidateCompilerJSON("--check-json-v2", richDiagnosticJSON(t, d)); err != nil {
		t.Fatal(err)
	}
	for _, edit := range []func(map[string]any){
		func(c map[string]any) { c["command"] = "workbench.action.terminal.sendSequence" },
		func(c map[string]any) { delete(c, "title") },
		func(c map[string]any) { c["arguments"] = []any{} },
		func(c map[string]any) { c["arguments"] = []any{map[string]any{"entryFile": "relative.tesl"}} },
		func(c map[string]any) { c["arguments"] = []any{map[string]any{"entryFile": entry, "database": ""}} },
		func(c map[string]any) { c["arguments"] = []any{map[string]any{"entryFile": entry, "shell": "bad"}} },
	} {
		c := command()
		edit(c)
		d["command"] = c
		if err := ValidateCompilerJSON("--check-json-v2", richDiagnosticJSON(t, d)); err == nil {
			t.Fatalf("invalid command accepted: %+v", c)
		}
	}
	d["command"], d["fixAllEligible"] = command(), true
	d["fix"] = map[string]any{"kind": "replace_line", "line": 0, "replacement": "fixed", "title": "Fix"}
	if err := ValidateCompilerJSON("--check-json-v2", richDiagnosticJSON(t, d)); err == nil {
		t.Fatal("multi-file command entered fix-all")
	}
	d["command"] = nil
	if err := ValidateCompilerJSON("--check-json-v2", richDiagnosticJSON(t, d)); err != nil {
		t.Fatal(err)
	}
}

func TestRichDiagnosticWireRejectsAmbiguity(t *testing.T) {
	valid := string(richDiagnosticJSON(t, richDiagnosticFixture()))
	for _, bad := range ambiguousRichDiagnostics(valid) {
		if err := ValidateCompilerJSON("--check-json-v2", []byte(bad)); err == nil {
			t.Fatalf("ambiguous wire response accepted: %s", bad)
		}
	}
}

func ambiguousRichDiagnostics(valid string) []string {
	return []string{
		strings.Replace(valid, `"version":2`, `"version":1,"version":2`, 1),
		strings.Replace(valid, `"version":2`, `"version":2,"Version":1`, 1),
		strings.Replace(valid, `"actionClass":"decision"`, `"actionClass":"mechanical","actionClass":"decision"`, 1),
		strings.Replace(valid, `"actionClass":"decision"`, `"actionClass":"decision","ActionClass":"mechanical"`, 1),
		strings.Replace(valid, `"needsConfirmation":true`, `"needsConfirmation":false,"needsConfirmation":true`, 1),
		strings.Replace(valid, `"needsConfirmation":true`, `"needs\u0043onfirmation":false,"needsConfirmation":true`, 1),
		strings.Replace(valid, `"needsConfirmation":true`, `"needsConfirmation":true,"NeedsConfirmation":false`, 1),
		strings.Replace(valid, `"needsConfirmation":true`, `"needsConfirmation":true,"needſConfirmation":false`, 1),
		strings.Replace(valid, `"needsConfirmation":true`, `"needsConfirmation":true,"need\u017fConfirmation":false`, 1),
		strings.Replace(valid, `"relatedInformation":[]`, `"relatedInformation":[{"file":"/tmp/old.tesl","File":"/tmp/other.tesl","message":"old","start":{"line":0,"col":0},"end":{"line":0,"col":0}}]`, 1),
		strings.Replace(valid, `"relatedInformation":[]`, `"relatedInformation":[{"file":"/tmp/old.tesl","message":"old","start":{"line":0,"col":0,"COL":1},"end":{"line":0,"col":0}}]`, 1),
		strings.Replace(valid, `"version":2`, `"version":2,"K":0,"\u212a":1`, 1),
		valid + `{}`, strings.Replace(valid, "a decision", string([]byte{0xff}), 1),
		`{"version":2,"diagnostics":[],"extra":` + strings.Repeat("[", 70) + "0" + strings.Repeat("]", 70) + "}",
	}
}

func TestRichDiagnosticShadowPaths(t *testing.T) {
	shadow, root := t.TempDir(), t.TempDir()
	data, err := json.Marshal(map[string]any{"relatedInformation": []any{map[string]any{"file": filepath.Join(shadow, "old.tesl")}},
		"command": map[string]any{"arguments": []any{map[string]any{"entryFile": filepath.Join(shadow, "app.tesl")}}}})
	if err != nil {
		t.Fatal(err)
	}
	mapped, err := mapShadowFilePaths(data, shadow, root)
	if err != nil {
		t.Fatal(err)
	}
	var actual struct {
		RelatedInformation []struct{ File string }
		Command            struct{ Arguments []struct{ EntryFile string } }
	}
	if err := json.Unmarshal(mapped, &actual); err != nil {
		t.Fatal(err)
	}
	if len(actual.RelatedInformation) != 1 || actual.RelatedInformation[0].File != filepath.Join(root, "old.tesl") ||
		len(actual.Command.Arguments) != 1 || actual.Command.Arguments[0].EntryFile != filepath.Join(root, "app.tesl") {
		t.Fatalf("diagnostic selections or related files kept a private mirror path: %s", mapped)
	}
}

func FuzzRichDiagnosticEnvelope(f *testing.F) {
	valid, err := json.Marshal(map[string]any{"version": 2, "diagnostics": []any{richDiagnosticFixture()}})
	if err != nil {
		f.Fatal(err)
	}
	f.Add(valid)
	f.Add([]byte(`{"version":2,"diagnostics":[]}`))
	f.Add([]byte(`{"version":2,"version":1}`))
	for _, bad := range ambiguousRichDiagnostics(string(valid)) {
		f.Add([]byte(bad))
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 1<<20 {
			t.Skip("compiler process output is separately bounded")
		}
		if err := ValidateCompilerJSON("--check-json-v2", data); err != nil {
			return
		}
		// Exercise the interpretation boundary, not merely the absence of a
		// validator panic. Go's struct decoder must preserve the exact-key
		// action fields that the validator approved.
		type action struct {
			ActionClass       *string `json:"actionClass"`
			NeedsConfirmation bool    `json:"needsConfirmation"`
			FixAllEligible    bool    `json:"fixAllEligible"`
		}
		var decoded struct {
			Version     int      `json:"version"`
			Diagnostics []action `json:"diagnostics"`
		}
		var exact map[string]json.RawMessage
		if err := json.Unmarshal(data, &decoded); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(data, &exact); err != nil {
			t.Fatal(err)
		}
		var exactDiagnostics []map[string]json.RawMessage
		if err := json.Unmarshal(exact["diagnostics"], &exactDiagnostics); err != nil {
			t.Fatal(err)
		}
		if decoded.Version != 2 || len(decoded.Diagnostics) != len(exactDiagnostics) {
			t.Fatal("validated envelope changed during struct decoding")
		}
		for i, fields := range exactDiagnostics {
			var want action
			for name, target := range map[string]any{
				"actionClass": &want.ActionClass, "needsConfirmation": &want.NeedsConfirmation, "fixAllEligible": &want.FixAllEligible,
			} {
				if err := json.Unmarshal(fields[name], target); err != nil {
					t.Fatal(err)
				}
			}
			if !reflect.DeepEqual(decoded.Diagnostics[i], want) {
				t.Fatal("validated action changed during struct decoding")
			}
		}
	})
}
