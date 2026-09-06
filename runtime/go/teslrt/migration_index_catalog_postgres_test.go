package teslrt

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func pgIndexCatalogPostgresSetup(t *testing.T, unique bool) (*pgControlTestFixture, *pgx.Conn, PgMigrationCatalogTable, PgMigrationCatalogTable, pgMigrationIndexJob) {
	t.Helper()
	f := pgNewControlTest(t)
	f.install(t, 1)
	f.call(t, "create table notes_app.todos(id text primary key,done boolean not null,optional text)")
	reader := pgCatalogTestReader(t, f)
	old := PgMigrationCatalogTable{Name: "todos", Columns: []PgMigrationCatalogColumn{
		{Name: "id", Type: "text", PrimaryKey: true}, {Name: "done", Type: "bool"},
	}}
	current := old
	current.Columns = append(slices.Clone(old.Columns), PgMigrationCatalogColumn{Name: "optional", Type: "text", Nullable: true})
	index := PgMigrationCatalogIndex{Name: "done__v2", Columns: []string{"done"}}
	if unique {
		index = PgMigrationCatalogIndex{Name: "optional__v2", Columns: []string{"optional"}, Unique: true}
	}
	current.Indexes = []PgMigrationCatalogIndex{index}
	job := pgMigrationIndexJob{Version: 2, Table: "todos", State: "building", Index: index}
	return f, reader, old, current, job
}

func pgCheckIndexCatalogSnapshot(t *testing.T, f *pgControlTestFixture, reader *pgx.Conn,
	table PgMigrationCatalogTable, job pgMigrationIndexJob, version int, wantReady bool) {
	t.Helper()
	pgReadOnlyCatalogTestTransaction(t, f, reader, func(tx pgx.Tx) {
		report, ready, err := pgInspectMigrationCatalogWithIndexJobsInTx(f.ctx, tx, f.namespace, f.roles.Worker,
			[]PgMigrationCatalogTable{table}, []pgMigrationIndexJob{job}, version)
		if err != nil || len(report.Missing) != 0 || len(report.Drift) != 0 || ready != wantReady {
			t.Fatalf("read-only index catalog: ready=%v want=%v err=%v report=%+v", ready, wantReady, err, report)
		}
	})
}

func TestPgMigrationIndexCatalogPostgresActiveBuild(t *testing.T) {
	f, reader, old, current, job := pgIndexCatalogPostgresSetup(t, false)
	pgCheckIndexCatalogSnapshot(t, f, reader, current, job, 2, true) // Absent plain index is not a readiness dependency.
	writer, err := pgx.ConnectConfig(f.ctx, f.worker.Config())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = writer.Close(context.Background()) }()
	tx, err := writer.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	if _, err := tx.Exec(f.ctx, "insert into notes_app.todos(id,done) values('inflight',false)"); err != nil {
		t.Fatal(err)
	}
	build := make(chan error, 1)
	finished := make(chan struct{})
	buildContext, cancelBuild := context.WithCancel(f.ctx)
	pid := f.worker.PgConn().PID()
	go func() {
		defer close(finished)
		_, err := f.worker.Exec(buildContext, "create index concurrently done__v2 on notes_app.todos(done)")
		build <- err
	}()
	defer func() {
		cancelBuild()
		_ = tx.Rollback(context.Background())
		<-finished
	}()
	deadline := time.Now().Add(5 * time.Second)
	for {
		var active bool
		if err := f.installer.QueryRow(f.ctx, `select exists(select 1 from pg_catalog.pg_stat_progress_create_index
 where pid=$1 and command='CREATE INDEX CONCURRENTLY')`, pid).Scan(&active); err != nil {
			t.Fatal(err)
		}
		if active {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("concurrent index build never appeared in PostgreSQL progress")
		}
		time.Sleep(10 * time.Millisecond)
	}
	// Both an old bridge binary and the introducing binary can inspect a real
	// still-running invalid plain index using a role without TEMP or CREATE.
	pgCheckIndexCatalogSnapshot(t, f, reader, old, job, 1, true)
	pgCheckIndexCatalogSnapshot(t, f, reader, current, job, 2, true)
	if err := tx.Commit(f.ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-build:
		if err != nil {
			t.Fatal(err)
		}
	case <-f.ctx.Done():
		t.Fatal(f.ctx.Err())
	}
	job.State = "valid"
	pgCheckIndexCatalogSnapshot(t, f, reader, old, job, 1, true)
	pgCheckIndexCatalogSnapshot(t, f, reader, current, job, 2, true)
	f.call(t, "create index unrecorded on notes_app.todos(done)")
	pgReadOnlyCatalogTestTransaction(t, f, reader, func(tx pgx.Tx) {
		report, ready, err := pgInspectMigrationCatalogWithIndexJobsInTx(f.ctx, tx, f.namespace, f.roles.Worker,
			[]PgMigrationCatalogTable{old}, []pgMigrationIndexJob{job}, 1)
		if err != nil || ready || len(report.Drift) != 1 || report.Drift[0].Object != "unrecorded" {
			t.Fatalf("unrecorded index was hidden by the future-job allowance: %v %v %+v", ready, err, report)
		}
	})
}

func TestPgMigrationIndexCatalogPostgresFailedUniqueReadiness(t *testing.T) {
	f, reader, old, current, job := pgIndexCatalogPostgresSetup(t, true)
	pgCheckIndexCatalogSnapshot(t, f, reader, old, job, 1, true)
	pgCheckIndexCatalogSnapshot(t, f, reader, current, job, 2, false)
	f.call(t, "insert into notes_app.todos(id,done,optional) values('first',false,'duplicate'),('second',true,'duplicate')")
	_, err := f.worker.Exec(f.ctx, "create unique index concurrently optional__v2 on notes_app.todos(optional)")
	var conflict *pgconn.PgError
	if !errors.As(err, &conflict) || conflict.Code != "23505" {
		t.Fatalf("fixture did not leave a failed concurrent unique build: %v", err)
	}
	job.State = "failed"
	pgCheckIndexCatalogSnapshot(t, f, reader, old, job, 1, true)
	pgCheckIndexCatalogSnapshot(t, f, reader, current, job, 2, false)
	// Old writers still omit every unique key into NULL. This is an actual
	// PostgreSQL write against the failed physical remnant, not just a planner fact.
	f.call(t, "insert into notes_app.todos(id,done) values('old-a',false),('old-b',false)")
	f.call(t, "drop index concurrently notes_app.optional__v2")
	f.call(t, "update notes_app.todos set optional=null where id='second'")
	f.call(t, "create unique index concurrently optional__v2 on notes_app.todos(optional)")
	job.State = "building"
	pgCheckIndexCatalogSnapshot(t, f, reader, current, job, 2, false) // Await durable worker success too.
	job.State = "valid"
	pgCheckIndexCatalogSnapshot(t, f, reader, current, job, 2, true)
	pgCheckIndexCatalogSnapshot(t, f, reader, old, job, 1, true)
	_, err = f.worker.Exec(f.ctx, "insert into notes_app.todos(id,done,optional) values('rejected',false,'duplicate')")
	if !errors.As(err, &conflict) || conflict.Code != "23505" {
		t.Fatalf("ready unique index did not enforce uniqueness: %v", err)
	}
}
