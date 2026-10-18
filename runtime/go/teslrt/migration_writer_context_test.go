package teslrt

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func TestPgWriterContextTransactionIdentity(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	db := pgRowBaselineFixture(t, f)
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
		t.Fatal(err)
	}
	state, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, db, f.roles)
	if err != nil {
		t.Fatal(err)
	}
	ns := quoteIdentifier(f.namespace) + "."
	protocol := &PostgresDB{schema: f.namespace, migration: &pgMigrationAdmission{
		version: 1, fenceNamespace: state.FenceNamespace, controlFormat: pgRowControlFormat,
	}}
	// A definer wrapper models the eventual trigger's owner-only read. It is
	// fixture-only, installed after production's exact catalog checks above.
	if _, err := f.installer.Exec(f.ctx, `create function `+ns+`test_writer() returns integer language sql volatile security definer set search_path='' as 'select `+ns+`tesl_writer_version()'; alter function `+ns+`test_writer() owner to `+quoteIdentifier(f.roles.Owner)); err != nil {
		t.Fatal(err)
	}
	exec := func(tx pgx.Tx, sql string) {
		t.Helper()
		if _, err := tx.Exec(f.ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	refuse := func(tx pgx.Tx, sql, reason string) {
		t.Helper()
		exec(tx, "savepoint rejected")
		if _, err := tx.Exec(f.ctx, sql); err == nil || !strings.Contains(err.Error(), reason) {
			t.Fatalf("expected %q, got %v", reason, err)
		}
		exec(tx, "rollback to rejected")
	}
	read := func(tx pgx.Tx) {
		t.Helper()
		var version int
		if err := tx.QueryRow(f.ctx, "select "+ns+"test_writer()").Scan(&version); err != nil || version != 1 {
			t.Fatal("lost admitted identity", version, err)
		}
	}
	for _, commit := range []bool{true, false, true} {
		tx, err := request.Begin(f.ctx)
		if err != nil {
			t.Fatal(err)
		}
		refuse(tx, "select "+ns+"test_writer()", "missing admitted writer transaction")
		exec(tx, "set local tesl.writer_version='1'")
		refuse(tx, "select "+ns+"test_writer()", "missing admitted writer transaction")
		refuse(tx, "insert into "+ns+"tesl_writer_context values(pg_backend_pid(),pg_current_xact_id(),'"+state.DatabaseUUID+"',1)", "permission denied")
		refuse(tx, "select "+ns+"tesl_writer_version()", "permission denied")
		refuse(tx, "select "+ns+"tesl_admit_writer(2)", "protected physical manifest")
		exec(tx, "savepoint before_admission")
		if err := pgAdmitMigrationTransaction(f.ctx, tx, protocol, true); err != nil {
			t.Fatal("compiled transaction admission", err)
		}
		read(tx)
		exec(tx, "rollback to before_admission")
		refuse(tx, "select "+ns+"test_writer()", "missing admitted writer transaction")
		exec(tx, "select "+ns+"tesl_admit_writer(1)")
		exec(tx, "select "+ns+"tesl_admit_writer(1)") // nested/repeated admission
		refuse(tx, "select "+ns+"tesl_admit_writer(2)", "identity cannot change")
		read(tx)
		if commit {
			err = tx.Commit(f.ctx)
		} else {
			err = tx.Rollback(f.ctx)
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	for _, isolation := range []pgx.TxIsoLevel{pgx.RepeatableRead, pgx.Serializable} {
		tx, err := request.BeginTx(f.ctx, pgx.TxOptions{IsoLevel: isolation})
		if err != nil {
			t.Fatal(err)
		}
		refuse(tx, "select "+ns+"tesl_admit_writer(1)", "requires READ COMMITTED")
		if err := tx.Rollback(f.ctx); err != nil {
			t.Fatal(err)
		}
	}
	for _, conn := range []*pgx.Conn{f.worker, request} {
		if _, err := conn.Exec(f.ctx, "delete from "+ns+"tesl_writer_context"); err == nil {
			t.Fatal("non-owner mutated writer records")
		}
		if _, err := conn.Exec(f.ctx, "select "+ns+"tesl_writer_version()"); err == nil {
			t.Fatal("non-owner called internal writer-context reader")
		}
	}
	// Retirement must wait for the admitted writer even after the admission
	// statement has returned; it must not merely protect the function call.
	tx, err := request.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	exec(tx, "select "+ns+"tesl_admit_writer(1)")
	var acquired bool
	if err := f.worker.QueryRow(f.ctx, "select pg_try_advisory_lock($1::integer,1)", state.FenceNamespace).Scan(&acquired); err != nil || acquired {
		t.Fatal("writer fence did not survive admission", acquired, err)
	}
	if err := tx.Rollback(f.ctx); err != nil {
		t.Fatal(err)
	}
	if err := f.worker.QueryRow(f.ctx, "select pg_try_advisory_lock($1::integer,1)", state.FenceNamespace).Scan(&acquired); err != nil || !acquired {
		t.Fatal("writer fence survived rollback", acquired, err)
	}
	// Block a new admission behind retirement, advance the floor while it
	// waits, then release. The post-wait snapshot must see the retired floor.
	result := make(chan error, 1)
	go func() {
		_, err := request.Exec(f.ctx, "select "+ns+"tesl_admit_writer(1)")
		result <- err
	}()
	ctx, cancel := context.WithTimeout(f.ctx, 5*time.Second)
	defer cancel()
	for {
		var waiting bool
		if err := f.installer.QueryRow(ctx, "select exists(select 1 from pg_catalog.pg_locks where pid=$1 and locktype='advisory' and not granted)", request.PgConn().PID()).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting {
			break
		}
		if err := pgIndexWait(ctx, time.Millisecond); err != nil {
			t.Fatal(err)
		}
	}
	// Test-only mutation isolates the fresh-snapshot boundary from the
	// separately tested reviewed Contract retirement authorization.
	if _, err := f.installer.Exec(f.ctx, "update "+ns+"tesl_schema_state set current=2,min_version=2,compat_floor=2 where id=1"); err != nil {
		t.Fatal(err)
	}
	if _, err := f.worker.Exec(f.ctx, "select pg_advisory_unlock($1::integer,1)", state.FenceNamespace); err != nil {
		t.Fatal(err)
	}
	if err := <-result; err == nil || !strings.Contains(err.Error(), "is retired") {
		t.Fatal("admitted retired release after fence wait", err)
	}
}
