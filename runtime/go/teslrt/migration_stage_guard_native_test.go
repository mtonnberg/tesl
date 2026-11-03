//go:build tesl_migration_test

package teslrt

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func TestPgStageGuardCompiledWindow(t *testing.T) {
	t.Setenv("TESL_SCHEMA_POLL_S", "1")
	root := os.Getenv("TESL_STAGE_GUARD_PROGRAMS")
	if root == "" {
		t.Skip("compiled guarded programs required")
	}
	f, request := pgNewWorkerTest(t)
	f.namespace = "notes"
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	t.Cleanup(cancel)
	f.ctx = ctx
	pgStageInstall(t, f, root, "v1")
	pgRowAdditiveWorker(t, f, root, "v1")()
	old := pgRowAdditiveApp(t, f, root, "v1")
	pgCallRowAccessApp(t, ctx, old, "POST", "/one", 200)
	stop := pgRowAdditiveWorker(t, f, root, "v2")
	for {
		var count int
		if err := f.worker.QueryRow(ctx, "select count(*) from notes.tesl_schema_index where state='valid'").Scan(&count); err != nil {
			t.Fatal(err)
		}
		if count == 5 {
			break
		}
		if err := pgIndexWait(ctx, 10*time.Millisecond); err != nil {
			t.Fatal(err)
		}
	}
	stop()
	older := pgRowAdditiveApp(t, f, root, "v2")
	pgRowAdditiveWorker(t, f, root, "v3")()
	fresh := pgRowAdditiveApp(t, f, root, "v3")
	pgCallRowAccessApp(t, ctx, fresh, "POST", "/two", 200)
	pgCallRowAccessApp(t, ctx, fresh, "POST", "/text", 200)
	pgCallRowAccessApp(t, ctx, fresh, "PUT", "/edit", 500)
	var partial int
	if err := f.worker.QueryRow(ctx, `select count(*) from notes.notes where title='edited'`).Scan(&partial); err != nil || partial != 0 {
		t.Fatal("compiled bulk update did not roll back", partial, err)
	}
	var unique, guards int
	if err := f.worker.QueryRow(ctx, `select (select count(*) from pg_catalog.pg_index i join pg_catalog.pg_class c on c.oid=i.indrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='notes' and c.relname='notes' and i.indisunique and not i.indisprimary),(select count(*) from notes.tesl_schema_stage_guards)`).Scan(&unique, &guards); err != nil || unique != 0 || guards != 5 {
		t.Fatal("guarded readiness invented UNIQUE", unique, guards, err)
	}
	begin := func(conn *pgx.Conn, v int) pgx.Tx {
		t.Helper()
		tx, err := conn.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(ctx, "select notes.tesl_admit_writer($1)", v); err != nil {
			t.Fatal(err)
		}
		return tx
	}
	exec := func(tx pgx.Tx, sql string) {
		t.Helper()
		if _, err := tx.Exec(ctx, sql); err != nil {
			t.Fatal(sql, err)
		}
	}
	duplicate := func(err error, target string) {
		t.Helper()
		var e *pgconn.PgError
		if !errors.As(err, &e) || e.Code != "23505" || e.ConstraintName != target {
			t.Fatalf("expected staged 23505/%s, got %v", target, err)
		}
	}
	tx := begin(request, 2)
	exec(tx, `insert into notes.notes(id,title) values('old-a','overlap'),('old-b','overlap')`)
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	tx = begin(request, 3)
	_, err := tx.Exec(ctx, `insert into notes.notes(id,title) values('new','overlap')`)
	duplicate(err, "title_unique")
	_ = tx.Rollback(ctx)
	tx = begin(request, 3)
	exec(tx, `insert into notes.notes(id,title) values('null-a','null-a'),('null-b','null-b')`)
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	tx = begin(request, 3)
	_, err = tx.Exec(ctx, `insert into notes.notes(id,title) values('bulk-a','bulk'),('bulk-b','bulk')`)
	duplicate(err, "title_unique")
	_ = tx.Rollback(ctx)
	tx = begin(request, 3)
	_, err = tx.Exec(ctx, `update notes.notes set title='bulk-update' where id in ('null-a','null-b')`)
	duplicate(err, "title_unique")
	_ = tx.Rollback(ctx)
	tx = begin(request, 3)
	exec(tx, `update notes.notes set id='moved',title=title||'-new' where id='null-a'`)
	exec(tx, `update notes.notes set id='moved-again' where id='moved'`)
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	// A forged GUC and stale committed backend record cannot authorize raw DML.
	if _, err = request.Exec(ctx, `set tesl.writer_version='2'; insert into notes.notes(id,title) values('forged','forged')`); err == nil {
		t.Fatal("missing context accepted")
	}
	pgStageInstall(t, f, root, "v3") // exact replay/catalog observation
	t.Run("key-domains-and-profile", func(t *testing.T) {
		for _, domain := range []struct{ column, value, target string }{
			{"active", "true", "active_unique"}, {"amount", "-2147483648", "amount_unique"}, {"big_amount", "2147483647", "big_amount_unique"}, {"optional_text", "'new-é'", "optional_text_unique"},
		} {
			tx := begin(request, 3)
			exec(tx, "insert into notes.notes(id,title,"+domain.column+") values('"+domain.column+"-a','"+domain.column+"-a',"+domain.value+")")
			exec(tx, "savepoint violation")
			_, err := tx.Exec(ctx, "insert into notes.notes(id,title,"+domain.column+") values('"+domain.column+"-b','"+domain.column+"-b',"+domain.value+")")
			duplicate(err, domain.target)
			exec(tx, "rollback to violation")
			if err := tx.Commit(ctx); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := request.Exec(ctx, `set plan_cache_mode=force_generic_plan; set random_page_cost=1e12; set enable_seqscan=on; set cpu_tuple_cost=0.03`); err != nil {
			t.Fatal(err)
		}
		profile := func() string {
			var s string
			if err := request.QueryRow(ctx, `select current_setting('plan_cache_mode')||'/'||current_setting('random_page_cost')||'/'||current_setting('enable_seqscan')||'/'||current_setting('cpu_tuple_cost')`).Scan(&s); err != nil {
				t.Fatal(err)
			}
			return s
		}
		before := profile()
		tx := begin(request, 3)
		exec(tx, `insert into notes.notes(id,title) values('profile','profile')`)
		if got := profile(); got != before {
			t.Fatal("successful probe leaked its transaction-local profile", before, got)
		}
		exec(tx, "savepoint violation")
		_, err := tx.Exec(ctx, `insert into notes.notes(id,title) values('profile-duplicate','profile')`)
		duplicate(err, "title_unique")
		exec(tx, "rollback to violation")
		if got := profile(); got != before {
			t.Fatal("failed probe leaked its transaction-local profile", before, got)
		}
		if err := tx.Commit(ctx); err != nil {
			t.Fatal(err)
		}
		if got := profile(); got != before {
			t.Fatal("probe leaked profile", before, got)
		}
	})
	t.Run("fresh-lock-wait-and-cross-key", func(t *testing.T) {
		second, err := pgx.ConnectConfig(ctx, request.Config().Copy())
		if err != nil {
			t.Fatal(err)
		}
		defer second.Close(ctx)
		third, err := pgx.ConnectConfig(ctx, request.Config().Copy())
		if err != nil {
			t.Fatal(err)
		}
		defer third.Close(ctx)
		a := begin(request, 3)
		defer a.Rollback(ctx)
		exec(a, `insert into notes.notes(id,title) values('race-a','race')`)
		b := begin(second, 3)
		defer b.Rollback(ctx)
		done := make(chan error, 1)
		go func() {
			_, err := b.Exec(ctx, `insert into notes.notes(id,title) values('race-b','race')`)
			done <- err
		}()
		wait, stop := context.WithTimeout(ctx, 5*time.Second)
		defer stop()
		for {
			var waiting bool
			if err := f.worker.QueryRow(wait, `select exists(select 1 from pg_catalog.pg_locks where pid=$1 and locktype='advisory' and objsubid=1 and not granted)`, second.PgConn().PID()).Scan(&waiting); err != nil {
				t.Fatal(err)
			}
			if waiting {
				break
			}
			if err := pgIndexWait(wait, time.Millisecond); err != nil {
				t.Fatal(err)
			}
		}
		c := begin(third, 3)
		exec(c, `set local lock_timeout='1s'`)
		exec(c, `insert into notes.notes(id,title) values('cross','different-key')`)
		if err := c.Commit(ctx); err != nil {
			t.Fatal("cross-key write blocked", err)
		}
		if err := a.Commit(ctx); err != nil {
			t.Fatal(err)
		}
		duplicate(<-done, "title_unique")
	})
	t.Run("actual-expression-and-savepoint-values", func(t *testing.T) {
		tx := begin(request, 3)
		exec(tx, `insert into notes.notes(id,title) values('case-a','case'),('case-b','CASE')`)
		exec(tx, "savepoint changed")
		_, err := tx.Exec(ctx, `update notes.notes set title=upper(title) where id='case-a'`)
		duplicate(err, "title_unique")
		exec(tx, "rollback to changed")
		exec(tx, `update notes.notes set token='repair' where title='overlap'`)
		exec(tx, "savepoint changed")
		exec(tx, `update notes.notes set title='rolled-back' where id='case-a'`)
		exec(tx, "rollback to changed")
		exec(tx, `insert into notes.notes(id,title) values('after-rollback','rolled-back')`)
		if err := tx.Commit(ctx); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("catalog-and-managed-lifecycle", func(t *testing.T) {
		refuse := func(reason string) {
			t.Helper()
			tx := begin(request, 3)
			_, err := tx.Exec(ctx, `insert into notes.notes(id,title) values('unsafe','unsafe')`)
			_ = tx.Rollback(ctx)
			if err == nil || !strings.Contains(err.Error(), reason) {
				t.Fatalf("expected %s, got %v", reason, err)
			}
		}
		for _, ddl := range []string{`create index unsafe_guard on notes.notes(id,title)`, `create index unsafe_guard on notes.notes(id) include(title)`} {
			if _, err := f.worker.Exec(ctx, ddl); err != nil {
				t.Fatal(err)
			}
			refuse("unsafe guard index path")
			if _, err := f.worker.Exec(ctx, `drop index notes.unsafe_guard`); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := f.installer.Exec(ctx, `update pg_catalog.pg_index set indcheckxmin=true where indexrelid='notes.title_lookup'::regclass`); err != nil {
			t.Fatal(err)
		}
		refuse("unsafe guard index path")
		if _, err := f.installer.Exec(ctx, `update pg_catalog.pg_index set indcheckxmin=false where indexrelid='notes.title_lookup'::regclass`); err != nil {
			t.Fatal(err)
		}
		if _, err := f.installer.Exec(ctx, `alter tablespace pg_default set(random_page_cost=1000000000000)`); err != nil {
			t.Fatal(err)
		}
		refuse("tablespace costs")
		if _, err := f.installer.Exec(ctx, `alter tablespace pg_default reset(random_page_cost)`); err != nil {
			t.Fatal(err)
		}
		for _, sql := range []string{
			`select notes.tesl_stage_guard_body('{}')`,
			`select notes.tesl_stage_guard_spec(3,''::bytea)`,
			`delete from notes.tesl_schema_stage_guards`,
			`select notes.tesl_activate_stage_guards(4)`,
			`select notes.tesl_register_index(repeat('a',64),3,0,'notes','unsafe_guard',array['title'],false)`,
			`select notes.tesl_register_row_physical(4,'',''::bytea,'','','',0,true)`,
			`select notes.tesl_register_row_contract(3,'',''::bytea,'','',''::bytea,'',0,0,'')`,
		} {
			if _, err := f.worker.Exec(ctx, sql); err == nil {
				t.Fatal("Worker bypassed closed guard lifecycle", sql)
			}
		}
	})
	// Old admitted producers retain their semantics even after guard activation.
	pgCallRowAccessApp(t, ctx, older, "PUT", "/edit", 200)
	pgStageInstall(t, f, root, "v3")
	if out, err := pgRowAdditiveCommand(f, root, "v3", "--schema", "close-epoch", "--through", "V3", "--force", "--json").CombinedOutput(); err != nil {
		t.Fatalf("retire older producers: %v %s", err, out)
	}
	if _, err := request.Exec(ctx, `select notes.tesl_admit_writer(2)`); err == nil || !strings.Contains(err.Error(), "retired") {
		t.Fatal("retired V2 selected unguarded mode", err)
	}
	if _, err := request.Exec(ctx, `select notes.tesl_admit_writer(4)`); err == nil {
		t.Fatal("future V4 selected unguarded mode")
	}
	tx = begin(request, 3)
	_, err = tx.Exec(ctx, `insert into notes.notes(id,title) values('after-floor','edited')`)
	duplicate(err, "title_unique")
	_ = tx.Rollback(ctx)
}

func TestPgStageGuardActivationBoundary(t *testing.T) {
	root := os.Getenv("TESL_STAGE_GUARD_PROGRAMS")
	if root == "" {
		t.Skip("compiled guarded programs required")
	}
	t.Setenv("TESL_SCHEMA_POLL_S", "1")
	f, request := pgNewWorkerTest(t)
	f.namespace = "notes"
	pgStageInstall(t, f, root, "v3")
	if out, err := pgRowAdditiveCommand(f, root, "v3", "--schema", "catch-up", "--json").CombinedOutput(); err != nil {
		t.Fatalf("guarded catch-up: %v %s", err, out)
	}
	var id, hash string
	var descriptor, spec []byte
	if err := f.installer.QueryRow(f.ctx, `select stage_id,descriptor,physical_hash,spec from notes.tesl_schema_stage_guards order by stage_id limit 1`).Scan(&id, &descriptor, &hash, &spec); err != nil {
		t.Fatal(err)
	}
	for _, mutation := range []string{
		`update notes.tesl_schema_stage_guards set descriptor=descriptor||'x'::bytea where stage_id=$1`,
		`update notes.tesl_schema_stage_guards set physical_hash=repeat('0',64) where stage_id=$1`,
		`update notes.tesl_schema_stage_guards set spec=jsonb_set(spec,'{target}','"forged"'::jsonb) where stage_id=$1`,
	} {
		if _, err := f.installer.Exec(f.ctx, mutation, id); err != nil {
			t.Fatal(err)
		}
		if _, err := request.Exec(f.ctx, `select notes.tesl_admit_writer(3)`); err == nil {
			t.Fatal("tampered activation admitted V3", mutation)
		}
		if out, err := pgRowAdditiveCommand(f, root, "v3", "--schema", "status", "--json").CombinedOutput(); err == nil {
			t.Fatal("tampered activation passed closed catalog", mutation, string(out))
		}
		if _, err := f.installer.Exec(f.ctx, `update notes.tesl_schema_stage_guards set descriptor=$2,physical_hash=$3,spec=$4 where stage_id=$1`, id, descriptor, hash, spec); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := f.installer.Exec(f.ctx, `update notes.tesl_schema_index set state='failed' where id=(select job_id from notes.tesl_schema_stages where stage_id=$1)`, id); err != nil {
		t.Fatal(err)
	}
	if _, err := request.Exec(f.ctx, `select notes.tesl_admit_writer(3)`); err == nil {
		t.Fatal("V3 admission ignored invalid prep job")
	}
	if _, err := f.installer.Exec(f.ctx, `update notes.tesl_schema_index set state='valid' where id=(select job_id from notes.tesl_schema_stages where stage_id=$1)`, id); err != nil {
		t.Fatal(err)
	}
	pgStageInstall(t, f, root, "v3")
}
