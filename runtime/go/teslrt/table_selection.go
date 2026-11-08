package teslrt

import "sort"

// TableSelectTop selects a bounded ordered range. Unlike TableSelectSorted, its
// comparator must be pure, total and a strict weak order. The compiler selects
// this path only for ordered Int/String/Bool fields and their non-secret nominal
// wrappers. Float/Quantity ordering retains the legacy path because IEEE NaN
// comparisons do not satisfy this contract.
func TableSelectTop[Row any](table *Table[Row], match func(Row) bool, less func(Row, Row) bool, offset, limit int) []Row {
	if offset < 0 || limit < 0 {
		return TableSelectSorted(table, match, less, offset, limit)
	}
	rows, _ := table.snapshot()
	if limit == 0 {
		for _, row := range rows {
			match(row)
		}
		return []Row{}
	}
	// Finish every predicate before any comparison, preserving reentrant
	// predicate evaluation and failures on one immutable table snapshot.
	matched := make([]int, 0, len(rows))
	for index, row := range rows {
		if match(row) {
			matched = append(matched, index)
		}
	}
	if offset >= len(matched) {
		return []Row{}
	}
	keep := len(matched)
	if limit < len(matched)-offset {
		keep = offset + limit // Bounded by len(matched), so cannot overflow.
	}
	if keep >= len(matched)/4 {
		// Full sorting is preferable when the requested prefix is already large.
		out := make([]Row, len(matched))
		for index, source := range matched {
			out[index] = rows[source]
		}
		sort.SliceStable(out, func(left, right int) bool { return less(out[left], out[right]) })
		return sliceRange(out, offset, limit)
	}
	// A max-heap keeps the worst retained row at its root. Original snapshot
	// positions break ties, reproducing stable insertion order exactly.
	heap := append([]int(nil), matched[:keep]...)
	worse := func(left, right int) bool {
		if less(rows[right], rows[left]) {
			return true
		}
		if less(rows[left], rows[right]) {
			return false
		}
		return left > right
	}
	down := func(root int) {
		for root < len(heap)/2 {
			child := root*2 + 1
			if child+1 < len(heap) && worse(heap[child+1], heap[child]) {
				child++
			}
			if !worse(heap[child], heap[root]) {
				return
			}
			heap[root], heap[child] = heap[child], heap[root]
			root = child
		}
	}
	for root := len(heap)/2 - 1; root >= 0; root-- {
		down(root)
	}
	for _, index := range matched[keep:] {
		// A later row that ties the current worst must not displace it.
		if less(rows[index], rows[heap[0]]) {
			heap[0] = index
			down(0)
		}
	}
	sort.Slice(heap, func(left, right int) bool { return worse(heap[right], heap[left]) })
	out := make([]Row, keep-offset)
	for index, source := range heap[offset:] {
		out[index] = rows[source]
	}
	return out
}

func TableSelectOneTop[Row any](table *Table[Row], match func(Row) bool, less func(Row, Row) bool) Maybe[Row] {
	rows := TableSelectTop(table, match, less, 0, 1)
	if len(rows) == 0 {
		return Nothing[Row]()
	}
	return Something(rows[0])
}
