package teslrt

// Set is Tesl's `Set a`, held as elements kept SORTED with no duplicates.
//
// Same reasoning as Dict (see dict.go): a Go map cannot be keyed by the non-comparable
// teslrt.Int, and Go randomises map iteration order per run — which would make the same
// binary print different output across runs, worse than Racket's unspecified-but-stable
// order. Sorted order is deterministic and free here, since the insertion point is the
// binary search membership already performs.
//
// Racket's `Set.toList` iterates a hash, so element order is UNSPECIFIED in Tesl: a
// program may observe membership and size, never order. That divergence is real and
// demonstrated — see the Dict entry in the migration tracker.
//
// Ordering comes in from the emitter, which knows the concrete element type at every
// call site.
type Set[A any] struct {
	Elements []A
}

func SetEmpty[A any]() Set[A] {
	return Set[A]{}
}

func SetSingleton[A any](value A) Set[A] {
	return Set[A]{Elements: []A{value}}
}

func SetSize[A any](s Set[A]) Int {
	return FromInt64(int64(len(s.Elements)))
}

func SetIsEmpty[A any](s Set[A]) bool {
	return len(s.Elements) == 0
}

// setSearch returns the insertion index and whether the element was present.
func setSearch[A any](s Set[A], value A, less func(A, A) bool) (int, bool) {
	low, high := 0, len(s.Elements)
	for low < high {
		middle := int(uint(low+high) >> 1)
		switch {
		case less(s.Elements[middle], value):
			low = middle + 1
		case less(value, s.Elements[middle]):
			high = middle
		default:
			return middle, true
		}
	}
	return low, false
}

func SetMember[A any](value A, s Set[A], less func(A, A) bool) bool {
	_, found := setSearch(s, value, less)
	return found
}

// SetInsert is a WRITER, so it allocates rather than reusing the caller's spare
// capacity — the same rule list.go states.
func SetInsert[A any](value A, s Set[A], less func(A, A) bool) Set[A] {
	index, found := setSearch(s, value, less)
	if found {
		return s
	}
	elements := make([]A, 0, len(s.Elements)+1)
	elements = append(elements, s.Elements[:index]...)
	elements = append(elements, value)
	elements = append(elements, s.Elements[index:]...)
	return Set[A]{Elements: elements}
}

func SetRemove[A any](value A, s Set[A], less func(A, A) bool) Set[A] {
	index, found := setSearch(s, value, less)
	if !found {
		return s
	}
	elements := make([]A, 0, len(s.Elements)-1)
	elements = append(elements, s.Elements[:index]...)
	elements = append(elements, s.Elements[index+1:]...)
	return Set[A]{Elements: elements}
}

// SetToList hands back a copy in element order, so a caller cannot reach the set's own
// storage through the list.
func SetToList[A any](s Set[A]) []A {
	out := make([]A, len(s.Elements))
	copy(out, s.Elements)
	return out
}

// SetFromList sorts once and drops duplicates rather than inserting n times, which
// would be O(n²).
func SetFromList[A any](values []A, less func(A, A) bool) Set[A] {
	out := SetEmpty[A]()
	if len(values) == 0 {
		return out
	}
	sorted := ListSortBy(values, less)
	elements := make([]A, 0, len(sorted))
	for index, value := range sorted {
		if index == 0 || less(elements[len(elements)-1], value) {
			elements = append(elements, value)
		}
	}
	return Set[A]{Elements: elements}
}

// SetUnion, SetIntersection, and SetDifference each merge two ordered runs in one pass,
// so they are O(n+m) rather than n lookups.
func SetUnion[A any](left, right Set[A], less func(A, A) bool) Set[A] {
	elements := make([]A, 0, len(left.Elements)+len(right.Elements))
	leftIndex, rightIndex := 0, 0
	for leftIndex < len(left.Elements) && rightIndex < len(right.Elements) {
		switch {
		case less(left.Elements[leftIndex], right.Elements[rightIndex]):
			elements = append(elements, left.Elements[leftIndex])
			leftIndex++
		case less(right.Elements[rightIndex], left.Elements[leftIndex]):
			elements = append(elements, right.Elements[rightIndex])
			rightIndex++
		default:
			elements = append(elements, left.Elements[leftIndex])
			leftIndex++
			rightIndex++
		}
	}
	elements = append(elements, left.Elements[leftIndex:]...)
	elements = append(elements, right.Elements[rightIndex:]...)
	return Set[A]{Elements: elements}
}

func SetIntersection[A any](left, right Set[A], less func(A, A) bool) Set[A] {
	elements := make([]A, 0, min(len(left.Elements), len(right.Elements)))
	leftIndex, rightIndex := 0, 0
	for leftIndex < len(left.Elements) && rightIndex < len(right.Elements) {
		switch {
		case less(left.Elements[leftIndex], right.Elements[rightIndex]):
			leftIndex++
		case less(right.Elements[rightIndex], left.Elements[leftIndex]):
			rightIndex++
		default:
			elements = append(elements, left.Elements[leftIndex])
			leftIndex++
			rightIndex++
		}
	}
	return Set[A]{Elements: elements}
}

func SetDifference[A any](left, right Set[A], less func(A, A) bool) Set[A] {
	elements := make([]A, 0, len(left.Elements))
	leftIndex, rightIndex := 0, 0
	for leftIndex < len(left.Elements) && rightIndex < len(right.Elements) {
		switch {
		case less(left.Elements[leftIndex], right.Elements[rightIndex]):
			elements = append(elements, left.Elements[leftIndex])
			leftIndex++
		case less(right.Elements[rightIndex], left.Elements[leftIndex]):
			rightIndex++
		default:
			leftIndex++
			rightIndex++
		}
	}
	elements = append(elements, left.Elements[leftIndex:]...)
	return Set[A]{Elements: elements}
}

// SetIsSubset reports whether every element of left is also in right.
func SetIsSubset[A any](left, right Set[A], less func(A, A) bool) bool {
	rightIndex := 0
	for _, value := range left.Elements {
		for rightIndex < len(right.Elements) && less(right.Elements[rightIndex], value) {
			rightIndex++
		}
		if rightIndex >= len(right.Elements) || less(value, right.Elements[rightIndex]) {
			return false
		}
		rightIndex++
	}
	return true
}

// SetEqualBy compares in one pass, since both sides are ordered.
func SetEqualBy[A any](left, right Set[A], equal func(A, A) bool) bool {
	if len(left.Elements) != len(right.Elements) {
		return false
	}
	for index := range left.Elements {
		if !equal(left.Elements[index], right.Elements[index]) {
			return false
		}
	}
	return true
}
