package teslrt

import (
	"encoding/hex"
	"encoding/json"
	"slices"
	"strings"
	"testing"
)

func TestDerivedCanonicalMode(t *testing.T) {
	history := compiledRowHistories["Schema.Notes"].history
	if _, err := pgReadRowCompanion(history, teslGeneratedRowHistoryJSON); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name, want string
		change     func(map[string]any, *pgRowCanonical)
	}{
		{"descriptor-mode", "semantic mode", func(d map[string]any, n *pgRowCanonical) { d["mode"] = "migrate" }},
		{"empty-mode", "semantic mode", func(d map[string]any, n *pgRowCanonical) { n.children[6] = pgRowList() }},
		{"fake-callback", "semantic mode", func(d map[string]any, n *pgRowCanonical) {
			n.children[6] = pgRowList(pgRowAtom("derived"), pgRowAtom("fake-callback"))
		}},
		{"computed-source", "cannot compute", func(d map[string]any, n *pgRowCanonical) {
			for _, raw := range d["fieldMapping"].([]any) {
				m := raw.(map[string]any)
				if m["target"] == "count" {
					m["kind"] = "computed"
					m["constant"] = nil
				}
			}
			for i, raw := range n.children[4].children {
				if raw.children[0].isAtom("default") && raw.children[1].isAtom("count") {
					n.children[4].children[i] = pgRowList(pgRowAtom("computed"), pgRowAtom("count"))
				}
			}
			slices.SortFunc(n.children[4].children, func(a, b pgRowCanonical) int { return strings.Compare(pgRowEncode(a), pgRowEncode(b)) })
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var envelope map[string]any
			if err := json.Unmarshal([]byte(teslGeneratedRowHistoryJSON), &envelope); err != nil {
				t.Fatal(err)
			}
			d := envelope["databases"].([]any)[0].(map[string]any)["transforms"].([]any)[0].(map[string]any)
			document, _, err := pgReadRowCanonical(d["transformContract"].(string))
			if err != nil {
				t.Fatal(err)
			}
			row := &document.children[3].children[3].children[0]
			tc.change(d, row)
			raw, hash := pgRowBaselineDocument(document.children[3])
			d["transformContract"], d["transformContractHash"] = hex.EncodeToString([]byte(raw)), hash
			payload, err := json.Marshal(envelope)
			if err != nil {
				t.Fatal(err)
			}
			_, err = pgReadRowCompanion(history, string(payload))
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatal("freshly rehashed malformed Derived accepted or wrong refusal", err)
			}
		})
	}
}
