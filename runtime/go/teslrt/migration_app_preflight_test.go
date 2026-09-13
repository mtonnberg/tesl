package teslrt

import (
	"bytes"
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
)

func appPreflightDatabase(t *testing.T, name, topology string) *Database {
	t.Helper()
	family, database := compiledHistoryFixture(t, t.Name()+name)
	database.Name = name
	database.Config.MigrationTopology = topology
	// A malformed secret must never reach DSN parsing in the local preflight.
	database.Config.Password = "'preflight-private"
	RegisterDatabaseMigrationHistory(database, family)
	t.Cleanup(func() {
		pgMigrationRegistrations.Lock()
		delete(pgMigrationClosedFamilies, family)
		pgMigrationRegistrations.Unlock()
	})
	pgFacilityCleanup(t, database)
	return database
}

func appPreflightQueue(t *testing.T) (*Database, *Queue, func()) {
	t.Helper()
	history, companion := queueProjectionFixture(t)
	registerQueueProjection(t, history, companion)
	database := RegisterDatabaseIdentity(history.Database, NewDatabase("QueueApp", PostgresConfig{Schema: history.Namespace, MigrationTopology: "Embedded", Password: "'preflight-private"}, nil))
	RegisterDatabaseMigrationHistory(database, history.Family)
	queue := NewQueueOn(database, "AppNotifications", 1, "", 0)
	RegisterQueueSchema(queue, database, history.Family, "Notifications", 3)
	t.Cleanup(func() {
		pgMigrationRegistrations.Lock()
		delete(pgMigrationClosedFamilies, history.Family)
		pgMigrationRegistrations.Unlock()
		queueSchemaOwners.Lock()
		delete(queueSchemaOwners.queues, database)
		queueSchemaOwners.Unlock()
	})
	pgFacilityCleanup(t, database)
	register := func() {
		RegisterQueueSchemaJobCodec(queue, history.Family, "Notifications", "Notify", 3,
			queueProjectionPayload(companion)["contractHash"].(string), "Schema.Todo.VCurrent.Notify",
			func(value any) any { return value }, func(value any) (any, error) { return value, nil })
	}
	return database, queue, register
}

// Exercises preparation and atomic registration closure only. This private test
// helper never opens a connection or grants production queue admission. Public
// PreflightApplicationDatabases must still refuse every versioned queued DB.
func prepareAppRegistrationsForTest(databases ...*Database) error {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	pending, err := pgPrepareApplicationDatabases(databases)
	if err != nil {
		return err
	}
	pending.closeRegistrations()
	return nil
}

func requireAppPreflightOpen(t *testing.T, databases ...*Database) {
	t.Helper()
	for _, database := range databases {
		if database.applicationPreflightClosed || database.migrationFacilitiesClosed || database.bound() != nil {
			t.Fatal("failed preflight sealed a declaration or opened a binding", database.Name)
		}
	}
}

// INV-PRIVILEGE; TR-BOOT-EXPAND. A batch failure must not publish any closures.
func TestAppPreflightChecksAllTargetsBeforeClosureAndCanRetry(t *testing.T) {
	first := appPreflightDatabase(t, "First", "Worker")
	second := appPreflightDatabase(t, "Second", "Invalid")
	if err := PreflightApplicationDatabases(first, second); err == nil || !strings.Contains(err.Error(), "topology") || strings.Contains(err.Error(), "preflight-private") {
		t.Fatal("expected local topology refusal", err)
	}
	requireAppPreflightOpen(t, first, second)
	// Repair the actual bad declaration; no reset/reopen escape hatch is needed.
	second.Config.MigrationTopology = "Embedded"
	second.Config.Schema = "wrong_namespace"
	if err := PreflightApplicationDatabases(first, second); err == nil || !strings.Contains(err.Error(), "namespace") {
		t.Fatal("namespace mismatch passed local validation", err)
	}
	requireAppPreflightOpen(t, first, second)
	second.Config.Schema = "app_space"
	if err := PreflightApplicationDatabases(first, second, first); err != nil {
		t.Fatal(err)
	}
	if !first.applicationPreflightClosed || !second.applicationPreflightClosed || first.bound() != nil || second.bound() != nil {
		t.Fatal("batch did not seal exactly its targets without I/O")
	}
	if err := PreflightApplicationDatabases(first, second); err != nil {
		t.Fatal("idempotent startup", err)
	}
}

func TestAppPreflightIncompleteCodecsDoNotSealAnotherDatabase(t *testing.T) {
	first := appPreflightDatabase(t, "First", "Worker")
	queued, queue, register := appPreflightQueue(t)
	if err := prepareAppRegistrationsForTest(first, queued); err == nil || !strings.Contains(err.Error(), "incomplete") {
		t.Fatal(err)
	}
	requireAppPreflightOpen(t, first, queued)
	if queue.backend.(*pgQueueBackend).queueCodecsClosed {
		t.Fatal("failed batch sealed codecs")
	}
	register()
	if err := prepareAppRegistrationsForTest(first, queued, queued); err != nil {
		t.Fatal(err)
	}
	backend := queue.backend.(*pgQueueBackend)
	if !backend.queueCodecsClosed || !queued.applicationPreflightClosed {
		t.Fatal("complete codecs not sealed")
	}
	for _, late := range []func(){register, func() {
		RegisterJobCodec(queue, "Other", func(v any) any { return v }, func(v any) (any, error) { return v, nil })
	}, func() { RegisterQueueSchema(queue, queued, backend.queueSchema.history.Family, "Notifications", 3) }, func() { NewQueueOn(queued, "Late", 1, "", 0) }} {
		failure := pgFacilityPanic(late)
		if failure == nil || !strings.Contains(fmt.Sprint(failure), "closed") {
			t.Fatal("late registration was not refused", failure)
		}
	}
	if codecs, err := QueueSourceCodecs(queue); err != nil || len(codecs) != 1 {
		t.Fatal("late refusal changed codecs", codecs, err)
	}
}

func TestAppPreflightSeesDuplicateNamedUnboundQueueObjects(t *testing.T) {
	database, queue, register := appPreflightQueue(t)
	register()
	NewQueueOn(database, queue.name, 1, "", 0)
	if err := PreflightApplicationDatabases(database); err == nil || !strings.Contains(err.Error(), "bindings") {
		t.Fatal("duplicate name hid unbound backend", err)
	}
	requireAppPreflightOpen(t, database)
}

func TestAppPreflightDoesNotActivateUnlistedDatabasesOrBroadenSingleScope(t *testing.T) {
	active := appPreflightDatabase(t, "Active", "Worker")
	inactive := appPreflightDatabase(t, "Inactive", "Worker")
	NewQueueOn(inactive, "InactiveJobs", 1, "", 0)
	if err := PreflightApplicationDatabases(active); err != nil {
		t.Fatal(err)
	}
	requireAppPreflightOpen(t, inactive)
	// The explicit singleton guard remains local, and Embedded's ordinary
	// WithDatabase capability check does not acquire App declaration semantics.
	embedded := appPreflightDatabase(t, "ExplicitEmbedded", "Embedded")
	NewCacheOn[string](embedded, "ExistingScopeCache", 1, func(v string) any { return v }, DecodeStringValue)
	if err := pgVerifyMigrationFacilities(embedded); err != nil {
		t.Fatal(err)
	}
	requireAppPreflightOpen(t, embedded)
	if err := PreflightApplicationDatabases(inactive); err == nil {
		t.Fatal("inactive queue unexpectedly acquired production admission")
	}
	requireAppPreflightOpen(t, inactive)
}

func TestAppPreflightLegacyAndInvalidArgumentsHaveNoPartialEffects(t *testing.T) {
	first := appPreflightDatabase(t, "First", "Worker")
	if err := PreflightApplicationDatabases(first, nil); err == nil {
		t.Fatal("nil active target accepted")
	}
	requireAppPreflightOpen(t, first)
	legacy := NewDatabase("Legacy", PostgresConfig{MigrationTopology: "Worker"}, nil)
	pgFacilityCleanup(t, legacy)
	queue := NewQueueOn(legacy, "Jobs", 1, "", 0)
	if err := PreflightApplicationDatabases(legacy); err != nil {
		t.Fatal(err)
	}
	RegisterJobCodec(queue, "Legacy", func(v any) any { return v }, func(v any) (any, error) { return v, nil })
	NewQueueOn(legacy, "Later", 1, "", 0)
	requireAppPreflightOpen(t, legacy)
}

func TestAppPreflightSchemaCommandSelectsOnlyItsOwnDatabase(t *testing.T) {
	history := pgExpansionTestHistory("preflight_selected", 1)
	selected := &Database{Name: "Selected", Config: PostgresConfig{Schema: history.Namespace, MigrationTopology: "Worker", User: "request", RequestRole: "request", WorkerRole: "worker", Password: "'private"}, migrationHistory: &history}
	identity := "AppPreflightSelected"
	RegisterDatabaseIdentity(identity, selected)
	t.Cleanup(func() { databaseIdentities.Delete(identity) })
	inactive := appPreflightDatabase(t, "Inactive", "Worker")
	inactiveIdentity := "AppPreflightInactive"
	RegisterDatabaseIdentity(inactiveIdentity, inactive)
	t.Cleanup(func() { databaseIdentities.Delete(inactiveIdentity) })
	NewQueueOn(inactive, "InactiveJobs", 1, "", 0)
	var output bytes.Buffer
	err := pgRunSchemaCommandContext(context.Background(), pgSchemaCommand{verb: "worker", database: history.Database}, &output)
	if err == nil || err.Error() != "invalid PostgreSQL schema connection configuration" {
		t.Fatal("selected command checked unrelated App capabilities", err)
	}
	requireAppPreflightOpen(t, inactive)
	if selected.applicationPreflightClosed || !selected.migrationFacilitiesClosed || selected.bound() != nil || output.Len() != 0 {
		t.Fatal("command gained App semantics or I/O")
	}
}

func TestAppPreflightRegistrationRaceCannotLeaveUncheckedCodecs(t *testing.T) {
	for attempt := 0; attempt < 32; attempt++ {
		t.Run(fmt.Sprint(attempt), func(t *testing.T) {
			database, queue, register := appPreflightQueue(t)
			start := make(chan struct{})
			var group sync.WaitGroup
			var preflight error
			var registration any
			group.Go(func() { <-start; preflight = prepareAppRegistrationsForTest(database) })
			group.Go(func() { <-start; registration = pgFacilityPanic(register) })
			close(start)
			group.Wait()
			if registration != nil {
				t.Fatal("first complete codec registration should remain available", registration)
			}
			if preflight != nil {
				requireAppPreflightOpen(t, database)
				if err := prepareAppRegistrationsForTest(database); err != nil {
					t.Fatal(err)
				}
			}
			if !queue.backend.(*pgQueueBackend).queueCodecsClosed {
				t.Fatal("startup accepted unsealed codecs")
			}
			if codecs, err := QueueSourceCodecs(queue); err != nil || len(codecs) != 1 {
				t.Fatal(codecs, err)
			}
		})
	}
}

func TestAppPreflightConstructorRaceIsAllOrNone(t *testing.T) {
	for attempt := 0; attempt < 32; attempt++ {
		t.Run(fmt.Sprint(attempt), func(t *testing.T) {
			first := appPreflightDatabase(t, "First", "Worker")
			second := appPreflightDatabase(t, "Second", "Worker")
			start := make(chan struct{})
			var group sync.WaitGroup
			var validation error
			var registration any
			group.Go(func() { <-start; validation = PreflightApplicationDatabases(first, second) })
			group.Go(func() { <-start; registration = pgFacilityPanic(func() { NewQueueOn(second, "Racing", 1, "", 0) }) })
			close(start)
			group.Wait()
			if (validation == nil) == (registration == nil) {
				t.Fatal("both race participants succeeded/refused", validation, registration)
			}
			if validation != nil {
				requireAppPreflightOpen(t, first, second)
			} else if !first.applicationPreflightClosed || !second.applicationPreflightClosed {
				t.Fatal("partial success")
			}
		})
	}
}

func TestAppPreflightCannotAcquireQueueAuthorityFromLateCompanion(t *testing.T) {
	history, companion := queueProjectionFixture(t)
	registerCompiledMigrationHistory(history.Database, history.Family, history.Namespace, history.CurrentVersion, history.SourceCompilerABI, history.StoredValueCompatibility, history.HistoryJSON)
	database := RegisterDatabaseMigrationHistory(NewDatabase("OldEntityOnly", PostgresConfig{Schema: history.Namespace, MigrationTopology: "Embedded"}, nil), history.Family)
	t.Cleanup(func() {
		pgMigrationRegistrations.Lock()
		delete(pgMigrationClosedFamilies, history.Family)
		pgMigrationRegistrations.Unlock()
	})
	if err := PreflightApplicationDatabases(database); err != nil {
		t.Fatal(err)
	}
	failure := pgFacilityPanic(func() { registerCompiledQueueHistory(queueProjectionJSON(t, companion)) })
	if failure == nil || !strings.Contains(fmt.Sprint(failure), "registration is closed") {
		t.Fatal("late queue contracts bypassed startup validation", failure)
	}
	if _, err := history.QueueSourceInventory(1); err == nil {
		t.Fatal("failed registration published queue authority")
	}
}

func TestAppPreflightDuplicateNamedQueueRaceCannotEscapeClosure(t *testing.T) {
	for attempt := 0; attempt < 32; attempt++ {
		t.Run(fmt.Sprint(attempt), func(t *testing.T) {
			database, queue, register := appPreflightQueue(t)
			register()
			start := make(chan struct{})
			var group sync.WaitGroup
			var validation error
			var registration any
			group.Go(func() { <-start; validation = prepareAppRegistrationsForTest(database) })
			group.Go(func() { <-start; registration = pgFacilityPanic(func() { NewQueueOn(database, queue.name, 1, "", 0) }) })
			close(start)
			group.Wait()
			if (validation == nil) == (registration == nil) {
				t.Fatal("duplicate backend escaped checked set", validation, registration)
			}
			if validation != nil {
				requireAppPreflightOpen(t, database)
			} else if !queue.backend.(*pgQueueBackend).queueCodecsClosed {
				t.Fatal("incomplete codec closure")
			}
		})
	}
}

func TestAppPreflightDoesNotSealCompletedCodecsBeforeLaterRefusal(t *testing.T) {
	database, queue, register := appPreflightQueue(t)
	register()
	later := appPreflightDatabase(t, "Later", "Invalid")
	if err := prepareAppRegistrationsForTest(database, later); err == nil {
		t.Fatal("invalid later target accepted")
	}
	requireAppPreflightOpen(t, database, later)
	if queue.backend.(*pgQueueBackend).queueCodecsClosed {
		t.Fatal("later failure sealed first target's complete codecs")
	}
	later.Config.MigrationTopology = "Worker"
	if err := prepareAppRegistrationsForTest(database, later); err != nil {
		t.Fatal("repair/retry", err)
	}
	if !queue.backend.(*pgQueueBackend).queueCodecsClosed || !later.applicationPreflightClosed {
		t.Fatal("repair did not publish all closures")
	}
	for _, constructor := range pgFacilityConstructors() {
		failure := pgFacilityPanic(func() { constructor.run(database) })
		if failure == nil || !strings.Contains(fmt.Sprint(failure), "declarations are closed") {
			t.Fatal("late App facility escaped closure", constructor.kind, failure)
		}
	}
}

func TestAppPreflightAndCodecReadersUseCompatibleLockOrder(t *testing.T) {
	database, queue, register := appPreflightQueue(t)
	register()
	var group sync.WaitGroup
	group.Go(func() {
		for range 100 {
			if _, err := QueueSourceCodecs(queue); err != nil {
				t.Error(err)
			}
		}
	})
	group.Go(func() {
		for range 100 {
			if err := prepareAppRegistrationsForTest(database); err != nil {
				t.Error(err)
			}
		}
	})
	group.Wait()
}

func TestAppPreflightVersionedQueuesRefuseLegacyStorageInBothTopologies(t *testing.T) {
	for _, topology := range []string{"Worker", "Embedded"} {
		t.Run(topology, func(t *testing.T) {
			database, queue, register := appPreflightQueue(t)
			register()
			database.Config.MigrationTopology = topology
			first := appPreflightDatabase(t, "EntityOnly", "Worker")
			want := "Embedded migration topology does not yet support versioned queues"
			if topology == "Worker" {
				want = "Worker migration topology does not yet support durable queue"
			}
			requireRefusal := func(err any) {
				t.Helper()
				if err == nil || !strings.Contains(fmt.Sprint(err), want) {
					t.Fatal("versioned queue entered legacy runtime", err)
				}
			}
			requireRefusal(PreflightApplicationDatabases(first, database))
			requireAppPreflightOpen(t, first, database)
			if queue.backend.(*pgQueueBackend).queueCodecsClosed {
				t.Fatal("production refusal published codec closure")
			}
			called := false
			requireRefusal(pgFacilityPanic(func() { WithDatabase(database, func() { called = true }) }))
			if called {
				t.Fatal("explicit scope ran a queued versioned database")
			}
			history, _ := database.CompiledMigrationHistory()
			for _, verb := range []string{"install", "worker"} {
				var out bytes.Buffer
				requireRefusal(pgRunSchemaCommandContext(context.Background(), pgSchemaCommand{verb: verb, database: history.Database}, &out))
				if out.Len() != 0 {
					t.Fatal("refused command wrote output")
				}
			}
			roles := PgMigrationControlRoles{Worker: "embedded"}
			if topology == "Worker" {
				roles.Request = "request"
			}
			connection := &PostgresDB{schema: "test_space", migration: &pgMigrationAdmission{roles: roles}}
			for _, cached := range []bool{false, true} {
				key := pgTableKey{db: connection, table: jobsTable}
				if cached {
					pgTablesReady.Store(key, &pgTableOnce{done: true})
				}
				ranDDL := false
				failure := pgFacilityPanic(func() { ensureTable(connection, jobsTable, func(string) []string { ranDDL = true; return nil }) })
				// The opened-binding guard receives the physical table name, independently
				// of the source queue label. Its nil pool proves refusal precedes SQL.
				if failure == nil {
					t.Fatal("opened binding bypassed queue refusal")
				}
				if topology == "Embedded" {
					requireRefusal(failure)
				} else {
					pgRequireFacilityRefusal(t, failure, jobsTable)
				}
				if ranDDL {
					t.Fatal("unsupported queue evaluated DDL")
				}
				pgTablesReady.Delete(key)
			}
		})
	}
}
