package teslrt

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"unicode/utf8"
)

// The compiler emits each application's migration history into its own
// generated package, internal/teslhistory, whose init registers it here. The
// runtime package therefore stays byte-identical across an application's
// revisions, so Go's build cache reuses it instead of recompiling it whenever
// a migration is added. Generated packages that register databases import
// teslhistory, so this registration runs before theirs.

// RegisterCompiledMigrationHistory registers one database's compiled source history.
func RegisterCompiledMigrationHistory(database, family, namespace string, version int, sourceABI, compatibility, history string) {
	registerCompiledMigrationHistory(database, family, namespace, version, sourceABI, compatibility, history)
}

// RegisterCompiledQueueHistory registers the compiled queue history companion.
func RegisterCompiledQueueHistory(payload string) { registerCompiledQueueHistory(payload) }

// RegisterCompiledRowHistory registers the compiled row transform history.
func RegisterCompiledRowHistory(payload string) { registerCompiledRowHistory(payload) }

// RegisterCompiledRowPhysicalHistory registers the retained physical row history.
func RegisterCompiledRowPhysicalHistory(payload string) { registerCompiledRowPhysicalHistory(payload) }

// RegisterCompiledRowContractHistory registers the reviewed row Contract history.
func RegisterCompiledRowContractHistory(payload string) { registerCompiledRowContractHistory(payload) }

// Lazy validation of the compiler-linked migration history.
//
// A generated application links its complete migration history: one compiled
// document per release, so the bytes grow with every release. A process that
// only serves requests must not pay for every historical release on each start.
// The rule below decides what is checked when.
//
// At registration (Go package initialization, before any database opens) every
// companion is checked for:
//
//   - integrity: valid UTF-8 and balanced JSON structure over all bytes, plus a
//     SHA-256 digest that identifies the linked document;
//   - identity: format, kind, compiler ABI, stored-value compatibility, and each
//     database's identity, namespace and current version, against the linked
//     source history;
//   - the serving window: every part a request process reads, fully validated.
//
// The serving window of a database whose current version is N is:
//
//   - V1: the fresh-install anchor. Startup compares the persisted baseline
//     inventory (tables, queue inventory, catalog hash) byte for byte with it.
//   - V(N-1) and VN: the current schema, physical row layout, current codecs,
//     queue contracts and transforms targeting VN, and the predecessor needed to
//     check the VN expansion step and a required V(N-1) Contract.
//
// Startup additionally compares each version that the database has recorded
// with the linked bytes of that version (physical contract and hash text, queue
// inventory hash), and reads the stage cancellations of the versions whose
// physical document format carries them, without validating those versions'
// contents again: a schema command validated and published them.
//
// Everything else (older schema snapshots, physical plans, transform
// descriptors, queue inventories and Contracts, installation origins, and the
// cross-release checks over the complete history) is validated, at most once
// per process, when a caller needs it. Every mutating schema command
// (install, deploy, worker, catch-up, contract, close-epoch) and every process
// that executes DDL itself (Embedded topology) validates the complete history
// before it changes the database. An accessor that is asked for a version
// outside the window validates the complete history first; it never returns an
// unchecked historical part. A history of at most three versions is entirely
// inside the window and is validated completely at registration.
//
// Each document is decoded once per process. Validated forms are immutable and
// shared; accessors that hand data to callers who may mutate it copy it.

// pgHistoryCounters count expensive history work. Tests use them to show that
// serving start does a bounded amount of work regardless of the release count.
var pgHistoryCounters struct {
	complete atomic.Int64 // complete validations of one linked companion
	elements atomic.Int64 // individually validated window elements
}

// pgServingWindow reports whether version k of a history whose current version
// is current is validated at registration and readable without the complete
// history being validated.
func pgServingWindow(current, k int) bool {
	return k >= 1 && k <= current && (k == 1 || k >= current-1)
}

// pgHistoryInWindow reports whether the whole history is inside the window.
func pgHistoryInWindow(current int) bool { return current <= 3 }

// pgMemo memoizes one deterministic computation over immutable linked bytes.
// A panic inside the computation is recorded as an error, never as success.
type pgMemo[T any] struct {
	once  sync.Once
	ready atomic.Bool
	value T
	err   error
}

// peek returns a finished result without starting the computation.
func (m *pgMemo[T]) peek() (T, error, bool) {
	if !m.ready.Load() {
		var zero T
		return zero, nil, false
	}
	return m.value, m.err, true
}

func (m *pgMemo[T]) get(f func() (T, error)) (T, error) {
	m.once.Do(func() {
		defer func() {
			if failure := recover(); failure != nil {
				var zero T
				m.value, m.err = zero, fmt.Errorf("invalid compiled migration history: %v", failure)
			}
			m.ready.Store(true)
		}()
		m.value, m.err = f()
	})
	return m.value, m.err
}

// pgHistoryDigest identifies linked bytes. It is not a signature: the bytes are
// part of the executable, and the digest only names them in comparisons.
func pgHistoryDigest(payload string) string {
	h := sha256.New()
	_, _ = h.Write([]byte(payload))
	return hex.EncodeToString(h.Sum(nil))
}

// pgHistoryIdentity names a linked history by the digest computed once at
// registration, so per-connection keys need not rehash the whole document.
func pgHistoryIdentity(history PgCompiledMigrationHistory) string {
	if source := pgLinkedSourceOf(history); source != nil {
		if header, err := source.readHeader(); err == nil {
			return header.digest
		}
	}
	return pgHistoryDigest(history.HistoryJSON)
}

// pgJSONIntegrity checks that a linked document is UTF-8. Every caller then
// splits the root with pgJSONObject, which walks the complete string/bracket
// structure of every value and refuses trailing data, at memory speed. Neither
// decodes values; element readers apply the full closed-grammar checks to
// everything they decode.
func pgJSONIntegrity(payload string) error {
	if !utf8.ValidString(payload) {
		return fmt.Errorf("migration history is not UTF-8")
	}
	return nil
}

func pgJSONSpace(s string, i int) int {
	for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') {
		i++
	}
	return i
}

var errPgJSONStructure = fmt.Errorf("invalid compiled migration history: malformed JSON structure")

func pgJSONSkipString(s string, i int) (int, error) {
	j := i + 1
	for {
		k := strings.IndexByte(s[j:], '"')
		if k < 0 {
			return 0, errPgJSONStructure
		}
		j += k
		slashes := 0
		for p := j - 1; p > i && s[p] == '\\'; p-- {
			slashes++
		}
		if slashes%2 == 0 {
			return j + 1, nil
		}
		j++
	}
}

// pgJSONSkip returns the end offset of the value that starts at i.
func pgJSONSkip(s string, i int) (int, error) {
	if i >= len(s) {
		return 0, errPgJSONStructure
	}
	switch s[i] {
	case '"':
		return pgJSONSkipString(s, i)
	case '{', '[':
		stack := make([]byte, 0, 16)
		for j := i; j < len(s); {
			switch c := s[j]; c {
			case '"':
				end, err := pgJSONSkipString(s, j)
				if err != nil {
					return 0, err
				}
				j = end
				continue
			case '{', '[':
				if len(stack) >= 64 {
					return 0, fmt.Errorf("migration history exceeds nesting limit")
				}
				stack = append(stack, c)
			case '}', ']':
				if len(stack) == 0 || (c == '}') != (stack[len(stack)-1] == '{') {
					return 0, errPgJSONStructure
				}
				stack = stack[:len(stack)-1]
				if len(stack) == 0 {
					return j + 1, nil
				}
			}
			j++
		}
		return 0, errPgJSONStructure
	default:
		j := i
		for j < len(s) && s[j] != ',' && s[j] != '}' && s[j] != ']' && s[j] != ' ' && s[j] != '\t' && s[j] != '\n' && s[j] != '\r' {
			j++
		}
		if j == i {
			return 0, errPgJSONStructure
		}
		return j, nil
	}
}

func pgJSONKey(raw string) (string, error) {
	if len(raw) >= 2 && !strings.ContainsAny(raw[1:len(raw)-1], "\\") {
		inner := raw[1 : len(raw)-1]
		for i := 0; i < len(inner); i++ {
			if inner[i] < 0x20 {
				return "", errPgJSONStructure
			}
		}
		return inner, nil
	}
	var key string
	if err := json.Unmarshal([]byte(raw), &key); err != nil {
		return "", errPgJSONStructure
	}
	return key, nil
}

// pgJSONObject splits one object into its exact fields. Duplicate keys, a
// missing key or an extra key fail, like pgMigrationWireReader.object. Values
// are raw text; their contents are checked when they are decoded.
func pgJSONObject(raw string, keys ...string) (map[string]string, error) {
	i := pgJSONSpace(raw, 0)
	if i >= len(raw) || raw[i] != '{' {
		return nil, errPgJSONStructure
	}
	fields := make(map[string]string, len(keys))
	i = pgJSONSpace(raw, i+1)
	if i < len(raw) && raw[i] == '}' {
		i++
	} else {
		for {
			if i >= len(raw) || raw[i] != '"' {
				return nil, errPgJSONStructure
			}
			end, err := pgJSONSkipString(raw, i)
			if err != nil {
				return nil, err
			}
			key, err := pgJSONKey(raw[i:end])
			if err != nil {
				return nil, err
			}
			i = pgJSONSpace(raw, end)
			if i >= len(raw) || raw[i] != ':' {
				return nil, errPgJSONStructure
			}
			i = pgJSONSpace(raw, i+1)
			valueEnd, err := pgJSONSkip(raw, i)
			if err != nil {
				return nil, err
			}
			if _, duplicate := fields[key]; duplicate {
				return nil, fmt.Errorf("migration history has duplicate or invalid object key")
			}
			fields[key] = raw[i:valueEnd]
			i = pgJSONSpace(raw, valueEnd)
			if i < len(raw) && raw[i] == ',' {
				i = pgJSONSpace(raw, i+1)
				continue
			}
			if i < len(raw) && raw[i] == '}' {
				i++
				break
			}
			return nil, errPgJSONStructure
		}
	}
	if pgJSONSpace(raw, i) != len(raw) {
		return nil, errPgJSONStructure
	}
	if len(fields) != len(keys) {
		return nil, fmt.Errorf("invalid compiled migration history: unexpected object fields")
	}
	for _, key := range keys {
		if _, ok := fields[key]; !ok {
			return nil, fmt.Errorf("invalid compiled migration history: missing field %s", key)
		}
	}
	return fields, nil
}

// pgJSONArray splits one array into raw element texts.
func pgJSONArray(raw string) ([]string, error) {
	i := pgJSONSpace(raw, 0)
	if i >= len(raw) || raw[i] != '[' {
		return nil, errPgJSONStructure
	}
	elements := []string{}
	i = pgJSONSpace(raw, i+1)
	if i < len(raw) && raw[i] == ']' {
		i++
	} else {
		for {
			end, err := pgJSONSkip(raw, i)
			if err != nil {
				return nil, err
			}
			elements = append(elements, raw[i:end])
			i = pgJSONSpace(raw, end)
			if i < len(raw) && raw[i] == ',' {
				i = pgJSONSpace(raw, i+1)
				continue
			}
			if i < len(raw) && raw[i] == ']' {
				i++
				break
			}
			return nil, errPgJSONStructure
		}
	}
	if pgJSONSpace(raw, i) != len(raw) {
		return nil, errPgJSONStructure
	}
	return elements, nil
}

// pgJSONValue decodes one small scalar or structure with the strict history
// checks (UTF-8, Unicode escapes, duplicate keys) applied to exactly its text.
func pgJSONValue[T any](raw string) (T, error) {
	var value T
	if err := pgMigrationCheckJSON(raw); err != nil {
		return value, err
	}
	r := &pgMigrationWireReader{}
	value = pgMigrationRead[T](r, json.RawMessage(raw))
	return value, r.err
}

// pgValidateCompleteHistory validates every linked part of a database's
// history: all source versions and origins, row transforms and their callback
// bindings, physical plans, Contracts and queue inventories, with every
// cross-release rule. Schema commands that change the database and processes
// that execute DDL call it before they act. It runs once per process.
func pgValidateCompleteHistory(database *Database) error {
	history, ok := database.CompiledMigrationHistory()
	if !ok {
		return nil
	}
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	if source := pgLinkedSourceOf(history); source != nil {
		if _, err := source.readHeader(); err == nil {
			if _, err := pgReadRowBase(history); err != nil {
				return err
			}
		}
	}
	if registration, err := pgQueueRegistrationOf(history); err == nil {
		if _, err := registration.lazy.complete(); err != nil {
			return err
		}
	}
	compiled := compiledRowHistories[history.Family]
	if compiled == nil {
		return nil
	}
	if _, err := compiled.complete(); err != nil {
		return err
	}
	for i := range compiled.transforms {
		compiled.checked[i] = true
	}
	for _, registration := range compiledRowRegistrations[compiled] {
		if err := pgCheckRowRegistrationTypes(registration); err != nil {
			return err
		}
	}
	if physical := compiledRowPhysicalHistories[compiled]; physical != nil {
		if _, err := physical.all(); err != nil {
			return err
		}
	}
	if contracts := compiledRowContractHistories[compiled]; contracts != nil {
		if _, err := contracts.complete(compiledRowContracts[compiled]); err != nil {
			return err
		}
		// The additive-tail Contract rule for the versions serving reads, over
		// every earlier transformation.
		if physical := compiledRowPhysicalHistories[compiled]; physical != nil {
			for k := max(1, history.CurrentVersion-1); k <= history.CurrentVersion; k++ {
				if _, err := pgRowAdditiveTailPlan(compiled, physical, k, true); err != nil {
					return err
				}
			}
		}
	}
	if _, err := pgQueueRegistrationOf(history); err == nil {
		queues, err := pgRowQueueSources(history)
		if err != nil {
			return err
		}
		if _, err := queues.complete(); err != nil {
			return err
		}
	}
	return nil
}

// pgLinkedSource is the process-wide decoded form of one linked v4/v5 source
// history. Several databases of one application share one document and one
// pgLinkedSource. Everything in it is immutable after its memo completes.
type pgLinkedSource struct {
	history PgCompiledMigrationHistory // the first linked database using these bytes
	header  pgMemo[*pgLinkedSourceHeader]
	full    pgMemo[[]PgRowSourceInventory]
	queue   pgMemo[[]pgQueueSourceDatabase]

	mutex    sync.Mutex
	versions map[string]map[int]*pgMemo[PgRowSourceVersion] // family -> version
}

type pgLinkedSourceHeader struct {
	format    int
	digest    string
	databases map[string]*pgLinkedSourceDatabase // by family
}

type pgLinkedSourceDatabase struct {
	database, family, namespace string
	current                     int
	versions                    []string // raw element text, index = version-1
	retirements                 []PgRowRetirementDescriptor
}

var pgLinkedSources = struct {
	sync.Mutex
	families map[string]*pgLinkedSource
}{families: map[string]*pgLinkedSource{}}

// pgLinkedSourceOf returns the shared source for a history that is exactly the
// one linked for its family, or nil for any other (for example a test-built)
// history, whose readers then decode it directly every time.
func pgLinkedSourceOf(history PgCompiledMigrationHistory) *pgLinkedSource {
	linked, ok := compiledMigrationHistories.Load(history.Family)
	if !ok || linked.(PgCompiledMigrationHistory) != history { //nolint:forcetypeassert // private registry
		return nil
	}
	pgLinkedSources.Lock()
	defer pgLinkedSources.Unlock()
	if source := pgLinkedSources.families[history.Family]; source != nil && source.history.HistoryJSON == history.HistoryJSON {
		if source.history.SourceCompilerABI == history.SourceCompilerABI && source.history.StoredValueCompatibility == history.StoredValueCompatibility {
			return source
		}
		return nil
	}
	for _, source := range pgLinkedSources.families {
		if source.history.HistoryJSON == history.HistoryJSON && source.history.SourceCompilerABI == history.SourceCompilerABI && source.history.StoredValueCompatibility == history.StoredValueCompatibility {
			pgLinkedSources.families[history.Family] = source
			return source
		}
	}
	source := &pgLinkedSource{history: history, versions: map[string]map[int]*pgMemo[PgRowSourceVersion]{}}
	pgLinkedSources.families[history.Family] = source
	return source
}

// complete validates the whole document (every version, origin and
// cross-version rule) once per process.
func (source *pgLinkedSource) complete() ([]PgRowSourceInventory, error) {
	return source.full.get(func() ([]PgRowSourceInventory, error) {
		return pgReadRowBaseDecode(source.history)
	})
}

// readHeader checks integrity and identity over the whole document without
// validating any version's contents.
func (source *pgLinkedSource) readHeader() (*pgLinkedSourceHeader, error) {
	header, err := source.header.get(source.readHeaderNow)
	if err == nil && header == nil {
		err = fmt.Errorf("invalid compiled migration history: missing row source header")
	}
	return header, err
}

func (source *pgLinkedSource) readHeaderNow() (*pgLinkedSourceHeader, error) {
	history := source.history
	payload := history.HistoryJSON
	if len(payload) > pgRowSourceLimit {
		return nil, fmt.Errorf("row source history exceeds size budget")
	}
	if err := pgJSONIntegrity(payload); err != nil {
		return nil, err
	}
	root, err := pgJSONObject(payload, "version", "kind", "compilerAbi", "storedValueCompatibility", "databases")
	if err != nil {
		return nil, err
	}
	format, err := pgJSONValue[int](root["version"])
	if err != nil {
		return nil, err
	}
	kind, err := pgJSONValue[string](root["kind"])
	if err != nil {
		return nil, err
	}
	abi, err := pgJSONValue[string](root["compilerAbi"])
	if err != nil {
		return nil, err
	}
	compatibility, err := pgJSONValue[string](root["storedValueCompatibility"])
	if err != nil {
		return nil, err
	}
	if (format != 4 && format != 5) || kind != "compiled-migration-source-history" || abi != history.SourceCompilerABI || compatibility != history.StoredValueCompatibility ||
		!strings.HasPrefix(history.SourceCompilerABI, "tesl-source-abi-v1:") || !pgMigrationDigest(strings.TrimPrefix(history.SourceCompilerABI, "tesl-source-abi-v1:")) || !pgStoredValueCompatibility(history.StoredValueCompatibility) {
		return nil, fmt.Errorf("invalid compiled migration history: row source envelope differs from linked compiler metadata")
	}
	entries, err := pgJSONArray(root["databases"])
	if err != nil {
		return nil, err
	}
	header := &pgLinkedSourceHeader{format: format, digest: pgHistoryDigest(payload), databases: map[string]*pgLinkedSourceDatabase{}}
	last := ""
	for _, raw := range entries {
		keys := []string{"database", "family", "namespace", "currentVersion", "versions", "origins"}
		if format == 5 {
			keys = append(keys, "retirements")
		}
		fields, err := pgJSONObject(raw, keys...)
		if err != nil {
			return nil, err
		}
		d := &pgLinkedSourceDatabase{}
		if d.database, err = pgJSONValue[string](fields["database"]); err != nil {
			return nil, err
		}
		if d.family, err = pgJSONValue[string](fields["family"]); err != nil {
			return nil, err
		}
		if d.namespace, err = pgJSONValue[string](fields["namespace"]); err != nil {
			return nil, err
		}
		if d.current, err = pgJSONValue[int](fields["currentVersion"]); err != nil {
			return nil, err
		}
		if d.database <= last || !pgMigrationFamily(d.family) || header.databases[d.family] != nil || !pgMigrationIdentifier(d.namespace) || d.current < 1 || d.current > 2147483646 {
			return nil, fmt.Errorf("invalid compiled migration history: invalid or duplicate row source database")
		}
		last = d.database
		if d.versions, err = pgJSONArray(fields["versions"]); err != nil {
			return nil, err
		}
		if len(d.versions) != d.current {
			return nil, fmt.Errorf("invalid compiled migration history: row source versions must be complete")
		}
		if format == 5 {
			if d.retirements, err = pgReadRowRetirementShapes(fields["retirements"], d.current); err != nil {
				return nil, err
			}
		}
		header.databases[d.family] = d
	}
	if len(header.databases) == 0 {
		return nil, fmt.Errorf("invalid compiled migration history: row source history requires a database")
	}
	own := header.databases[history.Family]
	if own == nil || own.database != history.Database || own.namespace != history.Namespace || own.current != history.CurrentVersion {
		return nil, fmt.Errorf("invalid compiled migration history: row source history is missing its linked database")
	}
	return header, nil
}

// pgReadRowRetirementShapes decodes the retirement list with the checks that do
// not need other versions. Complete validation checks the adjacent snapshots.
func pgReadRowRetirementShapes(raw string, current int) ([]PgRowRetirementDescriptor, error) {
	if err := pgMigrationCheckJSON(raw); err != nil {
		return nil, err
	}
	r := &pgMigrationWireReader{}
	lastVersion := 1
	result := pgMigrationReadArray(r, json.RawMessage(raw), func(raw json.RawMessage) PgRowRetirementDescriptor {
		item := r.object(raw, "migrationVersion", "entity", "fromSchemaSnapshot", "toSchemaSnapshot")
		retirement := PgRowRetirementDescriptor{MigrationVersion: pgMigrationRead[int](r, item["migrationVersion"]), Entity: pgMigrationRead[string](r, item["entity"]), FromSchemaSnapshot: pgMigrationRead[string](r, item["fromSchemaSnapshot"]), ToSchemaSnapshot: pgMigrationRead[string](r, item["toSchemaSnapshot"])}
		v := retirement.MigrationVersion
		if v <= lastVersion || v > current || !pgQueueIdentity(retirement.Entity) || !pgMigrationDigest(retirement.FromSchemaSnapshot) || !pgMigrationDigest(retirement.ToSchemaSnapshot) {
			r.fail("invalid or unordered row source retirement")
		}
		lastVersion = v
		return retirement
	})
	return result, r.err
}

// database returns the header entry of one linked family.
func (source *pgLinkedSource) database(family string) (*pgLinkedSourceDatabase, error) {
	header, err := source.readHeader()
	if err != nil {
		return nil, err
	}
	d := header.databases[family]
	if d == nil {
		return nil, fmt.Errorf("invalid compiled migration history: row source history is missing its linked database")
	}
	return d, nil
}

// version returns one validated source version. A version inside the serving
// window is validated on its own; any other version first validates the
// complete history.
func (source *pgLinkedSource) version(family string, k int) (PgRowSourceVersion, error) {
	d, err := source.database(family)
	if err != nil {
		return PgRowSourceVersion{}, err
	}
	if k < 1 || k > d.current {
		return PgRowSourceVersion{}, fmt.Errorf("source version V%d is outside the linked history", k)
	}
	if !pgServingWindow(d.current, k) {
		all, err := source.complete()
		if err != nil {
			return PgRowSourceVersion{}, err
		}
		for _, inventory := range all {
			if inventory.Family == family {
				if k > len(inventory.Versions) {
					break
				}
				return inventory.Versions[k-1], nil
			}
		}
		return PgRowSourceVersion{}, fmt.Errorf("invalid compiled migration history: row source history is missing its linked database")
	}
	source.mutex.Lock()
	byVersion := source.versions[family]
	if byVersion == nil {
		byVersion = map[int]*pgMemo[PgRowSourceVersion]{}
		source.versions[family] = byVersion
	}
	memo := byVersion[k]
	if memo == nil {
		memo = &pgMemo[PgRowSourceVersion]{}
		byVersion[k] = memo
	}
	source.mutex.Unlock()
	return memo.get(func() (PgRowSourceVersion, error) {
		pgHistoryCounters.elements.Add(1)
		raw := d.versions[k-1]
		if err := pgMigrationCheckJSON(raw); err != nil {
			return PgRowSourceVersion{}, err
		}
		r := &pgMigrationWireReader{}
		version := pgReadRowSourceVersion(r, json.RawMessage(raw), family, source.history.SourceCompilerABI, source.history.StoredValueCompatibility)
		if r.err == nil && version.Version != k {
			r.fail("row versions must be consecutive")
		}
		return version, r.err
	})
}

// window validates every source version inside the serving window, and the
// retirement adjacency inside it, or the complete history when it is small.
func (source *pgLinkedSource) window(family string) error {
	d, err := source.database(family)
	if err != nil {
		return err
	}
	if pgHistoryInWindow(d.current) {
		_, err := pgReadRowBase(source.history)
		return err
	}
	for k := 1; k <= d.current; k++ {
		if !pgServingWindow(d.current, k) {
			continue
		}
		if _, err := source.version(family, k); err != nil {
			return err
		}
	}
	for _, retirement := range d.retirements {
		v := retirement.MigrationVersion
		if !pgServingWindow(d.current, v) || !pgServingWindow(d.current, v-1) {
			continue
		}
		from, err := source.version(family, v-1)
		if err != nil {
			return err
		}
		to, err := source.version(family, v)
		if err != nil {
			return err
		}
		if retirement.FromSchemaSnapshot != from.SchemaSnapshotHash || retirement.ToSchemaSnapshot != to.SchemaSnapshotHash {
			return fmt.Errorf("invalid compiled migration history: row source retirement differs from adjacent schema identity")
		}
	}
	return nil
}
