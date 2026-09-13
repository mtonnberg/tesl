package teslrt

import (
	"context"
	"github.com/jackc/pgx/v5"
	"testing"
	"time"
)

func pgRowBaselineFixture(t *testing.T, f *pgControlTestFixture) *Database {
	t.Helper()
	return pgRowBaselineFixtureWith(t, f, nil)
}

func pgRowBaselineFixtureWith(t *testing.T, f *pgControlTestFixture, change func(*PgCompiledMigrationHistory, map[string]any, map[string]any)) *Database {
	t.Helper()
	return pgRowBaselineFixtureConfigured(t, f, change, nil)
}
func pgRowBaselineFixtureConfigured(t *testing.T, f *pgControlTestFixture, change func(*PgCompiledMigrationHistory, map[string]any, map[string]any), configure func(*Database)) *Database {
	t.Helper()
	h, base, companion := rowTestFixture(t)
	h.Namespace = f.namespace
	h.CurrentVersion = 1
	rowTestDB(base)["namespace"] = f.namespace
	rowTestDB(base)["currentVersion"] = 1
	rowTestDB(base)["versions"] = rowTestDB(base)["versions"].([]any)[:1]
	rowTestDB(base)["origins"] = rowTestDB(base)["origins"].([]any)[:1]
	rowTestDB(companion)["namespace"] = f.namespace
	rowTestDB(companion)["currentVersion"] = 1
	rowTestDB(companion)["transforms"] = []any{}
	if change != nil {
		change(&h, base, companion)
	}
	h.HistoryJSON = rowTestJSON(t, base)
	db := rowTestRegister(t, h, companion)
	config := f.worker.Config()
	db.Config = PostgresConfig{DBName: config.Database, User: config.User, Host: config.Host, Port: int(config.Port), Schema: f.namespace, ControlOwner: f.roles.Owner, MigrationTopology: "Embedded", DDLConnection: config.ConnString()}
	if f.roles.Request != "" {
		db.Config.MigrationTopology = "Worker"
		db.Config.User = f.roles.Request
		db.Config.RequestRole = f.roles.Request
		db.Config.WorkerRole = f.roles.Worker
	}
	if configure != nil {
		configure(db)
	}
	if err := PreflightApplicationDatabases(db); err != nil {
		t.Fatal(err)
	}
	return db
}

func TestPgRowBaselineFreshWorkerV1(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	db := pgRowBaselineFixture(t, f)
	installed, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles)
	if err != nil {
		t.Fatal(err)
	}
	if installed.Format != 5 || installed.Current != 0 || installed.InitialVersion != 1 || installed.InstallingVersion != 1 {
		t.Fatal("wrong protected initial baseline", installed)
	}
	b, err := pgCompiledRowBaseline(db)
	if err != nil {
		t.Fatal(err)
	}
	pending, cancel := context.WithTimeout(f.ctx, 100*time.Millisecond)
	_, err = pgWaitForRowBaseline(pending, request, b, f.roles)
	cancel()
	if err == nil {
		t.Fatal("request admitted before physical baseline")
	}
	// Cancellation may close pgx while a catalog query is active. A real
	// startup retry borrows a fresh connection rather than reusing that socket.
	requestConfig := request.Config().Copy()
	_ = request.Close(f.ctx)
	request, err = pgx.ConnectConfig(f.ctx, requestConfig)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		_ = request.Close(cleanup)
	})
	state, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, db, f.roles)
	if err != nil {
		t.Fatal(err)
	}
	if state.Format != 5 || state.Current != 1 || state.DatabaseUUID != installed.DatabaseUUID {
		t.Fatal("wrong completed baseline", state)
	}
	if _, err := pgWaitForRowBaseline(f.ctx, request, b, f.roles); err != nil {
		t.Fatal(err)
	}
	if _, err := request.Exec(f.ctx, `insert into notes_app.notes(id,title) values(1,'first'); update notes_app.notes set title='changed' where id=1`); err != nil {
		t.Fatal(err)
	}
	var generation int
	var title string
	if err := request.QueryRow(f.ctx, `select _tesl_v,title from notes_app.notes where id=1`).Scan(&generation, &title); err != nil || generation != 1 || title != "changed" {
		t.Fatal("ordinary request writes lost permanent marker", generation, title, err)
	}
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
		t.Fatal("installer retry", err)
	}
	if _, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, db, f.roles); err != nil {
		t.Fatal("worker retry", err)
	}
	for _, sql := range []string{`update notes_app.tesl_row_baseline set inventory_authority='complete'`, `delete from notes_app.tesl_row_entities`, `select notes_app.tesl_begin_expansion(2,repeat('a',64),repeat('b',64),'` + b.history.SourceCompilerABI + `','` + b.history.StoredValueCompatibility + `',0,true)`} {
		if _, err := request.Exec(f.ctx, sql); err == nil {
			t.Fatal("request mutated protected baseline", sql)
		}
	}
	if _, err := f.worker.Exec(f.ctx, `select notes_app.tesl_begin_expansion(2,repeat('a',64),repeat('b',64),$1,$2,0,true)`, b.history.SourceCompilerABI, b.history.StoredValueCompatibility); err == nil {
		t.Fatal("Worker advanced unsupported V2")
	}
}
