package teslrt

import (
	"bytes"
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

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
