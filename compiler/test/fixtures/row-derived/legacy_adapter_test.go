package teslmodapp

import (
	"encoding/json"
	old "tesl.generated/teslmodapp/internal/teslmodschemanotesv1"
	rt "tesl.generated/teslmodapp/internal/teslrt"
	"testing"
)

func TestDerivedLegacyOldCodec(t *testing.T) {
	if err := rt.PreflightApplicationDatabases(MainDatabase); err != nil {
		t.Fatal(err)
	}
	input := old.Note{Id: "identity", Author: "before", Title: "distinct-title", Memo: "retained-memo", Metadata: old.Metadata{Text: "old"}}
	result, err := MainDatabaseCompiledRowTransform0.Run(input)
	if err != nil || result.Tag != rt.MigratedRow || result.RowValue.Owner != "new-owner" {
		t.Fatal("Derived legacy forward", result, err)
	}
	reverse, err := MainDatabaseCompiledRowWriteBack0.Reverse(result.RowValue)
	if err != nil || reverse.Author != "former" || reverse.Metadata.Text != "retained-memo" || reverse.Id != input.Id || reverse.Title != input.Title {
		t.Fatal("checked legacy reverse", reverse, err)
	}
	encoded, err := MainDatabaseCompiledRowWriteBack0.Encode(result.RowValue)
	if err != nil {
		t.Fatal(err)
	}
	projection, err := MainDatabaseCompiledRowStorage0.SourceProjection().CheckOrder([]string{"id", "author", "title", "memo", "metadata"})
	if err != nil {
		t.Fatal(err)
	}
	params, err := encoded.Parameters(projection)
	if err != nil || len(params) != 5 {
		t.Fatal("full old projection", params, err)
	}
	var data map[string]string
	if err := json.Unmarshal([]byte(params[4].(string)), &data); err != nil {
		t.Fatal(err)
	}
	if len(data) != 1 || data["oldText"] != "retained-memo" || params[1] != "former" {
		t.Fatal("legacy output used wrong old codec", params)
	}
}
