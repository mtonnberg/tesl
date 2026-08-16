package teslrt

import (
	"fmt"
	"sort"
	"strings"
	"sync"
)

// An in-memory table, the `backend: Memory` store.
//
// Rows are held as VALUES, and every read returns a copy of the slice header's contents
// rather than the table's own storage — the same "only writers allocate, readers may not
// alias the store" rule list.go states, applied here because a table is mutable and long
// lived where a Tesl list is neither.
//
// The mutex is not decoration: an HTTP server serves each request on its own goroutine, so
// two handlers touching the same table race by construction. The gates run `go test -race`
// on emitted code, which is what would catch a missing lock.
type Table[Row any] struct {
	mutex sync.RWMutex
	rows  []Row
}

func NewTable[Row any]() *Table[Row] {
	return &Table[Row]{}
}

// TableInsert stores a row, rejecting one whose primary key is already present —
// `conflicts(existing, inserted)` compares the two keys, since their type is known only
// to the emitter. The Racket memory backend keys its store BY the primary key and raises
// on a duplicate, so this is parity rather than an extra: a table that silently accepted
// two rows with one key would answer `selectOne` differently on the two backends.
func TableInsert[Row any](table *Table[Row], entity string, row Row, conflicts func(Row, Row) bool,
	unique ...UniqueIndex[Row]) Row {
	table.mutex.Lock()
	defer table.mutex.Unlock()
	table.checkUniqueLocked(entity, row, unique, -1)
	table.insertLocked(entity, row, conflicts)
	return row
}

// A declared `unique index [a, b]`. It is an INVARIANT rather than a performance hint, so the
// in-memory store enforces it: the whole point of that store is that a test fails the way
// production fails, and skipping the check would let `tesl test` pass on data PostgreSQL
// rejects. On a Postgres-backed entity the SERVER enforces it — the bootstrap creates the
// index — so the check here is the memory path's alone.
type UniqueIndex[Row any] struct {
	// Entity as the declaration names it, which is what the refusal names.
	Entity string
	// Columns as the declaration lists them, which is what the refusal names.
	Columns []string
	// Constrained is false when the row holds a NULL in an indexed column: two NULLs are not
	// equal, so such a row is unconstrained. PostgreSQL's rule, and Racket's.
	Constrained func(Row) bool
	Same        func(Row, Row) bool
	// Describe renders the indexed values for the refusal.
	Describe func(Row) string
}

// UniqueIndexOf is what a declaration emits. A constructor rather than a struct literal for
// the reason `NewDatabase` is one: gofmt ALIGNS the keys of a multi-line composite literal and
// breaks the alignment run at a nested multi-line value, a rule the emitter would have to
// reproduce exactly at every shape. A call with one argument per line is stable at every size.
func UniqueIndexOf[Row any](entity string, columns []string, constrained func(Row) bool,
	same func(Row, Row) bool, describe func(Row) string) UniqueIndex[Row] {
	return UniqueIndex[Row]{
		Entity:      entity,
		Columns:     columns,
		Constrained: constrained,
		Same:        same,
		Describe:    describe,
	}
}

// The caller holds the write lock. `skip` is the position of the row being REPLACED, so an
// update never conflicts with itself; -1 skips nothing.
func (table *Table[Row]) checkUniqueLocked(entity string, row Row, indexes []UniqueIndex[Row],
	skip int) {
	for _, index := range indexes {
		if index.Constrained != nil && !index.Constrained(row) {
			continue
		}
		for position, existing := range table.rows {
			if position == skip || !index.Same(existing, row) {
				continue
			}
			panic("entity " + entity + " already contains a row with (" +
				strings.Join(index.Columns, " ") + ") = " + index.Describe(row) +
				"; the declared unique index on (" + strings.Join(index.Columns, ", ") +
				") forbids duplicates")
		}
	}
}

// TableInsertMany inserts in order, and a row conflicting with an EARLIER row of the same
// batch is rejected just as it would be if the two were inserted separately — Racket's
// insert-many! is a loop over insert-one!.
func TableInsertMany[Row any](table *Table[Row], entity string, rows []Row,
	conflicts func(Row, Row) bool, unique ...UniqueIndex[Row]) struct{} {
	table.mutex.Lock()
	defer table.mutex.Unlock()
	for _, row := range rows {
		table.checkUniqueLocked(entity, row, unique, -1)
		table.insertLocked(entity, row, conflicts)
	}
	return struct{}{}
}

// The caller holds the write lock.
func (table *Table[Row]) insertLocked(entity string, row Row, conflicts func(Row, Row) bool) {
	for _, existing := range table.rows {
		if conflicts(existing, row) {
			panic(fmt.Sprintf("insert: entity %s already contains a row with that primary key", entity))
		}
	}
	table.rows = append(table.rows, row)
}

// TableSelectOne returns the FIRST row matching, in insertion order. Tesl's `selectOne`
// yields `Maybe`, so "no row" is a value rather than an error.
func TableSelectOne[Row any](table *Table[Row], match func(Row) bool) Maybe[Row] {
	table.mutex.RLock()
	defer table.mutex.RUnlock()
	for _, row := range table.rows {
		if match(row) {
			return Something(row)
		}
	}
	return Nothing[Row]()
}

func TableSelect[Row any](table *Table[Row], match func(Row) bool) []Row {
	table.mutex.RLock()
	defer table.mutex.RUnlock()
	out := make([]Row, 0, len(table.rows))
	for _, row := range table.rows {
		if match(row) {
			out = append(out, row)
		}
	}
	return out
}

// An aggregate walks the rows in place: it needs no copy of them, and on the Memory store
// it is the whole implementation. On a SQL backend an aggregate must instead become a
// `SELECT COUNT/SUM/MAX(...) ... WHERE ...` — the work belongs in the database, and the
// query structure to build it from is the same recovered seed. Nothing here should be
// carried over to that path.
func TableCount[Row any](table *Table[Row], match func(Row) bool) Int {
	table.mutex.RLock()
	defer table.mutex.RUnlock()
	matched := 0
	for _, row := range table.rows {
		if match(row) {
			matched++
		}
	}
	return FromInt64(int64(matched))
}

// TableSelectRange is `limit` / `offset` without an `order` clause: rows come back in
// insertion order, which is the order the un-ordered Racket path yields as well. A
// negative `limit` means "no limit".
func TableSelectRange[Row any](table *Table[Row], match func(Row) bool, offset, limit int) []Row {
	return sliceRange(TableSelect(table, match), offset, limit)
}

// TableSelectSorted is `order by`, plus any `limit`/`offset` applied after the sort.
// `less` reports strictly-before, and the sort is STABLE, so rows comparing equal keep
// their insertion order.
func TableSelectSorted[Row any](table *Table[Row], match func(Row) bool, less func(Row, Row) bool, offset, limit int) []Row {
	rows := TableSelect(table, match)
	sort.SliceStable(rows, func(left, right int) bool { return less(rows[left], rows[right]) })
	return sliceRange(rows, offset, limit)
}

// TableSelectOneSorted is `selectOne … order …`: the first row after sorting.
func TableSelectOneSorted[Row any](table *Table[Row], match func(Row) bool, less func(Row, Row) bool) Maybe[Row] {
	rows := TableSelectSorted(table, match, less, 0, 1)
	if len(rows) == 0 {
		return Nothing[Row]()
	}
	return Something(rows[0])
}

// TableFold is the scalar aggregate (`selectSum`): the matching rows' projections
// combined left to right from `zero`, so an empty table yields `zero` — the same answer
// SQL's SUM-over-no-rows gives once Tesl has typed it as the column type.
func TableFold[Row any, Value any](table *Table[Row], match func(Row) bool, project func(Row) Value, combine func(Value, Value) Value, zero Value) Value {
	table.mutex.RLock()
	defer table.mutex.RUnlock()
	total := zero
	for _, row := range table.rows {
		if match(row) {
			total = combine(total, project(row))
		}
	}
	return total
}

// TableSumMoney is `selectSum` over a MONEY column. It is not a `TableFold` because the fold's
// zero would need a currency before any row has been seen; instead the currency is adopted from
// the first matching row and every later row is checked against it, in ONE pass over the same
// rows under the same read lock — nothing is materialised.
//
// The two refusals are Racket's (`money-sum-result`), and both are about answering honestly
// rather than plausibly: a total over no rows has no currency to carry (`$0.00` would be a
// guess), and a total across currencies needs a rate, which is dated data a SUM may not invent.
func TableSumMoney[Row any](table *Table[Row], match func(Row) bool, project func(Row) Money,
	entity, field string) Money {
	table.mutex.RLock()
	defer table.mutex.RUnlock()
	total := FromInt64(0)
	var currency Currency
	distinct := map[string]struct{}{}
	for _, row := range table.rows {
		if !match(row) {
			continue
		}
		amount := project(row)
		if len(distinct) == 0 {
			currency = amount.Currency
		}
		distinct[amount.Currency.Code] = struct{}{}
		total = Add(total, amount.MinorUnits)
	}
	return MoneySumResult(entity, field, total, currency, len(distinct))
}

// MoneySumResult is the rule both stores answer a Money sum by, so the two cannot phrase a
// refusal differently: the counted currencies decide, and the wording is Racket's
// (`money-sum-result`) down to the count it names.
func MoneySumResult(entity, field string, total Int, currency Currency, distinct int) Money {
	if distinct == 0 {
		panic("field " + field + " on entity " + entity +
			": cannot sum Money over an empty row set (no currency for the zero total);" +
			" guard with a count first")
	}
	if distinct > 1 {
		panic("field " + field + " on entity " + entity +
			": cannot sum Money across mixed currencies (found " + FromInt64(int64(distinct)).String() +
			"); filter by currency first")
	}
	return Money{MinorUnits: total, Currency: currency}
}

// TableExtreme is `selectMax` / `selectMin`: the projection of the matching rows that no
// other beats, where `better(candidate, best)` reports that the candidate wins.
//
// The answer is a `Maybe`: with no matching row there is no value of the column's type to
// return, and unlike `selectSum` there is no identity to fall back on. Racket's aggregates
// answer `Nothing` in the same case.
func TableExtreme[Row any, Value any](table *Table[Row], match func(Row) bool, project func(Row) Value, better func(Value, Value) bool) Maybe[Value] {
	table.mutex.RLock()
	defer table.mutex.RUnlock()
	var best Value
	found := false
	for _, row := range table.rows {
		if !match(row) {
			continue
		}
		candidate := project(row)
		if !found || better(candidate, best) {
			best = candidate
			found = true
		}
	}
	if !found {
		return Nothing[Value]()
	}
	return Something(best)
}

// SqlLike is the `like` / `ilike` predicate: `%` matches any run of characters and `_`
// exactly one, and the whole value must match. It is a direct matcher rather than a
// translation to a regular expression, so a pattern can never inject one.
func SqlLike(value, pattern string, foldCase bool) bool {
	if foldCase {
		value = strings.ToLower(value)
		pattern = strings.ToLower(pattern)
	}
	text := []rune(value)
	glob := []rune(pattern)
	// Standard backtracking match: `star` remembers where the last `%` was, so a failure
	// after it resumes by letting that `%` consume one more character.
	textAt, globAt, star, retry := 0, 0, -1, 0
	for textAt < len(text) {
		switch {
		case globAt < len(glob) && (glob[globAt] == '_' || glob[globAt] == text[textAt]):
			textAt++
			globAt++
		case globAt < len(glob) && glob[globAt] == '%':
			star = globAt
			globAt++
			retry = textAt
		case star >= 0:
			globAt = star + 1
			retry++
			textAt = retry
		default:
			return false
		}
	}
	for globAt < len(glob) && glob[globAt] == '%' {
		globAt++
	}
	return globAt == len(glob)
}

func sliceRange[Row any](rows []Row, offset, limit int) []Row {
	if offset >= len(rows) {
		return []Row{}
	}
	rows = rows[offset:]
	if limit >= 0 && limit < len(rows) {
		rows = rows[:limit]
	}
	return rows
}

// TableDelete removes every matching row. `delete` is a statement in Tesl, so the count
// goes nowhere; TableDeleteCount is the form that reports it.
func TableDelete[Row any](table *Table[Row], match func(Row) bool) struct{} {
	TableDeleteCount(table, match)
	return struct{}{}
}

func TableDeleteCount[Row any](table *Table[Row], match func(Row) bool) Int {
	table.mutex.Lock()
	defer table.mutex.Unlock()
	kept := make([]Row, 0, len(table.rows))
	removed := 0
	for _, row := range table.rows {
		if match(row) {
			removed++
			continue
		}
		kept = append(kept, row)
	}
	table.rows = kept
	return FromInt64(int64(removed))
}

// TableUpdate replaces every matching row with the result of `apply`. Like `delete`, a
// plain `update` is a statement, so nothing is reported back.
func TableUpdate[Row any](table *Table[Row], match func(Row) bool, apply func(Row) Row,
	unique ...UniqueIndex[Row]) struct{} {
	table.mutex.Lock()
	defer table.mutex.Unlock()
	for index, row := range table.rows {
		if !match(row) {
			continue
		}
		updated := apply(row)
		table.checkUniqueLocked(uniqueEntity(unique), updated, unique, index)
		table.rows[index] = updated
	}
	return struct{}{}
}

// The entity NAME a unique-index refusal carries. `update` does not take one — nothing else in
// its emission needs it — so it travels on the index, where the refusal is built.
func uniqueEntity[Row any](indexes []UniqueIndex[Row]) string {
	if len(indexes) == 0 {
		return ""
	}
	return indexes[0].Entity
}

// TableUpdateReturnOne is `updateAndReturnOne`: it yields the FIRST updated row, and
// traps when the predicate matched nothing — Racket takes the `car` of the updated rows,
// which errors on an empty list, so "no row updated" is a failure on both backends rather
// than a zero value.
func TableUpdateReturnOne[Row any](table *Table[Row], match func(Row) bool, apply func(Row) Row,
	unique ...UniqueIndex[Row]) Row {
	table.mutex.Lock()
	defer table.mutex.Unlock()
	for index, row := range table.rows {
		if !match(row) {
			continue
		}
		updated := apply(row)
		table.checkUniqueLocked(uniqueEntity(unique), updated, unique, index)
		table.rows[index] = updated
		return updated
	}
	panic("updateAndReturnOne: no row matched")
}

// TableTruncate empties the table, for a test that wants a fresh store.
func TableTruncate[Row any](table *Table[Row]) {
	table.mutex.Lock()
	defer table.mutex.Unlock()
	table.rows = nil
}

// `deleteAndReturnResult` answers a `DeleteResult`, which is `NoRowDeleted` or `RowsDeleted n`.
// It is a runtime-provided ADT for the reason `Maybe` is: it crosses module boundaries, so it
// cannot be emitted once per module that mentions it.
//
// The distinction it draws is the one a plain count does not: deleting nothing is a different
// OUTCOME from deleting rows, and a caller that has to act on "nothing matched" reads it as a
// case rather than as a comparison with zero.
type DeleteResultTag int

const (
	DeleteResultNoRowDeleted DeleteResultTag = iota
	DeleteResultRowsDeleted
)

type DeleteResult struct {
	Tag              DeleteResultTag
	RowsDeletedCount Int
}

func NoRowDeleted() DeleteResult {
	return DeleteResult{Tag: DeleteResultNoRowDeleted}
}

func RowsDeleted(count Int) DeleteResult {
	return DeleteResult{Tag: DeleteResultRowsDeleted, RowsDeletedCount: count}
}

// TableDeleteResult is `deleteAndReturnResult` over the in-memory store.
func TableDeleteResult[Row any](table *Table[Row], match func(Row) bool) DeleteResult {
	removed := TableDeleteCount(table, match)
	if Compare(removed, FromInt64(0)) == 0 {
		return NoRowDeleted()
	}
	return RowsDeleted(removed)
}
