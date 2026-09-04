package teslrt

import (
	"fmt"
	"strings"

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
	Args    func() []any
	Capture func(int)
	// Probe is a second statement a dispatcher may run to EXPLAIN an empty result — for
	// `updateAndReturnOne`, the `select count(*)` over the same predicate that tells "no row
	// matched" from "more than one row matched". Empty for every other plan.
	Probe     string
	ProbeArgs func() []any
}

// PgSql is the constructor the emitter calls. A function rather than a struct literal because
// gofmt aligns the keys of a multi-line composite literal and breaks the alignment run at a
// nested multi-line value; a call with the argument thunk last is stable at every size.
func PgSql(statement string, args func() []any) PgPlan {
	return PgPlan{SQL: statement, Args: args}
}

// PgSqlProbed is `PgSql` plus the explaining probe (see PgPlan.Probe).
func PgSqlProbed(statement string, args func() []any, probe string, probeArgs func() []any) PgPlan {
	return PgPlan{SQL: statement, Args: args, Probe: probe, ProbeArgs: probeArgs}
}

func (plan PgPlan) probeArguments() []any {
	if plan.ProbeArgs == nil {
		return nil
	}
	return plan.ProbeArgs()
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
		return PgQueryPlan(connection, plan, scan)
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
		return PgQueryOnePlan(connection, plan, scan)
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
		return PgCountPlan(connection, plan)
	}
	return TableCount(table, match)
}

// DbSum is `selectSum` over a scalar column. The statement is `coalesce(sum(col), 0)`, so a
// sum over no rows is zero on both paths rather than NULL on one of them.
func DbSum[Row any, Value any](database *Database, table *Table[Row], match func(Row) bool,
	project func(Row) Value, combine func(Value, Value) Value, zero Value, plan PgPlan,
	scan func(pgx.Row) (Value, error)) Value {
	if connection := database.bound(); connection != nil {
		return PgScalarPlan(connection, plan, scan)
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
		return PgSumMoneyPlan(connection, plan, entity, field)
	}
	return TableSumMoney(table, match, project, entity, field)
}

// DbExtreme is `selectMax` / `selectMin`: `max(col)` / `min(col)` on the server, and the same
// `Maybe` on both paths, since SQL's aggregate over no rows is NULL where Tesl says Nothing.
func DbExtreme[Row any, Value any](database *Database, table *Table[Row], match func(Row) bool,
	project func(Row) Value, better func(Value, Value) bool, plan PgPlan,
	scan func(pgx.Row) (Maybe[Value], error)) Maybe[Value] {
	if connection := database.bound(); connection != nil {
		return PgScalarPlan(connection, plan, scan)
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
		PgExecPlan(connection, plan)
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
		updated := pgUpdateReturnOne(connection, plan, scan)
		if len(updated) == 0 {
			panic("updateAndReturnOne: no row matched")
		}
		return updated[0]
	}
	return TableUpdateReturnOne(table, match, apply, unique...)
}

// pgUpdateReturnOne runs the emitted `update … where <pred> and (select count(*) from …
// where <pred>) = 1 returning …` statement. The count guard is what makes "one row" a
// server-side guarantee: with two or more matches the statement updates NOTHING. A first
// version selected the row by `ctid` through a scalar subquery, which raised
// cardinality_violation for the ambiguous case but MISSED the row under contention — a
// concurrent writer moves the row to a new ctid, and the outer TID scan keeps the statement's
// snapshot, so an existing row answered "no row matched" (whitebox campaign, 2026-09-02).
// The count form re-checks the predicate on the row's latest version instead. An empty
// result is then explained by the plan's probe, so the ambiguous case still gets its own
// trap — the same message the Memory table raises.
func pgUpdateReturnOne[Row any](db *PostgresDB, plan PgPlan,
	scan func(pgx.CollectableRow) (Row, error)) []Row {
	updated := PgQueryPlan(db, plan, scan)
	if len(updated) == 0 && plan.Probe != "" {
		matched, exact := PgCount(db, plan.Probe, plan.probeArguments()).Int64()
		if exact && matched > 1 {
			panic(updateReturnOneAmbiguous)
		}
	}
	return updated
}

// DbDelete is `delete`.
func DbDelete[Row any](database *Database, table *Table[Row], match func(Row) bool,
	plan PgPlan) struct{} {
	if connection := database.bound(); connection != nil {
		PgExecPlan(connection, plan)
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

// DbDeleteCount is `deleteAndReturnResult`. On the server the count comes back from the
// statement's own tag, so the rows are counted once on either path.
func DbDeleteCount[Row any](database *Database, table *Table[Row], match func(Row) bool,
	plan PgPlan) Int {
	if connection := database.bound(); connection != nil {
		return FromInt64(PgExecPlan(connection, plan))
	}
	return TableDeleteCount(table, match)
}

// DbUpsert is `upsert … onConflict [c] doUpdate [u]`. On a Postgres-backed database the SERVER
// decides the conflict — `insert … on conflict (c) do update set u = EXCLUDED.u` is one
// statement and one round trip, and the conflict target is the unique index the bootstrap
// created — so the memory path's find-then-merge has no counterpart there. Off a connection it
// is exactly that find-then-merge, which is what makes a test exercise the same program.
func DbUpsert[Row any](database *Database, table *Table[Row], entity string, row Row,
	matches func(Row, Row) bool, merge func(Row, Row) Row, conflicts func(Row, Row) bool,
	statement string, bind func(Row) []any, unique ...UniqueIndex[Row]) Row {
	if connection := database.bound(); connection != nil {
		PgExec(connection, statement, bind(row))
		return row
	}
	return TableUpsert(table, entity, row, matches, merge, conflicts, unique...)
}

// DbGroupFold is the grouped aggregate. On a Postgres-backed database the GROUPING is the
// server's — `select <key>, <agg> … group by 1 order by 1` — because shipping every row here to
// bucket it is the thing a grouped aggregate exists to avoid; the scanner reads one (key, value)
// pair per row. Off a connection it folds the in-memory table, and both answer in ascending key
// order, which is the contract rather than an accident of iteration.
func DbGroupFold[Row any, Key any, Value any](
	database *Database, table *Table[Row],
	match func(Row) bool,
	key func(Row) Key, less func(Key, Key) bool, equal func(Key, Key) bool,
	step func(Value, Row) Value, zero Value,
	plan PgGroupPlan, scan func(pgx.CollectableRow) (Tuple2[Key, Value], error),
) []Tuple2[Key, Value] {
	if connection := database.bound(); connection != nil {
		statement, arguments := plan.statement()
		return PgQuery(connection, statement, arguments, scan)
	}
	return TableGroupFold(table, match, key, less, equal, step, zero)
}

// PgGroupPlan is a grouped aggregate's statement in PIECES rather than as one string.
//
// The bucket expression depends on the ZONE, and a zone is a value the program supplies at run
// time (`minutesPerDay(zone: TimeZone)`), so the statement cannot be baked at compile time —
// `dsl/sql.rkt` composes the same one per call for the same reason. The pieces are what the
// emitter knows statically; the zone-dependent part is assembled here, so the two backends
// cannot drift on where a bucket starts.
type PgGroupPlan struct {
	// The aggregate over the group, already rendered: `count(*)`, `coalesce(sum("minutes"), 0)`.
	Aggregate string
	// The qualified, quoted table.
	Table string
	// The `where …` fragment, or "" — with its own `$1..$n` placeholders.
	Where string
	// The where fragment's arguments. The bucket's own argument follows them.
	Args []any
	// The quoted group column.
	Column string
	// "" groups by the column itself; otherwise the calendar unit (Hour|Day|Week|Month|Year).
	Unit string
	Zone PgGroupZone
}

// statement renders the plan, and the bucket expression with it.
//
// A NAMED zone hands the DST-correct work to PostgreSQL's own tzdata —
// `date_trunc(u, ts at time zone $z) at time zone $z` — which mirrors the engine's two-step
// semantics (instant → local wall clock → truncate → back), and PG's `date_trunc('week')` is
// the ISO Monday week the engine uses. A FIXED offset is integer arithmetic on the millisecond
// column for hour/day/week, and `date_trunc` on the UTC-shifted timestamp for month/year,
// because those two are calendar units rather than fixed spans.
func (plan PgGroupPlan) statement() (string, []any) {
	arguments := append([]any{}, plan.Args...)
	placeholder := func(value any) string {
		arguments = append(arguments, value)
		return fmt.Sprintf("$%d", len(arguments))
	}
	unit := strings.ToLower(plan.Unit)
	// The unit is the one part of this statement that lands in SQL TEXT rather than a parameter
	// (`date_trunc` takes a literal field name), so it is checked against the closed set the
	// emitter can produce. Nothing user-supplied reaches it today — `Time.truncHour` and its
	// four siblings are the only sources — and this is what keeps that true if a later surface
	// lets a unit come from a value.
	switch unit {
	case "", "hour", "day", "week", "month", "year":
	default:
		panic("database: " + unit + " is not a grouping unit (hour, day, week, month, year)")
	}
	bucket := plan.Column
	switch {
	case unit == "":
	case !plan.Zone.Fixed && plan.Zone.Name != "":
		zone := placeholder(plan.Zone.Name)
		bucket = fmt.Sprintf(
			"(extract(epoch from (date_trunc('%s', to_timestamp((%s)::double precision / 1000.0) "+
				"at time zone %s) at time zone %s))::bigint * 1000)",
			unit, plan.Column, zone, zone)
	default:
		offset := placeholder(int64(plan.Zone.OffsetMinutes) * 60000)
		local := fmt.Sprintf("(%s + %s)", plan.Column, offset)
		// Floor to a multiple of n, with the sign of the dividend handled: `%` in SQL keeps the
		// dividend's sign, and a bucket before the epoch must round DOWN.
		floorTo := func(value string, n int64) string {
			return fmt.Sprintf("(%s - (((%s %% %d) + %d) %% %d))", value, value, n, n, n)
		}
		switch unit {
		case "hour":
			bucket = fmt.Sprintf("(%s - %s)", floorTo(local, 3600000), offset)
		case "day":
			bucket = fmt.Sprintf("(%s - %s)", floorTo(local, 86400000), offset)
		case "week":
			// Epoch day 0 is a Thursday, so the ISO Monday week is the week grid shifted by
			// three days — the same +3/-3 the engine applies.
			shifted := fmt.Sprintf("(%s + 259200000)", local)
			bucket = fmt.Sprintf("((%s - 259200000) - %s)", floorTo(shifted, 604800000), offset)
		default:
			bucket = fmt.Sprintf(
				"((extract(epoch from date_trunc('%s', to_timestamp((%s)::double precision / 1000.0) "+
					"at time zone 'UTC'))::bigint * 1000) - %s)",
				unit, local, offset)
		}
	}
	where := ""
	if plan.Where != "" {
		where = " " + plan.Where
	}
	return fmt.Sprintf("select %s, %s from %s%s group by 1 order by 1",
		bucket, plan.Aggregate, plan.Table, where), arguments
}
