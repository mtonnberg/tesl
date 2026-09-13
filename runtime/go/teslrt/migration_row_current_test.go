package teslrt

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

func currentCodecFixture() (PgRowSourceInventory, map[string]any) {
	e := PgRowSourceEntity{Entity: "Note", Table: "notes", Generation: 2, TypeContractHash: strings.Repeat("a", 64), Columns: []PgRowSchemaColumn{{Field: "id", Name: "id", Type: "text", PrimaryKey: true}, {Field: "memo", Name: "memo_v2", Type: "jsonb", Nullable: true}}}
	v := PgRowSourceVersion{Version: 3, SchemaSnapshotHash: strings.Repeat("b", 64), StorageSnapshotHash: strings.Repeat("c", 64), Entities: []PgRowSourceEntity{e}}
	base := PgRowSourceInventory{CurrentVersion: 3, Versions: []PgRowSourceVersion{{Version: 1}, {Version: 2}, v}, Transforms: []PgRowTransformDescriptor{{MigrationVersion: 2, Entity: "Note", TargetGeneration: 2}}}
	d := map[string]any{"schemaVersion": 3, "entity": "Note", "generation": 2, "schemaSnapshot": v.SchemaSnapshotHash, "storageSnapshot": v.StorageSnapshotHash, "typeContractHash": e.TypeContractHash, "projection": []string{"memo", "id"}}
	return base, d
}
func TestPgRowCurrentDescriptorRequiresExactCurrentIdentity(t *testing.T) {
	base, d := currentCodecFixture()
	check := func(t *testing.T, input any, want bool) {
		t.Helper()
		raw, err := json.Marshal(input)
		if err != nil {
			t.Fatal(err)
		}
		reader := &pgMigrationWireReader{}
		got := pgReadRowCurrentCodecs(reader, raw, base)
		if (reader.err == nil) != want {
			t.Fatalf("accepted=%v expected=%v: %v", reader.err == nil, want, reader.err)
		}
		if want && (len(got) != 1 || got[0].Projection[0] != "memo" || got[0].Generation != 2 || got[0].SchemaVersion != 3) {
			t.Fatal("compiler field order or generation was reinterpreted", got)
		}
	}
	check(t, []any{d}, true)
	for _, item := range []struct {
		name  string
		value any
	}{
		{"schemaVersion", 2}, {"schemaVersion", 4}, {"generation", 3}, {"generation", 1},
		{"entity", "Other"}, {"schemaSnapshot", strings.Repeat("d", 64)}, {"storageSnapshot", strings.Repeat("d", 64)},
		{"typeContractHash", strings.Repeat("d", 64)}, {"projection", []string{"id"}},
		{"projection", []string{"id", "id"}}, {"projection", []string{"id", "other"}},
		{"callback", "synthetic-migration"},
	} {
		t.Run(item.name, func(t *testing.T) {
			copy := map[string]any{}
			for key, value := range d {
				copy[key] = value
			}
			copy[item.name] = item.value
			check(t, []any{copy}, false)
		})
	}
	check(t, []any{}, false)
	check(t, []any{d, d}, false)
	for field := range d {
		t.Run("missing-"+field, func(t *testing.T) {
			copy := map[string]any{}
			for key, value := range d {
				if key != field {
					copy[key] = value
				}
			}
			check(t, []any{copy}, false)
		})
	}
}
func TestPgRowCurrentDescriptorCannotReplaceActiveTransform(t *testing.T) {
	base, d := currentCodecFixture()
	base.Transforms = append(base.Transforms, PgRowTransformDescriptor{MigrationVersion: 3, Entity: "Note", TargetGeneration: 3})
	raw, err := json.Marshal([]any{d})
	if err != nil {
		t.Fatal(err)
	}
	reader := &pgMigrationWireReader{}
	pgReadRowCurrentCodecs(reader, raw, base)
	if reader.err == nil {
		t.Fatal("current codec replaced an active migration window")
	}
}
func TestPgRowCurrentRequiresEveryCurrentEntity(t *testing.T) {
	base, d := currentCodecFixture()
	other := base.Versions[2].Entities[0]
	other.Entity = "Other"
	other.Table = "others"
	base.Versions[2].Entities = append(base.Versions[2].Entities, other)
	raw, err := json.Marshal([]any{d})
	if err != nil {
		t.Fatal(err)
	}
	reader := &pgMigrationWireReader{}
	pgReadRowCurrentCodecs(reader, raw, base)
	if reader.err == nil {
		t.Fatal("a second current entity lost mandatory codec authority")
	}
}
func TestPgRowCurrentZeroReferenceCannotRegister(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("zero current reference registered")
		}
	}()
	RegisterCompiledRowCurrentStorage[struct{}](PgRowCurrentSourceRef{}, PgCompiledRowCodec[struct{}]{})
}
func TestPgRowCurrentAbsentAdmissionDoesNotInvokeCodecs(t *testing.T) {
	storage := &PgRowCurrentStorage[string]{encode: func(string) ([]any, error) { t.Fatal("codec ran without admission"); return nil, nil }}
	if _, err := storage.materialize(nil, "value"); err == nil {
		t.Fatal("write accepted absent admission")
	}
	if _, err := storage.decodePhysical(nil, nil); err == nil {
		t.Fatal("read accepted absent admission")
	}
}

func TestPgRowCurrentCodecOwnerOrderIsIndependent(t *testing.T) {
	type row struct{ Owner, Title string }
	fields := []string{"owner", "title"}
	decode := func(pgx.CollectableRow) (row, error) { t.Fatal("registration invoked decoder"); return row{}, nil }
	encode := func(row) ([]any, error) { t.Fatal("registration invoked encoder"); return nil, nil }
	codec := NewCompiledRowCodec(fields, decode, encode)
	descriptor := PgRowCurrentCodecDescriptor{Projection: []string{"owner", "title"}}
	fields[0] = "mutated"
	if err := pgCheckCurrentCodecOrder(codec, descriptor); err != nil {
		t.Fatal("caller mutated codec-owned order", err)
	}
	for _, fields := range [][]string{{"title", "owner"}, {"owner"}, {"owner", "owner"}, nil} {
		t.Run(strings.Join(fields, ","), func(t *testing.T) {
			mutated := descriptor
			mutated.Projection = fields
			if err := pgCheckCurrentCodecOrder(codec, mutated); err == nil {
				t.Fatal("different positional field mapping accepted", fields)
			}
		})
	}
	for _, invalid := range []PgCompiledRowCodec[row]{
		{}, NewCompiledRowCodec([]string{"owner", "title"}, nil, encode),
		NewCompiledRowCodec([]string{"owner", "title"}, decode, nil),
	} {
		if err := pgCheckCurrentCodecOrder(invalid, descriptor); err == nil {
			t.Fatal("incomplete codec bundle accepted")
		}
	}
}
