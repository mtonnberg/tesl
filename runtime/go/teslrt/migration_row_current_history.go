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

// pgExpectedRowCurrentCodecsAt needs only the current source version and the
// transforms that target it.
func pgExpectedRowCurrentCodecsAt(transforms []PgRowTransformDescriptor, current int, last PgRowSourceVersion) map[string]PgRowSourceEntity {
	expected := map[string]PgRowSourceEntity{}
	transforming := map[string]bool{}
	for _, d := range transforms {
		if d.MigrationVersion == current {
			transforming[d.Entity] = true
		}
	}
	for _, e := range last.Entities {
		if e.Generation > 1 && !transforming[e.Entity] {
			expected[e.Entity] = e
		}
	}
	return expected
}

func pgReadRowCurrentCodecs(r *pgMigrationWireReader, raw json.RawMessage, base PgRowSourceInventory) []PgRowCurrentCodecDescriptor {
	if len(base.Versions) == 0 {
		return pgReadRowCurrentCodecsAt(r, raw, base.Transforms, base.CurrentVersion, PgRowSourceVersion{}, false)
	}
	return pgReadRowCurrentCodecsAt(r, raw, base.Transforms, base.CurrentVersion, base.Versions[len(base.Versions)-1], true)
}

func pgReadRowCurrentCodecsAt(r *pgMigrationWireReader, raw json.RawMessage, transforms []PgRowTransformDescriptor, current int, v PgRowSourceVersion, hasVersions bool) []PgRowCurrentCodecDescriptor {
	expected := map[string]PgRowSourceEntity{}
	if hasVersions {
		expected = pgExpectedRowCurrentCodecsAt(transforms, current, v)
	}
	result := pgMigrationReadArray(r, raw, func(raw json.RawMessage) PgRowCurrentCodecDescriptor {
		o := r.object(raw, "schemaVersion", "entity", "generation", "schemaSnapshot", "storageSnapshot", "typeContractHash", "projection")
		d := PgRowCurrentCodecDescriptor{SchemaVersion: pgMigrationRead[int](r, o["schemaVersion"]), Entity: pgMigrationRead[string](r, o["entity"]), Generation: pgMigrationRead[int](r, o["generation"]), SchemaSnapshot: pgMigrationRead[string](r, o["schemaSnapshot"]), StorageSnapshot: pgMigrationRead[string](r, o["storageSnapshot"]), TypeContractHash: pgMigrationRead[string](r, o["typeContractHash"])}
		e, ok := expected[d.Entity]
		if !ok || d.SchemaVersion != current || d.Generation != e.Generation || d.TypeContractHash != e.TypeContractHash || !hasVersions {
			r.fail("current codec differs from its exact current source entity")
			return d
		}
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
