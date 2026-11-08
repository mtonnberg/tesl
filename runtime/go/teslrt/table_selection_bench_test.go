package teslrt

import "testing"

type selectionBenchRow struct {
	ID      int
	Score   Int
	Label   string
	Details [4]string
}

var selectionBenchResult []selectionBenchRow

// Query-only benchmark. Unique IDs are constructed directly so quadratic
// insertion checks are not confused with the selection workload being measured.
func BenchmarkMemoryBoundedSelection(b *testing.B) {
	rows := make([]selectionBenchRow, 100000)
	for index := range rows {
		rows[index] = selectionBenchRow{ID: index, Score: FromInt64(int64((index * 48271) % 100003)), Label: "item"}
	}
	table := &Table[selectionBenchRow]{rows: rows}
	match := func(selectionBenchRow) bool { return true }
	less := func(a, c selectionBenchRow) bool { return Compare(a.Score, c.Score) < 0 }
	b.Run("legacy-range", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			selectionBenchResult = sliceRange(TableSelect(table, match), 10, 10)
		}
	})
	b.Run("legacy-sorted", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			selectionBenchResult = TableSelectSorted(table, match, less, 0, 10)
		}
	})
	b.Run("bounded-range", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			selectionBenchResult = TableSelectRange(table, match, 10, 10)
		}
	})
	b.Run("bounded-sorted", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			selectionBenchResult = TableSelectTop(table, match, less, 0, 10)
		}
	})
}
