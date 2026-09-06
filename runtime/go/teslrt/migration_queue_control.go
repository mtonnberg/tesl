package teslrt

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
)

// These helpers are deliberately private. Candidate format 4 has no published
// function catalog, opener, CLI target or queue dispatch path yet.
type pgQueueCandidatePreparation struct {
	history PgCompiledMigrationHistory
	roles   PgMigrationControlRoles
}
type pgQueueCandidateBaseline struct {
	Authority, EstablishedBy string
	InitialVersion           int
	InventoryHash            string
}

func pgInstallQueueCandidate(ctx context.Context, conn *pgx.Conn, history PgCompiledMigrationHistory, roles PgMigrationControlRoles) (PgMigrationControlState, error) {
	if _, err := history.ExpansionPlan(history.CurrentVersion); err != nil {
		return PgMigrationControlState{}, err
	}
	if _, err := history.QueueSourceInventory(history.CurrentVersion); err != nil {
		return PgMigrationControlState{}, err
	}
	candidate := &pgQueueCandidatePreparation{history: history, roles: roles}
	return pgInstallMigrationControlPrepared(ctx, conn, history.Namespace, roles, history.CurrentVersion, nil, candidate)
}
func pgInspectQueueCandidate(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles) (PgMigrationControlState, error) {
	state, err := pgInspectControlCandidateMode(ctx, tx, namespace, roles, true, true)
	if err != nil {
		return PgMigrationControlState{}, err
	}
	if state.Format != pgQueueCandidateFormat {
		return PgMigrationControlState{}, fmt.Errorf("unpublished queue candidate requires exact format 4")
	}
	if _, err := pgReadQueueCandidateBaseline(ctx, tx, namespace, state); err != nil {
		return PgMigrationControlState{}, err
	}
	return state, nil
}

func pgReadQueueCandidateBaseline(ctx context.Context, tx pgx.Tx, ns string, state PgMigrationControlState) (pgQueueCandidateBaseline, error) {
	var b pgQueueCandidateBaseline
	err := tx.QueryRow(ctx, "select inventory_authority,established_by,initial_version,coalesce(inventory_hash,'') from "+pgx.Identifier{ns, "tesl_queue_baseline"}.Sanitize()+" where id=1").Scan(&b.Authority, &b.EstablishedBy, &b.InitialVersion, &b.InventoryHash)
	if err != nil {
		return b, fmt.Errorf("candidate queue baseline is missing: %w", err)
	}
	if b.InitialVersion != state.InitialVersion || (b.Authority == "complete" && (b.EstablishedBy != "fresh-install" || !pgMigrationDigest(b.InventoryHash))) || (b.Authority == "unknown" && (b.EstablishedBy != "format-upgrade" || b.InventoryHash != "")) || (b.Authority != "complete" && b.Authority != "unknown") {
		return b, fmt.Errorf("candidate queue baseline authority is inconsistent")
	}
	// Unknown historical absence never becomes authority. Complete inventories
	// form a contiguous installed prefix with at most one pending next version.
	var versions, contracts, payloads int
	q := pgx.Identifier{ns}.Sanitize() + "."
	err = tx.QueryRow(ctx, "select (select count(*) from "+q+"tesl_queue_versions),(select count(*) from "+q+"tesl_queue_contracts),(select count(*) from "+q+"tesl_queue_payloads)").Scan(&versions, &contracts, &payloads)
	if err != nil {
		return b, err
	}
	if b.Authority == "unknown" && (versions != 0 || contracts != 0 || payloads != 0) {
		return b, fmt.Errorf("unknown candidate baseline cannot acquire source inventory authority")
	}
	if b.Authority == "complete" {
		var hash string
		var first, last int
		if err := tx.QueryRow(ctx, "select coalesce(min(version),0),coalesce(max(version),0) from "+q+"tesl_queue_versions").Scan(&first, &last); err != nil {
			return b, err
		}
		limit := state.Current + 1
		if state.Current == 0 {
			limit = state.InitialVersion
		}
		if versions == 0 || first != b.InitialVersion || last > limit || last < max(state.Current, b.InitialVersion) || versions != last-first+1 {
			return b, fmt.Errorf("fresh candidate inventory is incomplete or out of order")
		}
		if err := tx.QueryRow(ctx, "select inventory_hash from "+q+"tesl_queue_versions where version=$1", b.InitialVersion).Scan(&hash); err != nil {
			return b, err
		}
		if hash != b.InventoryHash {
			return b, fmt.Errorf("fresh candidate baseline inventory hash differs")
		}
	}
	return b, nil
}

// Canonical byte framing is the existing length-prefixed migration format. No
// JSON rendering/order, process name or app queue name enters this digest.
func pgQueueCandidateInventoryHash(h PgCompiledMigrationHistory, v PgQueueSourceVersion) (string, error) {
	contracts := []string{}
	previous := ""
	seen := map[string]bool{}
	for _, q := range v.Contracts {
		if !pgQueueIdentity(q.Queue) || q.Queue <= previous || len(q.Payloads) == 0 {
			return "", fmt.Errorf("queue inventory contracts are unsorted, duplicate or empty")
		}
		previous = q.Queue
		jobs := []string{}
		prevJob := ""
		for _, p := range q.Payloads {
			if !pgQueueIdentity(p.Job) || p.Job <= prevJob || seen[p.Job] {
				return "", fmt.Errorf("queue inventory payload ownership differs")
			}
			prevJob = p.Job
			seen[p.Job] = true
			bytes, err := hex.DecodeString(p.Contract)
			if err != nil || hex.EncodeToString(bytes) != p.Contract {
				return "", fmt.Errorf("invalid queue contract bytes")
			}
			if err := pgQueueCanonicalContract(bytes); err != nil {
				return "", err
			}
			if fmt.Sprintf("%x", sha256.Sum256(bytes)) != p.ContractHash {
				return "", fmt.Errorf("queue contract digest differs")
			}
			jobs = append(jobs, pgMigrationSeq(pgMigrationBytes(p.Job), pgMigrationBytes("tesl-queue-payload-v1"), pgMigrationBytes(string(bytes)), pgMigrationBytes(p.ContractHash)))
		}
		contracts = append(contracts, pgMigrationSeq(pgMigrationBytes(q.Queue), pgMigrationSeq(jobs...)))
	}
	if v.Version < 1 || v.Version > 2147483646 || !pgMigrationDigest(v.StorageSnapshotHash) || !pgMigrationDigest(v.SchemaSnapshotHash) || (!strings.HasPrefix(h.SourceCompilerABI, "tesl-source-abi-v1:") || !pgMigrationDigest(strings.TrimPrefix(h.SourceCompilerABI, "tesl-source-abi-v1:"))) || !pgStoredValueCompatibility(h.StoredValueCompatibility) || (v.SourceSealInventory != "complete" && v.SourceSealInventory != "unknown" && v.SourceSealInventory != "unrecorded") {
		return "", fmt.Errorf("invalid queue inventory version binding")
	}
	body := pgMigrationSeq(pgMigrationBytes("tesl-queue-inventory-v1"), pgMigrationBytes(h.Family), pgMigrationBytes(strconv.Itoa(v.Version)), pgMigrationBytes(v.StorageSnapshotHash), pgMigrationBytes(v.SchemaSnapshotHash), pgMigrationBytes(h.StoredValueCompatibility), pgMigrationSeq(contracts...))
	return fmt.Sprintf("%x", sha256.Sum256([]byte(body))), nil
}

func pgCreateQueueCandidateTables(ctx context.Context, tx pgx.Tx, ns string, roles PgMigrationControlRoles) error {
	if _, err := tx.Exec(ctx, "set local role "+quoteIdentifier(roles.Owner)); err != nil {
		return err
	}
	readers := quoteIdentifier(roles.Worker)
	if roles.Request != "" {
		readers += "," + quoteIdentifier(roles.Request)
	}
	for _, spec := range pgQueueCandidateTables(ns) {
		if _, err := tx.Exec(ctx, "create table "+pgx.Identifier{ns, spec.name}.Sanitize()+" ("+spec.columns+")"); err != nil {
			return err
		}
		if spec.name != "tesl_jobs" {
			if _, err := tx.Exec(ctx, "grant select on "+pgx.Identifier{ns, spec.name}.Sanitize()+" to "+readers); err != nil {
				return err
			}
		}
		migrationBoundary("queue-candidate-table-" + spec.name)
	}
	for _, sql := range pgQueueCandidateIndexes(ns) {
		if _, err := tx.Exec(ctx, sql); err != nil {
			return err
		}
	}
	return nil
}
func (c *pgQueueCandidatePreparation) prepareFresh(ctx context.Context, tx pgx.Tx, state PgMigrationControlState) error {
	if state.Format != 3 || state.Current != 0 || state.InitialVersion != c.history.CurrentVersion || state.InstallingVersion != state.InitialVersion {
		return fmt.Errorf("candidate complete baseline requires a genuinely fresh installation")
	}
	inv, err := c.history.QueueSourceInventory(state.InitialVersion)
	if err != nil {
		return err
	}
	v := inv.Versions[0]
	hash, err := pgQueueCandidateInventoryHash(c.history, v)
	if err != nil {
		return err
	}
	if err := pgCreateQueueCandidateTables(ctx, tx, c.history.Namespace, c.roles); err != nil {
		return err
	}
	q := pgx.Identifier{c.history.Namespace}.Sanitize() + "."
	_, err = tx.Exec(ctx, "insert into "+q+"tesl_queue_baseline(id,inventory_authority,established_by,initial_version,inventory_hash) values(1,'complete','fresh-install',$1,$2)", state.InitialVersion, hash)
	if err != nil {
		return err
	}
	if err := pgInsertQueueCandidateInventory(ctx, tx, c.history, v, hash); err != nil {
		return err
	}
	if err := pgCreateQueueCandidateFunctions(ctx, tx, c.history.Namespace, c.roles); err != nil {
		return err
	}
	migrationBoundary("queue-candidate-inventory")
	_, err = tx.Exec(ctx, "update "+q+"tesl_schema_meta set format_version=4 where id=1 and format_version=3")
	return err
}
func pgInsertQueueCandidateInventory(ctx context.Context, tx pgx.Tx, h PgCompiledMigrationHistory, v PgQueueSourceVersion, hash string) error {
	q := pgx.Identifier{h.Namespace}.Sanitize() + "."
	count := 0
	for _, contract := range v.Contracts {
		count += len(contract.Payloads)
	}
	_, err := tx.Exec(ctx, "insert into "+q+"tesl_queue_versions(version,storage_snapshot_hash,schema_snapshot_hash,inventory_hash,source_seal_inventory,compiler_abi,stored_value_compatibility,contract_count,payload_count) values($1,$2,$3,$4,$5,$6,$7,$8,$9)", v.Version, v.StorageSnapshotHash, v.SchemaSnapshotHash, hash, v.SourceSealInventory, h.SourceCompilerABI, h.StoredValueCompatibility, len(v.Contracts), count)
	if err != nil {
		return err
	}
	for _, contract := range v.Contracts {
		if _, err := tx.Exec(ctx, "insert into "+q+"tesl_queue_contracts(version,queue,payload_count) values($1,$2,$3)", v.Version, contract.Queue, len(contract.Payloads)); err != nil {
			return err
		}
		for _, p := range contract.Payloads {
			data, err := hex.DecodeString(p.Contract)
			if err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, "insert into "+q+"tesl_queue_payloads(version,queue,job_type,contract_format,contract,contract_hash) values($1,$2,$3,'tesl-queue-payload-v1',$4,$5)", v.Version, contract.Queue, p.Job, data, p.ContractHash); err != nil {
				return err
			}
		}
	}
	return nil
}

// A metadata-only candidate 3 -> 4 rehearsal. There is deliberately no public or
// CLI caller, no baseline adoption and no queue enablement.
func pgUpgradeQueueCandidate(ctx context.Context, conn *pgx.Conn, h PgCompiledMigrationHistory, roles PgMigrationControlRoles) (PgMigrationControlState, error) {
	var observed, result PgMigrationControlState
	if _, err := h.ExpansionPlan(h.CurrentVersion); err != nil {
		return result, err
	}
	inspect := func(tx pgx.Tx) (PgMigrationControlState, error) {
		return pgInspectControlCandidateMode(ctx, tx, h.Namespace, roles, true, true)
	}
	err := pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error {
		if err := pgControlRoles(ctx, tx, roles, true); err != nil {
			return err
		}
		var err error
		observed, err = inspect(tx)
		return err
	})
	if err != nil {
		return result, err
	}
	err = pgMigrationSessionLock(ctx, conn, observed.FenceNamespace, 2147483647, true, func() error {
		return pgControlTransaction(ctx, conn, true, func(tx pgx.Tx) error {
			if err := pgControlRoles(ctx, tx, roles, true); err != nil {
				return err
			}
			state, err := inspect(tx)
			if err != nil {
				return err
			}
			if state.DatabaseUUID != observed.DatabaseUUID || state.FenceNamespace != observed.FenceNamespace {
				return fmt.Errorf("candidate installation identity changed while acquiring locks")
			}
			plan, err := h.ExpansionPlan(state.InitialVersion)
			if err != nil {
				return err
			}
			intents, err := pgReadExpansionIntents(ctx, tx, h.Namespace)
			if err != nil {
				return err
			}
			if err := pgVerifyExpansionHistory(state, plan, intents); err != nil {
				return err
			}
			if state.Format == 4 {
				b, err := pgReadQueueCandidateBaseline(ctx, tx, h.Namespace, state)
				if err != nil {
					return err
				}
				if b.Authority != "unknown" {
					return fmt.Errorf("candidate upgrade cannot reinterpret a fresh complete baseline")
				}
				result = state
				return nil
			}
			if state.Format != 3 || state.Current == 0 || state.InstallingVersion != 0 || len(intents) != state.Current-state.InitialVersion+1 {
				return fmt.Errorf("candidate upgrade requires exact completed format 3 history")
			}
			catalog, err := pgExpansionRecordedCatalog(plan, intents)
			if err != nil {
				return err
			}
			if err := pgVerifyExpansionCatalog(ctx, tx, h.Namespace, roles.Worker, catalog); err != nil {
				return err
			}
			if err := pgVerifyRequestGrants(ctx, tx, h.Namespace, roles, catalog); err != nil {
				return err
			}
			migrationBoundary("queue-candidate-upgrade-before-objects")
			if err := pgCreateQueueCandidateTables(ctx, tx, h.Namespace, roles); err != nil {
				return err
			}
			q := pgx.Identifier{h.Namespace}.Sanitize() + "."
			if _, err := tx.Exec(ctx, "insert into "+q+"tesl_queue_baseline(id,inventory_authority,established_by,initial_version) values(1,'unknown','format-upgrade',$1)", state.InitialVersion); err != nil {
				return err
			}
			if err := pgCreateQueueCandidateFunctions(ctx, tx, h.Namespace, roles); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, "update "+q+"tesl_schema_meta set format_version=4 where id=1 and format_version=3"); err != nil {
				return err
			}
			result, err = pgInspectQueueCandidate(ctx, tx, h.Namespace, roles)
			if err != nil {
				return err
			}
			migrationBoundary("queue-candidate-upgrade-before-commit")
			if err := tx.Commit(ctx); err != nil {
				return err
			}
			migrationBoundary("queue-candidate-upgrade-after-commit")
			return nil
		})
	})
	if err != nil {
		return PgMigrationControlState{}, err
	}
	return result, nil
}
