package teslrt

import "testing"

func TestMigratedZeroRejects(t *testing.T) {
	var result Migrated[struct{ Required string }]
	if result.Tag != MigratedReject || result.Tag == MigratedRow {
		t.Fatal("a zero migration result must not be a successful row")
	}
}
