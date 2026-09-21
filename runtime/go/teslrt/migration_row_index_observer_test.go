package teslrt

import (
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// This is a PostgreSQL primitive/observer test using the existing format3 job
// functions and pure row descriptors. It is not a generated row5 index worker
// acceptance test. It also exercises Contract's retained-index completion gate
// after the same exact job and catalog observations used by the full observer.
func TestPgRowIndexProtectedJobObserver(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	f.expand(t, 1)
	id := pgIndexControlTestIntent(t, f)
	pgIndexControlTestRegister(t, f, id, "notes", "note_id_lookup", []string{"id"})
	f.call(t, "drop table notes_app.notes; create table notes_app.notes(id bigint primary key,key text not null)")
	manifest, _, _ := rowIndexManifest(t)
	manifest.plan.hash, manifest.creatorABI = strings.Repeat("b", 64), pgTestSourceABI
	baseline := &pgRowBaseline{history: PgCompiledMigrationHistory{Namespace: f.namespace, CurrentVersion: 1, SourceCompilerABI: pgTestSourceABI}}
	contract := false
	read := func(catalog bool) error {
		return pgControlSnapshotMode(f.ctx, f.worker, pgx.ReadOnly, func(tx pgx.Tx) error {
			intents, err := pgReadExpansionIntents(f.ctx, tx, f.namespace)
			if err != nil {
				return err
			}
			jobs, err := pgReadRowIndexJobs(f.ctx, tx, baseline, manifest, intents, false)
			if err != nil {
				return err
			}
			if len(jobs) != 1 || jobs[0].ID != id {
				return fmt.Errorf("missing original protected job")
			}
			if !catalog {
				return nil
			}
			metadata, err := pgReadCatalogExpectations(f.ctx, tx)
			if err != nil {
				return err
			}
			actual, err := pgReadMigrationTable(f.ctx, tx, f.namespace, "notes")
			if err != nil {
				return err
			}
			expected, err := metadata.entity(f.ctx, tx, PgMigrationCatalogTable{Name: "notes", Columns: []PgMigrationCatalogColumn{{Name: "id", Type: "int8", PrimaryKey: true}, {Name: "key", Type: "text"}}, Indexes: []PgMigrationCatalogIndex{jobs[0].Index}}, f.roles.Worker)
			if err != nil {
				return err
			}
			var report PgMigrationCatalogReport
			_, _, ready, err := pgPrepareRowIndexCatalog(metadata, actual, expected, manifest.predecessor, jobs, &report)
			if err != nil {
				return err
			}
			if !ready || len(report.Missing)+len(report.Drift) != 0 {
				return fmt.Errorf("catalog state differs: %+v", report)
			}
			if contract {
				return pgRequireRowContractIndexesComplete(f.ctx, tx, f.namespace)
			}
			return nil
		})
	}
	if err := read(true); err != nil {
		t.Fatal("pending absent index refused", err)
	}
	f.call(t, "create index concurrently note_id_lookup on notes_app.notes(id)")
	if err := read(true); err != nil {
		t.Fatal("exact actual concurrent index refused", err)
	}
	contract = true
	for _, state := range []string{"pending", "building", "failed"} {
		var detail any
		if state == "failed" {
			detail = "test build failure"
		}
		if _, err := f.installer.Exec(f.ctx, "update notes_app.tesl_schema_index set state=$1,attempts=1,error=$2", state, detail); err != nil {
			t.Fatal(err)
		}
		if err := read(true); err == nil || !strings.Contains(err.Error(), "requires all retained index jobs to be valid") {
			t.Fatal("Contract accepted unfinished protected index despite a valid physical index", state, err)
		}
	}
	if _, err := f.installer.Exec(f.ctx, "update notes_app.tesl_schema_index set state='valid',error=null"); err != nil {
		t.Fatal(err)
	}
	if err := read(true); err != nil {
		t.Fatal("Contract refused exact completed retained index", err)
	}
	f.call(t, "drop index notes_app.note_id_lookup")
	if err := read(true); err == nil {
		t.Fatal("Contract accepted completed job with missing physical index")
	}
	f.call(t, "create index note_id_lookup on notes_app.notes(key)")
	if err := read(true); err == nil {
		t.Fatal("Contract accepted completed job with foreign index shape")
	}
	f.call(t, "drop index notes_app.note_id_lookup; create index note_id_lookup on notes_app.notes(id)")
	if err := read(true); err != nil {
		t.Fatal("Contract refused restored exact retained index", err)
	}
	if _, err := f.installer.Exec(f.ctx, "update notes_app.tesl_schema_index set table_name='foreign'"); err != nil {
		t.Fatal(err)
	}
	if err := read(false); err == nil {
		t.Fatal("wrong protected descriptor accepted")
	}
	if _, err := f.installer.Exec(f.ctx, "update notes_app.tesl_schema_index set table_name='notes'; delete from notes_app.tesl_schema_leases where name='index:note_id_lookup'"); err != nil {
		t.Fatal(err)
	}
	if err := read(false); err == nil {
		t.Fatal("whole missing index lease accepted")
	}
	if _, err := f.installer.Exec(f.ctx, "delete from notes_app.tesl_schema_index"); err != nil {
		t.Fatal(err)
	}
	if err := read(false); err == nil || !strings.Contains(err.Error(), "no protected job") {
		t.Fatal("whole missing job inventory accepted", err)
	}
}

func TestPgRowIndexOrphanLeaseCannotEscapeFullObserver(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	db := pgRowBaselineFixture(t, f)
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
		t.Fatal(err)
	}
	if _, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, db, f.roles); err != nil {
		t.Fatal(err)
	}
	baseline, err := pgCompiledRowBaseline(db)
	if err != nil {
		t.Fatal(err)
	}
	read := func() error {
		return pgControlSnapshotMode(f.ctx, f.worker, pgx.ReadOnly, func(tx pgx.Tx) error {
			_, _, err := pgReadRowBaselineState(f.ctx, tx, baseline, f.roles, false)
			return err
		})
	}
	if err := read(); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"index:orphan", "row:orphan:2:0", "arbitrary"} {
		if _, err := f.installer.Exec(f.ctx, "insert into notes_app.tesl_schema_leases(name) values($1)", name); err != nil {
			t.Fatal(err)
		}
		if err := read(); err == nil {
			t.Fatal("lease prefix bypassed complete inventory", name)
		}
		if _, err := f.installer.Exec(f.ctx, "delete from notes_app.tesl_schema_leases where name=$1", name); err != nil {
			t.Fatal(err)
		}
	}
	if err := read(); err != nil {
		t.Fatal("restored exact baseline refused", err)
	}
}
