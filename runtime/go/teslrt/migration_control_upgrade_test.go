package teslrt

import (
	"context"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Materialize the exact previous production schema, including its unchanged
// function bodies. These tests exercise the transactional runtime upgrade API;
// actual pre-bridge compiler/binary coverage is a separate pending acceptance gate.
func pgControlTestFormat2(t *testing.T, f *pgControlTestFixture) {
	t.Helper()
	for _, fn := range pgMigrationIndexFunctions(f.namespace) {
		if _, err := f.installer.Exec(f.ctx, "drop function "+pgx.Identifier{f.namespace, fn.name}.Sanitize()+"("+pgControlArgumentTypes(fn)+")"); err != nil {
			t.Fatal(err)
		}
	}
	for _, spec := range pgMigrationIndexTables {
		if _, err := f.installer.Exec(f.ctx, "drop table "+pgx.Identifier{f.namespace, spec.name}.Sanitize()); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := f.installer.Exec(f.ctx, "update "+quoteIdentifier(f.namespace)+".tesl_schema_meta set format_version=2"); err != nil {
		t.Fatal(err)
	}
}

func pgControlUpgradePreservedRows(t *testing.T, f *pgControlTestFixture) string {
	t.Helper()
	var data string
	if err := f.installer.QueryRow(f.ctx, `select pg_catalog.jsonb_build_array(
 (select pg_catalog.to_jsonb(m)-'format_version' from notes_app.tesl_schema_meta m),
 (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(s)) from notes_app.tesl_schema_state s),
 (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(v) order by version,step,seq) from notes_app.tesl_schema_versions v),
 (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(e) order by version) from notes_app.tesl_schema_expansions e),
 (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(o) order by version,ordinal) from notes_app.tesl_schema_expansion_objects o),
 (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(i) order by instance) from notes_app.tesl_schema_instances i),
 (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(n) order by id) from notes_app.notes n))::text`).Scan(&data); err != nil {
		t.Fatal(err)
	}
	return data
}

func TestPgMigrationControlUpgradePreservesCompletedHistoryAndIdentity(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	f.expand(t, 3)
	f.call(t, "insert into notes_app.notes(id,active) values('retained',true)")
	pgControlTestFormat2(t, f)
	before, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
	if err != nil || before.Format != 2 {
		t.Fatalf("bridge could not inspect exact format2: %+v %v", before, err)
	}
	preserved := pgControlUpgradePreservedRows(t, f)
	history := pgCompatibilityTestCompiler(pgExpansionTestHistory(f.namespace, 3), "b")
	state, err := UpgradePgCompiledMigrationControl(f.ctx, f.installer, history, f.roles, 3)
	if err != nil || state.Format != 3 {
		t.Fatalf("upgrade: %+v %v", state, err)
	}
	expected := before
	expected.Format = 3
	if !reflect.DeepEqual(state, expected) || pgControlUpgradePreservedRows(t, f) != preserved {
		t.Fatal("control upgrade rewrote completed history, source ABI, rows or identity")
	}
	for i := 0; i < 2; i++ {
		retry, err := UpgradePgCompiledMigrationControl(f.ctx, f.installer, history, f.roles, 3)
		if err != nil || !reflect.DeepEqual(retry, state) || pgControlUpgradePreservedRows(t, f) != preserved {
			t.Fatalf("retry changed a completed upgrade: %+v %v", retry, err)
		}
	}
	f.call(t, "insert into notes_app.notes(id,active) values('old-writer-after-upgrade',false)")
}

func TestPgMigrationControlUpgradeRefusesBeforeMutation(t *testing.T) {
	for _, scenario := range []string{"worker identity", "unsupported target", "unfinished intent", "older source", "different contract", "drift", "hidden table", "hidden worker table", "hidden function"} {
		t.Run(scenario, func(t *testing.T) {
			f := pgNewControlTest(t)
			f.install(t, 1)
			f.expand(t, 2)
			pgControlTestFormat2(t, f)
			history, conn, target := pgExpansionTestHistory(f.namespace, 2), f.installer, 3
			switch scenario {
			case "worker identity":
				conn = f.worker
			case "unsupported target":
				target = 4
			case "unfinished intent":
				history = pgExpansionTestHistory(f.namespace, 3)
				plan, err := history.ExpansionPlan(1)
				if err != nil {
					t.Fatal(err)
				}
				s := plan.Steps[2]
				f.call(t, "select notes_app.tesl_begin_expansion(3,$1,$2,$3,$4,$5,true)", s.SnapshotHash, s.StepHash, history.SourceCompilerABI, history.StoredValueCompatibility, len(s.Operations))
			case "older source":
				history = pgExpansionTestHistory(f.namespace, 1)
			case "different contract":
				history.StoredValueCompatibility = "tesl-stored-value-v1:" + strings.Repeat("d", 64)
			case "drift":
				f.call(t, "alter table notes_app.notes alter active drop not null")
			case "hidden table", "hidden worker table":
				owner, name := f.roles.Owner, "hidden_control_relation"
				if scenario == "hidden worker table" {
					owner, name = f.roles.Worker, "tesl_schema_index"
				}
				if _, err := f.installer.Exec(f.ctx, "create table notes_app."+name+" (id integer); alter table notes_app."+name+" owner to "+quoteIdentifier(owner)); err != nil {
					t.Fatal(err)
				}
			case "hidden function":
				if _, err := f.installer.Exec(f.ctx, "create function notes_app.hidden() returns integer language sql as 'select 1'; alter function notes_app.hidden() owner to "+quoteIdentifier(f.roles.Owner)); err != nil {
					t.Fatal(err)
				}
			}
			before := pgControlUpgradePreservedRows(t, f)
			if _, err := UpgradePgCompiledMigrationControl(f.ctx, conn, history, f.roles, target); err == nil {
				t.Fatal("unsafe upgrade was accepted")
			}
			if before != pgControlUpgradePreservedRows(t, f) {
				t.Fatal("refused upgrade changed original history or rows")
			}
			var format, functions int
			if err := f.installer.QueryRow(f.ctx, "select format_version,(select count(*) from pg_catalog.pg_proc where pronamespace='notes_app'::regnamespace and proname='tesl_claim_index') from notes_app.tesl_schema_meta").Scan(&format, &functions); err != nil || format != 2 || functions != 0 {
				t.Fatalf("refused upgrade published format3: %d %d %v", format, functions, err)
			}
		})
	}
}

func TestPgMigrationControlUpgradeWaitCancellationReleasesLocks(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	state := f.expand(t, 1)
	pgControlTestFormat2(t, f)
	f.call(t, "select pg_catalog.pg_advisory_lock($1::integer,2147483647)", state.FenceNamespace)
	blocked, err := pgx.ConnectConfig(f.ctx, f.installer.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = blocked.Close(context.Background()) }()
	ctx, cancel := context.WithCancel(f.ctx)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := UpgradePgCompiledMigrationControl(ctx, blocked, pgExpansionTestHistory(f.namespace, 1), f.roles, 3)
		done <- err
	}()
	pgWaitControlLock(t, f, []uint32{blocked.PgConn().PID()})
	cancel()
	if err := <-done; err == nil {
		t.Fatal("cancelled upgrade acquired coordination authority")
	}
	f.call(t, "select pg_catalog.pg_advisory_unlock($1::integer,2147483647)", state.FenceNamespace)
	// A fresh connection is the real retry path; cancelled pgx operations may
	// legitimately close their borrowed connection.
	conn, err := pgx.ConnectConfig(f.ctx, f.installer.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(context.Background()) }()
	ctx, stop := context.WithTimeout(f.ctx, 2*time.Second)
	defer stop()
	if _, err := UpgradePgCompiledMigrationControl(ctx, conn, pgExpansionTestHistory(f.namespace, 1), f.roles, 3); err != nil {
		t.Fatalf("cancelled upgrade obstructed a fresh retry: %v", err)
	}
}

func TestPgMigrationControlUpgradeTakesBootBeforeInstallerLock(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	state := f.expand(t, 1)
	pgControlTestFormat2(t, f)
	f.call(t, "select pg_catalog.pg_advisory_lock($1::integer,2147483647)", state.FenceNamespace)
	conn, err := pgx.ConnectConfig(f.ctx, f.installer.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(context.Background()) }()
	done := make(chan error, 1)
	go func() {
		_, err := UpgradePgCompiledMigrationControl(f.ctx, conn, pgExpansionTestHistory(f.namespace, 1), f.roles, 3)
		done <- err
	}()
	pgWaitControlLock(t, f, []uint32{conn.PgConn().PID()})
	var shared bool
	if err := f.worker.QueryRow(f.ctx, "select pg_catalog.pg_try_advisory_lock_shared(32341,0)").Scan(&shared); err != nil || !shared {
		t.Fatalf("upgrade inverted the expander's boot/installer lock order: %v %v", shared, err)
	}
	f.call(t, "select pg_catalog.pg_advisory_unlock_shared(32341,0)")
	f.call(t, "select pg_catalog.pg_advisory_unlock($1::integer,2147483647)", state.FenceNamespace)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestPgMigrationControlUpgradeRechecksInstallationAfterLockWait(t *testing.T) {
	for _, mutation := range []string{
		"update notes_app.tesl_schema_meta set fence_ns=fence_ns+1",
		"with changed as (update public.tesl_fence_namespaces set database_uuid=gen_random_uuid() returning database_uuid) update notes_app.tesl_schema_meta set database_uuid=(select database_uuid from changed)",
	} {
		f := pgNewControlTest(t)
		f.install(t, 1)
		state := f.expand(t, 1)
		pgControlTestFormat2(t, f)
		f.call(t, "select pg_catalog.pg_advisory_lock($1::integer,2147483647)", state.FenceNamespace)
		conn, err := pgx.ConnectConfig(f.ctx, f.installer.Config().Copy())
		if err != nil {
			t.Fatal(err)
		}
		done := make(chan error, 1)
		go func() {
			_, err := UpgradePgCompiledMigrationControl(f.ctx, conn, pgExpansionTestHistory(f.namespace, 1), f.roles, 3)
			_ = conn.Close(context.Background())
			done <- err
		}()
		pgWaitControlLock(t, f, []uint32{conn.PgConn().PID()})
		if _, err := f.installer.Exec(f.ctx, mutation); err != nil {
			t.Fatal(err)
		}
		f.call(t, "select pg_catalog.pg_advisory_unlock($1::integer,2147483647)", state.FenceNamespace)
		if err := <-done; err == nil {
			t.Fatal("upgrade used identity cached before the boot lock")
		}
		var format int
		if err := f.installer.QueryRow(f.ctx, "select format_version from notes_app.tesl_schema_meta").Scan(&format); err != nil || format != 2 {
			t.Fatalf("identity refusal committed upgrade: %d %v", format, err)
		}
	}
}
