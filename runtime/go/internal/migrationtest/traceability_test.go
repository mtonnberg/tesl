package migrationtest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
	"unicode"
	"unicode/utf8"
)

type protocolTransition struct {
	Statement  string   `json:"statement"`
	Operations []string `json:"operations"`
}

type protocolInventory struct {
	Version         int                           `json:"version"`
	Scope           string                        `json:"scope"`
	UncoveredScopes []string                      `json:"uncovered_scopes"`
	Invariants      map[string]string             `json:"invariants"`
	Transitions     map[string]protocolTransition `json:"transitions"`
	TestLayers      map[string]string             `json:"test_layers"`
}

type protocolTest struct {
	Name        string   `json:"name"`
	File        string   `json:"file"`
	Line        int      `json:"line"`
	Layer       string   `json:"layer"`
	Invariants  []string `json:"invariants"`
	Transitions []string `json:"transitions"`
	Failpoints  []string `json:"named_failpoints"`
	UsesFixture bool     `json:"-"`
}

type protocolSource struct {
	Tests          []protocolTest
	ModelIDs       map[string][]string
	Operations     map[string]bool
	OperationPaths map[string][]string
}

var protocolID = regexp.MustCompile(`\b(?:INV|TR)-[A-Z0-9]+(?:-[A-Z0-9]+)*\b`)

func isGoTestName(name string) bool {
	if !strings.HasPrefix(name, "Test") {
		return false
	}
	r, _ := utf8.DecodeRuneInString(strings.TrimPrefix(name, "Test"))
	return !unicode.IsLower(r)
}

func rejectDuplicateJSONKeys(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	var value func(int) error
	value = func(depth int) error {
		if depth > 128 {
			return fmt.Errorf("protocol inventory is nested too deeply")
		}
		item, err := decoder.Token()
		if err != nil {
			return err
		}
		switch item {
		case json.Delim('{'):
			seen := map[string]bool{}
			for decoder.More() {
				key, err := decoder.Token()
				if err != nil {
					return err
				}
				name, ok := key.(string)
				if !ok || seen[name] {
					return fmt.Errorf("duplicate or invalid protocol inventory key %q", name)
				}
				seen[name] = true
				if err := value(depth + 1); err != nil {
					return err
				}
			}
			_, err = decoder.Token()
		case json.Delim('['):
			for decoder.More() {
				if err := value(depth + 1); err != nil {
					return err
				}
			}
			_, err = decoder.Token()
		}
		return err
	}
	return value(0)
}

func sortedUnique(values []string) []string {
	values = slices.Clone(values)
	slices.Sort(values)
	return slices.Compact(values)
}

func readProtocolSource(files map[string]string) (protocolSource, error) {
	result := protocolSource{ModelIDs: map[string][]string{}, Operations: map[string]bool{}, OperationPaths: map[string][]string{}}
	for _, name := range slices.Sorted(maps.Keys(files)) {
		positions := token.NewFileSet()
		file, err := parser.ParseFile(positions, name, files[name], parser.ParseComments)
		if err != nil {
			return result, err
		}
		if strings.HasSuffix(name, "_test.go") {
			for _, decl := range file.Decls {
				fn, ok := decl.(*ast.FuncDecl)
				if !ok || fn.Recv != nil || !isGoTestName(fn.Name.Name) {
					continue
				}
				test := protocolTest{Name: fn.Name.Name, File: name, Line: positions.Position(fn.Pos()).Line}
				for _, id := range protocolID.FindAllString(fn.Doc.Text(), -1) {
					if strings.HasPrefix(id, "INV-") {
						test.Invariants = append(test.Invariants, id)
					} else {
						test.Transitions = append(test.Transitions, id)
					}
				}
				ast.Inspect(fn.Body, func(node ast.Node) bool {
					if call, ok := node.(*ast.CallExpr); ok {
						if fun, ok := call.Fun.(*ast.Ident); ok && (fun.Name == "newDatabaseFixture" || fun.Name == "newUninstalledDatabaseFixture" || fun.Name == "newRegistryDatabase") {
							test.UsesFixture = true
						}
					}
					if value, ok := node.(*ast.CompositeLit); ok {
						if typ, ok := value.Type.(*ast.Ident); ok && typ.Name == "Event" {
							for i, item := range value.Elts {
								expr := item
								if field, ok := item.(*ast.KeyValueExpr); ok {
									key, ok := field.Key.(*ast.Ident)
									if !ok || key.Name != "Name" {
										continue
									}
									expr = field.Value
								} else if i != 0 {
									continue
								}
								if literal, ok := expr.(*ast.BasicLit); ok && literal.Kind == token.STRING {
									value, err := strconv.Unquote(literal.Value)
									if err == nil {
										test.Failpoints = append(test.Failpoints, value)
									}
								}
							}
						}
					}
					return true
				})
				test.Invariants, test.Transitions, test.Failpoints = sortedUnique(test.Invariants), sortedUnique(test.Transitions), sortedUnique(test.Failpoints)
				result.Tests = append(result.Tests, test)
			}
		} else if strings.HasPrefix(name, "model") {
			ast.Inspect(file, func(node ast.Node) bool {
				if literal, ok := node.(*ast.BasicLit); ok && literal.Kind == token.STRING {
					value, err := strconv.Unquote(literal.Value)
					if err == nil {
						for _, id := range protocolID.FindAllString(value, -1) {
							result.ModelIDs[id] = append(result.ModelIDs[id], fmt.Sprintf("%s:%d", name, positions.Position(literal.Pos()).Line))
						}
					}
				}
				if statement, ok := node.(*ast.SwitchStmt); ok {
					if field, ok := statement.Tag.(*ast.SelectorExpr); ok && field.Sel.Name == "Kind" {
						if receiver, ok := field.X.(*ast.Ident); ok && receiver.Name == "op" {
							for _, clause := range statement.Body.List {
								for _, expr := range clause.(*ast.CaseClause).List {
									if literal, ok := expr.(*ast.BasicLit); ok && literal.Kind == token.STRING {
										if operation, err := strconv.Unquote(literal.Value); err == nil {
											result.Operations[operation] = true
											result.OperationPaths[operation] = append(result.OperationPaths[operation], fmt.Sprintf("%s:%d", name, positions.Position(literal.Pos()).Line))
										}
									}
								}
							}
						}
					}
				}
				return true
			})
		}
	}
	return result, nil
}

func protocolCoverage(spec protocolInventory, source protocolSource) ([]byte, error) {
	source.Tests = slices.Clone(source.Tests)
	if spec.Version != 1 || spec.Scope != "implemented-harness-kernel" || len(spec.Invariants) == 0 || len(spec.Transitions) == 0 || len(source.Tests) == 0 || len(source.Operations) == 0 {
		return nil, fmt.Errorf("incomplete protocol inventory or unsupported scope/version")
	}
	for id, statement := range spec.Invariants {
		if !strings.HasPrefix(id, "INV-") || protocolID.FindString(id) != id || statement == "" {
			return nil, fmt.Errorf("invalid invariant %q", id)
		}
	}
	operations := map[string]bool{}
	for id, transition := range spec.Transitions {
		if !strings.HasPrefix(id, "TR-") || protocolID.FindString(id) != id || transition.Statement == "" {
			return nil, fmt.Errorf("invalid transition %q", id)
		}
		for _, operation := range transition.Operations {
			if !source.Operations[operation] {
				return nil, fmt.Errorf("%s names missing model operation %q", id, operation)
			}
			operations[operation] = true
		}
	}
	for operation := range source.Operations {
		if !operations[operation] {
			return nil, fmt.Errorf("model operation %q has no registered transition", operation)
		}
	}
	for id := range source.ModelIDs {
		if spec.Invariants[id] == "" {
			return nil, fmt.Errorf("model names unregistered invariant %s", id)
		}
	}
	testsByID := map[string][]string{}
	usedLayers := map[string]bool{}
	for i := range source.Tests {
		test := &source.Tests[i]
		key := test.File + "#" + test.Name
		layerKey := test.File
		if _, exists := spec.TestLayers[key]; exists {
			layerKey = key
		}
		test.Layer = spec.TestLayers[layerKey]
		usedLayers[layerKey] = true
		switch test.Layer {
		case "model", "harness":
			if test.UsesFixture {
				return nil, fmt.Errorf("%s uses PostgreSQL but is labelled %s", key, test.Layer)
			}
		case "postgres", "compiled-postgres", "owned-cluster-nightly", "pooler":
		default:
			return nil, fmt.Errorf("%s has no recognised coverage layer", key)
		}
		if len(test.Invariants) == 0 {
			return nil, fmt.Errorf("%s names no invariant", key)
		}
		for _, id := range test.Invariants {
			if spec.Invariants[id] == "" {
				return nil, fmt.Errorf("%s names unregistered invariant %s", key, id)
			}
			testsByID[id] = append(testsByID[id], key)
		}
		for _, id := range test.Transitions {
			if _, exists := spec.Transitions[id]; !exists {
				return nil, fmt.Errorf("%s names unregistered transition %s", key, id)
			}
			testsByID[id] = append(testsByID[id], key)
		}
	}
	for key := range spec.TestLayers {
		if !usedLayers[key] {
			return nil, fmt.Errorf("coverage layer %q refers to no current test", key)
		}
	}
	type entry struct {
		ID         string   `json:"id"`
		Statement  string   `json:"statement"`
		ModelPaths []string `json:"model_paths"`
		Tests      []string `json:"tests"`
	}
	entries := []entry{}
	statements := maps.Clone(spec.Invariants)
	for id, transition := range spec.Transitions {
		statements[id] = transition.Statement
	}
	for _, id := range slices.Sorted(maps.Keys(statements)) {
		if protocolID.FindString(id) != id || statements[id] == "" || len(testsByID[id]) == 0 {
			return nil, fmt.Errorf("%s is invalid or has no test", id)
		}
		paths := slices.Clone(source.ModelIDs[id])
		for _, operation := range spec.Transitions[id].Operations {
			paths = append(paths, source.OperationPaths[operation]...)
		}
		entries = append(entries, entry{ID: id, Statement: statements[id], ModelPaths: sortedUnique(paths), Tests: sortedUnique(testsByID[id])})
	}
	report := struct {
		Scope                   string         `json:"scope"`
		SourceRoot              string         `json:"source_root"`
		UncoveredScopes         []string       `json:"uncovered_scopes"`
		ConfiguredPRMajors      []int          `json:"configured_pr_postgres_majors"`
		ConfiguredNightlyMajors []int          `json:"configured_nightly_postgres_majors"`
		Entries                 []entry        `json:"entries"`
		Tests                   []protocolTest `json:"tests"`
	}{spec.Scope, "runtime/go/internal/migrationtest", spec.UncoveredScopes, []int{14, 18}, []int{14, 15, 16, 17, 18}, entries, source.Tests}
	data, err := json.MarshalIndent(report, "", "  ")
	return append(data, '\n'), err
}

// INV-TRACEABILITY; TR-TRACEABILITY-CHECK.
func TestProtocolTraceability(t *testing.T) {
	root := os.Getenv("TESL_REPO_ROOT")
	if root == "" {
		root = filepath.Join("..", "..", "..", "..")
	}
	data, err := os.ReadFile(filepath.Join(root, "dev-docs", "migration-protocol-inventory.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := rejectDuplicateJSONKeys(data); err != nil {
		t.Fatal(err)
	}
	var spec protocolInventory
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&spec); err != nil {
		t.Fatal(err)
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		t.Fatal("trailing content in protocol inventory")
	}
	files := map[string]string{}
	paths, err := filepath.Glob(filepath.Join(root, "runtime", "go", "internal", "migrationtest", "*.go"))
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		files[filepath.Base(path)] = string(data)
	}
	source, err := readProtocolSource(files)
	if err != nil {
		t.Fatal(err)
	}
	generated, err := protocolCoverage(spec, source)
	if err != nil {
		t.Fatal(err)
	}
	workflow, err := os.ReadFile(filepath.Join(root, ".github", "workflows", "migration-protocol.yml"))
	if err != nil {
		t.Fatal(err)
	}
	for _, matrix := range []string{"'[14,18]'", "'[14,15,16,17,18]'", "TESL_MIGRATION_TEST_POSTGRES_MAJOR: ${{ matrix.postgres }}"} {
		if !bytes.Contains(workflow, []byte(matrix)) {
			t.Fatal("workflow PostgreSQL lanes differ from the coverage map")
		}
	}
	path := filepath.Join(root, "dev-docs", "migration-protocol-coverage.json")
	if os.Getenv("TESL_UPDATE_MIGRATION_TRACEABILITY") == "1" {
		if err := os.WriteFile(path, generated, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	checkedIn, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(checkedIn, generated) {
		t.Fatal("migration coverage map is stale; run TESL_UPDATE_MIGRATION_TRACEABILITY=1 go test ./internal/migrationtest -run '^TestProtocolTraceability$' from runtime/go")
	}
}

// INV-TRACEABILITY; TR-TRACEABILITY-CHECK.
func TestTraceabilityRejectsMissingAndMisclassifiedCoverage(t *testing.T) {
	files := map[string]string{
		"model.go": `package example
func step(op Op) { switch op.Kind { case "advance": panic("INV-ONE: guarded") } }`,
		"example_test.go": `package example
// INV-ONE; TR-ONE.
func TestExample(t *testing.T) {
  event := Event{"paused", "worker", 1}; _ = event
  named := Event{Actor:"other", Name:"second", Occurrence:1}; _ = named
  unrelated := Other{Name:"not-an-event"}; _ = unrelated
}
// INV-IGNORED is in a helper, not a regression test.
func helper() {}
// INV-IGNORED is also not exercised by go test in a lowercase-suffix helper.
func Testhelper() {}`,
	}
	spec := protocolInventory{Version: 1, Scope: "implemented-harness-kernel", Invariants: map[string]string{"INV-ONE": "one property"},
		Transitions: map[string]protocolTransition{"TR-ONE": {Statement: "one edge", Operations: []string{"advance"}}},
		TestLayers:  map[string]string{"example_test.go": "model"}}
	source, err := readProtocolSource(files)
	if err != nil {
		t.Fatal(err)
	}
	first, err := protocolCoverage(spec, source)
	if err != nil {
		t.Fatal(err)
	}
	if len(source.Tests) != 1 || !slices.Equal(source.Tests[0].Failpoints, []string{"paused", "second"}) {
		t.Fatalf("test metadata extraction lost the function boundary: %+v", source.Tests)
	}
	for name, mutate := range map[string]func(*protocolInventory, *protocolSource){
		"unknown invariant":  func(s *protocolInventory, _ *protocolSource) { delete(s.Invariants, "INV-ONE") },
		"untested invariant": func(s *protocolInventory, _ *protocolSource) { s.Invariants["INV-TWO"] = "uncovered" },
		"unknown transition": func(s *protocolInventory, _ *protocolSource) { delete(s.Transitions, "TR-ONE") },
		"untested transition": func(s *protocolInventory, _ *protocolSource) {
			s.Transitions["TR-TWO"] = protocolTransition{Statement: "uncovered"}
		},
		"new operation": func(_ *protocolInventory, s *protocolSource) { s.Operations["unlisted"] = true },
		"deleted operation": func(s *protocolInventory, _ *protocolSource) {
			s.Transitions["TR-ONE"] = protocolTransition{Statement: "one edge", Operations: []string{"missing"}}
		},
		"test without invariant":  func(_ *protocolInventory, s *protocolSource) { s.Tests[0].Invariants = nil },
		"unclassified test":       func(s *protocolInventory, _ *protocolSource) { delete(s.TestLayers, "example_test.go") },
		"stale test entry":        func(s *protocolInventory, _ *protocolSource) { s.TestLayers["deleted_test.go"] = "model" },
		"database labelled model": func(_ *protocolInventory, s *protocolSource) { s.Tests[0].UsesFixture = true },
	} {
		t.Run(name, func(t *testing.T) {
			candidate := spec
			candidate.Invariants, candidate.Transitions, candidate.TestLayers = maps.Clone(spec.Invariants), maps.Clone(spec.Transitions), maps.Clone(spec.TestLayers)
			parsed, err := readProtocolSource(files)
			if err != nil {
				t.Fatal(err)
			}
			mutate(&candidate, &parsed)
			if _, err := protocolCoverage(candidate, parsed); err == nil {
				t.Fatal("missing or misleading coverage was accepted")
			}
		})
	}
	second, err := protocolCoverage(spec, source)
	if err != nil || !bytes.Equal(first, second) {
		t.Fatalf("coverage generation is not deterministic: %v", err)
	}
	for _, duplicate := range []string{
		`{"version":1,"version":2}`,
		`{"invariants":{"INV-ONE":"first","INV-ONE":"second"}}`,
		`{"entries":[{"name":"first","name":"second"}]}`,
		`{"version":1,"\u0076ersion":2}`,
	} {
		if err := rejectDuplicateJSONKeys([]byte(duplicate)); err == nil {
			t.Fatalf("duplicate JSON definition was accepted: %s", duplicate)
		}
	}
	if err := rejectDuplicateJSONKeys([]byte(`{"first":{"name":"one"},"second":{"name":"two"},"rows":[1,true,null]}`)); err != nil {
		t.Fatalf("independent JSON object scopes were merged: %v", err)
	}
}
