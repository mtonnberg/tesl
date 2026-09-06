package teslrt

import (
	"context"
	"fmt"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestPgMigrationBootSelectsProtectedOriginWithOtherOriginRefused(t *testing.T) {
	for _, origin := range []int{2, 3} {
		t.Run(fmt.Sprintf("origin V%d", origin), func(t *testing.T) {
			f := pgNewControlTest(t)
			before := f.install(t, origin)
			db := pgBootTestDatabase(t, f, 3)
			history := pgPlanTestRewrite(t, *db.migrationHistory, func(o map[string]any) {
				origins := o["databases"].([]any)[0].(map[string]any)["origins"].([]any)
				refused := origins[1].(map[string]any)
				refused["steps"] = nil
				refused["errors"] = []any{map[string]any{"code": "MIG016", "message": "retained relation collision"}}
			})
			db.migrationHistory = &history
			if origin == 2 {
				if _, err := InstallPgCompiledMigrationControl(f.ctx, f.installer, history, f.roles); err == nil || !strings.Contains(err.Error(), "MIG016") {
					t.Fatalf("installer accepted a refused protected origin: %v", err)
				}
				pgBootRefuses(t, db, "MIG016")
				after, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
				if err != nil || !reflect.DeepEqual(before, after) {
					t.Fatalf("refused origin changed control state: %+v, %v", after, err)
				}
				var tables int
				if err := f.worker.QueryRow(f.ctx, "select count(*) from pg_catalog.pg_tables where schemaname=$1 and tablename in ('notes','audit')", f.namespace).Scan(&tables); err != nil || tables != 0 {
					t.Fatalf("refused origin created entity storage: %d, %v", tables, err)
				}
			} else {
				WithDatabase(db, func() {
					if got := PgCount(db.bound(), "select count(*) from notes_app.notes", nil); got.String() != "0" {
						t.Fatalf("fresh origin contains rows: %v", got)
					}
				})
			}
			status, err := InspectPgMigrationStatus(f.ctx, f.worker, history, f.roles)
			if err != nil || status.InitialVersion != origin || status.DatabaseUUID != before.DatabaseUUID ||
				(origin == 2 && (!strings.Contains(status.HistoryError, "MIG016") || status.CurrentVersion != 0)) ||
				(origin == 3 && (status.HistoryError != "" || status.CurrentVersion != 3)) {
				t.Fatalf("status selected the wrong origin: %+v, %v", status, err)
			}
		})
	}
}

func pgBootTestDatabase(t *testing.T, f *pgControlTestFixture, version int) *Database {
	t.Helper()
	conn := f.worker.Config()
	config := PostgresConfig{DBName: conn.Database, User: conn.User, Password: conn.Password,
		Host: conn.Host, Port: int(conn.Port), Schema: f.namespace, ControlOwner: f.roles.Owner, PoolSize: 1, MigrationTopology: "Embedded"}
	if strings.HasPrefix(conn.Host, "/") {
		config.SocketDir = conn.Host
	}
	history := pgExpansionTestHistory(f.namespace, version)
	db := &Database{Name: "Main", Config: config, migrationHistory: &history,
		// Versioned startup must never use legacy name-based bootstrap.
		Tables: []PostgresTable{{Name: "legacy_bootstrap_must_not_run"}}}
	t.Cleanup(func() {
		postgresConnectOnce.Range(func(key, value any) bool {
			initialization, ok := value.(*postgresInitialization)
			if !ok {
				return true
			}
			<-initialization.done
			if initialization.db != nil && initialization.db.pool.Config().ConnConfig.Database == conn.Database {
				postgresConnectOnce.CompareAndDelete(key, value)
				initialization.db.pool.Close()
			}
			return true
		})
	})
	return db
}

func pgBootRefuses(t *testing.T, db *Database, fragment string) {
	t.Helper()
	entered := false
	failure := recoverDebugSQLFailure(func() { WithDatabase(db, func() { entered = true }) })
	if entered || failure == nil || !strings.Contains(fmt.Sprint(failure), fragment) {
		t.Fatalf("startup refusal %q: body=%v failure=%v", fragment, entered, failure)
	}
	if db.bound() != nil {
		t.Fatal("failed startup published a database binding")
	}
}

func TestPgMigrationBootRequiresInstallationAndCanRetry(t *testing.T) {
	f := pgNewControlTest(t)
	db := pgBootTestDatabase(t, f, 1)
	pgBootRefuses(t, db, "migration startup refused")
	var tables int
	if err := f.installer.QueryRow(f.ctx, "select count(*) from pg_catalog.pg_tables where schemaname=$1", f.namespace).Scan(&tables); err != nil || tables != 0 {
		t.Fatalf("uninstalled boot performed DDL: %d, %v", tables, err)
	}
	f.install(t, 1)
	WithDatabase(db, func() {
		PgExec(db.bound(), "insert into notes_app.notes(id,active) values ('retry',true)", nil)
	})
	if db.bound() != nil {
		t.Fatal("successful scope retained its binding")
	}
	if err := f.installer.QueryRow(f.ctx, "select count(*) from pg_catalog.pg_tables where schemaname=$1", f.namespace).Scan(&tables); err != nil || tables != len(pgMigrationControlTables)+1 {
		t.Fatalf("versioned startup used legacy bootstrap: %d, %v", tables, err)
	}
}

func TestPgMigrationBootKeepsRowsAndSeparatesRevisions(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	v1, v2 := pgBootTestDatabase(t, f, 1), pgBootTestDatabase(t, f, 2)
	var old *PostgresDB
	WithDatabase(v1, func() {
		old = v1.bound()
		WithTransaction(func() {
			WithDatabase(v1, func() {
				PgExec(old, "insert into notes_app.notes(id,active) values ('before',true)", nil)
			})
		})
	})
	WithDatabase(v2, func() {
		if v2.bound() == old || v2.bound().migration.version != 2 || old.migration.version != 1 {
			t.Fatal("a later revision reused or mutated the old binding")
		}
		if n := PgCount(v2.bound(), "select count(*) from notes_app.notes where rank = -9007199254740993 and optional is null", nil); n.String() != "1" {
			t.Fatalf("startup lost or failed to migrate the existing row: %s", n.String())
		}
	})
	// A new pool forces real startup of the old source after a later deployment.
	restarted := pgBootTestDatabase(t, f, 1)
	restarted.Config.PoolSize = 2
	WithDatabase(restarted, func() {
		PgExec(restarted.bound(), "insert into notes_app.notes(id,active) values ('old-restart',false)", nil)
	})
	WithDatabase(v1, func() {
		if v1.bound() != old {
			t.Fatal("identical configuration did not reuse its initialized pool")
		}
		if n := PgCount(old, "select count(*) from notes_app.notes", nil); n.String() != "2" {
			t.Fatalf("old revision cannot read retained rows: %s", n.String())
		}
	})
}

func TestPgMigrationBootRefusesLookalikesAndChangedContracts(t *testing.T) {
	for _, scenario := range []string{"unrecorded table", "stored-value compatibility", "catalog", "control owner", "namespace"} {
		t.Run(scenario, func(t *testing.T) {
			f := pgNewControlTest(t)
			f.install(t, 1)
			db := pgBootTestDatabase(t, f, 1)
			fragment := "migration startup refused"
			switch scenario {
			case "unrecorded table":
				f.call(t, "create table notes_app.notes(id text primary key, active bool not null)")
				f.call(t, "insert into notes_app.notes values ('unowned',true)")
			case "stored-value compatibility":
				f.expand(t, 1)
				old := db.migrationHistory.StoredValueCompatibility
				db.migrationHistory.StoredValueCompatibility = "tesl-stored-value-v1:" + strings.Repeat("b", 64)
				db.migrationHistory.HistoryJSON = strings.ReplaceAll(db.migrationHistory.HistoryJSON, old, db.migrationHistory.StoredValueCompatibility)
			case "catalog":
				f.expand(t, 1)
				f.call(t, "alter table notes_app.notes alter column active drop not null")
			case "control owner":
				f.expand(t, 1)
				db.Config.ControlOwner = f.roles.Worker
			case "namespace":
				db.Config.Schema = "wrong_namespace"
				fragment = "namespace disagrees"
			}
			pgBootRefuses(t, db, fragment)
			if scenario == "unrecorded table" {
				var id string
				if err := f.worker.QueryRow(f.ctx, "select id from notes_app.notes").Scan(&id); err != nil || id != "unowned" {
					t.Fatalf("refusal touched existing data: %q, %v", id, err)
				}
			}
		})
	}
}

func TestPgMigrationBootConcurrentScopesShareOneInitializedPool(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	db := pgBootTestDatabase(t, f, 1)
	var group sync.WaitGroup
	pools := make(chan *PostgresDB, 8)
	failures := make(chan any, 8)
	for range 8 {
		group.Go(func() {
			failures <- recoverDebugSQLFailure(func() {
				WithDatabase(db, func() { pools <- db.bound() })
			})
		})
	}
	group.Wait()
	close(pools)
	close(failures)
	for failure := range failures {
		if failure != nil {
			t.Fatalf("concurrent startup failed: %v", failure)
		}
	}
	var first *PostgresDB
	for pool := range pools {
		if first == nil {
			first = pool
		} else if first != pool {
			t.Fatal("concurrent startup published different pools")
		}
	}
	state, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
	if err != nil || len(state.Versions) != 3 {
		t.Fatalf("concurrent startup duplicated or lost history: %+v, %v", state, err)
	}
}

func TestPgMigrationBootVerifiesEveryReplacementConnection(t *testing.T) {
	for _, scenario := range []string{"UUID", "fence", "format", "domain", "protocol", "worker", "retirement"} {
		t.Run(scenario, func(t *testing.T) {
			f := pgNewControlTest(t)
			f.install(t, 1)
			db := pgBootTestDatabase(t, f, 1)
			WithDatabase(db, func() {
				opened := db.bound()
				var statement string
				switch scenario {
				case "UUID":
					statement = "update notes_app.tesl_schema_meta set database_uuid='11111111-1111-1111-1111-111111111111'"
				case "fence":
					statement = "update notes_app.tesl_schema_meta set fence_ns=fence_ns+1"
				case "format":
					statement = "update notes_app.tesl_schema_meta set format_version=999"
				case "domain":
					statement = "update notes_app.tesl_schema_meta set fence_domain='different'"
				case "protocol":
					statement = "update notes_app.tesl_schema_meta set retirement_protocol_floor=2"
				case "worker":
					// Use a dedicated connection with the wrong actual login.
					if err := pgVerifyMigrationConnection(f.ctx, f.installer, opened); err == nil {
						t.Fatal("installer login was accepted as a worker")
					}
					return
				case "retirement":
					f.expand(t, 2)
					statement = "update notes_app.tesl_schema_state set min_version=2,compat_floor=2"
				}
				if _, err := f.installer.Exec(f.ctx, statement); err != nil {
					t.Fatal(err)
				}
				// The listener path uses a dedicated connection, not the pool.
				if err := pgVerifyMigrationConnection(f.ctx, f.worker, opened); err == nil {
					t.Fatal("dedicated connection ignored changed identity/admission")
				}
				opened.pool.Reset()
				ctx, cancel := context.WithTimeout(f.ctx, time.Second)
				defer cancel()
				if err := opened.pool.Ping(ctx); err == nil {
					t.Fatal("replacement physical pool connection ignored changed identity/admission")
				}
			})
		})
	}
}

// Keep the verifier's transaction closed on a successful dedicated connection,
// so LISTEN can follow it and no idle transaction pins an old snapshot.
func TestPgMigrationBootDedicatedConnectionFinishesAdmission(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	db := pgBootTestDatabase(t, f, 1)
	WithDatabase(db, func() {
		if err := pgVerifyMigrationConnection(f.ctx, f.worker, db.bound()); err != nil {
			t.Fatal(err)
		}
		if f.worker.PgConn().TxStatus() != 'I' {
			t.Fatal("connection verification retained a transaction")
		}
		if _, err := f.worker.Exec(f.ctx, "listen migration_boot_test"); err != nil {
			t.Fatal(err)
		}
		if err := pgVerifyMigrationConnection(f.ctx, f.worker, db.bound()); err != nil {
			t.Fatalf("listening connection failed admission: %v", err)
		}
	})
}
