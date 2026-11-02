package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"testing"
)

func migrationGuideReport(t *testing.T) migrationWizardReport {
	t.Helper()
	var report migrationWizardReport
	if err := json.Unmarshal([]byte(`{
 "decisions":[{"id":"entity:Note","entity":"Note","file":"/p/v2.tesl","line":4,"col":3,"reason":"Note.title: no additive value source","options":[{"id":"additive-default","label":"Use a literal String default","template":"Additive [Default title (todo \"Choose a String literal\")]","help":"A compiler-checked primitive default route.","needsCustomCode":true}]}],
 "diagnostics":{"diagnostics":[
  {"file":"/p/v2.tesl","code":"MIG003","severity":"error","start":{"line":4,"col":3},"message":"unresolved migration decision: Note.title: no additive value source"},
  {"file":"/p/v2.tesl","code":"MIG024","severity":"error","start":{"line":8,"col":2},"message":"Same differs in private validator"}
 ]}}`), &report); err != nil {
		t.Fatal(err)
	}
	return report
}

func TestMigrationWizardReviewBrowsesAndExpandsWithoutApplyingChoices(t *testing.T) {
	app, calls := fakeApp(t)
	app.Stdin = strings.NewReader("?\nn\n?\n1\nq\n")
	proceed, err := app.migrationWizardReview(context.Background(), migrationGuideReport(t), "Save your decision")
	if err != nil || proceed || len(*calls) != 0 {
		t.Fatalf("browse/help executed or approved a choice: %v %v %+v", proceed, err, *calls)
	}
	output := app.Stdout.(*bytes.Buffer).String()
	for _, required := range []string{"Item 1/2", "Item 2/2", "Compiler-proposed scaffolds", "Use a literal String default", `Additive [Default title (todo "Choose a String literal")]`, "Same requires an equal complete semantic closure", "does not replace changed historical evidence", "Guidance without a compiler-proposed option cannot update source", "--resume"} {
		if !strings.Contains(output, required) {
			t.Errorf("missing %q in:\n%s", required, output)
		}
	}
	if strings.Contains(output, "Compute the value from each old row") {
		t.Fatal("consumer-derived choice replaced the compiler's explicit option list")
	}
}

func TestMigrationWizardReviewCannotApplyChoiceWithoutRetainedPreview(t *testing.T) {
	app, calls := fakeApp(t)
	app.Stdin = strings.NewReader("1\n")
	proceed, err := app.migrationWizardReview(context.Background(), migrationGuideReport(t), "Choose")
	if proceed || err == nil || !strings.Contains(err.Error(), "fresh guarded preview") || len(*calls) != 0 {
		t.Fatalf("unbound metadata authorized an edit: %v %v %+v", proceed, err, *calls)
	}
}

func TestMigrationWizardReviewRequiresSavedRecheckAndHandlesEOF(t *testing.T) {
	app, calls := fakeApp(t)
	app.Stdin = strings.NewReader("n\n\n")
	proceed, err := app.migrationWizardReview(context.Background(), migrationGuideReport(t), "Save your decision")
	if err != nil || !proceed || len(*calls) != 0 {
		t.Fatalf("Enter should return to the guarded regeneration loop: %v %v", proceed, err)
	}
	app.Stdin = strings.NewReader("")
	if proceed, err := app.migrationWizardReview(context.Background(), migrationGuideReport(t), "Save"); proceed || !errors.Is(err, io.EOF) {
		t.Fatalf("EOF approved a decision: %v %v", proceed, err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	app.Stdin = migrationNeverRead{t}
	if proceed, err := app.migrationWizardReview(ctx, migrationGuideReport(t), "Save"); proceed || !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled decision read: %v %v", proceed, err)
	}
}

func TestMigrationWizardReviewKeepsLongCompilerDetailsExpandable(t *testing.T) {
	report := migrationGuideReport(t)
	report.Diagnostics.Diagnostics = report.Diagnostics.Diagnostics[:1]
	message := "unresolved migration decision: " + strings.Repeat("detailed reason 🙂 ", 40) + "COMPILER_DETAIL_END"
	help := strings.Repeat("option-specific explanation ", 30) + "OPTION_DETAIL_END"
	report.Diagnostics.Diagnostics[0].Message = message
	report.Decisions[0].Options[0].Help = help
	for _, expanded := range []bool{false, true} {
		app, _ := fakeApp(t)
		input := "q\n"
		if expanded {
			input = "?\nq\n"
		}
		app.Stdin = strings.NewReader(input)
		if proceed, err := app.migrationWizardReview(context.Background(), report, "Save"); proceed || err != nil {
			t.Fatalf("review: %v %v", proceed, err)
		}
		output := app.Stdout.(*bytes.Buffer).String()
		if strings.Contains(output, message) != expanded || strings.Contains(output, help) != expanded {
			t.Fatalf("full diagnostic and option explanation should require expanded help (expanded=%v):\n%s", expanded, output)
		}
		if !strings.Contains(output, "MIG003") || !strings.Contains(output, "Use a literal String default") {
			t.Fatal("compact review lost its diagnostic identity or option label")
		}
	}
}
