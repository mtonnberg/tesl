package teslrt

import (
	"context"
	"fmt"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/jackc/pgx/v5"
)

// PgRowAccessSlot lives beside one concrete generated entity type. Its database
// bindings capture concrete old/new codecs and callbacks; no erased row registry
// or nominal conversion participates in query dispatch.
type PgRowAccessSlot[Row any] struct {
	mutex  sync.RWMutex
	owners map[*Database]*pgRowAccess[Row]
}
type pgRowAccess[Row any] struct {
	registration *pgRowRegistration
	selectRows   func(PgRowQuery, bool, bool, func([]Row) ([]Row, error)) ([]Row, error)
	insert       func(Row) error
}

func NewPgRowAccessSlot[Row any]() *PgRowAccessSlot[Row] {
	return &PgRowAccessSlot[Row]{owners: map[*Database]*pgRowAccess[Row]{}}
}

// These fragments are emitted from the checked query AST. Field holes retain
// logical identities until the exact retained physical plan resolves them.
// Values remain driver parameters; this API never rewrites a SQL statement.
type PgRowQuery struct {
	parts, fields []string
	args          func() []any
}

func PgRowSQL(parts, fields []string, args func() []any) PgRowQuery {
	return PgRowQuery{parts: slices.Clone(parts), fields: slices.Clone(fields), args: args}
}

// Preserve ordinary evaluation timing at first driver use and retain the exact
// parameters throughout this logical operation. The compatibility barrier keeps
// its SQL plan valid without replaying the application body or its effects.
func (q PgRowQuery) capturedArguments() PgRowQuery {
	original := q.args
	once := sync.OnceValue(func() []any {
		if original == nil {
			return nil
		}
		return slices.Clone(original())
	})
	q.args = func() []any { return slices.Clone(once()) }
	return q
}

func (q PgRowQuery) statement(a *pgRowTransactionAdmission, d PgRowTransformDescriptor) (string, error) {
	if len(q.parts) != len(q.fields)+1 {
		return "", fmt.Errorf("invalid compiled logical query fragments")
	}
	var out strings.Builder
	for i, part := range q.parts {
		out.WriteString(part)
		if i == len(q.fields) {
			break
		}
		name := q.fields[i]
		if a != nil && a.plan != nil && a.plan.settled {
			if a.entity == nil {
				return "", fmt.Errorf("settled query requires its entity projection")
			}
			// The admission token selected this exact registered settled plan
			// using its Contract receipt. Historical aliases are now retired.
			column := a.entity.field(name)
			if column == "" {
				return "", fmt.Errorf("settled query omitted current field: %s", name)
			}
			out.WriteString(pgx.Identifier{column}.Sanitize())
			continue
		}
		previous := ""
		for _, m := range d.FieldMapping {
			if m.Target == name && (m.Kind == "copy" || m.Kind == "rename") {
				if m.Source != nil {
					previous = *m.Source
				}
				break
			}
		}
		if previous == "" {
			return "", fmt.Errorf("migration query needs an unchanged stored field: %s", name)
		}
		if a == nil || a.plan == nil || a.entity == nil {
			return "", fmt.Errorf("migration query requires its admitted entity projection")
		}
		old, err := pgCompiledRowPhysicalPlan(a.database, a.plan.version-1)
		if err != nil {
			return "", err
		}
		source := old.entity(a.entity.identity)
		// Rename retains a historical physical column, while newly added computed
		// fields cannot be queried until a later checked predicate planner exists.
		if source == nil {
			return "", fmt.Errorf("migration query lacks previous entity projection")
		}
		column := source.field(previous)
		current := a.entity.field(name)
		retained := current == column
		for _, alias := range a.entity.aliases {
			if alias.logical == name && alias.physical == column {
				retained = true
			}
		}
		if column == "" || !retained {
			return "", fmt.Errorf("migration query field changes stored projection")
		}

		out.WriteString(pgx.Identifier{column}.Sanitize())
	}
	return out.String(), nil
}
func RegisterCompiledRowAccess[From, To any](storage *PgRowStorage[From, To], slot *PgRowAccessSlot[To], capture ...func(PgPlan) PgPlan) *PgRowAccessSlot[To] {
	if len(capture) > 1 || len(capture) == 1 && capture[0] == nil {
		panic("invalid row access capture binding")
	}
	capture = slices.Clone(capture)
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	if storage == nil || storage.transform == nil || storage.transform.registration == nil || slot == nil {
		panic("missing compiled row access binding")
	}
	r := storage.transform.registration
	if !r.storageAttached || r.accessAttached || r.sealed || pgMigrationClosedFamilies[r.compiled.history.Family] {
		panic("duplicate, late, or incomplete compiled row access binding")
	}
	if compiledRowPhysicalHistories[r.compiled] == nil {
		panic("compiled row access requires exact physical history")
	}
	slot.mutex.Lock()
	defer slot.mutex.Unlock()
	if slot.owners == nil || slot.owners[r.database] != nil {
		panic("compiled row access slot already bound to database")
	}
	d := r.compiled.inventory.Transforms[r.index]
	access := &pgRowAccess[To]{registration: r}
	access.selectRows = func(query PgRowQuery, write, one bool, update func([]To) ([]To, error)) ([]To, error) {
		query = query.capturedArguments()
		ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
		defer cancel()
		plan, err := pgCompiledRowPhysicalPlan(r.database, d.MigrationVersion)
		if err != nil {
			return nil, err
		}
		entity := plan.entity(d.Entity)
		return pgWithRowTransaction(ctx, r.database, plan, entity, write, func(a *pgRowTransactionAdmission) ([]To, error) {
			if err := pgCheckRowData(a, storage, write); err != nil {
				return nil, err
			}
			tail, err := query.statement(a, d)
			if err != nil {
				return nil, err
			}
			sql := pgPhysicalSelectColumns(a.plan, a.entity) + tail
			if write {
				return pgRowCursorUpdate(ctx, a, storage, sql+" for update", query.args, one, update, capture)
			}
			plan := pgCapturedRowPlan(sql, query.args, capture)
			count := 0
			captured := false
			if plan.Capture != nil {
				defer func() {
					if !captured {
						plan.Capture(count)
					}
				}()
			}
			arguments := plan.arguments()
			migrationBoundary("row-query-before-select")
			rows, err := a.tx.Query(ctx, sql, arguments...)
			if err != nil {
				return nil, err
			}
			values, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (To, error) { return pgDecodePhysicalRow(a, storage, row) })
			if err != nil {
				return nil, err
			}
			count = len(values)
			// Complete the read capture before subsequent DML installs its own one.
			if plan.Capture != nil {
				plan.Capture(count)
				captured = true
			}
			return values, nil
		})
	}
	access.insert = func(value To) error {
		ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
		defer cancel()
		plan, err := pgCompiledRowPhysicalPlan(r.database, d.MigrationVersion)
		if err != nil {
			return err
		}
		_, err = pgWithRowTransaction(ctx, r.database, plan, plan.entity(d.Entity), true, func(a *pgRowTransactionAdmission) (struct{}, error) {
			return struct{}{}, pgInsertPhysicalRow(ctx, a, storage, value, capture...)
		})
		return err
	}
	if err := pgAttachRowBackfill(storage); err != nil {
		panic(err)
	}
	slot.owners[r.database] = access
	r.accessAttached = true
	return slot
}

// One portal owns the complete UPDATE target snapshot. FETCH bounds the Go row
// batch while row locks and every write remain in the same admitted transaction.
// In particular, this never reissues SELECT with a new page/snapshot.
var pgRowCursorSequence atomic.Uint64

func pgRowRMWBatch() (int, error) {
	text := os.Getenv("TESL_RMW_BATCH")
	if text == "" {
		return 2000, nil
	}
	n, err := strconv.Atoi(text)
	if err != nil || n <= 0 {
		return 0, fmt.Errorf("TESL_RMW_BATCH must be a positive integer")
	}
	return n, nil
}

func pgRowCursorUpdate[From, To any](ctx context.Context, a *pgRowTransactionAdmission, storage *PgRowStorage[From, To], sql string, args func() []any, one bool, update func([]To) ([]To, error), capture []func(PgPlan) PgPlan) (result []To, err error) {
	if err = a.check(true); err != nil {
		return nil, err
	}
	if update == nil {
		return nil, fmt.Errorf("missing typed row update")
	}
	batch, err := pgRowRMWBatch()
	if err != nil {
		return nil, err
	}
	// Two rows establish ambiguity before any updateAndReturnOne DML, even if
	// the ordinary streaming batch setting is one.
	if one {
		batch = 2
	}
	cursor := pgx.Identifier{fmt.Sprintf("tesl_rmw_%d", pgRowCursorSequence.Add(1))}.Sanitize()
	declare := pgCapturedRowPlan("declare "+cursor+" no scroll cursor for "+sql, args, capture)
	arguments := declare.arguments()
	migrationBoundary("row-rmw-before-declare")
	tag, err := a.tx.Exec(ctx, declare.SQL, arguments...)
	if declare.Capture != nil {
		declare.Capture(int(tag.RowsAffected()))
	}
	if err != nil {
		return nil, err
	}
	defer func() {
		// A failed statement can leave the transaction aborted. Preserve that
		// original failure; the enclosing admission scope rolls back all batches.
		_, closeErr := a.tx.Exec(ctx, "close "+cursor)
		if err == nil {
			err = closeErr
		}
	}()
	for {
		fetch := pgCapturedRowPlan("fetch forward "+strconv.Itoa(batch)+" from "+cursor, nil, capture)
		rows, readErr := a.tx.Query(ctx, fetch.SQL)
		if readErr != nil {
			return nil, readErr
		}
		values, readErr := pgx.CollectRows(rows, func(row pgx.CollectableRow) (To, error) { return pgDecodePhysicalRow(a, storage, row) })
		if fetch.Capture != nil {
			fetch.Capture(len(values))
		}
		if readErr != nil {
			return nil, readErr
		}
		migrationBoundary("row-rmw-after-fetch")
		if len(values) == 0 && !one {
			return nil, nil
		}
		next, updateErr := update(values)
		if updateErr != nil {
			return nil, updateErr
		}
		if len(next) != len(values) {
			return nil, fmt.Errorf("typed update changed row count")
		}
		for i, value := range values {
			if _, writeErr := pgUpdateDecodedPhysicalRow(ctx, a, storage, value, next[i], capture...); writeErr != nil {
				return nil, writeErr
			}
		}
		if one {
			return next, nil
		}
		if len(values) < batch {
			return nil, nil
		}
	}
}

func (slot *PgRowAccessSlot[Row]) access(database *Database) *pgRowAccess[Row] {
	if slot == nil {
		panic("missing compiled typed entity access slot")
	}
	slot.mutex.RLock()
	access := slot.owners[database]
	slot.mutex.RUnlock()
	if access == nil {
		panic("missing compiled typed entity access for database")
	}
	pgMigrationRegistrations.Lock()
	closed := access.registration.sealed
	pgMigrationRegistrations.Unlock()
	if !closed {
		panic("compiled typed entity access requires application preflight")
	}
	return access
}
func pgPhysicalSelectColumns(plan *pgRowPhysicalPlan, entity *pgRowPhysicalEntity) string {
	columns := []string{pgx.Identifier{"_tesl_v"}.Sanitize()}
	for _, c := range entity.columns {
		columns = append(columns, pgx.Identifier{c.catalog.Name}.Sanitize())
	}
	return "select " + strings.Join(columns, ",") + " from " + pgx.Identifier{plan.namespace, entity.table}.Sanitize()
}
func DbRowSelect[Row any](slot *PgRowAccessSlot[Row], database *Database, table *Table[Row], match func(Row) bool, less func(Row, Row) bool, offset, limit int, query PgRowQuery) []Row {
	if database.bound() == nil {
		if less == nil {
			return TableSelectRange(table, match, offset, limit)
		}
		return TableSelectSorted(table, match, less, offset, limit)
	}
	rows, err := slot.access(database).selectRows(query, false, false, nil)
	if err != nil {
		panic(pgFailure("database", err))
	}
	return rows
}
func DbRowSelectOne[Row any](slot *PgRowAccessSlot[Row], database *Database, table *Table[Row], match func(Row) bool, less func(Row, Row) bool, query PgRowQuery) Maybe[Row] {
	rows := DbRowSelect(slot, database, table, match, less, 0, 1, query)
	if len(rows) == 0 {
		return Nothing[Row]()
	}
	return Something(rows[0])
}
func DbRowInsert[Row any](slot *PgRowAccessSlot[Row], database *Database, table *Table[Row], entity string, row Row, conflicts func(Row, Row) bool, unique ...UniqueIndex[Row]) Row {
	if database.bound() == nil {
		return TableInsert(table, entity, row, conflicts, unique...)
	}
	if err := slot.access(database).insert(row); err != nil {
		panic(pgFailure("database", err))
	}
	return row
}
func pgDbRowUpdate[Row any](slot *PgRowAccessSlot[Row], database *Database, table *Table[Row], match func(Row) bool, apply func(Row) Row, prepare func() (PgRowQuery, func(Row) Row), one bool, unique ...UniqueIndex[Row]) []Row {
	if database.bound() == nil {
		if one {
			return []Row{TableUpdateReturnOne(table, match, apply, unique...)}
		}
		TableUpdate(table, match, apply, unique...)
		return nil
	}
	access := slot.access(database)
	query, update := prepare()
	rows, err := access.selectRows(query, true, one, func(values []Row) ([]Row, error) {
		if one && len(values) != 1 {
			if len(values) == 0 {
				return nil, fmt.Errorf("updateAndReturnOne: no row matched")
			}
			return nil, fmt.Errorf("%s", updateReturnOneAmbiguous)
		}
		result := make([]Row, len(values))
		for i, value := range values {
			result[i] = update(value)
		}
		return result, nil
	})
	if err != nil {
		panic(pgFailure("database", err))
	}
	return rows
}

func DbRowUpdate[Row any](slot *PgRowAccessSlot[Row], database *Database, table *Table[Row], match func(Row) bool, apply func(Row) Row, prepare func() (PgRowQuery, func(Row) Row), unique ...UniqueIndex[Row]) struct{} {
	pgDbRowUpdate(slot, database, table, match, apply, prepare, false, unique...)
	return struct{}{}
}
func DbRowUpdateReturnOne[Row any](slot *PgRowAccessSlot[Row], database *Database, table *Table[Row], match func(Row) bool, apply func(Row) Row, prepare func() (PgRowQuery, func(Row) Row), unique ...UniqueIndex[Row]) Row {
	rows := pgDbRowUpdate(slot, database, table, match, apply, prepare, true, unique...)
	if rows == nil || len(rows) != 1 {
		panic(pgFailure("database", fmt.Errorf("updateAndReturnOne returned an invalid row count")))
	}
	return rows[0]
}

func DbRowInsertMany[Row any](slot *PgRowAccessSlot[Row], database *Database, table *Table[Row], entity string, rows []Row, conflicts func(Row, Row) bool, unique ...UniqueIndex[Row]) struct{} {
	if database.bound() == nil {
		return TableInsertMany(table, entity, rows, conflicts, unique...)
	}
	access := slot.access(database)
	for _, row := range rows {
		if err := access.insert(row); err != nil {
			panic(pgFailure("database", err))
		}
	}
	return struct{}{}
}
