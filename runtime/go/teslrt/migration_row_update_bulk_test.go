package teslrt

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Publication guards in isolation; only same-package tests can manufacture this
// private admission. The native companion exercises real compiled admission.
func TestPgRowBulkUpdateGuards(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	f.install(t, 1)
	f.call(t, `create table notes_app.bulk_updates(id text primary key,title text not null,_tesl_v smallint not null);
insert into notes_app.bulk_updates values('a','old-a',2),('b','old-b',2)`)
	for _, name := range []string{"both", "active-window", "future", "unique", "stage", "json-key", "duplicate", "large-payload", "aggregate-payload", "unknown-carrier", "changed-key", "lost-row", "sql-error", "expired"} {
		t.Run(name, func(t *testing.T) {
			tx, err := f.worker.Begin(f.ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback(context.Background()) }()
			compiled := &pgCompiledRowHistory{}
			plan := &pgRowPhysicalPlan{namespace: f.namespace, version: 2, compiled: compiled}
			window := &pgRowPhysicalPlan{namespace: f.namespace, version: 2, compiled: compiled}
			entity := &pgRowPhysicalEntity{identity: "Note", table: "bulk_updates", generation: 2, columns: []pgRowPhysicalColumn{
				{catalog: PgMigrationCatalogColumn{Name: "id", Type: "text", PrimaryKey: true}},
				{catalog: PgMigrationCatalogColumn{Name: "title", Type: "text"}},
			}}
			a := &pgRowTransactionAdmission{tx: tx, database: &Database{}, protocol: &pgMigrationAdmission{}, plan: plan, window: window, entity: entity, write: true}
			a.active.Store(true)
			if pgCanBulkRowUpdate(a, []func(PgPlan) PgPlan{func(plan PgPlan) PgPlan { return plan }}) {
				t.Fatal("debug capture must retain its per-row statements")
			}
			before := []pgPhysicalWrite{{primary: "a"}, {primary: "b"}}
			rows := []pgPhysicalWrite{
				{primary: "a", columns: []string{"id", "title", "_tesl_v"}, values: []any{"a", "new-a", int16(2)}},
				{primary: "b", columns: []string{"id", "title", "_tesl_v"}, values: []any{"b", "new-b", int16(2)}},
			}
			switch name {
			case "active-window":
				a.window = a.plan
			case "future":
				a.currentGenerations = map[int]bool{3: true}
			case "unique":
				entity.indexes = []PgMigrationCatalogIndex{{Name: "title_unique", Columns: []string{"title"}, Unique: true}}
			case "stage":
				window.stageGuards = []pgStageGuard{{}}
			case "json-key":
				entity.columns[0].catalog.Type = "jsonb"
			case "duplicate":
				before[1], rows[1] = before[0], rows[0]
			case "large-payload":
				rows[1].values[1] = strings.Repeat("x", pgRowBulkUpdateMaxBytes+1)
			case "aggregate-payload":
				rows[0].values[1] = strings.Repeat("x", pgRowBulkUpdateMaxBytes/2)
				rows[1].values[1] = rows[0].values[1]
			case "unknown-carrier":
				type customText string
				rows[1].values[1] = customText("new-b")
			case "changed-key":
				rows[1].primary = "different"
			case "lost-row":
				before[1].primary = "missing"
			case "sql-error":
				rows[1].values[1] = nil
			case "expired":
				a.active.Store(false)
			}
			key := pgRowWriterSetting(plan.namespace, entity.identity)
			if _, err := tx.Exec(f.ctx, "select set_config($1,'prior-value',true)", key); err != nil {
				t.Fatal(err)
			}
			used, err := pgUpdateMaterializedPhysicalRows(f.ctx, a, before, rows)
			wantError := name == "changed-key" || name == "lost-row" || name == "sql-error" || name == "expired"
			if (err != nil) != wantError || used != (name == "both") {
				t.Fatalf("used=%t err=%v", used, err)
			}
			if name == "changed-key" || name == "lost-row" {
				if err == nil || !strings.Contains(err.Error(), "primary key or lost its locked row") {
					t.Fatal(err)
				}
			}
			if name != "sql-error" {
				var previous string
				if err := tx.QueryRow(f.ctx, "select current_setting($1,true)", key).Scan(&previous); err != nil || previous != "prior-value" {
					t.Fatal("writer setting not restored", previous, err)
				}
				if !wantError {
					var changed int
					if err := tx.QueryRow(f.ctx, "select count(*) from notes_app.bulk_updates where title like 'new-%'").Scan(&changed); err != nil {
						t.Fatal(err)
					}
					want := 0
					if name == "both" {
						want = 2
					}
					if changed != want {
						t.Fatal("unexpected publication", changed)
					}
				}
			}
			if err := tx.Rollback(f.ctx); err != nil && err != pgx.ErrTxClosed {
				t.Fatal(err)
			}
			var changed int
			if err := f.worker.QueryRow(f.ctx, "select count(*) from notes_app.bulk_updates where title like 'new-%'").Scan(&changed); err != nil || changed != 0 {
				t.Fatal("rollback leaked publication", changed, err)
			}
		})
	}
}

type pgBulkUpdateQueryCount struct{ calls atomic.Int64 }

func (trace *pgBulkUpdateQueryCount) TraceQueryStart(ctx context.Context, _ *pgx.Conn, _ pgx.TraceQueryStartData) context.Context {
	trace.calls.Add(1)
	return ctx
}
func (*pgBulkUpdateQueryCount) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}

func TestPgRowBulkUpdateQueryCountDoesNotGrowPerRow(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	f.install(t, 1)
	f.call(t, `create table notes_app.bulk_updates(id text primary key,title text not null,_tesl_v smallint not null);
insert into notes_app.bulk_updates select i::text,'old',2 from generate_series(1,128) i`)
	trace := &pgBulkUpdateQueryCount{}
	config := f.worker.Config().Copy()
	config.Tracer = trace
	conn, err := pgx.ConnectConfig(f.ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(context.Background()) }()
	var counts [2]int64
	for sample, count := range []int{2, 128} {
		tx, err := conn.Begin(f.ctx)
		if err != nil {
			t.Fatal(err)
		}
		compiled := &pgCompiledRowHistory{}
		plan := &pgRowPhysicalPlan{namespace: f.namespace, version: 2, compiled: compiled}
		window := &pgRowPhysicalPlan{namespace: f.namespace, version: 2, compiled: compiled}
		entity := &pgRowPhysicalEntity{identity: "Note", table: "bulk_updates", generation: 2, columns: []pgRowPhysicalColumn{
			{catalog: PgMigrationCatalogColumn{Name: "id", Type: "text", PrimaryKey: true}},
			{catalog: PgMigrationCatalogColumn{Name: "title", Type: "text"}},
		}}
		a := &pgRowTransactionAdmission{tx: tx, database: &Database{}, protocol: &pgMigrationAdmission{}, plan: plan, window: window, entity: entity, write: true}
		a.active.Store(true)
		var before, after []pgPhysicalWrite
		for index := 1; index <= count; index++ {
			key := fmt.Sprint(index)
			before = append(before, pgPhysicalWrite{primary: key})
			after = append(after, pgPhysicalWrite{primary: key, columns: []string{"id", "title", "_tesl_v"}, values: []any{key, "new", int16(2)}})
		}
		trace.calls.Store(0)
		used, err := pgUpdateMaterializedPhysicalRows(f.ctx, a, before, after)
		calls := trace.calls.Load()
		if !used || err != nil {
			t.Fatal("bulk path not exercised", used, err)
		}
		counts[sample] = calls
		var changed int
		if err := tx.QueryRow(f.ctx, "select count(*) from notes_app.bulk_updates where title='new'").Scan(&changed); err != nil || changed != count {
			t.Fatal("wrong publication count", changed, err)
		}
		if err := tx.Rollback(f.ctx); err != nil {
			t.Fatal(err)
		}
	}
	if counts[0] == 0 || counts[0] != counts[1] {
		t.Fatal("bulk publication regained per-row round trips", counts)
	}
}

func TestPgRowBulkUpdateBudgetFallbackDoesNotRepeatCodecs(t *testing.T) {
	t.Setenv("TESL_RMW_BATCH", "2000")
	f, _ := pgNewWorkerTest(t)
	f.install(t, 1)
	f.call(t, `create table notes_app.bulk_updates(id text primary key,title text not null,_tesl_v smallint not null);
insert into notes_app.bulk_updates select i::text,'old',2 from generate_series(1,4) i`)
	tx, err := f.worker.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	compiled := &pgCompiledRowHistory{}
	plan := &pgRowPhysicalPlan{namespace: f.namespace, version: 2, compiled: compiled}
	window := &pgRowPhysicalPlan{namespace: f.namespace, version: 2, compiled: compiled}
	entity := &pgRowPhysicalEntity{identity: "Note", table: "bulk_updates", generation: 2, columns: []pgRowPhysicalColumn{
		{catalog: PgMigrationCatalogColumn{Name: "id", Type: "text", PrimaryKey: true}},
		{catalog: PgMigrationCatalogColumn{Name: "title", Type: "text"}},
	}}
	a := &pgRowTransactionAdmission{tx: tx, database: &Database{}, protocol: &pgMigrationAdmission{}, plan: plan, window: window, entity: entity, write: true}
	a.active.Store(true)
	if !pgCanBulkRowUpdate(a, nil) {
		t.Fatal("fixture must reach the argument-budget decision")
	}
	type value struct{ id, title string }
	calls := map[string]int{}
	data := pgRowAccessData[value]{
		decode: func(_ *pgRowTransactionAdmission, row pgx.CollectableRow) (value, error) {
			var marker int16
			var result value
			err := row.Scan(&marker, &result.id, &result.title)
			return result, err
		},
		materialize: func(_ *pgRowTransactionAdmission, row value) (pgPhysicalWrite, error) {
			calls[row.id]++
			return pgPhysicalWrite{primary: row.id, columns: []string{"id", "title", "_tesl_v"}, values: []any{row.id, row.title, int16(2)}}, nil
		},
	}
	payload := strings.Repeat("x", pgRowBulkUpdateMaxBytes/2)
	_, err = pgRowCursorUpdateUsing(f.ctx, a, data, "select _tesl_v,id,title from notes_app.bulk_updates order by id for update", nil, false,
		func(rows []value) ([]value, error) {
			next := slices.Clone(rows)
			for index := range next {
				next[index].title = payload
			}
			return next, nil
		}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(calls) != 4 {
		t.Fatal("wrong codec input set", calls)
	}
	for id, count := range calls {
		if count != 2 {
			t.Fatal("fallback re-evaluated original or updated codec", id, count)
		}
	}
	var updated int
	if err := tx.QueryRow(f.ctx, "select count(*) from notes_app.bulk_updates where length(title)=$1", len(payload)).Scan(&updated); err != nil || updated != 4 {
		t.Fatal("fallback lost rows", updated, err)
	}
}
