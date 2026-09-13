package teslrt

import (
	"encoding/json"
)

// Current codecs describe an already current row, independently of any earlier
// nominal transition. Ordered fields are compiler-owned, never an API argument.
type PgRowCurrentCodecDescriptor struct {
	SchemaVersion, Generation                                 int
	Entity, SchemaSnapshot, StorageSnapshot, TypeContractHash string
	Projection                                                []string
}

func pgExpectedRowCurrentCodecs(base PgRowSourceInventory) map[string]PgRowSourceEntity {
	expected := map[string]PgRowSourceEntity{}
	if len(base.Versions) == 0 {
		return expected
	}
	for _, d := range base.Transforms {
		if d.MigrationVersion == base.CurrentVersion {
			return expected
		}
	}
	for _, e := range base.Versions[len(base.Versions)-1].Entities {
		if e.Generation > 1 {
			expected[e.Entity] = e
		}
	}
	return expected
}

func pgReadRowCurrentCodecs(r *pgMigrationWireReader, raw json.RawMessage, base PgRowSourceInventory) []PgRowCurrentCodecDescriptor {
	expected := pgExpectedRowCurrentCodecs(base)
	result := pgMigrationReadArray(r, raw, func(raw json.RawMessage) PgRowCurrentCodecDescriptor {
		o := r.object(raw, "schemaVersion", "entity", "generation", "schemaSnapshot", "storageSnapshot", "typeContractHash", "projection")
		d := PgRowCurrentCodecDescriptor{SchemaVersion: pgMigrationRead[int](r, o["schemaVersion"]), Entity: pgMigrationRead[string](r, o["entity"]), Generation: pgMigrationRead[int](r, o["generation"]), SchemaSnapshot: pgMigrationRead[string](r, o["schemaSnapshot"]), StorageSnapshot: pgMigrationRead[string](r, o["storageSnapshot"]), TypeContractHash: pgMigrationRead[string](r, o["typeContractHash"])}
		e, ok := expected[d.Entity]
		if !ok || d.SchemaVersion != base.CurrentVersion || d.Generation != e.Generation || d.TypeContractHash != e.TypeContractHash || len(base.Versions) == 0 {
			r.fail("current codec differs from its exact current source entity")
			return d
		}
		v := base.Versions[len(base.Versions)-1]
		if d.SchemaSnapshot != v.SchemaSnapshotHash || d.StorageSnapshot != v.StorageSnapshotHash {
			r.fail("current codec differs from its exact schema and storage snapshots")
		}
		d.Projection = pgRowProjectionFields(r, o["projection"], e.Columns)
		delete(expected, d.Entity)
		return d
	})
	last := ""
	for _, d := range result {
		if d.Entity <= last {
			r.fail("current codecs must have distinct ordered entity owners")
		}
		last = d.Entity
	}
	if len(expected) != 0 {
		r.fail("current codec inventory is incomplete")
	}
	return result
}
