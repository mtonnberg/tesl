package teslrt

import (
	"github.com/jackc/pgx/v5"
)

// The query dispatchers for an entity of a Postgres-backed database.
//
// Each takes BOTH forms of the same query — the Go predicate the in-memory store needs and the
// statement the server needs — and runs whichever the binding selects (see database.go). They
// exist only for entities a `backend: Postgres` database manages; a Memory-backed entity emits
// the plain `Table*` call directly, so nothing about a memory-only program changes.
//
// WHY THE ARGUMENTS ARE A THUNK. Both forms sit at the same call site, which is what keeps them
// from drifting apart — but only one of them RUNS. Were the arguments a plain slice they would
// be evaluated on the way in even when the memory path is taken, and a `where` operand that
// reads the clock, draws a random value or fails a check would then run where the memory-only
// emission never ran it. The thunk is what makes "emitted twice" mean "evaluated once, on the
// path that is taken".
//
// The statement's TEXT never contains a value: every operand is a `$n` placeholder, so nothing
// a request sends can change what a statement SAYS.
type PgPlan struct {
	SQL string
	// Args is nil for a statement with no placeholders.
	Args func() []any
}

// PgSql is the constructor the emitter calls. A function rather than a struct literal because
// gofmt aligns the keys of a multi-line composite literal and breaks the alignment run at a
// nested multi-line value; a call with the argument thunk last is stable at every size.
func PgSql(statement string, args func() []any) PgPlan {
	return PgPlan{SQL: statement, Args: args}
}

func (plan PgPlan) arguments() []any {
	if plan.Args == nil {
		return nil
	}
	return plan.Args()
}

// DbSelect is `select … [order …] [limit …] [offset …]`. `less` is nil when the query has no
// order clause; on the server side the ordering and the range are already in the statement.
func DbSelect[Row any](database *Database, table *Table[Row], match func(Row) bool,
	less func(Row, Row) bool, offset, limit int, plan PgPlan,
	scan func(pgx.CollectableRow) (Row, error)) []Row {
	if connection := database.bound(); connection != nil {
		return PgQuery(connection, plan.SQL, plan.arguments(), scan)
	}
	if less == nil {
		return TableSelectRange(table, match, offset, limit)
	}
	return TableSelectSorted(table, match, less, offset, limit)
}

// DbSelectOne is `selectOne`: the statement carries `limit 1`, so "no row" is the only thing
// left to decide and both paths decide it the same way.
func DbSelectOne[Row any](database *Database, table *Table[Row], match func(Row) bool,
	less func(Row, Row) bool, plan PgPlan,
	scan func(pgx.CollectableRow) (Row, error)) Maybe[Row] {
	if connection := database.bound(); connection != nil {
		return PgQueryOne(connection, plan.SQL, plan.arguments(), scan)
	}
	if less == nil {
		return TableSelectOne(table, match)
	}
	return TableSelectOneSorted(table, match, less)
}

// DbCount is `selectCount`. The server counts in the database rather than shipping rows to be
// counted here, which is the whole reason an aggregate is a separate query shape.
func DbCount[Row any](database *Database, table *Table[Row], match func(Row) bool,
	plan PgPlan) Int {
	if connection := database.bound(); connection != nil {
		return PgCount(connection, plan.SQL, plan.arguments())
	}
	return TableCount(table, match)
}

// DbSum is `selectSum` over a scalar column. The statement is `coalesce(sum(col), 0)`, so a
// sum over no rows is zero on both paths rather than NULL on one of them.
func DbSum[Row any, Value any](database *Database, table *Table[Row], match func(Row) bool,
	project func(Row) Value, combine func(Value, Value) Value, zero Value, plan PgPlan,
	scan func(pgx.Row) (Value, error)) Value {
	if connection := database.bound(); connection != nil {
		return PgScalar(connection, plan.SQL, plan.arguments(), scan)
	}
	return TableFold(table, match, project, combine, zero)
}

// DbSumMoney is `selectSum` over a MONEY column, whose two refusals (an empty row set has no
// currency for its zero; two currencies have no common total) need two more facts than the sum
// itself. Both come back in ONE statement — `sum`, `count(distinct currency)`, `min(currency)`
// — which is the shape `dsl/sql.rkt` uses, so neither path makes a second pass over the rows.
func DbSumMoney[Row any](database *Database, table *Table[Row], match func(Row) bool,
	project func(Row) Money, entity, field string, plan PgPlan) Money {
	if connection := database.bound(); connection != nil {
		return PgSumMoney(connection, plan.SQL, plan.arguments(), entity, field)
	}
	return TableSumMoney(table, match, project, entity, field)
}

// DbExtreme is `selectMax` / `selectMin`: `max(col)` / `min(col)` on the server, and the same
// `Maybe` on both paths, since SQL's aggregate over no rows is NULL where Tesl says Nothing.
func DbExtreme[Row any, Value any](database *Database, table *Table[Row], match func(Row) bool,
	project func(Row) Value, better func(Value, Value) bool, plan PgPlan,
	scan func(pgx.Row) (Maybe[Value], error)) Maybe[Value] {
	if connection := database.bound(); connection != nil {
		return PgScalar(connection, plan.SQL, plan.arguments(), scan)
	}
	return TableExtreme(table, match, project, better)
}

// DbInsert is `insert`. The duplicate-key refusal is the SERVER's on the Postgres path — the
// primary key column carries the constraint — and the emitted `conflicts` comparison on the
// memory path, which is what makes the two agree about which programs run.
//
// The arguments are read off the ROW rather than emitted a second time from the same field
// expressions: a row whose `createdAt` is `Time.nowMillis()` would otherwise be STORED with one
// instant and ANSWERED with another.
func DbInsert[Row any](database *Database, table *Table[Row], entity string, row Row,
	conflicts func(Row, Row) bool, statement string, bind func(Row) []any,
	unique ...UniqueIndex[Row]) Row {
	if connection := database.bound(); connection != nil {
		// A declared `unique index` is a real index on the server, created by the bootstrap,
		// so the constraint is enforced where the rows are rather than twice.
		PgExec(connection, statement, bind(row))
		return row
	}
	return TableInsert(table, entity, row, conflicts, unique...)
}

// DbInsertMany inserts in order. One statement per row rather than a multi-row VALUES list, so
// a row conflicting with an EARLIER row of the same batch is refused exactly where it would be
// if the two had been inserted separately — Racket's `insert-many!` is a loop over
// `insert-one!`, and a single statement would instead fail the whole batch at a different point.
// The rows are only known at run time, so the statement is fixed and its ARGUMENTS are read off
// each row by the emitter's binder — the one place in this file where a plan cannot be a value.
func DbInsertMany[Row any](database *Database, table *Table[Row], entity string, rows []Row,
	conflicts func(Row, Row) bool, statement string, bind func(Row) []any,
	unique ...UniqueIndex[Row]) struct{} {
	if connection := database.bound(); connection != nil {
		for _, row := range rows {
			PgExec(connection, statement, bind(row))
		}
		return struct{}{}
	}
	return TableInsertMany(table, entity, rows, conflicts, unique...)
}

// DbUpdate is `update … set …`. Nothing is reported back: a plain update is a statement.
func DbUpdate[Row any](database *Database, table *Table[Row], match func(Row) bool,
	apply func(Row) Row, plan PgPlan, unique ...UniqueIndex[Row]) struct{} {
	if connection := database.bound(); connection != nil {
		PgExec(connection, plan.SQL, plan.arguments())
		return struct{}{}
	}
	return TableUpdate(table, match, apply, unique...)
}

// DbUpdateReturnOne is `updateAndReturnOne`: the statement carries `returning`, and a predicate
// that matched nothing is a failure on both paths rather than a zero value.
func DbUpdateReturnOne[Row any](database *Database, table *Table[Row], match func(Row) bool,
	apply func(Row) Row, plan PgPlan, scan func(pgx.CollectableRow) (Row, error),
	unique ...UniqueIndex[Row]) Row {
	if connection := database.bound(); connection != nil {
		updated := PgQuery(connection, plan.SQL, plan.arguments(), scan)
		if len(updated) == 0 {
			panic("updateAndReturnOne: no row matched")
		}
		return updated[0]
	}
	return TableUpdateReturnOne(table, match, apply, unique...)
}

// DbDelete is `delete`.
func DbDelete[Row any](database *Database, table *Table[Row], match func(Row) bool,
	plan PgPlan) struct{} {
	if connection := database.bound(); connection != nil {
		PgExec(connection, plan.SQL, plan.arguments())
		return struct{}{}
	}
	return TableDelete(table, match)
}

// DbTruncate empties an entity's store, for a test block that starts from an empty one.
func DbTruncate[Row any](database *Database, table *Table[Row], tableName string) {
	if connection := database.bound(); connection != nil {
		PgTruncate(connection, tableName)
		return
	}
	TableTruncate(table)
}

// DbDeleteResult is `deleteAndReturnResult`. On the server the count comes back from the
// statement's own tag rather than from a second query, so the rows are walked once on either
// path.
func DbDeleteResult[Row any](database *Database, table *Table[Row], match func(Row) bool,
	plan PgPlan) DeleteResult {
	if connection := database.bound(); connection != nil {
		removed := PgExec(connection, plan.SQL, plan.arguments())
		if removed == 0 {
			return NoRowDeleted()
		}
		return RowsDeleted(FromInt64(removed))
	}
	return TableDeleteResult(table, match)
}
