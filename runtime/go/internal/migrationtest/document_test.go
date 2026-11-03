package migrationtest

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func classifySQLFences(source string) (sqlCount, normative int, failures []string) {
	marker, width, start := byte(0), 0, 0
	inFence, wantClass := false, false
	for line, text := range strings.Split(source, "\n") {
		trimmed := strings.TrimSpace(text)
		fenceWidth := 0
		if len(trimmed) > 0 && (trimmed[0] == '`' || trimmed[0] == '~') {
			for fenceWidth < len(trimmed) && trimmed[fenceWidth] == trimmed[0] {
				fenceWidth++
			}
		}
		if inFence {
			if fenceWidth >= width && trimmed[0] == marker && strings.TrimSpace(trimmed[fenceWidth:]) == "" {
				if wantClass {
					failures = append(failures, fmt.Sprintf("line %d: empty SQL fence has no class", start))
				}
				inFence, wantClass = false, false
				continue
			}
			if wantClass {
				wantClass = false
				if strings.HasPrefix(trimmed, "-- [normative-template]") {
					normative++
				} else if !strings.HasPrefix(trimmed, "-- [illustrative]") && !strings.HasPrefix(trimmed, "-- [generated-snapshot]") {
					failures = append(failures, fmt.Sprintf("line %d: SQL fence has no recognised class", line+1))
				}
			}
			continue
		}
		if fenceWidth >= 3 {
			marker, width, start = trimmed[0], fenceWidth, line+1
			inFence = true
			language := strings.Fields(trimmed[fenceWidth:])
			wantClass = len(language) > 0 && strings.EqualFold(language[0], "sql")
			if wantClass {
				sqlCount++
			}
		}
	}
	if inFence {
		failures = append(failures, fmt.Sprintf("line %d: unterminated code fence", start))
	}
	return
}

// SQL examples are classified before they can become executable test inputs.
// An unclassified fence must never silently be mistaken for production DDL.
// INV-SQL-CLASS; TR-SQL-CLASSIFY.
func TestNormativeSQLFencesAreClassified(t *testing.T) {
	root := os.Getenv("TESL_REPO_ROOT")
	if root == "" {
		root = filepath.Join("..", "..", "..", "..")
	}
	sqlCount, normative := 0, 0
	for _, name := range []string{"database-migrations.md", "queue-payload-migrations.md", "staged-uniqueness-guard.md"} {
		source, err := os.ReadFile(filepath.Join(root, "roadmap", "next", name))
		if err != nil {
			t.Fatal(err)
		}
		count, templates, failures := classifySQLFences(string(source))
		sqlCount += count
		normative += templates
		for _, failure := range failures {
			t.Errorf("%s: %s", name, failure)
		}
	}
	if sqlCount == 0 || normative == 0 {
		t.Fatal("SQL inventory is empty")
	}
}

// INV-SQL-CLASS; TR-SQL-CLASSIFY.
func TestSQLFenceClassifierCannotSilentlySkipTemplates(t *testing.T) {
	for _, fence := range []string{"```sql", "``` sql", "~~~~SQL", "  ````sql"} {
		close := strings.Repeat(strings.TrimSpace(fence)[:1], 4)
		for _, class := range []string{"normative-template", "illustrative", "generated-snapshot"} {
			t.Run(fence+"/"+class, func(t *testing.T) {
				count, templates, failures := classifySQLFences(fence + "\n-- [" + class + "]\nselect 1;\n" + close)
				expected := 0
				if class == "normative-template" {
					expected = 1
				}
				if count != 1 || templates != expected || len(failures) != 0 {
					t.Fatalf("valid SQL fence misclassified: %d, %d, %v", count, templates, failures)
				}
			})
		}
	}
	for _, source := range []string{
		"```sql\nselect 1;\n```",
		"~~~sql\n~~~",
		"```sql\n-- [normative-template]\nselect 1;",
		"```sql\n\n-- [normative-template]\n```",
	} {
		if _, _, failures := classifySQLFences(source); len(failures) == 0 {
			t.Fatalf("unclassified or incomplete SQL was accepted: %q", source)
		}
	}
	count, templates, failures := classifySQLFences("````markdown\n```sql\nselect 1;\n```\n````")
	if count != 0 || templates != 0 || len(failures) != 0 {
		t.Fatalf("literal inner fence was treated as executable SQL: %d, %d, %v", count, templates, failures)
	}
}

// INV-SQL-SOURCE; TR-SQL-DOCUMENT.
func TestControlBootstrapDocumentMatchesExecutedFixture(t *testing.T) {
	root := os.Getenv("TESL_REPO_ROOT")
	if root == "" {
		root = filepath.Join("..", "..", "..", "..")
	}
	fixture, err := os.ReadFile(filepath.Join(root, "runtime", "go", "internal", "migrationtest", "testdata", "control-bootstrap.sql"))
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "roadmap", "next", "database-migrations.md")
	document, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	updated, err := renderControlBootstrapDocument(string(document), string(fixture))
	if err != nil {
		t.Fatal(err)
	}
	if os.Getenv("TESL_UPDATE_MIGRATION_SQL_DOCS") == "1" {
		if err := os.WriteFile(path, []byte(updated), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	if updated != string(document) {
		t.Fatal("documented control SQL differs from the executed fixture; run TESL_UPDATE_MIGRATION_SQL_DOCS=1 go test ./internal/migrationtest -run '^TestControlBootstrapDocumentMatchesExecutedFixture$' from runtime/go")
	}
}

func renderControlBootstrapDocument(document, fixture string) (string, error) {
	const marker = "-- [normative-template] the control schema"
	const boundary = "-- END GENERATED CONTROL BOOTSTRAP"
	if !strings.HasPrefix(fixture, marker) || !strings.HasSuffix(fixture, "\ncommit;\n") || strings.Count(fixture, "\ncommit;") != 1 || strings.Contains(fixture, "```") {
		return "", fmt.Errorf("control fixture must contain one complete bootstrap transaction")
	}
	if strings.Count(document, "```sql\n"+marker) != 1 || strings.Count(document, boundary) != 1 {
		return "", fmt.Errorf("document must contain exactly one normative control SQL fence")
	}
	start := strings.Index(document, "```sql\n"+marker) + len("```sql\n")
	end := strings.Index(document[start:], boundary)
	close := strings.Index(document[start:], "\n```")
	if end < 0 || close < 0 || end >= close {
		return "", fmt.Errorf("documented bootstrap transaction is incomplete")
	}
	end += start
	if !strings.HasSuffix(document[start:end], "\ncommit;\n") {
		return "", fmt.Errorf("documented bootstrap transaction has no final commit")
	}
	return document[:start] + fixture + document[end:], nil
}

// INV-SQL-SOURCE; TR-SQL-DOCUMENT.
func TestControlSQLDocumentRenderingPreservesSurroundingContent(t *testing.T) {
	const marker = "-- [normative-template] the control schema"
	fixture := marker + "\nbegin;\nselect 1;\ncommit;\n"
	prefix, suffix := "Before\n```sql\n", "\n-- END GENERATED CONTROL BOOTSTRAP\n\n-- later statements stay intact\nselect 2;\n```\nAfter\n"
	document := prefix + marker + "\nbegin;\nselect 0;\ncommit;" + suffix
	updated, err := renderControlBootstrapDocument(document, fixture)
	if err != nil || updated != prefix+strings.TrimSuffix(fixture, "\n")+suffix {
		t.Fatalf("surrounding design text changed: %q %v", updated, err)
	}
	for _, invalid := range []string{document + document, strings.Replace(document, "\ncommit;", "", 1), "```sql\n" + marker + "\n```\ncommit;", "No control template"} {
		if _, err := renderControlBootstrapDocument(invalid, fixture); err == nil {
			t.Fatalf("ambiguous or incomplete document accepted: %q", invalid)
		}
	}
	for _, invalid := range []string{strings.Replace(fixture, marker, "select 1;", 1), strings.TrimSuffix(fixture, "\ncommit;\n"), fixture + "commit;\n", strings.Replace(fixture, "select 1;", "```", 1)} {
		if _, err := renderControlBootstrapDocument(document, invalid); err == nil {
			t.Fatalf("incomplete or ambiguous fixture accepted: %q", invalid)
		}
	}
}
