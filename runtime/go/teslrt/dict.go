package teslrt

import (
	"fmt"
	"slices"
)

// Dict is Tesl's `Dict k v`, held as entries kept SORTED BY KEY.
//
// Two forces pick this representation over a Go map. First, a Go map cannot be keyed
// by teslrt.Int at all — it is deliberately non-comparable — so a map would need an
// emitter-supplied key encoding and would still store the original key alongside it.
// Second, and more important: Go randomises map iteration order per run, while the
// Racket backend iterates a hash whose order is unspecified but stable within a run
// (tesl/dict.rkt uses `hash-keys` and `in-hash`, and says so: "hash has no order").
// Emitting raw map order would therefore make a Tesl program's output differ between
// runs of the SAME binary — strictly worse than the Racket behavior. Sorted order is
// deterministic, reproducible, and a defensible reading of an operation the language
// leaves unspecified.
//
// Costs, accepted: lookup is O(log n) rather than O(1), and insert is O(n) because a
// Tesl Dict is immutable and every write copies (the same rule as List — see list.go).
// Racket's persistent hash is asymptotically better; Tesl dicts are typically small
// (headers, cookies, config) and this keeps the runtime auditable.
//
// Ordering is supplied by the emitter, which knows the concrete key type at every call
// site — the same device used for list equality and sorting.
type Dict[K any, V any] struct {
	Entries []DictEntry[K, V]
}

type DictEntry[K any, V any] struct {
	Key   K
	Value V
}

func DictEmpty[K any, V any]() Dict[K, V] {
	return Dict[K, V]{}
}

func DictSize[K any, V any](d Dict[K, V]) Int {
	return FromInt64(int64(len(d.Entries)))
}

func DictIsEmpty[K any, V any](d Dict[K, V]) bool {
	return len(d.Entries) == 0
}

// dictSearch returns the entry index for key, and whether it was present.
func dictSearch[K any, V any](d Dict[K, V], key K, less func(K, K) bool) (int, bool) {
	return slices.BinarySearchFunc(d.Entries, key, func(entry DictEntry[K, V], key K) int {
		switch {
		case less(entry.Key, key):
			return -1
		case less(key, entry.Key):
			return 1
		default:
			return 0
		}
	})
}

func DictLookup[K any, V any](d Dict[K, V], key K, less func(K, K) bool) Maybe[V] {
	if index, found := dictSearch(d, key, less); found {
		return Something(d.Entries[index].Value)
	}
	return Nothing[V]()
}

func DictMember[K any, V any](d Dict[K, V], key K, less func(K, K) bool) bool {
	_, found := dictSearch(d, key, less)
	return found
}

// DictInsert replaces any existing entry for key. It is a WRITER, so it allocates
// rather than touching the caller's entries.
func DictInsert[K any, V any](d Dict[K, V], key K, value V, less func(K, K) bool) Dict[K, V] {
	index, found := dictSearch(d, key, less)
	if found {
		entries := make([]DictEntry[K, V], len(d.Entries))
		copy(entries, d.Entries)
		entries[index] = DictEntry[K, V]{Key: key, Value: value}
		return Dict[K, V]{Entries: entries}
	}
	entries := make([]DictEntry[K, V], 0, len(d.Entries)+1)
	entries = append(entries, d.Entries[:index]...)
	entries = append(entries, DictEntry[K, V]{Key: key, Value: value})
	entries = append(entries, d.Entries[index:]...)
	return Dict[K, V]{Entries: entries}
}

func DictRemove[K any, V any](d Dict[K, V], key K, less func(K, K) bool) Dict[K, V] {
	index, found := dictSearch(d, key, less)
	if !found {
		return d
	}
	entries := make([]DictEntry[K, V], 0, len(d.Entries)-1)
	entries = append(entries, d.Entries[:index]...)
	entries = append(entries, d.Entries[index+1:]...)
	return Dict[K, V]{Entries: entries}
}

// sameKey is equality derived from the ordering the emitter supplies: neither key
// orders before the other.
func sameKey[K any](left, right K, less func(K, K) bool) bool {
	return !less(left, right) && !less(right, left)
}

// DictKeys, DictValues, and DictToList all iterate in key order, so a Tesl program's
// output does not depend on which backend ran it or on Go's map seed.
func DictKeys[K any, V any](d Dict[K, V]) []K {
	keys := make([]K, len(d.Entries))
	for index, entry := range d.Entries {
		keys[index] = entry.Key
	}
	return keys
}

func DictValues[K any, V any](d Dict[K, V]) []V {
	values := make([]V, len(d.Entries))
	for index, entry := range d.Entries {
		values[index] = entry.Value
	}
	return values
}

func DictToList[K any, V any](d Dict[K, V]) []Tuple2[K, V] {
	pairs := make([]Tuple2[K, V], len(d.Entries))
	for index, entry := range d.Entries {
		pairs[index] = Tuple2[K, V]{Tuple2First: entry.Key, Tuple2Second: entry.Value}
	}
	return pairs
}

// DictFromList lets LATER duplicates win, matching tesl/dict.rkt's `for/hash`.
//
// Sorted once rather than inserted one at a time: n inserts would be O(n²), where a
// stable sort plus a dedup pass is O(n log n). Stability is what makes "later wins"
// well defined — equal keys keep their input order, so the last of each run is the
// one to keep.
func DictFromList[K any, V any](pairs []Tuple2[K, V], less func(K, K) bool) Dict[K, V] {
	entries := make([]DictEntry[K, V], len(pairs))
	for index, pair := range pairs {
		entries[index] = DictEntry[K, V]{Key: pair.Tuple2First, Value: pair.Tuple2Second}
	}
	slices.SortStableFunc(entries, func(left, right DictEntry[K, V]) int {
		switch {
		case less(left.Key, right.Key):
			return -1
		case less(right.Key, left.Key):
			return 1
		default:
			return 0
		}
	})
	// Compacts in place: `entries` was just allocated here, so nothing else can see it,
	// and each write lands at an index at or below the one being read.
	kept := entries[:0]
	for index := 0; index < len(entries); index++ {
		last := index
		for last+1 < len(entries) && sameKey(entries[last].Key, entries[last+1].Key, less) {
			last++
		}
		kept = append(kept, entries[last])
		index = last
	}
	return Dict[K, V]{Entries: kept}
}

// DictEqualBy compares two dicts entry by entry. Since both are kept in key order, a
// single pass suffices — no lookup per key. Key and value comparisons are supplied by
// the emitter, which knows both concrete types at the comparison site.
func DictEqualBy[K any, V any](
	left, right Dict[K, V], keyEqual func(K, K) bool, valueEqual func(V, V) bool,
) bool {
	if len(left.Entries) != len(right.Entries) {
		return false
	}
	for index := range left.Entries {
		if !keyEqual(left.Entries[index].Key, right.Entries[index].Key) {
			return false
		}
		if !valueEqual(left.Entries[index].Value, right.Entries[index].Value) {
			return false
		}
	}
	return true
}

// stringKeyLess is the ordering a String-keyed Dict is built with — the comparator the emitter
// passes at every `Dict.lookup` on String keys. It lives here rather than with the HTTP request
// snapshot that first needed it: `Tesl.JWT`'s claims are a String-keyed Dict too, and a program
// that signs a token need not serve HTTP.
func stringKeyLess(left, right string) bool { return left < right }

// DictSingleton is `Dict.singleton`: the one-entry dict, which is how a claims dict or a
// single-key lookup table is usually written.
func DictSingleton[K any, V any](key K, value V) Dict[K, V] {
	return Dict[K, V]{Entries: []DictEntry[K, V]{{Key: key, Value: value}}}
}

// DictRequireKey is `check Dict.requireKey key d`: it answers the SAME dict, and what a caller
// gains is the `HasKey` proof that makes `Dict.get` reachable. The proof erases here, so what
// survives is the rejection — a 400, because a missing key in a request-shaped dict is bad input
// rather than a broken program.
func DictRequireKey[K any, V any](d Dict[K, V], key K, less func(K, K) bool) Check[Dict[K, V]] {
	if _, found := dictSearch(d, key, less); found {
		return Accept(d)
	}
	return Reject[Dict[K, V]](400, fmt.Sprintf("expected key %v to be present in Dict", key))
}

// DictGet is `Dict.get`: the value for a key the caller has PROVEN present. The proof is what
// makes it total, and it erases — so this traps rather than answering a zero value, which is the
// only honest thing left if a caller ever reached it without the proof.
func DictGet[K any, V any](d Dict[K, V], key K, less func(K, K) bool) V {
	if index, found := dictSearch(d, key, less); found {
		return d.Entries[index].Value
	}
	panic(fmt.Sprintf("Dict.get: key %v is not present — a `check Dict.requireKey` must prove it "+
		"first", key))
}
