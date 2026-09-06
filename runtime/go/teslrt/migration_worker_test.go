package teslrt

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func TestPgMigrationWorkerTopologyDefaultsAndDeclaredRoles(t *testing.T) {
	notDeployed(t)
	roles, err := pgMigrationRoles(PostgresConfig{}, "local_login")
	if err != nil || roles != (PgMigrationControlRoles{Owner: "tesl_control", Worker: "local_login"}) {
		t.Fatalf("local default: %+v %v", roles, err)
	}
	t.Setenv("TESL_DEPLOYED", "") // Presence, including an empty value, selects Worker.
	roles, err = pgMigrationRoles(PostgresConfig{}, "installer_login")
	if err != nil || roles != (PgMigrationControlRoles{Owner: "tesl_control", Worker: "tesl_schema", Request: "tesl_app"}) {
		t.Fatalf("deployed default derives roles from the installer: %+v %v", roles, err)
	}
	roles, err = pgMigrationRoles(PostgresConfig{MigrationTopology: "Embedded"}, "local_login")
	if err != nil || roles.Request != "" || roles.Worker != "local_login" {
		t.Fatalf("explicit Embedded: %+v %v", roles, err)
	}
	config := PostgresConfig{MigrationTopology: "Worker", ControlOwner: "owner", WorkerRole: "worker", RequestRole: "request"}
	roles, err = pgMigrationRoles(config, "unrelated_login")
	if err != nil || roles != (PgMigrationControlRoles{Owner: "owner", Worker: "worker", Request: "request"}) {
		t.Fatalf("declared roles: %+v %v", roles, err)
	}
	for _, invalid := range []PostgresConfig{
		{MigrationTopology: "worker"}, {MigrationTopology: "Embedded", RequestRole: "request"},
		{MigrationTopology: "Embedded", WorkerRole: "worker"},
	} {
		if _, err := pgMigrationRoles(invalid, "login"); err == nil {
			t.Fatalf("invalid topology accepted: %+v", invalid)
		}
	}
}

func TestPgMigrationWorkerDDLConnectionIsSeparateAndRedacted(t *testing.T) {
	for _, key := range []string{"PGHOST", "PGPORT", "PGUSER", "PGDATABASE", "PGPASSWORD", "PGSERVICE"} {
		t.Setenv(key, "")
		if err := os.Unsetenv(key); err != nil {
			t.Fatal(err)
		}
	}
	base := PostgresConfig{DBName: "app", User: "request", Host: "localhost", Port: 5432}
	parsed, err := pgMigrationDDLConfig(base)
	if err != nil || parsed.User != "request" || parsed.Database != "app" {
		t.Fatalf("omitted DDL connection: %+v %v", parsed, err)
	}
	base.DDLConnection = "postgres://worker:secret@127.0.0.1:6432/app?application_name=tesl-schema"
	parsed, err = pgMigrationDDLConfig(base)
	if err != nil || parsed.User != "worker" || parsed.Password != "secret" || parsed.Port != 6432 || parsed.RuntimeParams["application_name"] != "tesl-schema" {
		t.Fatalf("explicit DDL connection was not preserved: %v", err)
	}
	base.DDLConnection = "postgres://worker:never-print-this@[malformed"
	if _, err := pgMigrationDDLConfig(base); err == nil || strings.Contains(err.Error(), "never-print-this") {
		t.Fatalf("malformed DDL connection error exposed credentials: %v", err)
	}
}

func TestPgMigrationWorkerCommandArguments(t *testing.T) {
	for _, args := range [][]string{
		{"--schema", "worker", "--worker", "worker"}, {"--schema", "worker", "--request", "request"},
		{"--schema", "status", "--request", "request"}, {"--schema", "install", "--worker", "worker", "--request"},
		{"--schema", "install", "--worker", "worker", "--request", ""},
		{"--schema", "install", "--worker", "worker", "--request", "a", "--request", "b"},
	} {
		if _, handled, err := pgParseSchemaCommand(args); !handled || err == nil {
			t.Fatalf("invalid Worker command accepted: %v", args)
		}
	}
	for _, args := range [][]string{
		{"--schema", "worker", "--json"},
		{"--schema", "install", "--worker", "worker", "--request", "request", "--json"},
	} {
		if _, handled, err := pgParseSchemaCommand(args); !handled || err != nil {
			t.Fatalf("valid Worker command refused: %v %v", args, err)
		}
	}
}

func TestPgMigrationWorkerCommandsRedactInvalidConnectionBeforeSQL(t *testing.T) {
	history := pgExpansionTestHistory("notes_app", 1)
	db := &Database{Name: "Main", Config: PostgresConfig{
		DBName: "unused", User: "request", Host: "localhost", Port: 5432, Schema: "notes_app",
		Password: "'never-print-this", MigrationTopology: "Worker", WorkerRole: "worker", RequestRole: "request",
	}, migrationHistory: &history}
	RegisterDatabaseIdentity("WorkerFixture.InvalidConfig", db)
	t.Cleanup(func() { databaseIdentities.Delete("WorkerFixture.InvalidConfig") })
	for _, verb := range []string{"worker", "install", "status"} {
		t.Run(verb, func(t *testing.T) {
			var out bytes.Buffer
			err := pgRunSchemaCommandContext(context.Background(), pgSchemaCommand{
				verb: verb, database: history.Database, worker: "worker", request: "request", json: true,
			}, &out)
			if err == nil || err.Error() != "invalid PostgreSQL schema connection configuration" || out.Len() != 0 {
				t.Fatalf("invalid connection reached SQL or exposed credentials: %v %s", err, &out)
			}
		})
	}
}

func TestPgMigrationWorkerOrdinaryStartupRedactsInvalidConnectionBeforeSQL(t *testing.T) {
	history := pgExpansionTestHistory("notes_app", 1)
	db := &Database{Name: "Main", Config: PostgresConfig{
		DBName: "unused", User: "request", Host: "localhost", Port: 5432, Schema: "notes_app",
		Password: "'never-print-this", MigrationTopology: "Worker", WorkerRole: "worker", RequestRole: "request",
	}, migrationHistory: &history}
	entered := false
	failure := recoverDebugSQLFailure(func() {
		WithDatabase(db, func() { entered = true })
	})
	if entered || db.bound() != nil || fmt.Sprint(failure) != "database: invalid PostgreSQL configuration" {
		t.Fatalf("invalid ordinary connection published a binding or exposed credentials: entered=%v failure=%v", entered, failure)
	}
}

func pgNewWorkerTest(t *testing.T) (*pgControlTestFixture, *pgx.Conn) {
	t.Helper()
	f := pgNewControlTest(t)
	f.roles.Request = strings.TrimSuffix(f.roles.Worker, "_worker") + "_request"
	if _, err := f.installer.Exec(f.ctx, "create role "+quoteIdentifier(f.roles.Request)+" login; revoke temporary on database "+
		quoteIdentifier(f.worker.Config().Database)+" from public; grant temporary on database "+quoteIdentifier(f.worker.Config().Database)+
		" to "+quoteIdentifier(f.roles.Owner)+","+quoteIdentifier(f.roles.Worker)); err != nil {
		t.Fatal(err)
	}
	config := f.worker.Config().Copy()
	config.User = f.roles.Request
	config.RuntimeParams["application_name"] = "tesl-app:worker-runtime-test"
	request, err := pgx.ConnectConfig(f.ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = request.Close(ctx)
		_, _ = f.installer.Exec(ctx, "drop owned by "+quoteIdentifier(f.roles.Request)+"; drop role "+quoteIdentifier(f.roles.Request))
	})
	return f, request
}

func pgWorkerTestDatabase(t *testing.T, f *pgControlTestFixture, version int) *Database {
	t.Helper()
	db := pgBootTestDatabase(t, f, version)
	db.Config.MigrationTopology = "Worker"
	db.Config.WorkerRole, db.Config.RequestRole = f.roles.Worker, f.roles.Request
	db.Config.User = f.roles.Request
	return db
}

func TestPgMigrationWorkerRequestHasDMLWithoutDDLOrTemporaryPrivilege(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	f.install(t, 1)
	f.expand(t, 1)
	history := pgExpansionTestHistory(f.namespace, 1)
	state, err := pgWaitForMigrationReadiness(f.ctx, request, history, f.roles)
	if err != nil || state.Current != 1 {
		t.Fatalf("request readiness: %+v %v", state, err)
	}
	var temporary bool
	if err := request.QueryRow(f.ctx, "select pg_my_temp_schema()<>0 or has_database_privilege(current_user,current_database(),'TEMP')").Scan(&temporary); err != nil || temporary {
		t.Fatalf("request inspection created or required temporary objects: %v %v", temporary, err)
	}
	for _, sql := range []string{
		"create temporary table forbidden_temp(id text)", "create table notes_app.forbidden(id text)",
		"alter table notes_app.notes add column forbidden text", "drop table notes_app.notes", "truncate notes_app.notes",
		"update notes_app.tesl_schema_state set current=9", "select notes_app.tesl_record_expanded(1)",
		"select notes_app.tesl_begin_expansion(2,'x','x','x','x',0,true)",
		"select notes_app.tesl_record_expansion_object(1,0,'x')", "set role " + quoteIdentifier(f.roles.Worker),
		"set role " + quoteIdentifier(f.roles.Owner),
	} {
		if _, err := request.Exec(f.ctx, sql); err == nil {
			t.Fatalf("request login obtained forbidden authority: %s", sql)
		}
	}
	db := pgWorkerTestDatabase(t, f, 1)
	db.Config.DDLConnection = "not a DSN; request startup must never parse or use this"
	WithDatabase(db, func() {
		PgExec(db.bound(), "insert into notes_app.notes(id,active) values ('dml',true)", nil)
		PgExec(db.bound(), "update notes_app.notes set active=false where id='dml'", nil)
		if got := PgCount(db.bound(), "select count(*) from notes_app.notes where id='dml' and not active", nil); got.String() != "1" {
			t.Fatalf("request DML result: %s", got)
		}
		PgExec(db.bound(), "delete from notes_app.notes where id='dml'", nil)
	})
	if _, err := request.Exec(f.ctx, "select notes_app.tesl_admit(1); select notes_app.tesl_heartbeat(1,1,1)"); err != nil {
		t.Fatalf("request admission/heartbeat denied: %v", err)
	}
	if _, err := pgWaitForMigrationReadiness(f.ctx, f.worker, history, f.roles); err == nil || !strings.Contains(err.Error(), "configured request identity") {
		t.Fatalf("worker credential was accepted for request startup: %v", err)
	}
}

func TestPgMigrationWorkerReconnectRechecksRequestIdentityAndIsolation(t *testing.T) {
	for _, mutation := range []string{"identity", "worker membership"} {
		t.Run(mutation, func(t *testing.T) {
			f, _ := pgNewWorkerTest(t)
			f.install(t, 1)
			f.expand(t, 1)
			db := pgWorkerTestDatabase(t, f, 1)
			WithDatabase(db, func() {
				opened := db.bound()
				if _, err := f.installer.Exec(f.ctx, "insert into notes_app.notes(id,active) values ('kept',true)"); err != nil {
					t.Fatal(err)
				}
				statement := "update notes_app.tesl_schema_meta set database_uuid='11111111-1111-1111-1111-111111111111'"
				if mutation == "worker membership" {
					statement = "grant " + quoteIdentifier(f.roles.Worker) + " to " + quoteIdentifier(f.roles.Request)
				}
				if _, err := f.installer.Exec(f.ctx, statement); err != nil {
					t.Fatal(err)
				}
				opened.pool.Reset()
				ctx, cancel := context.WithTimeout(f.ctx, 300*time.Millisecond)
				defer cancel()
				if err := opened.pool.Ping(ctx); err == nil {
					t.Fatal("reconnected request pool accepted changed identity/authority")
				}
				if opened.pool.Stat().AcquiredConns() != 0 {
					t.Fatal("refused replacement connection leaked a lease")
				}
			})
		})
	}
}

func TestPgMigrationWorkerPendingRequestTimesOutWithoutMutationAndThenStarts(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	f.install(t, 1)
	before := pgCompatibilityTestDurableState(t, f)
	ctx, cancel := context.WithTimeout(f.ctx, 350*time.Millisecond)
	_, err := pgWaitForMigrationReadiness(ctx, request, pgExpansionTestHistory(f.namespace, 2), f.roles)
	cancel()
	if !errors.Is(err, context.DeadlineExceeded) || before != pgCompatibilityTestDurableState(t, f) {
		t.Fatalf("pending request changed metadata or did not time out: %v", err)
	}
	var tables int
	if err := f.installer.QueryRow(f.ctx, "select count(*) from pg_catalog.pg_tables where schemaname=$1 and tablename='notes'", f.namespace).Scan(&tables); err != nil || tables != 0 {
		t.Fatalf("request created entity storage while pending: %d %v", tables, err)
	}
	f.expand(t, 2)
	// Cancellation may close pgx's connection while a catalog query is active.
	// A real startup retry borrows a new dedicated connection in either case.
	config := request.Config().Copy()
	_ = request.Close(f.ctx)
	restarted, err := pgx.ConnectConfig(f.ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = restarted.Close(ctx)
	})
	if state, err := pgWaitForMigrationReadiness(f.ctx, restarted, pgExpansionTestHistory(f.namespace, 2), f.roles); err != nil || state.Current != 2 {
		t.Fatalf("request failed to start after expansion: %+v %v", state, err)
	}
}

func TestPgMigrationWorkerExecutorRejectsRequestIdentityBeforeProbes(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	f.install(t, 1)
	before := pgCompatibilityTestDurableState(t, f)
	if _, err := ExecutePgMigrationExpansion(f.ctx, request, pgExpansionTestHistory(f.namespace, 1), f.roles); err == nil || err.Error() != "migration expansion requires the configured worker identity" {
		t.Fatalf("request login reached executor catalog probes: %v", err)
	}
	var temporary bool
	if err := request.QueryRow(f.ctx, "select pg_my_temp_schema()<>0 or has_database_privilege(current_user,current_database(),'TEMP')").Scan(&temporary); err != nil || temporary {
		t.Fatalf("wrong executor created or required temporary objects: %v %v", temporary, err)
	}
	if before != pgCompatibilityTestDurableState(t, f) {
		t.Fatal("wrong executor changed protected migration state")
	}
}

func TestPgMigrationWorkerTopologyAndACLChangesRefuseWithoutRepair(t *testing.T) {
	for _, change := range []string{"Embedded profile", "worker role", "request role", "missing admission grant", "transition grant", "missing DML", "extra DML", "schema create", "control write"} {
		t.Run(change, func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			f.install(t, 1)
			f.expand(t, 1)
			roles := f.roles
			switch change {
			case "Embedded profile":
				roles.Request = ""
			case "worker role":
				roles.Worker, roles.Request = roles.Request, roles.Worker
			case "request role":
				roles.Request = roles.Owner
			case "missing admission grant":
				_, err := f.installer.Exec(f.ctx, "revoke execute on function notes_app.tesl_admit(integer) from "+quoteIdentifier(roles.Request))
				if err != nil {
					t.Fatal(err)
				}
			case "transition grant":
				_, err := f.installer.Exec(f.ctx, "grant execute on function notes_app.tesl_record_expanded(integer) to "+quoteIdentifier(roles.Request))
				if err != nil {
					t.Fatal(err)
				}
			case "missing DML":
				_, err := f.installer.Exec(f.ctx, "revoke update on notes_app.notes from "+quoteIdentifier(roles.Request))
				if err != nil {
					t.Fatal(err)
				}
			case "extra DML":
				_, err := f.installer.Exec(f.ctx, "grant trigger on notes_app.notes to "+quoteIdentifier(roles.Request))
				if err != nil {
					t.Fatal(err)
				}
			case "schema create":
				_, err := f.installer.Exec(f.ctx, "grant create on schema notes_app to "+quoteIdentifier(roles.Request))
				if err != nil {
					t.Fatal(err)
				}
			case "control write":
				_, err := f.installer.Exec(f.ctx, "grant update on notes_app.tesl_schema_state to "+quoteIdentifier(roles.Request))
				if err != nil {
					t.Fatal(err)
				}
			}
			before := pgCompatibilityTestDurableState(t, f)
			if roles.Request == "" {
				if _, err := InstallPgCompiledMigrationControl(f.ctx, f.installer, pgExpansionTestHistory(f.namespace, 1), roles); err == nil {
					t.Fatal("Worker grant profile silently adopted as Embedded")
				}
			} else if _, err := pgWaitForMigrationReadiness(f.ctx, request, pgExpansionTestHistory(f.namespace, 1), roles); err == nil {
				t.Fatal("altered request role/profile was accepted")
			}
			if before != pgCompatibilityTestDurableState(t, f) {
				t.Fatal("refusal rewrote protected state")
			}
		})
	}
}

func TestPgMigrationWorkerRequestRoleMembershipCannotElevate(t *testing.T) {
	for _, membership := range []string{"worker", "owner", "indirect worker NOINHERIT", "pg_write_all_data", "createrole", "superuser"} {
		t.Run(membership, func(t *testing.T) {
			f, _ := pgNewWorkerTest(t)
			sql := ""
			switch membership {
			case "worker":
				sql = "grant " + quoteIdentifier(f.roles.Worker) + " to " + quoteIdentifier(f.roles.Request)
			case "owner":
				sql = "grant " + quoteIdentifier(f.roles.Owner) + " to " + quoteIdentifier(f.roles.Request)
			case "indirect worker NOINHERIT":
				bridge := f.roles.Request + "_bridge"
				sql = "create role " + quoteIdentifier(bridge) + " nologin; grant " + quoteIdentifier(f.roles.Worker) + " to " + quoteIdentifier(bridge) + "; alter role " + quoteIdentifier(f.roles.Request) + " noinherit; grant " + quoteIdentifier(bridge) + " to " + quoteIdentifier(f.roles.Request)
				t.Cleanup(func() { _, _ = f.installer.Exec(context.Background(), "drop role "+quoteIdentifier(bridge)) })
			case "pg_write_all_data":
				sql = "grant pg_write_all_data to " + quoteIdentifier(f.roles.Request)
			case "createrole":
				sql = "alter role " + quoteIdentifier(f.roles.Request) + " createrole"
			case "superuser":
				sql = "alter role " + quoteIdentifier(f.roles.Request) + " superuser"
			}
			if _, err := f.installer.Exec(f.ctx, sql); err != nil {
				t.Fatal(err)
			}
			if membership == "indirect worker NOINHERIT" {
				var inherited bool
				if err := f.installer.QueryRow(f.ctx, "select pg_catalog.pg_has_role($1,$2,'USAGE')", f.roles.Request, f.roles.Worker).Scan(&inherited); err != nil || inherited {
					t.Fatalf("fixture unexpectedly inherits worker authority: %v %v", inherited, err)
				}
			}
			if _, err := InstallPgMigrationControl(f.ctx, f.installer, f.namespace, f.roles, 1); err == nil || !strings.Contains(err.Error(), "role isolation") {
				t.Fatalf("elevated request role accepted: %v", err)
			}
		})
	}
}

func TestPgMigrationWorkerLongLivedRolesCannotOwnDatabase(t *testing.T) {
	for _, principal := range []string{"worker", "request"} {
		for _, membership := range []string{"direct owner", "owner membership", "indirect owner NOINHERIT"} {
			t.Run(principal+"/"+membership, func(t *testing.T) {
				f, _ := pgNewWorkerTest(t)
				role := f.roles.Worker
				if principal == "request" {
					role = f.roles.Request
				}
				database := quoteIdentifier(f.worker.Config().Database)
				installer := quoteIdentifier(f.installer.Config().User)
				owner, bridge := role, role+"_bridge"
				if membership != "direct owner" {
					owner = role + "_dbowner"
					if _, err := f.installer.Exec(f.ctx, "create role "+quoteIdentifier(owner)+" nologin"); err != nil {
						t.Fatal(err)
					}
				}
				// Restore database ownership before the fixture drops the request
				// role; DROP OWNED intentionally does not drop an owned database.
				t.Cleanup(func() {
					ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
					defer cancel()
					_, _ = f.installer.Exec(ctx, "alter database "+database+" owner to "+installer)
					if membership == "indirect owner NOINHERIT" {
						_, _ = f.installer.Exec(ctx, "drop role "+quoteIdentifier(bridge))
					}
					if membership != "direct owner" {
						_, _ = f.installer.Exec(ctx, "drop role "+quoteIdentifier(owner))
					}
				})
				if _, err := f.installer.Exec(f.ctx, "alter database "+database+" owner to "+quoteIdentifier(owner)); err != nil {
					t.Fatal(err)
				}
				switch membership {
				case "direct owner":
					var implicit bool
					if err := f.installer.QueryRow(f.ctx, "select pg_catalog.pg_has_role($1,'pg_database_owner','MEMBER')", role).Scan(&implicit); err != nil || !implicit {
						t.Fatalf("fixture does not exercise implicit pg_database_owner authority: %v %v", implicit, err)
					}
				case "owner membership":
					if _, err := f.installer.Exec(f.ctx, "grant "+quoteIdentifier(owner)+" to "+quoteIdentifier(role)); err != nil {
						t.Fatal(err)
					}
				case "indirect owner NOINHERIT":
					if _, err := f.installer.Exec(f.ctx, "create role "+quoteIdentifier(bridge)+" nologin; grant "+quoteIdentifier(owner)+" to "+quoteIdentifier(bridge)+
						"; alter role "+quoteIdentifier(role)+" noinherit; grant "+quoteIdentifier(bridge)+" to "+quoteIdentifier(role)); err != nil {
						t.Fatal(err)
					}
					var inherited bool
					if err := f.installer.QueryRow(f.ctx, "select pg_catalog.pg_has_role($1,$2,'USAGE')", role, owner).Scan(&inherited); err != nil || inherited {
						t.Fatalf("fixture unexpectedly inherits database-owner authority: %v %v", inherited, err)
					}
				}
				if _, err := InstallPgMigrationControl(f.ctx, f.installer, f.namespace, f.roles, 1); err == nil || !strings.Contains(err.Error(), "role isolation") {
					t.Fatalf("database-owning %s accepted: %v", principal, err)
				}
			})
		}
	}
}

type pgWorkerReadyWriter struct{ output chan []byte }

func (w pgWorkerReadyWriter) Write(data []byte) (int, error) {
	w.output <- bytes.Clone(data)
	return len(data), nil
}

func TestPgMigrationWorkerCommandReadyLifetimeAndCancellation(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	f.install(t, 1)
	db := pgWorkerTestDatabase(t, f, 2)
	db.Config.DDLConnection = f.worker.Config().ConnString()
	RegisterDatabaseIdentity("WorkerFixture.Command", db)
	t.Cleanup(func() { databaseIdentities.Delete("WorkerFixture.Command") })
	ctx, cancel := context.WithCancel(f.ctx)
	defer cancel()
	output := make(chan []byte, 2)
	done := make(chan error, 1)
	go func() {
		done <- pgRunSchemaCommandContext(ctx, pgSchemaCommand{verb: "worker", database: db.migrationHistory.Database, json: true}, pgWorkerReadyWriter{output})
	}()
	var report struct {
		Kind, Database, DatabaseUUID  string
		BinaryVersion, CurrentVersion int
	}
	select {
	case data := <-output:
		if err := json.Unmarshal(data, &report); err != nil || report.Kind != "schema-worker-ready" || report.BinaryVersion != 2 || report.CurrentVersion != 2 || report.DatabaseUUID == "" {
			t.Fatalf("invalid worker readiness: %s %v", data, err)
		}
	case err := <-done:
		t.Fatalf("worker exited before ready: %v", err)
	case <-f.ctx.Done():
		t.Fatal("worker did not become ready")
	}
	select {
	case err := <-done:
		t.Fatalf("ready worker did not remain alive: %v", err)
	default:
	}
	if db.bound() != nil {
		t.Fatal("schema worker published an application pool")
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-f.ctx.Done():
		t.Fatal("worker did not stop on cancellation")
	}
	select {
	case data := <-output:
		t.Fatalf("worker emitted more than one readiness report: %s", data)
	default:
	}
	state, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
	if err != nil || state.DatabaseUUID != report.DatabaseUUID || state.Current != 2 {
		t.Fatalf("cancelled worker lost committed state: %+v %v", state, err)
	}
}

func TestPgMigrationWorkerInstallerRolesMustMatchConfiguration(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	db := pgWorkerTestDatabase(t, f, 1)
	db.Config.DDLConnection = f.installer.Config().ConnString()
	RegisterDatabaseIdentity("WorkerFixture.Install", db)
	t.Cleanup(func() { databaseIdentities.Delete("WorkerFixture.Install") })
	for _, roles := range []PgMigrationControlRoles{{Worker: f.roles.Worker}, {Worker: f.roles.Request, Request: f.roles.Worker}} {
		var out bytes.Buffer
		err := pgRunSchemaCommandContext(f.ctx, pgSchemaCommand{verb: "install", database: db.migrationHistory.Database, worker: roles.Worker, request: roles.Request, json: true}, &out)
		if err == nil || out.Len() != 0 || !strings.Contains(err.Error(), "matching the compiled database configuration") {
			t.Fatalf("mismatched install roles accepted: %v %s", err, &out)
		}
	}
	var out bytes.Buffer
	db.Config.DDLConnection = f.worker.Config().ConnString()
	err := pgRunSchemaCommandContext(f.ctx, pgSchemaCommand{verb: "install", database: db.migrationHistory.Database, worker: f.roles.Worker, request: f.roles.Request, json: true}, &out)
	if err == nil || !strings.Contains(err.Error(), "temporary control-owner membership") || out.Len() != 0 {
		t.Fatalf("installer accepted the normal schema-worker credential: %v %s", err, &out)
	}
	db.Config.DDLConnection = f.installer.Config().ConnString()
	err = pgRunSchemaCommandContext(f.ctx, pgSchemaCommand{verb: "install", database: db.migrationHistory.Database, worker: f.roles.Worker, request: f.roles.Request, json: true}, &out)
	if err != nil {
		t.Fatal(err)
	}
	before, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
	if err != nil {
		t.Fatal(err)
	}
	embedded := f.roles
	embedded.Request = ""
	if _, err := InstallPgMigrationControl(f.ctx, f.installer, f.namespace, embedded, 1); err == nil {
		t.Fatal("existing Worker install converted to Embedded")
	}
	after, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatalf("installer changed topology/state: %v", err)
	}
	var installed pgSchemaInstallation
	if err := json.Unmarshal(out.Bytes(), &installed); err != nil || installed.DatabaseUUID != before.DatabaseUUID || installed.Kind != "schema-install" {
		t.Fatalf("Worker installation report: %s %v", &out, err)
	}
}
