package teslrt

import (
	"context"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

type pgControlTestFixture struct {
	ctx               context.Context
	installer, worker *pgx.Conn
	namespace         string
	roles             PgMigrationControlRoles
}

func pgNewControlTest(t *testing.T) *pgControlTestFixture {
	t.Helper()
	config := liveCluster(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	admin, err := pgx.Connect(ctx, postgresDSN(config))
	if err != nil {
		t.Fatal(err)
	}
	name := "ctl_" + strings.ReplaceAll(UUIDv7(), "-", "")
	f := &pgControlTestFixture{ctx: ctx, namespace: "notes_app", roles: PgMigrationControlRoles{Owner: name + "_owner", Worker: name + "_worker"}}
	t.Cleanup(func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		if f.worker != nil {
			_ = f.worker.Close(cleanup)
		}
		if f.installer != nil {
			_ = f.installer.Close(cleanup)
		}
		_, _ = admin.Exec(cleanup, "drop database if exists "+quoteIdentifier(name)+" with (force)")
		_, _ = admin.Exec(cleanup, "drop role if exists "+quoteIdentifier(f.roles.Worker))
		_, _ = admin.Exec(cleanup, "drop role if exists "+quoteIdentifier(f.roles.Owner))
		_ = admin.Close(cleanup)
	})
	for _, statement := range []string{
		"create role " + quoteIdentifier(f.roles.Owner) + " nologin",
		"create role " + quoteIdentifier(f.roles.Worker) + " login",
		"create database " + quoteIdentifier(name),
		"grant create on database " + quoteIdentifier(name) + " to " + quoteIdentifier(f.roles.Owner),
	} {
		if _, err := admin.Exec(ctx, statement); err != nil {
			t.Fatal(err)
		}
	}
	config.DBName = name
	f.installer, err = pgx.Connect(ctx, postgresDSN(config))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.installer.Exec(ctx, "grant create on schema public to "+quoteIdentifier(f.roles.Owner)); err != nil {
		t.Fatal(err)
	}
	config.User = f.roles.Worker
	f.worker, err = pgx.Connect(ctx, postgresDSN(config))
	if err != nil {
		t.Fatal(err)
	}
	return f
}

func (f *pgControlTestFixture) install(t *testing.T, version int) PgMigrationControlState {
	t.Helper()
	state, err := InstallPgMigrationControl(f.ctx, f.installer, f.namespace, f.roles, version)
	if err != nil {
		t.Fatal(err)
	}
	return state
}

func (f *pgControlTestFixture) call(t *testing.T, sql string, args ...any) {
	t.Helper()
	if _, err := f.worker.Exec(f.ctx, sql, args...); err != nil {
		t.Fatal(err)
	}
}

func TestPgMigrationControlInstallsAndInspectsWithoutEntityDDL(t *testing.T) {
	f := pgNewControlTest(t)
	before, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
	if err != nil || before.Present {
		t.Fatalf("empty control: %+v, %v", before, err)
	}
	state := f.install(t, 7)
	if !state.Present || state.InitialVersion != 7 || state.InstallingVersion != 7 || state.Current != 0 || state.MinVersion != 0 ||
		state.FenceNamespace < 1 || state.DatabaseUUID == "" || len(state.Versions) != 0 {
		t.Fatalf("unexpected installation state: %+v", state)
	}
	inspected, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
	if err != nil || !reflect.DeepEqual(state, inspected) {
		t.Fatalf("worker inspection differs: %+v, %v", inspected, err)
	}
	// A later binary cannot replace an interrupted installer's target.
	retry := f.install(t, 9)
	if !reflect.DeepEqual(state, retry) {
		t.Fatal("installer retry replaced initial identity or target")
	}
	var count int
	if err := f.installer.QueryRow(f.ctx, "select count(*) from pg_catalog.pg_tables where schemaname=$1", f.namespace).Scan(&count); err != nil || count != len(pgMigrationControlTables) {
		t.Fatalf("installer created unexpected entity tables: %d, %v", count, err)
	}
	if f.installer.PgConn().TxStatus() != 'I' || f.worker.PgConn().TxStatus() != 'I' {
		t.Fatal("control inspection retained a transaction")
	}
}

func TestPgMigrationControlQuotedNamespaceIsData(t *testing.T) {
	f := pgNewControlTest(t)
	f.namespace = "control '$tesl_control$\"\\雪"
	state := f.install(t, 1)
	got, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
	if err != nil || !reflect.DeepEqual(state, got) {
		t.Fatalf("quoted namespace changed control definitions: %+v, %v", got, err)
	}
}

func TestPgMigrationControlRecordsCompleteImmutableExpansion(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 7)
	ns := quoteIdentifier(f.namespace) + "."
	snap, art := strings.Repeat("a", 64), strings.Repeat("b", 64)
	object := "c7c61b7c4be08d91cc48acdf4a9d2aec3b970d284008dd4a0d8ac02b9a2f5d4b"
	if _, err := f.worker.Exec(f.ctx, "select "+ns+"tesl_admit(7)"); err == nil {
		t.Fatal("uninstalled version admitted")
	}
	begin := "select " + ns + "tesl_begin_expansion($1::integer,$2::text,$3::text,$4::text,$5::integer,$6::boolean)"
	f.call(t, begin, 7, snap, art, "source-abi", 1, true)
	f.call(t, begin, 7, snap, art, "source-abi", 1, true)
	for _, args := range [][]any{{7, snap, object, "source-abi", 1, true}, {7, snap, art, "changed-abi", 1, true}, {7, snap, art, "source-abi", 2, true}, {8, snap, art, "source-abi", 0, true}, {7, snap, art, "source-abi", 1, false}} {
		if _, err := f.worker.Exec(f.ctx, begin, args...); err == nil {
			t.Fatalf("invalid intent accepted: %+v", args)
		}
	}
	if _, err := f.worker.Exec(f.ctx, "select "+ns+"tesl_record_expanded(7)"); err == nil {
		t.Fatal("incomplete objects recorded as expanded")
	}
	mark := "select " + ns + "tesl_record_expansion_object($1::integer,$2::integer,$3::text)"
	f.call(t, mark, 7, 0, object)
	f.call(t, mark, 7, 0, object)
	for _, args := range [][]any{{7, 0, art}, {7, 1, object}, {7, -1, object}, {8, 0, object}} {
		if _, err := f.worker.Exec(f.ctx, mark, args...); err == nil {
			t.Fatalf("invalid object record accepted: %+v", args)
		}
	}
	f.call(t, "select "+ns+"tesl_record_expanded(7)")
	f.call(t, "select "+ns+"tesl_record_expanded(7)")
	state, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
	if err != nil || state.Current != 7 || state.MinVersion != 7 || state.CompatFloor != 7 || state.InstallingVersion != 0 || len(state.Versions) != 3 {
		t.Fatalf("initial completion: %+v, %v", state, err)
	}
	f.call(t, "select "+ns+"tesl_admit(7)")
	for _, version := range []int{0, 6, 8} {
		if _, err := f.worker.Exec(f.ctx, "select "+ns+"tesl_admit($1::integer)", version); err == nil {
			t.Fatalf("unadmitted version accepted: %d", version)
		}
	}
	for _, version := range []int{8, 9, 10} {
		f.call(t, begin, version, snap, art, "source-abi", 0, true)
		f.call(t, "select "+ns+"tesl_record_expanded($1::integer)", version)
	}
	// The additive epoch admits V7 at V10 without pretending only two versions
	// are present. Source identity matching remains the executor's obligation.
	f.call(t, "select "+ns+"tesl_admit(7)")
	f.call(t, "set application_name='tesl-app:control-test'")
	f.call(t, "select "+ns+"tesl_heartbeat(7,1,7)")
	var instance string
	if err := f.worker.QueryRow(f.ctx, "select instance from "+ns+"tesl_schema_instances").Scan(&instance); err != nil || instance != "tesl-app:control-test" {
		t.Fatalf("heartbeat: %s, %v", instance, err)
	}
}

func TestPgMigrationControlWorkerCannotOwnOrRewriteControl(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	if _, err := InstallPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles, 1); err == nil {
		t.Fatal("worker used installer authority")
	}
	ns := quoteIdentifier(f.namespace) + "."
	for _, sql := range []string{
		"set role " + quoteIdentifier(f.roles.Owner),
		"update " + ns + "tesl_schema_state set min_version=99",
		"insert into " + ns + "tesl_schema_expansion_objects values(1,0,'forged',now())",
		"delete from " + ns + "tesl_schema_meta",
		"truncate " + ns + "tesl_schema_versions",
		"alter table " + ns + "tesl_schema_state add column forged text",
		"drop schema " + quoteIdentifier(f.namespace) + " cascade",
		"insert into public.tesl_fence_namespaces(database_uuid) values(gen_random_uuid())",
		"select nextval('public.tesl_fence_namespaces_fence_ns_seq')",
	} {
		if _, err := f.worker.Exec(f.ctx, sql); err == nil {
			t.Fatalf("worker crossed the control boundary: %s", sql)
		}
	}
	// Entity DDL belongs to the worker, independently of protected control state.
	f.call(t, "create table "+ns+"notes(id text primary key)")
	f.call(t, "insert into "+ns+"notes values('kept')")
	state, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
	if err != nil || state.Current != 0 {
		t.Fatalf("ordinary worker DDL damaged control inspection: %+v, %v", state, err)
	}
	var owner string
	if err := f.worker.QueryRow(f.ctx, `select r.rolname from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
 join pg_catalog.pg_roles r on r.oid=c.relowner where n.nspname=$1 and c.relname='notes'`, f.namespace).Scan(&owner); err != nil || owner != f.roles.Worker {
		t.Fatalf("entity ownership: %s, %v", owner, err)
	}
}

func TestPgMigrationControlRejectsLookalikesWithoutAdoption(t *testing.T) {
	for _, kind := range []string{"registry", "namespace", "populated"} {
		t.Run(kind, func(t *testing.T) {
			f := pgNewControlTest(t)
			var sql string
			switch kind {
			case "registry":
				sql = "create table public.tesl_fence_namespaces (" + pgMigrationFenceRegistry.columns + ")"
			case "namespace":
				sql = "create schema " + quoteIdentifier(f.namespace)
			case "populated":
				sql = fmt.Sprintf("create schema %s authorization %s; create table %s.notes(id text primary key)", quoteIdentifier(f.namespace), quoteIdentifier(f.roles.Owner), quoteIdentifier(f.namespace))
			}
			if _, err := f.installer.Exec(f.ctx, sql); err != nil {
				t.Fatal(err)
			}
			if state, err := InstallPgMigrationControl(f.ctx, f.installer, f.namespace, f.roles, 1); err == nil || state.Present {
				t.Fatalf("lookalike silently adopted: %+v, %v", state, err)
			}
			var created bool
			if err := f.installer.QueryRow(f.ctx, `select exists(select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
 where n.nspname=$1 and c.relname='tesl_schema_meta')`, f.namespace).Scan(&created); err != nil || created {
				t.Fatalf("failed installation committed control state: %v, %v", created, err)
			}
		})
	}
}

func TestPgMigrationControlRejectsProtectedCatalogDrift(t *testing.T) {
	for name, mutation := range map[string]func(*pgControlTestFixture) string{
		"table owner": func(f *pgControlTestFixture) string {
			return "alter table notes_app.tesl_schema_state owner to " + quoteIdentifier(f.roles.Worker)
		},
		"extra nullable column": func(*pgControlTestFixture) string {
			return "alter table notes_app.tesl_schema_state add column extra text"
		},
		"changed type": func(*pgControlTestFixture) string {
			return "alter table notes_app.tesl_schema_state alter column current type bigint"
		},
		"changed nullability": func(*pgControlTestFixture) string {
			return "alter table notes_app.tesl_schema_state alter column current drop not null"
		},
		"changed default": func(*pgControlTestFixture) string {
			return "alter table notes_app.tesl_schema_state alter column compat_floor set default 1"
		},
		"changed check": func(*pgControlTestFixture) string {
			return "alter table notes_app.tesl_schema_state drop constraint tesl_schema_state_id_check; alter table notes_app.tesl_schema_state add check (id between 0 and 2)"
		},
		"extra index": func(*pgControlTestFixture) string {
			return "create index extra_control on notes_app.tesl_schema_state(current)"
		},
		"RLS": func(*pgControlTestFixture) string {
			return "alter table notes_app.tesl_schema_state enable row level security"
		},
		"table write grant": func(f *pgControlTestFixture) string {
			return "grant update on notes_app.tesl_schema_state to " + quoteIdentifier(f.roles.Worker)
		},
		"column write grant": func(f *pgControlTestFixture) string {
			return "grant update(min_version) on notes_app.tesl_schema_state to " + quoteIdentifier(f.roles.Worker)
		},
		"PUBLIC write grant": func(*pgControlTestFixture) string { return "grant insert on notes_app.tesl_schema_versions to public" },
		"registry sequence cycle": func(*pgControlTestFixture) string {
			return "alter sequence public.tesl_fence_namespaces_fence_ns_seq cycle"
		},
		"registry sequence increment": func(*pgControlTestFixture) string {
			return "alter sequence public.tesl_fence_namespaces_fence_ns_seq increment 2"
		},
		"registry sequence cache": func(*pgControlTestFixture) string {
			return "alter sequence public.tesl_fence_namespaces_fence_ns_seq cache 4"
		},
		"registry sequence grant": func(f *pgControlTestFixture) string {
			return "grant usage on sequence public.tesl_fence_namespaces_fence_ns_seq to " + quoteIdentifier(f.roles.Worker)
		},
		"registry write grant": func(f *pgControlTestFixture) string {
			return "grant delete on public.tesl_fence_namespaces to " + quoteIdentifier(f.roles.Worker)
		},
		"function owner": func(f *pgControlTestFixture) string {
			return "alter function notes_app.tesl_admit(integer) owner to " + quoteIdentifier(f.roles.Worker)
		},
		"function body": func(*pgControlTestFixture) string {
			return "create or replace function notes_app.tesl_admit(v integer) returns integer language plpgsql stable security definer set search_path='' as 'begin return 0; end'"
		},
		"function invoker": func(*pgControlTestFixture) string {
			return "alter function notes_app.tesl_admit(integer) security invoker"
		},
		"function search path": func(*pgControlTestFixture) string {
			return "alter function notes_app.tesl_admit(integer) set search_path=public"
		},
		"function strict":     func(*pgControlTestFixture) string { return "alter function notes_app.tesl_admit(integer) strict" },
		"function volatility": func(*pgControlTestFixture) string { return "alter function notes_app.tesl_admit(integer) immutable" },
		"function parallel": func(*pgControlTestFixture) string {
			return "alter function notes_app.tesl_admit(integer) parallel safe"
		},
		"function PUBLIC execution": func(*pgControlTestFixture) string {
			return "grant execute on function notes_app.tesl_record_expanded(integer) to public"
		},
		"function grant option": func(f *pgControlTestFixture) string {
			return "grant execute on function notes_app.tesl_admit(integer) to " + quoteIdentifier(f.roles.Worker) + " with grant option"
		},
		"extra owner function": func(f *pgControlTestFixture) string {
			return "create function notes_app.unrecorded() returns integer language sql as 'select 1'; alter function notes_app.unrecorded() owner to " + quoteIdentifier(f.roles.Owner)
		},
		"namespace PUBLIC create": func(*pgControlTestFixture) string { return "grant create on schema notes_app to public" },
		"owner LOGIN":             func(f *pgControlTestFixture) string { return "alter role " + quoteIdentifier(f.roles.Owner) + " login" },
		"worker administrative": func(f *pgControlTestFixture) string {
			return "alter role " + quoteIdentifier(f.roles.Worker) + " createrole"
		},
		"worker owner membership": func(f *pgControlTestFixture) string {
			return "grant " + quoteIdentifier(f.roles.Owner) + " to " + quoteIdentifier(f.roles.Worker)
		},
		"registry identity mismatch": func(*pgControlTestFixture) string {
			return "update notes_app.tesl_schema_meta set database_uuid=pg_catalog.gen_random_uuid()"
		},
		"state singleton missing": func(*pgControlTestFixture) string { return "delete from notes_app.tesl_schema_state" },
		"unknown control format":  func(*pgControlTestFixture) string { return "update notes_app.tesl_schema_meta set format_version=999" },
		"unknown fence domain": func(*pgControlTestFixture) string {
			return "update notes_app.tesl_schema_meta set fence_domain='hashtext'"
		},
		"changed install target": func(*pgControlTestFixture) string {
			return "update notes_app.tesl_schema_state set installing_version=9"
		},
	} {
		t.Run(name, func(t *testing.T) {
			f := pgNewControlTest(t)
			f.install(t, 1)
			if _, err := f.installer.Exec(f.ctx, mutation(f)); err != nil {
				t.Fatal(err)
			}
			if state, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles); err == nil || state.Present {
				t.Fatalf("protected catalog drift accepted: %+v, %v", state, err)
			}
		})
	}
}

func pgWaitControlLock(t *testing.T, f *pgControlTestFixture, pids []uint32) {
	t.Helper()
	ticker := time.NewTicker(5 * time.Millisecond)
	defer ticker.Stop()
	for {
		var waiting int
		if err := f.installer.QueryRow(f.ctx, "select count(*) from pg_catalog.pg_locks where locktype='advisory' and not granted and pid=any($1::integer[])", pids).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting == len(pids) {
			return
		}
		select {
		case <-f.ctx.Done():
			t.Fatal("control installers did not reach the blocked boot lock")
		case <-ticker.C:
		}
	}
}

func TestPgMigrationControlConcurrentInstallersUseTheCommittedWinner(t *testing.T) {
	f := pgNewControlTest(t)
	if _, err := f.installer.Exec(f.ctx, "select pg_catalog.pg_advisory_lock(32341,0)"); err != nil {
		t.Fatal(err)
	}
	type result struct {
		state PgMigrationControlState
		err   error
	}
	results := make(chan result, 2)
	var pids []uint32
	for _, version := range []int{7, 9} {
		conn, err := pgx.ConnectConfig(f.ctx, f.installer.Config().Copy())
		if err != nil {
			t.Fatal(err)
		}
		pids = append(pids, conn.PgConn().PID())
		go func(version int) {
			state, err := InstallPgMigrationControl(f.ctx, conn, f.namespace, f.roles, version)
			_ = conn.Close(context.Background())
			results <- result{state, err}
		}(version)
	}
	pgWaitControlLock(t, f, pids)
	if _, err := f.installer.Exec(f.ctx, "select pg_catalog.pg_advisory_unlock(32341,0)"); err != nil {
		t.Fatal(err)
	}
	first, second := <-results, <-results
	if first.err != nil || second.err != nil || !reflect.DeepEqual(first.state, second.state) {
		t.Fatalf("concurrent installers disagreed: %+v / %+v", first, second)
	}
	if first.state.InitialVersion != 7 && first.state.InitialVersion != 9 {
		t.Fatalf("unrequested initial version: %+v", first.state)
	}
	var entries int
	if err := f.installer.QueryRow(f.ctx, "select count(*) from public.tesl_fence_namespaces").Scan(&entries); err != nil || entries != 1 {
		t.Fatalf("concurrent installation allocated multiple identities: %d, %v", entries, err)
	}
}

func TestPgMigrationControlAllocatesDistinctFamilies(t *testing.T) {
	f := pgNewControlTest(t)
	first := f.install(t, 7)
	f.namespace = "other_app"
	second := f.install(t, 9)
	if first.DatabaseUUID == second.DatabaseUUID || first.FenceNamespace == second.FenceNamespace || second.InitialVersion != 9 {
		t.Fatalf("schema families share control identity: %+v / %+v", first, second)
	}
}

func TestPgMigrationControlNeverEvaluatesLiveDefaults(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	if _, err := f.installer.Exec(f.ctx, `create sequence notes_app.counter;
alter table notes_app.tesl_schema_state alter column current set default pg_catalog.nextval('notes_app.counter')`); err != nil {
		t.Fatal(err)
	}
	if _, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles); err == nil {
		t.Fatal("computing control default accepted")
	}
	var called bool
	if err := f.installer.QueryRow(f.ctx, "select is_called from notes_app.counter").Scan(&called); err != nil || called {
		t.Fatalf("inspection evaluated a live default: %v, %v", called, err)
	}
}

func TestPgMigrationControlChecksInheritedCapabilities(t *testing.T) {
	for _, role := range []string{"pg_write_all_data", "pg_signal_backend", "pg_execute_server_program", "pg_read_server_files", "pg_write_server_files"} {
		t.Run(role, func(t *testing.T) {
			f := pgNewControlTest(t)
			f.install(t, 1)
			if _, err := f.installer.Exec(f.ctx, "grant "+quoteIdentifier(role)+" to "+quoteIdentifier(f.roles.Worker)); err != nil {
				t.Fatal(err)
			}
			if role == "pg_write_all_data" {
				// No explicit table ACL changed, but this predefined role really
				// bypasses the intended control boundary. Pin the counterexample.
				if _, err := f.worker.Exec(f.ctx, "update notes_app.tesl_schema_state set current=0"); err != nil {
					t.Fatalf("fixture did not acquire implicit control write authority: %v", err)
				}
			}
			if _, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles); err == nil {
				t.Fatal("inherited privileged role accepted")
			}
		})
	}
	t.Run("monitoring is allowed", func(t *testing.T) {
		f := pgNewControlTest(t)
		before := f.install(t, 1)
		if _, err := f.installer.Exec(f.ctx, "grant pg_monitor to "+quoteIdentifier(f.roles.Worker)); err != nil {
			t.Fatal(err)
		}
		after, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
		if err != nil || !reflect.DeepEqual(before, after) {
			t.Fatalf("read-only monitoring changed control authority: %+v, %v", after, err)
		}
	})
}

func TestPgMigrationControlCancellationReleasesOwnership(t *testing.T) {
	f := pgNewControlTest(t)
	if _, err := f.installer.Exec(f.ctx, "select pg_catalog.pg_advisory_lock(32341,0)"); err != nil {
		t.Fatal(err)
	}
	conn, err := pgx.ConnectConfig(f.ctx, f.installer.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(f.ctx)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := InstallPgMigrationControl(ctx, conn, f.namespace, f.roles, 7)
		done <- err
	}()
	pgWaitControlLock(t, f, []uint32{conn.PgConn().PID()})
	cancel()
	if err := <-done; err == nil || !conn.IsClosed() {
		t.Fatalf("cancelled acquisition retained an ambiguous backend: %v, closed=%v", err, conn.IsClosed())
	}
	if _, err := f.installer.Exec(f.ctx, "select pg_catalog.pg_advisory_unlock(32341,0)"); err != nil {
		t.Fatal(err)
	}
	// A later installer can still create a single complete control identity.
	f.install(t, 7)
}

func TestPgMigrationControlTemporaryInstallerMembershipMustBeRevoked(t *testing.T) {
	f := pgNewControlTest(t)
	setupRole := f.roles.Owner + "_setup"
	if _, err := f.installer.Exec(f.ctx, "create role "+quoteIdentifier(setupRole)+" login; grant "+quoteIdentifier(f.roles.Owner)+" to "+quoteIdentifier(setupRole)); err != nil {
		t.Fatal(err)
	}
	var setup *pgx.Conn
	t.Cleanup(func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		if setup != nil {
			_ = setup.Close(cleanup)
		}
		_, _ = f.installer.Exec(cleanup, "drop role "+quoteIdentifier(setupRole))
	})
	config := f.installer.Config().Copy()
	config.User = setupRole
	var err error
	setup, err = pgx.ConnectConfig(f.ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	state, err := InstallPgMigrationControl(f.ctx, setup, f.namespace, f.roles, 7)
	if err != nil {
		t.Fatal(err)
	}
	var currentRole string
	if err := setup.QueryRow(f.ctx, "select current_user").Scan(&currentRole); err != nil || currentRole != setupRole {
		t.Fatalf("installer retained SET ROLE authority outside its transaction: %s, %v", currentRole, err)
	}
	if _, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles); err == nil {
		t.Fatal("unrevoked installer membership was accepted as steady state")
	}
	if _, err := f.installer.Exec(f.ctx, "revoke "+quoteIdentifier(f.roles.Owner)+" from "+quoteIdentifier(setupRole)); err != nil {
		t.Fatal(err)
	}
	inspected, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
	if err != nil || !reflect.DeepEqual(state, inspected) {
		t.Fatalf("revoked installer did not leave a valid worker boundary: %+v, %v", inspected, err)
	}
}

func TestPgMigrationControlObjectProgressIsAnAtomicPrefix(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	step := PgMigrationExpansionStep{StepHash: strings.Repeat("b", 64), Operations: make([]PgMigrationExpansionOperation, 2)}
	f.call(t, "select notes_app.tesl_begin_expansion(1,$1::text,$2::text,'source-abi',2,true)", strings.Repeat("a", 64), step.StepHash)
	first, err := step.ObjectHash(0)
	if err != nil {
		t.Fatal(err)
	}
	second, err := step.ObjectHash(1)
	if err != nil {
		t.Fatal(err)
	}
	mark := "select notes_app.tesl_record_expansion_object(1,$1::integer,$2::text)"
	if _, err := f.worker.Exec(f.ctx, mark, 1, second); err == nil {
		t.Fatal("out-of-order progress accepted")
	}
	tx, err := f.worker.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(f.ctx, "create table notes_app.atomic_entity(id text primary key)"); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(f.ctx, mark, 0, first); err != nil {
		t.Fatal(err)
	}
	if err := tx.Rollback(f.ctx); err != nil {
		t.Fatal(err)
	}
	var count int
	if err := f.worker.QueryRow(f.ctx, "select count(*) from notes_app.tesl_schema_expansion_objects").Scan(&count); err != nil || count != 0 {
		t.Fatalf("rolled-back DDL retained durable progress: %d, %v", count, err)
	}
	f.call(t, mark, 0, first)
	f.call(t, mark, 1, second)
	f.call(t, "select notes_app.tesl_record_expanded(1)")
}
