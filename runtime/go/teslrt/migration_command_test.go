package teslrt

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"reflect"
	"strings"
	"testing"
)

func TestSchemaCommandIsInertWithoutItsFlag(t *testing.T) {
	for _, args := range [][]string{nil, {"--ordinary-argument"}} {
		var out, diagnostics bytes.Buffer
		if handled, code := RunSchemaCommand(args, &out, &diagnostics); handled || code != 0 || out.Len() != 0 || diagnostics.Len() != 0 {
			t.Fatalf("ordinary application arguments activated schema work: %v", args)
		}
	}
}

func TestSchemaCommandRejectsBadArgumentsBeforeConnection(t *testing.T) {
	for _, args := range [][]string{
		{"--schema"}, {"--schema=status"}, {"--schema", "unknown"}, {"--other", "--schema", "status"},
		{"--schema", "status", "--database"}, {"--schema", "status", "--database", ""},
		{"--schema", "status", "--database", "--json"}, {"--schema", "status", "--json", "--json"},
		{"--schema", "status", "--database", "A.Main", "--database", "B.Main"},
		{"--schema", "status", "--unknown"}, {"--schema", "status", "positional"},
		{"--schema", "install"}, {"--schema", "install", "--worker"}, {"--schema", "install", "--worker", ""},
		{"--schema", "install", "--worker", "--json"}, {"--schema", "install", "--worker", "bad\x00role"},
		{"--schema", "install", "--worker", "a", "--worker", "b"}, {"--schema", "status", "--worker", "a"},
	} {
		var out, diagnostics bytes.Buffer
		if handled, code := RunSchemaCommand(args, &out, &diagnostics); !handled || code != 2 || out.Len() != 0 || diagnostics.Len() == 0 {
			t.Fatalf("invalid schema command could fall through to application startup: %v (%s, %s)", args, &out, &diagnostics)
		}
	}
	if handled, code := RunSchemaCommand([]string{"--schema", "status"}, nil, io.Discard); !handled || code != 2 {
		t.Fatal("missing output writer did not refuse")
	}
	command, handled, err := pgParseSchemaCommand([]string{"--schema", "status", "--json", "--database", "A.Main"})
	if err != nil || !handled || !command.json || command.database != "A.Main" {
		t.Fatalf("valid command did not preserve selection: %+v %v", command, err)
	}
	command, handled, err = pgParseSchemaCommand([]string{"--schema", "install", "--worker", "worker ' 雪", "--json", "--database", "A.Main"})
	if err != nil || !handled || command.verb != "install" || command.worker != "worker ' 雪" || !command.json || command.database != "A.Main" {
		t.Fatalf("installer arguments changed the role identity: %+v %v", command, err)
	}
}

func TestPgMigrationInstallCommandUsesExplicitWorkerAndCurrentOrigin(t *testing.T) {
	f := pgNewControlTest(t)
	db := pgBootTestDatabase(t, f, 3)
	RegisterDatabaseIdentity("CommandFixture.Install", db)
	t.Cleanup(func() { databaseIdentities.Delete("CommandFixture.Install") })
	args := []string{"--schema", "install", "--worker", f.roles.Worker, "--database", db.migrationHistory.Database, "--json"}
	var out, diagnostics bytes.Buffer
	// The service credential cannot run the one-time installer.
	if handled, code := RunSchemaCommand(args, &out, &diagnostics); !handled || code != 2 || out.Len() != 0 || !strings.Contains(diagnostics.String(), "temporary control-owner membership") {
		t.Fatalf("worker installation: %s %s", &out, &diagnostics)
	}
	db.Config.User, db.Config.Password = f.installer.Config().User, f.installer.Config().Password
	diagnostics.Reset()
	if handled, code := RunSchemaCommand(args, &out, &diagnostics); !handled || code != 0 || diagnostics.Len() != 0 {
		t.Fatalf("installer command: %s %s", &out, &diagnostics)
	}
	var report pgSchemaInstallation
	if err := json.Unmarshal(out.Bytes(), &report); err != nil || report.Version != 1 || report.Kind != "schema-install" || report.InitialVersion != 3 ||
		report.BinaryVersion != 3 || report.InstallingVersion != 3 || report.CurrentVersion != 0 || report.DatabaseUUID == "" {
		t.Fatalf("installation did not select the current revision: %s %v", &out, err)
	}
	if db.bound() != nil {
		t.Fatal("installer opened an application pool")
	}
	before, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
	if err != nil || before.DatabaseUUID != report.DatabaseUUID {
		t.Fatalf("explicit worker cannot inspect installed control: %+v %v", before, err)
	}
	var tables int
	if err := f.worker.QueryRow(f.ctx, "select count(*) from pg_catalog.pg_tables where schemaname=$1", f.namespace).Scan(&tables); err != nil || tables != len(pgMigrationControlTables) {
		t.Fatalf("installer performed entity DDL: %d, %v", tables, err)
	}
	if handled, code := RunSchemaCommand(args, pgSchemaBrokenWriter{}, io.Discard); !handled || code != 2 {
		t.Fatal("post-install output failure was swallowed")
	}
	out.Reset()
	if handled, code := RunSchemaCommand(args[:len(args)-1], &out, &diagnostics); !handled || code != 0 ||
		!strings.Contains(out.String(), "origin V3") || !strings.Contains(out.String(), "Revoke") || strings.Contains(out.String(), "V0") {
		t.Fatalf("human installer retry: %s %s", &out, &diagnostics)
	}
	after, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatalf("retry changed identity or history: %+v %v", after, err)
	}
	db.Config.User, db.Config.Password = f.worker.Config().User, f.worker.Config().Password
	WithDatabase(db, func() {
		if got := PgCount(db.bound(), "select count(*) from notes_app.notes", nil); got.String() != "0" {
			t.Fatal("fresh current-origin database contains rows")
		}
	})
}

func TestPgMigrationInstallRetainsAndVerifiesExistingHistory(t *testing.T) {
	f := pgNewControlTest(t)
	history := pgExpansionTestHistory(f.namespace, 3)
	before := f.install(t, 1)
	checkRetry := func() {
		t.Helper()
		after, err := InstallPgCompiledMigrationControl(f.ctx, f.installer, history, f.roles)
		if err != nil || !reflect.DeepEqual(before, after) {
			t.Fatalf("compiled installer replaced old installation: %+v, %v", after, err)
		}
	}
	checkRetry() // An interrupted old baseline must finish, not jump to V3.
	before = f.expand(t, 1)
	f.call(t, "insert into notes_app.notes(id,active) values ('retained',true)")
	checkRetry()
	oldABI := history.SourceCompilerABI
	history.SourceCompilerABI = "tesl-source-abi-v1:" + strings.Repeat("b", 64)
	history.HistoryJSON = strings.ReplaceAll(history.HistoryJSON, oldABI, history.SourceCompilerABI)
	if _, err := InstallPgCompiledMigrationControl(f.ctx, f.installer, history, f.roles); err == nil || !strings.Contains(err.Error(), "ABI or plan differs") {
		t.Fatalf("installer accepted rewritten source history: %v", err)
	}
	after, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatalf("refused installer changed control: %+v, %v", after, err)
	}
	var rows int
	if err := f.worker.QueryRow(f.ctx, "select count(*) from notes_app.notes where id='retained' and active").Scan(&rows); err != nil || rows != 1 {
		t.Fatalf("installer changed retained data: %d, %v", rows, err)
	}
}

func TestPgMigrationInstallRefusesNoLoginWorker(t *testing.T) {
	f := pgNewControlTest(t)
	if _, err := f.installer.Exec(f.ctx, "alter role "+quoteIdentifier(f.roles.Worker)+" nologin"); err != nil {
		t.Fatal(err)
	}
	if _, err := InstallPgCompiledMigrationControl(f.ctx, f.installer, pgExpansionTestHistory(f.namespace, 1), f.roles); err == nil || !strings.Contains(err.Error(), "role isolation") {
		t.Fatalf("installer granted a non-login worker: %v", err)
	}
	var exists bool
	if err := f.installer.QueryRow(f.ctx, "select exists(select 1 from pg_catalog.pg_namespace where nspname=$1)", f.namespace).Scan(&exists); err != nil || exists {
		t.Fatalf("refused installer created namespace: %v, %v", exists, err)
	}
}

func TestSchemaCommandSelectsCompiledConnectionIdentity(t *testing.T) {
	if _, _, err := pgSelectSchemaDatabase(""); err == nil {
		t.Fatal("selection invented a compiled versioned connection")
	}
	first := &Database{Name: "Main", migrationHistory: &PgCompiledMigrationHistory{Database: "CommandFixtureA.Main"}}
	second := &Database{Name: "Main", migrationHistory: &PgCompiledMigrationHistory{Database: "CommandFixtureB.Main"}}
	RegisterDatabaseIdentity("CommandFixtureA.Main", first)
	t.Cleanup(func() { databaseIdentities.Delete("CommandFixtureA.Main") })
	selected, history, err := pgSelectSchemaDatabase("")
	if err != nil || selected != first || history.Database != "CommandFixtureA.Main" {
		t.Fatalf("single connection selection: %+v %v", history, err)
	}
	RegisterDatabaseIdentity("CommandFixtureB.Main", second)
	t.Cleanup(func() { databaseIdentities.Delete("CommandFixtureB.Main") })
	for _, selector := range []string{"", "Main", "Absent.Main"} {
		if _, _, err := pgSelectSchemaDatabase(selector); err == nil || !strings.Contains(err.Error(), "CommandFixtureA.Main, CommandFixtureB.Main") {
			t.Fatalf("ambiguous/unknown selection did not list exact identities: %s, %v", selector, err)
		}
	}
	selected, _, err = pgSelectSchemaDatabase("CommandFixtureB.Main")
	if err != nil || selected != second {
		t.Fatalf("qualified selection changed connection: %v", err)
	}
}

func TestPgMigrationStatusNeverInstallsOrExpands(t *testing.T) {
	f := pgNewControlTest(t)
	history := pgExpansionTestHistory(f.namespace, 2)
	status, err := InspectPgMigrationStatus(f.ctx, f.worker, history, f.roles)
	if err != nil || status.Present || len(status.Expansions) != 0 || status.HistoryError != "" {
		t.Fatalf("uninstalled status: %+v, %v", status, err)
	}
	seed := f.install(t, 1)
	status, err = InspectPgMigrationStatus(f.ctx, f.worker, history, f.roles)
	if err != nil || !status.Present || status.InstallingVersion != 1 || status.CurrentVersion != 0 || status.HistoryError != "" {
		t.Fatalf("incomplete initial installation: %+v, %v", status, err)
	}
	before := f.expand(t, 1)
	f.call(t, "insert into notes_app.notes(id,active) values ('retained',true)")
	f.call(t, "set application_name='tesl-app:status-observation'")
	f.call(t, "select notes_app.tesl_heartbeat(1,1,1)")
	status, err = InspectPgMigrationStatus(f.ctx, f.worker, history, f.roles)
	if err != nil || status.DatabaseUUID != seed.DatabaseUUID || status.CurrentVersion != 1 || status.BinaryVersion != 2 ||
		status.MinVersion != 1 || status.HistoryError != "" || len(status.Expansions) != 1 || len(status.Instances) != 1 {
		t.Fatalf("status changed or misreported installed history: %+v, %v", status, err)
	}
	if status.Expansions[0].Completed != status.Expansions[0].Total || len(status.Expansions[0].Steps) != 3 ||
		status.Instances[0].Instance != "tesl-app:status-observation" || status.Instances[0].LastSeen.IsZero() || status.Instances[0].Version != 1 {
		t.Fatalf("missing progress or heartbeat observation: %+v", status)
	}
	after, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatalf("status rewrote protected history: %+v, %v", after, err)
	}
	var rows, columns int
	if err := f.worker.QueryRow(f.ctx, "select count(*) from notes_app.notes where id='retained' and active").Scan(&rows); err != nil || rows != 1 {
		t.Fatalf("status touched retained rows: %d, %v", rows, err)
	}
	if err := f.worker.QueryRow(f.ctx, "select count(*) from information_schema.columns where table_schema='notes_app' and table_name='notes'").Scan(&columns); err != nil || columns != 2 {
		t.Fatalf("status expanded V2: %d, %v", columns, err)
	}
	if f.worker.PgConn().TxStatus() != 'I' {
		t.Fatal("status left a transaction open")
	}
}

type pgSchemaBrokenWriter struct{}

func (pgSchemaBrokenWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

func TestPgMigrationStatusCommandReportsHistoryMismatchWithoutRepair(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	f.expand(t, 1)
	db := pgBootTestDatabase(t, f, 2)
	identity := "CommandFixture.Status"
	RegisterDatabaseIdentity(identity, db)
	t.Cleanup(func() { databaseIdentities.Delete(identity) })
	var out, diagnostics bytes.Buffer
	args := []string{"--schema", "status", "--database", db.migrationHistory.Database, "--json"}
	if handled, code := RunSchemaCommand(args, &out, &diagnostics); !handled || code != 0 || diagnostics.Len() != 0 {
		t.Fatalf("status command: %s %s", &out, &diagnostics)
	}
	var report PgMigrationStatus
	if err := json.Unmarshal(out.Bytes(), &report); err != nil || report.CurrentVersion != 1 || report.BinaryVersion != 2 {
		t.Fatalf("status JSON: %s %v", &out, err)
	}
	if db.bound() != nil {
		t.Fatal("status bound the application database")
	}
	oldABI := db.migrationHistory.SourceCompilerABI
	db.migrationHistory.SourceCompilerABI = "tesl-source-abi-v1:" + strings.Repeat("b", 64)
	db.migrationHistory.HistoryJSON = strings.ReplaceAll(db.migrationHistory.HistoryJSON, oldABI, db.migrationHistory.SourceCompilerABI)
	out.Reset()
	if handled, code := RunSchemaCommand(args, &out, &diagnostics); !handled || code != 2 {
		t.Fatal("changed ABI appeared compatible")
	}
	if err := json.Unmarshal(out.Bytes(), &report); err != nil || report.HistoryError == "" || report.CurrentVersion != 1 || len(report.Expansions) != 1 {
		t.Fatalf("mismatch lost observed state: %s %v", &out, err)
	}
	if !strings.Contains(diagnostics.String(), "history differs") {
		t.Fatalf("missing mismatch explanation: %s", &diagnostics)
	}
	// Output failure must not be swallowed or start the application.
	if handled, code := RunSchemaCommand(args, pgSchemaBrokenWriter{}, io.Discard); !handled || code != 2 {
		t.Fatal("output failure was not reported")
	}
	if state, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles); err != nil || state.Current != 1 {
		t.Fatalf("reporting a mismatch changed database history: %+v %v", state, err)
	}
}

func TestPgMigrationStatusCancellationPreservesBorrowedConnection(t *testing.T) {
	f := pgNewControlTest(t)
	ctx, cancel := context.WithCancel(f.ctx)
	cancel()
	_, err := InspectPgMigrationStatus(ctx, f.worker, pgExpansionTestHistory(f.namespace, 1), f.roles)
	if !errors.Is(err, context.Canceled) || f.worker.IsClosed() || f.worker.PgConn().TxStatus() != 'I' {
		t.Fatalf("pre-canceled status changed connection: %v", err)
	}
}

func TestPgMigrationStatusHumanOutputReportsInstallationAndEscapesInstances(t *testing.T) {
	f := pgNewControlTest(t)
	db := pgBootTestDatabase(t, f, 1)
	const identity = "CommandFixture.Human"
	RegisterDatabaseIdentity(identity, db)
	t.Cleanup(func() { databaseIdentities.Delete(identity) })
	report := func() string {
		t.Helper()
		var out, diagnostics bytes.Buffer
		if handled, code := RunSchemaCommand([]string{"--schema", "status"}, &out, &diagnostics); !handled || code != 0 || diagnostics.Len() != 0 {
			t.Fatalf("human status: %s %s", &out, &diagnostics)
		}
		if strings.Contains(out.String(), "V0") {
			t.Fatal("human status invented version zero")
		}
		return out.String()
	}
	if text := report(); !strings.Contains(text, "not installed") {
		t.Fatalf("missing installation explanation: %s", text)
	}
	f.install(t, 1)
	if text := report(); !strings.Contains(text, "installation of V1 is incomplete") {
		t.Fatalf("missing incomplete-installation explanation: %s", text)
	}
	f.expand(t, 1)
	f.call(t, "select pg_catalog.set_config('application_name',$1,false)", "tesl-app:\n\x1b[2J")
	f.call(t, "select notes_app.tesl_heartbeat(1,1,1)")
	text := report()
	if !strings.Contains(text, "Database V1; oldest admitted V1") || !strings.Contains(text, "last heartbeat") ||
		strings.Contains(text, "\x1b") || !strings.Contains(text, "\\x1b") {
		t.Fatalf("status lost or failed to escape instance information: %q", text)
	}
}

func TestPgMigrationStatusDoesNotAdoptOrIgnoreControlDrift(t *testing.T) {
	for _, scenario := range []string{"pre-versioning storage", "control drift"} {
		t.Run(scenario, func(t *testing.T) {
			f := pgNewControlTest(t)
			if scenario == "pre-versioning storage" {
				for _, sql := range []string{"create schema notes_app authorization " + f.roles.Owner, "grant usage,create on schema notes_app to " + f.roles.Worker} {
					if _, err := f.installer.Exec(f.ctx, sql); err != nil {
						t.Fatal(err)
					}
				}
				f.call(t, "create table notes_app.notes(id text primary key)")
				f.call(t, "insert into notes_app.notes values ('retained')")
			} else {
				f.install(t, 1)
				f.expand(t, 1)
				if _, err := f.installer.Exec(f.ctx, "alter table notes_app.tesl_schema_state add column unexpected text"); err != nil {
					t.Fatal(err)
				}
			}
			status, err := InspectPgMigrationStatus(f.ctx, f.worker, pgExpansionTestHistory(f.namespace, 1), f.roles)
			if scenario == "pre-versioning storage" {
				if err != nil || status.Present {
					t.Fatalf("legacy storage appeared installed: %+v %v", status, err)
				}
				var id string
				if err := f.worker.QueryRow(f.ctx, "select id from notes_app.notes").Scan(&id); err != nil || id != "retained" {
					t.Fatalf("status changed pre-versioning data: %s %v", id, err)
				}
			} else if err == nil || status.Present {
				t.Fatalf("unverified control state escaped inspection: %+v %v", status, err)
			}
		})
	}
}
