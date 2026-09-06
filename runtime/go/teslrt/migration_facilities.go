package teslrt

import (
	"fmt"
	"sort"
	"strings"
)

type pgMigrationFacility struct{ kind, name string }

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
// usable by ordinary in-memory tests and schema status. Only a Worker preflight
// refuses the unsupported durable deployment, before it opens any connection.
func pgRegisterMigrationFacility(database *Database, kind, name string) {
	if database == nil {
		return
	}
	facility := pgMigrationFacility{kind, name}
	database.mutex.Lock()
	defer database.mutex.Unlock()
	if database.migrationFacilitiesClosed {
		panic(pgMigrationFacilitiesError(database.Name, []pgMigrationFacility{facility}))
	}
	if database.migrationFacilities == nil {
		database.migrationFacilities = make(map[pgMigrationFacility]struct{})
	}
	database.migrationFacilities[facility] = struct{}{}
}

// This is a local capability restriction, not a persisted footprint or proof
// that old binaries cannot use durable facilities. Worker runtime tables have no
// protected installation protocol yet, so a new Worker instance must declare none.
// Closing registration and inspecting declarations share one lock: a constructor
// racing with preflight either makes preflight refuse or itself refuses before
// creating a backend. Neither side can introduce a facility after validation.
func pgVerifyMigrationFacilities(database *Database) error {
	if database == nil {
		return nil
	}
	database.mutex.Lock()
	defer database.mutex.Unlock()
	if database.migrationHistory == nil {
		return nil
	}
	roles, err := pgMigrationRoles(database.Config, database.Config.User)
	if err != nil {
		return fmt.Errorf("database %q: %w", database.Name, err)
	}
	if roles.Request == "" {
		return nil
	}
	if len(database.migrationFacilities) != 0 {
		facilities := make([]pgMigrationFacility, 0, len(database.migrationFacilities))
		for facility := range database.migrationFacilities {
			facilities = append(facilities, facility)
		}
		return pgMigrationFacilitiesError(database.Name, facilities)
	}
	database.migrationFacilitiesClosed = true
	return nil
}

// The opened connection retains its actual topology. Check that immutable
// binding at lazy-storage entry points as well, before touching a pool or
// trusting an already-completed bootstrap flag. A later environment change or
// manually constructed backend must not turn Worker requests into DDL writers.
func pgVerifyMigrationFacilityConnection(connection *PostgresDB, facility string) error {
	if connection != nil && connection.migration != nil && connection.migration.roles.Request != "" {
		return pgMigrationFacilitiesError(connection.schema, []pgMigrationFacility{{kind: facility}})
	}
	return nil
}
