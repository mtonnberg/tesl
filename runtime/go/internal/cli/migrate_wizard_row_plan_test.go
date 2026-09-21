package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func wizardRowPlan() map[string]any {
	return map[string]any{
		"version": 1, "kind": "migration-plan-preview", "ok": true,
		"planType": "row-history", "executable": false,
		"database": "App.Main", "family": "Schema.Notes", "initialVersion": 1,
		"steps": []any{
			map[string]any{"version": 1, "tables": []any{map[string]any{"entity": "Note", "table": "notes", "generation": 1}}},
			map[string]any{"version": 2, "requiresContractVersion": 1,
				"tables": []any{map[string]any{"entity": "Note", "table": "notes", "generation": 2}},
				"transforms": []any{map[string]any{
					"entity": "Note", "table": "notes", "mode": "Migrate", "fromGeneration": 1, "toGeneration": 2, "requiresFinalGeneration": 3,
					"fields": []any{
						map[string]any{"target": "title", "source": "title", "kind": "revalidate", "sourceColumn": "title", "targetColumn": "title", "proofEnforcement": "runtime-only"},
						map[string]any{"target": "info", "source": "info", "kind": "retype", "sourceColumn": "info", "targetColumn": "info__v2", "proofEnforcement": nil},
						map[string]any{"target": "weight", "source": nil, "kind": "computed", "sourceColumn": nil, "targetColumn": "weight", "proofEnforcement": nil},
					},
				}},
				"codecChanges": []any{map[string]any{"entity": "Note"}},
				"contract":     map[string]any{"sourceFile": "migrations/notes/v2-contract.tesl", "sourceHash": "exact-source-hash", "operationCount": 2},
			},
		},
	}
}

func runWizardRowPlan(t *testing.T, plan map[string]any) (string, error) {
	t.Helper()
	app, _ := fakeApp(t)
	calls := 0
	app.Execute = func(_ context.Context, inv Invocation) error {
		calls++
		if !reflect.DeepEqual(inv.Args, []string{"migrate", "plan", "--database", "App.Main", "--", "app.tesl"}) {
			t.Fatalf("unexpected operation (plan must remain read-only): %q", inv.Args)
		}
		return json.NewEncoder(inv.Stdout).Encode(plan)
	}
	err := app.migrationWizardPlan(context.Background(), migrationWizardOptions{
		entry: "app.tesl", database: "App.Main",
		selection: migrationWizardSelection{Database: "App.Main", Family: "Schema.Notes"},
	}, 2)
	if calls != 1 {
		t.Fatalf("wanted exactly one compiler preview, got %d operations", calls)
	}
	return app.Stdout.(*bytes.Buffer).String(), err
}

func TestMigrationWizardRowHistoryPlan(t *testing.T) {
	output, err := runWizardRowPlan(t, wizardRowPlan())
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"Application checks passed", "App.Main V2", "Requires the prior Contract for V1",
		`entity "Note": table "notes", generation 2`, `generation 1 -> 2; required final generation 3`,
		`revalidate "title" -> "title"; storage "title" -> "title"; proof enforcement: "runtime-only"`,
		`retype "info" -> "info"; storage "info" -> "info__v2"`,
		`computed <computed> -> "weight"; storage <none> -> "weight"`,
		`Checked Contract source: "migrations/notes/v2-contract.tesl" (2 operations)`,
		"1 stored codec change reports", "source preview, not persisted finality or decoder-removal evidence",
		"did not connect to PostgreSQL", "schema-worker-ready",
	} {
		if !strings.Contains(output, want) {
			t.Errorf("missing %q in:\n%s", want, output)
		}
	}
}

func TestMigrationWizardRefusesInvalidRowHistoryPlan(t *testing.T) {
	for name, mutate := range map[string]func(map[string]any){
		"unknown plan type":        func(p map[string]any) { p["planType"] = "execute" },
		"invalid plan type":        func(p map[string]any) { p["planType"] = 42 },
		"database changed":         func(p map[string]any) { p["database"] = "App.Other" },
		"family changed":           func(p map[string]any) { p["family"] = "Schema.Other" },
		"missing steps":            func(p map[string]any) { delete(p, "steps") },
		"empty steps":              func(p map[string]any) { p["steps"] = []any{} },
		"current revision changed": func(p map[string]any) { p["steps"].([]any)[1].(map[string]any)["version"] = 3 },
		"missing initial step":     func(p map[string]any) { p["steps"] = p["steps"].([]any)[1:] },
		"repeated step":            func(p map[string]any) { p["steps"].([]any)[0].(map[string]any)["version"] = 2 },
		"wrong initial revision":   func(p map[string]any) { p["initialVersion"] = 2 },
		"missing table inventory":  func(p map[string]any) { delete(p["steps"].([]any)[1].(map[string]any), "tables") },
		"future contract":          func(p map[string]any) { p["steps"].([]any)[1].(map[string]any)["requiresContractVersion"] = 2 },
		"executable":               func(p map[string]any) { p["executable"] = true },
		"missing executable":       func(p map[string]any) { delete(p, "executable") },
		"null executable":          func(p map[string]any) { p["executable"] = nil },
	} {
		t.Run(name, func(t *testing.T) {
			plan := wizardRowPlan()
			mutate(plan)
			output, err := runWizardRowPlan(t, plan)
			if err == nil {
				t.Fatal("invalid source preview accepted")
			}
			if output != "" {
				t.Fatalf("refusal printed a success summary: %s", output)
			}
		})
	}
}

func TestMigrationWizardAdditivePlanUnchanged(t *testing.T) {
	plan := wizardRowPlan()
	delete(plan, "planType")
	plan["steps"] = []any{map[string]any{"version": 2, "epochPreserving": true, "operations": []any{
		map[string]any{"kind": "add-column", "table": "notes", "column": map[string]any{"name": "memo"}},
	}}}
	output, err := runWizardRowPlan(t, plan)
	if err != nil || !strings.Contains(output, `add-column "notes.memo"`) {
		t.Fatalf("additive plan changed: %v\n%s", err, output)
	}
	if strings.Contains(output, "row-history") {
		t.Fatalf("additive plan mislabeled: %s", output)
	}
}

// Exercise the compiler-owned serializer and CLI consumer together using the
// same full application as the PostgreSQL revalidation regression. Relative
// source layout and seals are preserved inside an isolated project.
func TestMigrationWizardNativeRowHistoryPreview(t *testing.T) {
	repo := os.Getenv("TESL_REPO_ROOT")
	if repo == "" {
		t.Skip("requires TESL_REPO_ROOT and built compiler")
	}
	compiler := filepath.Join(repo, "compiler", "_build", "default", "bin", "main.exe")
	if _, err := os.Stat(compiler); err != nil {
		t.Fatal(err)
	}
	app, _ := fakeApp(t)
	app.Environment = os.Environ()
	app.Resolver.Getenv = func(key string) string {
		if key == "TESL_COMPILER" {
			return compiler
		}
		if key == "TESL_TOOLCHAIN_ROOT" {
			return ""
		}
		return os.Getenv(key)
	}
	app.Execute = execute
	fixture := filepath.Join(repo, "example", "learn", "db-revalidation")
	originals := map[string][]byte{}
	err := filepath.WalkDir(fixture, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			// Public CLI runs may leave generated build artifacts alongside the
			// fixture; copy only its source tree into this isolated test.
			if path != fixture && strings.HasPrefix(entry.Name(), ".") {
				return filepath.SkipDir
			}
			return nil
		}
		relative, err := filepath.Rel(fixture, path)
		if err != nil {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		originals[relative] = data
		writeProjectFile(t, app.Directory, relative, string(data))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	err = app.migrationWizardPlan(ctx, migrationWizardOptions{
		entry: "app.tesl", database: "App.Main",
		selection: migrationWizardSelection{Database: "App.Main", Family: "Schema.Notes"},
	}, 2)
	output := app.Stdout.(*bytes.Buffer).String()
	if err != nil {
		t.Fatalf("real row-history preview: %v\n%s\n%s", err, output, app.Stderr)
	}
	for _, want := range []string{
		"Application checks passed. PostgreSQL plan for App.Main V2:",
		`revalidate "title" -> "title"; storage "title" -> "title"; proof enforcement: "runtime-only"`,
		"Checked Contract source:", "v2-contract.tesl",
		"source preview, not persisted finality or decoder-removal evidence",
		"did not connect to PostgreSQL",
	} {
		if !strings.Contains(output, want) {
			t.Errorf("missing %q in actual compiler preview:\n%s", want, output)
		}
	}
	for path, before := range originals {
		after, err := os.ReadFile(filepath.Join(app.Directory, path))
		if err != nil || !bytes.Equal(before, after) {
			t.Fatalf("source-only preview changed %s: %v", path, err)
		}
	}
}
