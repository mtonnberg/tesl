package teslrt

import (
	"context"
	"testing"
)

// A valid-looking protected queue attachment must never authorize the legacy
// lazy DDL path, even if a cached ready flag would otherwise bypass bootstrap.
func TestRowQueueRuntimeDoesNotAuthorizeLegacyFacilities(t *testing.T) {
	database := NewDatabase("row-queue", PostgresConfig{Schema: "row_queue"}, nil)
	connection := &PostgresDB{schema: "row_queue", migration: &pgMigrationAdmission{
		controlFormat: pgRowControlFormat,
		roles:         PgMigrationControlRoles{Owner: "control", Worker: "schema", Request: "app"},
	}, queueRuntime: &pgQueueRuntime{database: database}}
	for _, table := range []string{jobsTable, cacheTable, outboxTable} {
		for _, cached := range []bool{false, true} {
			key := pgTableKey{db: connection, table: table}
			if cached {
				pgTablesReady.Store(key, &pgTableOnce{done: true})
			}
			ran := false
			pgRequireFacilityRefusal(t, pgFacilityPanic(func() { ensureTable(connection, table, func(string) []string { ran = true; return nil }) }), table)
			pgTablesReady.Delete(key)
			if ran {
				t.Fatal("protected queue attachment allowed legacy DDL")
			}
		}
	}
	runtime := &pgPubsub{ready: true}
	pgRequireFacilityRefusal(t, runtime.prepareOn(connection, nil), "SSE")
	pgRequireFacilityRefusal(t, createPubsubOutbox(context.Background(), connection), "SSE")
	pgRequireFacilityRefusal(t, normalizeLegacyPubsubRows(connection), "SSE")
}
