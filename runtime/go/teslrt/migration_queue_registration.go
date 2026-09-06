package teslrt

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"

	"github.com/jackc/pgx/v5"
)

// Install only the private candidate extension. Production format 3's exact
// function bodies and grants are unchanged. The owner creates every function;
// request roles cannot register inventory or call the worker-only validators.
func pgCreateQueueCandidateFunctions(ctx context.Context, tx pgx.Tx, ns string, roles PgMigrationControlRoles) error {
	if _, err := tx.Exec(ctx, "set local role "+quoteIdentifier(roles.Owner)); err != nil {
		return err
	}
	for _, fn := range pgQueueCandidateControlFunctions(ns) {
		if fn.name != "tesl_record_expanded" && !strings.HasPrefix(fn.name, "tesl_queue_") && fn.name != "tesl_register_queue_inventory" {
			continue
		}
		sql := pgControlFunctionSQL(ns, roles.Owner, fn)
		if fn.name == "tesl_record_expanded" {
			sql = strings.Replace(sql, "create function ", "create or replace function ", 1)
		}
		if _, err := tx.Exec(ctx, sql); err != nil {
			return fmt.Errorf("candidate function %s: %w", fn.name, err)
		}
		qualified := pgx.Identifier{ns, fn.name}.Sanitize() + "(" + pgControlArgumentTypes(fn) + ")"
		grantees := pgControlFunctionRoles(roles, fn)
		for i := range grantees {
			grantees[i] = quoteIdentifier(grantees[i])
		}
		if _, err := tx.Exec(ctx, "revoke all on function "+qualified+" from public; grant execute on function "+qualified+" to "+strings.Join(grantees, ",")); err != nil {
			return err
		}
	}
	return nil
}

// This private worker helper accepts only a version selected from the checked,
// atomically linked companion. The SQL entrypoint independently checks its
// canonical digest, complete baseline, pending intent and immutable predecessor.
// Call after begin_expansion, in a READ COMMITTED transaction.
func pgRegisterQueueCandidateInventory(ctx context.Context, tx pgx.Tx, h PgCompiledMigrationHistory, initial, version int) error {
	source, err := h.QueueSourceInventory(initial)
	if err != nil {
		return err
	}
	if version < initial || version > h.CurrentVersion || version-initial >= len(source.Versions) {
		return fmt.Errorf("queue registration version is outside linked origin")
	}
	v := source.Versions[version-initial]
	if v.Version != version {
		return fmt.Errorf("queue registration has an incomplete linked origin")
	}
	hash, err := pgQueueCandidateInventoryHash(h, v)
	if err != nil {
		return err
	}
	contracts := v.Contracts
	if contracts == nil {
		contracts = []PgQueueSourceContract{}
	}
	encoded, err := pgQueueRegistrationJSON(contracts)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, "select "+pgx.Identifier{h.Namespace, "tesl_register_queue_inventory"}.Sanitize()+"($1::text,$2::integer,$3::text,$4::text,$5::text,$6::text,$7::text,$8::text,$9::jsonb)", h.Family, v.Version, v.StorageSnapshotHash, v.SchemaSnapshotHash, h.SourceCompilerABI, h.StoredValueCompatibility, v.SourceSealInventory, hash, string(encoded))
	return err
}

// The SQL boundary has a deliberately small closed data shape.
func pgQueueRegistrationJSON(contracts []PgQueueSourceContract) ([]byte, error) {
	type payload struct {
		Job          string `json:"job"`
		Contract     string `json:"contract"`
		ContractHash string `json:"contractHash"`
	}
	type contract struct {
		Queue    string    `json:"queue"`
		Payloads []payload `json:"payloads"`
	}
	wire := []contract{}
	for _, q := range contracts {
		p := []payload{}
		for _, v := range q.Payloads {
			p = append(p, payload(v))
		}
		wire = append(wire, contract{q.Queue, p})
	}
	return json.Marshal(wire)
}

type pgQueueRecordedInventory struct {
	Version                         PgQueueSourceVersion
	Hash, CreatorABI, Compatibility string
}

// Independent read-only metadata validation: a request login cannot execute the
// worker-only SQL validators, and needs no TEMP, CREATE or jobs table privileges.
func pgReadQueueCandidateInventory(ctx context.Context, tx pgx.Tx, h PgCompiledMigrationHistory, version int) (pgQueueRecordedInventory, error) {
	var r pgQueueRecordedInventory
	got := &r.Version
	q := pgx.Identifier{h.Namespace}.Sanitize() + "."
	var contracts, payloads int
	err := tx.QueryRow(ctx, "select version,storage_snapshot_hash,schema_snapshot_hash,source_seal_inventory,inventory_hash,compiler_abi,stored_value_compatibility,contract_count,payload_count from "+q+"tesl_queue_versions where version=$1", version).Scan(&got.Version, &got.StorageSnapshotHash, &got.SchemaSnapshotHash, &got.SourceSealInventory, &r.Hash, &r.CreatorABI, &r.Compatibility, &contracts, &payloads)
	if err != nil {
		return r, err
	}
	if !strings.HasPrefix(r.CreatorABI, "tesl-source-abi-v1:") || !pgMigrationDigest(strings.TrimPrefix(r.CreatorABI, "tesl-source-abi-v1:")) || r.Compatibility != h.StoredValueCompatibility {
		return r, fmt.Errorf("candidate inventory ABI or compatibility differs")
	}
	rows, err := tx.Query(ctx, "select queue,payload_count from "+q+"tesl_queue_contracts where version=$1 order by queue collate \"C\"", version)
	if err != nil {
		return r, err
	}
	type count struct {
		queue string
		count int
	}
	counts := []count{}
	for rows.Next() {
		var c count
		if err := rows.Scan(&c.queue, &c.count); err != nil {
			rows.Close()
			return r, err
		}
		counts = append(counts, c)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return r, err
	}
	got.Contracts = []PgQueueSourceContract{}
	actualPayloads := 0
	for _, c := range counts {
		contract := PgQueueSourceContract{Queue: c.queue, Payloads: []PgQueueSourcePayload{}}
		rows, err := tx.Query(ctx, "select job_type,pg_catalog.encode(contract,'hex'),contract_hash from "+q+"tesl_queue_payloads where version=$1 and queue=$2 order by job_type collate \"C\"", version, c.queue)
		if err != nil {
			return r, err
		}
		for rows.Next() {
			var p PgQueueSourcePayload
			if err := rows.Scan(&p.Job, &p.Contract, &p.ContractHash); err != nil {
				rows.Close()
				return r, err
			}
			contract.Payloads = append(contract.Payloads, p)
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return r, err
		}
		if len(contract.Payloads) != c.count {
			return r, fmt.Errorf("candidate queue payload count differs")
		}
		actualPayloads += c.count
		got.Contracts = append(got.Contracts, contract)
	}
	if contracts != len(got.Contracts) || payloads != actualPayloads {
		return r, fmt.Errorf("candidate queue inventory is incomplete")
	}
	// FK/catalog verification precedes this reader; count every payload as well,
	// so even an externally corrupted orphan cannot disappear from the inventory.
	var storedCount int
	if err := tx.QueryRow(ctx, "select count(*) from "+q+"tesl_queue_payloads where version=$1", version).Scan(&storedCount); err != nil {
		return r, err
	}
	if storedCount != actualPayloads {
		return r, fmt.Errorf("candidate inventory has unowned payloads")
	}
	actualHash, err := pgQueueCandidateInventoryHash(h, *got)
	if err != nil {
		return r, err
	}
	if actualHash != r.Hash {
		return r, fmt.Errorf("candidate queue inventory canonical digest differs")
	}
	return r, nil
}

func pgQueueInventoryPreserves(old, next PgQueueSourceVersion) bool {
	available := map[string]PgQueueSourcePayload{}
	for _, q := range next.Contracts {
		for _, p := range q.Payloads {
			available[q.Queue+"\x00"+p.Job] = p
		}
	}
	for _, q := range old.Contracts {
		for _, p := range q.Payloads {
			if got, ok := available[q.Queue+"\x00"+p.Job]; !ok || got != p {
				return false
			}
		}
	}
	return true
}

func (c *pgQueueCandidatePreparation) verify(ctx context.Context, tx pgx.Tx, state PgMigrationControlState) error {
	if state.Format != 4 {
		return fmt.Errorf("candidate fresh installer cannot adopt format %d", state.Format)
	}
	plan, err := c.history.ExpansionPlan(state.InitialVersion)
	if err != nil {
		return err
	}
	intents, err := pgReadExpansionIntents(ctx, tx, c.history.Namespace)
	if err != nil {
		return err
	}
	if err := pgVerifyExpansionObservation(state, plan, intents); err != nil {
		return err
	}
	b, err := pgReadQueueCandidateBaseline(ctx, tx, c.history.Namespace, state)
	if err != nil {
		return err
	}
	if b.Authority != "complete" {
		return fmt.Errorf("unknown legacy baseline cannot become a complete fresh inventory")
	}
	source, err := c.history.QueueSourceInventory(state.InitialVersion)
	if err != nil {
		return err
	}
	var last int
	if err := tx.QueryRow(ctx, "select max(version) from "+pgx.Identifier{c.history.Namespace, "tesl_queue_versions"}.Sanitize()).Scan(&last); err != nil {
		return err
	}
	var previous PgQueueSourceVersion
	for version := state.InitialVersion; version <= last; version++ {
		r, err := pgReadQueueCandidateInventory(ctx, tx, c.history, version)
		if err != nil {
			return err
		}
		v := r.Version
		if version == state.InitialVersion {
			if r.Hash != b.InventoryHash {
				return fmt.Errorf("candidate baseline differs from linked checked inventory")
			}
			if state.Current == 0 && r.CreatorABI != c.history.SourceCompilerABI {
				return fmt.Errorf("pending candidate inventory is pinned to its creator compiler ABI")
			}
		} else if !pgQueueInventoryPreserves(previous, v) {
			return fmt.Errorf("candidate queue payload was removed, moved or changed at V%d", version)
		}
		if intent := intents[version]; intent != nil {
			if intent.SourceABI != r.CreatorABI {
				return fmt.Errorf("candidate inventory creator differs from expansion intent at V%d", version)
			}
			if intent.SnapshotHash != v.StorageSnapshotHash || intent.StoredValueCompatibility != r.Compatibility {
				return fmt.Errorf("candidate inventory source differs from expansion intent at V%d", version)
			}
		} else if state.Current != 0 || version != state.InitialVersion {
			return fmt.Errorf("candidate inventory has no expansion intent at V%d", version)
		}
		// An old admitted binary validates future inventories structurally and against
		// protected provenance, without inventing checked source for those versions.
		if version <= c.history.CurrentVersion {
			want := source.Versions[version-state.InitialVersion]
			want.SourceSealInventory = v.SourceSealInventory
			if !reflect.DeepEqual(want, v) {
				return fmt.Errorf("candidate queue inventory is incomplete or differs from linked source at V%d", version)
			}
		}
		previous = v
	}
	return nil
}
