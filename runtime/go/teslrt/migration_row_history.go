package teslrt

// Checked source metadata for the internal compiler artifact path. None of
// these descriptions is an observed catalog, a SQL adapter, or DDL authority.
// Version 4 remains deliberately unsupported by ExpansionPlan and public boot.

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"slices"
	"strconv"
	"strings"
)

const pgRowSourceLimit = 64 << 20

type PgRowSchemaColumn struct {
	Field, Name, Type    string
	Nullable, PrimaryKey bool
}

type PgRowSourceEntity struct {
	Entity, Table                  string
	Generation                     int
	TypeContract, TypeContractHash string
	// Nominal Go layout comes from the compiler's actual emitter environment.
	// It is linked metadata outside Tesl semantic hashes, not inferred here from
	// version spelling or a claimed structural equivalence.
	GoTypePackage, GoTypeName string
	Columns                   []PgRowSchemaColumn
}

type PgRowSourceVersion struct {
	Version                              int
	SchemaContract, SchemaSnapshotHash   string
	StorageContract, StorageSnapshotHash string
	Entities                             []PgRowSourceEntity
}

type PgRowFieldMapping struct {
	Target, Kind     string
	Source, Constant *string
}

type PgRowWriteBackMapping struct{ Previous, Current string }

type PgRowTransformDescriptor struct {
	WriteBacks                                                        []PgRowWriteBackMapping
	MigrationVersion                                                  int
	Entity, Table, Mode                                               string
	PreviousGeneration, TargetGeneration                              int
	FromSchemaSnapshot, ToSchemaSnapshot                              string
	FromStorageSnapshot, ToStorageSnapshot                            string
	FromTypeContractHash, ToTypeContractHash                          string
	SourceSchemaColumns, TargetSchemaColumns                          []PgRowSchemaColumn
	SourceProjection, TargetProjection                                []string
	FieldMapping                                                      []PgRowFieldMapping
	TransformContractFormat, TransformContract, TransformContractHash string
}

type PgRowSourceInventory struct {
	Database, Family, Namespace string
	CurrentVersion              int
	Versions                    []PgRowSourceVersion
	Transforms                  []PgRowTransformDescriptor
}

// Canonical atoms are bytes, not necessarily UTF-8 strings. A closed tree parser
// validates lengths and budgets; callers then validate their specific domain.
type pgRowCanonical struct {
	atom     bool
	value    string
	children []pgRowCanonical
}

func pgReadRowCanonical(encoded string) (pgRowCanonical, []byte, error) {
	var empty pgRowCanonical
	if len(encoded) == 0 || len(encoded) > pgRowSourceLimit || len(encoded)%2 != 0 {
		return empty, nil, fmt.Errorf("invalid row canonical size")
	}
	data, err := hex.DecodeString(encoded)
	if err != nil || hex.EncodeToString(data) != encoded {
		return empty, nil, fmt.Errorf("row canonical bytes require lowercase hex")
	}
	offset, nodes := 0, 0
	var read func(int) (pgRowCanonical, error)
	read = func(depth int) (pgRowCanonical, error) {
		nodes++
		if depth > 512 || nodes > 1_000_000 || offset >= len(data) {
			return empty, fmt.Errorf("row canonical tree exceeds its budget or is truncated")
		}
		tag := data[offset]
		offset++
		if tag != 's' && tag != 'l' {
			return empty, fmt.Errorf("invalid row canonical node")
		}
		start, count := offset, 0
		for offset < len(data) && data[offset] >= '0' && data[offset] <= '9' {
			if count > len(data)/10 {
				return empty, fmt.Errorf("oversized row canonical length")
			}
			count = count*10 + int(data[offset]-'0')
			offset++
		}
		if offset == start || offset >= len(data) || data[offset] != ':' || offset-start > 1 && data[start] == '0' || count > len(data) {
			return empty, fmt.Errorf("invalid row canonical length")
		}
		offset++
		if tag == 's' {
			if count > len(data)-offset {
				return empty, fmt.Errorf("truncated row canonical atom")
			}
			value := string(data[offset : offset+count])
			offset += count
			return pgRowCanonical{atom: true, value: value}, nil
		}
		if count > 1_000_000-nodes || count > (len(data)-offset)/3 {
			return empty, fmt.Errorf("oversized row canonical list")
		}
		children := make([]pgRowCanonical, 0, count)
		for range count {
			child, err := read(depth + 1)
			if err != nil {
				return empty, err
			}
			children = append(children, child)
		}
		return pgRowCanonical{children: children}, nil
	}
	root, err := read(0)
	if err != nil {
		return empty, nil, err
	}
	if offset != len(data) {
		return empty, nil, fmt.Errorf("trailing row canonical bytes")
	}
	return root, data, nil
}

func (n pgRowCanonical) isAtom(value string) bool { return n.atom && n.value == value }
func (n pgRowCanonical) list(size int) bool       { return !n.atom && len(n.children) == size }
func pgRowCanonicalEqual(a, b pgRowCanonical) bool {
	return a.atom == b.atom && a.value == b.value && slices.EqualFunc(a.children, b.children, pgRowCanonicalEqual)
}

func pgRowDocument(r *pgMigrationWireReader, encoded, digest, domain string) pgRowCanonical {
	node, raw, err := pgReadRowCanonical(encoded)
	if err != nil {
		r.fail(err.Error())
		return pgRowCanonical{}
	}
	if !pgMigrationDigest(digest) || fmt.Sprintf("%x", sha256.Sum256(raw)) != digest || !node.list(4) ||
		!node.children[0].isAtom("tesl-migration-canonical") || !node.children[1].isAtom("1") || !node.children[2].isAtom(domain) {
		r.fail("row canonical document identity or domain mismatch")
		return pgRowCanonical{}
	}
	return node.children[3]
}

func pgRowColumn(r *pgMigrationWireReader, raw json.RawMessage) PgRowSchemaColumn {
	o := r.object(raw, "field", "name", "type", "nullable", "primaryKey")
	c := PgRowSchemaColumn{Field: pgMigrationRead[string](r, o["field"]), Name: pgMigrationRead[string](r, o["name"]), Type: pgMigrationRead[string](r, o["type"]), Nullable: pgMigrationRead[bool](r, o["nullable"]), PrimaryKey: pgMigrationRead[bool](r, o["primaryKey"])}
	if !pgRowName(c.Field) || !pgRowColumnName(c.Field, c.Name) || !pgMigrationIdentifier(c.Name) || c.Name == "_tesl_v" || !slices.Contains([]string{"numeric", "float8", "text", "bool", "int4", "int8", "jsonb"}, c.Type) || c.PrimaryKey && c.Nullable {
		r.fail("invalid row schema column")
	}
	return c
}

// Snapshot validation binds the exact annotation below; this lexical check
// prevents a foreign logical field from claiming another field's physical name.
func pgRowColumnName(field, name string) bool {
	base := pgRowSQLColumnName(field)
	if name == base {
		return true
	}
	suffix, ok := strings.CutPrefix(name, base+"__v")
	if !ok {
		return false
	}
	version, err := strconv.Atoi(suffix)
	return err == nil && version >= 2 && version <= 2147483646 && strconv.Itoa(version) == suffix
}

func pgRowName(name string) bool {
	if name == "" {
		return false
	}
	for i, c := range name {
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' || i > 0 && c >= '0' && c <= '9' {
			continue
		}
		return false
	}
	return true
}

func pgRowColumns(r *pgMigrationWireReader, raw json.RawMessage) []PgRowSchemaColumn {
	columns := pgMigrationReadArray(r, raw, func(raw json.RawMessage) PgRowSchemaColumn { return pgRowColumn(r, raw) })
	last, keys := "", 0
	fields := map[string]bool{}
	for _, c := range columns {
		if c.Name <= last || fields[c.Field] {
			r.fail("row columns must have distinct fields and sorted physical names")
		}
		last, fields[c.Field] = c.Name, true
		if c.PrimaryKey {
			keys++
		}
	}
	if len(columns) == 0 || len(columns) > 1599 || keys != 1 {
		r.fail("row entity requires one primary key and bounded complete columns")
	}
	return columns
}

func pgRowEntity(r *pgMigrationWireReader, raw json.RawMessage) PgRowSourceEntity {
	o := r.object(raw, "entity", "table", "generation", "typeContract", "typeContractHash", "goTypePackage", "goTypeName", "columns")
	e := PgRowSourceEntity{Entity: pgMigrationRead[string](r, o["entity"]), Table: pgMigrationRead[string](r, o["table"]), Generation: pgMigrationRead[int](r, o["generation"]), TypeContract: pgMigrationRead[string](r, o["typeContract"]), TypeContractHash: pgMigrationRead[string](r, o["typeContractHash"]), GoTypePackage: pgMigrationRead[string](r, o["goTypePackage"]), GoTypeName: pgMigrationRead[string](r, o["goTypeName"]), Columns: pgRowColumns(r, o["columns"])}
	if !pgQueueIdentity(e.Entity) || !pgMigrationIdentifier(e.Table) || e.Generation < 1 || e.Generation > 32767 ||
		!strings.HasPrefix(e.GoTypePackage, "tesl.generated/") || strings.ContainsAny(e.GoTypePackage, "\x00\\ \t\r\n") || !pgRowName(e.GoTypeName) {
		r.fail("invalid row source entity identity, generation or generated nominal type")
	}
	pgRowDocument(r, e.TypeContract, e.TypeContractHash, "contract")
	return e
}

func pgRowBool(node pgRowCanonical, value bool) bool {
	return node.list(2) && node.children[0].isAtom("bool") && node.children[1].isAtom(strconv.FormatBool(value))
}

// Compare the declared per-schema column inventory with its exact canonical
// storage description. This neither observes nor predicts a retained catalog.
func pgRowCheckStorage(r *pgMigrationWireReader, schema, storage pgRowCanonical, entities []PgRowSourceEntity) {
	if !storage.list(3) || !storage.children[0].isAtom("postgres-storage-v1") || !pgRowCanonicalEqual(schema, storage.children[1]) || storage.children[2].atom {
		r.fail("row storage document does not embed its exact schema snapshot")
		return
	}
	tables := storage.children[2].children
	if len(tables) != len(entities) {
		r.fail("row entity inventory is incomplete for its storage tables")
		return
	}
	byTable := map[string]PgRowSourceEntity{}
	for _, e := range entities {
		byTable[e.Table] = e
	}
	last := ""
	names := map[string]bool{}
	for _, table := range tables {
		if !table.list(3) || !table.children[0].atom || table.children[1].atom || table.children[2].atom {
			r.fail("invalid canonical row table")
			return
		}
		name := table.children[0].value
		e, ok := byTable[name]
		if !ok || name <= last || names[name] {
			r.fail("row table inventory/order differs from storage")
			return
		}
		last, names[name] = name, true
		if len(table.children[1].children) != len(e.Columns) {
			r.fail("row column inventory differs from storage")
			return
		}
		columns := map[string]bool{}
		for i, c := range e.Columns {
			n := table.children[1].children[i]
			if !n.list(4) || !n.children[0].isAtom(c.Name) || !n.children[1].isAtom(c.Type) || !pgRowBool(n.children[2], c.Nullable) || !pgRowBool(n.children[3], c.PrimaryKey) {
				r.fail("row column differs from canonical storage")
				return
			}
			columns[c.Name] = true
		}
		lastIndex := ""
		for _, index := range table.children[2].children {
			if !index.list(3) || !index.children[0].atom || !pgMigrationIdentifier(index.children[0].value) || index.children[1].atom ||
				!pgRowBool(index.children[2], true) && !pgRowBool(index.children[2], false) {
				r.fail("invalid canonical row index")
				return
			}
			name := index.children[0].value
			if name <= lastIndex || names[name] {
				r.fail("duplicate or unsorted row storage relation")
				return
			}
			lastIndex, names[name] = name, true
			used := map[string]bool{}
			for _, key := range index.children[1].children {
				if !key.atom || !columns[key.value] || used[key.value] {
					r.fail("row index keys differ from storage")
					return
				}
				used[key.value] = true
			}
			if len(used) == 0 {
				r.fail("row index has no keys")
				return
			}
		}
	}
}

func pgReadRowBase(history PgCompiledMigrationHistory) ([]PgRowSourceInventory, error) {
	if len(history.HistoryJSON) > pgRowSourceLimit {
		return nil, fmt.Errorf("row source history exceeds size budget")
	}
	if err := pgMigrationCheckJSON(history.HistoryJSON); err != nil {
		return nil, err
	}
	r := &pgMigrationWireReader{}
	root := r.object(json.RawMessage(history.HistoryJSON), "version", "kind", "compilerAbi", "storedValueCompatibility", "databases")
	if pgMigrationRead[int](r, root["version"]) != 4 || pgMigrationRead[string](r, root["kind"]) != "compiled-migration-source-history" ||
		pgMigrationRead[string](r, root["compilerAbi"]) != history.SourceCompilerABI || pgMigrationRead[string](r, root["storedValueCompatibility"]) != history.StoredValueCompatibility ||
		!strings.HasPrefix(history.SourceCompilerABI, "tesl-source-abi-v1:") || !pgMigrationDigest(strings.TrimPrefix(history.SourceCompilerABI, "tesl-source-abi-v1:")) || !pgStoredValueCompatibility(history.StoredValueCompatibility) {
		r.fail("row source envelope differs from linked compiler metadata")
	}
	last := ""
	families := map[string]bool{}
	result := pgMigrationReadArray(r, root["databases"], func(raw json.RawMessage) PgRowSourceInventory {
		o := r.object(raw, "database", "family", "namespace", "currentVersion", "versions", "origins")
		d := PgRowSourceInventory{Database: pgMigrationRead[string](r, o["database"]), Family: pgMigrationRead[string](r, o["family"]), Namespace: pgMigrationRead[string](r, o["namespace"]), CurrentVersion: pgMigrationRead[int](r, o["currentVersion"])}
		if d.Database <= last || !pgMigrationFamily(d.Family) || families[d.Family] || !pgMigrationIdentifier(d.Namespace) || d.CurrentVersion < 1 || d.CurrentVersion > 2147483646 {
			r.fail("invalid or duplicate row source database")
		}
		last, families[d.Family] = d.Database, true
		d.Versions = pgMigrationReadArray(r, o["versions"], func(raw json.RawMessage) PgRowSourceVersion {
			v := r.object(raw, "version", "schemaContract", "schemaSnapshotHash", "storageContract", "storageSnapshotHash", "entities")
			version := PgRowSourceVersion{Version: pgMigrationRead[int](r, v["version"]), SchemaContract: pgMigrationRead[string](r, v["schemaContract"]), SchemaSnapshotHash: pgMigrationRead[string](r, v["schemaSnapshotHash"]), StorageContract: pgMigrationRead[string](r, v["storageContract"]), StorageSnapshotHash: pgMigrationRead[string](r, v["storageSnapshotHash"])}
			schema := pgRowDocument(r, version.SchemaContract, version.SchemaSnapshotHash, "snapshot")
			storage := pgRowDocument(r, version.StorageContract, version.StorageSnapshotHash, "migration")
			version.Entities = pgMigrationReadArray(r, v["entities"], func(raw json.RawMessage) PgRowSourceEntity { return pgRowEntity(r, raw) })
			lastEntity := ""
			seen := map[string]bool{}
			for _, entity := range version.Entities {
				if entity.Entity <= lastEntity || seen[entity.Table] {
					r.fail("row entities require unique sorted owners and tables")
				}
				lastEntity, seen[entity.Table] = entity.Entity, true
			}
			pgRowCheckStorage(r, schema, storage, version.Entities)
			pgRowCheckTypeInventory(r, schema, d.Family, history.SourceCompilerABI, history.StoredValueCompatibility, version.Entities)
			return version
		})
		if len(d.Versions) != d.CurrentVersion {
			r.fail("row source versions must be complete")
		}
		previous := map[string]PgRowSourceEntity{}
		tables := map[string]string{}
		for i, v := range d.Versions {
			if v.Version != i+1 {
				r.fail("row versions must be consecutive")
			}
			next := map[string]PgRowSourceEntity{}
			for _, entity := range v.Entities {
				old, exists := previous[entity.Entity]
				if !exists && entity.Generation != 1 || exists && (old.Table != entity.Table || entity.Generation < old.Generation || entity.Generation > old.Generation+1) {
					r.fail("row entity generation/table history is inconsistent")
				}
				if owner, exists := tables[entity.Table]; exists && owner != entity.Entity {
					r.fail("row physical table cannot change owners")
				}
				tables[entity.Table], next[entity.Entity] = entity.Entity, entity
			}
			for name := range previous {
				if _, exists := next[name]; !exists {
					r.fail("row source lifecycle does not yet support dropping entities")
				}
			}
			previous = next
		}
		origins := pgMigrationRead[[]json.RawMessage](r, o["origins"])
		if len(origins) != d.CurrentVersion {
			r.fail("row source history omits installation origins")
		}
		for i, raw := range origins {
			origin := r.object(raw, "initialVersion", "steps", "errors")
			if pgMigrationRead[int](r, origin["initialVersion"]) != i+1 {
				r.fail("row source origins are not consecutive")
			}
			errors := pgMigrationRead[[]json.RawMessage](r, origin["errors"])
			if len(errors) > 0 {
				if !bytes.Equal(bytes.TrimSpace(origin["steps"]), []byte("null")) {
					r.fail("refused source origin must not have steps")
				}
				for _, raw := range errors {
					e := r.object(raw, "code", "message")
					if pgMigrationRead[string](r, e["code"]) == "" || pgMigrationRead[string](r, e["message"]) == "" {
						r.fail("empty source execution refusal")
					}
				}
			} else {
				_, steps, _ := r.origin(raw, i+1, d.CurrentVersion)
				if r.err == nil {
					if err := pgReplayMigrationSteps(steps, map[int]string{}); err != nil {
						r.fail(err.Error())
					}
					for _, step := range steps {
						if step.Version < 1 || step.Version > len(d.Versions) || step.SnapshotHash != d.Versions[step.Version-1].StorageSnapshotHash {
							r.fail("source origin snapshot mismatch")
						}
					}
				}
			}
		}
		return d
	})
	if len(result) == 0 {
		r.fail("row source history requires a database")
	}
	found := false
	for _, d := range result {
		if d.Database == history.Database {
			found = true
			if d.Family != history.Family || d.Namespace != history.Namespace || d.CurrentVersion != history.CurrentVersion {
				r.fail("row source history belongs to another linked database")
			}
		}
	}
	if !found {
		r.fail("row source history is missing its linked database")
	}
	return result, r.err
}

func pgRowFindEntity(version PgRowSourceVersion, name string) (PgRowSourceEntity, bool) {
	for _, entity := range version.Entities {
		if entity.Entity == name {
			return entity, true
		}
	}
	return PgRowSourceEntity{}, false
}

func pgRowMapping(r *pgMigrationWireReader, raw json.RawMessage) PgRowFieldMapping {
	o := r.object(raw, "target", "kind", "source", "constant")
	m := PgRowFieldMapping{Target: pgMigrationRead[string](r, o["target"]), Kind: pgMigrationRead[string](r, o["kind"]), Source: pgRowNullableString(r, o["source"]), Constant: pgRowNullableString(r, o["constant"])}
	if !pgRowName(m.Target) {
		r.fail("invalid row mapping target")
	}
	switch m.Kind {
	case "copy", "rename", "retype":
		if m.Source == nil || !pgRowName(*m.Source) || m.Constant != nil || m.Kind == "copy" && *m.Source != m.Target || m.Kind == "rename" && *m.Source == m.Target {
			r.fail("invalid row source mapping")
		}
	case "empty-optional", "computed":
		if m.Source != nil || m.Constant != nil {
			r.fail("unexpected row mapping operand")
		}
	case "default":
		if m.Source != nil || m.Constant == nil {
			r.fail("missing row default literal")
		} else {
			n, _, err := pgReadRowCanonical(*m.Constant)
			if err != nil || !n.list(2) || !n.children[0].atom || !n.children[1].atom || !slices.Contains([]string{"int", "float64", "string", "bool"}, n.children[0].value) {
				r.fail("invalid canonical row default literal")
			}
		}
	default:
		r.fail("unsupported row mapping kind")
	}
	return m
}

func pgRowDescriptor(r *pgMigrationWireReader, raw json.RawMessage, base PgRowSourceInventory, abi string, version int) PgRowTransformDescriptor {
	fields := []string{"migrationVersion", "entity", "table", "mode", "previousGeneration", "targetGeneration", "fromSchemaSnapshot", "toSchemaSnapshot", "fromStorageSnapshot", "toStorageSnapshot", "fromTypeContractHash", "toTypeContractHash", "sourceSchemaColumns", "targetSchemaColumns", "fieldMapping", "transformContractFormat", "transformContract", "transformContractHash"}
	if version >= 2 {
		fields = append(fields, "sourceProjection", "targetProjection")
	}
	if version == 3 {
		fields = append(fields, "writeBacks")
	}
	o := r.object(raw, fields...)
	d := PgRowTransformDescriptor{MigrationVersion: pgMigrationRead[int](r, o["migrationVersion"]), Entity: pgMigrationRead[string](r, o["entity"]), Table: pgMigrationRead[string](r, o["table"]), Mode: pgMigrationRead[string](r, o["mode"]), PreviousGeneration: pgMigrationRead[int](r, o["previousGeneration"]), TargetGeneration: pgMigrationRead[int](r, o["targetGeneration"]), FromSchemaSnapshot: pgMigrationRead[string](r, o["fromSchemaSnapshot"]), ToSchemaSnapshot: pgMigrationRead[string](r, o["toSchemaSnapshot"]), FromStorageSnapshot: pgMigrationRead[string](r, o["fromStorageSnapshot"]), ToStorageSnapshot: pgMigrationRead[string](r, o["toStorageSnapshot"]), FromTypeContractHash: pgMigrationRead[string](r, o["fromTypeContractHash"]), ToTypeContractHash: pgMigrationRead[string](r, o["toTypeContractHash"]), SourceSchemaColumns: pgRowColumns(r, o["sourceSchemaColumns"]), TargetSchemaColumns: pgRowColumns(r, o["targetSchemaColumns"]), FieldMapping: pgMigrationReadArray(r, o["fieldMapping"], func(raw json.RawMessage) PgRowFieldMapping { return pgRowMapping(r, raw) }), TransformContractFormat: pgMigrationRead[string](r, o["transformContractFormat"]), TransformContract: pgMigrationRead[string](r, o["transformContract"]), TransformContractHash: pgMigrationRead[string](r, o["transformContractHash"])}
	if version >= 2 {
		d.SourceProjection = pgRowProjectionFields(r, o["sourceProjection"], d.SourceSchemaColumns)
		d.TargetProjection = pgRowProjectionFields(r, o["targetProjection"], d.TargetSchemaColumns)
	}
	if version == 3 {
		d.WriteBacks = pgMigrationReadArray(r, o["writeBacks"], func(raw json.RawMessage) PgRowWriteBackMapping {
			item := r.object(raw, "previous", "current")
			return PgRowWriteBackMapping{Previous: pgMigrationRead[string](r, item["previous"]), Current: pgMigrationRead[string](r, item["current"])}
		})
	}
	link := pgRowDocument(r, d.TransformContract, d.TransformContractHash, "migration")
	if !link.list(5) || !link.children[0].isAtom("checked-transform-link") || !link.children[1].isAtom("1") || !link.children[2].list(2) || !link.children[2].children[0].isAtom("compiler-abi") || !link.children[2].children[1].isAtom(abi) || link.children[3].atom || len(link.children[3].children) == 0 || link.children[4].atom {
		r.fail("row transform semantic link or ABI mismatch")
	}
	if d.Mode != "migrate" || d.TransformContractFormat != "tesl-row-transform-v1" || d.MigrationVersion < 2 || d.MigrationVersion > len(base.Versions) {
		r.fail("unsupported row transform or source version")
		return d
	}
	from, to := base.Versions[d.MigrationVersion-2], base.Versions[d.MigrationVersion-1]
	a, foundA := pgRowFindEntity(from, d.Entity)
	b, foundB := pgRowFindEntity(to, d.Entity)
	if !foundA || !foundB || d.Table != a.Table || d.Table != b.Table || d.PreviousGeneration != a.Generation || d.TargetGeneration != b.Generation || d.TargetGeneration != d.PreviousGeneration+1 || d.FromSchemaSnapshot != from.SchemaSnapshotHash || d.ToSchemaSnapshot != to.SchemaSnapshotHash || d.FromStorageSnapshot != from.StorageSnapshotHash || d.ToStorageSnapshot != to.StorageSnapshotHash || d.FromTypeContractHash != a.TypeContractHash || d.ToTypeContractHash != b.TypeContractHash || !slices.Equal(d.SourceSchemaColumns, a.Columns) || !slices.Equal(d.TargetSchemaColumns, b.Columns) {
		r.fail("row transform does not match its exact adjacent source inventories")
	}
	before, after := map[string]PgRowSchemaColumn{}, map[string]PgRowSchemaColumn{}
	for _, c := range a.Columns {
		before[c.Field] = c
	}
	for _, c := range b.Columns {
		after[c.Field] = c
	}
	if len(d.FieldMapping) != len(after) {
		r.fail("row field mapping is incomplete")
	}
	last := ""
	for _, m := range d.FieldMapping {
		c, exists := after[m.Target]
		if !exists || m.Target <= last {
			r.fail("row field mapping requires sorted distinct target fields")
		}
		last = m.Target
		if m.Kind == "retype" && version != 3 {
			r.fail("Retype requires a v3 checked WriteBack companion")
		}
		if m.Source != nil {
			old, exists := before[*m.Source]
			if !exists || m.Kind != "retype" && (old.Type != c.Type || old.Nullable != c.Nullable) {
				r.fail("row copied field disagrees with source representation")
			}
		}
		if m.Kind == "empty-optional" && !c.Nullable {
			r.fail("empty optional row target is not nullable")
		}
	}
	if version == 3 {
		pgRowCheckWriteBacks(r, d, before, after)
	}
	pgRowCheckLinkMapping(r, link, base.Family, d, a, b)
	return d
}

func pgReadRowCompanion(history PgCompiledMigrationHistory, payload string) ([]PgRowSourceInventory, error) {
	base, err := pgReadRowBase(history)
	if err != nil {
		return nil, err
	}
	if len(payload) == 0 || len(payload) > pgRowSourceLimit {
		return nil, fmt.Errorf("row companion exceeds its size budget")
	}
	if err := pgMigrationCheckJSON(payload); err != nil {
		return nil, err
	}
	r := &pgMigrationWireReader{}
	o := r.object(json.RawMessage(payload), "version", "kind", "compilerAbi", "storedValueCompatibility", "databases")
	version := pgMigrationRead[int](r, o["version"])
	if (version != 1 && version != 2 && version != 3) || pgMigrationRead[string](r, o["kind"]) != "compiled-row-transform-history" || pgMigrationRead[string](r, o["compilerAbi"]) != history.SourceCompilerABI || pgMigrationRead[string](r, o["storedValueCompatibility"]) != history.StoredValueCompatibility {
		r.fail("row companion format or linked ABI mismatch")
	}
	dbs := pgMigrationRead[[]json.RawMessage](r, o["databases"])
	if len(dbs) != len(base) {
		r.fail("row companion database inventory is incomplete")
	}
	for i, raw := range dbs {
		d := r.object(raw, "database", "family", "namespace", "currentVersion", "transforms")
		if i >= len(base) {
			break
		}
		b := &base[i]
		if pgMigrationRead[string](r, d["database"]) != b.Database || pgMigrationRead[string](r, d["family"]) != b.Family || pgMigrationRead[string](r, d["namespace"]) != b.Namespace || pgMigrationRead[int](r, d["currentVersion"]) != b.CurrentVersion {
			r.fail("row companion database identity mismatch")
		}
		b.Transforms = pgMigrationReadArray(r, d["transforms"], func(raw json.RawMessage) PgRowTransformDescriptor {
			return pgRowDescriptor(r, raw, *b, history.SourceCompilerABI, version)
		})
		expected := map[string]bool{}
		for v := 1; v < len(b.Versions); v++ {
			for _, e := range b.Versions[v].Entities {
				old, exists := pgRowFindEntity(b.Versions[v-1], e.Entity)
				if exists && e.Generation == old.Generation+1 {
					expected[fmt.Sprintf("%d/%s", v+1, e.Entity)] = true
				}
			}
		}
		lastVersion, lastEntity := 0, ""
		for _, transform := range b.Transforms {
			key := fmt.Sprintf("%d/%s", transform.MigrationVersion, transform.Entity)
			if !expected[key] || transform.MigrationVersion < lastVersion || transform.MigrationVersion == lastVersion && transform.Entity <= lastEntity {
				r.fail("unexpected, duplicated or unordered row transform")
			}
			delete(expected, key)
			lastVersion, lastEntity = transform.MigrationVersion, transform.Entity
		}
		pgRowCheckColumnOrigins(r, *b, version)
		if len(expected) != 0 {
			r.fail("row companion omits a generation transition")
		}
	}
	if r.err != nil {
		return nil, r.err
	}
	return base, nil
}

func pgRowEncode(node pgRowCanonical) string {
	if node.atom {
		return "s" + strconv.Itoa(len(node.value)) + ":" + node.value
	}
	var out strings.Builder
	out.WriteString("l" + strconv.Itoa(len(node.children)) + ":")
	for _, child := range node.children {
		out.WriteString(pgRowEncode(child))
	}
	return out.String()
}
func pgRowAtom(value string) pgRowCanonical               { return pgRowCanonical{atom: true, value: value} }
func pgRowList(children ...pgRowCanonical) pgRowCanonical { return pgRowCanonical{children: children} }
func pgRowTypeReference(family, entity string) pgRowCanonical {
	parts := []pgRowCanonical{}
	for _, part := range strings.Split(entity, ".") {
		parts = append(parts, pgRowAtom(part))
	}
	return pgRowList(pgRowAtom("reference"), pgRowAtom("type"), pgRowList(pgRowAtom("schema"), pgRowAtom(family), pgRowAtom("snapshot"), pgRowList(parts...)))
}
func pgRowClosure(r *pgMigrationWireReader, node pgRowCanonical, abi, compatibility string) (pgRowCanonical, map[string]pgRowCanonical) {
	if !node.list(3) {
		r.fail("row semantic closure compatibility mismatch")
		return pgRowCanonical{}, nil
	}
	storedSemantics := node.children[0].isAtom("stored-value-semantics") && node.children[1].isAtom(compatibility)
	compilerSemantics := node.children[0].isAtom("compiler-semantics") && node.children[1].isAtom(abi)
	if !storedSemantics && !compilerSemantics {
		r.fail("row semantic closure compatibility mismatch")
		return pgRowCanonical{}, nil
	}
	closure := node.children[2]
	if !closure.list(3) || !closure.children[0].isAtom("closure") || closure.children[1].atom || closure.children[2].atom {
		r.fail("invalid row semantic closure")
		return pgRowCanonical{}, nil
	}
	defs := map[string]pgRowCanonical{}
	last := ""
	for _, definition := range closure.children[2].children {
		encoded := pgRowEncode(definition)
		if !definition.list(2) || encoded <= last {
			r.fail("unordered row semantic definitions")
			continue
		}
		last = encoded
		key := pgRowEncode(definition.children[0])
		if _, exists := defs[key]; exists {
			r.fail("duplicate row semantic definition")
		}
		defs[key] = definition.children[1]
	}
	last = ""
	for _, root := range closure.children[1].children {
		key := pgRowEncode(root)
		if key <= last {
			r.fail("unordered row semantic roots")
		}
		last = key
		if _, exists := defs[key]; !exists {
			r.fail("row semantic root is missing its definition")
		}
	}
	return closure.children[1], defs
}

// Bind source type closures to their declared root, and every reached definition
// to the exact complete schema snapshot. This checks identity and containment;
// Tesl's compiler remains responsible for semantic reachability and proofs.
func pgRowCheckTypeInventory(r *pgMigrationWireReader, schema pgRowCanonical, family, abi, compatibility string, entities []PgRowSourceEntity) {
	roots, definitions := pgRowClosure(r, schema, abi, compatibility)
	if len(roots.children) != len(definitions) {
		r.fail("row schema snapshot must root every owned declaration")
	}
	expectedEntities := map[string]pgRowCanonical{}
	for key, body := range definitions {
		if !body.atom && len(body.children) > 0 && body.children[0].isAtom("entity") {
			expectedEntities[key] = body
		}
	}
	if len(expectedEntities) != len(entities) {
		r.fail("row source entity inventory is incomplete for its schema")
	}
	for _, entity := range entities {
		reference := pgRowTypeReference(family, entity.Entity)
		key := pgRowEncode(reference)
		body, exists := expectedEntities[key]
		if !exists || !body.list(6) || !pgRowCanonicalEqual(body.children[1], reference) || !body.children[2].isAtom(entity.Table) || !body.children[3].atom || body.children[4].atom || body.children[5].atom {
			r.fail("row entity identity or table disagrees with its schema")
			continue
		}
		fields := map[string]bool{}
		physical := map[string]string{}
		for _, field := range body.children[4].children {
			if !field.list(5) || !field.children[0].isAtom("field") || !field.children[1].atom || fields[field.children[1].value] {
				r.fail("invalid row entity schema field")
				continue
			}
			name := field.children[1].value
			storage := field.children[4]
			column := pgRowSQLColumnName(name)
			if storage.list(3) && storage.children[0].isAtom("column-storage") && storage.children[2].atom {
				column = storage.children[2].value
				storage = storage.children[1]
			}
			validStorage := storage.list(1) && storage.children[0].isAtom("none") || storage.list(2) && storage.children[0].isAtom("some") && storage.children[1].atom
			if !validStorage {
				r.fail("invalid canonical field storage annotation")
			}
			physical[name] = column
			fields[field.children[1].value] = true
		}
		if len(fields) != len(entity.Columns) {
			r.fail("row schema columns omit an entity field")
		}
		for _, column := range entity.Columns {
			if !fields[column.Field] || column.Name != physical[column.Field] || column.PrimaryKey != (column.Field == body.children[3].value) {
				r.fail("row schema column does not match entity field/primary key")
			}
		}
		payload := pgRowDocument(r, entity.TypeContract, entity.TypeContractHash, "contract")
		typeRoots, typeDefinitions := pgRowClosure(r, payload, abi, compatibility)
		if !typeRoots.list(1) || !pgRowCanonicalEqual(typeRoots.children[0], reference) {
			r.fail("row type contract belongs to another entity or family")
		}
		for key, definition := range typeDefinitions {
			original, exists := definitions[key]
			if !exists || !pgRowCanonicalEqual(original, definition) {
				r.fail("row type contract differs from its exact source schema")
			}
		}
	}
}

func pgRowCheckLinkMapping(r *pgMigrationWireReader, link pgRowCanonical, family string, descriptor PgRowTransformDescriptor, before, after PgRowSourceEntity) {
	if !link.list(5) || link.children[3].atom {
		return
	}
	from, to := pgRowTypeReference(family, descriptor.Entity), pgRowTypeReference(family, descriptor.Entity)
	from.children[2].children[2] = pgRowAtom("from")
	to.children[2].children[2] = pgRowAtom("to")
	mappings := []string{}
	for _, m := range descriptor.FieldMapping {
		fields := []pgRowCanonical{pgRowAtom(m.Kind)}
		if m.Source != nil {
			fields = append(fields, pgRowAtom(*m.Source))
		}
		fields = append(fields, pgRowAtom(m.Target))
		if m.Constant != nil {
			literal, _, err := pgReadRowCanonical(*m.Constant)
			if err != nil {
				r.fail(err.Error())
				continue
			}
			fields = append(fields, literal)
		}
		mappings = append(mappings, pgRowEncode(pgRowList(fields...)))
	}
	slices.Sort(mappings)
	matches := 0
	for _, row := range link.children[3].children {
		if !row.list(8) || !row.children[0].isAtom("entity-transform") {
			r.fail("invalid checked row transform semantic entry")
			continue
		}
		if !pgRowCanonicalEqual(row.children[1], from) || !pgRowCanonicalEqual(row.children[2], to) {
			continue
		}
		matches++
		pgRowCheckLinkedTypes(r, row.children[3], family, before, after)
		validMode := row.children[6].list(2) && len(descriptor.WriteBacks) == 0 || row.children[6].list(3) && len(descriptor.WriteBacks) > 0
		if row.children[4].atom || !validMode || !row.children[6].children[0].isAtom("migrate") {
			r.fail("row callback semantic mode mismatch")
			continue
		}
		if len(descriptor.WriteBacks) > 0 {
			writes := row.children[6].children[2]
			if writes.atom || len(writes.children) != len(descriptor.WriteBacks) {
				r.fail("WriteBack semantic closure inventory mismatch")
			} else {
				remaining := make(map[string]string, len(descriptor.WriteBacks))
				for _, mapping := range descriptor.WriteBacks {
					remaining[mapping.Previous] = mapping.Current
				}
				for _, w := range writes.children {
					if !w.list(4) || !w.children[0].isAtom("write-back") || !w.children[1].atom {
						r.fail("WriteBack endpoints disagree with checked semantic closures")
						continue
					}
					expected, present := remaining[w.children[1].value]
					if !present || !w.children[2].isAtom(expected) {
						r.fail("WriteBack semantic closure endpoints are not a bijection")
						continue
					}
					delete(remaining, w.children[1].value)
					roots, _ := pgRowClosure(r, pgRowList(pgRowAtom("compiler-semantics"), link.children[2].children[1], w.children[3]), link.children[2].children[1].value, "")
					if !roots.list(1) {
						r.fail("WriteBack requires one checked function closure root")
					}
				}
				if len(remaining) != 0 {
					r.fail("WriteBack semantic closure endpoints are not a bijection")
				}
			}
		}
		actual := []string{}
		for _, m := range row.children[4].children {
			actual = append(actual, pgRowEncode(m))
		}
		if !slices.Equal(actual, mappings) {
			r.fail("row field mapping differs from its checked semantic link")
		}
	}
	if matches != 1 {
		r.fail("checked semantic link does not uniquely own this row entity")
	}
}

func pgRowNullableString(r *pgMigrationWireReader, raw json.RawMessage) *string {
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return nil
	}
	value := pgMigrationRead[string](r, raw)
	return &value
}

// Exact ASCII naming projection used by Validation_common.sql_column_name.
// This binds logical fields to physical columns even when two fields have the
// same carrier and could otherwise be swapped without changing storage hashes.
func pgRowSQLColumnName(name string) string {
	var out strings.Builder
	upper := func(c byte) bool { return c >= 'A' && c <= 'Z' }
	lower := func(c byte) bool { return c >= 'a' && c <= 'z' }
	for i := 0; i < len(name); i++ {
		c := name[i]
		if upper(c) {
			if i > 0 && (lower(name[i-1]) || name[i-1] >= '0' && name[i-1] <= '9' || upper(name[i-1]) && i+1 < len(name) && lower(name[i+1])) {
				out.WriteByte('_')
			}
			c += 'a' - 'A'
		}
		out.WriteByte(c)
	}
	return out.String()
}

func pgRowProjectRole(node pgRowCanonical, family, role string) pgRowCanonical {
	if node.atom {
		return node
	}
	children := make([]pgRowCanonical, len(node.children))
	for i, child := range node.children {
		children[i] = pgRowProjectRole(child, family, role)
	}
	projected := pgRowList(children...)
	if projected.list(4) && children[0].isAtom("schema") && children[1].isAtom(family) && children[2].isAtom("snapshot") {
		projected.children[2] = pgRowAtom(role)
	}
	return projected
}

// The checked semantic link must retain the exact old/new type declaration
// closures, including proof and codec definitions. Equal carriers and hashes in
// the outer descriptor cannot substitute a different same-shaped source type.
func pgRowCheckLinkedTypes(r *pgMigrationWireReader, linked pgRowCanonical, family string, before, after PgRowSourceEntity) {
	expectedRoots := map[string]bool{}
	expectedDefinitions := map[string]pgRowCanonical{}
	for i, entity := range []PgRowSourceEntity{before, after} {
		payload := pgRowDocument(r, entity.TypeContract, entity.TypeContractHash, "contract")
		if !payload.list(3) || !payload.children[2].list(3) {
			r.fail("invalid source type closure")
			return
		}
		role := []string{"from", "to"}[i]
		closure := pgRowProjectRole(payload.children[2], family, role)
		for _, root := range closure.children[1].children {
			expectedRoots[pgRowEncode(root)] = true
		}
		for _, definition := range closure.children[2].children {
			if !definition.list(2) {
				r.fail("invalid source type definition")
				return
			}
			key := pgRowEncode(definition.children[0])
			if previous, exists := expectedDefinitions[key]; exists && !pgRowCanonicalEqual(previous, definition) {
				r.fail("inconsistent shared old/new type definition")
			}
			expectedDefinitions[key] = definition
		}
	}
	if !linked.list(3) || !linked.children[0].isAtom("closure") || linked.children[1].atom || linked.children[2].atom {
		r.fail("invalid linked old/new type closure")
		return
	}
	if len(linked.children[1].children) != len(expectedRoots) || len(linked.children[2].children) != len(expectedDefinitions) {
		r.fail("linked old/new type closure is incomplete or has different definitions")
	}
	last := ""
	for _, root := range linked.children[1].children {
		key := pgRowEncode(root)
		if !expectedRoots[key] || key <= last {
			r.fail("linked old/new type roots differ from source contracts")
		}
		last = key
	}
	last = ""
	for _, definition := range linked.children[2].children {
		encoded := pgRowEncode(definition)
		if !definition.list(2) {
			r.fail("invalid linked type definition")
			continue
		}
		expected, exists := expectedDefinitions[pgRowEncode(definition.children[0])]
		if !exists || encoded <= last || !pgRowCanonicalEqual(expected, definition) {
			r.fail("linked old/new type declaration differs from exact source contracts")
		}
		last = encoded
	}
}

// Logical decoder/encoder order is compiler layout metadata. It is neither a
// sorted schema inventory nor a persisted physical column mapping.
func pgRowProjectionFields(r *pgMigrationWireReader, raw json.RawMessage, columns []PgRowSchemaColumn) []string {
	fields := pgMigrationRead[[]string](r, raw)
	expected := map[string]bool{}
	for _, column := range columns {
		expected[column.Field] = true
	}
	if len(fields) != len(columns) || len(fields) == 0 {
		r.fail("row projection requires every logical field")
	}
	for _, field := range fields {
		if !expected[field] {
			r.fail("row projection requires distinct known logical fields")
		}
		delete(expected, field)
	}
	if len(expected) != 0 {
		r.fail("row projection is incomplete")
	}
	return fields
}

func pgRowCheckWriteBacks(r *pgMigrationWireReader, d PgRowTransformDescriptor, before, after map[string]PgRowSchemaColumn) {
	writes := map[string]string{}
	last := ""
	for _, w := range d.WriteBacks {
		_, old := before[w.Previous]
		_, fresh := after[w.Current]
		if !old || !fresh || w.Previous <= last || before[w.Previous].PrimaryKey || after[w.Current].PrimaryKey {
			r.fail("invalid WriteBack endpoints")
		}
		last = w.Previous
		writes[w.Previous] = w.Current
	}
	covered := map[string]bool{}
	for _, m := range d.FieldMapping {
		if m.Source == nil {
			continue
		}
		if m.Kind == "retype" {
			if writes[*m.Source] != m.Target || after[m.Target].Name != pgRowSQLColumnName(m.Target)+"__v"+fmt.Sprint(d.MigrationVersion) || before[*m.Source].Name == after[m.Target].Name {
				r.fail("Retype lacks its exact versioned storage and WriteBack pair")
			}
		} else {
			covered[*m.Source] = true
		}
	}
	for old, fresh := range writes {
		if covered[old] {
			r.fail("WriteBack cannot replace a copied field")
		}
		covered[old] = true
		matched := false
		for _, m := range d.FieldMapping {
			if m.Target == fresh && (m.Kind == "computed" || m.Kind == "retype" && m.Source != nil && *m.Source == old) {
				matched = true
			}
		}
		if !matched {
			r.fail("WriteBack target lacks a checked computed or Retype mapping")
		}
	}
	for field := range before {
		if !covered[field] {
			r.fail("row adapter omits an old field's write-back value")
		}
	}
}

// A snapshot annotation is not permission to invent a physical column. Its
// origin must be the exact Retype edge, and later snapshots retain that identity.
func pgRowCheckColumnOrigins(r *pgMigrationWireReader, base PgRowSourceInventory, format int) {
	for i, v := range base.Versions {
		for _, entity := range v.Entities {
			var old PgRowSourceEntity
			if i > 0 {
				old, _ = pgRowFindEntity(base.Versions[i-1], entity.Entity)
			}
			for _, c := range entity.Columns {
				if c.Name == pgRowSQLColumnName(c.Field) {
					continue
				}
				if format < 3 || i == 0 {
					r.fail("versioned column requires a checked Retype history")
					continue
				}
				retained := false
				for _, p := range old.Columns {
					if p.Field == c.Field && p.Name == c.Name {
						retained = true
					}
				}
				if retained {
					continue
				}
				introduced := false
				for _, d := range base.Transforms {
					if d.MigrationVersion == v.Version && d.Entity == entity.Entity {
						for _, m := range d.FieldMapping {
							if m.Kind == "retype" && m.Target == c.Field && c.Name == pgRowSQLColumnName(c.Field)+"__v"+fmt.Sprint(v.Version) {
								introduced = true
							}
						}
					}
				}
				if !introduced {
					r.fail("versioned column lacks its exact introducing Retype mapping")
				}
			}
		}
	}
}
