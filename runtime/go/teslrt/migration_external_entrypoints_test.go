package teslrt

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
)

// These private entrypoints are called from Go emitted/copied by the compiler,
// outside this package's ordinary source graph. Keep a checked link inventory:
// each function value must have an actual external producer, rather than turning
// off unused-code checking for the runtime. Their execution/authority is tested
// by the mandatory compiled PostgreSQL suites, not by this linkage check.
func TestMigrationExternalEntrypoints(t *testing.T) {
	root := os.Getenv("TESL_REPO_ROOT")
	if root == "" {
		root = filepath.Join("..", "..", "..")
	}
	bridge := filepath.Join(root, "compiler", "test", "fixtures", "queue-repair-postgres", "bridge.go")
	file, err := parser.ParseFile(token.NewFileSet(), bridge, nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	calls := map[string]bool{}
	ast.Inspect(file, func(node ast.Node) bool {
		if call, ok := node.(*ast.CallExpr); ok {
			if name, ok := call.Fun.(*ast.Ident); ok {
				calls[name.Name] = true
			}
		}
		return true
	})
	for _, entry := range []any{
		pgOpenQueueConversionCandidate,
		pgQueueConversionCandidateQueueContext,
		pgInstallQueueConversionCandidate,
		pgUpgradeQueueConversionCandidate,
		pgRegisterQueueRepairCandidate,
		pgApplyQueueConversionCandidate,
		pgStageRowQueueConversions,
		pgOpenRowQueueConversion,
		pgRetireRowQueue,
	} {
		name := runtime.FuncForPC(reflect.ValueOf(entry).Pointer()).Name()
		name = name[strings.LastIndex(name, ".")+1:]
		if !calls[name] {
			t.Errorf("private entrypoint %s has no call in %s; remove obsolete fixture-only runtime code", name, bridge)
		}
	}
	emitter, err := os.ReadFile(filepath.Join(root, "compiler", "lib", "emit_go.ml"))
	if err != nil {
		t.Fatal(err)
	}
	name := runtime.FuncForPC(reflect.ValueOf(registerCompiledQueueConversionSources).Pointer()).Name()
	name = name[strings.LastIndex(name, ".")+1:]
	if !strings.Contains(string(emitter), "func init() { "+name+"([]pgQueueConversionSourceSpec{") {
		t.Fatal("queue source registration no longer has its compiler-emitted initializer")
	}
}
