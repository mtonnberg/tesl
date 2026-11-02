package migrationguide

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestChangedProofGuideNeverOffersRevalidateAsReplacement(t *testing.T) {
	guide := ForDiagnostic("MIG003", "Note: stored proof contract changed for Note.title")
	if len(guide.Options) != 1 || guide.Options[0].ID != "retype-proof" || !strings.Contains(guide.Options[0].Example, "WriteBack") {
		t.Fatalf("changed proof options: %+v", guide.Options)
	}
	help := strings.Join(guide.Help, "\n")
	for _, required := range []string{"does not replace changed historical evidence", "exact historical field type and proof", "unrelated old update", "Cross-field entity predicates are unsupported"} {
		if !strings.Contains(help, required) {
			t.Errorf("missing compatibility boundary %q", required)
		}
	}
}

func TestCurrentAndFrozenHashHelpHaveDifferentRecovery(t *testing.T) {
	draft := ForDiagnostic("MIG001", "changed current hash")
	frozen := ForDiagnostic("MIG013", "changed source")
	if !strings.Contains(draft.Summary, "has not been deployed") || len(frozen.Options) != 0 || !strings.Contains(frozen.Summary, "Preserve the recorded bytes") {
		t.Fatalf("draft/frozen recovery conflated: %+v %+v", draft, frozen)
	}
}

func TestCompilerDecisionOptionsReplaceTextHeuristics(t *testing.T) {
	var decision Decision
	if err := json.Unmarshal([]byte(`{"id":"entity:Note","entity":"Note","file":"/p/v2.tesl","line":20,"col":12,"reason":"Note.title: no additive value source","options":[{"id":"additive-default","label":"Use a checked default route","template":"Additive [Default title (todo \"Choose a String literal\")]","help":"A String literal is required.","needsCustomCode":true}]}`), &decision); err != nil {
		t.Fatal(err)
	}
	guide := ForDecision(decision)
	if len(guide.Options) != 1 || guide.Options[0].ID != "additive-default" || guide.Options[0].Example != decision.Options[0].Template || !guide.Options[0].RequiresCustomCode {
		t.Fatalf("compiler options were replaced with guesses: %+v", guide)
	}
	if !strings.Contains(strings.Join(guide.Help, "\n"), "Custom-code holes remain blocking") {
		t.Fatal("template was presented as a completed migration")
	}
}

func TestUnrecognizedDiagnosticDoesNotInventAnEdit(t *testing.T) {
	guide := ForDiagnostic("MIG999", "unknown future diagnostic")
	if len(guide.Options) != 0 || !strings.Contains(strings.Join(guide.Help, "\n"), "Examples alone do not change source") {
		t.Fatalf("unknown diagnostic received a speculative edit: %+v", guide)
	}
}

func TestCompilerRefusalToProposeOptionsDoesNotFallBackToGuesses(t *testing.T) {
	guide := ForDecision(Decision{Entity: "Note", Reason: "Note.title: no additive value source", Options: []DecisionOption{}})
	if len(guide.Options) != 0 || !strings.Contains(guide.Summary, "has not proposed a source template") {
		t.Fatalf("explicit compiler option boundary lost: %+v", guide)
	}
}

func TestSelectedDefaultHoleDoesNotAskForAnotherMigrationDecision(t *testing.T) {
	guide := ForDiagnostic("MIG003", "unresolved migration decision: Choose a literal of type String for Note.title")
	if len(guide.Options) != 0 || !strings.Contains(guide.Summary, "scaffold is written") {
		t.Fatalf("selected literal hole was turned back into a migration-route choice: %+v", guide)
	}
}
