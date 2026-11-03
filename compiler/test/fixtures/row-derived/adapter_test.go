package teslmodapp

import (
	"math"
	old "tesl.generated/teslmodapp/internal/teslmodschemanotesv1"
	rt "tesl.generated/teslmodapp/internal/teslrt"
	"testing"
)

func TestDerivedActualTypedCallback(t *testing.T) {
	input := old.Note{Id: "identity", Author: "different-owner", Title: "distinct-title", Memo: "retained-memo"}
	if _, err := MainDatabaseCompiledRowTransform0.Run(input); err == nil {
		t.Fatal("unsealed Derived callback ran")
	}
	if err := rt.PreflightApplicationDatabases(MainDatabase); err != nil {
		t.Fatal(err)
	}
	result, err := MainDatabaseCompiledRowTransform0.Run(input)
	if err != nil || result.Tag != rt.MigratedRow {
		t.Fatal("generated Derived did not return Row", result, err)
	}
	row := result.RowValue
	if row.Id != input.Id || row.Owner != input.Author || row.Title != input.Title || row.Memo != input.Memo || row.Count.String() != "123456789012345678901234567890" || row.Label != "derived" || !row.Enabled || math.Float64bits(row.Ratio) != 1<<63 || row.Extra.Tag != rt.MaybeNothing {
		t.Fatal("generated Derived changed mapped values", row)
	}
}
