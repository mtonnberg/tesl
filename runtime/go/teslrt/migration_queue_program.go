package teslrt

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"slices"
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
	if err := pgMigrationCheckJSON(payload); err != nil {
		panic(err)
	}
	r := &pgMigrationWireReader{}
	root := r.object(json.RawMessage(payload), "version", "kind", "compilerAbi", "storedValueCompatibility", "databases")
	entries := pgMigrationRead[[]json.RawMessage](r, root["databases"])
	pending := map[string]pgQueueHistoryRegistration{}
	for _, raw := range entries {
		d := r.object(raw, "database", "family", "namespace", "currentVersion", "versions", "origins")
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
			if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_') {
				return false
			}
		}
	}
	return true
}

func pgReadQueueHistory(history PgCompiledMigrationHistory, payload string, initial int) (PgQueueSourceInventory, error) {
	var empty PgQueueSourceInventory
	if initial < 1 || initial > history.CurrentVersion {
		return empty, fmt.Errorf("queue installation origin is outside linked history")
	}
	// ExpansionPlan validates every database and origin, including refused ones,
	// and reconstructs source snapshots independently from the queue companion.
	if _, err := history.ExpansionPlan(1); err != nil {
		return empty, err
	}
	if err := pgMigrationCheckJSON(payload); err != nil {
		return empty, err
	}
	r := &pgMigrationWireReader{}
	root := r.object(json.RawMessage(payload), "version", "kind", "compilerAbi", "storedValueCompatibility", "databases")
	if pgMigrationRead[int](r, root["version"]) != 1 || pgMigrationRead[string](r, root["kind"]) != "compiled-queue-history" {
		r.fail("unsupported queue companion format")
	}
	if pgMigrationRead[string](r, root["compilerAbi"]) != history.SourceCompilerABI || pgMigrationRead[string](r, root["storedValueCompatibility"]) != history.StoredValueCompatibility {
		r.fail("queue companion compiler provenance disagrees with linked history")
	}
	linkedRoot := r.object(json.RawMessage(history.HistoryJSON), "version", "kind", "compilerAbi", "storedValueCompatibility", "databases")
	linked := pgMigrationRead[[]json.RawMessage](r, linkedRoot["databases"])
	entries := pgMigrationRead[[]json.RawMessage](r, root["databases"])
	if len(entries) != len(linked) {
		r.fail("queue companion omits or adds a linked database")
	}
	var selected PgQueueSourceInventory
	lastIdentity := ""
	for index, raw := range entries {
		if r.err != nil {
			break
		}
		d := r.object(raw, "database", "family", "namespace", "currentVersion", "versions", "origins")
		identity, family, namespace := pgMigrationRead[string](r, d["database"]), pgMigrationRead[string](r, d["family"]), pgMigrationRead[string](r, d["namespace"])
		current := pgMigrationRead[int](r, d["currentVersion"])
		base := r.object(linked[index], "database", "family", "namespace", "currentVersion", "origins")
		if identity <= lastIdentity || identity != pgMigrationRead[string](r, base["database"]) || family != pgMigrationRead[string](r, base["family"]) || namespace != pgMigrationRead[string](r, base["namespace"]) || current != pgMigrationRead[int](r, base["currentVersion"]) {
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
		}
		// Until jobs transformations exist, every pre-existing identity keeps
		// its full contract through each revision. This checks old origins too;
		// only new identities are additive, and an empty array is explicit.
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
					if fresh, exists := next[job]; !exists || fresh != payload {
						r.fail("queue payload contract changed across source versions")
					}
				}
			}
			previous = currentContracts
		}
		origins := pgMigrationRead[[]json.RawMessage](r, d["origins"])
		baseOrigins := pgMigrationRead[[]json.RawMessage](r, base["origins"])
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
			_, steps, _ := r.origin(baseOrigins[i], i+1, current)
			for _, step := range steps {
				if r.err != nil {
					break
				}
				if versions[step.Version-1].StorageSnapshotHash != step.SnapshotHash {
					r.fail("queue inventory storage snapshot differs across linked origins")
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
// queue name, storage schema, facility refusal, or claim behavior.
func RegisterQueueSchema(queue *Queue, database *Database, family, identity string, version int) struct{} {
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
	return struct{}{}
}

// RegisterQueueSchemaJobCodec registers identity and implementation together;
// ordinary RegisterJobCodec cannot overwrite this checked registration later.
func RegisterQueueSchemaJobCodec(queue *Queue, family, contract, job string, version int, contractHash, legacyName string,
	encode func(any) any, decode func(any) (any, error)) struct{} {
	if queue == nil || encode == nil || decode == nil || legacyName == "" {
		panic("queue schema: incomplete codec registration")
	}
	backend, ok := queue.backend.(*pgQueueBackend)
	if !ok {
		panic("queue schema: codec has no durable queue binding")
	}
	backend.codecsMutex.Lock()
	defer backend.codecsMutex.Unlock()
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
