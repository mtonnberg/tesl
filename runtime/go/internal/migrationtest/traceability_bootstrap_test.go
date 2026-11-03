package migrationtest

import (
	"go/ast"
	"strconv"
)

// Only Go's actual bootstrap signature is exempt. TestMain(*testing.T) is
// an ordinary test and still requires a registered layer and invariants.
func isTestingMain(file *ast.File, fn *ast.FuncDecl) bool {
	if fn.Name.Name != "TestMain" || fn.Recv != nil || fn.Type.TypeParams != nil || fn.Type.Results.NumFields() != 0 || fn.Type.Params.NumFields() != 1 {
		return false
	}
	pointer, ok := fn.Type.Params.List[0].Type.(*ast.StarExpr)
	if !ok {
		return false
	}
	for _, imp := range file.Imports {
		path, err := strconv.Unquote(imp.Path.Value)
		if err != nil || path != "testing" {
			continue
		}
		name := "testing"
		if imp.Name != nil {
			name = imp.Name.Name
		}
		if name == "." {
			typ, ok := pointer.X.(*ast.Ident)
			return ok && typ.Name == "M"
		}
		typ, ok := pointer.X.(*ast.SelectorExpr)
		if !ok {
			return false
		}
		qualifier, ok := typ.X.(*ast.Ident)
		return ok && qualifier.Name == name && typ.Sel.Name == "M"
	}
	return false
}
