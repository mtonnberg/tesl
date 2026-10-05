package teslrt

import (
	"bytes"
	"context"
	"encoding/hex"
	"fmt"
	"reflect"

	"github.com/jackc/pgx/v5"
)

// Bind a compiler-checked queue-only target physical descriptor to the actual
// installed application and staged callbacks. This does not insert an expansion
// receipt, publish V2, alter jobs or grant dispatch. Activation must consume the
// exact target binding rather than treating a standalone payload as a schema.
func pgStageRowQueueTarget(ctx context.Context, conn *pgx.Conn, namespace string, roles PgMigrationControlRoles, document, digest string) error {
	plan, err := pgParseRowPhysicalPlan(document, digest)
	if err != nil {
		return err
	}
	if plan.namespace != namespace || plan.version < 2 || len(plan.queueConversions) == 0 || len(plan.windows) != 0 || len(plan.retirements) != 0 || plan.requiresContractVersion != 0 {
		return fmt.Errorf("queue target staging requires an exact adjacent queue-only physical descriptor")
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
		if err := tx.QueryRow(ctx, "select "+ns+"tesl_queue_admit($1,$2)", plan.version-1, conversion.queue).Scan(&floor); err != nil {
			return err
		}
	}
	var current int
	if err := tx.QueryRow(ctx, "select current from "+ns+"tesl_schema_state where id=1 for update").Scan(&current); err != nil {
		return err
	}
	if current != plan.version-1 || state.MinVersion != current || state.CompatFloor != current {
		return fmt.Errorf("queue target staging requires the fully retired adjacent source")
	}
	var priorDoc []byte
	var priorHash, abi, compatibility, family string
	if err := tx.QueryRow(ctx, "select p.contract,p.contract_hash,p.compiler_abi,p.stored_value_compatibility,r.family from "+ns+"tesl_row_physical p cross join "+ns+"tesl_row_versions r where p.version=$1 and r.version=1", current).Scan(&priorDoc, &priorHash, &abi, &compatibility, &family); err != nil {
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
	if err := tx.QueryRow(ctx, "select count(*) from "+ns+"tesl_row_queue_conversion_staging where from_version=$1 and revision=0", current).Scan(&staged); err != nil {
		return err
	}
	if staged != len(plan.queueConversions) {
		return fmt.Errorf("queue target does not cover the complete staged conversion set")
	}
	for _, conversion := range plan.queueConversions {
		compiledQueueConversionSources.RLock()
		source := compiledQueueConversionSources.byDigest[conversion.digest]
		compiledQueueConversionSources.RUnlock()
		if source == nil || source.parentDigest != "" || source.family != family || source.queue != conversion.queue || source.job != conversion.job || source.fromVersion != current || source.toVersion != plan.version || source.conversion.children[2].value != compatibility || source.conversion.children[1].value != abi {
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
		err = tx.QueryRow(ctx, "select s.database_uuid::text=$1 and s.fence_ns=$2 and s.to_version=$10 and s.source_digest=$3 and s.source_document=$4 and s.old_contract=$5 and s.new_contract=$6 and s.inventory_hash=q.inventory_hash and s.expansion_hash=q.expansion_hash and s.old_contract=p.contract from "+ns+`tesl_row_queue_conversion_staging s
 join `+ns+`tesl_row_queue_sources q on q.version=s.from_version
 join `+ns+`tesl_queue_payloads p on p.version=s.from_version and p.queue=s.queue and p.job_type=s.job_type
  where s.from_version=$9 and s.queue=$7 and s.job_type=$8 and s.revision=0`, state.DatabaseUUID, state.FenceNamespace, source.spec.digest, mustQueueConversionDocument(source), old, fresh, source.queue, source.job, current, plan.version).Scan(&matches)
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
	args := []any{state.DatabaseUUID, state.FenceNamespace, priorHash, raw, digest, abi, compatibility, plan.version}
	var matches bool
	err = tx.QueryRow(ctx, "select database_uuid::text=$1 and fence_ns=$2 and predecessor_hash=$3 and contract=$4 and contract_hash=$5 and compiler_abi=$6 and stored_value_compatibility=$7 from "+ns+"tesl_row_queue_target_staging where version=$8", args...).Scan(&matches)
	if err == nil {
		if !matches {
			return fmt.Errorf("immutable queue target staging differs")
		}
		return tx.Commit(ctx)
	}
	if err != pgx.ErrNoRows {
		return err
	}
	if _, err := tx.Exec(ctx, "insert into "+ns+"tesl_row_queue_target_staging(version,database_uuid,fence_ns,predecessor_hash,contract,contract_hash,compiler_abi,stored_value_compatibility) values($8,$1,$2,$3,$4,$5,$6,$7)", args...); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func mustQueueConversionDocument(source *pgQueueConversionSource) []byte {
	// The registry admitted these exact hex bytes before publication.
	raw, _ := hex.DecodeString(source.spec.document)
	return raw
}

// Select only executable repairs rooted in this binary's exact physical edge.
// Refuse competing repair branches before any installer transaction is opened.
func pgCompiledRowQueueInstallSources(b *pgRowBaseline) ([]string, error) {
	compiledQueueConversionExecutables.RLock()
	sources := make([]*pgQueueConversionSource, 0, len(compiledQueueConversionExecutables.byDigest))
	for _, executable := range compiledQueueConversionExecutables.byDigest {
		sources = append(sources, executable.queueConversionSource())
	}
	compiledQueueConversionExecutables.RUnlock()
	result := make([]string, 0, len(b.target.queueConversions))
	for _, conversion := range b.target.queueConversions {
		latest, revision := conversion.digest, 0
		seen := map[int]string{}
		for _, source := range sources {
			if source.family != b.history.Family || source.queue != conversion.queue || source.job != conversion.job || source.toVersion != b.target.version {
				continue
			}
			lineage, err := pgQueueConversionCandidateLineage(source.spec.digest)
			if err != nil {
				return nil, err
			}
			if lineage[len(lineage)-1].spec.digest != conversion.digest {
				return nil, fmt.Errorf("compiled queue repair differs from the physical edge's exact root")
			}
			for _, ancestor := range lineage {
				if prior, ok := seen[ancestor.repairRevision]; ok && prior != ancestor.spec.digest {
					return nil, fmt.Errorf("compiled queue repairs contain competing immutable revisions")
				}
				seen[ancestor.repairRevision] = ancestor.spec.digest
			}
			if source.repairRevision > revision {
				latest, revision = source.spec.digest, source.repairRevision
			}
		}
		if _, ok := seen[0]; !ok {
			return nil, fmt.Errorf("queue installation lacks its compiler-linked executable root")
		}
		result = append(result, latest)
	}
	return result, nil
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
	if (current != root.fromVersion && current != root.toVersion) || lockedFloor != floor || lockedFloor != root.fromVersion || state.CompatFloor != root.fromVersion {
		return fmt.Errorf("queue conversion staging requires its admitted source or exact published target")
	}
	if current == root.toVersion {
		var authorized bool
		if err := tx.QueryRow(ctx, "select exists(select 1 from "+ns+`tesl_row_queue_target_staging t
 join `+ns+`tesl_row_physical p on p.version=t.version and p.contract=t.contract and p.contract_hash=t.contract_hash
 join `+ns+`tesl_schema_versions v on v.version=t.version and v.step='expanded' and v.artefact_hash=t.contract_hash
 join `+ns+`tesl_row_queue_conversion_staging c on c.to_version=t.version and c.revision=0
 where t.version=$1 and t.database_uuid::text=$2 and t.fence_ns=$3 and c.source_digest=$4 and c.source_document=$5)`, root.toVersion, state.DatabaseUUID, state.FenceNamespace, root.spec.digest, mustQueueConversionDocument(root)).Scan(&authorized); err != nil {
			return err
		}
		if !authorized {
			return fmt.Errorf("repair staging requires the immutable root of the completed queue expansion")
		}
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
			if err := pgVerifyRowQueueTransition(ctx, tx, b.history.Namespace, state, previous, recorded.Version); err != nil {
				return err
			}
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

func pgVerifyRowQueueTransition(ctx context.Context, tx pgx.Tx, namespace string, state PgMigrationControlState, before, after PgQueueSourceVersion) error {
	ns := quoteIdentifier(namespace) + "."
	oldJSON, err := pgQueueRegistrationJSON(before.Contracts)
	if err != nil {
		return err
	}
	newJSON, err := pgQueueRegistrationJSON(after.Contracts)
	if err != nil {
		return err
	}
	var valid bool
	if err := tx.QueryRow(ctx, "select "+ns+"tesl_row_queue_transition_valid($1::jsonb,$2::jsonb,$3)", string(oldJSON), string(newJSON), after.Version).Scan(&valid); err != nil {
		return err
	}
	if !valid {
		return fmt.Errorf("row queue recorded transition lacks exact staged authority")
	}
	var raw []byte
	var hash string
	if err := tx.QueryRow(ctx, "select contract,contract_hash from "+ns+"tesl_row_queue_target_staging where version=$1", after.Version).Scan(&raw, &hash); err != nil {
		return err
	}
	plan, err := pgParseRowPhysicalPlan(hex.EncodeToString(raw), hash)
	if err != nil {
		return err
	}
	if plan.version != after.Version || pgRowEpochPreserving(plan) || plan.schemaSnapshotHash != after.SchemaSnapshotHash || plan.storageSnapshotHash != after.StorageSnapshotHash {
		return fmt.Errorf("staged queue target differs from its registered inventory")
	}
	for _, c := range plan.queueConversions {
		payload := func(v PgQueueSourceVersion, expected string) bool {
			for _, q := range v.Contracts {
				if q.Queue == c.queue {
					for _, p := range q.Payloads {
						if p.Job == c.job {
							return p.Contract == expected
						}
					}
				}
			}
			return false
		}
		if !payload(before, c.oldContract) || !payload(after, c.newContract) {
			return fmt.Errorf("registered queue inventory differs from its physical conversion payloads")
		}
		var matches bool
		if err := tx.QueryRow(ctx, "select database_uuid::text=$1 and fence_ns=$2 and source_digest=$3 and old_contract=$4 and new_contract=$5 from "+ns+"tesl_row_queue_conversion_staging where from_version=$6 and queue=$7 and job_type=$8 and revision=0", state.DatabaseUUID, state.FenceNamespace, c.digest, mustQueueContractBytes(c.oldContract), mustQueueContractBytes(c.newContract), before.Version, c.queue, c.job).Scan(&matches); err != nil {
			return err
		}
		if !matches {
			return fmt.Errorf("physical queue decision differs from immutable staged source")
		}
	}
	return nil
}

func mustQueueContractBytes(encoded string) []byte {
	raw, _ := hex.DecodeString(encoded) // Admitted by the canonical physical parser.
	return raw
}

// Prepare the protected successor physical manifest and complete queue inventory
// atomically from the staged target. This does not publish the expansion or grant
// Target admission. Unchanged entities keep all physical operations at zero.
func pgPrepareRowQueueTarget(ctx context.Context, conn *pgx.Conn, namespace string, roles PgMigrationControlRoles, target PgQueueSourceVersion, document, digest string) error {
	plan, err := pgParseRowPhysicalPlan(document, digest)
	if err != nil {
		return err
	}
	if plan.namespace != namespace || plan.version < 2 || target.Version != plan.version || len(plan.queueConversions) == 0 || target.SchemaSnapshotHash != plan.schemaSnapshotHash || target.StorageSnapshotHash != plan.storageSnapshotHash {
		return fmt.Errorf("queue successor inventory differs from checked target")
	}
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return err
	}
	defer pgQueueConversionCandidateRollback(tx)
	if err := pgControlSession(ctx, tx); err != nil {
		return err
	}
	if err := pgControlRoles(ctx, tx, roles, false); err != nil {
		return err
	}
	var worker bool
	if err := tx.QueryRow(ctx, "select current_user=$1 and session_user=$1", roles.Worker).Scan(&worker); err != nil {
		return err
	}
	if !worker {
		return fmt.Errorf("queue target preparation requires exact Worker login")
	}
	state, err := pgInspectRowControl(ctx, tx, namespace, roles)
	if err != nil {
		return err
	}
	ns := quoteIdentifier(namespace) + "."
	var prior, abi, compatibility string
	var raw []byte
	var uuid string
	var fence int
	if err := tx.QueryRow(ctx, "select predecessor_hash,compiler_abi,stored_value_compatibility,contract,database_uuid::text,fence_ns from "+ns+"tesl_row_queue_target_staging where version=$2 and contract_hash=$1", digest, plan.version).Scan(&prior, &abi, &compatibility, &raw, &uuid, &fence); err != nil {
		return err
	}
	if uuid != state.DatabaseUUID || fence != state.FenceNamespace || hex.EncodeToString(raw) != document {
		return fmt.Errorf("queue target staging belongs to another installation or descriptor")
	}
	contracts, err := pgQueueRegistrationJSON(target.Contracts)
	if err != nil {
		return err
	}
	history := PgCompiledMigrationHistory{Family: plan.family, Namespace: namespace, SourceCompilerABI: abi, StoredValueCompatibility: compatibility}
	source, err := pgRowQueueSourceBinding(history, target)
	if err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, "select "+ns+"tesl_register_row_physical($6,$1,$2,$3,$4,$5,0,false)", prior, raw, digest, abi, compatibility, plan.version); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, "select "+ns+"tesl_register_row_queue_source($1,$12,$2,$3,$4,$5,$6,$7,$8::jsonb,$9,$10,$11)", plan.family, target.StorageSnapshotHash, target.SchemaSnapshotHash, abi, compatibility, target.SourceSealInventory, source.inventoryHash, string(contracts), []byte(source.binding), source.bindingHash, digest, plan.version); err != nil {
		return err
	}
	before, err := pgReadQueueCandidateInventory(ctx, tx, history, plan.version-1)
	if err != nil {
		return err
	}
	if err := pgVerifyRowQueueTransition(ctx, tx, namespace, state, before.Version, target); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, "select "+ns+"tesl_begin_expansion($4,$1,$1,$2,$3,0,false)", digest, abi, compatibility, plan.version); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// Complete the zero-DDL queue-only expansion using the application's normal
// compatibility drain and protected publication function. New-version admission
// starts only at this commit; preparation and target staging alone cannot admit it.
func pgPublishRowQueueTarget(ctx context.Context, conn *pgx.Conn, namespace string, roles PgMigrationControlRoles, target PgQueueSourceVersion, document, digest string) error {
	if err := pgPrepareRowQueueTarget(ctx, conn, namespace, roles, target, document, digest); err != nil {
		return err
	}
	var initial PgMigrationControlState
	if err := pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error {
		var err error
		initial, err = pgInspectRowControl(ctx, tx, namespace, roles)
		return err
	}); err != nil {
		return err
	}
	if initial.Current != target.Version-1 && initial.Current != target.Version {
		return fmt.Errorf("queue target publication requires its adjacent source or exact target replay")
	}
	ns := quoteIdentifier(namespace) + "."
	return pgRowCompatibilityDrain(ctx, conn, initial.FenceNamespace, initial.MinVersion, initial.Current, "queue-target", func() error {
		return pgExpansionTransaction(ctx, conn, func(tx pgx.Tx) error {
			state, err := pgInspectRowControl(ctx, tx, namespace, roles)
			if err != nil {
				return err
			}
			if state.DatabaseUUID != initial.DatabaseUUID || state.FenceNamespace != initial.FenceNamespace || state.Current != initial.Current || state.MinVersion != initial.MinVersion {
				return fmt.Errorf("queue target admission changed while draining")
			}
			var physicalDoc []byte
			var physicalHash string
			var preserving bool
			var ops int
			if err := tx.QueryRow(ctx, "select contract,contract_hash,epoch_preserving,operation_count from "+ns+"tesl_row_physical where version=$1", target.Version).Scan(&physicalDoc, &physicalHash, &preserving, &ops); err != nil {
				return err
			}
			if hex.EncodeToString(physicalDoc) != document || physicalHash != digest || preserving || ops != 0 {
				return fmt.Errorf("queue target publication lost its exact narrowing manifest")
			}
			var family, abi, compatibility string
			if err := tx.QueryRow(ctx, "select family,compiler_abi,stored_value_compatibility from "+ns+"tesl_row_versions where version=1").Scan(&family, &abi, &compatibility); err != nil {
				return err
			}
			history := PgCompiledMigrationHistory{Family: family, Namespace: namespace, SourceCompilerABI: abi, StoredValueCompatibility: compatibility}
			before, err := pgReadQueueCandidateInventory(ctx, tx, history, target.Version-1)
			if err != nil {
				return err
			}
			after, err := pgReadQueueCandidateInventory(ctx, tx, history, target.Version)
			if err != nil {
				return err
			}
			if !reflect.DeepEqual(after.Version, target) {
				return fmt.Errorf("queue target inventory changed before publication")
			}
			if err := pgVerifyRowQueueTransition(ctx, tx, namespace, state, before.Version, after.Version); err != nil {
				return err
			}
			_, err = tx.Exec(ctx, "select "+ns+"tesl_record_expanded($1)", target.Version)
			return err
		})
	})
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
