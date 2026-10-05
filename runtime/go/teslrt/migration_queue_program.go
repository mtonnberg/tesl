package teslrt

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"reflect"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
)

// PgQueueSourceInventory is checked source information, never installed
// baseline authority, permission to claim a job, or evidence of legacy adoption.
// All returned slices are independent copies parsed from immutable linked bytes.
type PgQueueSourceInventory struct {
	Database, Family, Namespace    string
	InitialVersion, CurrentVersion int
	Versions                       []PgQueueSourceVersion
}
type PgQueueSourceVersion struct {
	Version                                 int
	StorageSnapshotHash, SchemaSnapshotHash string
	SourceSealInventory                     string // complete, unknown, or unrecorded
	Contracts                               []PgQueueSourceContract
}
type PgQueueSourceContract struct {
	Queue    string
	Payloads []PgQueueSourcePayload
}
type PgQueueSourcePayload struct{ Job, Contract, ContractHash string }

type pgQueueHistoryRegistration struct {
	history PgCompiledMigrationHistory
	json    string
}

var queueSchemaOwners = struct {
	sync.Mutex
	queues map[*Database]map[string]*Queue
}{queues: map[*Database]map[string]*Queue{}}

var compiledQueueHistories = struct {
	sync.RWMutex
	families map[string]pgQueueHistoryRegistration
}{families: map[string]pgQueueHistoryRegistration{}}

// Generated runtime initialization publishes the entire validated companion in
// one critical section. Failed validation or any conflicting family leaves the
// registry untouched; there is never a partially linked database set.
func registerCompiledQueueHistory(payload string) {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	if err := pgMigrationCheckJSON(payload); err != nil {
		panic(err)
	}
	r := &pgMigrationWireReader{}
	root := r.object(json.RawMessage(payload), "version", "kind", "compilerAbi", "storedValueCompatibility", "databases")
	entries := pgMigrationRead[[]json.RawMessage](r, root["databases"])
	pending := map[string]pgQueueHistoryRegistration{}
	for _, raw := range entries {
		keys := []string{"database", "family", "namespace", "currentVersion", "versions", "origins"}
		if pgMigrationRead[int](r, root["version"]) == 2 {
			keys = append(keys, "transitions")
		}
		d := r.object(raw, keys...)
		family := pgMigrationRead[string](r, d["family"])
		linked, ok := compiledMigrationHistories.Load(family)
		if !ok {
			r.fail("queue companion has no linked migration history")
			break
		}
		history := linked.(PgCompiledMigrationHistory)
		if _, err := pgReadQueueHistory(history, payload, 1); err != nil {
			panic(err)
		}
		if _, exists := pending[family]; exists {
			r.fail("duplicate queue companion family")
		}
		pending[family] = pgQueueHistoryRegistration{history: history, json: payload}
	}
	if r.err != nil {
		panic(r.err)
	}
	if len(pending) == 0 {
		panic("queue companion requires at least one database")
	}
	compiledQueueHistories.Lock()
	defer compiledQueueHistories.Unlock()
	for family, registration := range pending {
		if _, exists := compiledQueueHistories.families[family]; !exists && pgMigrationClosedFamilies[family] {
			panic("database: application startup queue history registration is closed")
		}
		if previous, exists := compiledQueueHistories.families[family]; exists && previous != registration {
			panic("database: conflicting compiled queue history for " + family)
		}
	}
	for family, registration := range pending {
		compiledQueueHistories.families[family] = registration
	}
}

// QueueSourceInventory refuses missing companion metadata explicitly. In
// particular, old binaries and unrecorded V1 must not imply an empty installed
// queue inventory. Only a future protected installation may persist that fact.
func (history PgCompiledMigrationHistory) QueueSourceInventory(initialVersion int) (PgQueueSourceInventory, error) {
	compiledQueueHistories.RLock()
	registration, ok := compiledQueueHistories.families[history.Family]
	compiledQueueHistories.RUnlock()
	if !ok {
		return PgQueueSourceInventory{}, fmt.Errorf("compiled queue inventory metadata is missing; baseline completeness is unknown")
	}
	if registration.history != history {
		return PgQueueSourceInventory{}, fmt.Errorf("compiled queue inventory belongs to another linked database history")
	}
	return pgReadQueueHistory(history, registration.json, initialVersion)
}

func pgQueueIdentity(value string) bool {
	if value == "" {
		return false
	}
	for _, segment := range strings.Split(value, ".") {
		if segment == "" || segment[0] < 'A' || segment[0] > 'Z' {
			return false
		}
		for _, c := range segment {
			if (c < 'A' || c > 'Z') && (c < 'a' || c > 'z') && (c < '0' || c > '9') && c != '_' {
				return false
			}
		}
	}
	return true
}

// A v3 artifact only records storage identities through executable origins.
// A v4 source artifact additionally records every exact schema snapshot, even
// for origins whose execution remains refused. Neither form establishes an
// installed baseline; sourceSealInventory remains separate companion provenance.
type pgQueueSourceDatabase struct {
	database, family, namespace string
	current                     int
	versions                    []pgQueueSourceSnapshot
}
type pgQueueSourceSnapshot struct {
	storage, schema string
	definitions     map[string]pgRowCanonical // nil for the legacy v3 projection
}

func pgQueueSourceProjection(history PgCompiledMigrationHistory) ([]pgQueueSourceDatabase, error) {
	if err := pgMigrationCheckJSON(history.HistoryJSON); err != nil {
		return nil, err
	}
	r := &pgMigrationWireReader{}
	root := r.object(json.RawMessage(history.HistoryJSON), "version", "kind", "compilerAbi", "storedValueCompatibility", "databases")
	format := pgMigrationRead[int](r, root["version"])
	if r.err != nil {
		return nil, r.err
	}
	if format == 4 || format == 5 {
		inventories, err := pgReadRowBase(history)
		if err != nil {
			return nil, err
		}
		result := make([]pgQueueSourceDatabase, 0, len(inventories))
		for _, inventory := range inventories {
			d := pgQueueSourceDatabase{database: inventory.Database, family: inventory.Family, namespace: inventory.Namespace, current: inventory.CurrentVersion}
			for _, version := range inventory.Versions {
				schema := pgRowDocument(r, version.SchemaContract, version.SchemaSnapshotHash, "snapshot")
				_, definitions := pgRowClosure(r, schema, history.SourceCompilerABI, history.StoredValueCompatibility)
				d.versions = append(d.versions, pgQueueSourceSnapshot{storage: version.StorageSnapshotHash, schema: version.SchemaSnapshotHash, definitions: definitions})
			}
			result = append(result, d)
		}
		return result, r.err
	}
	// Preserve the existing closed v3 grammar, all-origin replay and selected V1
	// execution refusal. Do not weaken ExpansionPlan to accept source-only v4.
	if _, err := history.ExpansionPlan(1); err != nil {
		return nil, err
	}
	result := []pgQueueSourceDatabase{}
	for _, raw := range pgMigrationRead[[]json.RawMessage](r, root["databases"]) {
		object := r.object(raw, "database", "family", "namespace", "currentVersion", "origins")
		d := pgQueueSourceDatabase{database: pgMigrationRead[string](r, object["database"]), family: pgMigrationRead[string](r, object["family"]), namespace: pgMigrationRead[string](r, object["namespace"]), current: pgMigrationRead[int](r, object["currentVersion"])}
		d.versions = make([]pgQueueSourceSnapshot, d.current)
		for i, rawOrigin := range pgMigrationRead[[]json.RawMessage](r, object["origins"]) {
			_, steps, _ := r.origin(rawOrigin, i+1, d.current)
			for _, step := range steps {
				d.versions[step.Version-1].storage = step.SnapshotHash
			}
		}
		result = append(result, d)
	}
	return result, r.err
}

func pgQueueCheckSourceVersion(r *pgMigrationWireReader, history PgCompiledMigrationHistory, family string, source pgQueueSourceSnapshot, version PgQueueSourceVersion) {
	if source.storage != "" && source.storage != version.StorageSnapshotHash {
		r.fail("queue inventory storage snapshot differs across linked origins")
	}
	if source.definitions == nil {
		return
	}
	if source.schema != version.SchemaSnapshotHash {
		r.fail("queue inventory schema snapshot differs from linked source")
	}
	expected := map[string]pgRowCanonical{}
	for key, definition := range source.definitions {
		if !definition.atom && len(definition.children) > 0 && definition.children[0].isAtom("queue-schema") {
			expected[key] = definition
		}
	}
	if len(expected) != len(version.Contracts) {
		r.fail("queue inventory omits or adds a source queue-schema")
	}
	for _, contract := range version.Contracts {
		reference := pgRowTypeReference(family, contract.Queue)
		reference.children[1] = pgRowAtom("value")
		definition, exists := expected[pgRowEncode(reference)]
		if !exists || !definition.list(3) || !pgRowCanonicalEqual(definition.children[1], reference) || definition.children[2].atom {
			r.fail("queue inventory owner differs from exact source queue-schema")
			continue
		}
		members := map[string]bool{}
		for _, member := range definition.children[2].children {
			key := pgRowEncode(member)
			if members[key] {
				r.fail("source queue-schema has duplicate payloads")
			}
			members[key] = true
		}
		if len(members) != len(contract.Payloads) {
			r.fail("queue payload inventory differs from source queue-schema")
		}
		for _, payload := range contract.Payloads {
			reference := pgRowTypeReference(family, payload.Job)
			if !members[pgRowEncode(reference)] {
				r.fail("queue payload belongs to another source queue-schema")
			}
			document := pgRowDocument(r, payload.Contract, payload.ContractHash, "contract")
			if !document.list(2) || !document.children[0].isAtom("queue-payload-v1") {
				r.fail("queue payload canonical source domain differs")
				continue
			}
			roots, definitions := pgRowClosure(r, document.children[1], history.SourceCompilerABI, history.StoredValueCompatibility)
			if !roots.list(1) || !pgRowCanonicalEqual(roots.children[0], reference) {
				r.fail("queue payload type root differs from exact source identity")
			}
			// The compiler owns reachability/proofs. This verifies its complete queue
			// membership and binds every supplied closure definition to that snapshot.
			for key, definition := range definitions {
				original, exists := source.definitions[key]
				if !exists || !pgRowCanonicalEqual(original, definition) {
					r.fail("queue payload closure differs from exact source snapshot")
				}
			}
		}
	}
}

func pgReadQueueHistory(history PgCompiledMigrationHistory, payload string, initial int) (PgQueueSourceInventory, error) {
	var empty PgQueueSourceInventory
	if initial < 1 || initial > history.CurrentVersion {
		return empty, fmt.Errorf("queue installation origin is outside linked history")
	}
	// Select a fully validated source projection, not execution permission.
	base, err := pgQueueSourceProjection(history)
	if err != nil {
		return empty, err
	}
	if err := pgMigrationCheckJSON(payload); err != nil {
		return empty, err
	}
	r := &pgMigrationWireReader{}
	root := r.object(json.RawMessage(payload), "version", "kind", "compilerAbi", "storedValueCompatibility", "databases")
	format := pgMigrationRead[int](r, root["version"])
	if (format != 1 && format != 2) || pgMigrationRead[string](r, root["kind"]) != "compiled-queue-history" {
		r.fail("unsupported queue companion format")
	}
	if pgMigrationRead[string](r, root["compilerAbi"]) != history.SourceCompilerABI || pgMigrationRead[string](r, root["storedValueCompatibility"]) != history.StoredValueCompatibility {
		r.fail("queue companion compiler provenance disagrees with linked history")
	}
	entries := pgMigrationRead[[]json.RawMessage](r, root["databases"])
	if len(entries) != len(base) {
		r.fail("queue companion omits or adds a linked database")
	}
	var selected PgQueueSourceInventory
	lastIdentity := ""
	for index, raw := range entries {
		if r.err != nil {
			break
		}
		keys := []string{"database", "family", "namespace", "currentVersion", "versions", "origins"}
		if format == 2 {
			keys = append(keys, "transitions")
		}
		d := r.object(raw, keys...)
		identity, family, namespace := pgMigrationRead[string](r, d["database"]), pgMigrationRead[string](r, d["family"]), pgMigrationRead[string](r, d["namespace"])
		current := pgMigrationRead[int](r, d["currentVersion"])
		if index >= len(base) {
			r.fail("queue companion adds a linked database")
			break
		}
		owner := base[index]
		if identity <= lastIdentity || identity != owner.database || family != owner.family || namespace != owner.namespace || current != owner.current {
			r.fail("queue companion connection identity, order or version disagrees with linked history")
		}
		lastIdentity = identity
		versions := pgMigrationReadArray(r, d["versions"], func(raw json.RawMessage) PgQueueSourceVersion {
			v := r.object(raw, "version", "storageSnapshotHash", "schemaSnapshotHash", "checkedInventory", "sourceSealInventory", "contracts")
			result := PgQueueSourceVersion{Version: pgMigrationRead[int](r, v["version"]), StorageSnapshotHash: pgMigrationRead[string](r, v["storageSnapshotHash"]), SchemaSnapshotHash: pgMigrationRead[string](r, v["schemaSnapshotHash"]), SourceSealInventory: pgMigrationRead[string](r, v["sourceSealInventory"])}
			if pgMigrationRead[string](r, v["checkedInventory"]) != "complete" || !pgMigrationDigest(result.StorageSnapshotHash) || !pgMigrationDigest(result.SchemaSnapshotHash) || !slices.Contains([]string{"complete", "unknown", "unrecorded"}, result.SourceSealInventory) {
				r.fail("queue inventory requires explicit checked completeness, source provenance and snapshot identities")
			}
			lastQueue := ""
			jobs := map[string]bool{}
			result.Contracts = pgMigrationReadArray(r, v["contracts"], func(raw json.RawMessage) PgQueueSourceContract {
				c := r.object(raw, "queue", "payloads")
				contract := PgQueueSourceContract{Queue: pgMigrationRead[string](r, c["queue"])}
				if !pgQueueIdentity(contract.Queue) || contract.Queue <= lastQueue {
					r.fail("queue contracts must have unique sorted family-relative identities")
				}
				lastQueue = contract.Queue
				lastJob := ""
				contract.Payloads = pgMigrationReadArray(r, c["payloads"], func(raw json.RawMessage) PgQueueSourcePayload {
					p := r.object(raw, "job", "contractFormat", "contract", "contractHash")
					job := PgQueueSourcePayload{Job: pgMigrationRead[string](r, p["job"]), Contract: pgMigrationRead[string](r, p["contract"]), ContractHash: pgMigrationRead[string](r, p["contractHash"])}
					if !pgQueueIdentity(job.Job) || job.Job <= lastJob || jobs[job.Job] {
						r.fail("queue payload identities must be sorted and owned exactly once")
					}
					lastJob = job.Job
					jobs[job.Job] = true
					bytes, err := hex.DecodeString(job.Contract)
					if err != nil || len(bytes) == 0 || hex.EncodeToString(bytes) != job.Contract || pgMigrationRead[string](r, p["contractFormat"]) != "tesl-queue-payload-v1" || !pgMigrationDigest(job.ContractHash) || fmt.Sprintf("%x", sha256.Sum256(bytes)) != job.ContractHash {
						r.fail("queue payload contract bytes disagree with their canonical identity")
					}
					if err := pgQueueCanonicalContract(bytes); err != nil {
						r.fail(err.Error())
					}
					return job
				})
				if len(contract.Payloads) == 0 {
					r.fail("queue contract has no payloads")
				}
				return contract
			})
			return result
		})
		if len(versions) != current {
			r.fail("queue companion must describe every source version including empty inventories")
		}
		for i, v := range versions {
			if v.Version != i+1 {
				r.fail("queue inventory versions must be consecutive")
			}
			if i < len(owner.versions) {
				pgQueueCheckSourceVersion(r, history, owner.family, owner.versions[i], v)
			}
		}
		transitions := map[int]*pgRowPhysicalPlan{}
		if format == 2 {
			for _, raw := range pgMigrationRead[[]json.RawMessage](r, d["transitions"]) {
				t := r.object(raw, "contract", "hash")
				plan, err := pgParseRowPhysicalPlan(pgMigrationRead[string](r, t["contract"]), pgMigrationRead[string](r, t["hash"]))
				if err != nil {
					r.fail("invalid queue source transition")
					continue
				}
				if plan.family != family || plan.namespace != namespace || plan.version < 2 || plan.version > len(versions) || transitions[plan.version] != nil || !pgQueuePhysicalTransitionMatches(versions[plan.version-2], versions[plan.version-1], plan) {
					r.fail("queue source transition differs from exact adjacent inventories")
					continue
				}
				transitions[plan.version] = plan
			}
		}
		// Every changed pre-existing identity requires a complete checked physical
		// transition. This checks old origins too; only new identities are additive,
		// and an empty array is explicit. Metadata grants no database authority.
		previous := map[string]map[string]PgQueueSourcePayload{}
		for _, version := range versions {
			currentContracts := map[string]map[string]PgQueueSourcePayload{}
			for _, contract := range version.Contracts {
				jobs := map[string]PgQueueSourcePayload{}
				for _, payload := range contract.Payloads {
					jobs[payload.Job] = payload
				}
				currentContracts[contract.Queue] = jobs
			}
			for queue, jobs := range previous {
				next, exists := currentContracts[queue]
				if !exists {
					r.fail("queue contract was removed across source versions")
				}
				for job, payload := range jobs {
					if fresh, exists := next[job]; !exists || fresh != payload && transitions[version.Version] == nil {
						r.fail("queue payload contract changed across source versions")
					}
				}
			}
			previous = currentContracts
		}
		origins := pgMigrationRead[[]json.RawMessage](r, d["origins"])
		if len(origins) != current {
			r.fail("queue companion must describe every installation origin")
		}
		for i, rawOrigin := range origins {
			if r.err != nil {
				break
			}
			o := r.object(rawOrigin, "initialVersion", "versions")
			origin := pgMigrationRead[int](r, o["initialVersion"])
			refs := pgMigrationRead[[]int](r, o["versions"])
			if origin != i+1 || len(refs) != current-i {
				r.fail("queue origin has incomplete version references")
			}
			for j, ref := range refs {
				if ref != origin+j {
					r.fail("queue origin references another version inventory")
				}
			}

		}
		if identity == history.Database {
			selected = PgQueueSourceInventory{Database: identity, Family: family, Namespace: namespace, InitialVersion: initial, CurrentVersion: current}
			if r.err == nil {
				selected.Versions = versions[initial-1:]
			}
		}
	}
	if r.err != nil {
		return empty, r.err
	}
	if selected.Database == "" {
		return empty, fmt.Errorf("queue companion is missing its linked database")
	}
	return selected, nil
}

// The reader needs exact canonical bytes, not an interpreter for schema IR.
// Validate the length-delimited tree and domain wrapper so no ambiguous or
// trailing byte sequence can acquire the same logical payload description.
func pgQueueCanonicalContract(data []byte) error {
	atom := func(value string) string { return fmt.Sprintf("s%d:%s", len(value), value) }
	prefix := "l4:" + atom("tesl-migration-canonical") + atom("1") + atom("contract") + "l2:" + atom("queue-payload-v1")
	if !strings.HasPrefix(string(data), prefix) {
		return fmt.Errorf("invalid queue canonical domain")
	}
	offset := 0
	var read func(int) (string, error)
	read = func(depth int) (string, error) {
		if depth > 512 || offset >= len(data) {
			return "", fmt.Errorf("invalid queue canonical contract")
		}
		tag := data[offset]
		offset++
		if tag != 's' && tag != 'l' {
			return "", fmt.Errorf("invalid queue canonical node")
		}
		start := offset
		count := 0
		for offset < len(data) && data[offset] >= '0' && data[offset] <= '9' {
			if count > len(data) {
				return "", fmt.Errorf("oversized queue canonical node")
			}
			count = count*10 + int(data[offset]-'0')
			offset++
		}
		if offset == start || offset >= len(data) || data[offset] != ':' || offset-start > 1 && data[start] == '0' {
			return "", fmt.Errorf("invalid queue canonical length")
		}
		offset++
		if count > len(data) {
			return "", fmt.Errorf("oversized queue canonical node")
		}
		if tag == 's' {
			if count > len(data)-offset {
				return "", fmt.Errorf("truncated queue canonical bytes")
			}
			value := string(data[offset : offset+count])
			offset += count
			return value, nil
		}
		children := make([]string, 0)
		for range count {
			child, err := read(depth + 1)
			if err != nil {
				return "", err
			}
			if depth == 0 || depth == 1 {
				children = append(children, child)
			}
		}
		if depth == 0 && (count != 4 || len(children) != 4 || children[0] != "tesl-migration-canonical" || children[1] != "1" || children[2] != "contract" || children[3] != "queue-payload-v1") {
			return "", fmt.Errorf("invalid queue canonical domain")
		}
		if depth == 1 && len(children) > 0 {
			return children[0], nil
		}
		return "", nil
	}
	_, err := read(0)
	if err != nil {
		return err
	}
	if offset != len(data) {
		return fmt.Errorf("trailing queue canonical bytes")
	}
	return nil
}

// PgQueueCodecSource records which checked payload contract the generated codec
// implements. LegacyTypeName remains the existing runtime wire spelling; these
// metadata IDs do not authorize reading or rewriting another schema version.
type PgQueueCodecSource struct {
	Family, Queue, Job, ContractHash, LegacyTypeName string
	Version                                          int
}
type pgQueueBinding struct {
	history  PgCompiledMigrationHistory
	contract PgQueueSourceContract
	version  int
	codecs   map[string]PgQueueCodecSource
}

// RegisterQueueSchema binds an actual durable queue pointer to its exact linked
// database and checked contract. It neither opens a connection nor changes the
// queue name, storage schema, facility refusal, or claim behavior. The checked
// identity is registered as a notification alias for the private queue listener.
func RegisterQueueSchema(queue *Queue, database *Database, family, identity string, version int) struct{} {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	if queue == nil || database == nil {
		panic("queue schema: missing queue or database")
	}
	backend, ok := queue.backend.(*pgQueueBackend)
	if !ok || backend.database != database {
		panic("queue schema: queue belongs to another database")
	}
	linked, ok := compiledMigrationHistories.Load(family)
	if !ok {
		panic("queue schema: missing linked database history")
	}
	history := linked.(PgCompiledMigrationHistory)
	actual, exists := databaseIdentities.Load(history.Database)
	bound, boundOK := database.CompiledMigrationHistory()
	if !exists || actual != database || !boundOK || bound != history {
		panic("queue schema: database pointer does not own the linked identity")
	}
	if database.Config.Schema != history.Namespace || version != history.CurrentVersion {
		panic("queue schema: database namespace or version mismatch")
	}
	inventory, err := history.QueueSourceInventory(version)
	if err != nil {
		panic(err)
	}
	var contract *PgQueueSourceContract
	for _, candidate := range inventory.Versions[0].Contracts {
		if candidate.Queue == identity {
			copy := candidate
			contract = &copy
		}
	}
	if contract == nil {
		panic("queue schema: unknown contract")
	}
	backend.codecsMutex.Lock()
	defer backend.codecsMutex.Unlock()
	if backend.queueCodecsClosed {
		panic("queue schema: application startup codec registration is closed")
	}
	if backend.queueSchema != nil {
		if backend.queueSchema.history != history || backend.queueSchema.contract.Queue != identity || backend.queueSchema.version != version {
			panic("queue schema: conflicting registration")
		}
		return struct{}{}
	}
	if len(backend.codecs) != 0 {
		panic("queue schema: untracked codecs already registered")
	}
	queueSchemaOwners.Lock()
	defer queueSchemaOwners.Unlock()
	owners := queueSchemaOwners.queues[database]
	if owners == nil {
		owners = map[string]*Queue{}
	}
	if previous, exists := owners[identity]; exists && previous != queue {
		panic("queue schema: contract already belongs to another queue")
	}
	owners[identity] = queue
	queueSchemaOwners.queues[database] = owners
	backend.queueSchema = &pgQueueBinding{history: history, contract: *contract, version: version, codecs: map[string]PgQueueCodecSource{}}
	pubsubFor(database).registerQueueAlias(identity, queue)
	return struct{}{}
}

// RegisterQueueSchemaJobCodec registers identity and implementation together;
// ordinary RegisterJobCodec cannot overwrite this checked registration later.
func RegisterQueueSchemaJobCodec(queue *Queue, family, contract, job string, version int, contractHash, legacyName string,
	encode func(any) any, decode func(any) (any, error)) struct{} {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	if queue == nil || encode == nil || decode == nil || legacyName == "" {
		panic("queue schema: incomplete codec registration")
	}
	backend, ok := queue.backend.(*pgQueueBackend)
	if !ok {
		panic("queue schema: codec has no durable queue binding")
	}
	backend.codecsMutex.Lock()
	defer backend.codecsMutex.Unlock()
	if backend.queueCodecsClosed {
		panic("queue schema: application startup codec registration is closed")
	}
	binding := backend.queueSchema
	if binding == nil || binding.history.Family != family || binding.contract.Queue != contract || binding.version != version {
		panic("queue schema: codec belongs to another queue contract")
	}
	matched := false
	for _, p := range binding.contract.Payloads {
		if p.Job == job && p.ContractHash == contractHash {
			matched = true
		}
	}
	if !matched {
		panic("queue schema: codec payload identity or contract does not match checked inventory")
	}
	if _, exists := binding.codecs[job]; exists {
		panic("queue schema: duplicate codec registration")
	}
	for _, existing := range backend.codecs {
		if existing.typeName == legacyName {
			panic("queue schema: duplicate legacy codec spelling")
		}
	}
	binding.codecs[job] = PgQueueCodecSource{Family: family, Queue: contract, Job: job, Version: version, ContractHash: contractHash, LegacyTypeName: legacyName}
	backend.codecs = append(backend.codecs, jobCodec{typeName: legacyName, encode: encode, decode: decode})
	return struct{}{}
}

// QueueSourceCodecs returns a complete checked declaration/codec binding or an
// explicit refusal. Empty or partially initialized registrations never succeed.
func QueueSourceCodecs(queue *Queue) ([]PgQueueCodecSource, error) {
	if queue == nil {
		return nil, fmt.Errorf("queue schema metadata is missing")
	}
	backend, ok := queue.backend.(*pgQueueBackend)
	if !ok {
		return nil, fmt.Errorf("queue schema metadata is missing")
	}
	backend.codecsMutex.RLock()
	defer backend.codecsMutex.RUnlock()
	binding := backend.queueSchema
	if binding == nil || len(binding.codecs) != len(binding.contract.Payloads) {
		return nil, fmt.Errorf("queue schema codec metadata is missing or incomplete")
	}
	linked, ok := backend.database.CompiledMigrationHistory()
	if !ok || linked != binding.history {
		return nil, fmt.Errorf("queue schema codec belongs to another database history")
	}
	result := make([]PgQueueCodecSource, 0, len(binding.codecs))
	for _, p := range binding.contract.Payloads {
		codec, ok := binding.codecs[p.Job]
		if !ok {
			return nil, fmt.Errorf("queue schema codec metadata is incomplete")
		}
		result = append(result, codec)
	}
	return result, nil
}

// Queue conversion sources and their pure adapters are deliberately separate
// from installed queue bindings. Registration here grants no database access,
// claim, restamping, repair or retirement authority.
type pgQueueConversionSourceSpec struct {
	document, digest, callbackIdentity                           string
	oldType, newType, decoder, converter, encoder, targetDecoder string
}

type pgQueueConversionSource struct {
	spec                   pgQueueConversionSourceSpec
	family, queue, job     string
	fromVersion, toVersion int
	parentDigest           string
	repairRevision         int
	conversion             pgRowCanonical
}

var compiledQueueConversionSources = struct {
	sync.RWMutex
	byDigest map[string]*pgQueueConversionSource
}{byDigest: map[string]*pgQueueConversionSource{}}

var compiledQueueConversionExecutables = struct {
	sync.RWMutex
	byDigest map[string]pgQueueConversionExecutable
}{byDigest: map[string]pgQueueConversionExecutable{}}

func pgReadQueueConversionSource(spec pgQueueConversionSourceSpec) (*pgQueueConversionSource, error) {
	r := &pgMigrationWireReader{}
	node := pgRowDocument(r, spec.document, spec.digest, "migration")
	if r.err != nil {
		return nil, r.err
	}
	parentDigest, repairRevision := "", 0
	if node.list(4) && node.children[0].isAtom("checked-queue-repair-source-v1") {
		if !node.children[1].atom || !pgMigrationDigest(node.children[1].value) || !node.children[2].atom {
			return nil, fmt.Errorf("queue repair predecessor or revision is invalid")
		}
		parentDigest = node.children[1].value
		var err error
		repairRevision, err = strconv.Atoi(node.children[2].value)
		if err != nil || repairRevision < 1 || repairRevision > 2147483646 || strconv.Itoa(repairRevision) != node.children[2].value {
			return nil, fmt.Errorf("queue repair revision is invalid")
		}
		node = node.children[3]
	}
	if !(node.list(13) && node.children[0].isAtom("checked-queue-transform-source-v1")) &&
		!(node.list(17) && node.children[0].isAtom("checked-queue-transform-source-v2")) {
		return nil, fmt.Errorf("queue conversion source has an unsupported closed format")
	}
	if node.list(17) {
		for _, hash := range node.children[13:] {
			if !hash.atom || !pgMigrationDigest(hash.value) {
				return nil, fmt.Errorf("queue conversion schema snapshot binding is invalid")
			}
		}
	}
	for i := 1; i <= 6; i++ {
		if !node.children[i].atom {
			return nil, fmt.Errorf("queue conversion source header is not scalar")
		}
	}
	abi, compatibility := node.children[1].value, node.children[2].value
	family, queue, job := node.children[3].value, node.children[5].value, node.children[6].value
	version, err := strconv.Atoi(node.children[4].value)
	if err != nil || strconv.Itoa(version) != node.children[4].value || version < 2 || version > 2147483646 ||
		!pgMigrationFamily(family) || !pgQueueIdentity(queue) || !pgQueueIdentity(job) ||
		!strings.HasPrefix(abi, "tesl-source-abi-v1:") || !pgMigrationDigest(strings.TrimPrefix(abi, "tesl-source-abi-v1:")) ||
		!strings.HasPrefix(compatibility, "tesl-stored-value-v1:") || !pgMigrationDigest(strings.TrimPrefix(compatibility, "tesl-stored-value-v1:")) {
		return nil, fmt.Errorf("queue conversion source identity is invalid")
	}
	if !strings.HasPrefix(spec.callbackIdentity, family+".Migrate.") {
		return nil, fmt.Errorf("queue conversion callback belongs to another family")
	}
	for _, part := range strings.Split(spec.callbackIdentity, ".") {
		if !pgRowName(part) {
			return nil, fmt.Errorf("queue conversion callback identity is invalid")
		}
	}
	for _, name := range []string{spec.oldType, spec.newType, spec.decoder, spec.converter, spec.encoder, spec.targetDecoder} {
		if !strings.HasPrefix(name, "tesl.generated/") || !strings.Contains(name, "/internal/") || strings.ContainsAny(name, "\x00\r\n") {
			return nil, fmt.Errorf("queue conversion has an invalid emitted binding")
		}
	}
	if pgRowCanonicalEqual(node.children[7], node.children[8]) {
		return nil, fmt.Errorf("unchanged queue payload cannot claim conversion authority")
	}
	reference := pgRowTypeReference(family, job)
	from := pgRowProjectRole(reference, family, "from")
	to := pgRowProjectRole(reference, family, "to")
	named := func(ref pgRowCanonical) pgRowCanonical { return pgRowList(pgRowAtom("named"), ref) }
	primitive := func(name string) pgRowCanonical {
		return named(pgRowList(pgRowAtom("reference"), pgRowAtom("type"), pgRowList(pgRowAtom("primitive"), pgRowAtom(name))))
	}
	rawClosure := func(body pgRowCanonical) (pgRowCanonical, map[string]pgRowCanonical) {
		return pgRowClosure(r, pgRowList(pgRowAtom("compiler-semantics"), pgRowAtom(abi), body), abi, compatibility)
	}
	sourceDefinitions := map[string]pgRowCanonical{}
	oldDefinitions := map[string]pgRowCanonical{}
	for i, role := range []string{"from", "to"} {
		roots, definitions := pgRowClosure(r, node.children[7+i], abi, compatibility)
		body := definitions[pgRowEncode(reference)]
		if !roots.list(1) || !pgRowCanonicalEqual(roots.children[0], reference) || !body.list(4) || !body.children[0].isAtom("record-declaration") || !pgRowCanonicalEqual(body.children[1], reference) {
			r.fail("queue conversion payload has another nominal source owner")
		}
		codecReference := pgRowProjectRole(reference, family, role)
		codecReference.children[1] = pgRowAtom("codec")
		codecRoots, codecDefinitions := rawClosure(node.children[9+i])
		if !codecRoots.list(1) || !pgRowCanonicalEqual(codecRoots.children[0], codecReference) {
			r.fail("queue conversion codec has another source owner")
		}
		expected := map[string]pgRowCanonical{}
		for key, value := range definitions {
			// The key is framed canonical text. Project the original definitions
			// directly rather than performing text substitutions in user literals.
			if value.atom || len(value.children) < 2 || pgRowEncode(value.children[1]) != key {
				r.fail("queue payload has an invalid declaration")
				continue
			}
			projected := pgRowProjectRole(value, family, role)
			expected[pgRowEncode(projected.children[1])] = projected
			sourceDefinitions[pgRowEncode(projected.children[1])] = projected
		}
		if i == 0 {
			oldDefinitions = expected
		}
		for key, value := range codecDefinitions {
			if original, ok := expected[key]; !ok || !pgRowCanonicalEqual(original, value) {
				r.fail("queue conversion codec differs from its exact payload contract")
			}
		}
		if len(codecDefinitions) != len(expected) {
			r.fail("queue conversion codec omits an exact payload dependency")
		}
		codec := codecDefinitions[pgRowEncode(codecReference)]
		if !codec.list(5) || !codec.children[0].isAtom("codec") || !pgRowCanonicalEqual(codec.children[1], codecReference) || !pgRowCanonicalEqual(codec.children[2], pgRowProjectRole(reference, family, role)) ||
			codec.children[3].atom || len(codec.children[3].children) == 0 || !codec.children[3].children[0].isAtom("fields") ||
			codec.children[4].atom || len(codec.children[4].children) < 2 || !codec.children[4].children[0].isAtom("alternatives") {
			r.fail("queue conversion requires complete record codecs")
		}
	}
	function := func(closure pgRowCanonical) (pgRowCanonical, pgRowCanonical) {
		roots, definitions := rawClosure(closure)
		for key, value := range definitions {
			if expected, known := sourceDefinitions[key]; known && !pgRowCanonicalEqual(expected, value) {
				r.fail("queue conversion function changed a source type or codec definition")
			}
		}
		if !roots.list(1) {
			r.fail("queue conversion requires one callback root")
			return pgRowCanonical{}, pgRowCanonical{}
		}
		body := definitions[pgRowEncode(roots.children[0])]
		if !body.list(6) || !body.children[0].isAtom("function") || !body.children[2].isAtom("fn") || !pgRowCanonicalEqual(body.children[1], roots.children[0]) {
			r.fail("queue conversion requires an ordinary checked function")
		}
		return roots.children[0], body
	}
	callbackRoot, callback := function(node.children[11])
	_, callbackDefinitions := rawClosure(node.children[11])
	for key, expected := range sourceDefinitions {
		if actual, found := callbackDefinitions[key]; !found || !pgRowCanonicalEqual(actual, expected) {
			r.fail("queue conversion callback omits an exact source dependency")
		}
	}
	parts := []pgRowCanonical{}
	for _, part := range strings.Split(spec.callbackIdentity, ".") {
		parts = append(parts, pgRowAtom(part))
	}
	expectedCallback := pgRowList(pgRowAtom("reference"), pgRowAtom("value"), pgRowList(pgRowAtom("global"), pgRowList(parts...)))
	expectedResult := pgRowList(pgRowAtom("plain"), pgRowList(pgRowAtom("apply"), primitive("Tesl.Migration.Migrated"), named(to)))
	if !pgRowCanonicalEqual(callbackRoot, expectedCallback) || !callback.list(6) || !callback.children[3].list(1) ||
		!callback.children[3].children[0].list(4) || !callback.children[3].children[0].children[0].isAtom("binding") ||
		!pgRowCanonicalEqual(callback.children[3].children[0].children[1], pgRowList(pgRowAtom("local"), pgRowAtom("0"))) ||
		!pgRowCanonicalEqual(callback.children[3].children[0].children[2], named(from)) ||
		!callback.children[3].children[0].children[3].list(1) || !callback.children[3].children[0].children[3].children[0].isAtom("none") ||
		!pgRowCanonicalEqual(callback.children[4], expectedResult) {
		r.fail("queue conversion callback signature differs from its payloads")
	}
	fixtures := node.children[12]
	if fixtures.atom || len(fixtures.children) == 0 {
		r.fail("queue conversion source has no checked fixture")
	}
	fixtureRoots := map[string]bool{}
	for _, fixture := range fixtures.children {
		root, body := function(fixture)
		_, definitions := rawClosure(fixture)
		for key, expected := range oldDefinitions {
			if actual, found := definitions[key]; !found || !pgRowCanonicalEqual(actual, expected) {
				r.fail("queue conversion fixture omits an exact old payload dependency")
			}
		}
		key := pgRowEncode(root)
		if fixtureRoots[key] {
			r.fail("duplicate queue conversion fixture")
		}
		fixtureRoots[key] = true
		direct := pgRowList(pgRowAtom("plain"), named(from))
		optional := pgRowList(pgRowAtom("plain"), pgRowList(pgRowAtom("apply"), primitive("Tesl.Maybe.Maybe"), named(from)))
		if !body.list(6) || !body.children[3].list(0) || (!pgRowCanonicalEqual(body.children[4], direct) && !pgRowCanonicalEqual(body.children[4], optional)) {
			r.fail("queue conversion fixture has another source payload")
		}
	}
	if r.err != nil {
		return nil, r.err
	}
	return &pgQueueConversionSource{spec: spec, family: family, queue: queue, job: job, fromVersion: version - 1, toVersion: version,
		parentDigest: parentDigest, repairRevision: repairRevision, conversion: node}, nil
}

func registerCompiledQueueConversionSources(specs []pgQueueConversionSourceSpec) {
	pending := map[string]*pgQueueConversionSource{}
	for _, spec := range specs {
		value, err := pgReadQueueConversionSource(spec)
		if err != nil {
			panic(err)
		}
		if _, exists := pending[spec.digest]; exists {
			panic("duplicate queue conversion source")
		}
		pending[spec.digest] = value
	}
	compiledQueueConversionSources.Lock()
	defer compiledQueueConversionSources.Unlock()
	for key, value := range pending {
		if old, exists := compiledQueueConversionSources.byDigest[key]; exists && old.spec != value.spec {
			panic("conflicting queue conversion source")
		}
		if value.parentDigest != "" {
			parent := pending[value.parentDigest]
			if parent == nil {
				parent = compiledQueueConversionSources.byDigest[value.parentDigest]
			}
			if parent == nil || parent.repairRevision+1 != value.repairRevision {
				panic("queue repair has no exact immutable predecessor")
			}
			// Each revision introduces a new callback; a later repair must not
			// silently reuse an earlier deployed conversion declaration.
			for ancestor := parent; ancestor != nil; {
				if ancestor.spec.callbackIdentity == value.spec.callbackIdentity {
					panic("queue repair reused a deployed callback")
				}
				digest := ancestor.parentDigest
				if digest == "" {
					break
				}
				next := pending[digest]
				if next == nil {
					next = compiledQueueConversionSources.byDigest[digest]
				}
				if next == nil || next.repairRevision+1 != ancestor.repairRevision {
					panic("queue repair has an incomplete or non-monotone lineage")
				}
				ancestor = next
			}
			for i := 0; i < 11; i++ {
				if !pgRowCanonicalEqual(parent.conversion.children[i], value.conversion.children[i]) {
					panic("queue repair changed its frozen source or target contract")
				}
			}
			if len(parent.conversion.children) != len(value.conversion.children) {
				panic("queue repair changed snapshot binding format")
			}
			for i := 13; i < len(value.conversion.children); i++ {
				if !pgRowCanonicalEqual(parent.conversion.children[i], value.conversion.children[i]) {
					panic("queue repair changed full schema snapshot bindings")
				}
			}
		}
	}
	for key, value := range pending {
		compiledQueueConversionSources.byDigest[key] = value
	}
}

// QueueConversionResult is an immutable pure conversion outcome, not permission
// to change a durable job. The zero value never represents accepted data.
type QueueConversionResult struct {
	kind, original, payload, reason string
	source                          *pgQueueConversionSource
}

func (r QueueConversionResult) Kind() string     { return r.kind }
func (r QueueConversionResult) Original() string { return r.original }
func (r QueueConversionResult) Payload() string  { return r.payload }
func (r QueueConversionResult) Reason() string   { return r.reason }
func (r QueueConversionResult) SourceDigest() string {
	if r.source == nil {
		return ""
	}
	return r.source.spec.digest
}
func (r QueueConversionResult) SourceVersion() int {
	if r.source == nil {
		return 0
	}
	return r.source.fromVersion
}
func (r QueueConversionResult) TargetVersion() int {
	if r.source == nil {
		return 0
	}
	return r.source.toVersion
}

type CompiledQueueConversion[Old, Current any] struct {
	source       *pgQueueConversionSource
	decode       func(any) Check[Old]
	convert      func(Old) Migrated[Current]
	encode       func(Current) any
	targetDecode func(any) Check[Current]
}

func (c *CompiledQueueConversion[Old, Current]) SourceVersion() int {
	if c == nil || c.source == nil {
		return 0
	}
	return c.source.fromVersion
}

// BindCompiledQueueConversion accepts only the exact generated types and named
// wrappers recorded by the compiler-owned registration. Arbitrary callbacks and
// zero values cannot acquire even this pure adapter binding.
func BindCompiledQueueConversion[Old, Current any](digest string, decode func(any) Check[Old], convert func(Old) Migrated[Current], encode func(Current) any, targetDecode func(any) Check[Current]) (*CompiledQueueConversion[Old, Current], error) {
	compiledQueueConversionSources.RLock()
	source := compiledQueueConversionSources.byDigest[digest]
	compiledQueueConversionSources.RUnlock()
	if source == nil {
		return nil, fmt.Errorf("queue conversion source is not linked")
	}
	typeName := func(t reflect.Type) string { return t.PkgPath() + "." + t.Name() }
	if typeName(reflect.TypeFor[Old]()) != source.spec.oldType || typeName(reflect.TypeFor[Current]()) != source.spec.newType {
		return nil, fmt.Errorf("queue conversion nominal types differ from linked source")
	}
	for _, binding := range []struct {
		value any
		name  string
	}{{decode, source.spec.decoder}, {convert, source.spec.converter}, {encode, source.spec.encoder}, {targetDecode, source.spec.targetDecoder}} {
		value := reflect.ValueOf(binding.value)
		if value.IsNil() {
			return nil, fmt.Errorf("queue conversion callback is missing")
		}
		fn := runtime.FuncForPC(value.Pointer())
		if fn == nil || fn.Name() != binding.name {
			return nil, fmt.Errorf("queue conversion callback differs from its emitted source binding")
		}
	}
	value := &CompiledQueueConversion[Old, Current]{source, decode, convert, encode, targetDecode}
	compiledQueueConversionExecutables.Lock()
	compiledQueueConversionExecutables.byDigest[digest] = value
	compiledQueueConversionExecutables.Unlock()
	return value, nil
}

func (c *CompiledQueueConversion[Old, Current]) Convert(sourceVersion int, bytes []byte) (result QueueConversionResult, err error) {
	if c != nil && c.source != nil && c.source.parentDigest != "" {
		return result, fmt.Errorf("queue repair requires its predecessor's rejected outcome")
	}
	return c.convertBytes(sourceVersion, bytes)
}

// Repair retries only an opaque rejection from the exact preceding conversion
// or repair revision. It always decodes the original historical bytes. Like
// Convert, this pure operation grants no permission to mutate a durable job.
func (c *CompiledQueueConversion[Old, Current]) Repair(rejected QueueConversionResult) (QueueConversionResult, error) {
	if c == nil || c.source == nil || c.source.parentDigest == "" || rejected.kind != "migration-rejected" ||
		rejected.source == nil || rejected.source.spec.digest != c.source.parentDigest {
		return QueueConversionResult{}, fmt.Errorf("queue repair requires its exact predecessor's rejection")
	}
	return c.convertBytes(rejected.SourceVersion(), []byte(rejected.original))
}

func (c *CompiledQueueConversion[Old, Current]) convertBytes(sourceVersion int, bytes []byte) (result QueueConversionResult, err error) {
	if c == nil || c.source == nil || c.decode == nil || c.convert == nil || c.encode == nil || c.targetDecode == nil {
		return result, fmt.Errorf("queue conversion is not bound")
	}
	if sourceVersion != c.source.fromVersion {
		return result, fmt.Errorf("queue conversion source version differs")
	}
	defer func() {
		if recover() != nil {
			result = QueueConversionResult{}
			err = fmt.Errorf("queue conversion trapped")
		}
	}()
	original := string(bytes)
	result = QueueConversionResult{kind: "payload-invalid", original: original, source: c.source}
	parsed, parseErr := ParseJSON([]byte(original))
	if parseErr != nil {
		return result, nil
	}
	old, ok := c.decode(parsed).Value()
	if !ok {
		return result, nil
	}
	converted := c.convert(old)
	switch converted.Tag {
	case MigratedReject:
		result.kind, result.reason = "migration-rejected", converted.RejectReason
		return result, nil
	case MigratedRow:
		encoded, encodeErr := json.Marshal(c.encode(converted.RowValue))
		if encodeErr != nil {
			return QueueConversionResult{}, fmt.Errorf("queue conversion target encoding failed")
		}
		raw, decodeErr := ParseJSON(encoded)
		if decodeErr != nil || !c.targetDecode(raw).OK() {
			return QueueConversionResult{}, fmt.Errorf("queue conversion target codec rejected its encoded value")
		}
		result.kind, result.payload = "converted", string(encoded)
		return result, nil
	default:
		return QueueConversionResult{}, fmt.Errorf("queue conversion returned an invalid result tag")
	}
}
