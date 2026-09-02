package teslrt

import "testing"

// These benchmarks replace the two Racket-only overhead probes with the same
// hot paths exercised by emitted Go programs. They are smoke benchmarks: CI
// checks allocation/output stability, while local performance work supplies
// longer budgets.
func BenchmarkProofOverhead(b *testing.B) {
	b.ReportAllocs()
	value := FromInt64(42)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		checked := Accept(value)
		if !checked.OK() || !Equal(MustCheck(checked), value) {
			b.Fatal("proof path changed")
		}
	}
}

func BenchmarkCodecOverhead(b *testing.B) {
	b.ReportAllocs()
	fields := map[string]any{
		"id":        "note-abc-123",
		"title":     "Buy milk and eggs",
		"content":   "Remember to also grab bread on the way home from work.",
		"authorId":  "user-42",
		"createdAt": FromInt64(1750000000000),
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		encoded := EncodeJSON(fields)
		if _, err := ParseJSON([]byte(encoded)); err != nil {
			b.Fatal(err)
		}
	}
}
