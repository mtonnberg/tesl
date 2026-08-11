package teslrt

import "testing"

func TestIfEvaluatesOnlySelectedBranch(t *testing.T) {
	t.Run("true", func(t *testing.T) {
		got := If(true,
			func() string { return "selected" },
			func() string { t.Fatal("false branch evaluated"); return "" })
		if got != "selected" {
			t.Fatalf("If(true) = %q, want selected", got)
		}
	})

	t.Run("false", func(t *testing.T) {
		got := If(false,
			func() string { t.Fatal("true branch evaluated"); return "" },
			func() string { return "selected" })
		if got != "selected" {
			t.Fatalf("If(false) = %q, want selected", got)
		}
	})
}
