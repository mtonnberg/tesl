package teslrt

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"testing"
)

type pgFacilityConstructor struct {
	kind string
	run  func(*Database)
}

func pgFacilityConstructors() []pgFacilityConstructor {
	return []pgFacilityConstructor{
		{"queue", func(database *Database) { NewQueueOn(database, "Jobs", 3, "fixed", 1) }},
		{"cache", func(database *Database) {
			NewCacheOn[string](database, "Results", 10, func(value string) any { return value }, DecodeStringValue)
		}},
		{"email outbox", func(database *Database) { NewOutboxOn(database, SmtpSettings{}) }},
		{"SSE channel", func(database *Database) { NewSseChannelOn(database, "Updates") }},
	}
}

func pgFacilityCleanup(t *testing.T, database *Database) {
	t.Helper()
	t.Cleanup(func() {
		if value, found := pgPubsubs.Load(database); found {
			value.(*pgPubsub).Close()
		}
	})
}

func pgFacilityPanic(run func()) (value any) {
	defer func() { value = recover() }()
	run()
	return nil
}

func pgRequireFacilityRefusal(t *testing.T, failure any, kind string) {
	t.Helper()
	text := fmt.Sprint(failure)
	if failure == nil || !strings.Contains(text, "Worker migration topology does not yet support durable") ||
		!strings.Contains(text, kind) || !strings.Contains(text, "protected runtime storage") {
		t.Fatalf("expected explicit unsupported Worker %s refusal, got %v", kind, failure)
	}
}

// INV-PRIVILEGE; TR-BOOT-EXPAND.
func TestPgMigrationWorkerFacilitiesRefuseEveryConstructorBeforeConnection(t *testing.T) {
	for _, constructor := range pgFacilityConstructors() {
		for _, linkFirst := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/history-first-%t", constructor.kind, linkFirst), func(t *testing.T) {
				family, database := compiledHistoryFixture(t, t.Name())
				database.Config.MigrationTopology = "Worker"
				// Invalid connection data must never be parsed, printed or opened:
				// capability refusal is a pure step before connection initialization.
				database.Config.Password = "'private-connection-value"
				database.Config.DDLConnection = "postgres://private-connection-value:bad%/"
				pgFacilityCleanup(t, database)
				if linkFirst {
					RegisterDatabaseMigrationHistory(database, family)
				}
				constructor.run(database)
				if !linkFirst {
					if err := pgVerifyMigrationFacilities(database); err != nil {
						t.Fatalf("unversioned constructor should remain usable before history registration: %v", err)
					}
					RegisterDatabaseMigrationHistory(database, family)
				}
				before, _ := database.CompiledMigrationHistory()
				err := pgVerifyMigrationFacilities(database)
				pgRequireFacilityRefusal(t, err, constructor.kind)
				if strings.Contains(err.Error(), "private-connection-value") {
					t.Fatal("facility refusal exposed connection credentials")
				}
				called := false
				failure := pgFacilityPanic(func() { WithDatabase(database, func() { called = true }) })
				pgRequireFacilityRefusal(t, failure, constructor.kind)
				after, _ := database.CompiledMigrationHistory()
				if called || database.bound() != nil || before != after {
					t.Fatal("unsupported facility entered application code, bound a pool or changed source history")
				}
			})
		}
	}
}

// INV-PRIVILEGE; TR-BOOT-EXPAND.
func TestPgMigrationWorkerFacilitiesBlockSchemaCommandsButPreserveStatus(t *testing.T) {
	for _, constructor := range pgFacilityConstructors() {
		t.Run(constructor.kind, func(t *testing.T) {
			history := pgExpansionTestHistory("facility_command", 1)
			database := &Database{Name: "Facilities", Config: PostgresConfig{
				Schema: history.Namespace, MigrationTopology: "Worker", RequestRole: "request", WorkerRole: "worker",
				User: "request", Password: "'never-print-this",
			}, migrationHistory: &history}
			pgFacilityCleanup(t, database)
			constructor.run(database)
			identity := "FacilityCommand." + constructor.kind
			RegisterDatabaseIdentity(identity, database)
			t.Cleanup(func() { databaseIdentities.Delete(identity) })
			for _, verb := range []string{"install", "worker"} {
				var out bytes.Buffer
				err := pgRunSchemaCommandContext(context.Background(), pgSchemaCommand{
					verb: verb, database: history.Database, worker: "worker", request: "request", json: true,
				}, &out)
				pgRequireFacilityRefusal(t, err, constructor.kind)
				if out.Len() != 0 || database.bound() != nil || strings.Contains(err.Error(), "never-print-this") {
					t.Fatalf("unsupported %s performed work or exposed credentials: %v %s", verb, err, &out)
				}
			}
			var out bytes.Buffer
			err := pgRunSchemaCommandContext(context.Background(), pgSchemaCommand{
				verb: "status", database: history.Database, json: true,
			}, &out)
			if err == nil || err.Error() != "invalid PostgreSQL schema connection configuration" || out.Len() != 0 {
				t.Fatalf("status should reach its ordinary connection validation, not facility refusal: %v %s", err, &out)
			}
		})
	}
}

// INV-PRIVILEGE; TR-BOOT-EXPAND.
func TestPgMigrationWorkerFacilitiesRespectRuntimeDefaultAndLegacyMode(t *testing.T) {
	for _, scenario := range []struct {
		name, topology, deployed          string
		versioned, present, workerRefusal bool
	}{
		{"explicit-worker", "Worker", "", true, false, true},
		{"deployed-default", "", "1", true, true, true},
		{"empty-deployed-presence", "", "", true, true, true},
		{"false-is-still-present", "", "false", true, true, true},
		{"local-default", "", "", true, false, false},
		{"explicit-embedded-deployed", "Embedded", "1", true, true, false},
		{"legacy-worker-setting", "Worker", "1", false, true, false},
		{"legacy-deployed", "", "1", false, true, false},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			t.Setenv("TESL_DEPLOYED", scenario.deployed)
			if !scenario.present {
				if err := os.Unsetenv("TESL_DEPLOYED"); err != nil {
					t.Fatal(err)
				}
			}
			family, database := compiledHistoryFixture(t, t.Name())
			database.Config.MigrationTopology = scenario.topology
			pgFacilityCleanup(t, database)
			if scenario.versioned {
				RegisterDatabaseMigrationHistory(database, family)
			}
			for _, constructor := range pgFacilityConstructors() {
				constructor.run(database)
			}
			err := pgVerifyMigrationFacilities(database)
			if scenario.workerRefusal {
				for _, constructor := range pgFacilityConstructors() {
					pgRequireFacilityRefusal(t, err, constructor.kind)
				}
			} else if scenario.versioned {
				if err == nil || !strings.Contains(err.Error(), "Embedded migration topology does not yet support versioned queues") {
					t.Fatalf("versioned Embedded queue did not refuse legacy storage: %v", err)
				}
			} else if err != nil {
				t.Fatalf("existing unversioned facility behavior was refused: %v", err)
			}
			if database.bound() != nil || database.migrationFacilitiesClosed {
				t.Fatal("facility-only preflight opened a connection or sealed a refused/legacy declaration")
			}
		})
	}
}

// INV-PRIVILEGE; TR-BOOT-EXPAND.
func TestPgMigrationWorkerFacilitiesAreIsolatedPerDatabase(t *testing.T) {
	cleanFamily, clean := compiledHistoryFixture(t, "FacilitiesClean")
	dirtyFamily, dirty := compiledHistoryFixture(t, "FacilitiesDirty")
	for _, database := range []*Database{clean, dirty} {
		database.Config.MigrationTopology = "Worker"
		pgFacilityCleanup(t, database)
	}
	RegisterDatabaseMigrationHistory(clean, cleanFamily)
	RegisterDatabaseMigrationHistory(dirty, dirtyFamily)
	NewQueueOn(dirty, "OtherDatabaseQueue", 1, "", 0)
	if err := pgVerifyMigrationFacilities(clean); err != nil {
		t.Fatalf("another database's declarations contaminated the clean Worker: %v", err)
	}
	pgRequireFacilityRefusal(t, pgVerifyMigrationFacilities(dirty), "OtherDatabaseQueue")
	if !clean.migrationFacilitiesClosed || dirty.migrationFacilitiesClosed {
		t.Fatal("preflight sealed the wrong database")
	}
}

// INV-PRIVILEGE; TR-BOOT-EXPAND.
func TestPgMigrationWorkerFacilitiesRefuseLateConstructorsBeforeSideEffects(t *testing.T) {
	for _, constructor := range pgFacilityConstructors() {
		t.Run(constructor.kind, func(t *testing.T) {
			family, database := compiledHistoryFixture(t, t.Name())
			database.Config.MigrationTopology = "Worker"
			RegisterDatabaseMigrationHistory(database, family)
			if err := pgVerifyMigrationFacilities(database); err != nil {
				t.Fatal(err)
			}
			pgRequireFacilityRefusal(t, pgFacilityPanic(func() { constructor.run(database) }), constructor.kind)
			if len(database.migrationFacilities) != 0 {
				t.Fatal("late constructor changed the validated declaration set")
			}
			if _, found := pgPubsubs.Load(database); found {
				t.Fatal("late constructor started a listener runtime before refusing")
			}
			if err := pgVerifyMigrationFacilities(database); err != nil {
				t.Fatalf("refused late registration poisoned the validated database: %v", err)
			}
		})
	}
	// Once validated, registration cannot reopen because deployment environment
	// defaults later change. The pool was initialized under the earlier topology.
	t.Setenv("TESL_DEPLOYED", "")
	family, database := compiledHistoryFixture(t, "FacilitiesSealedDefault")
	RegisterDatabaseMigrationHistory(database, family)
	if err := pgVerifyMigrationFacilities(database); err != nil {
		t.Fatal(err)
	}
	if err := os.Unsetenv("TESL_DEPLOYED"); err != nil {
		t.Fatal(err)
	}
	pgRequireFacilityRefusal(t, pgFacilityPanic(func() { NewOutboxOn(database, SmtpSettings{}) }), "email outbox")
}

// INV-PRIVILEGE; TR-BOOT-EXPAND.
func TestPgMigrationWorkerFacilitiesRegistrationAndValidationAreAtomic(t *testing.T) {
	for iteration := range 64 {
		family, database := compiledHistoryFixture(t, fmt.Sprintf("FacilitiesRace%d", iteration))
		database.Config.MigrationTopology = "Worker"
		RegisterDatabaseMigrationHistory(database, family)
		start := make(chan struct{})
		var group sync.WaitGroup
		var validation error
		var registration any
		group.Go(func() {
			<-start
			validation = pgVerifyMigrationFacilities(database)
		})
		group.Go(func() {
			<-start
			registration = pgFacilityPanic(func() {
				NewCacheOn[string](database, "ConcurrentCache", 0, func(value string) any { return value }, DecodeStringValue)
			})
		})
		close(start)
		group.Wait()
		if (validation == nil) == (registration == nil) {
			t.Fatalf("expected exactly one side of registration/preflight to refuse: validation=%v registration=%v", validation, registration)
		}
		if validation != nil {
			pgRequireFacilityRefusal(t, validation, "ConcurrentCache")
		} else {
			pgRequireFacilityRefusal(t, registration, "ConcurrentCache")
		}
	}
}

// INV-PRIVILEGE; TR-BOOT-EXPAND.
func TestPgMigrationWorkerFacilitiesGuardLazyStorageBeforePoolOrCachedReadiness(t *testing.T) {
	connection := &PostgresDB{schema: "worker_space", migration: &pgMigrationAdmission{
		roles: PgMigrationControlRoles{Owner: "control", Worker: "schema", Request: "app"},
	}}
	// A nil pool is deliberate: every forbidden path must refuse before any SQL,
	// even when an old bootstrap cache or pub/sub ready bit claims completion.
	for _, table := range []string{jobsTable, cacheTable, outboxTable} {
		for _, cached := range []bool{false, true} {
			key := pgTableKey{db: connection, table: table}
			if cached {
				pgTablesReady.Store(key, &pgTableOnce{done: true})
			}
			called := false
			pgRequireFacilityRefusal(t, pgFacilityPanic(func() {
				ensureTable(connection, table, func(string) []string { called = true; return nil })
			}), table)
			if called {
				t.Fatal("forbidden lazy storage evaluated its DDL callback")
			}
			pgTablesReady.Delete(key)
		}
	}
	runtime := &pgPubsub{ready: true}
	ctx := context.Background()
	pgRequireFacilityRefusal(t, runtime.prepareOn(connection, nil), "SSE")
	pgRequireFacilityRefusal(t, createPubsubOutbox(ctx, connection), "SSE")
	pgRequireFacilityRefusal(t, normalizeLegacyPubsubRows(connection), "SSE")
	_, err := writePubsub(ctx, nil, connection, "Updates", "key", "{}")
	pgRequireFacilityRefusal(t, err, "SSE")
	listened, err := runtime.listen(connection)
	pgRequireFacilityRefusal(t, err, "SSE")
	if listened {
		t.Fatal("unsupported Worker started a listener")
	}
	for _, legacy := range []*PostgresDB{nil, {}} {
		if err := pgVerifyMigrationFacilityConnection(legacy, jobsTable); err != nil {
			t.Fatalf("legacy/Embedded opened connection was refused: %v", err)
		}
	}
}
