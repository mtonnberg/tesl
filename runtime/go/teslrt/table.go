package teslrt

import (
	"bytes"
	"fmt"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
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
//
// THE LOCK MODEL. No user code ever runs under the lock. A `where` operand or a `set` value is
// an arbitrary Tesl expression, and it may itself query THIS table (`set price = selectCount
// …`); `sync.RWMutex` is not reentrant, so a predicate evaluated under the read lock wedged the
// moment a writer queued behind it, and an `apply` evaluated under the write lock wedged at
// once. So:
//
//   - `rows` is IMMUTABLE once published: a writer never assigns into an element of the
//     published slice and never shortens it in place — it appends (writing only past every
//     published length) or installs a fresh slice. A reader therefore takes the slice header
//     under the read lock, releases it, and evaluates on that snapshot with no lock held.
//   - `version` counts every publication. A writer evaluates `match`/`apply` on a snapshot with
//     no lock held, then takes the write lock and installs the result ONLY if the version is
//     still the one it read; otherwise another writer got in between and the whole operation is
//     recomputed against the new rows, a bounded number of times. The unique-index check stays
//     under the write lock, where the rows it checks against cannot move.
//
// The optimistic retry re-evaluates `match`/`apply` on the new rows, so an operand with a side
// effect (a clock read, an enqueue) may run more than once — only under contention on one
// table, which is also when PostgreSQL would have re-evaluated a serialisation failure.
type Table[Row any] struct {
	mutex   sync.RWMutex
	rows    []Row
	version uint64
}

func NewTable[Row any]() *Table[Row] {
	return &Table[Row]{}
}

// snapshot is what a read starts from: the published rows and the version they belong to. The
// slice is safe to walk with no lock held because no writer mutates a published element.
func (table *Table[Row]) snapshot() ([]Row, uint64) {
	table.mutex.RLock()
	defer table.mutex.RUnlock()
	return table.rows, table.version
}

// publishLocked installs `next` as the table's rows. The caller holds the write lock and
// `next` either IS the current slice grown by append or a fresh slice — never the current
// slice with an element reassigned, which would race a reader walking its snapshot.
//
// The rows being replaced are recorded for rollback first when a Memory `transaction { }` is
// open on this goroutine (see database.go), so the FIRST write a transaction makes to a table
// is what a trap restores it to.
func (table *Table[Row]) publishLocked(next []Row) {
	if memoryTransactionsOpen.Load() > 0 {
		if transaction := currentMemoryTransaction(); transaction != nil {
			recordForRollback(transaction, table, table.rows)
		}
	}
	table.rows = next
	table.version++
}

// restoreRows is the rollback: the rows a transaction first saw, installed as a FRESH slice.
// A copy rather than the saved header, because appends made during the transaction may have
// written into the saved header's spare capacity and a reader may hold a snapshot that covers
// those slots — reusing the array would let a later append overwrite what that reader sees.
func (table *Table[Row]) restoreRows(saved []Row) {
	table.mutex.Lock()
	defer table.mutex.Unlock()
	table.rows = append(make([]Row, 0, len(saved)), saved...)
	table.version++
}

// How many times a writer recomputes against rows another writer changed under it before
// giving up. Each retry needs a DIFFERENT writer to have published in the window between the
// snapshot and the write lock; exhausting it means the table is being rewritten continuously.
const tableWriteRetries = 1000

func tableWriteContended(operation string) string {
	return "database: " + operation + " on the Memory store gave up after " +
		strconv.Itoa(tableWriteRetries) + " concurrent modifications of the table; " +
		"another writer is changing it continuously"
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
	checkUniqueIn(table.rows, entity, row, unique, -1)
	table.publishLocked(insertInto(table.rows, entity, row, conflicts))
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

// checkUniqueIn checks `row` against `rows`, which are the rows the write is about to publish
// against — the caller holds the write lock, so they cannot move. `skip` is the position of the
// row being REPLACED, so an update never conflicts with itself; -1 skips nothing.
func checkUniqueIn[Row any](rows []Row, entity string, row Row, indexes []UniqueIndex[Row],
	skip int) {
	for _, index := range indexes {
		if index.Constrained != nil && !index.Constrained(row) {
			continue
		}
		for position, existing := range rows {
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
		// Published one at a time, so the rows before a conflicting one STAY when it traps —
		// which is what one insert at a time would have left behind.
		checkUniqueIn(table.rows, entity, row, unique, -1)
		table.publishLocked(insertInto(table.rows, entity, row, conflicts))
	}
	return struct{}{}
}

// insertInto is `rows` with `row` appended, once no existing row shares its primary key. The
// caller holds the write lock. Appending is safe under the immutable-when-published rule
// because it writes only PAST every length a reader may hold.
func insertInto[Row any](rows []Row, entity string, row Row, conflicts func(Row, Row) bool) []Row {
	for _, existing := range rows {
		if conflicts(existing, row) {
			panic(fmt.Sprintf("insert: entity %s already contains a row with that primary key", entity))
		}
	}
	return append(rows, row)
}

// TableSelectOne returns the FIRST row matching, in insertion order. Tesl's `selectOne`
// yields `Maybe`, so "no row" is a value rather than an error.
func TableSelectOne[Row any](table *Table[Row], match func(Row) bool) Maybe[Row] {
	rows, _ := table.snapshot()
	for _, row := range rows {
		if match(row) {
			return Something(row)
		}
	}
	return Nothing[Row]()
}

func TableSelect[Row any](table *Table[Row], match func(Row) bool) []Row {
	rows, _ := table.snapshot()
	out := make([]Row, 0, len(rows))
	for _, row := range rows {
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
	rows, _ := table.snapshot()
	matched := 0
	for _, row := range rows {
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
	rows, _ := table.snapshot()
	total := zero
	for _, row := range rows {
		if match(row) {
			total = combine(total, project(row))
		}
	}
	return total
}

// TableSumMoney is `selectSum` over a MONEY column. It is not a `TableFold` because the fold's
// zero would need a currency before any row has been seen; instead the currency is adopted from
// the first matching row and every later row is checked against it, in ONE pass over one
// snapshot of the rows — nothing is materialised.
//
// The two refusals are Racket's (`money-sum-result`), and both are about answering honestly
// rather than plausibly: a total over no rows has no currency to carry (`$0.00` would be a
// guess), and a total across currencies needs a rate, which is dated data a SUM may not invent.
func TableSumMoney[Row any](table *Table[Row], match func(Row) bool, project func(Row) Money,
	entity, field string) Money {
	rows, _ := table.snapshot()
	total := FromInt64(0)
	var currency Currency
	distinct := map[string]struct{}{}
	for _, row := range rows {
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
	rows, _ := table.snapshot()
	var best Value
	found := false
	for _, row := range rows {
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
// exactly one, `\` makes the next character literal (`\%`, `\_`, `\\` — PostgreSQL's default
// ESCAPE), and the whole value must match. It is a direct matcher rather than a translation
// to a regular expression, so a pattern can never inject one.
//
// A pattern ending in a lone `\` is refused with PostgreSQL's own message: the server rejects
// the statement, so the Memory store must not quietly match something instead.
//
// `ilike` folds through Go's Unicode case mapping, where PostgreSQL folds by the column's
// COLLATION — under the `C` locale that is ASCII only — so non-ASCII case-insensitive matches
// may differ between the two stores. That is the server's rule, not something reproducible here.
func SqlLike(value, pattern string, foldCase bool) bool {
	if foldCase {
		value = strings.ToLower(value)
		pattern = strings.ToLower(pattern)
	}
	text := []rune(value)
	glob := likeTokens(pattern)
	// Standard backtracking match: `star` remembers where the last `%` was, so a failure
	// after it resumes by letting that `%` consume one more character.
	textAt, globAt, star, retry := 0, 0, -1, 0
	for textAt < len(text) {
		switch {
		case globAt < len(glob) && glob[globAt].matches(text[textAt]):
			textAt++
			globAt++
		case globAt < len(glob) && glob[globAt].kind == likeAnyRun:
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
	for globAt < len(glob) && glob[globAt].kind == likeAnyRun {
		globAt++
	}
	return globAt == len(glob)
}

type likeTokenKind int

const (
	likeLiteral likeTokenKind = iota
	likeAnyOne
	likeAnyRun
)

// One element of a parsed LIKE pattern: a literal character, `_`, or `%`.
type likeToken struct {
	kind    likeTokenKind
	literal rune
}

func (token likeToken) matches(character rune) bool {
	switch token.kind {
	case likeAnyOne:
		return true
	case likeLiteral:
		return token.literal == character
	case likeAnyRun:
		// A run never matches a single character here; the glob walker consumes it.
		return false
	default:
		return false
	}
}

// likeTokens parses a pattern once, so the escape is resolved BEFORE matching rather than
// re-examined at every backtrack.
func likeTokens(pattern string) []likeToken {
	runes := []rune(pattern)
	tokens := make([]likeToken, 0, len(runes))
	for at := 0; at < len(runes); at++ {
		switch runes[at] {
		case '\\':
			if at+1 >= len(runes) {
				panic("database: LIKE pattern must not end with escape character")
			}
			at++
			tokens = append(tokens, likeToken{kind: likeLiteral, literal: runes[at]})
		case '%':
			tokens = append(tokens, likeToken{kind: likeAnyRun})
		case '_':
			tokens = append(tokens, likeToken{kind: likeAnyOne})
		default:
			tokens = append(tokens, likeToken{kind: likeLiteral, literal: runes[at]})
		}
	}
	return tokens
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
	for range tableWriteRetries {
		rows, version := table.snapshot()
		// The predicate runs on the snapshot with no lock held: it may query this table.
		kept := make([]Row, 0, len(rows))
		removed := 0
		for _, row := range rows {
			if match(row) {
				removed++
				continue
			}
			kept = append(kept, row)
		}
		if table.publishIfUnchanged(version, kept) {
			return FromInt64(int64(removed))
		}
	}
	panic(tableWriteContended("delete"))
}

// publishIfUnchanged installs `next` when the table is still at `version` — the rows the caller
// computed `next` from — and reports whether it did. A false answer means another writer
// published in between and the caller recomputes.
func (table *Table[Row]) publishIfUnchanged(version uint64, next []Row) bool {
	table.mutex.Lock()
	defer table.mutex.Unlock()
	if table.version != version {
		return false
	}
	table.publishLocked(next)
	return true
}

// A replacement an update computed on its snapshot: the row at `position` becomes `row`.
type rowReplacement[Row any] struct {
	position int
	row      Row
}

// replaceIfUnchanged installs the replacements when the table is still at `version`, checking
// each replaced row against the declared unique indexes under the write lock — which is where
// the rows it is checked against cannot move — and building a FRESH slice, since assigning
// into the published one would race a reader's snapshot. Earlier replacements are visible to
// later checks, so two rows of one update swapping unique values are judged as the sequence
// they are on the server.
func (table *Table[Row]) replaceIfUnchanged(version uint64, replacements []rowReplacement[Row],
	unique []UniqueIndex[Row]) bool {
	table.mutex.Lock()
	defer table.mutex.Unlock()
	if table.version != version {
		return false
	}
	next := append(make([]Row, 0, len(table.rows)), table.rows...)
	for _, replacement := range replacements {
		checkUniqueIn(next, uniqueEntity(unique), replacement.row, unique, replacement.position)
		next[replacement.position] = replacement.row
	}
	table.publishLocked(next)
	return true
}

// TableUpdate replaces every matching row with the result of `apply`. Like `delete`, a
// plain `update` is a statement, so nothing is reported back.
func TableUpdate[Row any](table *Table[Row], match func(Row) bool, apply func(Row) Row,
	unique ...UniqueIndex[Row]) struct{} {
	for range tableWriteRetries {
		rows, version := table.snapshot()
		// `match` and `apply` run on the snapshot with no lock held: a `set` value may query
		// this very table, which under the write lock was a deadlock.
		replacements := []rowReplacement[Row]{}
		for index, row := range rows {
			if match(row) {
				replacements = append(replacements, rowReplacement[Row]{position: index, row: apply(row)})
			}
		}
		if table.replaceIfUnchanged(version, replacements, unique) {
			return struct{}{}
		}
	}
	panic(tableWriteContended("update"))
}

// The entity NAME a unique-index refusal carries. `update` does not take one — nothing else in
// its emission needs it — so it travels on the index, where the refusal is built.
func uniqueEntity[Row any](indexes []UniqueIndex[Row]) string {
	if len(indexes) == 0 {
		return ""
	}
	return indexes[0].Entity
}

// The trap both backends raise when an `updateAndReturnOne` predicate names more than one
// row. One message, so a program's `expectFail` and its operator log read the same on the
// Memory store and on Postgres. Declared HERE rather than beside the Postgres half because
// this file ships with every program and dbquery.go only with a Postgres-backed one — the
// runtime file gates are exclusion filters, and a constant used by an always-shipped file
// has to live in an always-shipped file.
const updateReturnOneAmbiguous = "updateAndReturnOne: the predicate matched more than one row; " +
	"narrow the `where` clause (the primary key or a unique index) so exactly one row is named"

// TableUpdateReturnOne is `updateAndReturnOne`: it updates the ONE row the predicate names
// and yields it. It traps when the predicate matched nothing ("no row updated" is a failure
// on both backends rather than a zero value) and it traps when the predicate matched more
// than one row — updating the first match while Postgres updated every match was a silent
// disagreement between the store tests run on and the store production runs on, so both
// now refuse the ambiguous predicate before changing anything.
func TableUpdateReturnOne[Row any](table *Table[Row], match func(Row) bool, apply func(Row) Row,
	unique ...UniqueIndex[Row]) Row {
	for range tableWriteRetries {
		rows, version := table.snapshot()
		matched := -1
		for index, row := range rows {
			if !match(row) {
				continue
			}
			if matched >= 0 {
				panic(updateReturnOneAmbiguous)
			}
			matched = index
		}
		if matched < 0 {
			panic("updateAndReturnOne: no row matched")
		}
		updated := apply(rows[matched])
		replacement := []rowReplacement[Row]{{position: matched, row: updated}}
		if table.replaceIfUnchanged(version, replacement, unique) {
			return updated
		}
	}
	panic(tableWriteContended("updateAndReturnOne"))
}

// TableTruncate empties the table, for a test that wants a fresh store.
func TableTruncate[Row any](table *Table[Row]) {
	table.mutex.Lock()
	defer table.mutex.Unlock()
	table.publishLocked(nil)
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

// TableAny reports whether any row matches. It is what an `innerJoin` becomes on the in-memory
// store: the clause filters the MAIN entity's rows to those with a counterpart, and the result
// is still a list of that entity — so it is an existence test, not a product.
//
// That reading is also why the Postgres path emits `exists (…)` rather than a real INNER JOIN:
// a join would DUPLICATE a main row for every counterpart, which a `List Order` cannot hold.
// The Racket backends disagree here — its memory store tests existence while its Postgres path
// joins — and the two Go paths agree with each other and with the declared result type.
func TableAny[Row any](table *Table[Row], match func(Row) bool) bool {
	rows, _ := table.snapshot()
	for _, row := range rows {
		if match(row) {
			return true
		}
	}
	return false
}

// TableGroupFold is the grouped aggregate: it buckets the matching rows by a key, folds
// each bucket, and answers one (key, value) pair per bucket, ORDERED BY KEY ASCENDING.
//
// The order is part of the contract rather than an accident of iteration: the Racket memory
// backend sorts its buckets and PostgreSQL's `GROUP BY … ORDER BY 1` does the same, and a
// series a chart draws is only a series if its points are in order.
//
// The key is compared through the two functions the emitter supplies rather than being used
// as a Go map key: a bucket key can be a `PosixMillis`, whose value is an arbitrary-precision
// integer and therefore not comparable with `==`. Rows are sorted by key and folded in runs,
// so no key is compared more than the sort needs.
func TableGroupFold[Row any, Key any, Value any](
	table *Table[Row],
	match func(Row) bool,
	key func(Row) Key,
	less func(Key, Key) bool,
	equal func(Key, Key) bool,
	step func(Value, Row) Value,
	zero Value,
) []Tuple2[Key, Value] {
	rows, _ := table.snapshot()
	type keyed struct {
		key Key
		row Row
	}
	matched := make([]keyed, 0, len(rows))
	for _, row := range rows {
		if match(row) {
			matched = append(matched, keyed{key: key(row), row: row})
		}
	}
	sort.SliceStable(matched, func(left, right int) bool {
		return less(matched[left].key, matched[right].key)
	})
	out := []Tuple2[Key, Value]{}
	for index := 0; index < len(matched); {
		bucket := zero
		at := index
		for ; at < len(matched) && equal(matched[at].key, matched[index].key); at++ {
			bucket = step(bucket, matched[at].row)
		}
		out = append(out, Tuple2[Key, Value]{Tuple2First: matched[index].key, Tuple2Second: bucket})
		index = at
	}
	return out
}

// TableUpsert is `upsert … onConflict [c] doUpdate [u]`: the row is inserted, unless one
// already matches on the CONFLICT columns, in which case only the UPDATE columns of that row
// are overwritten.
//
// The two halves are the Racket memory backend's, rule for rule: an existing row is found by
// its conflict columns (not by its primary key — the conflict target may be any unique
// index), the merged row is checked against the unique indexes with ITS OWN position skipped
// (updating a row must not collide with itself), and the insert path checks them with nothing
// skipped. The row that ends up stored is the answer, so a caller reads back what was
// written rather than what it asked for.
func TableUpsert[Row any](
	table *Table[Row],
	entity string,
	row Row,
	matches func(Row, Row) bool,
	merge func(Row, Row) Row,
	conflicts func(Row, Row) bool,
	unique ...UniqueIndex[Row],
) Row {
	// `matches` and `merge` are the emitter's field comparisons over two rows already in
	// hand, not Tesl expressions, so they carry no query and may run under the lock.
	table.mutex.Lock()
	defer table.mutex.Unlock()
	for position, existing := range table.rows {
		if !matches(existing, row) {
			continue
		}
		merged := merge(existing, row)
		checkUniqueIn(table.rows, entity, merged, unique, position)
		next := append(make([]Row, 0, len(table.rows)), table.rows...)
		next[position] = merged
		table.publishLocked(next)
		return merged
	}
	checkUniqueIn(table.rows, entity, row, unique, -1)
	table.publishLocked(insertInto(table.rows, entity, row, conflicts))
	return row
}

// Discard turns a value-returning call into Tesl's `Unit`. It exists for the forms the
// checker types as Unit while the runtime call still answers something — `upsert` is the
// one: the stored row is a useful thing for the runtime to hand back and a thing no Tesl
// program can name, so it is dropped here rather than in a statement the emitter would
// otherwise have to invent.
func Discard[A any](A) struct{} { return struct{}{} }

// The Memory-transaction machinery lives HERE, not in database.go, for the same reason
// `updateReturnOneAmbiguous` does: this file ships with every program and database.go only
// with a Postgres-backed one, and `publishLocked` above needs it in a Memory-only program.
// ── Memory transactions ───────────────────────────────────────────────────────
//
// The Memory store has no log to roll back from, so `transaction { }` there is ROLLBACK BY
// RESTORE: every table the body writes records, on its FIRST write inside the block, the rows it
// held before that write (table.go, `publishLocked`); a panic out of the body reinstalls those
// rows on every recorded table, then continues unwinding. Only tables the body touched pay
// anything, and the record is a slice header — the rows are immutable once published, so no
// copy is taken on the way in.
//
// WHAT THIS IS NOT. It is atomicity with respect to a trap in ONE goroutine, not isolation:
// another goroutine (a concurrent request against a Memory-backed server) sees the body's
// writes as they happen, and a write IT makes to a touched table between the body's first write
// and the rollback is undone with the body's. That is acceptable for what the Memory store is —
// the single-process dev and test store — and is the reason a Postgres-backed program's tests
// exercising isolation must run `with database`. Memory rollback is likewise single-process:
// nothing outside this process observes or participates in it.
//
// Nesting is refused exactly as the Postgres path refuses it, so a program cannot pass its tests
// with a shape that traps in production. The open transaction is keyed by goroutine, like the
// Postgres one, and for the same reason: a goroutine started inside the body does not join it.

// memoryTransaction is one open Memory `transaction { }`: the tables it has written and, per
// table, the rows to reinstall on rollback. It is touched only by the goroutine that owns it.
type memoryTransaction struct {
	recorded map[any]struct{}
	restores []func()
}

// recordForRollback remembers `rows` as what `table` held before this transaction's first write
// to it. A later write to the same table is ignored: the rollback target is the state before
// the transaction, not before the latest statement. A function rather than a method because
// the table is generic and a method cannot be.
func recordForRollback[Row any](transaction *memoryTransaction, table *Table[Row], rows []Row) {
	if _, seen := transaction.recorded[table]; seen {
		return
	}
	transaction.recorded[table] = struct{}{}
	transaction.restores = append(transaction.restores, func() { table.restoreRows(rows) })
}

var openMemoryTransactions sync.Map // goroutine id -> *memoryTransaction

// memoryTransactionsOpen lets a write skip the goroutine-id lookup entirely — the common case
// of a program with no transaction open anywhere.
var memoryTransactionsOpen atomic.Int64

func currentMemoryTransaction() *memoryTransaction {
	if found, open := openMemoryTransactions.Load(goroutineID()); open {
		if transaction, ok := found.(*memoryTransaction); ok {
			return transaction
		}
	}
	return nil
}

// WithMemoryTransaction is exported (rather than a package-private helper) because its only
// caller sits in database.go, which ships only with a Postgres-backed program — in a
// Memory-only module the function would be dead code the lint gate refuses.
func WithMemoryTransaction(body func()) {
	key := goroutineID()
	if _, nested := openMemoryTransactions.Load(key); nested {
		panic("transaction: a transaction is already open on the Memory store")
	}
	transaction := &memoryTransaction{recorded: map[any]struct{}{}}
	openMemoryTransactions.Store(key, transaction)
	memoryTransactionsOpen.Add(1)
	committed := false
	defer func() {
		openMemoryTransactions.Delete(key)
		memoryTransactionsOpen.Add(-1)
		if committed {
			return
		}
		// Most recent first, so a table written several times ends at its FIRST recorded
		// state — though `record` keeps only that one, the order also costs nothing.
		for index := len(transaction.restores) - 1; index >= 0; index-- {
			transaction.restores[index]()
		}
	}()
	body()
	committed = true
}

// goroutineID reads the id out of the goroutine's own stack header, which is the only place
// the runtime exposes it. The header's shape ("goroutine 17 [running]:") is fixed by
// `runtime.Stack` itself; an unreadable one answers 0, which is a key like any other — every
// goroutine that fails to parse would share one transaction, and none can, because the parse
// cannot fail for a header this function is looking at.
func goroutineID() uint64 {
	var header [64]byte
	written := runtime.Stack(header[:], false)
	fields := bytes.Fields(header[:written])
	if len(fields) < 2 {
		return 0
	}
	id, err := strconv.ParseUint(string(fields[1]), 10, 64)
	if err != nil {
		return 0
	}
	return id
}
