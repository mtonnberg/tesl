package teslrt

import (
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
)

func TestDerivedLegacyCanonicalMode(t *testing.T) {
	history := compiledRowHistories["Schema.Notes"].history
	inventory, err := pgReadRowCompanion(history, teslGeneratedRowHistoryJSON)
	if err != nil || len(inventory[0].Transforms[0].LegacyWrites) != 2 {
		t.Fatal("Derived legacy inventory", err)
	}
	for _, extra := range []bool{false, true} {
		t.Run(map[bool]string{false: "missing-reverse", true: "extra-reverse"}[extra], func(t *testing.T) {
			var envelope map[string]any
			if err := json.Unmarshal([]byte(teslGeneratedRowHistoryJSON), &envelope); err != nil {
				t.Fatal(err)
			}
			d := envelope["databases"].([]any)[0].(map[string]any)["transforms"].([]any)[0].(map[string]any)
			document, _, err := pgReadRowCanonical(d["transformContract"].(string))
			if err != nil {
				t.Fatal(err)
			}
			mode := &document.children[3].children[3].children[0].children[6]
			if !mode.list(2) || !mode.children[0].isAtom("derived") || len(mode.children[1].children) != 2 {
				t.Fatal("expected Derived width2 with exact two reverse closures")
			}
			writes := &mode.children[1]
			if extra {
				writes.children = append(writes.children, writes.children[0])
			} else {
				writes.children = writes.children[:1]
			}
			raw, hash := pgRowBaselineDocument(document.children[3])
			d["transformContract"], d["transformContractHash"] = hex.EncodeToString([]byte(raw)), hash
			payload, err := json.Marshal(envelope)
			if err != nil {
				t.Fatal(err)
			}
			_, err = pgReadRowCompanion(history, string(payload))
			if err == nil || !strings.Contains(err.Error(), "semantic closure inventory mismatch") {
				t.Fatal("freshly rehashed reverse inventory accepted or wrong refusal", err)
			}
		})
	}
}
