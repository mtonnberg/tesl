package migrationtest

import (
	"fmt"
	"regexp"
	"strings"
	"testing"
)

type fixtureStep struct {
	Kind, Name, Text string
}

var fixtureStepMarker = regexp.MustCompile(`^-- \[(sql|zero|hook) ([a-z][a-z0-9-]*)\]$`)

// This is a labelled fixture reader, not a SQL parser or production executor.
// Hooks are separate executable callbacks; SQL text is sent unchanged to PostgreSQL.
func readFixtureSteps(source string) ([]fixtureStep, error) {
	if !strings.HasPrefix(source, "-- [normative-template] ") {
		return nil, fmt.Errorf("fixture has no normative class")
	}
	var steps []fixtureStep
	seen := map[string]bool{}
	for line, text := range strings.Split(source, "\n") {
		trimmed := strings.TrimSpace(text)
		match := fixtureStepMarker.FindStringSubmatch(trimmed)
		if match != nil {
			if seen[match[2]] {
				return nil, fmt.Errorf("line %d: duplicate fixture step %s", line+1, match[2])
			}
			seen[match[2]] = true
			steps = append(steps, fixtureStep{Kind: match[1], Name: match[2]})
		} else if line != 0 && strings.HasPrefix(trimmed, "-- [") {
			return nil, fmt.Errorf("line %d: unrecognised fixture step marker", line+1)
		} else if len(steps) > 0 {
			last := &steps[len(steps)-1]
			last.Text += text + "\n"
		} else if trimmed != "" && !strings.HasPrefix(trimmed, "--") {
			return nil, fmt.Errorf("line %d: unlabelled SQL", line+1)
		}
	}
	if len(steps) == 0 {
		return nil, fmt.Errorf("fixture has no executable steps")
	}
	for i := range steps {
		step := &steps[i]
		step.Text = strings.TrimSpace(step.Text)
		hasSQL := false
		for _, line := range strings.Split(step.Text, "\n") {
			trimmed := strings.TrimSpace(line)
			hasSQL = hasSQL || (trimmed != "" && !strings.HasPrefix(trimmed, "--"))
		}
		if (step.Kind == "hook") == hasSQL {
			return nil, fmt.Errorf("step %s must contain %s", step.Name, map[bool]string{true: "only hook comments", false: "executable SQL"}[step.Kind == "hook"])
		}
	}
	return steps, nil
}

func renderContractDocument(document, fixture string) (string, error) {
	const marker = "-- [normative-template] `contract V8` as the harness runs it; :binds supplied by the executor."
	if !strings.HasPrefix(fixture, marker+"\n") || strings.Contains(fixture, "```") {
		return "", fmt.Errorf("contract fixture has no recognised identity")
	}
	if _, err := readFixtureSteps(fixture); err != nil {
		return "", err
	}
	prefix := "```sql\n" + marker + "\n"
	if strings.Count(document, prefix) != 1 {
		return "", fmt.Errorf("document must contain one normative contract fence")
	}
	start := strings.Index(document, prefix) + len("```sql\n")
	end := strings.Index(document[start:], "\n```\n")
	if end < 0 {
		return "", fmt.Errorf("documented contract fence is incomplete")
	}
	return document[:start] + strings.TrimSuffix(fixture, "\n") + document[start+end:], nil
}

// INV-SQL-SOURCE, INV-HARNESS; TR-SQL-DOCUMENT, TR-SCHEDULE.
func TestFixtureStepsCannotSilentlySkipSQLOrHooks(t *testing.T) {
	const prefix = "-- [normative-template] test fixture\n"
	valid := prefix + "-- [sql begin]\nbegin;\n-- [hook batch]\n-- Work on another backend.\n-- [zero final]\nselect 0;\n-- [sql commit]\ncommit;\n"
	steps, err := readFixtureSteps(valid)
	if err != nil || len(steps) != 4 || steps[1].Kind != "hook" || steps[2].Text != "select 0;" {
		t.Fatalf("read fixture: %+v %v", steps, err)
	}
	for _, invalid := range []string{
		strings.TrimPrefix(valid, prefix), prefix, prefix + "select 1;\n",
		prefix + "-- [sql empty]\n-- No SQL.\n", prefix + "-- [zero empty]\n",
		prefix + "-- [hook hidden]\nselect 1;\n", prefix + "-- [unknown operation]\n",
		valid + "-- [sql begin]\nselect 1;\n", valid + "-- [sql]\nselect 1;\n",
	} {
		if _, err := readFixtureSteps(invalid); err == nil {
			t.Fatalf("invalid fixture accepted: %q", invalid)
		}
	}
}

// INV-SQL-SOURCE; TR-SQL-DOCUMENT.
func TestContractSQLDocumentRenderingPreservesOtherFences(t *testing.T) {
	const marker = "-- [normative-template] `contract V8` as the harness runs it; :binds supplied by the executor."
	fixture := marker + "\n-- [sql test]\nselect 1;\n"
	document := "Before\n```sql\n" + marker + "\nselect 0;\n```\nAfter\n```sql\n-- [illustrative]\nselect 2;\n```\n"
	updated, err := renderContractDocument(document, fixture)
	if err != nil || !strings.HasSuffix(updated, "\n```\nAfter\n```sql\n-- [illustrative]\nselect 2;\n```\n") || !strings.Contains(updated, "-- [sql test]\nselect 1;") {
		t.Fatalf("rendered contract changed surrounding content: %q %v", updated, err)
	}
	for _, invalid := range []string{"No contract", document + document, strings.ReplaceAll(document, "\n```\n", "\n")} {
		if _, err := renderContractDocument(invalid, fixture); err == nil {
			t.Fatalf("ambiguous contract accepted: %q", invalid)
		}
	}
}
