package teslrt

import (
	"fmt"
	"sort"
	"strings"
	"sync"
)

// Registration transactions never hold a database lock while taking a queue
// codec lock: QueueSourceCodecs acquires these in the opposite order. All local
// registration writers join this lock; validation can inspect their immutable
// snapshots, then publish every closure only after the whole batch succeeds.
var pgMigrationRegistrations sync.Mutex
var pgMigrationClosedFamilies = map[string]bool{} // guarded by the registration transaction

type pgMigrationFacility struct{ kind, name string }

func pgMigrationQueueStorageError(database string) error {
	return fmt.Errorf("database %q: Embedded migration topology does not yet support versioned queues; protected storage and version-aware dispatch are not implemented", database)
}

func pgMigrationFacilitiesError(database string, facilities []pgMigrationFacility) error {
	labels := make([]string, 0, len(facilities))
	for _, facility := range facilities {
		label := facility.kind
		if facility.name != "" {
			label += " " + fmt.Sprintf("%q", facility.name)
		}
		labels = append(labels, label)
	}
	sort.Strings(labels)
	return fmt.Errorf("database %q: Worker migration topology does not yet support durable %s; protected runtime storage is not implemented",
		database, strings.Join(labels, ", "))
}

// Register declarations independently of history-link order. Construction remains
// usable by ordinary in-memory tests and schema status. Worker capability
// refusal and App registration closure both happen before connection startup.
func pgRegisterMigrationFacility(database *Database, kind, name string) {
	if database == nil {
		return
	}
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	facility := pgMigrationFacility{kind, name}
	database.mutex.Lock()
	defer database.mutex.Unlock()
	if database.applicationPreflightClosed {
		panic(fmt.Errorf("database %q: application startup declarations are closed", database.Name))
	}
	if database.migrationFacilitiesClosed {
		panic(pgMigrationFacilitiesError(database.Name, []pgMigrationFacility{facility}))
	}
	if database.migrationFacilities == nil {
		database.migrationFacilities = make(map[pgMigrationFacility]struct{})
	}
	database.migrationFacilities[facility] = struct{}{}
}

// Retain every actual queue, including duplicate names or queues whose codec
// registration has not completed. A name-only facility set cannot prove that
// every backend was checked and sealed. This runs before listener registration.
func pgRegisterMigrationQueue(database *Database, queue *Queue) {
	if database == nil {
		return
	}
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	database.mutex.Lock()
	defer database.mutex.Unlock()
	if database.applicationPreflightClosed || database.migrationFacilitiesClosed {
		panic(fmt.Errorf("database %q: application startup declarations are closed", database.Name))
	}
	if database.migrationQueues == nil {
		database.migrationQueues = map[*Queue]struct{}{}
	}
	database.migrationQueues[queue] = struct{}{}
}

// This is a local capability restriction, not a persisted footprint or proof
// that old binaries cannot use durable facilities. Worker runtime tables have no
// protected installation protocol yet, so a new Worker instance must declare none.
// Closing registration and inspecting declarations share one lock: a constructor
// racing with preflight either makes preflight refuse or itself refuses before
// creating a backend. Neither side can introduce a facility after validation.
func pgVerifyMigrationFacilities(database *Database) error {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	closeRegistration, err := pgCheckMigrationFacilities(database)
	if err == nil && closeRegistration {
		database.mutex.Lock()
		database.migrationFacilitiesClosed = true
		database.mutex.Unlock()
	}
	return err
}

// Called inside the registration transaction. This phase never mutates state.
func pgCheckMigrationFacilities(database *Database) (bool, error) {
	if database == nil {
		return false, nil
	}
	database.mutex.RLock()
	defer database.mutex.RUnlock()
	if database.migrationHistory == nil {
		return false, nil
	}
	roles, err := pgMigrationRoles(database.Config, database.Config.User)
	if err != nil {
		return false, fmt.Errorf("database %q: %w", database.Name, err)
	}
	if roles.Request == "" {
		for facility := range database.migrationFacilities {
			if facility.kind == "queue" {
				return false, pgMigrationQueueStorageError(database.Name)
			}
		}
		return false, nil
	}
	if len(database.migrationFacilities) != 0 {
		facilities := make([]pgMigrationFacility, 0, len(database.migrationFacilities))
		for facility := range database.migrationFacilities {
			facilities = append(facilities, facility)
		}
		return false, pgMigrationFacilitiesError(database.Name, facilities)
	}
	return true, nil
}

// PreflightApplicationDatabases validates only the compiler's explicit active
// App targets, before Main enters any database scope or executes user startup
// code. This is local capability/codec validation, never persisted queue
// authority or permission to create protected storage. App currently names one
// database; accepting a batch here gives atomic validation without expanding
// that language surface. Legacy databases keep their existing lifecycle.
func PreflightApplicationDatabases(databases ...*Database) error {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	pending, err := pgPrepareApplicationDatabases(databases)
	if err != nil {
		return err
	}
	for _, database := range pending.databases {
		if _, err := pgCheckMigrationFacilities(database); err != nil {
			return err
		}
	}
	pending.closeRegistrations()
	return nil
}

// Pure local preparation and registration closure are distinct from production
// capability admission. Both run inside pgMigrationRegistrations. A complete
// codec projection cannot make legacy queue storage safe for a versioned DB.
type pgApplicationPreflight struct {
	databases []*Database
	codecs    []*pgQueueBackend
}

func pgPrepareApplicationDatabases(databases []*Database) (pgApplicationPreflight, error) {
	var pending pgApplicationPreflight
	seen := map[*Database]bool{}
	for _, database := range databases {
		if database == nil {
			return pgApplicationPreflight{}, fmt.Errorf("application startup: missing database")
		}
		if seen[database] {
			continue
		}
		seen[database] = true
		history, versioned := database.CompiledMigrationHistory()
		if !versioned {
			continue
		}
		if _, err := pgMigrationRoles(database.Config, database.Config.User); err != nil {
			return pgApplicationPreflight{}, fmt.Errorf("database %q: %w", database.Name, err)
		}
		if database.Config.Schema != history.Namespace {
			return pgApplicationPreflight{}, fmt.Errorf("database %q: compiled migration namespace disagrees with its connection", database.Name)
		}
		checked, err := pgCheckApplicationQueueCodecs(database, history)
		if err != nil {
			return pgApplicationPreflight{}, fmt.Errorf("database %q: %w", database.Name, err)
		}
		pending.databases = append(pending.databases, database)
		pending.codecs = append(pending.codecs, checked...)
	}
	return pending, nil
}

func (pending pgApplicationPreflight) closeRegistrations() {
	// Every writer is excluded until all closures have been published. No failed
	// target can leave an earlier database or codec registry partially sealed.
	for _, backend := range pending.codecs {
		backend.codecsMutex.Lock()
		backend.queueCodecsClosed = true
		backend.codecsMutex.Unlock()
	}
	for _, database := range pending.databases {
		database.mutex.Lock()
		database.applicationPreflightClosed = true
		pgMigrationClosedFamilies[database.migrationHistory.Family] = true
		database.migrationFacilitiesClosed = true
		database.mutex.Unlock()
	}
}

// All registration writers are excluded. Snapshot the owners before reading
// codecs, and never retain either the owners or database lock across that read.
func pgCheckApplicationQueueCodecs(database *Database, history PgCompiledMigrationHistory) ([]*pgQueueBackend, error) {
	database.mutex.RLock()
	queueNames := map[string]bool{}
	for facility := range database.migrationFacilities {
		if facility.kind == "queue" {
			queueNames[facility.name] = true
		}
	}
	queues := map[*Queue]bool{}
	for queue := range database.migrationQueues {
		queues[queue] = true
	}
	database.mutex.RUnlock()
	queueSchemaOwners.Lock()
	owners := map[string]*Queue{}
	for identity, queue := range queueSchemaOwners.queues[database] {
		owners[identity] = queue
	}
	queueSchemaOwners.Unlock()
	compiledQueueHistories.RLock()
	_, companion := compiledQueueHistories.families[history.Family]
	compiledQueueHistories.RUnlock()
	if !companion && len(queueNames) == 0 && len(owners) == 0 && len(queues) == 0 {
		// Older entity-only binaries have no queue companion. Absence never
		// permits a queued database or claims a persisted empty baseline.
		return nil, nil
	}
	inventory, err := history.QueueSourceInventory(history.CurrentVersion)
	if err != nil {
		return nil, err
	}
	contracts := inventory.Versions[0].Contracts
	if len(owners) != len(contracts) || len(queueNames) != len(contracts) || len(queues) != len(contracts) {
		return nil, fmt.Errorf("queue schema application bindings are missing or incomplete")
	}
	var result []*pgQueueBackend
	for _, contract := range contracts {
		queue := owners[contract.Queue]
		if queue == nil || !queueNames[queue.name] || !queues[queue] {
			return nil, fmt.Errorf("queue schema application binding is missing")
		}
		if _, err := QueueSourceCodecs(queue); err != nil {
			return nil, err
		}
		backend, ok := queue.backend.(*pgQueueBackend)
		if !ok || backend.database != database {
			return nil, fmt.Errorf("queue schema application binding belongs to another database")
		}
		result = append(result, backend)
	}
	return result, nil
}

// The opened connection retains its actual topology. Check that immutable
// binding at lazy-storage entry points as well, before touching a pool or
// trusting an already-completed bootstrap flag. A later environment change or
// manually constructed backend must not turn Worker requests into DDL writers.
func pgVerifyMigrationFacilityConnection(connection *PostgresDB, facility string) error {
	if connection != nil && connection.migration != nil && facility == jobsTable && connection.migration.roles.Request == "" {
		return pgMigrationQueueStorageError(connection.schema)
	}
	if connection != nil && connection.migration != nil && connection.migration.roles.Request != "" {
		return pgMigrationFacilitiesError(connection.schema, []pgMigrationFacility{{kind: facility}})
	}
	return nil
}
