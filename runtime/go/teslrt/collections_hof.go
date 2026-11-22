package teslrt

// The List, Dict and Set functions that take a callback (or an equality the emitter supplies)
// and are not hot enough to be worth an inlined loop. Each is a WRITER in the sense list.go
// uses: it allocates its result and never shares the caller's storage. Dict and Set results
// stay in key order — the ordering comes from the emitter, as for every other Dict/Set
// operation.

// ListZipWith combines elements positionally and stops at the shorter list.
func ListZipWith[A, B, C any](combine func(A, B) C, xs []A, ys []B) []C {
	n := min(len(xs), len(ys))
	out := make([]C, n)
	for index := range n {
		out[index] = combine(xs[index], ys[index])
	}
	return out
}

// ListUnzip splits a list of two-element lists into [firsts, seconds]. An inner list of
// any other length is a program error, as it is for the stdlib's own definition.
func ListUnzip[A any](pairs [][]A) [][]A {
	firsts := make([]A, len(pairs))
	seconds := make([]A, len(pairs))
	for index, pair := range pairs {
		if len(pair) != 2 {
			panic("List.unzip: every element must be a two-element list")
		}
		firsts[index], seconds[index] = pair[0], pair[1]
	}
	return [][]A{firsts, seconds}
}

// ListPartition answers [passing, failing], each in the original order.
func ListPartition[A any](keep func(A) bool, xs []A) [][]A {
	passing, failing := []A{}, []A{}
	for _, x := range xs {
		if keep(x) {
			passing = append(passing, x)
		} else {
			failing = append(failing, x)
		}
	}
	return [][]A{passing, failing}
}

// ListGroupBy groups CONSECUTIVE elements whose keys are equal.
func ListGroupBy[A, K any](key func(A) K, xs []A, equal func(K, K) bool) [][]A {
	groups := [][]A{}
	var current K
	for index, x := range xs {
		k := key(x)
		if index > 0 && equal(current, k) {
			groups[len(groups)-1] = append(groups[len(groups)-1], x)
		} else {
			groups = append(groups, []A{x})
		}
		current = k
	}
	return groups
}

// ListFindIndex is the 0-based index of the first element satisfying the predicate.
func ListFindIndex[A any](matches func(A) bool, xs []A) Maybe[Int] {
	for index, x := range xs {
		if matches(x) {
			return Something(FromInt64(int64(index)))
		}
	}
	return Nothing[Int]()
}

// ListDedupe removes CONSECUTIVE duplicates; `List.unique` is the one that removes them all.
func ListDedupe[A any](xs []A, equal func(A, A) bool) []A {
	out := make([]A, 0, len(xs))
	for index, x := range xs {
		if index == 0 || !equal(xs[index-1], x) {
			out = append(out, x)
		}
	}
	return out
}

// ListIntersperse puts sep between consecutive elements.
func ListIntersperse[A any](sep A, xs []A) []A {
	out := make([]A, 0, max(0, 2*len(xs)-1))
	for index, x := range xs {
		if index > 0 {
			out = append(out, sep)
		}
		out = append(out, x)
	}
	return out
}

// ListIntercalate joins the inner lists with sep between them, then flattens.
func ListIntercalate[A any](sep []A, xss [][]A) []A {
	out := []A{}
	for index, xs := range xss {
		if index > 0 {
			out = append(out, sep...)
		}
		out = append(out, xs...)
	}
	return out
}

// ListNth is the element at a 0-based index, if it is in range.
func ListNth[A any](xs []A, index Int) Maybe[A] {
	at, exact := index.Int64()
	if !exact || at < 0 || at >= int64(len(xs)) {
		return Nothing[A]()
	}
	return Something(xs[at])
}

// DictMap maps the values; the keys, and so the order, are unchanged.
func DictMap[K, V, W any](f func(V) W, d Dict[K, V]) Dict[K, W] {
	return DictMapWithKey(func(_ K, value V) W { return f(value) }, d)
}

func DictMapWithKey[K, V, W any](f func(K, V) W, d Dict[K, V]) Dict[K, W] {
	entries := make([]DictEntry[K, W], len(d.Entries))
	for index, entry := range d.Entries {
		entries[index] = DictEntry[K, W]{Key: entry.Key, Value: f(entry.Key, entry.Value)}
	}
	return Dict[K, W]{Entries: entries}
}

func DictFilter[K, V any](keep func(V) bool, d Dict[K, V]) Dict[K, V] {
	return DictFilterWithKey(func(_ K, value V) bool { return keep(value) }, d)
}

func DictFilterWithKey[K, V any](keep func(K, V) bool, d Dict[K, V]) Dict[K, V] {
	entries := []DictEntry[K, V]{}
	for _, entry := range d.Entries {
		if keep(entry.Key, entry.Value) {
			entries = append(entries, entry)
		}
	}
	return Dict[K, V]{Entries: entries}
}

// DictFoldl folds the values in key order; DictFoldr in reverse key order.
func DictFoldl[K, V, B any](f func(B, V) B, init B, d Dict[K, V]) B {
	acc := init
	for _, entry := range d.Entries {
		acc = f(acc, entry.Value)
	}
	return acc
}

func DictFoldr[K, V, B any](f func(V, B) B, init B, d Dict[K, V]) B {
	acc := init
	for index := len(d.Entries) - 1; index >= 0; index-- {
		acc = f(d.Entries[index].Value, acc)
	}
	return acc
}

// DictInsertWith inserts, combining with f(new, old) when the key is already present.
func DictInsertWith[K, V any](f func(V, V) V, key K, value V, d Dict[K, V], less func(K, K) bool) Dict[K, V] {
	if index, found := dictSearch(d, key, less); found {
		value = f(value, d.Entries[index].Value)
	}
	return DictInsert(d, key, value, less)
}

// DictUnionWith keeps every key of both; a key in both gets f(left value, right value).
func DictUnionWith[K, V any](f func(V, V) V, left, right Dict[K, V], less func(K, K) bool) Dict[K, V] {
	entries := make([]DictEntry[K, V], 0, len(left.Entries)+len(right.Entries))
	leftAt, rightAt := 0, 0
	for leftAt < len(left.Entries) && rightAt < len(right.Entries) {
		l, r := left.Entries[leftAt], right.Entries[rightAt]
		switch {
		case less(l.Key, r.Key):
			entries = append(entries, l)
			leftAt++
		case less(r.Key, l.Key):
			entries = append(entries, r)
			rightAt++
		default:
			entries = append(entries, DictEntry[K, V]{Key: l.Key, Value: f(l.Value, r.Value)})
			leftAt++
			rightAt++
		}
	}
	entries = append(entries, left.Entries[leftAt:]...)
	entries = append(entries, right.Entries[rightAt:]...)
	return Dict[K, V]{Entries: entries}
}

// DictUpdate hands f the current value (or Nothing) and stores what it answers: Something
// inserts or replaces, Nothing removes.
func DictUpdate[K, V any](key K, f func(Maybe[V]) Maybe[V], d Dict[K, V], less func(K, K) bool) Dict[K, V] {
	updated := f(DictLookup(d, key, less))
	if updated.Tag == MaybeSomething {
		return DictInsert(d, key, updated.SomethingValue, less)
	}
	return DictRemove(d, key, less)
}

// DictDifference keeps the left entries whose key the right dict lacks.
func DictDifference[K, V any](left, right Dict[K, V], less func(K, K) bool) Dict[K, V] {
	return DictFilterWithKey(func(key K, _ V) bool { return !DictMember(right, key, less) }, left)
}

// DictIntersection keeps the left entries whose key the right dict also has (left values).
func DictIntersection[K, V any](left, right Dict[K, V], less func(K, K) bool) Dict[K, V] {
	return DictFilterWithKey(func(key K, _ V) bool { return DictMember(right, key, less) }, left)
}

// SetMap maps the elements; results that collide collapse into one.
func SetMap[A, B any](f func(A) B, s Set[A], less func(B, B) bool) Set[B] {
	mapped := make([]B, len(s.Elements))
	for index, element := range s.Elements {
		mapped[index] = f(element)
	}
	return SetFromList(mapped, less)
}

// SetFilter keeps the elements satisfying the predicate; the order is preserved.
func SetFilter[A any](keep func(A) bool, s Set[A]) Set[A] {
	elements := []A{}
	for _, element := range s.Elements {
		if keep(element) {
			elements = append(elements, element)
		}
	}
	return Set[A]{Elements: elements}
}

func SetFoldl[A, B any](f func(B, A) B, init B, s Set[A]) B {
	acc := init
	for _, element := range s.Elements {
		acc = f(acc, element)
	}
	return acc
}

func SetAll[A any](holds func(A) bool, s Set[A]) bool {
	for _, element := range s.Elements {
		if !holds(element) {
			return false
		}
	}
	return true
}

func SetAny[A any](holds func(A) bool, s Set[A]) bool {
	for _, element := range s.Elements {
		if holds(element) {
			return true
		}
	}
	return false
}

// SetPartition answers [passing, failing].
func SetPartition[A any](keep func(A) bool, s Set[A]) []Set[A] {
	parts := ListPartition(keep, s.Elements)
	return []Set[A]{{Elements: parts[0]}, {Elements: parts[1]}}
}
