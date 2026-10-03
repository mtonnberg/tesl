package teslrt

import (
	"bytes"
	"context"
	"encoding/hex"
	"fmt"
	"reflect"

	"github.com/jackc/pgx/v5"
)

// Bind an internally checked queue-only target physical descriptor to the actual
// installed application and staged callbacks. This does not insert an expansion
// receipt, publish V2, alter jobs or grant dispatch. Activation must consume the
// exact target binding rather than treating a standalone payload as a schema.
func pgStageRowQueueTarget(ctx context.Context, conn *pgx.Conn, namespace string, roles PgMigrationControlRoles, document, digest string) error {
	plan, err := pgParseRowPhysicalPlan(document, digest)
	if err != nil {
		return err
	}
	if plan.namespace != namespace || plan.version != 2 || len(plan.queueConversions) == 0 || len(plan.windows) != 0 || len(plan.retirements) != 0 || plan.requiresContractVersion != 0 {
		return fmt.Errorf("queue target staging requires an exact V2 queue-only physical descriptor")
	}
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return err
	}
	defer pgQueueConversionCandidateRollback(tx)
	if err := pgControlSession(ctx, tx); err != nil {
		return err
	}
	if err := pgControlRoles(ctx, tx, roles, true); err != nil {
		return err
	}
	state, err := pgInspectRowControl(ctx, tx, namespace, roles)
	if err != nil {
		return err
	}
	ns := quoteIdentifier(namespace) + "."
	for _, conversion := range plan.queueConversions {
		var floor int
		if err := tx.QueryRow(ctx, "select "+ns+"tesl_queue_admit(1,$1)", conversion.queue).Scan(&floor); err != nil {
			return err
		}
	}
	var current int
	if err := tx.QueryRow(ctx, "select current from "+ns+"tesl_schema_state where id=1 for update").Scan(&current); err != nil {
		return err
	}
	if current != 1 {
		return fmt.Errorf("queue target staging requires the installed V1 source")
	}
	var priorDoc []byte
	var priorHash, abi, compatibility, family string
	if err := tx.QueryRow(ctx, "select p.contract,p.contract_hash,p.compiler_abi,p.stored_value_compatibility,r.family from "+ns+"tesl_row_physical p cross join "+ns+"tesl_row_versions r where p.version=1 and r.version=1").Scan(&priorDoc, &priorHash, &abi, &compatibility, &family); err != nil {
		return err
	}
	prior, err := pgParseRowPhysicalPlan(hex.EncodeToString(priorDoc), priorHash)
	if err != nil {
		return err
	}
	if family != plan.family || !reflect.DeepEqual(prior.entities, plan.entities) {
		return fmt.Errorf("queue target changed the installed entity storage")
	}
	var staged int
	if err := tx.QueryRow(ctx, "select count(*) from "+ns+"tesl_row_queue_conversion_staging where from_version=1 and revision=0").Scan(&staged); err != nil {
		return err
	}
	if staged != len(plan.queueConversions) {
		return fmt.Errorf("queue target does not cover the complete staged conversion set")
	}
	for _, conversion := range plan.queueConversions {
		compiledQueueConversionSources.RLock()
		source := compiledQueueConversionSources.byDigest[conversion.digest]
		compiledQueueConversionSources.RUnlock()
		if source == nil || source.parentDigest != "" || source.family != family || source.queue != conversion.queue || source.job != conversion.job || source.fromVersion != 1 || source.toVersion != 2 || source.conversion.children[2].value != compatibility || source.conversion.children[1].value != abi {
			return fmt.Errorf("queue target has no exact compiler-linked conversion")
		}
		if !source.conversion.list(17) || source.conversion.children[13].value != prior.schemaSnapshotHash || source.conversion.children[14].value != plan.schemaSnapshotHash || source.conversion.children[15].value != prior.storageSnapshotHash || source.conversion.children[16].value != plan.storageSnapshotHash {
			return fmt.Errorf("queue target differs from its full checked schema/storage snapshots")
		}
		old, err := hex.DecodeString(conversion.oldContract)
		if err != nil {
			return err
		}
		fresh, err := hex.DecodeString(conversion.newContract)
		if err != nil {
			return err
		}
		if !bytes.Equal(old, pgQueueConversionPayloadContract(source, false)) || !bytes.Equal(fresh, pgQueueConversionPayloadContract(source, true)) {
			return fmt.Errorf("queue target payload differs from its checked conversion")
		}
		var matches bool
		err = tx.QueryRow(ctx, "select s.database_uuid::text=$1 and s.fence_ns=$2 and s.to_version=2 and s.source_digest=$3 and s.source_document=$4 and s.old_contract=$5 and s.new_contract=$6 and s.inventory_hash=q.inventory_hash and s.expansion_hash=q.expansion_hash and s.old_contract=p.contract from "+ns+`tesl_row_queue_conversion_staging s
 join `+ns+`tesl_row_queue_sources q on q.version=s.from_version
 join `+ns+`tesl_queue_payloads p on p.version=s.from_version and p.queue=s.queue and p.job_type=s.job_type
 where s.from_version=1 and s.queue=$7 and s.job_type=$8 and s.revision=0`, state.DatabaseUUID, state.FenceNamespace, source.spec.digest, mustQueueConversionDocument(source), old, fresh, source.queue, source.job).Scan(&matches)
		if err != nil {
			return err
		}
		if !matches {
			return fmt.Errorf("queue target differs from the application's staged conversion authority")
		}
	}
	if _, err := tx.Exec(ctx, "set local role "+quoteIdentifier(roles.Owner)); err != nil {
		return err
	}
	raw, err := hex.DecodeString(document)
	if err != nil {
		return err
	}
	args := []any{state.DatabaseUUID, state.FenceNamespace, priorHash, raw, digest, abi, compatibility}
	var matches bool
	err = tx.QueryRow(ctx, "select database_uuid::text=$1 and fence_ns=$2 and predecessor_hash=$3 and contract=$4 and contract_hash=$5 and compiler_abi=$6 and stored_value_compatibility=$7 from "+ns+"tesl_row_queue_target_staging where version=2", args...).Scan(&matches)
	if err == nil {
		if !matches {
			return fmt.Errorf("immutable queue target staging differs")
		}
		return tx.Commit(ctx)
	}
	if err != pgx.ErrNoRows {
		return err
	}
	if _, err := tx.Exec(ctx, "insert into "+ns+"tesl_row_queue_target_staging(version,database_uuid,fence_ns,predecessor_hash,contract,contract_hash,compiler_abi,stored_value_compatibility) values(2,$1,$2,$3,$4,$5,$6,$7)", args...); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func mustQueueConversionDocument(source *pgQueueConversionSource) []byte {
	// The registry admitted these exact hex bytes before publication.
	raw, _ := hex.DecodeString(source.spec.document)
	return raw
}

// Stage immutable compiler-owned conversions in an actual fresh application
// control catalog. Staging is deliberately not an expansion receipt or dispatch
// grant: the target physical history must independently authorize activation.
// Only the short-lived installer can append these rows; Worker/Request can read
// them but cannot invent or replace staged callbacks.
func pgStageRowQueueConversions(ctx context.Context, conn *pgx.Conn, namespace string, roles PgMigrationControlRoles, digest string) error {
	lineage, err := pgQueueConversionCandidateLineage(digest)
	if err != nil {
		return err
	}
	root := lineage[len(lineage)-1]
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return err
	}
	defer pgQueueConversionCandidateRollback(tx)
	if err := pgControlSession(ctx, tx); err != nil {
		return err
	}
	if err := pgControlRoles(ctx, tx, roles, true); err != nil {
		return err
	}
	state, err := pgInspectRowControl(ctx, tx, namespace, roles)
	if err != nil {
		return err
	}
	ns := quoteIdentifier(namespace) + "."
	// Admission takes the real application's version fence and validates every
	// source inventory and completed expansion in its installed prefix.
	var floor int
	if err := tx.QueryRow(ctx, "select "+ns+"tesl_queue_admit($1,$2)", root.fromVersion, root.queue).Scan(&floor); err != nil {
		return err
	}
	var current, lockedFloor int
	if err := tx.QueryRow(ctx, "select current,min_version from "+ns+"tesl_schema_state where id=1 for update").Scan(&current, &lockedFloor); err != nil {
		return err
	}
	if current != root.fromVersion || lockedFloor != floor {
		return fmt.Errorf("queue conversion staging requires its exact currently installed source version")
	}
	var family, compatibility, inventory, expansion, schemaSnapshot, storageSnapshot string
	var old []byte
	err = tx.QueryRow(ctx, "select r.family,q.stored_value_compatibility,b.inventory_hash,b.expansion_hash,p.contract,q.schema_snapshot_hash,q.storage_snapshot_hash from "+ns+`tesl_row_versions r
 join `+ns+`tesl_queue_versions q on q.version=$1
 join `+ns+`tesl_row_queue_sources b on b.version=q.version
 join `+ns+`tesl_queue_payloads p on p.version=q.version and p.queue=$2 and p.job_type=$3
 where r.version=1`, root.fromVersion, root.queue, root.job).Scan(&family, &compatibility, &inventory, &expansion, &old, &schemaSnapshot, &storageSnapshot)
	if err != nil {
		return err
	}
	if family != root.family || compatibility != root.conversion.children[2].value || !bytes.Equal(old, pgQueueConversionPayloadContract(root, false)) {
		return fmt.Errorf("queue conversion source differs from the application's installed payload contract")
	}
	if !root.conversion.list(17) || root.conversion.children[13].value != schemaSnapshot || root.conversion.children[15].value != storageSnapshot {
		return fmt.Errorf("queue conversion source differs from the application's complete installed snapshot")
	}
	if _, err := tx.Exec(ctx, "set local role "+quoteIdentifier(roles.Owner)); err != nil {
		return err
	}
	for i := len(lineage) - 1; i >= 0; i-- {
		source := lineage[i]
		if _, err := pgReadQueueConversionSource(source.spec); err != nil {
			return err
		}
		document, err := hex.DecodeString(source.spec.document)
		if err != nil {
			return err
		}
		args := []any{state.DatabaseUUID, state.FenceNamespace, root.fromVersion, root.toVersion, root.queue, root.job, source.repairRevision,
			source.spec.digest, document, source.parentDigest, inventory, expansion, old, pgQueueConversionPayloadContract(source, true)}
		var matches bool
		err = tx.QueryRow(ctx, "select database_uuid::text=$1 and fence_ns=$2 and from_version=$3 and to_version=$4 and queue=$5 and job_type=$6 and revision=$7 and source_digest=$8 and source_document=$9 and parent_digest=$10 and inventory_hash=$11 and expansion_hash=$12 and old_contract=$13 and new_contract=$14 from "+ns+"tesl_row_queue_conversion_staging where from_version=$3 and queue=$5 and job_type=$6 and revision=$7", args...).Scan(&matches)
		if err == nil {
			if !matches {
				return fmt.Errorf("immutable application queue conversion staging differs")
			}
			continue
		}
		if err != pgx.ErrNoRows {
			return err
		}
		var count int
		if err := tx.QueryRow(ctx, "select count(*) from "+ns+"tesl_row_queue_conversion_staging where from_version=$1 and queue=$2 and job_type=$3", root.fromVersion, root.queue, root.job).Scan(&count); err != nil {
			return err
		}
		if count != source.repairRevision {
			return fmt.Errorf("application queue repair staging prefix is incomplete")
		}
		if _, err := tx.Exec(ctx, "insert into "+ns+"tesl_row_queue_conversion_staging(database_uuid,fence_ns,from_version,to_version,queue,job_type,revision,source_digest,source_document,parent_digest,inventory_hash,expansion_hash,old_contract,new_contract) values($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)", args...); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

func pgCreateRowQueueBaseline(ctx context.Context, tx pgx.Tx, b *pgRowBaseline, roles PgMigrationControlRoles) error {
	if len(b.queues) == 0 {
		return fmt.Errorf("missing complete row queue source inventory")
	}
	if err := pgCreateQueueCandidateTables(ctx, tx, b.history.Namespace, roles); err != nil {
		return err
	}
	source := b.queues[0]
	ns := quoteIdentifier(b.history.Namespace) + "."
	if _, err := tx.Exec(ctx, "insert into "+ns+"tesl_queue_baseline(id,inventory_authority,established_by,initial_version,inventory_hash) values(1,'complete','fresh-install',1,$1)", source.inventoryHash); err != nil {
		return err
	}
	if err := pgInsertQueueCandidateInventory(ctx, tx, b.history, source.version, source.inventoryHash); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, "insert into "+ns+"tesl_row_queue_sources values(1,$1,$2,$3,$4)", []byte(source.binding), source.bindingHash, source.inventoryHash, b.catalogHash)
	return err
}

func pgRegisterRowQueueSource(ctx context.Context, tx pgx.Tx, b *pgRowBaseline, plan *pgRowPhysicalPlan) error {
	if plan == nil || plan.version < 2 || plan.version > len(b.queues) {
		return fmt.Errorf("row expansion lacks exact complete queue source")
	}
	source := b.queues[plan.version-1]
	if source.version.SchemaSnapshotHash != plan.schemaSnapshotHash || source.version.StorageSnapshotHash != plan.storageSnapshotHash {
		return fmt.Errorf("row queue source differs from exact physical source snapshots")
	}
	contracts, err := pgQueueRegistrationJSON(source.version.Contracts)
	if err != nil {
		return err
	}
	ns := quoteIdentifier(b.history.Namespace) + "."
	_, err = tx.Exec(ctx, "select "+ns+"tesl_register_row_queue_source($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb,$10,$11,$12)", b.history.Family, plan.version, source.version.StorageSnapshotHash, source.version.SchemaSnapshotHash, b.history.SourceCompilerABI, b.history.StoredValueCompatibility, source.version.SourceSealInventory, source.inventoryHash, string(contracts), []byte(source.binding), source.bindingHash, plan.hash)
	return err
}

func pgVerifyRowQueueBaseline(ctx context.Context, tx pgx.Tx, b *pgRowBaseline, state PgMigrationControlState) error {
	if len(b.queues) == 0 {
		return fmt.Errorf("missing complete row queue source inventory")
	}
	ns := quoteIdentifier(b.history.Namespace) + "."
	source := b.queues[0]
	var initial, versions, physicalVersions int
	var authority, established string
	var hash *string
	if err := tx.QueryRow(ctx, "select inventory_authority,established_by,initial_version,inventory_hash from "+ns+"tesl_queue_baseline where id=1").Scan(&authority, &established, &initial, &hash); err != nil {
		return err
	}
	if authority != "complete" || established != "fresh-install" || initial != 1 || hash == nil || *hash != source.inventoryHash {
		return fmt.Errorf("row queue baseline is not the exact complete fresh origin")
	}
	rows, err := tx.Query(ctx, "select version,source_binding,source_binding_hash,inventory_hash,expansion_hash from "+ns+"tesl_row_queue_sources order by version")
	if err != nil {
		return err
	}
	type binding struct {
		version                    int
		body                       []byte
		hash, inventory, expansion string
	}
	bindings, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (binding, error) {
		var b binding
		err := row.Scan(&b.version, &b.body, &b.hash, &b.inventory, &b.expansion)
		return b, err
	})
	if err != nil {
		return err
	}
	if err := tx.QueryRow(ctx, "select (select count(*) from "+ns+"tesl_queue_versions),(select count(*) from "+ns+"tesl_row_physical where version>1)").Scan(&versions, &physicalVersions); err != nil {
		return err
	}
	minimum := max(1, state.Current)
	if len(bindings) < minimum || len(bindings) > max(1, state.Current+1) || versions != len(bindings) || physicalVersions != len(bindings)-1 {
		return fmt.Errorf("row queue inventory is not the complete installed prefix")
	}
	var previous PgQueueSourceVersion
	for i, item := range bindings {
		if item.version != i+1 {
			return fmt.Errorf("row queue source versions are not contiguous")
		}
		recorded, err := pgReadQueueCandidateInventory(ctx, tx, b.history, item.version)
		if err != nil {
			return err
		}
		expected, err := pgRowQueueSourceBinding(b.history, recorded.Version)
		if err != nil {
			return err
		}
		if recorded.Hash != expected.inventoryHash || item.inventory != recorded.Hash || item.hash != expected.bindingHash || !bytes.Equal(item.body, []byte(expected.binding)) {
			return fmt.Errorf("row-owned queue canonical source binding differs")
		}
		if i < len(b.queues) && expected.inventoryHash != b.queues[i].inventoryHash {
			return fmt.Errorf("row queue inventory differs from local checked source")
		}
		if i > 0 && !pgQueueInventoryPreserves(previous, recorded.Version) {
			return fmt.Errorf("row queue recorded payload was removed, moved or changed")
		}
		if i == 0 {
			if item.expansion != b.catalogHash || expected.inventoryHash != source.inventoryHash {
				return fmt.Errorf("row queue source differs from original baseline expansion")
			}
		} else {
			var document []byte
			var hash, creator, compatibility string
			if err := tx.QueryRow(ctx, "select contract,contract_hash,compiler_abi,stored_value_compatibility from "+ns+"tesl_row_physical where version=$1", item.version).Scan(&document, &hash, &creator, &compatibility); err != nil {
				return err
			}
			plan, err := pgParseRowPhysicalPlan(fmt.Sprintf("%x", document), hash)
			if err != nil {
				return err
			}
			if plan.version != item.version || plan.family != b.history.Family || plan.namespace != b.history.Namespace || plan.schemaSnapshotHash != recorded.Version.SchemaSnapshotHash || plan.storageSnapshotHash != recorded.Version.StorageSnapshotHash || item.expansion != hash || recorded.CreatorABI != creator || recorded.Compatibility != compatibility {
				return fmt.Errorf("row queue source binding differs from recorded physical version")
			}
		}
		previous = recorded.Version
	}
	return nil
}

// Internal installer-only boundary: validates and closes the exact generated
// source/owner/codec inventory without permitting ordinary queue App startup.
// It is not selected by the public installer, CLI, opener, or Queue backend.
func pgInstallCompiledRowQueueCatalog(ctx context.Context, conn *pgx.Conn, database *Database, roles PgMigrationControlRoles) (PgMigrationControlState, error) {
	pgMigrationRegistrations.Lock()
	pending, err := pgPrepareApplicationDatabases([]*Database{database})
	if err == nil {
		history, ok := database.CompiledMigrationHistory()
		if !ok {
			err = fmt.Errorf("catalog installer requires versioned database")
		} else {
			_, err = pgRowQueueSources(history)
		}
	}
	if err == nil {
		database.mutex.RLock()
		for facility := range database.migrationFacilities {
			if facility.kind != "queue" {
				err = fmt.Errorf("row queue catalog refuses unsupported facility %s", facility.kind)
				break
			}
		}
		database.mutex.RUnlock()
	}
	if err == nil {
		pending.closeRegistrations()
	}
	pgMigrationRegistrations.Unlock()
	if err != nil {
		return PgMigrationControlState{}, err
	}
	baseline, err := pgCompiledRowBaseline(database)
	if err != nil {
		return PgMigrationControlState{}, err
	}
	return pgInstallMigrationControlPrepared(ctx, conn, baseline.history.Namespace, roles, 1, nil, &pgRowBaselinePreparation{baseline: baseline, roles: roles})
}
